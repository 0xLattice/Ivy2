import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Content and Volume fetches between whole nodes, and what a requester
/// sees of the node serving it: authorization, the byte budget, a source
/// that returns the wrong shape, stalls, closes and replaced sessions.
final class ContentExchangeEndToEndTests: XCTestCase {
    private func pair(
        serverTimeout: Duration = .seconds(15),
        mode: IvyMode = .overlay,
        privateContentExchangeEnabled: Bool = false
    ) -> (sim: Simulation, server: Simulation.Node, client: Simulation.Node, serverPeer: AuthenticatedPeer) {
        let sim = Simulation()
        let server = sim.node(
            mode: mode, requestTimeout: serverTimeout, privateContentExchangeEnabled: privateContentExchangeEnabled)
        let client = sim.node(mode: mode, privateContentExchangeEnabled: privateContentExchangeEnabled)
        sim.connect(client, server)
        return (sim, server, client, sim.session(client, to: server))
    }

    /// Answers the server's new jobs by hand until `done`.
    private func serve(
        _ sim: Simulation,
        _ server: Simulation.Node,
        until done: () -> Bool,
        read: (Job) -> JobResult?
    ) {
        var answered = server.startedJobs.count
        var rounds = 0
        while !done(), rounds < 200 {
            sim.run(for: .milliseconds(10))
            let started = server.startedJobs.count
            sim.answerJobsByHand(on: server, from: answered) { job in
                switch job {
                case .authorizeContent, .authorizeVolume: return .authorized(true)
                default: return read(job)
                }
            }
            answered = started
            rounds += 1
        }
    }

    // MARK: - Whole nodes

