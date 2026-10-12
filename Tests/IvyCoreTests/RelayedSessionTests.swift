import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Endpoint sessions carried by a configured carrier: identity, routes,
/// messages, content, frame budgets, and how a connect falls back to them.
final class RelayedSessionTests: XCTestCase {
    private let smallFrame: UInt32 = 256 * 1024

    // MARK: - End to end

    /// Reference: "A configured carrier forwards peer messages and multi-frame Volumes".
    func testConfiguredCarrierForwardsPeerMessagesAndMultiFrameVolumes() {
        let sim = Simulation()
        let (c, a, b) = sim.relayTriangle(
            frame: smallFrame, targetConfiguresCarrier: false, pinSource: true,
            requestTimeout: .seconds(5))
        let volumeBytes = Data(repeating: 0xa5, count: Int(smallFrame) + 1)
        b.volumes["relay-root"] = [ContentEntry(cid: "relay-root", data: volumeBytes)]

        XCTAssertEqual(c.core.peerConnectionCount, 2)
        XCTAssertEqual(a.connected.first { $0.key == c.key }?.role, .carrier)
        XCTAssertEqual(b.connected.first { $0.key == c.key }?.role, .endpoint)
        XCTAssertEqual(a.core.peerConnectionCount, 0)

        let connected = sim.await(
            .connectViaRelay(PeerEndpoint(publicKey: b.key.hex, host: "relay", port: 0)), on: a)
        XCTAssertEqual(connected, .connect(.connected))

        let payload = Data("relayed node state".utf8)
        let sent = sim.await(.send(to: b.peer, topic: "node.state", payload: payload), on: a)?.sent
        guard case .enqueued(let endpoint, .relayed(let carrier, let routeID))? = sent else {
            return XCTFail("expected an enqueued relayed message, got \(String(describing: sent))")
        }
        XCTAssertEqual(endpoint, b.peer)
        XCTAssertEqual(carrier, c.key)

        sim.run(until: { !b.received.isEmpty })
        XCTAssertEqual(
            b.connected.first { $0.id == a.peer }?.route,
            .relayed(carrier: c.key, routeID: routeID))
        let delivery = b.received.first
        XCTAssertEqual(delivery?.message, PeerMessage(topic: "node.state", payload: payload))
        XCTAssertEqual(delivery?.peer.id, a.peer)
        XCTAssertEqual(delivery?.peer.role, .endpoint)
        XCTAssertEqual(delivery?.peer.route, .relayed(carrier: c.key, routeID: routeID))

        // Fits a direct frame, not one wrapped for the carrier.
        let tooLargeForRelay = Data(repeating: 0xaa, count: Int(smallFrame) - 180)
        XCTAssertEqual(
            sim.await(.send(to: b.peer, topic: "node.large", payload: tooLargeForRelay), on: a)?.sent,
            .locallyRejected)

        // The rejected message took no sequence number.
        let afterRejection = Data("still sequenced".utf8)
        let after = sim.await(
            .send(to: b.peer, topic: "node.after-rejection", payload: afterRejection), on: a)?.sent
        XCTAssertEqual(after, .enqueued(endpoint: b.peer, route: .relayed(carrier: c.key, routeID: routeID)))
        sim.run(until: { b.received.count == 2 })
        XCTAssertEqual(
            b.received.last?.message,
            PeerMessage(topic: "node.after-rejection", payload: afterRejection))
        XCTAssertEqual(b.received.last?.peer.id, a.peer)

        let volume = sim.await(
            .fetchVolumeFrom(
                sim.session(a, to: b), rootCID: "relay-root",
                maximumArchiveBytes: .max, maximumEntries: .max),
            on: a)?.volume
        XCTAssertEqual(volume, AttributedVolumeResponse(
            rootCID: "relay-root", entries: ["relay-root": volumeBytes], servedBy: b.peer))

        // The carrier never saw an application message.
        XCTAssertTrue(c.received.isEmpty)
        XCTAssertTrue(c.startedJobs.isEmpty)

        sim.stop(b)
        sim.run(for: .seconds(1))
        XCTAssertEqual(a.core.peerConnectionCount, 0)
    }

