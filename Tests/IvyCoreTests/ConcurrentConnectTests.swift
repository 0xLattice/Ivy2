import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// A fetch reaching for a provider waits for a connect attempt already under
/// way to the same peer, and takes its outcome.
final class ConcurrentConnectTests: XCTestCase {
    private func fetch(_ root: String) -> Request {
        .fetchVolume(rootCID: root, maximumArchiveBytes: .max, maximumEntries: .max)
    }

    private func hint(_ node: Simulation.Node, root: String, provider: Simulation.Node, sim: Simulation) {
        node.core.storeProviderHint(
            rootCID: root,
            peer: provider.peer,
            endpoint: provider.endpoint,
            expiresAt: sim.unixSeconds + 600,
            source: provider.peer)
    }

    /// Two fetches for one root whose provider is known but not connected.
    /// The second used to find the provider "not connected" while the first
    /// was still dialling it, and return empty.
    func testFetchesThatNeedTheSameProviderAreBothServed() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        b.volumes["vol"] = volumeEntries(root: "vol", members: 3, bytesEach: 1_000)
        hint(a, root: "vol", provider: b, sim: sim)

        let first = sim.request(fetch("vol"), on: a)
        let second = sim.request(fetch("vol"), on: a)
        let third = sim.request(fetch("vol"), on: a)
        // Each fetch reads local storage first, then reaches for the provider.
        sim.run(for: .milliseconds(1))
        XCTAssertEqual(a.core.connectFollowers[b.key]?.count, 2, "the later fetches wait on the first dial")
        sim.run(until: { [first, second, third].allSatisfy { sim.result(of: $0, on: a) != nil } })

        for request in [first, second, third] {
            let volume = sim.result(of: request, on: a)?.volume
            XCTAssertEqual(volume?.entries.count, 4)
            XCTAssertEqual(volume?.servedBy, b.peer)
        }
        XCTAssertEqual(sim.trace.filter { entry in
            if case .dial = entry.effect { return entry.node == a.id }
            return false
        }.count, 1, "one dial serves all three")
        XCTAssertTrue(a.core.connectFollowers.isEmpty)
        XCTAssertEqual(a.core.diagnostics.outgoingDials, 0)
    }

    func testFollowersEndWhenTheAttemptTheyFollowFails() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        b.volumes["vol"] = volumeEntries(root: "vol", members: 1, bytesEach: 100)
        hint(a, root: "vol", provider: b, sim: sim)
        sim.setPartitioned(true, a, b)

        let first = sim.request(fetch("vol"), on: a)
        let second = sim.request(fetch("vol"), on: a)
        sim.run(until: { sim.result(of: first, on: a) != nil && sim.result(of: second, on: a) != nil })

        XCTAssertEqual(sim.result(of: first, on: a)?.volume?.entries, [:])
        XCTAssertEqual(sim.result(of: second, on: a)?.volume?.entries, [:])
        XCTAssertTrue(a.core.connectFollowers.isEmpty)
        XCTAssertTrue(a.core.connectOps.isEmpty)
        XCTAssertEqual(a.core.diagnostics.outgoingDials, 0)
    }

    func testCancellingAFollowerLeavesTheAttemptAndTheOthers() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        b.volumes["vol"] = volumeEntries(root: "vol", members: 1, bytesEach: 100)
        hint(a, root: "vol", provider: b, sim: sim)

        let first = sim.request(fetch("vol"), on: a)
        let second = sim.request(fetch("vol"), on: a)
        sim.run(for: .milliseconds(1))
        XCTAssertEqual(a.core.connectFollowers[b.key]?.count, 1)
        sim.cancel(second, on: a)
        XCTAssertEqual(sim.result(of: second, on: a)?.volume?.entries, [:])
        XCTAssertNil(a.core.connectFollowers[b.key])
        sim.run(until: { sim.result(of: first, on: a) != nil })
        XCTAssertEqual(sim.result(of: first, on: a)?.volume?.servedBy, b.peer)
    }

    /// A caller's own connect is still told at once that one is in progress.
    func testACallersConnectDoesNotFollow() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        let first = sim.request(.connect(b.endpoint), on: a)
        let second = sim.request(.connect(b.endpoint), on: a)
        XCTAssertEqual(sim.result(of: second, on: a), .connect(.failed(.connectionInProgress)))
        sim.run(until: { sim.result(of: first, on: a) != nil })
        XCTAssertEqual(sim.result(of: first, on: a), .connect(.connected))
    }

    func testStopEndsFollowers() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        hint(a, root: "vol", provider: b, sim: sim)
        let first = sim.request(fetch("vol"), on: a)
        let second = sim.request(fetch("vol"), on: a)
        sim.run(for: .milliseconds(1))
        XCTAssertEqual(a.core.connectFollowers[b.key]?.count, 1)
        sim.stop(a)
        XCTAssertNotNil(sim.result(of: first, on: a))
        XCTAssertNotNil(sim.result(of: second, on: a))
        XCTAssertTrue(a.core.connectFollowers.isEmpty)
        XCTAssertTrue(a.core.connectOps.isEmpty)
    }
}