    /// Targeted partial content crosses an authenticated session.
    func testTargetedContent() {
        let (sim, server, client, serverPeer) = pair()
        let root = "opaque-root"
        let child = "opaque-child"
        server.content = [root: Data("root bytes".utf8), child: Data("child bytes".utf8)]

        let response = sim.await(.fetchContentFrom(serverPeer, rootCID: root, cids: [child]), on: client)?.content
        XCTAssertEqual(response?.entries, [root: Data("root bytes".utf8), child: Data("child bytes".utf8)])
        XCTAssertEqual(response?.servedBy, server.peer)

        sim.send(.command(.reportDeficientContent(rootCID: root, servedBy: server.peer)), to: client)
        XCTAssertEqual(client.core.peerConnectionCount, 1)
        let sync = Data("next range".utf8)
        XCTAssertEqual(
            sim.await(.send(to: server.peer, topic: "sync.request", payload: sync), on: client)?.sent,
            .enqueued(endpoint: server.peer, route: .direct))
        sim.run(until: { !server.received.isEmpty })
        XCTAssertEqual(server.received.first?.message, PeerMessage(topic: "sync.request", payload: sync))
        XCTAssertEqual(server.received.first?.peer.id, client.peer)
        XCTAssertTrue(client.disconnected.isEmpty)
        XCTAssertEqual(client.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
    }

    /// A coalesced fetch with no provider record reaches a connected peer
    /// that holds the content.
    func testCoalescedFetchIsServedByAConnectedPeer() {
        let (sim, server, client, _) = pair()
        server.content = ["root": Data("root".utf8), "leaf": Data("leaf".utf8)]

        let first = sim.request(.fetchContent(rootCID: "root", cids: ["leaf"]), on: client)
        let second = sim.request(.fetchContent(rootCID: "root", cids: ["leaf", "root"]), on: client)
        sim.run(until: { sim.result(of: first, on: client) != nil && sim.result(of: second, on: client) != nil })

        let expected = RequestResult.content(AttributedContentResponse(
            entries: ["root": Data("root".utf8), "leaf": Data("leaf".utf8)], servedBy: server.peer))
        XCTAssertEqual(sim.result(of: first, on: client), expected)
        XCTAssertEqual(sim.result(of: second, on: client), expected)
        // One search, one request, one read on the server.
        XCTAssertEqual(server.contentReadsStarted.count, 1)
        XCTAssertEqual(client.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(client.core.diagnostics.servingSlotsHeld, 0)
    }

    /// A peer with no serving credit is served every request it makes.
    func testUnknownPeerIsServedPastRequestCapacity() {
        let (sim, server, client, serverPeer) = pair()
        server.content = ["root": Data("root".utf8)]
        XCTAssertEqual(server.ledger.servingPriority(for: client.peer), 0)

        for _ in 0..<20 {
            XCTAssertEqual(
                sim.await(.fetchContentFrom(serverPeer, rootCID: "root", cids: []), on: client)?.content,
                AttributedContentResponse(entries: ["root": Data("root".utf8)], servedBy: server.peer))
        }
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
    }

    /// Private-network nodes exchange content only when both opt in, and
    /// only between sessions: nothing is looked up.
    func testPrivateNetworkContentExchange() {
        let (sim, server, client, serverPeer) = pair(mode: .privateNetwork, privateContentExchangeEnabled: true)
        server.content = ["private-root": Data("root bytes".utf8), "private-child": Data("child bytes".utf8)]

        let fetched = sim.await(
            .fetchContentFrom(serverPeer, rootCID: "private-root", cids: ["private-child"]), on: client)?.content

        XCTAssertEqual(fetched?.entries, [
            "private-root": Data("root bytes".utf8),
            "private-child": Data("child bytes".utf8),
        ])
        XCTAssertTrue(client.core.knownPeerEndpoints.isEmpty)
        XCTAssertEqual(client.core.freshProviderQueryCount, 0)
    }

    /// Storage cannot exceed the aggregate content budget.
    func testOversizedContentSource() throws {
        let (sim, server, client, serverPeer) = pair()
        let budget = try XCTUnwrap(Message.contentResponseDataBudget(
            for: ["root"], maxFrameSize: IvyConfig.defaultProtocolMaxFrameSize, relayed: false))
        server.content = [
            "root": Data(repeating: 0xaa, count: budget + 1),
            "fits": Data(repeating: 0xbb, count: try XCTUnwrap(Message.contentResponseDataBudget(
                for: ["fits"], maxFrameSize: IvyConfig.defaultProtocolMaxFrameSize, relayed: false))),
        ]

        let response = sim.await(.fetchContentFrom(serverPeer, rootCID: "root", cids: []), on: client)
        XCTAssertEqual(response, .content(.empty))
        XCTAssertEqual(server.contentReadsStarted.first?.maxDataBytes, budget)
        XCTAssertEqual(client.ledger.violations(of: server.peer), 0)

        // Exactly the budget fits one frame.
        let exact = sim.await(.fetchContentFrom(serverPeer, rootCID: "fits", cids: []), on: client)?.content
        XCTAssertEqual(exact?.entries["fits"]?.count, server.content["fits"]?.count)
        XCTAssertEqual(client.core.connectedPeers, [server.peer])
    }

    /// Remote source output must exactly match the requested selection.
    func testMalformedContentSource() {
        let (sim, server, client, serverPeer) = pair()
        server.stallsStorage = true
        let selections: [String: [ContentEntry]] = [
            "duplicate": [ContentEntry(cid: "duplicate", data: Data()), ContentEntry(cid: "duplicate", data: Data())],
            "extra-root": [ContentEntry(cid: "extra-root", data: Data()), ContentEntry(cid: "unrequested", data: Data())],
            "missing-child": [ContentEntry(cid: "missing-child", data: Data())],
        ]

        for root in ["duplicate", "extra-root", "missing-child"] {
            let fetch = sim.request(.fetchContentFrom(serverPeer, rootCID: root, cids: ["child"]), on: client)
            serve(sim, server, until: { sim.result(of: fetch, on: client) != nil }) { job in
                guard case .readContent(let rootCID, _, _) = job else { return nil }
                return .entries(selections[rootCID] ?? [])
            }
            XCTAssertEqual(sim.result(of: fetch, on: client), .content(.empty), root)
        }
        XCTAssertEqual(server.contentReadsStarted.map(\.rootCID), ["duplicate", "extra-root", "missing-child"])
        // The server refused each; it sent nothing malformed to be blamed for.
        XCTAssertEqual(client.ledger.violations(of: server.peer), 0)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
    }

    /// Stopping the serving node cancels its active content callback.
    func testConnectionCloseCancelsContentCallback() {
        let (sim, server, client, serverPeer) = pair()
        server.stallsStorage = true

        let request = sim.request(.fetchContentFrom(serverPeer, rootCID: "root", cids: []), on: client)
        sim.run(until: { !server.startedJobs.isEmpty })
        XCTAssertNil(sim.result(of: request, on: client))

        sim.stop(server)
        XCTAssertEqual(server.cancelledJobs, server.startedJobs.map(\.id))
        sim.run(until: { sim.result(of: request, on: client) != nil })
        XCTAssertEqual(sim.result(of: request, on: client), .content(.empty))
        XCTAssertLessThan(sim.now, .seconds(1))
        XCTAssertTrue(client.core.pendingContentRequests.isEmpty)
    }

    /// A transport close retires a session even if storage ignores cancellation.
    func testConnectionCloseDoesNotWaitForStorage() {
        let (sim, server, client, serverPeer) = pair()
        server.stallsStorage = true

        let request = sim.request(.fetchContentFrom(serverPeer, rootCID: "root", cids: []), on: client)
        sim.run(until: { !server.startedJobs.isEmpty })

        sim.send(.command(.disconnect(server.peer)), to: client)
        XCTAssertEqual(sim.result(of: request, on: client), .content(.empty))
        sim.run(until: { server.core.peerConnectionCount == 0 })
        XCTAssertEqual(server.core.peerConnectionCount, 0)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.cancelledJobs, server.startedJobs.map(\.id))

        sim.releaseStorage(server)
        sim.settleDue()
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(server.core.diagnostics.jobsOutstanding, 0)
        XCTAssertEqual(server.startedJobs.count, 1)
    }

    /// A stalled authenticated Volume writer releases its reservation at the deadline.
    func testStalledVolumeWriterTimesOut() throws {
        let (sim, server, client, serverPeer) = pair(serverTimeout: .seconds(1))
        let entries = [ContentEntry(
            cid: "root", data: Data(repeating: 0xa5, count: Int(IvyConfig.defaultProtocolMaxFrameSize) + 1))]
        // While it is sent, a Volume holds its encoded size, not the worst case.
        let archiveBytes = try XCTUnwrap(VolumeArchive.encode(entries: entries, rootCID: "root")).data.count
        server.volumes["root"] = entries
        // The client stops taking the server's bytes: its application holds a delivery.
        client.holdsDeliveries = true
        _ = sim.await(.send(to: client.peer, topic: "hold", payload: Data([1])), on: server)
        sim.run(until: { !client.heldDeliveries.isEmpty })
        // Lets the server hear that the held record itself was taken.
        sim.run(for: .milliseconds(100))

        let fetch = sim.request(
            .fetchVolumeFrom(
                serverPeer,
                rootCID: "root",
                maximumArchiveBytes: MessageLimits.maxVolumeArchiveBytes,
                maximumEntries: Int(MessageLimits.maxVolumeEntryCount)),
            on: client)
        XCTAssertTrue(sim.run(
            until: { server.core.diagnostics.reservedServingVolumeBytes == archiveBytes }, timeout: .seconds(1)))
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        let stalledAt = sim.now
        XCTAssertTrue(sim.run(
            until: { server.core.diagnostics.reservedServingVolumeBytes == 0 }, timeout: .seconds(2)))
        XCTAssertLessThanOrEqual(sim.now - stalledAt, .seconds(1))
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)

        sim.run(until: { sim.result(of: fetch, on: client) != nil })
        XCTAssertEqual(sim.result(of: fetch, on: client), .volume(.empty))
        assertHoldsNoVolumeBytes(client)
        XCTAssertTrue(client.core.outstandingVolumeRequests.isEmpty)
    }

