import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// A link with no room for a Volume request is waited for. It is not a peer
/// that lacks the Volume.
final class FetchBackpressureTests: XCTestCase {
    private func fetch(_ root: String) -> Request {
        .fetchVolume(rootCID: root, maximumArchiveBytes: .max, maximumEntries: .max)
    }

    private func pair() -> (Simulation, Simulation.Node, Simulation.Node) {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        b.volumes["vol"] = volumeEntries(root: "vol", members: 3, bytesEach: 1_000)
        sim.connect(a, b)
        return (sim, a, b)
    }

    /// Writes past the high-water mark, so the link is not writable until
    /// the shell reports it flushed.
    private func fill(_ sim: Simulation, _ a: Simulation.Node, toward b: Simulation.Node) {
        let payload = Data(repeating: 9, count: IvyCore.writeHighWaterMark + 1)
        let sent = sim.request(.send(to: b.peer, topic: "t", payload: payload), on: a)
        guard case .send(.enqueued) = sim.result(of: sent, on: a) else {
            return XCTFail("the filling write was not sent")
        }
        XCTAssertEqual(a.core.sessions[b.key].flatMap { a.core.links[$0.link]?.writable }, false)
    }

    /// The fetch is started in the same instant a write crossed the mark,
    /// before the shell could say the bytes went out.
    func testAFetchStartedBehindAFullLinkIsServed() {
        let (sim, a, b) = pair()
        fill(sim, a, toward: b)
        let request = sim.request(fetch("vol"), on: a)
        sim.run(for: .zero)
        XCTAssertNil(sim.result(of: request, on: a), "it waits; it does not answer empty")

        sim.run(until: { sim.result(of: request, on: a) != nil })
        let volume = sim.result(of: request, on: a)?.volume
        XCTAssertEqual(volume?.entries.count, 4)
        XCTAssertEqual(volume?.servedBy, b.peer)
        XCTAssertTrue(a.core.writabilityWaiters.isEmpty)
        XCTAssertTrue(a.core.volumeFetches.isEmpty)
    }

    func testABundleFetchBehindAFullLinkIsSent() {
        let (sim, a, b) = pair()
        guard let session = a.core.authenticatedPeer(for: b.peer) else { return XCTFail("no session") }
        fill(sim, a, toward: b)
        let request = sim.request(.fetchVolumeBundle(rootCID: "vol", from: [session]), on: a)
        sim.run(until: { sim.result(of: request, on: a) != nil })
        guard case .volumeBundle(let answer) = sim.result(of: request, on: a) else {
            return XCTFail("no bundle answer")
        }
        XCTAssertNotEqual(answer.failure, .notSent)
    }

    func testAFetchWaitingOnALinkThatClosesEndsEmpty() {
        let (sim, a, b) = pair()
        fill(sim, a, toward: b)
        let request = sim.request(fetch("vol"), on: a)
        sim.run(for: .zero)
        sim.stop(b)
        sim.run(until: { sim.result(of: request, on: a) != nil })
        XCTAssertEqual(sim.result(of: request, on: a)?.volume?.entries, [:])
        XCTAssertTrue(a.core.writabilityWaiters.isEmpty)
        XCTAssertTrue(a.core.volumeFetches.isEmpty)
    }

    /// A link that never drains is given `requestTimeout`, like a peer that
    /// never answers.
    func testAFetchWaitingOnALinkThatStaysFullTimesOut() {
        let sim = Simulation()
        let node = sim.node()
        let peer = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        XCTAssertTrue(peer.authenticate())
        sim.run(for: .seconds(1))
        sim.setRawStalled(true, peer.connection, at: node)
        sim.saturate(node, toward: peer.id)

        let request = sim.request(fetch("vol"), on: node)
        sim.run(for: node.core.config.requestTimeout - .seconds(1))
        XCTAssertNil(sim.result(of: request, on: node))
        XCTAssertFalse(peer.isClosed)
        sim.run(for: .seconds(2))
        XCTAssertEqual(sim.result(of: request, on: node)?.volume?.entries, [:])
        XCTAssertFalse(peer.isClosed, "the wait ended on its deadline, not on the link")
        XCTAssertTrue(node.core.writabilityWaiters.isEmpty)
        XCTAssertTrue(node.core.volumeFetches.isEmpty)
    }

    func testCancellingAWaitingFetchLeavesNothingBehind() {
        let (sim, a, b) = pair()
        fill(sim, a, toward: b)
        let request = sim.request(fetch("vol"), on: a)
        sim.run(for: .zero)
        sim.cancel(request, on: a)
        XCTAssertEqual(sim.result(of: request, on: a)?.volume?.entries, [:])
        XCTAssertTrue(a.core.writabilityWaiters.isEmpty)
        XCTAssertTrue(a.core.volumeFetches.isEmpty)
    }
}
