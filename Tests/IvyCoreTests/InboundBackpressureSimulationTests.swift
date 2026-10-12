import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Ports of 15.0.1's InboundBackpressureTests. The held consumer is now an
/// application that has not answered `deliver`; the byte budgets are the
/// link's `charged` and the core's `inboundBytesUsed`.
final class InboundBackpressureSimulationTests: XCTestCase {
    private let maxFrame: UInt32 = 128 * 1024

    private func server(_ sim: Simulation, maxInboundBufferedBytes: Int? = nil) -> Simulation.Node {
        sim.node(
            maxConnectionsPerNetgroup: 8,
            maxInboundBufferedBytes: maxInboundBufferedBytes ?? IvyConfig.defaultMaxInboundBufferedBytes,
            protocolMaxFrameSize: maxFrame)
    }

    private func client(_ sim: Simulation, _ node: Simulation.Node, index: Int) -> HandPeer {
        let peer = HandPeer(sim, to: node, index: index, host: "10.\(index).0.1")
        XCTAssertTrue(peer.authenticate())
        return peer
    }

    private func topic(_ index: Int) -> String {
        String(format: "frame-%02d", index)
    }

    /// Signed records of exactly the maximum frame size, one per index.
    private func frames(_ indices: Range<Int>, from peer: HandPeer) -> [Data] {
        let empty = peer.record(.peerMessage(topic: topic(0), payload: Data()), sequence: 1).count
        return indices.map { index in
            let record = peer.record(.peerMessage(
                topic: topic(index),
                payload: Data(repeating: UInt8(truncatingIfNeeded: index), count: Int(maxFrame) - empty)))
            XCTAssertEqual(record.count, Int(maxFrame))
            return record
        }
    }

    // "a held consumer receives every frame, in order, once released"
    func testHeldConsumerReceivesEveryFrame() {
        let sim = Simulation()
        let node = server(sim)
        let peer = client(sim, node, index: 1)
        node.holdsDeliveries = true

        // One write of six maximum frames while the application holds the first.
        peer.writeFrames(frames(0..<6, from: peer))
        XCTAssertEqual(sim.topics(node, from: peer.id), [topic(0)])
        XCTAssertFalse(peer.isClosed)

        sim.openDeliveries(node)
        sim.run(until: { node.received.count == 6 })
        XCTAssertEqual(sim.topics(node, from: peer.id), (0..<6).map(topic))
        XCTAssertFalse(peer.isClosed)
    }

    // "while the consumer is held, reservations stay within the budget"
    func testHeldConsumerStaysWithinBudget() throws {
        let sim = Simulation()
        let node = server(sim)
        let peer = client(sim, node, index: 1)
        node.holdsDeliveries = true

        let records = frames(0..<7, from: peer)
        peer.writeFrames(Array(records.prefix(6)))

        let link = try XCTUnwrap(peer.link)
        XCTAssertEqual(link.budgetLimit, 2 * Int(maxFrame) + 4)
        XCTAssertFalse(peer.isClosed)
        XCTAssertGreaterThan(link.charged, 0)
        XCTAssertLessThanOrEqual(link.charged, link.budgetLimit)
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, link.charged)
        // The connection is not read while its record is held, so what the
        // peer writes next stays in the transport.
        XCTAssertFalse(peer.isRead)
        peer.writeFrames([records[6]])
        XCTAssertEqual(sim.unreadBytes(on: peer.connection, at: node), Int(maxFrame) + 4)
        XCTAssertEqual(try XCTUnwrap(peer.link).charged, link.charged)