    /// A content reply to a peer that stops draining releases its slot at the deadline.
    func testStalledContentReplyTimesOut() {
        let (sim, server, client, serverPeer) = pair(serverTimeout: .seconds(3))
        server.content = ["root": Data("root".utf8)]
        client.holdsDeliveries = true
        _ = sim.await(.send(to: client.peer, topic: "hold", payload: Data([1])), on: server)
        sim.run(until: { !client.heldDeliveries.isEmpty })
        // Lets the server hear that the held record itself was taken.
        sim.run(for: .milliseconds(100))
        // Past the high-water mark with nothing taken: the connection is full.
        let filler = Data(repeating: 0, count: IvyCore.writeHighWaterMark + 1)
        XCTAssertEqual(
            sim.await(.send(to: client.peer, topic: "fill", payload: filler), on: server)?.sent,
            .enqueued(endpoint: client.peer, route: .direct))
        sim.run(for: .milliseconds(100))
        XCTAssertEqual(
            sim.await(.send(to: client.peer, topic: "full", payload: Data([1])), on: server)?.sent, .backpressured)

        let fetch = sim.request(.fetchContentFrom(serverPeer, rootCID: "root", cids: []), on: client)
        XCTAssertTrue(sim.run(until: { !server.contentReadsStarted.isEmpty }, timeout: .seconds(1)))
        let servingSince = sim.now
        sim.run(for: .milliseconds(500))
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertNil(sim.result(of: fetch, on: client))

        XCTAssertTrue(sim.run(until: { server.core.diagnostics.servingSlotsHeld == 0 }, timeout: .seconds(4)))
        XCTAssertLessThanOrEqual(sim.now - servingSince, .seconds(3))
        XCTAssertGreaterThan(sim.now - servingSince, .seconds(2))

        sim.run(until: { sim.result(of: fetch, on: client) != nil })
        XCTAssertEqual(sim.result(of: fetch, on: client), .content(.empty))
        XCTAssertTrue(client.core.pendingContentRequests.isEmpty)
    }

