import Foundation
import XCTest
@testable import IvyCore
import IvySimulation
import Tally

/// Connecting over a connection the shell already holds, in place of one
/// the core would have asked it to dial.
final class ConnectOverTests: XCTestCase {
    func testSessionOverASuppliedConnection() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        let (request, connection) = sim.requestConnectOver(from: a, to: b)
        sim.run(until: { sim.result(of: request, on: a) != nil && !b.core.connectedPeers.isEmpty })

        XCTAssertEqual(sim.result(of: request, on: a), .connect(.connected))
        XCTAssertEqual(a.core.connectedPeers, [b.peer])
        XCTAssertEqual(b.core.connectedPeers, [a.peer])
        XCTAssertTrue(sim.isOpen(connection, at: a))
        XCTAssertEqual(a.core.diagnostics.outgoingDials, 0)
        // Nothing was dialled: the connection was the caller's.
        XCTAssertFalse(sim.trace.contains { entry in
            if case .dial = entry.effect { return true }
            return false
        })

        let sent = sim.await(.send(to: b.peer, topic: "t", payload: Data([1])), on: a)
        XCTAssertEqual(sent?.sent, .enqueued(endpoint: b.peer, route: .direct))
        sim.run(until: { !b.received.isEmpty })
        XCTAssertEqual(b.received.first?.message.topic, "t")
    }

    func testASuppliedConnectionWithNoObservedHostIsRefusedAndClosed() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        let (request, connection) = sim.requestConnectOver(from: a, to: b, observedHost: .some(nil))

        XCTAssertEqual(sim.result(of: request, on: a), .connect(.failed(.streamHasNoObservedHost)))
        XCTAssertFalse(sim.isOpen(connection, at: a))
        XCTAssertEqual(a.core.diagnostics.outgoingDials, 0)
        sim.run(for: .seconds(1))
        XCTAssertEqual(a.core.connectedPeers, [])
    }

    func testASuppliedConnectionIsClosedWhenTheNodeIsNotRunning() {
        let sim = Simulation()
        let a = sim.node(start: false)
        let b = sim.node()
        let (request, connection) = sim.requestConnectOver(from: a, to: b)

        XCTAssertEqual(sim.result(of: request, on: a), .connect(.failed(.notRunning)))
        XCTAssertFalse(sim.isOpen(connection, at: a))
    }

    func testASuppliedConnectionToAPeerAlreadyConnectedIsClosed() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        sim.connect(a, b)
        let session = sim.session(a, to: b)

        let (request, connection) = sim.requestConnectOver(from: a, to: b)
        sim.run(for: .seconds(1))
        XCTAssertEqual(sim.result(of: request, on: a), .connect(.connected))
        XCTAssertFalse(sim.isOpen(connection, at: a), "the surplus connection is closed")
        XCTAssertEqual(sim.session(a, to: b), session, "the existing session is untouched")
    }

    func testASuppliedConnectionHasNoFallback() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        // The far end never answers the handshake: it is not running.
        sim.stop(b)
        let (request, connection) = sim.requestConnectOver(from: a, to: b)
        sim.run(for: .seconds(40))

        XCTAssertEqual(sim.result(of: request, on: a), .connect(.failed(.identityVerificationFailed)))
        XCTAssertFalse(sim.isOpen(connection, at: a))
        XCTAssertFalse(sim.trace.contains { entry in
            if case .dial = entry.effect { return entry.node == a.id }
            return false
        }, "no dial and no carrier is tried in its place")
        XCTAssertEqual(a.core.diagnostics.outgoingDials, 0)
        XCTAssertEqual(a.core.diagnostics.pendingSessions, 0)
    }

    func testCancellingClosesTheSuppliedConnection() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        sim.stop(b)
        let (request, connection) = sim.requestConnectOver(from: a, to: b)
        sim.cancel(request, on: a)

        XCTAssertEqual(sim.result(of: request, on: a), .connect(.cancelled))
        XCTAssertFalse(sim.isOpen(connection, at: a))
        XCTAssertEqual(a.core.diagnostics.outgoingDials, 0)
        XCTAssertEqual(a.core.diagnostics.pendingSessions, 0)
    }
}