        sim.openDeliveries(node)
        sim.run(until: { node.received.count == 7 })
        XCTAssertEqual(sim.topics(node, from: peer.id), (0..<7).map(topic))
        sim.run(for: .seconds(1))
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0)
        XCTAssertEqual(peer.link?.charged, 0)
    }

    // "a declared length above the maximum frame closes even while the consumer is held"
    func testOversizeHeaderBehindAHeldRecordClosesOnRelease() {
        let sim = Simulation()
        let node = server(sim)
        let peer = client(sim, node, index: 1)
        node.holdsDeliveries = true

        var bytes = HandPeer.framed(frames(0..<2, from: peer))
        bytes.appendUInt32(maxFrame + 1)
        bytes.append(Data(repeating: 0xAA, count: 16))
        peer.writeBytes(bytes)

        // Unlike 15.0.1, nothing is decoded behind a held record (see
        // docs/migration.md): the bad length is found when the record is released.
        XCTAssertEqual(node.received.count, 1)
        XCTAssertFalse(peer.isClosed)
        XCTAssertFalse(sim.isReading(peer.connection, at: node))
        sim.openDeliveries(node)
        sim.run(for: .seconds(1))
        XCTAssertTrue(peer.isClosed)
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0)
    }

    // The same violation with nobody holding anything: closed at once, and
    // the records ahead of it are still delivered.
    func testOversizeHeaderCloses() {
        let sim = Simulation()
        let node = server(sim)
        let peer = client(sim, node, index: 1)

        var bytes = HandPeer.framed(frames(0..<1, from: peer))
        bytes.appendUInt32(maxFrame + 1)
        bytes.append(Data(repeating: 0xAA, count: 16))
        peer.writeBytes(bytes)
        sim.run(for: .seconds(1))

        XCTAssertTrue(peer.isClosed)
        XCTAssertEqual(sim.topics(node, from: peer.id), [topic(0)])
        XCTAssertEqual(node.disconnected, [peer.id])
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0)
    }

    // A zero length is no frame either.
    func testZeroLengthHeaderCloses() {
        let sim = Simulation()
        let node = server(sim)
        let peer = client(sim, node, index: 1)

        peer.writeBytes(Data([0, 0, 0, 0]))

        XCTAssertTrue(peer.isClosed)
        XCTAssertEqual(node.disconnected, [peer.id])
    }

    // "a held consumer on one connection does not slow another"
    func testSlowConnectionDoesNotAffectFastOne() throws {
        let sim = Simulation()
        let node = server(sim)
        let slow = client(sim, node, index: 1)
        let fast = client(sim, node, index: 2)
        node.holdsDeliveries = true

        slow.writeFrames(frames(0..<6, from: slow))
        XCTAssertEqual(sim.topics(node, from: slow.id), [topic(0)])

        // Only the fast connection's deliveries are answered.
        fast.writeFrames(frames(10..<20, from: fast))
        for _ in 0..<20 where sim.topics(node, from: fast.id).count < 10 {
            sim.releaseDeliveries(node, from: fast.id)
        }
        sim.releaseDeliveries(node, from: fast.id)
        XCTAssertEqual(sim.topics(node, from: fast.id), (10..<20).map(topic))

        XCTAssertFalse(slow.isClosed)
        XCTAssertEqual(sim.topics(node, from: slow.id), [topic(0)])
        let slowLink = try XCTUnwrap(slow.link)
        XCTAssertGreaterThan(slowLink.charged, 0)
        XCTAssertLessThanOrEqual(slowLink.charged, slowLink.budgetLimit)
        XCTAssertEqual(fast.link?.charged, 0)

        sim.openDeliveries(node)
        sim.run(until: { sim.topics(node, from: slow.id).count == 6 })
        XCTAssertEqual(sim.topics(node, from: slow.id), (0..<6).map(topic))
    }

    // "a connection paused on the global budget resumes when another connection releases"
    func testGlobalBudgetReleaseWakesAnotherConnection() throws {
        let sim = Simulation()
        // Room for one held frame and two headers, so the second
        // connection's first body is refused by the node-wide budget.
        let limit = Int(maxFrame) + 8
        let node = server(sim, maxInboundBufferedBytes: limit)
        XCTAssertTrue(node.core.isRunning)
        let a = client(sim, node, index: 1)
        let b = client(sim, node, index: 2)
        node.holdsDeliveries = true

        a.writeFrames(frames(0..<4, from: a))
        XCTAssertEqual(sim.topics(node, from: a.id), [topic(0)])

        b.writeFrames(frames(10..<20, from: b))
        XCTAssertFalse(b.isClosed)
        XCTAssertFalse(b.isRead)
        // B holds nothing, so its refusal came from the node-wide budget.
        XCTAssertEqual(try XCTUnwrap(b.link).charged, 0)
        XCTAssertTrue(try XCTUnwrap(b.link).stalledOnBudget)
        XCTAssertTrue(sim.topics(node, from: b.id).isEmpty)
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, try XCTUnwrap(a.link).charged)
        XCTAssertGreaterThan(node.core.diagnostics.inboundBytesUsed + Int(maxFrame), limit)

        sim.openDeliveries(node)
        sim.run(until: { node.received.count == 14 })
        XCTAssertEqual(sim.topics(node, from: b.id), (10..<20).map(topic))
        XCTAssertEqual(sim.topics(node, from: a.id), (0..<4).map(topic))
        XCTAssertFalse(a.isClosed)
        XCTAssertFalse(b.isClosed)
        sim.run(for: .seconds(1))
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0)
        XCTAssertTrue(b.isRead)
    }

    // "a paused decoder withholds socket reads and forwards one when budget frees"
    func testPausedConnectionWithholdsReadsUntilReleased() {
        let sim = Simulation()
        let node = server(sim)
        let peer = client(sim, node, index: 1)
        node.holdsDeliveries = true
        let resumesBefore = sim.resumeCount(peer.connection, at: node)

        for record in frames(0..<3, from: peer) { peer.writeFrames([record]) }
        XCTAssertEqual(sim.topics(node, from: peer.id), [topic(0)])
        XCTAssertFalse(peer.isRead)
        XCTAssertEqual(sim.unreadBytes(on: peer.connection, at: node), 2 * (Int(maxFrame) + 4))
        XCTAssertEqual(sim.resumeCount(peer.connection, at: node), resumesBefore)

        // One release reads one more record, which is held in turn.
        sim.releaseDeliveries(node)
        XCTAssertEqual(sim.topics(node, from: peer.id), [topic(0), topic(1)])
        XCTAssertEqual(sim.resumeCount(peer.connection, at: node), resumesBefore + 1)
        XCTAssertEqual(sim.unreadBytes(on: peer.connection, at: node), Int(maxFrame) + 4)
        XCTAssertFalse(peer.isRead)
        XCTAssertFalse(peer.isClosed)

        sim.releaseDeliveries(node)
        sim.releaseDeliveries(node)
        XCTAssertEqual(sim.topics(node, from: peer.id), (0..<3).map(topic))
        XCTAssertTrue(peer.isRead)
        XCTAssertEqual(peer.link?.charged, 0)
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0)
    }
}
