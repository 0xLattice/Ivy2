import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Ports of the connection and session tests in 15.0.1's
/// TCPIntegrationTests and PostIdentifyCallbackTests, plus the lifecycle
/// rules the sans-IO core states directly: pending sessions are invisible
/// and time out, sequences never repeat, reconnects back off, and stop
/// leaves nothing behind.
final class SessionLifecycleSimulationTests: XCTestCase {
    private func sessionID(_ node: Simulation.Node, for peer: PeerID) -> Data? {
        node.core.authenticatedPeer(for: peer)?.sessionID
    }

    // MARK: - Authentication

    // "SessionFinish authenticates both ends of a TCP connection"
    func testAuthenticatedConnect() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()

        sim.connect(client, server)

        XCTAssertEqual(server.core.peerConnectionCount, 1)
        XCTAssertEqual(client.core.peerConnectionCount, 1)
        XCTAssertEqual(server.connected.map(\.key), [client.key])
        XCTAssertEqual(client.connected.map(\.key), [server.key])
        XCTAssertEqual(sessionID(server, for: client.peer), sessionID(client, for: server.peer))
        XCTAssertEqual(server.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(client.core.diagnostics.pendingSessions, 0)
    }

    // "didConnect exposes only transcript-authenticated transport metadata"
    func testAuthenticatedMetadata() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()

        sim.connect(client, server)

