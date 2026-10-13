import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Two peers that reached each other through a carrier move to a direct
/// connection when one is supplied: signalling over the relayed session is
/// how two browsers open a data channel to each other.
final class DirectUpgradeTests: XCTestCase {
    /// A carrier with two endpoints that cannot dial each other, each in a
    /// netgroup of its own.
    private func triangle(seed: UInt64 = 1) -> (Simulation, c: Simulation.Node, a: Simulation.Node, b: Simulation.Node) {
        let sim = Simulation(seed: seed)
        let c = sim.node(host: "9.1.0.1", relayEnabled: true)
        let b = sim.node(host: "9.2.0.1")
        let a = sim.node(host: "9.3.0.1", carriers: [c.endpoint])
        sim.setPartitioned(true, a, b)
        sim.connect(b, c)
        sim.attach([a, b], to: c)
        return (sim, c, a, b)
    }

    private func relayed(seed: UInt64 = 1) -> (Simulation, c: Simulation.Node, a: Simulation.Node, b: Simulation.Node) {
        let (sim, c, a, b) = triangle(seed: seed)
        sim.connectRelayed(a, b)
        return (sim, c, a, b)
    }

    private func route(_ node: Simulation.Node, to peer: Simulation.Node) -> AuthenticatedRoute? {
        node.core.sessions[peer.key].flatMap { node.core.links[$0.link]?.route }
    }

    func testASuppliedConnectionReplacesTheRelayedSession() {
        let (sim, c, a, b) = relayed()
        guard case .relayed? = route(a, to: b), case .relayed? = route(b, to: a) else {
            return XCTFail("the session did not start relayed")
        }
        let before = (a: a.core.sessions[b.key]?.sessionID, b: b.core.sessions[a.key]?.sessionID)

        let (request, connection) = sim.requestConnectOver(from: a, to: b)
        sim.run(until: { sim.result(of: request, on: a) != nil })
        sim.run(for: .seconds(1))

        XCTAssertEqual(sim.result(of: request, on: a), .connect(.connected))
        XCTAssertEqual(route(a, to: b), .direct)
        XCTAssertEqual(route(b, to: a), .direct)
        XCTAssertTrue(sim.isOpen(connection, at: a))
        XCTAssertNotEqual(a.core.sessions[b.key]?.sessionID, before.a)
        XCTAssertEqual(a.core.sessions[b.key]?.sessionID, b.core.sessions[a.key]?.sessionID)
        // Neither application saw its peer go: one session took the other's place.
        XCTAssertFalse(a.disconnected.contains(b.peer))
        XCTAssertFalse(b.disconnected.contains(a.peer))
        // Each application is told of the session that took over.
        XCTAssertEqual(a.connected.last { $0.id == b.peer }?.route, .direct)
        XCTAssertEqual(b.connected.last { $0.id == a.peer }?.route, .direct)
        // The carrier's route is retired, and it keeps both of its sessions.
        XCTAssertTrue(c.core.installedRoutes.isEmpty)
        XCTAssertEqual(c.core.peerConnectionCount, 2)

        let sent = sim.await(.send(to: b.peer, topic: "t", payload: Data([7])), on: a)?.sent
        XCTAssertEqual(sent, .enqueued(endpoint: b.peer, route: .direct))
        let back = sim.await(.send(to: a.peer, topic: "u", payload: Data([8])), on: b)?.sent
        XCTAssertEqual(back, .enqueued(endpoint: a.peer, route: .direct))
        sim.run(until: { b.received.contains { $0.message.topic == "t" } && a.received.contains { $0.message.topic == "u" } })
        XCTAssertTrue(b.received.contains { $0.message.topic == "t" })
        XCTAssertTrue(a.received.contains { $0.message.topic == "u" })
    }

    /// A direct connection that never completes its handshake costs nothing.
    func testAFailedUpgradeLeavesTheRelayedSession() {
        let (sim, _, a, b) = relayed()
        let session = a.core.sessions[b.key]?.sessionID
        // The stream reaches somebody else, who will not answer as `b`.
        let other = sim.node(host: "9.4.0.1")
        let (request, connection) = sim.requestConnectOver(from: a, to: other, expecting: b.endpoint)
        sim.run(until: { sim.result(of: request, on: a) != nil })

        // The peer is connected, as `connect` promises, but still through
        // the carrier: the caller reads the session's route to tell.
        XCTAssertEqual(sim.result(of: request, on: a), .connect(.connected))
        XCTAssertFalse(sim.isOpen(connection, at: a))
        guard case .relayed? = route(a, to: b) else { return XCTFail("the relayed session was lost") }
        XCTAssertEqual(a.core.sessions[b.key]?.sessionID, session)
        XCTAssertFalse(a.disconnected.contains(b.peer))
        XCTAssertFalse(b.disconnected.contains(a.peer))
        XCTAssertEqual(a.core.diagnostics.outgoingDials, 0)
        let sent = sim.await(.send(to: b.peer, topic: "t", payload: Data([1])), on: a)?.sent
        guard case .enqueued(_, .relayed)? = sent else { return XCTFail("the relayed session was lost") }
    }

