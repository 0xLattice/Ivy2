import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// `fetchVolumeBundle`: the root's own Volume first, no Volume twice, what
/// `ended`, `noBundle` and `failure` say, and the Volumes kept when the
/// answer ends early.
final class VolumeBundleFetchTests: XCTestCase {
    private func requester(
        requestTimeout: Duration = .seconds(1),
        maxInFlightVolumeBytes: Int = IvyConfig.defaultMaxInFlightVolumeBytes,
        peers: Int = 1
    ) -> (sim: Simulation, node: Simulation.Node, peers: [FetchRawPeer]) {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: requestTimeout, maxInFlightVolumeBytes: maxInFlightVolumeBytes)
        return (sim, node, (0..<peers).map { FetchRawPeer(sim, to: node, index: $0) })
    }

    private func volume(_ root: String) -> [ContentEntry] {
        [ContentEntry(cid: root, data: Data("\(root) bytes".utf8))]
    }

    /// A bundle stream that breaks its order is a violation that keeps the
    /// Volumes already complete.
    func testBundleStreamViolations() {
        let (sim, node, peers) = requester()
        let peer = peers[0]
        func bundle(_ answer: (UInt64) -> Void) -> AttributedVolumeBundleResponse? {
            let fetch = sim.request(.fetchVolumeBundle(rootCID: "root", from: [peer.authenticated]), on: node)
            let wire = peer.takeVolumeRequest()
            XCTAssertEqual(wire?.rootCID, "root")
            XCTAssertEqual(wire?.bundle, true)
            answer(wire?.requestID ?? 0)
            let response = sim.result(of: fetch, on: node)?.bundle
            assertHoldsNoVolumeBytes(node)
            XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
            return response
        }

        // The first Volume is not the requested root's.
        let wrongFirst = bundle { peer.sendVolume(requestID: $0, root: "other") }
        XCTAssertEqual(wrongFirst?.volumes.map(\.rootCID), [])
        XCTAssertEqual(wrongFirst?.ended, false)
        XCTAssertEqual(wrongFirst?.noBundle, false)
        XCTAssertNil(wrongFirst?.failure)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 1)

        // The end arrives while a Volume is half assembled.
        let endMidVolume = bundle {
            peer.sendVolume(requestID: $0, root: "root")
            peer.sendVolume(requestID: $0, root: "member", count: 2, prefix: 4)
            peer.send(.volumeBundleEnd(requestID: $0))
        }
        XCTAssertEqual(endMidVolume?.volumes.map(\.rootCID), ["root"])
        XCTAssertEqual(endMidVolume?.ended, false)
        XCTAssertNil(endMidVolume?.failure)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 2)

        // A Volume the bundle already carried.
        let repeated = bundle {
            peer.sendVolume(requestID: $0, root: "root")
            peer.sendVolume(requestID: $0, root: "member")
            peer.sendVolume(requestID: $0, root: "member")
        }
        XCTAssertEqual(repeated?.volumes.map(\.rootCID), ["root", "member"])
        XCTAssertEqual(repeated?.ended, false)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 3)

        // The root's own Volume a second time.
        let repeatedRoot = bundle {
            peer.sendVolume(requestID: $0, root: "root")
            peer.sendVolume(requestID: $0, root: "root")
        }
        XCTAssertEqual(repeatedRoot?.volumes.map(\.rootCID), ["root"])
        XCTAssertEqual(repeatedRoot?.ended, false)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 4)

        // A second end is ignored.
        let endedTwice = bundle {
            peer.sendVolume(requestID: $0, root: "root")
            peer.send(.volumeBundleEnd(requestID: $0))
            peer.send(.volumeBundleEnd(requestID: $0))
        }
        XCTAssertEqual(endedTwice?.volumes.map(\.rootCID), ["root"])
        XCTAssertEqual(endedTwice?.ended, true)
        XCTAssertEqual(endedTwice?.noBundle, false)
        XCTAssertNil(endedTwice?.failure)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 4)
        XCTAssertEqual(node.core.connectedPeers, [peer.peer])
    }

    func testBundleIsServedRootFirstAndEnded() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.fetchNode()
        for root in ["root", "member-a", "member-b"] { server.volumes[root] = volume(root) }
        server.bundles["root"] = ["root", "member-b", "member-a"]
        sim.connect(client, server)
        let serverPeer = sim.session(client, to: server)

        let response = sim.await(.fetchVolumeBundle(rootCID: "root", from: [serverPeer]), on: client)?.bundle

        XCTAssertEqual(response, AttributedVolumeBundleResponse(
            volumes: ["root", "member-b", "member-a"].map {
                AttributedVolumeResponse(
                    rootCID: $0, entries: [$0: Data("\($0) bytes".utf8)], servedBy: server.peer)
            },
            noBundle: false,
            ended: true,
            failure: nil))
        sim.run(for: .seconds(1))
        assertHoldsNoVolumeBytes(client)
        XCTAssertTrue(client.core.outstandingVolumeRequests.isEmpty)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(server.core.diagnostics.reservedServingVolumeBytes, 0)
    }

    /// A Volume the source cannot send is left out; the bundle still ends.
    func testBundleLeavesOutAVolumeThatCannotBeSent() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.fetchNode()
        for root in ["root", "member"] { server.volumes[root] = volume(root) }
        server.bundles["root"] = ["root", "absent", "member"]
        sim.connect(client, server)

        let response = sim.await(
            .fetchVolumeBundle(rootCID: "root", from: [sim.session(client, to: server)]), on: client)?.bundle

        XCTAssertEqual(response?.volumes.map(\.rootCID), ["root", "member"])
        XCTAssertEqual(response?.ended, true)
        XCTAssertEqual(response?.noBundle, false)
        XCTAssertNil(response?.failure)
        XCTAssertEqual(client.ledger.violations(of: server.peer), 0)
    }

    /// An end with no Volume before it says the peer holds no bundle for the
    /// root, which is distinct from `contentUnavailable`.
    func testNoBundleIsDistinctFromUnavailable() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.fetchNode()
        server.volumes["root"] = volume("root")
        sim.connect(client, server)
        let serverPeer = sim.session(client, to: server)

        let none = sim.await(.fetchVolumeBundle(rootCID: "root", from: [serverPeer]), on: client)?.bundle
        XCTAssertEqual(none, AttributedVolumeBundleResponse(volumes: [], noBundle: true, ended: true, failure: nil))

        // Refused outright: nothing ended, and nothing says there is no bundle.
        let (rawSim, node, peers) = requester()
        let fetch = rawSim.request(.fetchVolumeBundle(rootCID: "root", from: [peers[0].authenticated]), on: node)
        peers[0].send(.contentUnavailable(requestID: peers[0].takeVolumeRequest()!.requestID))
        XCTAssertEqual(
            rawSim.result(of: fetch, on: node)?.bundle,
            AttributedVolumeBundleResponse(volumes: [], noBundle: false, ended: false, failure: nil))
        XCTAssertEqual(node.ledger.violations(of: peers[0].peer), 0)
        assertHoldsNoVolumeBytes(node)
    }

    func testBundleNobodyWasAskedForIsNotSent() {
        let (sim, node, peers) = requester()
        let peer = peers[0]
        let stale = peer.authenticated
        peer.replaceSession()
        let notSent = RequestResult.volumeBundle(
            AttributedVolumeBundleResponse(volumes: [], noBundle: false, ended: false, failure: .notSent))

        let unnamed = sim.request(.fetchVolumeBundle(rootCID: "root", from: []), on: node)
        XCTAssertEqual(sim.result(of: unnamed, on: node), notSent)

        let replaced = sim.request(.fetchVolumeBundle(rootCID: "root", from: [stale]), on: node)
        XCTAssertEqual(sim.result(of: replaced, on: node), notSent)

        let invalid = sim.request(.fetchVolumeBundle(rootCID: "", from: [peer.authenticated]), on: node)
        XCTAssertEqual(sim.result(of: invalid, on: node), notSent)

        XCTAssertNil(peer.takeVolumeRequest())
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
        XCTAssertTrue(node.core.volumeFetches.isEmpty)
    }

    /// The requester keeps every Volume completed before the answer ended,
    /// each counted against its in-flight budget until the fetch returns.
    func testVolumesAreKeptWhenTheAnswerStopsBeforeItsEnd() throws {
        let (sim, node, peers) = requester(requestTimeout: .seconds(2))
        let peer = peers[0]
        let rootArchive = VolumeArchive.encode(entries: volume("root"), rootCID: "root")!
        let memberArchive = VolumeArchive.encode(entries: volume("member"), rootCID: "member")!
        let started = sim.now

        let fetch = sim.request(.fetchVolumeBundle(rootCID: "root", from: [peer.authenticated]), on: node)
        let requestID = try XCTUnwrap(peer.takeVolumeRequest()).requestID
        peer.sendVolume(requestID: requestID, root: "root", entries: volume("root"))
        XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, rootArchive.data.count)
        XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, rootArchive.data.count)
        peer.sendVolume(requestID: requestID, root: "member", entries: volume("member"))
        let held = rootArchive.data.count + memberArchive.data.count
        XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, held)
        XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, held)
        // A third Volume starts and never finishes.
        peer.sendVolume(requestID: requestID, root: "late", entries: volume("late"), count: 2, prefix: 4)
        XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, held + 4)
        XCTAssertNil(sim.result(of: fetch, on: node))

        sim.run(until: { sim.result(of: fetch, on: node) != nil })

        let response = try XCTUnwrap(sim.result(of: fetch, on: node)?.bundle)
        XCTAssertEqual(sim.now - started, .seconds(2))
        XCTAssertEqual(response.volumes.map(\.rootCID), ["root", "member"])
        XCTAssertEqual(response.volumes.map(\.servedBy), [peer.peer, peer.peer])
        XCTAssertEqual(response.volumes.last?.entries, ["member": Data("member bytes".utf8)])
        XCTAssertFalse(response.ended)
        XCTAssertFalse(response.noBundle)
        XCTAssertNil(response.failure)
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)
        // A peer that sent a Volume has not been timing out.
        XCTAssertNil(node.core.volumeTimeoutStreaks[peer.peer])
    }

    func testVolumesAreKeptWhenTheSessionIsLost() throws {
        let (sim, node, peers) = requester()
        let peer = peers[0]

        let fetch = sim.request(.fetchVolumeBundle(rootCID: "root", from: [peer.authenticated]), on: node)
        let requestID = try XCTUnwrap(peer.takeVolumeRequest()).requestID
        peer.sendVolume(requestID: requestID, root: "root")
        peer.sendVolume(requestID: requestID, root: "member", count: 2, prefix: 4)
        peer.close()

        let response = try XCTUnwrap(sim.result(of: fetch, on: node)?.bundle)
        XCTAssertEqual(response.volumes.map(\.rootCID), ["root"])
        XCTAssertFalse(response.ended)
        XCTAssertNil(response.failure)
        assertHoldsNoVolumeBytes(node)
    }

    /// A bundle cut short by this node's own budget says so, and keeps what
    /// it had.
    func testLocalCapacityEndsABundleWithItsVolumesAndAFailure() throws {
        let rootArchive = VolumeArchive.encode(entries: volume("root"), rootCID: "root")!
        let (sim, node, peers) = requester(maxInFlightVolumeBytes: rootArchive.data.count + 8)
        let peer = peers[0]

        let fetch = sim.request(.fetchVolumeBundle(rootCID: "root", from: [peer.authenticated]), on: node)
        let requestID = try XCTUnwrap(peer.takeVolumeRequest()).requestID
        peer.sendVolume(requestID: requestID, root: "root", entries: volume("root"))
        XCTAssertNil(sim.result(of: fetch, on: node))
        peer.sendVolume(requestID: requestID, root: "member", entries: volume("member"))

        let response = try XCTUnwrap(sim.result(of: fetch, on: node)?.bundle)
        XCTAssertEqual(response.volumes.map(\.rootCID), ["root"])
        XCTAssertFalse(response.ended)
        XCTAssertEqual(response.failure, .localCapacityUnavailable)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)
        assertHoldsNoVolumeBytes(node)
    }

    /// Only the sessions named are asked, one at a time, until one sends a Volume.
    func testNamedSessionsAreAskedOneAtATimeUntilOneSendsAVolume() throws {
        let (sim, node, peers) = requester(peers: 3)
        let named = Array(peers.prefix(2))
        let unnamed = peers[2]

        let fetch = sim.request(
            .fetchVolumeBundle(rootCID: "root", from: named.map(\.authenticated)), on: node)
        let first = try XCTUnwrap(named.first { $0.takeVolumeRequestID() != nil })
        let second = try XCTUnwrap(named.first { $0 !== first })
        XCTAssertNil(second.takeVolumeRequest())
        XCTAssertEqual(node.core.outstandingVolumeRequests, [first.peer: 1])

        // Holding no bundle is an answer, and the next session is asked.
        first.send(.volumeBundleEnd(requestID: first.lastVolumeRequestID))
        XCTAssertNil(sim.result(of: fetch, on: node))
        XCTAssertNotNil(second.takeVolumeRequestID())
        XCTAssertEqual(node.core.outstandingVolumeRequests, [second.peer: 1])

        second.sendVolume(requestID: second.lastVolumeRequestID, root: "root")
        second.send(.volumeBundleEnd(requestID: second.lastVolumeRequestID))

        let response = try XCTUnwrap(sim.result(of: fetch, on: node)?.bundle)
        XCTAssertEqual(response.volumes.map(\.rootCID), ["root"])
        XCTAssertEqual(response.volumes.first?.servedBy, second.peer)
        XCTAssertTrue(response.ended)
        XCTAssertFalse(response.noBundle)
        XCTAssertNil(unnamed.takeVolumeRequest())
        XCTAssertEqual(node.core.freshProviderQueryCount, 0)
        assertHoldsNoVolumeBytes(node)
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
    }

    func testResultReportsTheLastPeerAsked() throws {
        let (sim, node, peers) = requester(peers: 2)

        // Both hold no bundle.
        let neither = sim.request(
            .fetchVolumeBundle(rootCID: "root", from: peers.map(\.authenticated)), on: node)
        for _ in peers {
            let asked = try XCTUnwrap(peers.first { $0.takeVolumeRequestID() != nil })
            asked.send(.volumeBundleEnd(requestID: asked.lastVolumeRequestID))
        }
        XCTAssertEqual(
            sim.result(of: neither, on: node)?.bundle,
            AttributedVolumeBundleResponse(volumes: [], noBundle: true, ended: true, failure: nil))

        // The last one asked refuses instead.
        let refused = sim.request(
            .fetchVolumeBundle(rootCID: "root", from: peers.map(\.authenticated)), on: node)
        let first = try XCTUnwrap(peers.first { $0.takeVolumeRequestID() != nil })
        first.send(.volumeBundleEnd(requestID: first.lastVolumeRequestID))
        let second = try XCTUnwrap(peers.first { $0.takeVolumeRequestID() != nil })
        second.send(.contentUnavailable(requestID: second.lastVolumeRequestID))
        XCTAssertEqual(
            sim.result(of: refused, on: node)?.bundle,
            AttributedVolumeBundleResponse(volumes: [], noBundle: false, ended: false, failure: nil))
    }

    /// A peer that was asked is not forgotten for one that was not.
    func testAnAskedPeersAnswerOutlivesASessionThatCouldNotBeAsked() throws {
        for seed in UInt64(1)...6 {
            let sim = Simulation(seed: seed)
            let node = sim.fetchNode()
            let live = FetchRawPeer(sim, to: node, index: 0)
            let replaced = FetchRawPeer(sim, to: node, index: 1)
            let stale = replaced.authenticated
            replaced.replaceSession()

            let fetch = sim.request(
                .fetchVolumeBundle(rootCID: "root", from: [stale, live.authenticated]), on: node)
            let requestID = try XCTUnwrap(live.takeVolumeRequest()).requestID
            live.send(.volumeBundleEnd(requestID: requestID))

            XCTAssertEqual(
                sim.result(of: fetch, on: node)?.bundle,
                AttributedVolumeBundleResponse(volumes: [], noBundle: true, ended: true, failure: nil),
                "seed \(seed)")
            XCTAssertNil(replaced.takeVolumeRequest())
        }
    }

    /// 15.0.1 returns a cancelled bundle fetch the Volumes it had completed:
    /// "however it ended".
    func testCancelledBundleKeepsTheVolumesAlreadyComplete() throws {
        let (sim, node, peers) = requester()
        let peer = peers[0]

        let fetch = sim.request(.fetchVolumeBundle(rootCID: "root", from: [peer.authenticated]), on: node)
        let requestID = try XCTUnwrap(peer.takeVolumeRequest()).requestID
        peer.sendVolume(requestID: requestID, root: "root")
        peer.sendVolume(requestID: requestID, root: "member", count: 2, prefix: 4)

        sim.cancel(fetch, on: node)

        let response = try XCTUnwrap(sim.result(of: fetch, on: node)?.bundle)
        assertHoldsNoVolumeBytes(node)
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
        XCTAssertEqual(response.volumes.map(\.rootCID), ["root"])
        XCTAssertFalse(response.ended)
        XCTAssertNil(response.failure)
    }

    /// `notSent` means no peer was asked. A fetch cancelled, or stopped,
    /// while its request is out was sent.
    func testBundleCancelledOrStoppedWhileAskingIsNotReportedAsNotSent() throws {
        let unanswered = AttributedVolumeBundleResponse(volumes: [], noBundle: false, ended: false, failure: nil)

        let (sim, node, peers) = requester()
        let cancelled = sim.request(
            .fetchVolumeBundle(rootCID: "root", from: [peers[0].authenticated]), on: node)
        XCTAssertNotNil(peers[0].takeVolumeRequest())
        sim.cancel(cancelled, on: node)
        XCTAssertEqual(sim.result(of: cancelled, on: node)?.bundle, unanswered)
        assertHoldsNoVolumeBytes(node)
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)

        let stopped = sim.request(
            .fetchVolumeBundle(rootCID: "root", from: [peers[0].authenticated]), on: node)
        XCTAssertNotNil(peers[0].takeVolumeRequest())
        sim.stop(node)
        XCTAssertEqual(sim.result(of: stopped, on: node)?.bundle, unanswered)
        assertHoldsNoVolumeBytes(node)
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
    }
}