    func testRelayedSessionAuthenticatesBothIdentitiesAndBindsTheRoute() {
        let sim = Simulation()
        let (c, a, b) = sim.relayTriangle()
        guard let routeID = sim.connectRelayed(a, b) else { return }

        let ab = sim.session(a, to: b)
        let ba = sim.session(b, to: a)
        XCTAssertEqual(ab.key, b.key)
        XCTAssertEqual(ba.key, a.key)
        XCTAssertEqual(ab.role, .endpoint)
        XCTAssertEqual(ba.role, .endpoint)
        XCTAssertEqual(ab.route, .relayed(carrier: c.key, routeID: routeID))
        XCTAssertEqual(ba.route, .relayed(carrier: c.key, routeID: routeID))
        // One session, agreed by both ends over the carrier.
        XCTAssertEqual(ab.sessionID, ba.sessionID)
        XCTAssertEqual(a.connected.last, ab)
        XCTAssertEqual(b.connected.last, ba)

        XCTAssertEqual(routeID.count, 32)
        XCTAssertNotEqual(routeID, IvyCore.directRouteBinding)
        XCTAssertEqual(Array(c.core.relayRoutes.keys), [routeID])
        XCTAssertEqual(c.core.relayRoutes[routeID]?.source, a.key)
        XCTAssertEqual(c.core.relayRoutes[routeID]?.target, b.key)
        XCTAssertEqual(c.core.relayRoutes[routeID]?.ready, true)
        XCTAssertTrue(c.core.installedRoutes.isEmpty)
        for (node, remote) in [(a, b), (b, a)] {
            XCTAssertEqual(Array(node.core.installedRoutes.keys), [routeID])
            XCTAssertEqual(node.core.installedRoutes[routeID]?.carrier, c.key)
            XCTAssertEqual(node.core.installedRoutes[routeID]?.remote, remote.key)
            XCTAssertEqual(
                node.core.installedRoutes[routeID]?.link, node.core.sessions[remote.key]?.link)
            XCTAssertTrue(node.core.relayRoutes.isEmpty)
            XCTAssertTrue(node.core.pendingRelayOpens.isEmpty)
            XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        }

        // A session keeps its route past the deadline for an unused one.
        sim.run(for: .seconds(20))
        XCTAssertEqual(sim.session(a, to: b), ab)
        XCTAssertEqual(sim.session(b, to: a), ba)
        XCTAssertEqual(a.disconnected, [])
        XCTAssertEqual(b.disconnected, [])
    }

    func testMessagesFlowBothWaysOverARelayedSession() {
        let sim = Simulation()
        let (c, a, b) = sim.relayTriangle()
        guard let routeID = sim.connectRelayed(a, b) else { return }
        let route = AuthenticatedRoute.relayed(carrier: c.key, routeID: routeID)

        for index in 0..<5 {
            XCTAssertEqual(
                sim.await(.send(to: b.peer, topic: "ab", payload: Data([UInt8(index)])), on: a)?.sent,
                .enqueued(endpoint: b.peer, route: route))
            XCTAssertEqual(
                sim.await(.send(to: a.peer, topic: "ba", payload: Data([UInt8(index)])), on: b)?.sent,
                .enqueued(endpoint: a.peer, route: route))
        }
        sim.run(until: { a.received.count == 5 && b.received.count == 5 })
        XCTAssertEqual(b.received.map(\.message.payload), (0..<5).map { Data([UInt8($0)]) })
        XCTAssertEqual(a.received.map(\.message.payload), (0..<5).map { Data([UInt8($0)]) })
        XCTAssertTrue(b.received.allSatisfy { $0.peer.id == a.peer && $0.peer.route == route })
        XCTAssertTrue(a.received.allSatisfy { $0.peer.id == b.peer && $0.peer.route == route })
        XCTAssertTrue(c.received.isEmpty)

        // The exact-session forms name the relayed session too.
        XCTAssertEqual(
            sim.await(
                .sendOnSession(sim.session(a, to: b), topic: "exact", payload: Data([9])), on: a)?.sent,
            .enqueued(endpoint: b.peer, route: route))
        XCTAssertEqual(
            sim.await(.waitUntilSessionWritable(sim.session(a, to: b)), on: a), .writable(true))
        XCTAssertEqual(c.ledger.violations(of: a.peer) + c.ledger.violations(of: b.peer), 0)
    }

