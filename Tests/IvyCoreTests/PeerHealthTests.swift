import Foundation
import XCTest
@testable import IvyCore
import IvySimulation
import Tally

/// Peer health monitor: 15.0.1's `PeerHealthMonitor`, now core state driven
/// by the `.health` deadline. The peer is a raw connection, so the test
/// decides which pings are answered.
final class PeerHealthTests: XCTestCase {
    private func pings(_ messages: [Message]) -> [UInt64] {
        messages.compactMap { message in
            if case .ping(let nonce) = message { return nonce }
            return nil
        }
    }

    /// ping, exact pong, and activity reset use deterministic time
    func testPingPongAndActivity() throws {
        let sim = Simulation()
        let node = sim.node(health: .default)
        let peer = WireRawPeer(sim, to: node, label: "health-peer")
        XCTAssertTrue(peer.handshake())
        XCTAssertEqual(node.core.health[peer.id]?.sessionID, peer.sessionID)

        // Silence shorter than the keepalive interval draws no ping.
        sim.run(for: .seconds(59))
        XCTAssertEqual(pings(peer.takeMessages()), [])
        sim.run(for: .seconds(1))
        let first = try XCTUnwrap(pings(peer.takeMessages()).first)
        XCTAssertEqual(node.core.health[peer.id]?.pendingPingNonce, first)

        // A pong for another nonce neither clears the ping nor counts as activity.
        peer.send(.pong(nonce: first &+ 999))
        XCTAssertEqual(node.core.health[peer.id]?.pendingPingNonce, first)
        sim.run(for: .seconds(60))
        let second = try XCTUnwrap(pings(peer.takeMessages()).first)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(node.core.health[peer.id]?.missedPongs, 1)
        XCTAssertEqual(node.core.health[peer.id]?.pendingPingNonce, second)

        peer.send(.pong(nonce: second))
        XCTAssertEqual(node.core.health[peer.id]?.pendingPingNonce, nil)
        XCTAssertEqual(node.core.health[peer.id]?.missedPongs, 0)

        sim.run(for: .seconds(60))
        XCTAssertEqual(pings(peer.takeMessages()).count, 1)
        XCTAssertNotNil(node.core.health[peer.id]?.pendingPingNonce)
        // Any record on the session is activity.
        peer.send(.peerMessage(topic: "alive", payload: Data([1])))
        XCTAssertEqual(node.core.health[peer.id]?.pendingPingNonce, nil)
        XCTAssertEqual(node.core.health[peer.id]?.missedPongs, 0)
        XCTAssertEqual(node.core.health[peer.id]?.lastActivity, sim.now)
        XCTAssertEqual(node.disconnected, [])
    }

    /// misses evict at the limit and replacement starts clean
    func testMissesAndReplacement() {
        let sim = Simulation()
        let node = sim.node(health: PeerHealthConfig(
            keepaliveInterval: .seconds(60),
            staleTimeout: .seconds(1_000),
            maxMissedPongs: 3))
        let peer = WireRawPeer(sim, to: node, label: "health-missed-peer")
        XCTAssertTrue(peer.handshake())

        for cycle in 0..<3 {
            sim.run(for: .seconds(60))
            XCTAssertEqual(pings(peer.takeMessages()).count, 1, "cycle \(cycle)")
            XCTAssertEqual(node.core.health[peer.id]?.missedPongs, cycle, "cycle \(cycle)")
            XCTAssertEqual(node.disconnected, [], "cycle \(cycle)")
        }
        sim.run(for: .seconds(60))
        XCTAssertEqual(pings(peer.takeMessages()), [])
        XCTAssertEqual(node.disconnected, [peer.id])
        XCTAssertTrue(sim.nodeClosedRaw(peer.connection))
        XCTAssertNil(node.core.health[peer.id])
        XCTAssertEqual(node.core.connectedPeers, [])

        let replacement = WireRawPeer(sim, to: node, label: "health-missed-peer", attempt: 1)
        XCTAssertTrue(replacement.handshake())
        XCTAssertEqual(node.core.health[peer.id]?.sessionID, replacement.sessionID)
        XCTAssertEqual(node.core.health[peer.id]?.pendingPingNonce, nil)
        XCTAssertEqual(node.core.health[peer.id]?.missedPongs, 0)
    }

