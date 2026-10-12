import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// The requesting side of exact content exchange: the selection contract,
/// response correlation, coalescing and its bounds, the search order, and
/// what a fetch holds across cancellation, its deadline, stop and restart.
final class ContentFetchTests: XCTestCase {
    private let rootBytes = Data("root".utf8)
    private let childBytes = Data("child".utf8)

    private func completions(of request: RequestID, in sim: Simulation) -> Int {
        sim.trace.filter {
            if case .completed(request, _) = $0.effect { return true }
            return false
        }.count
    }

    // MARK: - The selection contract, against the node's own source

    func testExactPartialSelection() {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)
        node.content = [
            "root": Data([0x00, 0xff, 0x7f]),
            "child-a": Data("bytes unrelated to the name".utf8),
            "child-b": Data([0x01, 0x02]),
            "unselected": Data([0x03]),
        ]

        let response = sim.await(
            .fetchContent(rootCID: "root", cids: ["child-b", "root", "child-a", "child-b"]), on: node)?.content

        XCTAssertEqual(response?.entries, [
            "root": Data([0x00, 0xff, 0x7f]),
            "child-a": Data("bytes unrelated to the name".utf8),
            "child-b": Data([0x01, 0x02]),
        ])
        XCTAssertNil(response?.servedBy)
        let reads = node.contentReadsStarted
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first?.rootCID, "root")
        XCTAssertEqual(reads.first?.cids, ["root", "child-a", "child-b"])
        XCTAssertEqual(reads.first?.maxDataBytes, Message.contentResponseDataBudget(
            for: ["root", "child-a", "child-b"],
            maxFrameSize: IvyConfig.defaultProtocolMaxFrameSize,
            relayed: false))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
    }

    func testEmptySelectedIdentifier() {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)
        node.content = ["root": rootBytes]

        let request = sim.request(.fetchContent(rootCID: "root", cids: [""]), on: node)

        XCTAssertEqual(sim.result(of: request, on: node), .content(.empty))
        XCTAssertTrue(node.startedJobs.isEmpty)
    }

    func testNonASCIIIdentifier() {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)

        let precomposed = sim.request(.fetchContent(rootCID: "\u{00e9}", cids: []), on: node)
        let combining = sim.request(.fetchContent(rootCID: "e\u{0301}", cids: []), on: node)

        XCTAssertEqual(sim.result(of: precomposed, on: node), .content(.empty))
        XCTAssertEqual(sim.result(of: combining, on: node), .content(.empty))
        XCTAssertTrue(node.startedJobs.isEmpty)
    }

    func testIncompleteSelection() {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)
        node.content = ["root": Data("root-only".utf8)]

        let response = sim.await(.fetchContent(rootCID: "root", cids: ["missing-child"]), on: node)

        XCTAssertEqual(response, .content(.empty))
        XCTAssertEqual(node.contentReadsStarted.first?.cids, ["root", "missing-child"])
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
    }

    /// Source output must exactly match the requested selection.
    func testExactSourceShape() {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)
        node.stallsStorage = true
        let root = ContentEntry(cid: "root", data: rootBytes)
        let child = ContentEntry(cid: "child", data: childBytes)

        func fetch(sourceReturns entries: [ContentEntry]) -> RequestResult? {
            let started = node.startedJobs.count
            let request = sim.request(.fetchContent(rootCID: "root", cids: ["child"]), on: node)
            sim.answerJobsByHand(on: node, from: started) { _ in .entries(entries) }
            sim.settleDue()
            return sim.result(of: request, on: node)
        }

        XCTAssertEqual(fetch(sourceReturns: [child, root])?.content?.entries, [
            "root": root.data,
            "child": child.data,
        ])
        for invalid in [
            [root, root],
            [root, ContentEntry(cid: "extra", data: Data())],
            [root],
        ] {
            XCTAssertEqual(fetch(sourceReturns: invalid), .content(.empty))
        }
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
    }

    func testLocalSourceAnswersBeforeAnyPeerIsAsked() {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)
        node.content = ["root": rootBytes]
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let response = sim.await(.fetchContent(rootCID: "root", cids: []), on: node)?.content

        XCTAssertEqual(response, AttributedContentResponse(entries: ["root": rootBytes], servedBy: nil))
        XCTAssertNil(peer.takeContentRequest())
        XCTAssertEqual(node.core.freshProviderQueryCount, 0)
    }

    // MARK: - Response correlation

    /// Only a complete response from an expected candidate resolves a fetch.
    func testAdversarialResponseCorrelation() throws {
        let sim = Simulation()
        let node = sim.fetchNode(maxContentCandidates: 2)
        let peers = (0..<3).map { FetchRawPeer(sim, to: node, index: $0) }

        let fetch = sim.request(.fetchContent(rootCID: "root", cids: ["child"]), on: node)
        var asked: [(peer: FetchRawPeer, requestID: UInt64)] = []
        var strangers: [FetchRawPeer] = []
        for peer in peers {
            if let request = peer.takeContentRequest() {
                XCTAssertEqual(request.rootCID, "root")
                XCTAssertEqual(request.cids, ["child"])
                asked.append((peer, request.requestID))
            } else {
                strangers.append(peer)
            }
        }
        XCTAssertEqual(asked.count, 2)
        let stranger = try XCTUnwrap(strangers.first)
        let (candidateA, requestID) = asked[0]
        let candidateB = asked[1].peer
        XCTAssertEqual(asked[1].requestID, requestID)
        let complete = [
            ContentEntry(cid: "root", data: rootBytes),
            ContentEntry(cid: "child", data: childBytes),
        ]

        // A peer that was not asked.
        stranger.send(.contentResponse(requestID: requestID, entries: complete))
        XCTAssertEqual(
            node.core.pendingContentRequests[requestID]?.candidates, [candidateA.peer, candidateB.peer])
        XCTAssertNil(sim.result(of: fetch, on: node))

        // A candidate answering a request that was never made.
        candidateB.send(.contentResponse(requestID: requestID &+ 1_000, entries: complete))
        XCTAssertEqual(
            node.core.pendingContentRequests[requestID]?.candidates, [candidateA.peer, candidateB.peer])
        XCTAssertNil(sim.result(of: fetch, on: node))

        // An entry that was not requested.
        candidateA.send(.contentResponse(requestID: requestID, entries: [
            ContentEntry(cid: "root", data: rootBytes),
            ContentEntry(cid: "extra", data: Data()),
        ]))
        XCTAssertEqual(node.core.pendingContentRequests[requestID]?.candidates, [candidateB.peer])
        XCTAssertNil(sim.result(of: fetch, on: node))
        XCTAssertEqual(node.ledger.violations(of: candidateA.peer), 1)

        candidateB.send(.contentResponse(requestID: requestID, entries: complete))

        XCTAssertEqual(sim.result(of: fetch, on: node), .content(AttributedContentResponse(
            entries: ["root": rootBytes, "child": childBytes],
            servedBy: candidateB.peer)))
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
        XCTAssertEqual(completions(of: fetch, in: sim), 1)
        XCTAssertEqual(node.ledger.violations(of: stranger.peer), 0)
        XCTAssertEqual(node.ledger.violations(of: candidateB.peer), 0)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        // Blame for a bad answer does not end the session.
        XCTAssertEqual(Set(node.core.connectedPeers), Set(peers.map(\.peer)))
    }

    func testDuplicateEntryIsAViolationAndMissingEntryIsNot() {
        let sim = Simulation()
        let node = sim.fetchNode()
        let duplicating = FetchRawPeer(sim, to: node, index: 0)
        let incomplete = FetchRawPeer(sim, to: node, index: 1)

        let fetch = sim.request(.fetchContent(rootCID: "root", cids: ["child"]), on: node)
        let requestID = duplicating.takeContentRequest()!.requestID
        XCTAssertEqual(incomplete.takeContentRequest()?.requestID, requestID)

        duplicating.send(.contentResponse(requestID: requestID, entries: [
            ContentEntry(cid: "root", data: rootBytes),
            ContentEntry(cid: "root", data: rootBytes),
        ]))
        XCTAssertNil(sim.result(of: fetch, on: node))
        XCTAssertEqual(node.ledger.violations(of: duplicating.peer), 1)

        // Its late, correct answer no longer counts: it had its turn.
        duplicating.send(.contentResponse(requestID: requestID, entries: [
            ContentEntry(cid: "root", data: rootBytes),
            ContentEntry(cid: "child", data: childBytes),
        ]))
        XCTAssertNil(sim.result(of: fetch, on: node))

        incomplete.send(.contentResponse(
            requestID: requestID, entries: [ContentEntry(cid: "root", data: rootBytes)]))

        // Never partial: the root alone is not the selection.
        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertEqual(node.ledger.violations(of: incomplete.peer), 0)
        XCTAssertEqual(node.ledger.violations(of: duplicating.peer), 1)
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
    }

    func testUnavailableFromEveryCandidateEndsTheFetchEmpty() {
        let sim = Simulation()
        let node = sim.fetchNode()
        let peers = (0..<2).map { FetchRawPeer(sim, to: node, index: $0) }

        let fetch = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        let requestID = peers[0].takeContentRequest()!.requestID
        peers[0].send(.contentUnavailable(requestID: requestID))
        XCTAssertNil(sim.result(of: fetch, on: node))
        peers[1].send(.contentUnavailable(requestID: requestID))

        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertEqual(sim.now, .zero)
        XCTAssertEqual(node.ledger.violations(of: peers[0].peer), 0)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
    }

    // MARK: - Exact-session fetches

    /// An exact content fetch is fenced to one authenticated session.
    func testExactSessionFetchIsFenced() throws {
        let sim = Simulation()
        let node = sim.fetchNode()
        let peer = FetchRawPeer(sim, to: node, index: 0)
        let oldPeer = peer.authenticated
        peer.replaceSession()
        let currentPeer = peer.authenticated
        XCTAssertNotEqual(oldPeer.sessionID, currentPeer.sessionID)

        let stale = sim.request(.fetchContentFrom(oldPeer, rootCID: "root", cids: []), on: node)
        XCTAssertEqual(sim.result(of: stale, on: node), .content(.empty))
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
        XCTAssertNil(peer.takeContentRequest())

        let fetch = sim.request(.fetchContentFrom(currentPeer, rootCID: "root", cids: ["child"]), on: node)
        let requestID = try XCTUnwrap(peer.takeContentRequest()).requestID
        let entries = [
            ContentEntry(cid: "root", data: rootBytes),
            ContentEntry(cid: "child", data: childBytes),
        ]

        node.core.handleContentResponse(
            requestID: requestID, entries: entries, from: peer.peer, sessionID: oldPeer.sessionID)
        XCTAssertNotNil(node.core.pendingContentRequests[requestID])
        XCTAssertNil(sim.result(of: fetch, on: node))

        peer.send(.contentResponse(requestID: requestID, entries: entries))
        XCTAssertEqual(sim.result(of: fetch, on: node), .content(AttributedContentResponse(
            entries: ["root": rootBytes, "child": childBytes],
            servedBy: peer.peer)))
    }

    func testReplacementSessionCannotSatisfyAnExactFetch() throws {
        let sim = Simulation()
        let node = sim.fetchNode()
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let fetch = sim.request(.fetchContentFrom(peer.authenticated, rootCID: "root", cids: []), on: node)
        let requestID = try XCTUnwrap(peer.takeContentRequest()).requestID

        peer.replaceSession()
        // The session the request was sent on is gone, and so is the request.
        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)

        peer.send(.contentResponse(
            requestID: requestID, entries: [ContentEntry(cid: "root", data: rootBytes)]))
        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertEqual(completions(of: fetch, in: sim), 1)
        XCTAssertEqual(node.core.connectedPeers, [peer.peer])
    }

    func testExactFetchAsksOnlyTheNamedPeer() throws {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)
        node.content = ["root": Data("local".utf8)]
        let named = FetchRawPeer(sim, to: node, index: 0)
        let other = FetchRawPeer(sim, to: node, index: 1)

        let fetch = sim.request(.fetchContentFrom(named.authenticated, rootCID: "root", cids: []), on: node)
        let requestID = try XCTUnwrap(named.takeContentRequest()).requestID
        XCTAssertNil(other.takeContentRequest())
        // Not the node's own source, and not a coalesced search.
        XCTAssertTrue(node.startedJobs.isEmpty)
        XCTAssertTrue(node.core.pendingFetches.isEmpty)

        other.send(.contentResponse(
            requestID: requestID, entries: [ContentEntry(cid: "root", data: rootBytes)]))
        XCTAssertNil(sim.result(of: fetch, on: node))

        named.send(.contentUnavailable(requestID: requestID))
        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertNil(other.takeContentRequest())
    }

    /// A request rejected before enqueue does not wait for its network timeout.
    func testLocallyRejectedRequestCompletesImmediately() {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(5))
        let peer = FetchRawPeer(sim, to: node, index: 0)
        let gone = peer.authenticated
        peer.close()
        sim.settleDue()
        XCTAssertTrue(node.core.connectedPeers.isEmpty)
        let started = sim.now

        let fetch = sim.request(.fetchContentFrom(gone, rootCID: "root", cids: []), on: node)

        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertEqual(sim.now, started)
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
    }

    func testExactFetchTimesOutEmptyWithoutBlame() throws {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(2))
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let fetch = sim.request(.fetchContentFrom(peer.authenticated, rootCID: "root", cids: []), on: node)
        let requestID = try XCTUnwrap(peer.takeContentRequest()).requestID
        sim.run(for: .milliseconds(1_900))
        XCTAssertNil(sim.result(of: fetch, on: node))
        sim.run(for: .milliseconds(200))

        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
        // The answer arrives after the deadline: nothing is waiting for it.
        peer.send(.contentResponse(
            requestID: requestID, entries: [ContentEntry(cid: "root", data: rootBytes)]))
        XCTAssertEqual(completions(of: fetch, in: sim), 1)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)
        XCTAssertEqual(node.core.connectedPeers, [peer.peer])
    }

    // MARK: - Coalescing and its bounds

    func testEqualFetchesShareOneSearchAndOneAnswer() throws {
        let sim = Simulation()
        let node = sim.fetchNode()
        let peer = FetchRawPeer(sim, to: node, index: 0)
        let key = ContentRequestKey(rootCID: "root", cids: ["child-a", "child-b"])

        let requests = [
            sim.request(.fetchContent(rootCID: "root", cids: ["child-b", "root", "child-a", "child-b"]), on: node),
            sim.request(.fetchContent(rootCID: "root", cids: ["child-a", "child-b"]), on: node),
            sim.request(.fetchContent(rootCID: "root", cids: ["child-b", "child-a"]), on: node),
        ]

        XCTAssertEqual(node.core.pendingFetches.count, 1)
        XCTAssertEqual(node.core.pendingFetches[key]?.waiters, requests)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 1)
        let wire = try XCTUnwrap(peer.takeContentRequest())
        XCTAssertEqual(wire.cids, ["child-a", "child-b"])
        XCTAssertNil(peer.takeContentRequest())

        // A different selection of the same root is a different fetch.
        let other = sim.request(.fetchContent(rootCID: "root", cids: ["child-a"]), on: node)
        XCTAssertEqual(node.core.pendingFetches.count, 2)
        XCTAssertNotNil(peer.takeContentRequest())

        let entries = ["root", "child-a", "child-b"].map { ContentEntry(cid: $0, data: Data($0.utf8)) }
        peer.send(.contentResponse(requestID: wire.requestID, entries: entries))

        let expected = RequestResult.content(AttributedContentResponse(
            entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.cid, $0.data) }),
            servedBy: peer.peer))
        for request in requests {
            XCTAssertEqual(sim.result(of: request, on: node), expected)
            XCTAssertEqual(completions(of: request, in: sim), 1)
        }
        XCTAssertNil(sim.result(of: other, on: node))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 1)
        sim.cancel(other, on: node)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
    }

    func testWaitersPerRequestBoundsACoalescedFetch() throws {
        let sim = Simulation()
        let node = sim.fetchNode(maxWaitersPerRequest: 2)
        let peer = FetchRawPeer(sim, to: node, index: 0)
        let key = ContentRequestKey(rootCID: "root", cids: [])

        let first = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        let second = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        let rejected = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)

        XCTAssertEqual(sim.result(of: rejected, on: node), .content(.empty))
        XCTAssertEqual(node.core.pendingFetches[key]?.waiters, [first, second])
        let requestID = try XCTUnwrap(peer.takeContentRequest()).requestID
        XCTAssertNil(peer.takeContentRequest())

        peer.send(.contentResponse(
            requestID: requestID, entries: [ContentEntry(cid: "root", data: rootBytes)]))
        for request in [first, second] {
            XCTAssertEqual(sim.result(of: request, on: node)?.content?.entries, ["root": rootBytes])
        }
        XCTAssertEqual(sim.result(of: rejected, on: node), .content(.empty))
        XCTAssertEqual(completions(of: rejected, in: sim), 1)
    }

    /// Public network fetch leaders stop at the pending-request cap.
    func testPublicNetworkFetchCap() throws {
        let sim = Simulation()
        let node = sim.fetchNode(maxPendingRequests: 2)
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let first = sim.request(.fetchContent(rootCID: "root-a", cids: []), on: node)
        let second = sim.request(.fetchContent(rootCID: "root-b", cids: []), on: node)
        let firstID = try XCTUnwrap(peer.takeContentRequest()).requestID
        let secondID = try XCTUnwrap(peer.takeContentRequest()).requestID
        XCTAssertEqual(node.core.diagnostics.activeFetches, 2)

        let rejected = sim.request(.fetchContent(rootCID: "root-c", cids: []), on: node)
        XCTAssertEqual(sim.result(of: rejected, on: node), .content(.empty))
        XCTAssertNil(peer.takeContentRequest())
        XCTAssertEqual(node.core.diagnostics.activeFetches, 2)
        XCTAssertEqual(node.core.pendingFetches.count, 2)

        // A waiter on a fetch already running is not a new leader.
        let follower = sim.request(.fetchContent(rootCID: "root-a", cids: []), on: node)
        XCTAssertNil(sim.result(of: follower, on: node))

        peer.send(.contentUnavailable(requestID: firstID))
        peer.send(.contentUnavailable(requestID: secondID))
        for request in [first, second, follower] {
            XCTAssertEqual(sim.result(of: request, on: node), .content(.empty))
        }
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)

        // The cap frees with the fetches that held it.
        _ = sim.request(.fetchContent(rootCID: "root-c", cids: []), on: node)
        XCTAssertEqual(try XCTUnwrap(peer.takeContentRequest()).rootCID, "root-c")
    }

    /// Cancelling coalesced waiters releases only their owned work.
    func testCoalescedFetchCancellation() throws {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(5), maxPendingRequests: 1)
        let peer = FetchRawPeer(sim, to: node, index: 0)
        let key = ContentRequestKey(rootCID: "root", cids: [])

        let leader = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        XCTAssertNotNil(peer.takeContentRequest())
        let follower = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        XCTAssertEqual(node.core.pendingFetches[key]?.waiters, [leader, follower])
        XCTAssertNil(peer.takeContentRequest())

        sim.cancel(follower, on: node)
        XCTAssertEqual(sim.result(of: follower, on: node), .content(.empty))
        XCTAssertNil(sim.result(of: leader, on: node))
        XCTAssertEqual(node.core.pendingFetches[key]?.waiters, [leader])
        XCTAssertEqual(node.core.diagnostics.activeFetches, 1)
        XCTAssertEqual(node.core.pendingContentRequests.count, 1)

        sim.cancel(leader, on: node)
        XCTAssertEqual(sim.result(of: leader, on: node), .content(.empty))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertTrue(node.core.pendingFetches.isEmpty)
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)

        // The search ended with its last waiter, so its slot is free again.
        let replacement = sim.request(.fetchContent(rootCID: "replacement", cids: []), on: node)
        let wire = try XCTUnwrap(peer.takeContentRequest())
        XCTAssertEqual(wire.rootCID, "replacement")
        peer.send(.contentUnavailable(requestID: wire.requestID))
        XCTAssertEqual(sim.result(of: replacement, on: node), .content(.empty))
        XCTAssertEqual(completions(of: follower, in: sim), 1)
        XCTAssertEqual(completions(of: leader, in: sim), 1)
    }

    func testCancellingTheFirstWaiterLeavesTheSearchToTheRest() throws {
        let sim = Simulation()
        let node = sim.fetchNode()
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let leader = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        let follower = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        let requestID = try XCTUnwrap(peer.takeContentRequest()).requestID

        sim.cancel(leader, on: node)
        XCTAssertEqual(sim.result(of: leader, on: node), .content(.empty))
        XCTAssertNotNil(node.core.pendingContentRequests[requestID])

        peer.send(.contentResponse(
            requestID: requestID, entries: [ContentEntry(cid: "root", data: rootBytes)]))
        XCTAssertEqual(sim.result(of: follower, on: node)?.content?.entries, ["root": rootBytes])
        XCTAssertEqual(sim.result(of: leader, on: node), .content(.empty))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
    }

    /// Cancelling a wire fetch removes its pending request immediately.
    func testWireFetchCancellation() throws {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(5), maxPendingRequests: 1)
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let request = sim.request(.fetchContentFrom(peer.authenticated, rootCID: "root", cids: []), on: node)
        XCTAssertEqual(node.core.pendingContentRequests.count, 1)
        sim.cancel(request, on: node)
        XCTAssertEqual(sim.result(of: request, on: node), .content(.empty))
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)

        let replacement = sim.request(
            .fetchContentFrom(peer.authenticated, rootCID: "replacement", cids: []), on: node)
        XCTAssertEqual(node.core.pendingContentRequests.count, 1)
        XCTAssertNil(sim.result(of: replacement, on: node))
        sim.stop(node)
        XCTAssertEqual(sim.result(of: replacement, on: node), .content(.empty))
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
        XCTAssertEqual(node.core.diagnostics.deadlines, 0)
    }

    // MARK: - The search order

    /// A content selection asks known providers, then fresh discovery, then
    /// the peers already connected.
    func testSearchAsksKnownProvidersThenDiscoveryThenConnectedPeers() throws {
        let sim = Simulation()
        let node = sim.fetchNode()
        let provider = FetchRawPeer(sim, to: node, index: 0)
        let router = FetchRawPeer(sim, to: node, index: 1, advertises: true)
        let bystander = FetchRawPeer(sim, to: node, index: 2)
        provider.send(.announceProvider(rootCID: "root", expiresAt: sim.unixSeconds + 60))
        XCTAssertEqual(node.core.providers(for: "root"), [provider.peer])
        let key = ContentRequestKey(rootCID: "root", cids: [])

        let fetch = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)

        // Known providers first, and nobody else.
        let known = try XCTUnwrap(provider.takeContentRequest()).requestID
        XCTAssertEqual(node.core.pendingFetches[key]?.phase, .askingKnown(known))
        XCTAssertTrue(router.takeMessages().isEmpty)
        XCTAssertTrue(bystander.takeMessages().isEmpty)
        XCTAssertEqual(node.core.freshProviderQueryCount, 0)

        // Then the network is asked who else provides the root.
        provider.send(.contentUnavailable(requestID: known))
        XCTAssertEqual(node.core.pendingFetches[key]?.phase, .searching)
        XCTAssertEqual(node.core.freshProviderQueryCount, 1)
        let query = try XCTUnwrap(router.takeProviderQuery())
        XCTAssertEqual(query.rootCID, "root")
        XCTAssertNil(router.takeContentRequest())
        XCTAssertTrue(bystander.takeMessages().isEmpty)

        // Then whoever is connected and has not been asked.
        router.send(.providers(rootCID: "root", requestID: query.requestID, records: []))
        let fallback = try XCTUnwrap(router.takeContentRequest()).requestID
        XCTAssertEqual(bystander.takeContentRequest()?.requestID, fallback)
        XCTAssertNil(provider.takeContentRequest())
        XCTAssertEqual(node.core.pendingFetches[key]?.phase, .askingFallback(fallback))

        router.send(.contentUnavailable(requestID: fallback))
        XCTAssertNil(sim.result(of: fetch, on: node))
        bystander.send(.contentResponse(
            requestID: fallback, entries: [ContentEntry(cid: "root", data: rootBytes)]))

        XCTAssertEqual(sim.result(of: fetch, on: node), .content(AttributedContentResponse(
            entries: ["root": rootBytes], servedBy: bystander.peer)))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
    }

    /// `requestTimeout` bounds the whole fetch, not each step of it.
    func testOneDeadlineCoversTheWholeSearch() throws {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(10))
        let provider = FetchRawPeer(sim, to: node, index: 0)
        let router = FetchRawPeer(sim, to: node, index: 1, advertises: true)
        provider.send(.announceProvider(rootCID: "root", expiresAt: sim.unixSeconds + 60))
        let started = sim.now

        let fetch = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        let known = try XCTUnwrap(provider.takeContentRequest()).requestID

        // The known provider takes most of the deadline to say no.
        sim.run(for: .seconds(8))
        provider.send(.contentUnavailable(requestID: known))
        XCTAssertNotNil(router.takeProviderQuery())
        // The lookup goes unanswered, then the fallback request does too.
        sim.run(for: .seconds(1))
        XCTAssertNotNil(router.takeContentRequest())
        XCTAssertNil(sim.result(of: fetch, on: node))

        sim.run(until: { sim.result(of: fetch, on: node) != nil })

        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertEqual(sim.now - started, .seconds(10))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
        XCTAssertTrue(node.core.pendingFetches.isEmpty)
        XCTAssertEqual(node.ledger.violations(of: provider.peer), 0)
        XCTAssertEqual(node.ledger.violations(of: router.peer), 0)
    }

    /// A provider the network names is connected to and asked before the
    /// peers that merely happen to be connected.
    func testFreshDiscoveryFindsAndAsksAnUnconnectedProvider() {
        let sim = Simulation()
        let requester = sim.fetchNode()
        let hub = sim.node()
        let provider = sim.node()
        provider.content = ["root": rootBytes]
        sim.connect(requester, hub)
        sim.connect(provider, hub)
        sim.send(.command(.announceProvider(rootCID: "root", expiresAt: sim.unixSeconds + 60)), to: provider)
        sim.run(for: .seconds(1))
        XCTAssertEqual(hub.core.providers(for: "root"), [provider.peer])
        XCTAssertFalse(requester.core.connectedPeers.contains(provider.peer))

        let response = sim.await(.fetchContent(rootCID: "root", cids: []), on: requester)?.content

        XCTAssertEqual(response, AttributedContentResponse(entries: ["root": rootBytes], servedBy: provider.peer))
        XCTAssertEqual(requester.core.freshProviderQueryCount, 1)
        XCTAssertTrue(requester.core.connectedPeers.contains(provider.peer))
        // The hub was asked who provides the root, never for the root.
        XCTAssertTrue(hub.startedJobs.isEmpty)
        XCTAssertEqual(requester.core.diagnostics.activeFetches, 0)
    }

    /// Last-resort content fallback rotates across connected peers.
    func testConnectedFallbackIsFair() {
        let sim = Simulation()
        let node = sim.fetchNode(maxContentCandidates: 2)
        let peers = (0..<3).map { FetchRawPeer(sim, to: node, index: $0) }

        func askedPeers(root: String) -> [PeerID] {
            let fetch = sim.request(.fetchContent(rootCID: root, cids: []), on: node)
            let asked = peers.filter { $0.takeContentRequest() != nil }.map(\.peer)
            sim.cancel(fetch, on: node)
            return asked
        }
        let first = askedPeers(root: "root-a")
        let second = askedPeers(root: "root-b")

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(Set(first + second), Set(peers.map(\.peer)))
    }

    // MARK: - What a fetch holds

    /// Local fetches coalesce and retain their concurrency slots across restart.
    func testLocalFetchWorkRemainsBoundedAcrossRestart() {
        let sim = Simulation()
        let node = sim.fetchNode(maxConcurrentContentRequests: 2, contentSource: true)
        node.stallsStorage = true

        let first = sim.request(.fetchContent(rootCID: "root-a", cids: []), on: node)
        XCTAssertEqual(node.startedJobs.count, 1)
        let follower = sim.request(.fetchContent(rootCID: "root-a", cids: []), on: node)
        XCTAssertEqual(
            node.core.pendingFetches[ContentRequestKey(rootCID: "root-a", cids: [])]?.waiters, [first, follower])
        XCTAssertEqual(node.startedJobs.count, 1)
        let second = sim.request(.fetchContent(rootCID: "root-b", cids: []), on: node)
        XCTAssertEqual(node.startedJobs.count, 2)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 2)

        sim.stop(node)
        XCTAssertEqual(sim.result(of: follower, on: node), .content(.empty))
        XCTAssertEqual(Set(node.cancelledJobs), Set(node.startedJobs.map(\.id)))
        // The reads ignored cancellation: they are still counted.
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 2)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 2)

        sim.start(node)
        let third = sim.request(.fetchContent(rootCID: "root-c", cids: []), on: node)
        XCTAssertEqual(sim.result(of: third, on: node), .content(.empty))
        XCTAssertEqual(node.startedJobs.count, 2)

        sim.releaseStorage(node)
        sim.settleDue()
        XCTAssertEqual(sim.result(of: first, on: node), .content(.empty))
        XCTAssertEqual(sim.result(of: second, on: node), .content(.empty))
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(node.core.diagnostics.jobsOutstanding, 0)
        for request in [first, follower, second, third] {
            XCTAssertEqual(completions(of: request, in: sim), 1)
        }
    }

    /// The fetch deadline returns while stalled work retains its bounded slot.
    func testFetchDeadlineKeepsStalledWorkBounded() {
        let sim = Simulation()
        let node = sim.fetchNode(
            requestTimeout: .milliseconds(50),
            maxPendingRequests: 1,
            maxConcurrentContentRequests: 1,
            contentSource: true,
            start: false)
        node.stallsStorage = true

        let first = sim.request(.fetchContent(rootCID: "root-a", cids: []), on: node)
        XCTAssertNil(sim.result(of: first, on: node))
        sim.run(until: { sim.result(of: first, on: node) != nil })
        XCTAssertEqual(sim.result(of: first, on: node), .content(.empty))
        XCTAssertEqual(sim.now, .milliseconds(50))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 1)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(node.cancelledJobs, node.startedJobs.map(\.id))

        let second = sim.request(.fetchContent(rootCID: "root-b", cids: []), on: node)
        XCTAssertEqual(sim.result(of: second, on: node), .content(.empty))
        XCTAssertEqual(node.startedJobs.count, 1)

        sim.releaseStorage(node)
        sim.settleDue()
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
    }

    /// The same bound on a node that has been started.
    func testFetchDeadlineKeepsStalledWorkBoundedWhileRunning() {
        let sim = Simulation()
        let node = sim.fetchNode(
            requestTimeout: .milliseconds(50),
            maxPendingRequests: 1,
            maxConcurrentContentRequests: 1,
            contentSource: true)
        node.stallsStorage = true

        let first = sim.request(.fetchContent(rootCID: "root-a", cids: []), on: node)
        sim.run(until: { sim.result(of: first, on: node) != nil })
        XCTAssertEqual(sim.result(of: first, on: node), .content(.empty))
        XCTAssertEqual(sim.now, .milliseconds(50))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 1)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(node.cancelledJobs, node.startedJobs.map(\.id))

        let second = sim.request(.fetchContent(rootCID: "root-b", cids: []), on: node)
        XCTAssertEqual(sim.result(of: second, on: node), .content(.empty))
        XCTAssertEqual(node.startedJobs.count, 1)

        sim.releaseStorage(node)
        sim.settleDue()
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
    }

    func testCancelledLocalReadStaysCountedUntilItsJobFinishes() {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)
        node.content = ["root": rootBytes]
        node.stallsStorage = true

        let fetch = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 1)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 1)

        sim.cancel(fetch, on: node)
        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertEqual(node.cancelledJobs, node.startedJobs.map(\.id))
        XCTAssertTrue(node.core.pendingFetches.isEmpty)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 1)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(node.core.diagnostics.jobsOutstanding, 1)

        // The read comes back with the content; nobody is waiting for it.
        sim.releaseStorage(node)
        sim.settleDue()
        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertEqual(completions(of: fetch, in: sim), 1)
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(node.core.diagnostics.jobsOutstanding, 0)
    }

    /// Stop drains a local fetch before the first network start.
    func testStopDrainsOfflineFetch() {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(5), contentSource: true, start: false)
        node.stallsStorage = true

        let stale = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        XCTAssertEqual(node.startedJobs.count, 1)
        XCTAssertNil(sim.result(of: stale, on: node))

        sim.stop(node)
        XCTAssertEqual(sim.result(of: stale, on: node), .content(.empty))

        let expected = Data("new".utf8)
        node.stallsStorage = false
        node.content = ["root": expected]
        sim.start(node)
        XCTAssertEqual(
            sim.await(.fetchContent(rootCID: "root", cids: []), on: node)?.content?.entries, ["root": expected])

        sim.releaseStorage(node)
        sim.settleDue()
        XCTAssertEqual(sim.result(of: stale, on: node), .content(.empty))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
    }

    /// Coalesced public fetches are isolated across stop and restart.
    func testPublicFetchIsRunScoped() throws {
        let sim = Simulation()
        let node = sim.fetchNode()
        let peer = FetchRawPeer(sim, to: node, index: 0)
        let key = ContentRequestKey(rootCID: "root", cids: [])

        let oldLeader = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        let oldFollower = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        XCTAssertEqual(node.core.pendingFetches[key]?.waiters.count, 2)
        let oldID = try XCTUnwrap(peer.takeContentRequest()).requestID

        sim.stop(node)
        XCTAssertEqual(sim.result(of: oldFollower, on: node), .content(.empty))
        XCTAssertEqual(sim.result(of: oldLeader, on: node), .content(.empty))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)

        sim.start(node)
        sim.send(.command(.setContentSource(false)), to: node)
        XCTAssertTrue(peer.handshake())
        let newLeader = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        let newFollower = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)
        XCTAssertEqual(node.core.pendingFetches[key]?.waiters, [newLeader, newFollower])
        let newID = try XCTUnwrap(peer.takeContentRequest()).requestID
        XCTAssertNotEqual(newID, oldID)

        // The old run's answer satisfies nobody in the new one.
        peer.send(.contentResponse(
            requestID: oldID, entries: [ContentEntry(cid: "root", data: Data("old".utf8))]))
        XCTAssertEqual(node.core.pendingFetches[key]?.waiters, [newLeader, newFollower])
        XCTAssertEqual(sim.result(of: oldLeader, on: node), .content(.empty))

        peer.send(.contentResponse(
            requestID: newID, entries: [ContentEntry(cid: "root", data: Data("new".utf8))]))
        let newResponse = RequestResult.content(AttributedContentResponse(
            entries: ["root": Data("new".utf8)], servedBy: peer.peer))
        XCTAssertEqual(sim.result(of: newLeader, on: node), newResponse)
        XCTAssertEqual(sim.result(of: newFollower, on: node), newResponse)
        XCTAssertNil(node.core.pendingFetches[key])
        for request in [oldLeader, oldFollower, newLeader, newFollower] {
            XCTAssertEqual(completions(of: request, in: sim), 1)
        }
    }

    func testFetchWithoutContentExchangeIsUnavailable() {
        let sim = Simulation()
        let node = sim.fetchNode(mode: .privateNetwork)
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let fetch = sim.request(.fetchContent(rootCID: "root", cids: []), on: node)

        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertNil(peer.takeContentRequest())
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
    }
}
