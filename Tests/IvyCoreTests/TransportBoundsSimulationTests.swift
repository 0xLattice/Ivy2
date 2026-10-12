import Crypto
import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Ports of 15.0.1's ResilienceTests ("Live transport bounds") and
/// PeerDisconnectTests ("Content teardown").
final class TransportBoundsSimulationTests: XCTestCase {
    private func standaloneCore(maxInboundBufferedBytes: Int = IvyConfig.defaultMaxInboundBufferedBytes) -> IvyCore {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
        var core = IvyCore(config: IvyConfig(
            signingKey: key,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            maxInboundBufferedBytes: maxInboundBufferedBytes))
        _ = core.step(.start, now: Timestamp(uptime: .zero, unixSeconds: 1_800_000_000))
        XCTAssertTrue(core.isRunning)
        return core
    }

    private func relayedLink(_ core: inout IvyCore, route: UInt8) -> LinkID {
        let carrier = try! PeerKey(rawRepresentation: Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 6, count: 32)).publicKey.rawRepresentation)
        let link = core.makeLink(
            .relayed(routeID: Data(repeating: route, count: 32), carrier: carrier),
            endpoint: PeerEndpoint(publicKey: "", host: "relay", port: 0))
        // Something ahead of its records is still being handled.
        core.links[link]?.block = .delivery(DeliveryToken(UInt64(route) + 90_000))
        return link
    }

    private func stalledPeer(_ sim: Simulation, _ node: Simulation.Node) -> HandPeer {
        let peer = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        XCTAssertTrue(peer.authenticate())
        // Let the handshake's own writes drain before the peer stops reading.
        sim.run(for: .seconds(1))
        _ = peer.takeRecords()
        sim.setRawStalled(true, peer.connection, at: node)
        return peer
    }

    // MARK: - Codec bounds

    // "application records obey the protocol frame cap"
    func testFrameCap() {
        let message = Message.peerMessage(topic: "state", payload: Data(repeating: 0xAB, count: 128))

        XCTAssertTrue(message.serialize(maxFrameSize: 64).isEmpty)

        let encoded = message.serialize(maxFrameSize: 256)
        guard case .peerMessage(let topic, let payload)? =
                Message.deserialize(encoded, maxDataPayload: 256) else {
            return XCTFail("bounded peer message did not round-trip")
        }
        XCTAssertEqual(topic, "state")
        XCTAssertEqual(payload, Data(repeating: 0xAB, count: 128))
    }

    // "message parser rejects oversized bounded fields"
    func testParserBounds() {
        let longTopic = String(repeating: "x", count: Int(MessageLimits.maxStringLength) + 1)
        XCTAssertTrue(Message.peerMessage(topic: longTopic, payload: Data()).serialize().isEmpty)

        var malformed = Data()
        malformed.appendUInt8(26)
        malformed.appendUInt64(1)
        malformed.appendUInt16(4)
        malformed.append(Data("root".utf8))
        malformed.appendUInt16(MessageLimits.maxContentCIDCount + 1)
        XCTAssertNil(Message.deserialize(malformed))
    }

    // MARK: - Relayed inbound queues

    // "relayed inbound queue overflow preserves order and closes the connection"
    func testRelayedInboundQueueOverflowClosesTheLink() {
        var core = standaloneCore()
        let link = relayedLink(&core, route: 1)

        for value in 0..<IvyCore.maxInboundBufferedRecords {
            XCTAssertTrue(core.feedRecord(Data([UInt8(value)]), to: link))
        }
        XCTAssertEqual(core.inboundBytesUsed, IvyCore.maxInboundBufferedRecords)
        XCTAssertEqual(
            core.links[link]?.queue,
            (0..<IvyCore.maxInboundBufferedRecords).map { Data([UInt8($0)]) })

        XCTAssertFalse(core.feedRecord(Data([0xff]), to: link))
        XCTAssertNil(core.links[link])
        XCTAssertEqual(core.inboundBytesUsed, 0)
        XCTAssertFalse(core.feedRecord(Data([1]), to: link))
    }

    func testRelayedLinkRefusesEmptyAndOversizeRecords() {
        var core = standaloneCore()
        let empty = relayedLink(&core, route: 1)
        XCTAssertFalse(core.feedRecord(Data(), to: empty))
        XCTAssertNil(core.links[empty])

        let oversize = relayedLink(&core, route: 2)
        XCTAssertFalse(core.feedRecord(
            Data(count: Int(IvyConfig.defaultProtocolMaxFrameSize) + 1), to: oversize))
        XCTAssertNil(core.links[oversize])
        XCTAssertEqual(core.inboundBytesUsed, 0)
    }

    // "relayed queues share one inbound byte budget"
    func testRelayedQueuesShareOneInboundByteBudget() {
        let frame = Int(IvyConfig.defaultProtocolMaxFrameSize)
        var core = standaloneCore(maxInboundBufferedBytes: frame + 4)
        let first = relayedLink(&core, route: 1)
        let second = relayedLink(&core, route: 2)

        XCTAssertTrue(core.feedRecord(Data(count: frame), to: first))
        XCTAssertFalse(core.feedRecord(Data(count: 5), to: second))
        XCTAssertNil(core.links[second])
        XCTAssertEqual(core.inboundBytesUsed, frame)

        // Handling the first link's record gives its bytes back.
        core.unblock(first)
        core.drainPumps()
        XCTAssertEqual(core.inboundBytesUsed, 0)
    }

    // MARK: - Outbound backpressure

    // "outbound backpressure waits for recovery and distinguishes closure"
    func testOutboundBackpressureWaitsForRecoveryAndDistinguishesClosure() throws {
        let sim = Simulation()
        let node = sim.node()
        let peer = stalledPeer(sim, node)

        let enqueued = sim.saturate(node, toward: peer.id)
        XCTAssertGreaterThan(enqueued, 0)
        let link = try XCTUnwrap(peer.link)
        XCTAssertFalse(link.writable)
        XCTAssertGreaterThan(link.unflushed, IvyCore.writeHighWaterMark)
        // Nothing is written past the mark.
        let written = sim.writeCount(by: node)
        XCTAssertEqual(
            sim.await(.send(to: peer.id, topic: "held", payload: Data([1, 2, 3])), on: node)?.sent,
            .backpressured)
        XCTAssertEqual(sim.writeCount(by: node), written)

        let writable = sim.request(.waitUntilWritable(peer.id), on: node)
        sim.run(for: .seconds(5))
        XCTAssertNil(sim.result(of: writable, on: node))
        XCTAssertFalse(peer.isClosed)

        sim.setRawStalled(false, peer.connection, at: node)
        sim.run(for: .zero)
        XCTAssertEqual(sim.result(of: writable, on: node), .writable(true))
        XCTAssertEqual(
            sim.await(.send(to: peer.id, topic: "resumed", payload: Data([1, 2, 3])), on: node)?.sent,
            .enqueued(endpoint: peer.id, route: .direct))
        XCTAssertEqual(sim.writeCount(by: node), written + 1)

        // A wait that ends because the connection closed says so.
        sim.run(for: .seconds(1))
        sim.setRawStalled(true, peer.connection, at: node)
        sim.saturate(node, toward: peer.id)
        let closed = sim.request(.waitUntilWritable(peer.id), on: node)
        XCTAssertNil(sim.result(of: closed, on: node))
        peer.close()
        XCTAssertEqual(sim.result(of: closed, on: node), .writable(false))
        XCTAssertEqual(
            sim.await(.send(to: peer.id, topic: "gone", payload: Data([4])), on: node)?.sent,
            .notConnected)
    }

    // "Ivy exposes live transport backpressure without advancing the session"
    func testBackpressureDoesNotAdvanceTheSession() throws {
        let sim = Simulation()
        let node = sim.node()
        let peer = stalledPeer(sim, node)

        let enqueued = sim.saturate(node, toward: peer.id)
        let sequenceState = try XCTUnwrap(node.core.sessions[peer.key]?.sequenceState)
        XCTAssertEqual(sequenceState.nextToSend, UInt64(enqueued) + 1)
        for _ in 0..<3 {
            XCTAssertEqual(
                sim.await(.send(to: peer.id, topic: "state", payload: Data()), on: node)?.sent,
                .backpressured)
        }
        XCTAssertEqual(node.core.sessions[peer.key]?.sequenceState, sequenceState)
        let session = try XCTUnwrap(node.core.authenticatedPeer(for: peer.id))
        XCTAssertEqual(
            sim.await(.sendOnSession(session, topic: "state", payload: Data()), on: node)?.sent,
            .backpressured)

        let writable = sim.request(.waitUntilSessionWritable(session), on: node)
        XCTAssertNil(sim.result(of: writable, on: node))
        sim.setRawStalled(false, peer.connection, at: node)
        sim.run(for: .zero)
        XCTAssertEqual(sim.result(of: writable, on: node), .writable(true))
        XCTAssertEqual(
            sim.await(.send(to: peer.id, topic: "state", payload: Data()), on: node)?.sent,
            .enqueued(endpoint: peer.id, route: .direct))

        // What reached the wire has no gap where the refused sends were.
        let records = peer.takeDataRecords()
        XCTAssertEqual(records.map(\.sequence), Array(1...UInt64(enqueued) + 1))

        peer.close()
        XCTAssertEqual(sim.await(.waitUntilWritable(peer.id), on: node), .writable(false))
        XCTAssertEqual(sim.await(.waitUntilSessionWritable(session), on: node), .writable(false))
    }

    func testCancelledWritabilityWaitCompletesFalse() {
        let sim = Simulation()
        let node = sim.node()
        let peer = stalledPeer(sim, node)
        sim.saturate(node, toward: peer.id)

        let writable = sim.request(.waitUntilWritable(peer.id), on: node)
        sim.cancel(writable, on: node)
        XCTAssertEqual(sim.result(of: writable, on: node), .writable(false))

        sim.setRawStalled(false, peer.connection, at: node)
        sim.run(for: .seconds(1))
        XCTAssertEqual(sim.result(of: writable, on: node), .writable(false))
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
    }

    // "a burst beyond Tally's per-peer request capacity is never locally rejected"
    func testOutboundBurstIsNotLocallyRejected() {
        let sim = Simulation()
        let node = sim.node()
        let remote = sim.node()
        sim.connect(node, remote)

        for _ in 0..<100 {
            XCTAssertEqual(
                sim.await(.send(to: remote.peer, topic: "state", payload: Data()), on: node)?.sent,
                .enqueued(endpoint: remote.peer, route: .direct))
        }

        sim.run(for: .seconds(1))
        XCTAssertEqual(remote.received.count, 100)
    }

    // "a content response waits out a backpressured connection"
    func testContentResponseWaitsForWritability() {
        let sim = Simulation()
        let node = sim.node()
        let content = Data(repeating: 7, count: 1_000)
        node.content = ["root": content]
        let peer = stalledPeer(sim, node)
        sim.saturate(node, toward: peer.id)
        _ = peer.takeRecords()

        peer.send(Message.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .milliseconds(100))
        XCTAssertTrue(peer.takeRecords().isEmpty)
        XCTAssertFalse(peer.isClosed)

        sim.setRawStalled(false, peer.connection, at: node)
        sim.run(for: .seconds(1))
        let responses = peer.takeMessages().compactMap { message -> [ContentEntry]? in
            if case .contentResponse(1, let entries) = message { return entries }
            return nil
        }
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.map(\.cid), ["root"])
        XCTAssertEqual(responses.first?.first?.data, content)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
    }

    // MARK: - Teardown

    // "teardown resolves every pending targeted content continuation"
    func testTeardownResolvesPendingContentFetch() {
        let sim = Simulation()
        let node = sim.node()
        let silent = sim.node()
        silent.stallsStorage = true
        sim.connect(node, silent)

        let fetch = sim.request(.fetchContentFrom(
            sim.session(node, to: silent), rootCID: "pending-root", cids: ["pending-child"]), on: node)
        sim.run(for: .milliseconds(100))
        XCTAssertEqual(node.core.pendingContentRequests.count, 1)
        XCTAssertNil(sim.result(of: fetch, on: node))

        sim.stop(node)

        let response = sim.result(of: fetch, on: node)?.content
        XCTAssertEqual(response?.entries.isEmpty, true)
        XCTAssertNil(response?.servedBy)
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
    }

    // The same request ends when only its peer goes away.
    func testPeerDisconnectResolvesPendingContentFetch() {
        let sim = Simulation()
        let node = sim.node()
        let silent = sim.node()
        silent.stallsStorage = true
        sim.connect(node, silent)

        let fetch = sim.request(.fetchContentFrom(
            sim.session(node, to: silent), rootCID: "pending-root", cids: ["pending-child"]), on: node)
        sim.run(for: .milliseconds(100))
        XCTAssertEqual(node.core.pendingContentRequests.count, 1)

        sim.send(.command(.disconnect(silent.peer)), to: node)

        XCTAssertEqual(sim.result(of: fetch, on: node)?.content, .empty)
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
    }

    // "peer retirement resolves session-bound neighbor work"
    func testPeerRetirementResolvesNeighborRequest() {
        let sim = Simulation()
        let node = sim.node()
        let peer = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        XCTAssertTrue(peer.authenticate(metadata: PeerMetadata(
            listenAddresses: [ListenAddress(host: "10.1.0.1", port: 4001)])))
        XCTAssertEqual(node.core.knownPeerEndpoints, [peer.endpoint])

        // The peer is asked and never answers.
        let lookup = sim.request(.findNode(target: "somewhere"), on: node)
        XCTAssertEqual(node.core.pendingNeighborResponses.count, 1)
        XCTAssertEqual(node.core.pendingNeighborResponses.values.first?.peer, peer.id)
        XCTAssertNil(sim.result(of: lookup, on: node))

        peer.close()

        XCTAssertTrue(node.core.pendingNeighborResponses.isEmpty)
        XCTAssertTrue(sim.run(until: { sim.result(of: lookup, on: node) != nil }, timeout: .seconds(30)))
        XCTAssertNotNil(sim.result(of: lookup, on: node)?.endpoints)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
    }
}