    // MARK: - The serving node, seen by a requester played by hand

    /// Remote content authorization runs before storage.
    func testContentAuthorizationPrecedesStorage() {
        let sim = Simulation()
        let server = sim.node()
        server.content = ["root": Data("root".utf8)]
        server.authorize = { _, _ in false }
        let requester = FetchRawPeer(sim, to: server, index: 0)

        requester.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.settleDue()

        XCTAssertEqual(server.authorizationsStarted, 1)
        XCTAssertTrue(server.contentReadsStarted.isEmpty)
        let replies = requester.takeContentReplies()
        XCTAssertEqual(replies.map(\.requestID), [1])
        XCTAssertNil(replies.first?.entries)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
    }

    /// Private content exchange requires explicit opt-in.
    func testPrivateContentExchangeRequiresOptIn() {
        let sim = Simulation()
        let disabled = sim.node(mode: .privateNetwork)
        let enabled = sim.node(mode: .privateNetwork, privateContentExchangeEnabled: true)
        enabled.authorize = { _, _ in false }

        let ignored = FetchRawPeer(sim, to: disabled, index: 0)
        ignored.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        ignored.send(.volumeRequest(requestID: 2, rootCID: "root"))
        sim.settleDue()
        XCTAssertTrue(disabled.startedJobs.isEmpty)
        XCTAssertTrue(ignored.takeMessages().isEmpty)
        XCTAssertEqual(disabled.core.connectedPeers, [ignored.peer])

        let answered = FetchRawPeer(sim, to: enabled, index: 1)
        answered.send(.contentRequest(requestID: 2, rootCID: "root", cids: []))
        sim.settleDue()
        XCTAssertEqual(enabled.authorizationsStarted, 1)
        XCTAssertTrue(enabled.contentReadsStarted.isEmpty)
        XCTAssertEqual(answered.takeContentReplies().map(\.requestID), [2])
    }