    func testVolumeFetchWorksOverRelayWithTheRelayedBudget() {
        let sim = Simulation()
        let (c, a, b) = sim.relayTriangle(frame: smallFrame)
        let entries = ["root": Data("r".utf8), "leaf": Data(repeating: 7, count: 100_000)]
        b.volumes["root"] = entries.map { ContentEntry(cid: $0.key, data: $0.value) }
        sim.connectRelayed(a, b)

        let response = sim.await(
            .fetchVolume(rootCID: "root", maximumArchiveBytes: .max, maximumEntries: .max), on: a)?.volume
        XCTAssertEqual(response?.entries, entries)
        XCTAssertEqual(response?.servedBy, b.peer)

        let exact = sim.await(
            .fetchVolumeFrom(
                sim.session(a, to: b), rootCID: "root", maximumArchiveBytes: .max, maximumEntries: .max),
            on: a)?.volume
        XCTAssertEqual(exact?.entries, entries)
        XCTAssertEqual(exact?.servedBy, b.peer)

        // A chunk is sized for a frame that must also fit the carrier's
        // envelope and record.
        let relayed = Message.volumeChunkDataBudget(rootCID: "root", maxFrameSize: smallFrame, relayed: true)
        let direct = Message.volumeChunkDataBudget(rootCID: "root", maxFrameSize: smallFrame, relayed: false)
        XCTAssertEqual(b.startedJobs.filter {
            if case .readVolume = $0.job { return true }
            return false
        }.count, 2)
        XCTAssertEqual(
            relayed.map { $0 + Message.relayPacketEnvelopeOverhead + SessionWireRecord.dataRecordOverhead },
            direct)
        XCTAssertTrue(c.startedJobs.isEmpty)
        XCTAssertTrue(a.core.volumeFetches.isEmpty)
        XCTAssertEqual(b.core.diagnostics.servingSlotsHeld, 0)
    }

    func testVolumeFetchSpansManyChunksOverRelay() {
        let sim = Simulation()
        let (c, a, b) = sim.relayTriangle(frame: smallFrame)
        let entries = volumeEntries(root: "vol", members: 20, bytesEach: 50_000)
        b.volumes["vol"] = entries
        sim.connectRelayed(a, b)

        let response = sim.await(
            .fetchVolume(rootCID: "vol", maximumArchiveBytes: .max, maximumEntries: .max), on: a)?.volume
        XCTAssertEqual(response?.entries.count, entries.count)
        XCTAssertEqual(response?.entries["vol-7"], entries[8].data)
        XCTAssertEqual(response?.servedBy, b.peer)
        sim.run(for: .seconds(1))
        XCTAssertEqual(a.core.diagnostics.inFlightVolumeBytes, 0)
        XCTAssertEqual(a.core.diagnostics.reservedVolumeBytes, 0)
        XCTAssertEqual(a.core.diagnostics.inboundBytesUsed, 0)
        XCTAssertEqual(b.core.diagnostics.reservedServingVolumeBytes, 0)
        XCTAssertEqual(c.core.diagnostics.inboundBytesUsed, 0)
        XCTAssertEqual(c.core.relayRoutes.count, 1)
    }

    // MARK: - Frame budgets

    /// Reference: "relayed outbound frame is capped by the carrier's advertised limit".
    func testRelayedFrameCappedByCarrier() {
        let sim = Simulation()
        let large: UInt32 = 512 * 1024
        // `a` sees the carrier in the carrier role, `b` as an ordinary peer.
        let (c, a, b) = sim.relayTriangle(
            frame: large, carrierFrame: smallFrame, targetConfiguresCarrier: false)
        sim.connectRelayed(a, b)

        for (node, remote) in [(a, b), (b, a)] {
            guard let link = node.core.sessions[remote.key]?.link else { return XCTFail("no session") }
            XCTAssertEqual(node.core.links[link]?.peerMaxFrameSize, large)
            XCTAssertEqual(node.core.effectiveOutboundFrameSize(for: link), smallFrame)
        }
        XCTAssertEqual(a.core.sessions[c.key]?.role, .carrier)
        XCTAssertEqual(b.core.sessions[c.key]?.role, .endpoint)

        // The endpoint accepts this; the carrier connection could not carry it.
        XCTAssertEqual(
            sim.await(
                .send(to: b.peer, topic: "big", payload: Data(repeating: 1, count: 300 * 1024)),
                on: a)?.sent,
            .locallyRejected)
        let fits = Data(repeating: 2, count: 200 * 1024)
        guard case .enqueued? = sim.await(.send(to: b.peer, topic: "fits", payload: fits), on: a)?.sent else {
            return XCTFail("a message within the carrier's frame was not sent")
        }
        sim.run(until: { !b.received.isEmpty })
        XCTAssertEqual(b.received.first?.message, PeerMessage(topic: "fits", payload: fits))
    }

