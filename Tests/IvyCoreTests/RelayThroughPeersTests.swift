import Foundation
import XCTest
@testable import IvyCore
import IvySimulation
import Tally

/// A node asks an ordinary peer it was told relays for a route, with no
/// carrier configured: how two nodes that cannot dial each other meet.
final class RelayThroughPeersTests: XCTestCase {
    /// `a` and `b` cannot reach each other, and each holds an ordinary
    /// session with every node of `relays`.
    private func pair(
        _ sim: Simulation, through relays: [Simulation.Node]
    ) -> (a: Simulation.Node, b: Simulation.Node) {
        let a = sim.relayNode()
        let b = sim.relayNode()
        sim.setPartitioned(true, a, b)
        for relay in relays {
            sim.connect(a, relay)
            sim.connect(b, relay)
        }
        sim.run(for: .milliseconds(100))
        return (a, b)
    }

    private func mark(_ sim: Simulation, _ peer: Simulation.Node, on node: Simulation.Node, _ relays: Bool = true) {
        sim.send(.command(.setRelaying(peer.peer, relays)), to: node)
    }

    func testAPeerSaidToRelayIsAskedWhenADialFails() {
        let sim = Simulation()
        let r = sim.relayNode(relayEnabled: true)
        let (a, b) = pair(sim, through: [r])

        // Not told of any, the node has no one to ask, and asks no one.
        XCTAssertEqual(sim.await(.connect(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
        XCTAssertTrue(a.core.connectedPeers.contains(r.peer))

        mark(sim, r, on: a)
        XCTAssertEqual(sim.await(.connect(b.endpoint), on: a), .connect(.connected))
        sim.run(until: { b.core.connectedPeers.contains(a.peer) })
        guard case .relayed(let carrier, let routeID)? = a.core.authenticatedPeer(for: b.peer)?.route else {
            return XCTFail("no relayed session")
        }
        XCTAssertEqual(carrier, r.key)
        let route = AuthenticatedRoute.relayed(carrier: r.key, routeID: routeID)

        XCTAssertEqual(
            sim.await(.send(to: b.peer, topic: "ab", payload: Data([1])), on: a)?.sent,
            .enqueued(endpoint: b.peer, route: route))
        XCTAssertEqual(
            sim.await(.send(to: a.peer, topic: "ba", payload: Data([2])), on: b)?.sent,
            .enqueued(endpoint: a.peer, route: route))
        sim.run(until: { a.received.count == 1 && b.received.count == 1 })
        XCTAssertEqual(b.received.map(\.message.payload), [Data([1])])
        XCTAssertEqual(a.received.map(\.message.payload), [Data([2])])

        // The peer that relays is still a peer like any other.
        XCTAssertEqual(a.core.authenticatedPeer(for: r.peer)?.role, .endpoint)
        XCTAssertEqual(
            sim.await(.send(to: r.peer, topic: "ar", payload: Data([3])), on: a)?.sent,
            .enqueued(endpoint: r.peer, route: .direct))
        sim.run(until: { r.received.count == 1 })
        XCTAssertEqual(r.received.map(\.message.payload), [Data([3])])
        for node in [a, b, r] {
            for other in [a, b, r] where other.peer != node.peer {
                XCTAssertEqual(node.ledger.violations(of: other.peer), 0)
            }
        }
    }

    func testARelayedSessionCanBeAskedForOutright() {
        let sim = Simulation()
        let r = sim.relayNode(relayEnabled: true)
        let (a, b) = pair(sim, through: [r])
        mark(sim, r, on: a)
        XCTAssertNotNil(sim.connectRelayed(a, b))
    }

    func testAPeerWithNoSessionToTheTargetSaysSoAndTheNextIsAsked() {
        let sim = Simulation()
        let relays = (0..<3).map { _ in sim.relayNode(relayEnabled: true) }
        let a = sim.relayNode()
        let b = sim.relayNode()
        sim.setPartitioned(true, a, b)
        for relay in relays { sim.connect(a, relay) }
        // Only one of them knows the target, whichever the node asks first.
        let knows = relays.sorted { $0.key < $1.key }.last!
        sim.connect(b, knows)
        sim.run(for: .milliseconds(100))
        for relay in relays { mark(sim, relay, on: a) }

        let started = sim.now
        XCTAssertEqual(sim.await(.connect(b.endpoint), on: a), .connect(.connected))
        guard case .relayed(let carrier, _)? = a.core.authenticatedPeer(for: b.peer)?.route else {
            return XCTFail("no relayed session")
        }
        XCTAssertEqual(carrier, knows.key)
        // The two that could not help were not waited for.
        XCTAssertLessThan(sim.now - started, .seconds(15))
        for relay in relays {
            XCTAssertTrue(a.core.connectedPeers.contains(relay.peer))
            XCTAssertEqual(relay.ledger.violations(of: a.peer), 0)
        }
    }

    func testWhatWasSaidOfAPeerIsForgottenWithItsSession() {
        let sim = Simulation()
        let r = sim.relayNode(relayEnabled: true)
        let (a, b) = pair(sim, through: [r])

        // Said of a peer the node has no session with, it is not kept.
        let stranger = sim.relayNode(relayEnabled: true)
        mark(sim, stranger, on: a)
        XCTAssertTrue(a.core.relayingPeers.isEmpty)

        mark(sim, r, on: a)
        XCTAssertEqual(a.core.relayingPeers, [r.key])
        mark(sim, r, on: a, false)
        XCTAssertTrue(a.core.relayingPeers.isEmpty)
        XCTAssertEqual(sim.await(.connect(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))

        mark(sim, r, on: a)
        sim.send(.command(.disconnect(r.peer)), to: a)
        sim.run(for: .milliseconds(100))
        XCTAssertTrue(a.core.relayingPeers.isEmpty)
    }

    /// Why a peer is asked only if it was said to relay.
    func testAPeerThatDoesNotRelayEndsTheSessionOfOneThatAsks() {
        let sim = Simulation()
        let n = sim.relayNode(relayEnabled: false)
        let (a, b) = pair(sim, through: [n])
        mark(sim, n, on: a)
        XCTAssertEqual(sim.await(.connect(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
        sim.run(for: .milliseconds(200))
        XCTAssertFalse(n.core.connectedPeers.contains(a.peer))
    }

    func testOnlyAFewPeersAreAskedForOneConnect() {
        let sim = Simulation()
        let relays = (0..<IvyCore.maxRelayingPeersAsked + 2).map { _ in sim.relayNode(relayEnabled: true) }
        let a = sim.relayNode()
        let b = sim.relayNode()
        sim.setPartitioned(true, a, b)
        for relay in relays {
            sim.connect(a, relay)
            mark(sim, relay, on: a)
        }
        // The target is known only to one the node does not get to.
        sim.connect(b, relays.sorted { $0.key < $1.key }.last!)
        sim.run(for: .milliseconds(100))
        XCTAssertEqual(sim.await(.connect(b.endpoint), on: a), .connect(.failed(.noRelayAvailable)))
    }
}