    /// Remote selection receives the exact direct aggregate data budget.
    func testRemoteSelectionBudget() {
        let sim = Simulation()
        let server = sim.node()
        server.content = ["root": Data()]
        let requester = FetchRawPeer(sim, to: server, index: 0)

        requester.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.settleDue()

        let read = server.contentReadsStarted.first
        XCTAssertEqual(read?.cids, ["root"])
        XCTAssertEqual(read?.maxDataBytes, Message.contentResponseDataBudget(
            for: ["root"], maxFrameSize: IvyConfig.defaultProtocolMaxFrameSize, relayed: false))
        XCTAssertNotEqual(read?.maxDataBytes, .max)
        let replies = requester.takeContentReplies()
        XCTAssertEqual(replies.first?.entries, [ContentEntry(cid: "root", data: Data())])
    }

    /// A structurally impossible exact selection does not invoke storage.
    func testImpossibleSelection() {
        let sim = Simulation()
        let server = sim.node()
        let requester = FetchRawPeer(sim, to: server, index: 0)
        let cids = (0..<Int(MessageLimits.maxContentCIDCount)).map { "child-\($0)" }

        requester.send(.contentRequest(requestID: 1, rootCID: "root", cids: cids))
        sim.settleDue()

        XCTAssertTrue(server.startedJobs.isEmpty)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(server.core.connectedPeers, [requester.peer])
    }

    /// A disconnected peer retains its serving slot until storage exits.
    func testDisconnectedPeerRetainsServingSlot() {
        let sim = Simulation()
        let server = sim.node(maxConcurrentContentRequests: 8)
        server.content = ["root": Data("root".utf8)]
        server.stallsStorage = true
        let requester = FetchRawPeer(sim, to: server, index: 0)

        requester.send(.contentRequest(requestID: 7, rootCID: "root", cids: []))
        XCTAssertEqual(server.startedJobs.count, 1)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)

        requester.close()
        XCTAssertTrue(server.core.connectedPeers.isEmpty)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertTrue(requester.handshake())
        requester.send(.contentRequest(requestID: 7, rootCID: "root", cids: []))
        XCTAssertEqual(server.startedJobs.count, 2)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 2)

        // The old session's storage call exits: only its slot frees.
        sim.send(.jobFinished(server.startedJobs[0].id, .authorized(true)), to: server)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.startedJobs.count, 2)

        sim.send(.jobFinished(server.startedJobs[1].id, .authorized(true)), to: server)
        XCTAssertEqual(server.startedJobs.count, 3)
        sim.send(
            .jobFinished(server.startedJobs[2].id, .entries([ContentEntry(cid: "root", data: Data("root".utf8))])),
            to: server)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(requester.takeContentReplies().map(\.requestID), [7])
    }

    /// A replaced session cannot deliver a stale content reply.
    func testStaleSessionReply() {
        let sim = Simulation()
        let server = sim.node()
        server.content = ["root": Data("root".utf8)]
        server.stallsStorage = true
        let requester = FetchRawPeer(sim, to: server, index: 0)

        requester.send(.contentRequest(requestID: 7, rootCID: "root", cids: []))
        XCTAssertEqual(server.startedJobs.count, 1)
        let oldConnection = requester.connection

        requester.replaceSession()
        XCTAssertTrue(sim.nodeClosedRaw(oldConnection))
        requester.send(.contentRequest(requestID: 7, rootCID: "root", cids: []))
        XCTAssertEqual(server.startedJobs.count, 2)
        // The old request's job was cancelled with its session and still holds its slot.
        XCTAssertEqual(server.cancelledJobs, [server.startedJobs[0].id])
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 2)

        sim.releaseStorage(server)
        sim.run(for: .milliseconds(100))

        // One reply, on the session that asked last; nothing more on the old connection.
        let replies = requester.takeContentReplies()
        XCTAssertEqual(replies.map(\.requestID), [7])
        XCTAssertEqual(replies.first?.entries, [ContentEntry(cid: "root", data: Data("root".utf8))])
        XCTAssertTrue(sim.takeRawOutput(oldConnection).isEmpty)
        XCTAssertEqual(server.contentReadsStarted.count, 1)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
    }
}
