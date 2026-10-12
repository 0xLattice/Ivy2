import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

private func directBudget(_ cids: [String]) -> Int {
    Message.contentResponseDataBudget(
        for: cids, maxFrameSize: IvyConfig.defaultProtocolMaxFrameSize, relayed: false)!
}

/// The serving side of exact content selections: what a peer's
/// `contentRequest` makes this node ask of its storage, and what it answers.
final class ContentServingSimulationTests: XCTestCase {
    private func server(
        _ sim: Simulation,
        slots: Int = 64,
        requestTimeout: Duration = .seconds(3_600)
    ) -> Simulation.Node {
        sim.node(requestTimeout: requestTimeout, maxConcurrentContentRequests: slots)
    }

    // MARK: - Authorization

    // remote content authorization runs before storage
    func testContentAuthorizationPrecedesStorage() {
        let sim = Simulation()
        let server = server(sim)
        server.content["root"] = Data("root".utf8)
        var asked: [(AuthenticatedPeer, String)] = []
        server.authorize = { peer, root in
            asked.append((peer, root))
            return false
        }
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(asked.map(\.1), ["root"])
        XCTAssertEqual(asked.first?.0, server.core.authenticatedPeer(for: peer.peer))
        XCTAssertEqual(server.contentAuthorizations, ["root"])
        XCTAssertEqual(server.contentReads.count, 0)
        XCTAssertEqual(peer.unavailable, [1])
        XCTAssertServingIdle(server)
    }