    func testRelayedFrameBudgetIsTheDirectBudgetLessTheRelayOverhead() {
        let sim = Simulation()
        let (_, a, b) = sim.relayTriangle(frame: smallFrame)
        sim.connectRelayed(a, b)

        // tag + topic + payload length, then the endpoint's record, the
        // carrier's envelope and the carrier's record.
        let topic = "t"
        let messageOverhead = 1 + 2 + topic.utf8.count + 4
        let largest = Int(smallFrame)
            - 2 * SessionWireRecord.dataRecordOverhead
            - Message.relayPacketEnvelopeOverhead
            - messageOverhead
        XCTAssertEqual(
            Message.peerMessage(topic: topic, payload: Data(count: largest)).serialize().count,
            largest + messageOverhead)

        XCTAssertEqual(
            sim.sendWhenWritable(
                from: a, to: b.peer, topic: topic, payload: Data(repeating: 3, count: largest + 1)),
            .locallyRejected)
        guard case .enqueued? = sim.sendWhenWritable(
            from: a, to: b.peer, topic: topic, payload: Data(repeating: 4, count: largest)) else {
            return XCTFail("the largest relayed message was not sent")
        }
        sim.run(until: { !b.received.isEmpty })
        XCTAssertEqual(b.received.first?.message.payload.count, largest)
        XCTAssertNotNil(a.core.authenticatedPeer(for: b.peer))
    }

    // MARK: - Carriers are not endpoints

    func testCarriersNeverEnterEndpointRouting() {
        let sim = Simulation()
        let (c, a, b) = sim.relayTriangle()
        c.volumes["root"] = [ContentEntry(cid: "root", data: Data("held by the carrier".utf8))]

        // Attached to a carrier and nothing else: no endpoint peer at all.
        XCTAssertEqual(a.core.sessions[c.key]?.role, .carrier)
        XCTAssertEqual(a.connected.map(\.role), [.carrier])
        XCTAssertEqual(a.core.connectedPeers, [])
        XCTAssertEqual(a.core.connectedPeerEndpoints, [])
        XCTAssertEqual(a.core.peerConnectionCount, 0)
        XCTAssertFalse(a.core.knownPeerEndpoints.contains { $0.publicKey == c.key.hex })
        XCTAssertNil(a.core.endpointSession(for: c.key))

        XCTAssertEqual(
            sim.await(.send(to: c.peer, topic: "t", payload: Data([1])), on: a)?.sent, .notConnected)
        XCTAssertEqual(sim.await(.waitUntilWritable(c.peer), on: a), .writable(false))
        XCTAssertEqual(sim.await(.findNode(target: c.key.hex), on: a)?.endpoints, [])
        XCTAssertEqual(
            sim.await(
                .fetchVolume(rootCID: "root", maximumArchiveBytes: .max, maximumEntries: .max), on: a)?.volume,
            .empty)
        XCTAssertTrue(c.startedJobs.isEmpty)

        sim.connectRelayed(a, b)
        XCTAssertEqual(a.core.connectedPeers, [b.peer])
        sim.send(.command(.broadcast(topic: "all", payload: Data([2]))), to: a)
        sim.run(until: { !b.received.isEmpty })
        sim.run(for: .seconds(1))
        XCTAssertEqual(b.received.map(\.message.topic), ["all"])
        XCTAssertTrue(c.received.isEmpty)
        XCTAssertFalse(a.core.knownPeerEndpoints.contains { $0.publicKey == c.key.hex })
        // Nobody misbehaved on the way.
        XCTAssertEqual(c.ledger.violations(of: a.peer), 0)
        XCTAssertEqual(a.ledger.violations(of: c.peer), 0)
        XCTAssertNotNil(a.core.sessions[c.key])
    }