    /// The initiator is done first and closes the route. When the carrier is
    /// the faster path, that close reaches the responder before the last
    /// record of the handshake does. The responder must not report its peer
    /// gone in between.
    func testTheRouteClosingAheadOfTheHandshakeIsNotADisconnect() {
        for seed: UInt64 in 1...12 {
            let (sim, _, a, b) = relayed(seed: seed)
            let (request, connection) = sim.requestConnectOver(from: a, to: b)
            sim.delayWrites(by: .milliseconds(200), on: connection, at: a)
            sim.run(until: { sim.result(of: request, on: a) != nil })
            // The route's close has arrived and the handshake's end has not.
            sim.run(for: .milliseconds(100))
            XCTAssertEqual(route(a, to: b), .direct, "seed \(seed)")
            XCTAssertNil(b.core.sessions[a.key], "seed \(seed): the test did not reach the gap")
            XCTAssertEqual(b.disconnected, [], "seed \(seed)")

            sim.run(for: .seconds(1))
            XCTAssertEqual(route(b, to: a), .direct, "seed \(seed)")
            XCTAssertEqual(b.disconnected, [], "seed \(seed)")
            XCTAssertEqual(a.disconnected, [], "seed \(seed)")
            XCTAssertTrue(b.core.heldDisconnects.isEmpty)
        }
    }

    /// A disconnect that was held is reported once the handshake it waited
    /// on ends without a session.
    func testAHeldDisconnectIsReportedWhenTheHandshakeFails() {
        let (sim, _, a, b) = relayed()
        let (_, connection) = sim.requestConnectOver(from: a, to: b)
        sim.delayWrites(by: .milliseconds(200), on: connection, at: a)
        sim.run(until: { b.core.hasVerifiedResponder(for: a.key) })
        // `a` gives up on `b` altogether: the route closes at once and the
        // direct connection after it.
        sim.send(.command(.disconnect(b.peer)), to: a)
        sim.run(for: .milliseconds(100))
        XCTAssertNil(b.core.sessions[a.key])
        sim.run(for: .seconds(2))
        XCTAssertEqual(b.disconnected, [a.peer])
        XCTAssertNil(b.core.sessions[a.key])
        XCTAssertTrue(b.core.heldDisconnects.isEmpty)
    }

    /// Whichever session has the smaller identifier, the direct one stays.
    func testTheDirectSessionWinsWhateverTheIdentifiers() {
        var relayedWasSmaller = 0
        var directWasSmaller = 0
        for seed in 1...24 {
            let (sim, _, a, b) = relayed(seed: UInt64(seed))
            guard let old = a.core.sessions[b.key]?.sessionID else { return XCTFail("no session") }
            let (request, _) = sim.requestConnectOver(from: a, to: b)
            sim.run(until: { sim.result(of: request, on: a) != nil })
            sim.run(for: .seconds(1))
            guard let new = a.core.sessions[b.key]?.sessionID else { return XCTFail("the session was lost") }
            if min(old, new) == old { relayedWasSmaller += 1 } else { directWasSmaller += 1 }
            XCTAssertEqual(route(a, to: b), .direct)
            XCTAssertEqual(route(b, to: a), .direct)
        }
        XCTAssertGreaterThan(relayedWasSmaller, 0, "both orders must have been tried")
        XCTAssertGreaterThan(directWasSmaller, 0, "both orders must have been tried")
    }

    /// A relayed session offered while a direct one is live is the one dropped.
    func testARelayedSessionDoesNotReplaceADirectOne() {
        for seed in 1...12 {
            let (sim, _, a, b) = triangle(seed: UInt64(seed))
            let (opened, _) = sim.requestConnectOver(from: a, to: b)
            sim.run(until: { sim.result(of: opened, on: a) != nil })
            sim.run(for: .seconds(1))
            XCTAssertEqual(route(a, to: b), .direct)
            let direct = a.core.sessions[b.key]?.sessionID
            _ = sim.await(
                .connectViaRelay(PeerEndpoint(publicKey: b.key.hex, host: "relay", port: 0)), on: a)
            sim.run(for: .seconds(1))
            XCTAssertEqual(route(a, to: b), .direct)
            XCTAssertEqual(route(b, to: a), .direct)
            XCTAssertEqual(a.core.sessions[b.key]?.sessionID, direct)
        }
    }
}