    /// default stale timeout is inclusive
    func testDefaultStaleTimeout() {
        let sim = Simulation()
        let node = sim.node(health: .default)
        let peer = WireRawPeer(sim, to: node, label: "health-stale-peer")
        XCTAssertTrue(peer.handshake())

        sim.run(for: .seconds(180) - .milliseconds(1))
        // Two unanswered pings are below the miss limit: the peer is still connected.
        XCTAssertEqual(pings(peer.takeMessages()).count, 2)
        XCTAssertEqual(node.core.health[peer.id]?.missedPongs, 1)
        XCTAssertEqual(node.disconnected, [])

        sim.run(for: .milliseconds(1))
        XCTAssertEqual(node.disconnected, [peer.id])
        XCTAssertTrue(sim.nodeClosedRaw(peer.connection))
        XCTAssertNil(node.core.health[peer.id])
    }

    /// delayed removal cannot erase a replacement session
    func testRemovalIsSessionScoped() throws {
        let sim = Simulation()
        let node = sim.node(health: .default)
        let old = WireRawPeer(sim, to: node, label: "health-replacement-peer", host: "9.1.0.1")
        XCTAssertTrue(old.handshake())
        sim.run(for: .seconds(60))
        XCTAssertNotNil(node.core.health[old.id]?.pendingPingNonce)

        // A second session for the same identity replaces the first only
        // when its session ID is the smaller, so try until one does.
        var replacement: WireRawPeer?
        for attempt in 1...32 {
            let candidate = WireRawPeer(
                sim, to: node, label: "health-replacement-peer", host: "9.2.0.1", attempt: attempt)
            if candidate.handshake() {
                replacement = candidate
                break
            }
            XCTAssertTrue(sim.nodeClosedRaw(candidate.connection), "attempt \(attempt)")
            XCTAssertEqual(node.core.health[old.id]?.sessionID, old.sessionID, "attempt \(attempt)")
        }
        let current = try XCTUnwrap(replacement)

        // Removing the replaced session's link left the replacement's entry alone.
        XCTAssertTrue(sim.nodeClosedRaw(old.connection))
        XCTAssertNotEqual(current.sessionID, old.sessionID)
        XCTAssertEqual(node.core.health[old.id]?.sessionID, current.sessionID)
        XCTAssertEqual(node.core.health[old.id]?.pendingPingNonce, nil)
        XCTAssertEqual(node.core.health[old.id]?.lastActivity, sim.now)
        XCTAssertEqual(node.core.health.count, 1)
        XCTAssertEqual(node.disconnected, [])
    }

    /// stopping monitoring cancels its scheduled sweep
    func testStopCancelsScheduledSweep() {
        let sim = Simulation()
        let node = sim.node(health: PeerHealthConfig(
            keepaliveInterval: .milliseconds(1),
            staleTimeout: .seconds(1),
            maxMissedPongs: 1))
        let peer = WireRawPeer(sim, to: node, label: "health-timer-stop-peer")
        XCTAssertTrue(peer.handshake())

        sim.stop(node)
        let effectsAtStop = sim.trace.count
        sim.run(for: .milliseconds(10))

        XCTAssertEqual(pings(peer.takeMessages()), [])
        XCTAssertEqual(sim.trace.count, effectsAtStop)
        XCTAssertEqual(node.core.diagnostics.deadlines, 0)
        XCTAssertTrue(node.core.health.isEmpty)
    }

    /// Without the stop, that sweep runs: the control for the test above.
    func testScheduledSweepPingsAfterTheKeepaliveInterval() {
        let sim = Simulation()
        let node = sim.node(health: PeerHealthConfig(
            keepaliveInterval: .milliseconds(1),
            staleTimeout: .seconds(1),
            maxMissedPongs: 1))
        let peer = WireRawPeer(sim, to: node, label: "health-timer-peer")
        XCTAssertTrue(peer.handshake())

        sim.run(for: .milliseconds(1))
        XCTAssertEqual(pings(peer.takeMessages()).count, 1)
        // One miss is the limit here, so the next sweep ends the session.
        sim.run(for: .milliseconds(1))
        XCTAssertEqual(node.disconnected, [peer.id])
    }

    /// Two live nodes answer each other's pings, so an idle session is kept.
    func testKeepaliveHoldsAnIdleSessionBetweenTwoNodes() {
        let sim = Simulation()
        let a = sim.node(health: .default)
        let b = sim.node(health: .default)
        sim.connect(a, b)

        sim.run(for: .seconds(900))

        XCTAssertEqual(a.core.connectedPeers, [b.peer])
        XCTAssertEqual(b.core.connectedPeers, [a.peer])
        XCTAssertEqual(a.disconnected, [])
        XCTAssertEqual(b.disconnected, [])
        XCTAssertEqual(a.core.health[b.peer]?.missedPongs, 0)
        XCTAssertEqual(b.core.health[a.peer]?.missedPongs, 0)
        let pingsSent = sim.trace.filter { entry in
            if case .write = entry.effect { return entry.time >= .seconds(60) }
            return false
        }
        XCTAssertFalse(pingsSent.isEmpty)
    }
}