    func testCarrierSessionCarriesOnlyKeepaliveAndRelayControl() {
        let forbidden: [Message] = [
            .peerMessage(topic: "t", payload: Data([1])),
            .findNode(target: Data(repeating: 1, count: 32), nonce: 3),
            .volumeRequest(requestID: 1, rootCID: "root"),
            .volumeBundleRequest(requestID: 1, rootCID: "root"),
            .announceProvider(rootCID: "root", expiresAt: 2_000_000_000),
        ]
        for message in forbidden {
            let sim = Simulation()
            let carrier = sim.relayIdentity(1)
            let node = sim.relayNode(carriers: [carrier.endpoint])
            sim.run(for: .milliseconds(50))
            let raw = RawRelayPeer(sim, to: node, as: carrier)
            XCTAssertEqual(node.core.sessions[carrier.key]?.role, .carrier)

            raw.send(.ping(nonce: 42))
            XCTAssertEqual(raw.take { $0.pongNonce }, [42])
            raw.send(.pong(nonce: 1))
            // Relay control it may send: an unsolicited reply for no route.
            raw.send(.relayReady(routeID: relayRouteID(1), status: 0))
            raw.send(.relayClose(routeID: relayRouteID(2)))
            sim.run(for: .zero)
            XCTAssertTrue(raw.isConnected)
            XCTAssertEqual(node.ledger.violations(of: carrier.peer), 0)

            raw.send(message)
            sim.run(for: .zero)
            XCTAssertFalse(raw.isConnected, "\(message)")
            XCTAssertTrue(raw.nodeClosedConnection, "\(message)")
            XCTAssertEqual(node.ledger.violations(of: carrier.peer), 1, "\(message)")
            XCTAssertEqual(node.disconnected, [carrier.peer])
            XCTAssertTrue(node.received.isEmpty)
            XCTAssertTrue(node.startedJobs.isEmpty)
            XCTAssertTrue(raw.take().isEmpty, "\(message)")
        }
    }

    // MARK: - Configuration

    func testEndpointAndCarrierIdentitiesAreDisjoint() {
        let sim = Simulation()
        let local = sim.signingKey(index: 0)
        let carrier = sim.relayIdentity(1)
        let other = sim.relayIdentity(2)
        func config(
            bootstrap: [PeerEndpoint] = [],
            carriers: [PeerEndpoint] = [],
            mode: IvyMode = .overlay
        ) -> IvyConfig {
            IvyConfig(
                signingKey: local, bootstrapPeers: bootstrap, stunServers: [],
                carriers: carriers, mode: mode)
        }
        let localKey = config().peerKey

        XCTAssertNoThrow(try config(bootstrap: [other.endpoint], carriers: [carrier.endpoint]).validate())
        XCTAssertThrowsError(
            try config(bootstrap: [carrier.endpoint], carriers: [carrier.endpoint]).validate()
        ) { XCTAssertEqual($0 as? IvyModeError, .identityRoleCollision(carrier.key.hex)) }
        XCTAssertThrowsError(
            try config(carriers: [PeerEndpoint(publicKey: localKey.hex, host: "9.9.0.1", port: 4001)])
                .validate()
        ) { XCTAssertEqual($0 as? IvyModeError, .identityRoleCollision(localKey.hex)) }
        XCTAssertThrowsError(
            try config(carriers: [carrier.endpoint], mode: .pinned(peer: carrier.key.hex)).validate()
        ) { XCTAssertEqual($0 as? IvyModeError, .identityRoleCollision(carrier.key.hex)) }
        XCTAssertThrowsError(
            try config(carriers: [carrier.endpoint, carrier.endpoint]).validate()
        ) { XCTAssertEqual($0 as? IvyModeError, .duplicateCarrierIdentity(carrier.key.hex)) }
        XCTAssertThrowsError(
            try config(carriers: [PeerEndpoint(publicKey: "not a key", host: "9.9.0.1", port: 4001)])
                .validate()
        ) { XCTAssertEqual($0 as? IvyModeError, .invalidCarrierIdentity("not a key")) }
        XCTAssertThrowsError(
            try config(carriers: [PeerEndpoint(publicKey: carrier.key.hex, host: "9.9.0.1", port: 0)])
                .validate())

        // A node with colliding roles does not run.
        let node = sim.relayNode(carriers: [carrier.endpoint], bootstrap: [carrier.endpoint])
        XCTAssertFalse(node.core.isRunning)
        XCTAssertFalse(sim.trace.contains { entry in
            if case .dial = entry.effect { return true }
            return false
        })

        // Policy follows the same split once running.
        let running = sim.relayNode(carriers: [carrier.endpoint]).core.config
        XCTAssertTrue(running.isConfiguredCarrier(carrier.key))
        XCTAssertFalse(running.allowsEndpoint(carrier.key))
        XCTAssertTrue(running.allowsEndpoint(other.key))
    }