    // The authorization is asked about the selection the storage would be:
    // the root first, then the other identifiers, each once.
    func testAuthorizationSeesTheExactSelection() {
        let sim = Simulation()
        let server = server(sim)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: ["child-b", "root", "child-a", "child-b"]))
        sim.run(for: .seconds(1))
        guard case .authorizeContent(let requester, let rootCID, let cids)? = server.startedJobs.first?.job else {
            return XCTFail("no authorization was asked")
        }
        XCTAssertEqual(requester.id, peer.peer)
        XCTAssertEqual(requester.route, .direct)
        XCTAssertEqual(rootCID, "root")
        XCTAssertEqual(cids, ["root", "child-a", "child-b"])
    }

    // authorization and storage use one captured source
    func testAuthorizationCannotSwapStorageSource() {
        let sim = Simulation()
        let server = server(sim)
        server.content["root"] = Data("root".utf8)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .milliseconds(50))
        XCTAssertEqual(server.contentAuthorizations, ["root"])
        // The source goes away while it is being asked: the request it
        // authorized is still read from it.
        sim.send(.command(.setContentSource(false)), to: server)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(server.contentReads.map(\.rootCID), ["root"])
        XCTAssertEqual(peer.contentResponses.map(\.requestID), [1])
        XCTAssertServingIdle(server)
    }

    // authorization work obeys the inbound content cap
    func testAuthorizationObeysContentCap() {
        let sim = Simulation()
        let server = server(sim, slots: 1)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        peer.send(.contentRequest(requestID: 1, rootCID: "one", cids: []))
        sim.run(for: .milliseconds(50))
        XCTAssertEqual(server.contentAuthorizations, ["one"])
        // The second request waits for the slot; its authorization does not start.
        peer.send(.contentRequest(requestID: 2, rootCID: "two", cids: []))
        sim.run(for: .milliseconds(50))
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(server.contentAuthorizations, ["one"])

        // Authorization and read of the first, then the second's turn.
        sim.answerStalledJobs(server)
        XCTAssertEqual(server.contentAuthorizations, ["one"])
        sim.answerStalledJobs(server)
        XCTAssertEqual(server.contentAuthorizations, ["one", "two"])
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 0)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.unavailable, [1, 2])
        XCTAssertServingIdle(server)
    }

    // private content exchange requires explicit opt-in
    func testPrivateContentExchangeRequiresOptIn() {
        let sim = Simulation()
        let disabled = sim.node(mode: .privateNetwork)
        disabled.content["root"] = Data("root".utf8)
        disabled.volumes["root"] = servingSmallVolume("root")
        disabled.bundles["root"] = ["root"]
        let stranger = ServingRawPeer(sim, to: disabled, index: 1)
        stranger.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        stranger.send(.volumeRequest(requestID: 2, rootCID: "root"))
        stranger.send(.volumeBundleRequest(requestID: 3, rootCID: "root"))
        sim.run(for: .seconds(1))
        // Nothing is asked of storage and nothing is answered; the session stays.
        XCTAssertEqual(disabled.startedJobs.count, 0)
        XCTAssertTrue(stranger.read().isEmpty)
        XCTAssertTrue(disabled.core.connectedPeers.contains(stranger.peer))
        XCTAssertServingIdle(disabled)

        let enabled = sim.node(mode: .privateNetwork, privateContentExchangeEnabled: true)
        enabled.authorize = { _, _ in false }
        let member = ServingRawPeer(sim, to: enabled, index: 2)
        member.send(.contentRequest(requestID: 2, rootCID: "root", cids: []))
        sim.run(for: .seconds(1))
        member.read()
        XCTAssertEqual(enabled.contentAuthorizations, ["root"])
        XCTAssertEqual(enabled.contentReads.count, 0)
        XCTAssertEqual(member.unavailable, [2])
        XCTAssertServingIdle(enabled)
    }

    // With the opt-in a private node serves selections, Volumes and bundles.
    func testPrivateNetworkServesContentWhenEnabled() {
        let sim = Simulation()
        let server = sim.node(mode: .privateNetwork, privateContentExchangeEnabled: true)
        server.content["root"] = Data("root".utf8)
        server.volumes["root"] = servingSmallVolume("root")
        server.bundles["root"] = ["root"]
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        peer.send(.volumeRequest(requestID: 2, rootCID: "root"))
        peer.send(.volumeBundleRequest(requestID: 3, rootCID: "root"))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.contentResponses.first?.entries, [ContentEntry(cid: "root", data: Data("root".utf8))])
        XCTAssertNotNil(peer.archive(requestID: 2, rootCID: "root"))
        XCTAssertNotNil(peer.archive(requestID: 3, rootCID: "root"))
        XCTAssertEqual(peer.bundleEnds, [3])
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertServingIdle(server)
    }

    // MARK: - The selection and its budget

    // remote selection receives the exact direct aggregate data budget
    func testRemoteSelectionBudget() {
        let sim = Simulation()
        let server = server(sim)
        server.content["root"] = Data()
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .seconds(1))
        let request = server.contentReads.first
        XCTAssertEqual(request?.rootCID, "root")
        XCTAssertEqual(request?.cids, ["root"])
        XCTAssertEqual(request?.maxDataBytes, directBudget(["root"]))
        XCTAssertNotEqual(request?.maxDataBytes, .max)
        peer.read()
        XCTAssertEqual(peer.contentResponses.first?.entries, [ContentEntry(cid: "root", data: Data())])
    }

    // The budget is the server's own frame size, less the framing: a peer
    // that says it accepts less or more does not change what storage is asked for.
    func testSelectionBudgetIsTheServersFrameSize() {
        let sim = Simulation()
        let server = sim.node(protocolMaxFrameSize: 256 * 1024)
        server.content["root"] = Data("root".utf8)
        let peer = ServingRawPeer(sim, to: server, index: 1, maxFrameSize: 1024 * 1024)
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: ["a", "b"]))
        sim.run(for: .seconds(1))
        XCTAssertEqual(
            server.contentReads.first?.maxDataBytes,
            Message.contentResponseDataBudget(for: ["root", "a", "b"], maxFrameSize: 256 * 1024, relayed: false))
    }

    // A selection reaches storage root first, each identifier once, and is
    // answered in that order.
    func testExactPartialSelection() {
        let sim = Simulation()
        let server = server(sim)
        server.content = [
            "root": Data([0x00, 0xff, 0x7f]),
            "child-a": Data("bytes unrelated to the name".utf8),
            "child-b": Data([0x01, 0x02]),
            "unselected": Data([0x03]),
        ]
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: ["child-b", "root", "child-a", "child-b"]))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(server.contentReads.count, 1)
        XCTAssertEqual(server.contentReads.first?.cids, ["root", "child-a", "child-b"])
        XCTAssertEqual(server.contentReads.first?.maxDataBytes, directBudget(["root", "child-a", "child-b"]))
        XCTAssertEqual(peer.contentResponses.first?.entries, [
            ContentEntry(cid: "root", data: Data([0x00, 0xff, 0x7f])),
            ContentEntry(cid: "child-a", data: Data("bytes unrelated to the name".utf8)),
            ContentEntry(cid: "child-b", data: Data([0x01, 0x02])),
        ])
        XCTAssertServingIdle(server)
    }

    // structurally impossible exact selection does not invoke storage
    func testImpossibleSelection() {
        let sim = Simulation()
        let server = server(sim)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        // With the root this is one entry more than a response can carry.
        let cids = (0..<Int(MessageLimits.maxContentCIDCount)).map { "child-\($0)" }
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: cids))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(server.startedJobs.count, 0)
        XCTAssertEqual(peer.unavailable, [1])
        XCTAssertServingIdle(server)
    }

    // an incomplete selection is reported as unavailable
    func testIncompleteSelection() {
        let sim = Simulation()
        let server = server(sim)
        server.content["root"] = Data("root-only".utf8)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: ["missing-child"]))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(server.contentReads.first?.cids, ["root", "missing-child"])
        XCTAssertEqual(peer.unavailable, [1])
        XCTAssertEqual(peer.contentResponses.count, 0)
        XCTAssertServingIdle(server)
    }

    // remote source output must exactly match the requested selection
    func testMalformedContentSource() {
        let sim = Simulation()
        let server = server(sim)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        let root = ContentEntry(cid: "root", data: Data("root".utf8))
        let child = ContentEntry(cid: "child", data: Data("child".utf8))
        let outputs: [[ContentEntry]] = [
            // In any order, the exact selection is served in the order asked.
            [child, root],
            [root, root],
            [root, ContentEntry(cid: "extra", data: Data())],
            [root],
            [root, child, child],
            [],
        ]
        for (index, output) in outputs.enumerated() {
            peer.send(.contentRequest(requestID: UInt64(index + 1), rootCID: "root", cids: ["child"]))
            sim.run(for: .milliseconds(20))
            sim.answerStalledJobs(server, where: { !servingJobIsRead($0) })
            guard let read = server.servingStalledJobs.first else { return XCTFail("no read was started") }
            sim.answerStalledJob(server, read.id, with: .entries(output))
        }
        // A source that answers with something that is not entries at all.
        peer.send(.contentRequest(requestID: 7, rootCID: "root", cids: ["child"]))
        sim.run(for: .milliseconds(20))
        sim.answerStalledJobs(server, where: { !servingJobIsRead($0) })
        sim.answerStalledJob(server, server.servingStalledJobs[0].id, with: .roots(["root", "child"]))

        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.contentResponses.map(\.requestID), [1])
        XCTAssertEqual(peer.contentResponses.first?.entries, [root, child])
        XCTAssertEqual(peer.unavailable, [2, 3, 4, 5, 6, 7])
        XCTAssertServingIdle(server)
    }

    // storage cannot exceed the aggregate content budget
    func testOversizedContentSource() {
        let sim = Simulation()
        let server = server(sim)
        let budget = directBudget(["root"])
        server.content["root"] = Data(repeating: 0xaa, count: budget + 1)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.unavailable, [1])
        XCTAssertEqual(peer.contentResponses.count, 0)

        // Exactly the budget is one full frame.
        server.content["root"] = Data(repeating: 0xaa, count: budget)
        peer.send(.contentRequest(requestID: 2, rootCID: "root", cids: []))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.contentResponses.first?.entries.first?.data.count, budget)
        XCTAssertEqual(peer.frameSizes.max(), Int(IvyConfig.defaultProtocolMaxFrameSize))

        // The budget is the selection's, not each entry's.
        let pair = directBudget(["root", "child"])
        server.content["root"] = Data(repeating: 0xaa, count: pair - 10)
        server.content["child"] = Data(repeating: 0xbb, count: 11)
        peer.send(.contentRequest(requestID: 3, rootCID: "root", cids: ["child"]))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.unavailable, [1, 3])
        XCTAssertServingIdle(server)
    }

    // Route overhead is subtracted before storage materializes bytes: on a
    // relayed session storage is asked for less, and what it returns fits.
    func testRelayedSelectionBudgetSubtractsTheRouteOverhead() throws {
        let frame: UInt32 = 128 * 1024
        let sim = Simulation()
        let relay = sim.node(relayEnabled: true, protocolMaxFrameSize: frame)
        let server = sim.node(carriers: [relay.endpoint], protocolMaxFrameSize: frame)
        let client = sim.node(carriers: [relay.endpoint], protocolMaxFrameSize: frame)
        sim.run(for: .seconds(5))
        XCTAssertEqual(sim.await(.connectViaRelay(server.endpoint), on: client), .connect(.connected))
        sim.run(for: .seconds(1))
        let session = try XCTUnwrap(server.core.sessions[client.key])
        XCTAssertEqual(server.core.links[session.link]?.isDirect, false)

        let direct = Message.contentResponseDataBudget(for: ["root"], maxFrameSize: frame, relayed: false)!
        let relayed = Message.contentResponseDataBudget(for: ["root"], maxFrameSize: frame, relayed: true)!
        XCTAssertEqual(direct - relayed, 1 + 32 + 4 + SessionWireRecord.dataRecordOverhead)
        server.content["root"] = Data(repeating: 0x11, count: relayed)
        server.content["over"] = Data(repeating: 0x22, count: relayed + 1)

        let before = sim.trace.count
        let exact = sim.await(
            .fetchContentFrom(sim.session(client, to: server), rootCID: "root", cids: []), on: client)?.content
        XCTAssertEqual(exact?.entries["root"]?.count, relayed)
        XCTAssertEqual(exact?.servedBy, server.peer)
        XCTAssertEqual(server.contentReads.first?.maxDataBytes, relayed)
        // The response left the server as exactly one full frame to the carrier.
        let written = sim.trace[before...].compactMap { entry -> Int? in
            guard entry.node == server.id, case .write(_, let bytes) = entry.effect else { return nil }
            return bytes.count - 4
        }
        XCTAssertEqual(written.max(), Int(frame))

        // One byte more fits a direct frame and not this route.
        let over = sim.await(
            .fetchContentFrom(sim.session(client, to: server), rootCID: "over", cids: []), on: client)?.content
        XCTAssertEqual(over, .empty)
        sim.run(for: .seconds(1))
        XCTAssertServingIdle(server)
    }

    // MARK: - Slots

    // inbound storage callbacks obey the global concurrency bound
    func testInboundContentConcurrency() {
        let sim = Simulation()
        let server = server(sim, slots: 2)
        let peers = (0..<3).map { ServingRawPeer(sim, to: server, index: $0 + 1) }
        server.stallsStorage = true
        peers[0].send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        peers[1].send(.contentRequest(requestID: 2, rootCID: "root", cids: []))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.contentReads.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)

        // A third request waits for a slot rather than reaching storage.
        peers[2].send(.contentRequest(requestID: 3, rootCID: "root", cids: []))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(server.contentAuthorizations.count, 2)
        XCTAssertEqual(server.contentReads.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)

        sim.releaseNextRead(server)
        XCTAssertEqual(server.contentReads.count, 3)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        for (index, peer) in peers.enumerated() {
            peer.read()
            XCTAssertEqual(peer.unavailable, [UInt64(index + 1)])
        }
        XCTAssertServingIdle(server)
    }

    // a disconnected peer retains its serving slot until storage exits
    func testDisconnectedPeerRetainsServingSlot() {
        let sim = Simulation()
        let server = server(sim, slots: 8)
        server.content["root"] = Data("root".utf8)
        let old = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        old.send(.contentRequest(requestID: 7, rootCID: "root", cids: []))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.contentReads.count, 1)
        XCTAssertEqual(server.core.servingContentRequests.count, 1)
        let oldRead = server.servingStalledJobs[0].id

        // The same peer comes back on a new connection and asks with the
        // same request ID: its own request, not a duplicate of the old one.
        old.close()
        XCTAssertEqual(server.cancelledJobs, [oldRead])
        XCTAssertEqual(server.core.servingContentRequests.count, 1)
        let replacement = ServingRawPeer(sim, to: server, index: 1)
        replacement.send(.contentRequest(requestID: 7, rootCID: "root", cids: []))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.contentReads.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)
        replacement.read()
        XCTAssertEqual(replacement.unavailable, [])

        sim.answerStalledJobs(server, limit: 1, where: servingJobIsRead)
        XCTAssertEqual(server.core.servingContentRequests.count, 1)
        // The old request's bytes go nowhere.
        replacement.read()
        XCTAssertEqual(replacement.contentResponses.count, 0)

        sim.answerStalledJobs(server, limit: 1, where: servingJobIsRead)
        XCTAssertEqual(server.core.servingContentRequests.count, 0)
        sim.run(for: .seconds(1))
        replacement.read()
        XCTAssertEqual(replacement.contentResponses.map(\.requestID), [7])
        XCTAssertServingIdle(server)
    }

    // restart retains stalled Volume slots and byte reservations
    func testRestartRetainsServingVolumeReservations() {
        let sim = Simulation()
        let server = server(sim, slots: 2)
        for root in ["root-a", "root-b", "root-c", "root-d"] {
            server.volumes[root] = [ContentEntry(cid: root, data: Data())]
        }
        let first = (0..<2).map { ServingRawPeer(sim, to: server, index: $0 + 1) }
        server.stallsStorage = true
        first[0].send(.volumeRequest(requestID: 1, rootCID: "root-a"))
        first[1].send(.volumeRequest(requestID: 2, rootCID: "root-b"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.volumeReads.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)
        XCTAssertEqual(
            server.core.diagnostics.reservedServingVolumeBytes, IvyConfig.defaultMaxInFlightVolumeBytes)

        sim.stop(server)
        XCTAssertEqual(server.cancelledJobs.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)
        XCTAssertEqual(
            server.core.diagnostics.reservedServingVolumeBytes, IvyConfig.defaultMaxInFlightVolumeBytes)
        sim.start(server)
        sim.run(for: .milliseconds(50))
        let second = (0..<2).map { ServingRawPeer(sim, to: server, index: $0 + 3) }
        // Both retained slots are busy, so new requests wait for them.
        second[0].send(.volumeRequest(requestID: 3, rootCID: "root-c"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(server.volumeReads.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)

        // A retained slot frees: the waiting request takes it.
        sim.releaseNextRead(server)
        XCTAssertEqual(server.volumeReads.count, 3)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)
        second[1].send(.volumeRequest(requestID: 4, rootCID: "root-d"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)

        sim.releaseNextRead(server)
        XCTAssertEqual(server.volumeReads.count, 4)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        for (index, peer) in second.enumerated() {
            peer.read()
            XCTAssertEqual(peer.chunks.map(\.requestID), [UInt64(index + 3)])
        }
        XCTAssertServingIdle(server)
    }

    // closing a connection cancels its active content callback
    func testConnectionCloseCancelsContentCallback() {
        let sim = Simulation()
        let server = server(sim)
        let client = sim.node(requestTimeout: .seconds(3_600))
        sim.connect(client, server)
        server.stallsStorage = true
        let fetch = sim.request(
            .fetchContentFrom(sim.session(client, to: server), rootCID: "root", cids: []), on: client)
        sim.runHoldingReads(server)
        XCTAssertEqual(server.contentReads.count, 1)
        let read = server.servingStalledJobs[0].id

        sim.stop(server)
        XCTAssertEqual(server.cancelledJobs, [read])
        sim.run(for: .seconds(1))
        XCTAssertEqual(sim.result(of: fetch, on: client)?.content, .empty)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        XCTAssertServingIdle(server)
    }

    // transport close retires a session even if storage ignores cancellation
    func testConnectionCloseDoesNotWaitForStorage() {
        let sim = Simulation()
        let server = server(sim)
        let client = sim.node(requestTimeout: .seconds(3_600))
        sim.connect(client, server)
        server.stallsStorage = true
        let fetch = sim.request(
            .fetchContentFrom(sim.session(client, to: server), rootCID: "root", cids: []), on: client)
        sim.runHoldingReads(server)
        XCTAssertEqual(server.contentReads.count, 1)

        sim.send(.command(.disconnect(server.peer)), to: client)
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.connectedPeers, [])
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.cancelledJobs.count, 1)
        XCTAssertEqual(sim.result(of: fetch, on: client)?.content, .empty)

        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        XCTAssertServingIdle(server)
    }

    // A session that ends during authorization is not read for.
    func testSessionLossDuringAuthorizationSkipsTheRead() {
        let sim = Simulation()
        let server = server(sim)
        server.content["root"] = Data("root".utf8)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .milliseconds(50))
        XCTAssertEqual(server.contentAuthorizations, ["root"])
        peer.close()
        XCTAssertEqual(server.cancelledJobs.count, 1)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.contentReads.count, 0)
        XCTAssertServingIdle(server)
    }

    // MARK: - Deadlines and replies

    // a content reply to a peer that stops draining releases its slot at the deadline
    func testStalledContentReplyTimesOut() {
        let sim = Simulation()
        let server = server(sim, requestTimeout: .seconds(3))
        server.content["root"] = Data("root".utf8)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.stopReading()
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.core.servingContentRequests.count, 1)
        XCTAssertEqual(server.contentReads.count, 1)
        sim.run(for: .milliseconds(1_900))
        XCTAssertEqual(server.core.servingContentRequests.count, 1)
        sim.run(for: .milliseconds(200))
        XCTAssertEqual(server.core.servingContentRequests.count, 0)
        XCTAssertEqual(server.cancelledJobs, [])
        XCTAssertTrue(server.core.writabilityWaiters.values.allSatisfy(\.isEmpty))
        XCTAssertServingIdle(server)

        // The reply was dropped with its request.
        peer.resumeReading()
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.contentResponses.count, 0)
    }

    // A reply waits out a connection that is not taking records and goes
    // out when it does.
    func testContentReplyWaitsForAWritableConnection() {
        let sim = Simulation()
        let server = server(sim, requestTimeout: .seconds(3))
        server.content["root"] = Data("root".utf8)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.stopReading()
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .seconds(2))
        XCTAssertEqual(server.core.servingContentRequests.count, 1)
        XCTAssertTrue(peer.read().isEmpty)
        peer.resumeReading()
        sim.run(for: .milliseconds(100))
        peer.read()
        XCTAssertEqual(peer.contentResponses.first?.entries, [ContentEntry(cid: "root", data: Data("root".utf8))])
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertServingIdle(server)
        // Its deadline went with it.
        sim.run(for: .seconds(5))
        XCTAssertEqual(peer.read().count, 0)
    }

    // `requestTimeout` runs from the moment a selection holds its slot, not
    // while it waits for one.
    func testContentDeadlineStartsWhenTheSlotIsHeld() {
        let sim = Simulation()
        let server = server(sim, slots: 1, requestTimeout: .seconds(2))
        server.content["root"] = Data("root".utf8)
        let holder = ServingRawPeer(sim, to: server, index: 1)
        let waiter = ServingRawPeer(sim, to: server, index: 2)
        server.stallsStorage = true
        holder.send(.volumeRequest(requestID: 1, rootCID: "absent"))
        sim.run(for: .milliseconds(50))
        // The holder sits in its (untimed) Volume authorization.
        waiter.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .seconds(10))
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(server.cancelledJobs, [])

        // The holder's authorization and read finish and its slot frees; the
        // selection's read then runs out its own two seconds.
        sim.answerStalledJobs(server)
        sim.answerStalledJobs(server)
        let granted = sim.now
        XCTAssertEqual(server.contentAuthorizations, ["root"])
        sim.answerStalledJobs(server)
        XCTAssertEqual(server.contentReads.count, 1)
        let read = server.servingStalledJobs[0].id
        sim.run(until: { !server.cancelledJobs.isEmpty }, timeout: .seconds(10))
        XCTAssertEqual(server.cancelledJobs, [read])
        XCTAssertEqual(sim.now - granted, .seconds(2))
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        XCTAssertServingIdle(server)
    }

    // A read that ignores cancellation keeps its slot until it finishes; the
    // requester is then told the content is unavailable.
    func testContentReadPastTheDeadlineKeepsItsSlotUntilItFinishes() {
        let sim = Simulation()
        let server = server(sim, slots: 1, requestTimeout: .seconds(2))
        server.content["root"] = Data("root".utf8)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.runHoldingReads(server)
        let read = server.servingStalledJobs[0].id
        sim.runHoldingReads(server, for: .seconds(3))
        XCTAssertEqual(server.cancelledJobs, [read])
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.core.diagnostics.jobsOutstanding, 1)
        XCTAssertTrue(peer.read().isEmpty)

        // A second request waits for the slot the cancelled read holds.
        peer.send(.contentRequest(requestID: 2, rootCID: "root", cids: []))
        sim.runHoldingReads(server, for: .seconds(3))
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(server.cancelledJobs, [read])

        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.unavailable, [1])
        XCTAssertEqual(peer.contentResponses.map(\.requestID), [2])
        XCTAssertServingIdle(server)
    }

    // A selection whose authorization outlives the deadline is dropped once
    // the authorization returns: it is not read, and (as in 15.0.1, where
    // the cancelled request returns without a reply) nothing is answered.
    func testContentAuthorizedPastTheDeadlineIsDroppedWithoutAReply() {
        let sim = Simulation()
        let server = server(sim, requestTimeout: .seconds(2))
        server.content["root"] = Data("root".utf8)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .seconds(3))
        XCTAssertEqual(server.contentAuthorizations, ["root"])
        XCTAssertEqual(server.cancelledJobs.count, 1)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)

        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(server.contentReads.count, 0)
        XCTAssertServingIdle(server)
        XCTAssertEqual(peer.contentResponses.count, 0)
        XCTAssertEqual(peer.unavailable, [])
    }

    // A selection refused past the deadline is still told so.
    func testContentRefusedPastTheDeadlineIsStillAnswered() {
        let sim = Simulation()
        let server = server(sim, requestTimeout: .seconds(2))
        server.authorize = { _, _ in false }
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .seconds(3))
        XCTAssertEqual(server.cancelledJobs.count, 1)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.unavailable, [1])
        XCTAssertEqual(server.contentReads.count, 0)
        XCTAssertServingIdle(server)
    }

    // A request answered in time leaves no deadline behind.
    func testServedRequestsLeaveNoDeadline() {
        let sim = Simulation()
        let server = server(sim, requestTimeout: .seconds(2))
        server.content["root"] = Data("root".utf8)
        server.volumes["root"] = servingSmallVolume("root")
        server.bundles["root"] = ["root"]
        let peer = ServingRawPeer(sim, to: server, index: 1)
        let deadlines = server.core.diagnostics.deadlines
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        peer.send(.volumeRequest(requestID: 2, rootCID: "root"))
        peer.send(.volumeBundleRequest(requestID: 3, rootCID: "root"))
        peer.send(.volumeRequest(requestID: 4, rootCID: "absent"))
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.core.diagnostics.deadlines, deadlines)
        XCTAssertServingIdle(server)
        sim.run(for: .seconds(10))
        XCTAssertEqual(server.cancelledJobs, [])
        peer.read()
        XCTAssertEqual(peer.answeredRequestIDs.sorted(), [1, 2, 3, 4])
    }
}