        let event = server.connected.first
        XCTAssertEqual(server.connected.count, 1)
        XCTAssertEqual(event?.key, client.key)
        XCTAssertEqual(event?.role, .endpoint)
        XCTAssertEqual(event?.route, .direct)
        XCTAssertEqual(event?.metadata, PeerMetadata(
            listenAddresses: [ListenAddress(host: client.host, port: 4001)]))
        XCTAssertEqual(event?.sessionID, sessionID(server, for: client.peer))
    }

    // "a single authenticated frame above 4 MiB crosses TCP once both peers raise the limit"
    func testLargeNegotiatedFrameCrossesConnection() {
        let bigFrame: UInt32 = 8 * 1024 * 1024
        let sim = Simulation()
        let server = sim.node(protocolMaxFrameSize: bigFrame)
        let client = sim.node(protocolMaxFrameSize: bigFrame)
        sim.connect(client, server)
        XCTAssertEqual(server.connected.first?.metadata.maxFrameSize, bigFrame)

        // Above the 4 MiB default, below the negotiated 8 MiB.
        let payload = Data(repeating: 0x5A, count: 5 * 1024 * 1024)
        let sent = sim.await(.send(to: server.peer, topic: "big-frame", payload: payload), on: client)
        XCTAssertEqual(sent?.sent, .enqueued(endpoint: server.peer, route: .direct))

        sim.run(until: { !server.received.isEmpty })
        XCTAssertEqual(server.received.first?.message, PeerMessage(topic: "big-frame", payload: payload))
        XCTAssertEqual(server.received.first?.peer.id, client.peer)
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.core.diagnostics.inboundBytesUsed, 0)
    }

    // A peer that kept the default is not sent more than it advertised.
    func testFrameAboveThePeersAdvertisedLimitIsLocallyRejected() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node(protocolMaxFrameSize: 8 * 1024 * 1024)
        sim.connect(client, server)

        let payload = Data(repeating: 0x5A, count: 5 * 1024 * 1024)
        let sent = sim.await(.send(to: server.peer, topic: "big-frame", payload: payload), on: client)

        XCTAssertEqual(sent?.sent, .locallyRejected)
        sim.run(for: .seconds(1))
        XCTAssertTrue(server.received.isEmpty)
        XCTAssertEqual(server.core.peerConnectionCount, 1)
    }

    // "connections accepted before discovery completes are health-tracked"
    func testConnectionDuringDiscoveryIsHealthTracked() {
        let sim = Simulation()
        let server = sim.addNode { key in
            IvyConfig(
                signingKey: key,
                stunServers: [("stun.invalid", 3478)],
                healthConfig: PeerHealthConfig(
                    keepaliveInterval: .seconds(60),
                    staleTimeout: .seconds(180)))
        }
        sim.start(server)
        XCTAssertTrue(sim.effects(of: server).contains(.discoverPublicAddress))
        let client = sim.node()

        sim.connect(client, server)

        XCTAssertNil(server.core.publicAddress)
        XCTAssertNotNil(server.core.health[client.peer])
        XCTAssertEqual(
            server.core.health[client.peer]?.sessionID.bytes, sessionID(server, for: client.peer))
    }

    // "Outbound authentication rejects an unexpected identity"
    func testIdentityMismatch() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()
        let expected = PeerEndpoint(
            publicKey: HandPeer.key(sim, index: 1).hex, host: server.host, port: 4001)

        let result = sim.await(.connect(expected), on: client)

        XCTAssertEqual(result?.isFailedConnect, true)
        sim.run(for: .seconds(1))
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertEqual(server.core.peerConnectionCount, 0)
        XCTAssertTrue(client.connected.isEmpty)
        XCTAssertTrue(server.connected.isEmpty)
        XCTAssertEqual(client.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(server.core.diagnostics.pendingSessions, 0)
    }

    // "Pinned listener rejects a substitute identity"
    func testPinnedSubstitute() {
        let sim = Simulation()
        let listener = sim.node(mode: .pinned(peer: HandPeer.key(sim, index: 1).hex))
        let substitute = sim.node()

        let result = sim.await(.connect(listener.endpoint), on: substitute)

        XCTAssertEqual(result?.isFailedConnect, true)
        sim.run(for: .seconds(1))
        XCTAssertEqual(listener.core.peerConnectionCount, 0)
        XCTAssertTrue(listener.connected.isEmpty)
        XCTAssertEqual(substitute.core.peerConnectionCount, 0)
    }

    // A pinned node does not dial anyone else either.
    func testPinnedNodeRefusesToDialAnotherIdentity() {
        let sim = Simulation()
        let other = sim.node()
        let pinned = sim.node(mode: .pinned(peer: HandPeer.key(sim, index: 1).hex))

        let result = sim.await(.connect(other.endpoint), on: pinned)

        XCTAssertEqual(result, .connect(.failed(.peerOutsideMode)))
        XCTAssertTrue(sim.dials(from: pinned).isEmpty)
    }

    func testConnectRejectsMalformedKeyAndStoppedNode() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()

        let malformed = sim.await(
            .connect(PeerEndpoint(publicKey: "not-a-key", host: server.host, port: 4001)), on: client)
        XCTAssertEqual(malformed, .connect(.failed(.invalidPeerKey)))

        sim.stop(client)
        XCTAssertEqual(sim.await(.connect(server.endpoint), on: client), .connect(.failed(.notRunning)))
        XCTAssertTrue(sim.dials(from: client).isEmpty)
    }

    // "the authenticated connection cap rejects excess peers"
    func testAuthenticatedConnectionCap() {
        let sim = Simulation()
        let server = sim.node(maxConnections: 1)
        let first = sim.node()
        let second = sim.node()

        sim.connect(first, server)
        let result = sim.await(.connect(server.endpoint), on: second)

        XCTAssertEqual(result?.isFailedConnect, true)
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.core.peerConnectionCount, 1)
        XCTAssertEqual(server.core.connectedPeers, [first.peer])
        XCTAssertEqual(second.core.peerConnectionCount, 0)
    }

    // MARK: - Pending sessions (IVY-002)

    func testPendingSessionIsInvisibleAndTimesOut() {
        let sim = Simulation()
        let node = sim.node(maxConnectionsPerNetgroup: 4)
        let silent = sim.openRawConnection(to: node, fromHost: "10.1.0.1")
        let halfway = HandPeer(sim, to: node, index: 1, host: "10.2.0.1")
        halfway.sendHello()
        XCTAssertTrue(halfway.receiveResponder())

        XCTAssertEqual(node.core.diagnostics.pendingSessions, 2)
        XCTAssertTrue(node.core.connectedPeers.isEmpty)
        XCTAssertTrue(node.core.connectedPeerEndpoints.isEmpty)
        XCTAssertTrue(node.core.knownPeerEndpoints.isEmpty)
        XCTAssertNil(node.core.authenticatedPeer(for: halfway.id))
        XCTAssertEqual(
            sim.await(.send(to: halfway.id, topic: "t", payload: Data()), on: node)?.sent,
            .notConnected)

        sim.run(for: .milliseconds(29_999))
        XCTAssertFalse(sim.nodeClosedRaw(silent))
        XCTAssertFalse(halfway.isClosed)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 2)

        sim.run(for: .milliseconds(1))
        XCTAssertTrue(sim.nodeClosedRaw(silent))
        XCTAssertTrue(halfway.isClosed)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        // The application never heard of either.
        XCTAssertTrue(node.connected.isEmpty)
        XCTAssertTrue(node.disconnected.isEmpty)
        XCTAssertTrue(node.received.isEmpty)
        XCTAssertEqual(node.core.diagnostics.deadlines, 1)
    }

    func testFinishedHandshakeIsNotTimedOut() {
        let sim = Simulation()
        let node = sim.node()
        let peer = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        XCTAssertTrue(peer.authenticate())

        sim.run(for: .seconds(120))

        XCTAssertFalse(peer.isClosed)
        XCTAssertTrue(peer.isAuthenticated)
        XCTAssertTrue(node.disconnected.isEmpty)
    }

    func testRecordsOnAPendingSessionNeverReachTheApplication() {
        let sim = Simulation()
        let node = sim.node(maxConnectionsPerNetgroup: 8)

        // An application record before the handshake has finished.
        let early = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        early.sendHello()
        XCTAssertTrue(early.receiveResponder())
        early.sendMessage("too-early")
        XCTAssertTrue(early.isClosed)

        // A Finish for a session the node never offered.
        let unasked = HandPeer(sim, to: node, index: 2, host: "10.2.0.1")
        unasked.write(.finish(try! SessionFinish.sign(
            sessionID: try! SessionID(bytes: Data(repeating: 7, count: 32)),
            sender: unasked.key,
            receiver: node.key,
            with: SimulatedSignatureScheme(key: unasked.key))))
        XCTAssertTrue(unasked.isClosed)

        // A hello meant for someone else.
        let misdirected = HandPeer(sim, to: node, index: 3, host: "10.3.0.1")
        misdirected.sendHello(responder: HandPeer.key(sim, index: 99))
        XCTAssertTrue(misdirected.isClosed)

        // A hello signed by another key.
        let forged = HandPeer(sim, to: node, index: 4, host: "10.4.0.1")
        let hello = SessionHelloInitiator(
            routeBinding: IvyCore.directRouteBinding,
            initiator: forged.key,
            responder: node.key,
            nonce: Data(repeating: 1, count: 32),
            metadata: PeerMetadata().encode()!)
        forged.write(.helloInitiator(try! SignedSessionHelloInitiator.sign(
            hello, with: SimulatedSignatureScheme(key: HandPeer.key(sim, index: 98)))))
        XCTAssertTrue(forged.isClosed)

        // Bytes that are no record at all.
        let garbage = HandPeer(sim, to: node, index: 5, host: "10.5.0.1")
        garbage.writeFrames([Data(repeating: 0xEE, count: 64)])
        XCTAssertTrue(garbage.isClosed)

        // A second hello on one connection.
        let repeated = HandPeer(sim, to: node, index: 6, host: "10.6.0.1")
        repeated.sendHello(nonce: 1)
        repeated.sendHello(nonce: 2)
        XCTAssertTrue(repeated.isClosed)

        sim.run(for: .seconds(1))
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertTrue(node.connected.isEmpty)
        XCTAssertTrue(node.disconnected.isEmpty)
        XCTAssertTrue(node.received.isEmpty)
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0)
    }

    func testApplicationSeesSessionBeforeItsRecords() {
        let sim = Simulation()
        let node = sim.node()
        node.holdsDeliveries = true
        let peer = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")

        XCTAssertTrue(peer.authenticate())
        peer.sendMessage("first")
        peer.sendMessage("second")
        sim.run(for: .seconds(1))

        // The session is announced and nothing else moves until it is taken.
        XCTAssertEqual(node.connected.map(\.id), [peer.id])
        XCTAssertTrue(node.received.isEmpty)
        XCTAssertEqual(node.heldDeliveries.count, 1)
        XCTAssertFalse(peer.isRead)
        XCTAssertFalse(peer.isClosed)

        sim.openDeliveries(node)
        sim.run(until: { node.received.count == 2 })
        XCTAssertEqual(node.received.map(\.message.topic), ["first", "second"])
        XCTAssertTrue(peer.isRead)
    }

    // MARK: - Messages

    // "Authenticated TCP carries directed sync and broadcast gossip"
    func testPeerMessageDelivery() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()
        sim.connect(client, server)

        let payload = Data("opaque node state".utf8)
        XCTAssertEqual(
            sim.await(.send(to: server.peer, topic: "node.state", payload: payload), on: client)?.sent,
            .enqueued(endpoint: server.peer, route: .direct))
        sim.run(until: { !server.received.isEmpty })
        XCTAssertEqual(server.received.first?.message, PeerMessage(topic: "node.state", payload: payload))
        XCTAssertEqual(server.received.first?.peer, server.connected.first)

        let gossip = Data("new block".utf8)
        sim.send(.command(.broadcast(topic: "blocks.gossip", payload: gossip)), to: client)
        sim.run(until: { server.received.count == 2 })
        XCTAssertEqual(server.received.last?.message, PeerMessage(topic: "blocks.gossip", payload: gossip))
        XCTAssertEqual(server.received.last?.peer.id, client.peer)
    }

    func testBroadcastReachesEveryConnectedPeer() {
        let sim = Simulation()
        let hub = sim.node()
        let spokes = (0..<3).map { _ in sim.node() }
        for spoke in spokes { sim.connect(spoke, hub) }

        sim.send(.command(.broadcast(topic: "gossip", payload: Data([1]))), to: hub)
        sim.run(for: .seconds(1))

        for spoke in spokes {
            XCTAssertEqual(spoke.received.map(\.message), [PeerMessage(topic: "gossip", payload: Data([1]))])
            XCTAssertEqual(spoke.received.first?.peer.id, hub.peer)
        }
        XCTAssertTrue(hub.received.isEmpty)
    }

    // "a blocked async delegate preserves a burst beyond the old inbound queue"
    func testAsyncDelegateBackpressure() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()
        sim.connect(client, server)
        server.holdsDeliveries = true

        let topics = (0..<12).map { "burst-\($0)" }
        let payload = Data(repeating: 0xAB, count: 4 * 1024)
        for topic in topics {
            XCTAssertEqual(
                sim.await(.send(to: server.peer, topic: topic, payload: payload), on: client)?.sent,
                .enqueued(endpoint: server.peer, route: .direct))
        }

        sim.run(for: .seconds(1))
        XCTAssertEqual(server.received.count, 1)
        XCTAssertEqual(server.core.peerConnectionCount, 1)
        XCTAssertEqual(client.core.peerConnectionCount, 1)

        sim.openDeliveries(server)
        sim.run(until: { server.received.count == topics.count })
        XCTAssertEqual(server.received.map(\.message.topic), topics)
    }

    func testSendResults() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()
        func send(_ payload: Data = Data()) -> SendMessageResult? {
            sim.await(.send(to: server.peer, topic: "t", payload: payload), on: client)?.sent
        }

        XCTAssertEqual(send(), .notConnected)
        XCTAssertEqual(sim.await(.waitUntilWritable(server.peer), on: client), .writable(false))

        sim.connect(client, server)
        let current = sim.session(client, to: server)
        XCTAssertEqual(send(), .enqueued(endpoint: server.peer, route: .direct))
        XCTAssertEqual(
            send(Data(count: Int(IvyConfig.defaultProtocolMaxFrameSize) + 1)), .locallyRejected)
        XCTAssertEqual(sim.await(.waitUntilWritable(server.peer), on: client), .writable(true))
        XCTAssertEqual(
            sim.await(.sendOnSession(current, topic: "exact", payload: Data()), on: client)?.sent,
            .enqueued(endpoint: server.peer, route: .direct))
        XCTAssertEqual(sim.await(.waitUntilSessionWritable(current), on: client), .writable(true))

        // A handle to a session that is not the current one sends nothing.
        let stale = AuthenticatedPeer(
            key: current.key,
            role: current.role,
            route: current.route,
            metadata: current.metadata,
            sessionID: Data(repeating: 9, count: 32))
        XCTAssertEqual(
            sim.await(.sendOnSession(stale, topic: "stale", payload: Data()), on: client)?.sent,
            .notConnected)
        XCTAssertEqual(sim.await(.waitUntilSessionWritable(stale), on: client), .writable(false))

        sim.run(for: .seconds(1))
        XCTAssertEqual(server.received.map(\.message.topic), ["t", "exact"])

        sim.send(.command(.disconnect(server.peer)), to: client)
        XCTAssertEqual(send(), .notConnected)
        XCTAssertEqual(
            sim.await(.sendOnSession(current, topic: "gone", payload: Data()), on: client)?.sent,
            .notConnected)
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.received.count, 2)
    }

    // "Private network carries direct messages and content without overlay traffic"
    func testPrivateNetworkTrafficIsolation() {
        let sim = Simulation()
        let server = sim.node(
            mode: .privateNetwork, maxConnectionsPerNetgroup: 4, privateContentExchangeEnabled: true)
        let client = sim.node(mode: .privateNetwork, privateContentExchangeEnabled: true)
        server.content = ["private-root": Data("root bytes".utf8), "private-child": Data("child bytes".utf8)]
        sim.connect(client, server)

        XCTAssertTrue(server.core.knownPeerEndpoints.isEmpty)
        XCTAssertTrue(client.core.knownPeerEndpoints.isEmpty)
        XCTAssertEqual(sim.await(.findNode(target: "private-root"), on: client), .endpoints([]))
        XCTAssertEqual(sim.await(.discoverProviders(rootCID: "private-root"), on: client), .endpoints([]))

        sim.run(for: .seconds(1))
        let writesBefore = sim.writeCount(by: client)
        sim.send(.command(.broadcast(topic: "not-private", payload: Data("broadcast".utf8))), to: client)
        sim.send(.command(.announceProvider(
            rootCID: "private-root", expiresAt: sim.unixSeconds + 60)), to: client)
        sim.run(for: .seconds(1))
        XCTAssertEqual(sim.writeCount(by: client), writesBefore)
        XCTAssertTrue(server.received.isEmpty)

        let fetched = sim.await(.fetchContentFrom(
            sim.session(client, to: server), rootCID: "private-root", cids: ["private-child"]), on: client)
        XCTAssertEqual(fetched?.content?.entries, server.content)

        // Overlay requests from a peer are dropped unanswered.
        let peer = HandPeer(sim, to: server, index: 1, host: "10.1.0.1")
        XCTAssertTrue(peer.authenticate())
        sim.run(for: .seconds(1))
        _ = peer.takeRecords()
        peer.send(Message.findNode(target: Data(repeating: 0xAA, count: 32), nonce: 1))
        peer.send(Message.announceProvider(rootCID: "private-root", expiresAt: sim.unixSeconds + 60))
        sim.run(for: .seconds(1))
        XCTAssertTrue(peer.takeRecords().isEmpty)
        XCTAssertTrue(server.core.providerHints.isEmpty)
        XCTAssertTrue(peer.isAuthenticated)

        let payload = Data("hierarchy fact".utf8)
        XCTAssertEqual(
            sim.await(.send(to: server.peer, topic: "hierarchy.fact", payload: payload), on: client)?.sent,
            .enqueued(endpoint: server.peer, route: .direct))
        sim.run(until: { !server.received.isEmpty })
        XCTAssertEqual(server.received.first?.message, PeerMessage(topic: "hierarchy.fact", payload: payload))
        XCTAssertEqual(server.received.first?.peer, server.connected.first)
    }

    // MARK: - Sequence and replay

    private func authenticatedPeer(_ sim: Simulation, _ node: Simulation.Node) -> HandPeer {
        let peer = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        XCTAssertTrue(peer.authenticate())
        return peer
    }

    private func assertSessionEnded(
        _ peer: HandPeer,
        at node: Simulation.Node,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(peer.isClosed, file: file, line: line)
        XCTAssertEqual(node.core.peerConnectionCount, 0, file: file, line: line)
        XCTAssertEqual(node.disconnected, [peer.id], file: file, line: line)
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0, file: file, line: line)
    }

    func testReplayedRecordEndsTheSession() {
        let sim = Simulation()
        let node = sim.node()
        let peer = authenticatedPeer(sim, node)
        let record = peer.record(.peerMessage(topic: "once", payload: Data([1])))

        peer.writeFrames([record])
        sim.run(for: .seconds(1))
        XCTAssertEqual(node.received.map(\.message.topic), ["once"])
        XCTAssertFalse(peer.isClosed)

        peer.writeFrames([record])
        sim.run(for: .seconds(1))
        XCTAssertEqual(node.received.map(\.message.topic), ["once"])
        assertSessionEnded(peer, at: node)
    }

    func testSequenceBelowTheLastReceivedEndsTheSession() {
        let sim = Simulation()
        let node = sim.node()
        let peer = authenticatedPeer(sim, node)

        peer.sendMessage("five", sequence: 5)
        sim.run(for: .seconds(1))
        peer.sendMessage("three", sequence: 3)
        sim.run(for: .seconds(1))

        XCTAssertEqual(node.received.map(\.message.topic), ["five"])
        assertSessionEnded(peer, at: node)
    }

    func testIncreasingSequencesWithGapsAreAccepted() {
        let sim = Simulation()
        let node = sim.node()
        let peer = authenticatedPeer(sim, node)

        for sequence in [1, 2, 7, 1_000, UInt64.max - 1, UInt64.max] {
            peer.sendMessage("s\(sequence)", sequence: sequence)
            sim.run(for: .milliseconds(10))
        }

        XCTAssertEqual(node.received.count, 6)
        XCTAssertFalse(peer.isClosed)
        XCTAssertTrue(node.disconnected.isEmpty)
    }

    func testRecordForAnotherSessionEndsTheSession() {
        let sim = Simulation()
        let node = sim.node()
        let peer = authenticatedPeer(sim, node)

        peer.writeFrames([peer.record(
            .peerMessage(topic: "elsewhere", payload: Data()),
            sessionID: try! SessionID(bytes: Data(repeating: 3, count: 32)))])
        sim.run(for: .seconds(1))

        XCTAssertTrue(node.received.isEmpty)
        assertSessionEnded(peer, at: node)
    }

    func testRecordWithABadSignatureEndsTheSession() {
        let sim = Simulation()
        let node = sim.node()
        let peer = authenticatedPeer(sim, node)
        var record = peer.record(.peerMessage(topic: "forged", payload: Data()))
        record[record.count - 1] ^= 0x01

        peer.writeFrames([record])
        sim.run(for: .seconds(1))

        XCTAssertTrue(node.received.isEmpty)
        assertSessionEnded(peer, at: node)
        // A bad signature proves nothing about who sent it.
        XCTAssertEqual(node.ledger.violations(of: peer.id), 0)
    }

    func testHandshakeRecordOnAnAuthenticatedSessionEndsIt() {
        let sim = Simulation()
        let node = sim.node()
        let peer = authenticatedPeer(sim, node)

        peer.sendHello(nonce: 2)
        sim.run(for: .seconds(1))

        assertSessionEnded(peer, at: node)
    }

    func testRecordsFromEachSideCarryConsecutiveSequences() {
        let sim = Simulation()
        let node = sim.node()
        let peer = authenticatedPeer(sim, node)
        sim.run(for: .seconds(1))
        _ = peer.takeRecords()

        for index in 0..<5 {
            XCTAssertEqual(
                sim.await(.send(to: peer.id, topic: "m\(index)", payload: Data()), on: node)?.sent,
                .enqueued(endpoint: peer.id, route: .direct))
        }

        let records = peer.takeDataRecords()
        XCTAssertEqual(records.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertTrue(records.allSatisfy { $0.sessionID == peer.sessionID })
        XCTAssertTrue(records.allSatisfy {
            $0.isValid(sender: node.key, receiver: peer.key, using: SimulatedSignatureScheme(key: peer.key))
        })
    }

    // MARK: - Duplicate and simultaneous sessions

    // "simultaneous cross-dial converges to one usable session"
    func testDuplicateSessionConvergence() {
        for seed in UInt64(1)...8 {
            let sim = Simulation(seed: seed)
            let left = sim.node()
            let right = sim.node()

            let leftDial = sim.request(.connect(right.endpoint), on: left)
            let rightDial = sim.request(.connect(left.endpoint), on: right)
            sim.run(until: {
                sim.result(of: leftDial, on: left) != nil && sim.result(of: rightDial, on: right) != nil
            })
            XCTAssertEqual(sim.result(of: leftDial, on: left), .connect(.connected), "seed \(seed)")
            XCTAssertEqual(sim.result(of: rightDial, on: right), .connect(.connected), "seed \(seed)")

            sim.run(for: .seconds(1))
            XCTAssertEqual(left.core.peerConnectionCount, 1, "seed \(seed)")
            XCTAssertEqual(right.core.peerConnectionCount, 1, "seed \(seed)")
            XCTAssertNotNil(sessionID(left, for: right.peer), "seed \(seed)")
            XCTAssertEqual(
                sessionID(left, for: right.peer), sessionID(right, for: left.peer), "seed \(seed)")
            XCTAssertEqual(left.core.diagnostics.pendingSessions, 0, "seed \(seed)")
            XCTAssertEqual(right.core.diagnostics.pendingSessions, 0, "seed \(seed)")
            XCTAssertEqual(left.core.diagnostics.outgoingDials, 0, "seed \(seed)")
            XCTAssertEqual(right.core.diagnostics.outgoingDials, 0, "seed \(seed)")
            XCTAssertTrue(left.disconnected.isEmpty, "seed \(seed)")
            XCTAssertTrue(right.disconnected.isEmpty, "seed \(seed)")
            // One of the two transports is gone on each side.
            XCTAssertEqual(left.core.links.count, 1, "seed \(seed)")
            XCTAssertEqual(right.core.links.count, 1, "seed \(seed)")

            let sent = sim.await(
                .send(to: right.peer, topic: "cross-dial", payload: Data("still live".utf8)), on: left)
            XCTAssertEqual(sent?.sent, .enqueued(endpoint: right.peer, route: .direct), "seed \(seed)")
            sim.run(until: { !right.received.isEmpty })
            XCTAssertEqual(
                right.received.first?.message,
                PeerMessage(topic: "cross-dial", payload: Data("still live".utf8)),
                "seed \(seed)")
            XCTAssertEqual(right.received.first?.peer.id, left.peer, "seed \(seed)")
        }
    }

    func testDuplicateSessionsConvergeOnTheSmallerSessionID() throws {
        var keptFirst = 0
        var replaced = 0
        for nonce in UInt8(1)...12 {
            let sim = Simulation()
            let node = sim.node(maxConnectionsPerNetgroup: 4)
            let first = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
            let second = HandPeer(sim, to: node, index: 1, host: "10.2.0.1")
            XCTAssertTrue(first.authenticate(nonce: nonce))
            second.authenticate(nonce: nonce &+ 100)
            sim.run(for: .seconds(1))

            let firstID = try XCTUnwrap(first.sessionID)
            let secondID = try XCTUnwrap(second.sessionID)
            let smaller = min(firstID, secondID)
            let (winner, loser) = smaller == firstID ? (first, second) : (second, first)
            if winner === first { keptFirst += 1 } else { replaced += 1 }

            XCTAssertEqual(sessionID(node, for: first.id), smaller.bytes, "nonce \(nonce)")
            XCTAssertTrue(winner.isAuthenticated, "nonce \(nonce)")
            XCTAssertFalse(winner.isClosed, "nonce \(nonce)")
            XCTAssertTrue(loser.isClosed, "nonce \(nonce)")
            XCTAssertEqual(node.core.peerConnectionCount, 1, "nonce \(nonce)")
            XCTAssertEqual(node.core.links.count, 1, "nonce \(nonce)")
            XCTAssertEqual(node.core.diagnostics.pendingSessions, 0, "nonce \(nonce)")
            // The peer stayed connected throughout: no disconnect is reported.
            XCTAssertTrue(node.disconnected.isEmpty, "nonce \(nonce)")

            // The surviving session still carries records; the other cannot.
            winner.sendMessage("survivor")
            sim.run(for: .seconds(1))
            XCTAssertEqual(node.received.map(\.message.topic), ["survivor"], "nonce \(nonce)")
            XCTAssertEqual(node.received.first?.peer.sessionID, smaller.bytes, "nonce \(nonce)")
        }
        XCTAssertGreaterThan(keptFirst, 0, "no run kept the first session")
        XCTAssertGreaterThan(replaced, 0, "no run replaced the first session")
    }

    // MARK: - Disconnect and exact-session control

    // "exact-session recovery is configured, suppressible, and stale-safe"
    func testExactSessionRecoveryIsConfiguredAndStaleSafe() throws {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node(bootstrap: [server.endpoint])
        sim.run(until: { client.core.peerConnectionCount == 1 && !client.connected.isEmpty })
        let initial = try XCTUnwrap(client.connected.last)

        XCTAssertEqual(sim.await(.recycleSession(initial), on: client), .flag(true))
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertTrue(sim.run(until: {
            let current = self.sessionID(client, for: server.peer)
            return client.core.peerConnectionCount == 1
                && current != nil
                && current != initial.sessionID
                && client.connected.count >= 2
        }))
        let replacement = sessionID(client, for: server.peer)
        XCTAssertEqual(client.disconnected, [server.peer])

        XCTAssertEqual(sim.await(.recycleSession(initial), on: client), .flag(false))
        XCTAssertEqual(sessionID(client, for: server.peer), replacement)
        XCTAssertEqual(sim.await(.disconnectSession(initial), on: client), .flag(false))
        XCTAssertEqual(sessionID(client, for: server.peer), replacement)
        XCTAssertFalse(client.core.reconnectSuppressed.contains(server.peer))

        let replacementPeer = try XCTUnwrap(client.connected.last)
        XCTAssertEqual(replacementPeer.sessionID, replacement)
        XCTAssertEqual(sim.await(.disconnectSession(replacementPeer), on: client), .flag(true))
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        let dials = sim.dials(from: client).count
        sim.run(for: .seconds(120))
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertEqual(sim.dials(from: client).count, dials)
        XCTAssertEqual(server.core.peerConnectionCount, 0)
    }

    // "exact-session recycle closes an unconfigured peer"
    func testExactSessionRecycleClosesUnconfiguredPeer() throws {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()
        sim.connect(client, server)
        let inbound = try XCTUnwrap(server.connected.first)

        XCTAssertEqual(sim.await(.recycleSession(inbound), on: server), .flag(true))

        XCTAssertEqual(server.core.peerConnectionCount, 0)
        XCTAssertEqual(server.disconnected, [client.peer])
        sim.run(for: .seconds(60))
        XCTAssertEqual(server.core.peerConnectionCount, 0)
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertEqual(client.disconnected, [server.peer])
        XCTAssertTrue(sim.dials(from: server).isEmpty)
    }

    func testDisconnectEndsTheSessionAndSuppressesReconnect() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node(bootstrap: [server.endpoint])
        sim.run(until: { client.core.peerConnectionCount == 1 && server.core.peerConnectionCount == 1 })

        sim.send(.command(.disconnect(server.peer)), to: client)
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertEqual(client.disconnected, [server.peer])
        XCTAssertEqual(sim.closes(by: client).count, 1)

        let dials = sim.dials(from: client).count
        sim.run(for: .seconds(120))
        XCTAssertEqual(server.disconnected, [client.peer])
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertEqual(sim.dials(from: client).count, dials)
        XCTAssertEqual(client.disconnected, [server.peer])

        // Asking for the peer again lifts the suppression.
        XCTAssertEqual(sim.await(.connect(server.endpoint), on: client), .connect(.connected))
        XCTAssertEqual(client.core.peerConnectionCount, 1)
    }

    func testRestartConfiguredSessionReplacesOnlyAConfiguredPeer() throws {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node(bootstrap: [server.endpoint])
        sim.run(until: { client.core.peerConnectionCount == 1 && server.core.peerConnectionCount == 1 })
        let initial = try XCTUnwrap(sessionID(client, for: server.peer))

        // The server did not configure the client: nothing happens.
        sim.send(.command(.restartConfiguredSession(client.peer)), to: server)
        XCTAssertEqual(server.core.peerConnectionCount, 1)
        XCTAssertTrue(server.disconnected.isEmpty)

        sim.send(.command(.restartConfiguredSession(server.peer)), to: client)
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertEqual(client.disconnected, [server.peer])
        XCTAssertTrue(sim.run(until: {
            client.core.peerConnectionCount == 1 && client.connected.count == 2
        }, timeout: .seconds(10)))
        XCTAssertNotEqual(sessionID(client, for: server.peer), initial)
    }

    func testRemoteCloseReportsOneDisconnect() {
        let sim = Simulation()
        let node = sim.node()
        let peer = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        XCTAssertTrue(peer.authenticate())

        peer.close()

        XCTAssertEqual(node.disconnected, [peer.id])
        XCTAssertEqual(node.core.peerConnectionCount, 0)
        XCTAssertTrue(node.core.links.isEmpty)
        // The shell reported the close; the core does not ask for it again.
        XCTAssertFalse(sim.closes(by: node).contains(peer.connection))
        XCTAssertEqual(sim.await(.send(to: peer.id, topic: "t", payload: Data()), on: node)?.sent, .notConnected)
    }

    // MARK: - Reconnecting configured peers

    // "configured peers retry after an initial startup failure"
    func testStartupRetry() {
        let sim = Simulation()
        let server = sim.node(start: false)
        let client = sim.node(
            bootstrap: [server.endpoint], mode: .pinned(peer: server.key.hex))

        sim.run(for: .milliseconds(100))
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        sim.start(server)

        XCTAssertTrue(sim.run(until: { client.core.peerConnectionCount == 1 }, timeout: .seconds(10)))
        XCTAssertNil(client.core.reconnectScheduled[server.peer])
        XCTAssertNil(client.core.reconnectAttempts[server.peer])
    }

    // "configured identities fail over across all declared routes"
    func testConfiguredRouteFailover() {
        let sim = Simulation()
        let server = sim.node()
        let dead = PeerEndpoint(publicKey: server.key.hex, host: "8.200.0.1", port: 4001)
        let client = sim.node(
            bootstrap: [dead, server.endpoint], mode: .pinned(peer: server.key.hex))

        XCTAssertTrue(sim.run(until: { client.connected.count == 1 }, timeout: .seconds(10)))
        XCTAssertEqual(sim.dials(from: client).map(\.endpoint.host), [dead.host, server.host])

        sim.stop(server)
        XCTAssertTrue(sim.run(until: { client.disconnected == [server.peer] }, timeout: .seconds(1)))
        sim.start(server)

        XCTAssertTrue(sim.run(until: { client.connected.count == 2 }, timeout: .seconds(10)))
        XCTAssertEqual(client.core.peerConnectionCount, 1)
        XCTAssertEqual(
            sim.dials(from: client).map(\.endpoint.host),
            [dead.host, server.host, dead.host, server.host])
    }

    // "an established configured peer reconnects after transport loss"
    func testEstablishedReconnect() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node(
            bootstrap: [server.endpoint], mode: .pinned(peer: server.key.hex))
        XCTAssertTrue(sim.run(
            until: { client.connected.count == 1 && server.connected.count == 1 }, timeout: .seconds(10)))

        sim.stop(server)
        XCTAssertTrue(sim.run(until: { client.disconnected == [server.peer] }, timeout: .seconds(1)))
        // The server asked to stop: its application hears no disconnect.
        XCTAssertTrue(server.disconnected.isEmpty)
        sim.start(server)

        XCTAssertTrue(sim.run(
            until: { client.connected.count == 2 && server.connected.count == 2 }, timeout: .seconds(10)))
        XCTAssertEqual(client.core.peerConnectionCount, 1)
        XCTAssertEqual(server.core.peerConnectionCount, 1)
        XCTAssertNotEqual(client.connected[0].sessionID, client.connected[1].sessionID)
    }

    // "a pinned reconnect cannot substitute another endpoint identity"
    func testPinnedReconnectRejectsSubstituteIdentity() {
        let sim = Simulation()
        let substitute = sim.node(host: "8.50.0.1")
        let expected = HandPeer.endpoint(sim, index: 1, host: "8.50.0.1")
        let client = sim.node(bootstrap: [expected], mode: .pinned(peer: expected.publicKey))

        sim.run(for: .seconds(10))

        // Every reconnect reaches the substitute and none is accepted.
        XCTAssertGreaterThanOrEqual(sim.dials(from: client).count, 3)
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertEqual(substitute.core.peerConnectionCount, 0)
        XCTAssertTrue(client.connected.isEmpty)
        XCTAssertTrue(substitute.connected.isEmpty)
        XCTAssertEqual(substitute.core.diagnostics.pendingSessions, 0)
    }

    func testReconnectBacksOffExponentiallyWithSeededJitter() {
        let sim = Simulation(seed: 7)
        let ghost = HandPeer.endpoint(sim, index: 1, host: "10.1.0.1")
        // Pinned, so nothing but the reconnect jitter draws from the generator.
        let node = sim.node(bootstrap: [ghost], mode: .pinned(peer: ghost.publicKey))
        sim.run(for: .seconds(180))

        // The node is the simulation's first, so its generator is seeded so.
        var random = CoreRandom.seeded(sim.seed &* 0x9E37_79B9_7F4A_7C15 &+ 0)
        let bases: [Int64] = [500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000]
        var expected: [Duration] = [.zero]
        for base in bases {
            let jitter = Int64(UInt64.random(in: 0...250, using: &random))
            // A dial fails one latency after it is asked for; the next
            // follows the failure by the backoff.
            expected.append(expected.last! + sim.latency + .milliseconds(base + jitter))
        }

        let times = sim.dials(from: node).map(\.time)
        XCTAssertGreaterThanOrEqual(times.count, expected.count)
        XCTAssertEqual(Array(times.prefix(expected.count)), expected)
        for (index, base) in bases.enumerated() where index + 1 < times.count {
            let delay = times[index + 1] - times[index] - sim.latency
            XCTAssertGreaterThanOrEqual(delay, .milliseconds(base))
            XCTAssertLessThanOrEqual(delay, .milliseconds(base + 250))
        }
    }

    func testReconnectScheduleRepeatsForASeedAndDiffersAcrossSeeds() {
        func dialTimes(seed: UInt64) -> ([Duration], String) {
            let sim = Simulation(seed: seed)
            let node = sim.node(bootstrap: [HandPeer.endpoint(sim, index: 1, host: "10.1.0.1")])
            sim.run(for: .seconds(60))
            return (sim.dials(from: node).map(\.time), sim.traceDigest)
        }

        let first = dialTimes(seed: 3)
        let again = dialTimes(seed: 3)
        let other = dialTimes(seed: 4)

        XCTAssertEqual(first.0, again.0)
        XCTAssertEqual(first.1, again.1)
        XCTAssertNotEqual(first.0, other.0)
    }

    func testSuccessfulConnectionResetsTheBackoff() {
        let sim = Simulation()
        let server = sim.node(start: false)
        let client = sim.node(bootstrap: [server.endpoint])
        sim.run(for: .seconds(20))
        XCTAssertGreaterThanOrEqual(client.core.reconnectAttempts[server.peer] ?? 0, 5)

        sim.start(server)
        XCTAssertTrue(sim.run(until: { client.core.peerConnectionCount == 1 }, timeout: .seconds(60)))
        XCTAssertNil(client.core.reconnectAttempts[server.peer])

        // The next loss starts again from half a second.
        sim.stop(server)
        sim.run(until: { client.disconnected == [server.peer] })
        let lost = sim.now
        let dials = sim.dials(from: client).count
        sim.run(until: { sim.dials(from: client).count > dials })
        let delay = sim.now - lost
        XCTAssertGreaterThanOrEqual(delay, .milliseconds(500))
        XCTAssertLessThanOrEqual(delay, .milliseconds(750))
    }

    // MARK: - Connect operations that end early

    // "a transport closed during promotion cannot make connect succeed"
    func testClosedPromotionFailsAuthentication() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()
        client.holdsDeliveries = true

        let request = sim.request(.connect(server.endpoint), on: client)
        sim.run(until: { !client.heldDeliveries.isEmpty })
        // The application has not taken the session, so connect has not returned.
        XCTAssertNil(sim.result(of: request, on: client))
        sim.run(for: .milliseconds(50))
        XCTAssertNil(sim.result(of: request, on: client))

        // The transport goes away before it does.
        sim.send(.command(.disconnect(client.peer)), to: server)
        sim.run(for: .seconds(1))

        XCTAssertEqual(sim.result(of: request, on: client)?.isFailedConnect, true)
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertEqual(server.core.peerConnectionCount, 0)
        XCTAssertEqual(client.core.diagnostics.outgoingDials, 0)

        // The late acknowledgement belongs to a session that is gone.
        sim.openDeliveries(client)
        sim.run(for: .seconds(1))
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertEqual(sim.result(of: request, on: client)?.isFailedConnect, true)
    }

    // "cancelling authentication immediately releases its socket"
    func testAuthenticationCancellationReleasesCapacity() throws {
        let sim = Simulation()
        sim.latency = .milliseconds(100)
        let stalled = sim.node()
        let client = sim.node()

        let request = sim.request(.connect(stalled.endpoint), on: client)
        sim.run(until: { client.core.diagnostics.pendingSessions == 1 })
        XCTAssertEqual(client.core.diagnostics.outgoingDials, 1)
        let connection = try XCTUnwrap(sim.lastDialledConnections?.dialer)
        XCTAssertFalse(sim.closes(by: client).contains(connection))

        sim.cancel(request, on: client)

        XCTAssertEqual(sim.result(of: request, on: client), .connect(.cancelled))
        XCTAssertEqual(client.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(client.core.diagnostics.outgoingDials, 0)
        XCTAssertTrue(sim.closes(by: client).contains(connection))

        sim.run(for: .seconds(5))
        XCTAssertEqual(stalled.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(stalled.core.peerConnectionCount, 0)
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertTrue(client.connected.isEmpty)
        XCTAssertTrue(stalled.connected.isEmpty)
    }

    func testCancellingADialInFlightKeepsItsCapacityUntilTheShellAnswers() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()

        let request = sim.request(.connect(server.endpoint), on: client)
        sim.cancel(request, on: client)

        XCTAssertEqual(sim.result(of: request, on: client), .connect(.cancelled))
        XCTAssertEqual(client.core.diagnostics.outgoingDials, 1)

        sim.run(for: .seconds(1))
        XCTAssertEqual(client.core.diagnostics.outgoingDials, 0)
        XCTAssertEqual(client.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(sim.closes(by: client).count, 1)
        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertEqual(server.core.peerConnectionCount, 0)
    }

    // "configured maintenance survives a transport closing during promotion"
    func testClosedPromotionRearmsConfiguredReconnect() throws {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node(
            bootstrap: [server.endpoint], mode: .pinned(peer: server.key.hex), start: false)
        client.holdsDeliveries = true
        sim.start(client)
        sim.run(until: { !client.heldDeliveries.isEmpty })
        sim.run(until: { server.core.peerConnectionCount == 1 })

        let inbound = try XCTUnwrap(server.core.authenticatedPeer(for: client.peer))
        XCTAssertEqual(sim.await(.recycleSession(inbound), on: server), .flag(true))
        sim.run(for: .milliseconds(50))

        XCTAssertEqual(client.core.peerConnectionCount, 0)
        XCTAssertNotNil(client.core.reconnectScheduled[server.peer])

        sim.openDeliveries(client)
        XCTAssertTrue(sim.run(until: {
            client.core.peerConnectionCount == 1 && server.core.peerConnectionCount == 1
        }, timeout: .seconds(10)))
    }

    // MARK: - Stop and restart

    func testStopCompletesEveryRequestAndClosesEveryConnection() throws {
        let sim = Simulation()
        let node = sim.node(maxConnectionsPerNetgroup: 8)
        let remote = sim.node()
        sim.connect(node, remote)
        let raw = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        XCTAssertTrue(raw.authenticate())
        let pending = sim.openRawConnection(to: node, fromHost: "10.2.0.1")
        sim.run(for: .seconds(1))
        let remoteConnection = try XCTUnwrap(sim.lastDialledConnections?.dialer)

        // One of each kind of request still waiting.
        remote.stallsStorage = true
        let fetch = sim.request(.fetchContentFrom(
            sim.session(node, to: remote), rootCID: "root", cids: []), on: node)
        let dial = sim.request(
            .connect(HandPeer.endpoint(sim, index: 2, host: "10.3.0.1")), on: node)
        sim.setRawStalled(true, raw.connection, at: node)
        sim.saturate(node, toward: raw.id)
        let writable = sim.request(.waitUntilWritable(raw.id), on: node)
        XCTAssertNil(sim.result(of: fetch, on: node))
        XCTAssertNil(sim.result(of: dial, on: node))
        XCTAssertNil(sim.result(of: writable, on: node))
        let disconnectsBefore = node.disconnected

        sim.stop(node)

        XCTAssertEqual(sim.result(of: fetch, on: node)?.content, .empty)
        XCTAssertEqual(sim.result(of: dial, on: node), .connect(.cancelled))
        XCTAssertEqual(sim.result(of: writable, on: node), .writable(false))
        XCTAssertEqual(
            Set(sim.closes(by: node)), [remoteConnection, raw.connection, pending])
        XCTAssertEqual(node.disconnected, disconnectsBefore)
        XCTAssertTrue(node.disconnected.isEmpty)

        XCTAssertFalse(node.core.isRunning)
        XCTAssertTrue(node.core.connectedPeers.isEmpty)
        XCTAssertTrue(node.core.links.isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
        XCTAssertEqual(node.core.diagnostics.deadlines, 0)
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)

        // The other end is told, and nothing more comes out of the stopped node.
        let effects = sim.effects(of: node).count
        sim.run(for: .seconds(120))
        XCTAssertEqual(remote.disconnected, [node.peer])
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertEqual(sim.effects(of: node).count, effects)
        XCTAssertTrue(node.disconnected.isEmpty)
    }

    func testRequestsOnAStoppedNodeCompleteAtOnce() {
        let sim = Simulation()
        let node = sim.node()
        let remote = sim.node()
        sim.connect(node, remote)
        let session = sim.session(node, to: remote)
        sim.stop(node)

        XCTAssertEqual(sim.await(.send(to: remote.peer, topic: "t", payload: Data()), on: node)?.sent, .notConnected)
        XCTAssertEqual(sim.await(.sendOnSession(session, topic: "t", payload: Data()), on: node)?.sent, .notConnected)
        XCTAssertEqual(sim.await(.waitUntilWritable(remote.peer), on: node), .writable(false))
        XCTAssertEqual(sim.await(.recycleSession(session), on: node), .flag(false))
        XCTAssertEqual(sim.await(.disconnectSession(session), on: node), .flag(false))
        XCTAssertEqual(sim.await(.connect(remote.endpoint), on: node), .connect(.failed(.notRunning)))
    }

    func testRestartStartsFromNothing() throws {
        let sim = Simulation()
        let server = sim.node()
        let node = sim.node(bootstrap: [server.endpoint], maxConnectionsPerNetgroup: 8)
        sim.run(until: { node.core.peerConnectionCount == 1 && server.core.peerConnectionCount == 1 })
        let first = try XCTUnwrap(node.connected.last)
        let raw = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        XCTAssertTrue(raw.authenticate())
        let pending = sim.openRawConnection(to: node, fromHost: "10.2.0.1")
        node.holdsDeliveries = true
        raw.sendMessage("held")
        XCTAssertEqual(node.heldDeliveries.count, 1)

        sim.stop(node)
        sim.run(for: .seconds(1))
        node.holdsDeliveries = false
        sim.start(node)

        // The old run's acknowledgement, bytes and deadlines do nothing.
        sim.releaseDeliveries(node)
        raw.sendMessage("after-stop")
        sim.send(.received(raw.connection, HandPeer.framed([Data([1, 2, 3])])), to: node)
        sim.send(.closed(pending), to: node)
        XCTAssertEqual(node.core.connectedPeers, [])
        XCTAssertNil(node.core.authenticatedPeer(for: raw.id))
        XCTAssertEqual(sim.await(.recycleSession(first), on: node), .flag(false))

        // The configured peer is dialled afresh and gets a new session.
        XCTAssertTrue(sim.run(until: { node.connected.count == 3 }, timeout: .seconds(10)))
        XCTAssertEqual(node.connected.last?.id, server.peer)
        XCTAssertNotEqual(node.connected.last?.sessionID, first.sessionID)
        XCTAssertEqual(node.core.connectedPeers, [server.peer])

        sim.run(for: .seconds(60))
        XCTAssertEqual(node.core.connectedPeers, [server.peer])
        XCTAssertEqual(node.received.map(\.message.topic), ["held"])
        XCTAssertTrue(node.disconnected.isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0)
    }

    func testRestartForgetsTheBackoffAndDisconnectSuppression() {
        let sim = Simulation()
        let ghost = HandPeer.endpoint(sim, index: 1, host: "10.1.0.1")
        let peer = PeerID(publicKey: ghost.publicKey)
        let node = sim.node(bootstrap: [ghost])
        sim.run(for: .seconds(20))
        XCTAssertGreaterThanOrEqual(node.core.reconnectAttempts[peer] ?? 0, 5)
        sim.send(.command(.disconnect(peer)), to: node)
        XCTAssertTrue(node.core.reconnectSuppressed.contains(peer))
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)

        sim.stop(node)
        sim.run(for: .seconds(120))
        let dials = sim.dials(from: node).count
        sim.start(node)

        // Start dials the configured peer at once, then backs off from the base.
        XCTAssertEqual(sim.dials(from: node).count, dials + 1)
        let restarted = sim.now
        sim.run(until: { sim.dials(from: node).count == dials + 2 })
        let delay = sim.now - restarted - sim.latency
        XCTAssertGreaterThanOrEqual(delay, .milliseconds(500))
        XCTAssertLessThanOrEqual(delay, .milliseconds(750))
    }
}