    func testAConfiguredCarrierCannotBeConnectedAsAnEndpoint() {
        let sim = Simulation()
        let (c, a, _) = sim.relayTriangle()
        XCTAssertEqual(
            sim.await(.connect(c.endpoint), on: a), .connect(.failed(.peerOutsideMode)))
        XCTAssertEqual(
            sim.await(.connectViaRelay(c.endpoint), on: a), .connect(.failed(.peerOutsideMode)))
        XCTAssertEqual(a.core.sessions[c.key]?.role, .carrier)
    }

    func testPrivateNetworkHasNoRelay() {
        let sim = Simulation()
        let carrier = sim.relayIdentity(1)
        func config(relayEnabled: Bool = false, carriers: [PeerEndpoint] = []) -> IvyConfig {
            IvyConfig(
                signingKey: sim.signingKey(index: 0), stunServers: [],
                relayEnabled: relayEnabled, carriers: carriers, mode: .privateNetwork)
        }
        XCTAssertNoThrow(try config().validate())
        XCTAssertThrowsError(try config(relayEnabled: true).validate())
        XCTAssertThrowsError(try config(carriers: [carrier.endpoint]).validate())
        XCTAssertFalse(sim.relayNode(relayEnabled: true, mode: .privateNetwork).core.isRunning)
        XCTAssertFalse(
            sim.relayNode(carriers: [carrier.endpoint], mode: .privateNetwork).core.isRunning)

        let a = sim.relayNode(mode: .privateNetwork)
        let b = sim.relayNode(mode: .privateNetwork)
        sim.setPartitioned(true, a, b)
        XCTAssertEqual(
            sim.await(.connectViaRelay(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
        XCTAssertEqual(
            sim.await(.connect(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
        assertNoRelayState(a, "a")

        // Relay control reaching a private node is dropped, not acted on.
        let raw = RawRelayPeer(sim, to: a, as: sim.relayIdentity(2))
        raw.send(.relayOffer(routeID: relayRouteID(1), sourceKey: sim.relayIdentity(3).key))
        raw.send(.relayOpen(routeID: relayRouteID(2), targetKey: b.key))
        raw.send(.relayPacket(routeID: relayRouteID(1), opaqueEndpointRecord: Data([1])))
        raw.send(.relayReady(routeID: relayRouteID(3), status: 0))
        sim.run(for: .zero)
        assertNoRelayState(a, "a")
        XCTAssertTrue(raw.take().isEmpty)
        XCTAssertTrue(raw.isConnected)
        XCTAssertEqual(a.ledger.violations(of: raw.identity.peer), 0)
    }

    // MARK: - Falling back to a carrier

    func testConnectFallsBackToTheCarrierWhenTheDirectDialFails() {
        let sim = Simulation()
        let (c, a, b) = sim.relayTriangle()
        XCTAssertEqual(sim.await(.connect(b.endpoint), on: a), .connect(.connected))
        sim.run(until: { b.core.connectedPeers.contains(a.peer) })

        guard case .relayed(let carrier, let routeID)? = a.core.authenticatedPeer(for: b.peer)?.route else {
            return XCTFail("expected a relayed session")
        }
        XCTAssertEqual(carrier, c.key)
        XCTAssertEqual(b.core.authenticatedPeer(for: a.peer)?.route, .relayed(carrier: c.key, routeID: routeID))
        XCTAssertEqual(a.core.diagnostics.outgoingDials, 0)
        XCTAssertEqual(a.core.diagnostics.pendingRequests, 0)

        // Already connected: neither form opens a second route.
        XCTAssertEqual(sim.await(.connectViaRelay(b.endpoint), on: a), .connect(.connected))
        XCTAssertEqual(sim.await(.connect(b.endpoint), on: a), .connect(.connected))
        XCTAssertEqual(c.core.relayRoutes.count, 1)
        XCTAssertEqual(a.core.installedRoutes.count, 1)
    }

    func testAReachablePeerIsConnectedDirectly() {
        let sim = Simulation()
        let (c, a, b) = sim.relayTriangle()
        sim.setPartitioned(false, a, b)
        sim.connect(a, b)
        XCTAssertEqual(sim.session(a, to: b).route, .direct)
        XCTAssertEqual(sim.session(b, to: a).route, .direct)
        for (node, name) in [(c, "carrier"), (a, "a"), (b, "b")] { assertNoRelayState(node, name) }
    }

    /// Reference: "direct address alternatives precede relay fallback".
    func testDirectAlternativesPrecedeRelayFallback() {
        let sim = Simulation()
        let c = sim.relayNode(relayEnabled: true)
        let b = sim.relayNode(carriers: [c.endpoint], start: false)
        let dead = PeerEndpoint(publicKey: b.key.hex, host: "8.200.0.1", port: 4001)
        // Two addresses for one configured peer: the first leads nowhere.
        let a = sim.relayNode(carriers: [c.endpoint], bootstrap: [dead, b.endpoint])

        // Nothing reaches `b` yet; once it is up, a carrier could.
        sim.run(for: .milliseconds(200))
        XCTAssertEqual(a.core.connectedPeers, [])
        sim.start(b)
        sim.attach([a, b], to: c)
        XCTAssertTrue(sim.run(until: { a.core.connectedPeers.contains(b.peer) }, timeout: .seconds(10)))
        sim.run(for: .milliseconds(100))

        XCTAssertEqual(a.connected.filter { $0.id == b.peer }.map(\.route), [.direct])
        XCTAssertEqual(b.connected.filter { $0.id == a.peer }.map(\.route), [.direct])
        let dialled: [String] = sim.trace.compactMap { entry in
            guard entry.node == a.id, case .dial(_, let endpoint) = entry.effect,
                  endpoint.publicKey == b.key.hex else { return nil }
            return endpoint.host
        }
        XCTAssertEqual(dialled, [dead.host, b.host, dead.host, b.host])
        for (node, name) in [(c, "carrier"), (a, "a"), (b, "b")] { assertNoRelayState(node, name) }
    }

    func testSeveralCarriersAreTriedInKeyOrder() {
        // Which carriers the target is attached to, and so which can serve.
        for attached in [[true, true], [false, true], [true, false]] {
            let sim = Simulation()
            let carriers = [sim.relayNode(relayEnabled: true), sim.relayNode(relayEnabled: true)]
                .sorted { $0.key < $1.key }
            let b = sim.relayNode()
            // Configured in the opposite order: the key decides, not the list.
            let a = sim.relayNode(carriers: carriers.reversed().map(\.endpoint))
            sim.setPartitioned(true, a, b)
            for (carrier, attach) in zip(carriers, attached) where attach { sim.connect(b, carrier) }
            XCTAssertTrue(sim.run(until: {
                carriers.allSatisfy { a.core.sessions[$0.key]?.role == .carrier }
            }))
            sim.run(for: .milliseconds(100))

            XCTAssertEqual(sim.await(.connect(b.endpoint), on: a), .connect(.connected), "\(attached)")
            let expected = attached[0] ? carriers[0] : carriers[1]
            guard case .relayed(let carrier, let routeID)? = a.core.authenticatedPeer(for: b.peer)?.route else {
                XCTFail("expected a relayed session \(attached)")
                continue
            }
            XCTAssertEqual(carrier, expected.key, "\(attached)")
            sim.run(for: .milliseconds(100))
            // Only the carrier in use holds a route; a refusal left nothing behind.
            for candidate in carriers {
                XCTAssertEqual(
                    Array(candidate.core.relayRoutes.keys),
                    candidate.key == expected.key ? [routeID] : [],
                    "\(attached)")
            }
            XCTAssertEqual(Array(a.core.installedRoutes.keys), [routeID])
            XCTAssertTrue(a.core.pendingRelayOpens.isEmpty)
        }
    }

    func testNoRelayAvailableWhenNoCarrierWorks() {
        // No carrier configured.
        do {
            let sim = Simulation()
            let a = sim.relayNode()
            let b = sim.relayNode()
            sim.setPartitioned(true, a, b)
            XCTAssertEqual(
                sim.await(.connectViaRelay(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
            XCTAssertEqual(
                sim.await(.connect(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
            assertNoRelayState(a, "a")
            XCTAssertEqual(a.core.diagnostics.outgoingDials, 0)
        }
        // The carrier does not know the target: it refuses with status 1.
        do {
            let sim = Simulation()
            let c = sim.relayNode(relayEnabled: true)
            let b = sim.relayNode()
            let a = sim.relayNode(carriers: [c.endpoint])
            sim.setPartitioned(true, a, b)
            sim.attach([a], to: c)
            let started = sim.now
            XCTAssertEqual(
                sim.await(.connectViaRelay(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
            XCTAssertEqual(
                sim.await(.connect(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
            // Refused, not timed out.
            XCTAssertLessThan(sim.now - started, .seconds(1))
            assertNoRelayState(a, "a")
            assertNoRelayState(c, "carrier")
            XCTAssertNotNil(a.core.sessions[c.key])
            XCTAssertEqual(c.ledger.violations(of: a.peer), 0)
        }
        // The configured carrier is down.
        do {
            let sim = Simulation()
            let c = sim.relayNode(relayEnabled: true, start: false)
            let b = sim.relayNode()
            let a = sim.relayNode(carriers: [c.endpoint])
            sim.setPartitioned(true, a, b)
            sim.run(for: .seconds(2))
            XCTAssertEqual(
                sim.await(.connectViaRelay(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
            assertNoRelayState(a, "a")
        }
    }

    func testACarrierWithRelayDisabledRejectsTheEndpointThatAsks() {
        let sim = Simulation()
        let c = sim.relayNode(relayEnabled: false)
        let b = sim.relayNode()
        let a = sim.relayNode(carriers: [c.endpoint])
        sim.setPartitioned(true, a, b)
        sim.connect(b, c)
        sim.attach([a, b], to: c)

        XCTAssertEqual(
            sim.await(.connectViaRelay(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
        XCTAssertEqual(c.ledger.violations(of: a.peer), 1)
        XCTAssertEqual(c.disconnected, [a.peer])
        XCTAssertTrue(c.core.connectedPeers.contains(b.peer))
        assertNoRelayState(a, "a")
        assertNoRelayState(c, "carrier")
        XCTAssertTrue(b.core.installedRoutes.isEmpty)
    }

    /// Reference: "relay admission failure closes the route promptly".
    func testRelayAdmissionFailureClosesRoutePromptly() {
        let sim = Simulation()
        let c = sim.relayNode(relayEnabled: true)
        // Room for the carrier and nobody else.
        let b = sim.relayNode(maxConnections: 1)
        let a = sim.relayNode(
            carriers: [c.endpoint], mode: .pinned(peer: b.key.hex), relayTimeout: .seconds(10))
        sim.setPartitioned(true, a, b)
        sim.connect(b, c)
        sim.attach([a, b], to: c)
        XCTAssertEqual(c.core.peerConnectionCount, 2)

        let started = sim.now
        XCTAssertEqual(
            sim.await(.connectViaRelay(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
        XCTAssertLessThan(sim.now - started, .seconds(5))
        sim.run(for: .milliseconds(200))
        XCTAssertEqual(b.core.peerConnectionCount, 1)
        XCTAssertNotNil(a.core.sessions[c.key])
        XCTAssertNotNil(c.core.sessions[a.key])
        XCTAssertEqual(a.disconnected, [])
        for (node, name) in [(c, "carrier"), (a, "a"), (b, "b")] { assertNoRelayState(node, name) }
        XCTAssertEqual(a.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(b.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(c.ledger.violations(of: a.peer) + c.ledger.violations(of: b.peer), 0)
        XCTAssertEqual(b.ledger.violations(of: a.peer) + b.ledger.violations(of: c.peer), 0)
    }
}
