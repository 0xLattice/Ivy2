import Foundation
import XCTest
@testable import IvyCore
import IvySimulation
import Tally

/// 15.0.1's `TestSeededGenerator`, seed override included, except that it
/// returns the state's high half. The low bits of this generator repeat
/// with a short period, and taken modulo 4 and 2 as the test below takes
/// them, the original drew the same mutation on every iteration.
private struct FramingSeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        guard let raw = ProcessInfo.processInfo.environment["IVY_TEST_SEED"] else {
            state = seed
            return
        }
        let value = raw.lowercased()
        state = if value.hasPrefix("0x") {
            UInt64(value.dropFirst(2), radix: 16) ?? seed
        } else {
            UInt64(value) ?? seed
        }
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 32
    }
}

/// Session frame bounds: 15.0.1's `SessionFrameDecoder` tests, against the
/// framing and byte budgets that now live in the core. Bytes reach a node
/// on raw connections; a record is observed as the message it delivers, so
/// the records here are signed data records on a hand-driven session.
final class InboundFramingTests: XCTestCase {
    /// The node's frame limit: just above the smallest a config may set.
    private static let limit: UInt32 = 70_000

    private func node(_ sim: Simulation, budget: Int = IvyConfig.defaultMaxInboundBufferedBytes) -> Simulation.Node {
        sim.node(maxInboundBufferedBytes: budget, protocolMaxFrameSize: Self.limit)
    }

    private func message(_ bytes: [UInt8]) -> Message {
        .peerMessage(topic: "frame", payload: Data(bytes))
    }

    private func delivered(_ node: Simulation.Node) -> [Data] {
        node.received.map(\.message.payload)
    }

    private func readingEffects(_ sim: Simulation, _ connection: ConnectionID) -> [Effect] {
        sim.trace.map(\.effect).filter {
            $0 == .pauseReading(connection) || $0 == .resumeReading(connection)
        }
    }

    /// oversized declared record closes before body allocation
    func testOversizedLength() {
        let sim = Simulation()
        let node = node(sim)
        let connection = sim.openRawConnection(to: node)
        sim.writeRaw(wireTestLengthPrefix(Self.limit + 1), on: connection, to: node)
        XCTAssertTrue(sim.nodeClosedRaw(connection))
        XCTAssertTrue(sim.takeRawOutput(connection).isEmpty)
        XCTAssertEqual(node.core.inboundBytesUsed, 0)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertTrue(node.core.links.isEmpty)

        // The limit itself is a length the node waits for.
        let atLimit = sim.openRawConnection(to: node, fromHost: "9.8.0.1")
        sim.writeRaw(wireTestLengthPrefix(Self.limit), on: atLimit, to: node)
        XCTAssertFalse(sim.nodeClosedRaw(atLimit))
        XCTAssertEqual(node.core.inboundBytesUsed, 0)
    }

    /// bounded records are delivered unchanged
    func testBoundedRecord() {
        let sim = Simulation()
        let node = node(sim)
        let peer = WireRawPeer(sim, to: node, label: "frame-bounded")
        XCTAssertTrue(peer.handshake())
        let payload: [UInt8] = [0x49, 0x56, 0x59, 0x08, 0x01]
        sim.writeRaw(wireTestFramed(peer.record(message(payload))), on: peer.connection, to: node)
        sim.run(for: .zero)
        XCTAssertEqual(delivered(node), [Data(payload)])
        XCTAssertEqual(node.core.inboundBytesUsed, 0)
    }

    /// every stream split delivers the same records
    func testEverySplit() {
        let sim = Simulation()
        let node = node(sim)
        let peer = WireRawPeer(sim, to: node, label: "frame-split")
        XCTAssertTrue(peer.handshake())
        let payloads: [[UInt8]] = [[0x49, 0x56, 0x59, 0x08, 0x01], [0xaa, 0xbb, 0xcc]]
        var expected: [Data] = []
        var split = 0

        while true {
            // The session's sequence numbers move on; the stream's length does not.
            let stream = payloads.reduce(Data()) { $0 + wireTestFramed(peer.record(message($1))) }
            guard split <= stream.count else { break }
            if split > 0 {
                sim.writeRaw(Data(stream.prefix(split)), on: peer.connection, to: node)
            }
            if split < stream.count {
                sim.writeRaw(Data(stream.dropFirst(split)), on: peer.connection, to: node)
            }
            sim.run(for: .zero)
            expected += payloads.map { Data($0) }
            XCTAssertEqual(delivered(node), expected, "split \(split)")
            XCTAssertEqual(node.core.inboundBytesUsed, 0, "split \(split)")
            guard delivered(node) == expected else { return }
            split += 1
        }
        XCTAssertGreaterThan(split, 200)
        XCTAssertFalse(sim.nodeClosedRaw(peer.connection))
    }

    /// coalesced frames preserve record boundaries
    func testCoalescedFrames() {
        let sim = Simulation()
        let node = node(sim)
        let peer = WireRawPeer(sim, to: node, label: "frame-coalesced")
        XCTAssertTrue(peer.handshake())
        let payloads: [[UInt8]] = [[1], [2, 3], [4, 5, 6]]
        let stream = payloads.reduce(Data()) { $0 + wireTestFramed(peer.record(message($1))) }

        sim.writeRaw(stream, on: peer.connection, to: node)
        sim.run(for: .zero)

        XCTAssertEqual(delivered(node), payloads.map { Data($0) })
        XCTAssertEqual(node.core.inboundBytesUsed, 0)
    }

    /// zero-length records close as malformed wire
    func testZeroLength() {
        let sim = Simulation()
        let node = node(sim)
        let connection = sim.openRawConnection(to: node)
        sim.writeRaw(wireTestLengthPrefix(0), on: connection, to: node)
        XCTAssertTrue(sim.nodeClosedRaw(connection))
        XCTAssertTrue(sim.takeRawOutput(connection).isEmpty)
        XCTAssertEqual(node.core.inboundBytesUsed, 0)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)

        // The same on an authenticated session, which ends with it.
        let peer = WireRawPeer(sim, to: node, label: "frame-zero", host: "9.8.0.1")
        XCTAssertTrue(peer.handshake())
        sim.writeRaw(wireTestLengthPrefix(0), on: peer.connection, to: node)
        XCTAssertTrue(sim.nodeClosedRaw(peer.connection))
        XCTAssertEqual(node.disconnected, [peer.id])
        XCTAssertEqual(node.core.inboundBytesUsed, 0)
    }

    /// declared lengths do not reserve unseen bytes or evict another connection
    func testSlowlorisIsolation() {
        let sim = Simulation()
        // The smallest node-wide budget a config may set: one maximum frame.
        let node = node(sim, budget: Int(Self.limit) + 4)
        let body = sim.openRawConnection(to: node, fromHost: "9.1.0.1")
        sim.writeRaw(wireTestLengthPrefix(Self.limit) + Data([1]), on: body, to: node)
        XCTAssertEqual(node.core.inboundBytesUsed, 1)

        let competing = WireRawPeer(sim, to: node, label: "frame-competing", host: "9.2.0.1")
        XCTAssertTrue(competing.handshake())
        competing.send(message([2]))
        sim.run(for: .zero)
        XCTAssertFalse(sim.nodeClosedRaw(competing.connection))
        XCTAssertFalse(sim.nodeClosedRaw(body))
        XCTAssertEqual(delivered(node), [Data([2])])
        XCTAssertEqual(node.core.inboundBytesUsed, 1)

        sim.closeRaw(competing.connection, at: node)
        sim.closeRaw(body, at: node)
        XCTAssertEqual(node.core.inboundBytesUsed, 0)
    }

    /// one connection cannot exceed its byte reservation
    ///
    /// On the decoder itself: a direct connection in a core holds at most
    /// one partial frame while it decodes, which its reservation of two
    /// maximum frames always covers.
    func testPerConnectionBudget() {
        var used = 0
        let nodeLimit = 64
        // A reservation of 2 * 2 + 4 = 8 bytes.
        var link = Link(
            id: 1,
            transport: .direct(ConnectionID(1)),
            endpoint: PeerEndpoint(publicKey: "", host: "unknown", port: 0),
            observedHost: nil,
            localHost: nil,
            localMaxFrameSize: 2)
        XCTAssertEqual(link.budgetLimit, 8)

        link.appendReceived(wireTestLengthPrefix(9) + Data(repeating: 0xaa, count: 8))
        guard case .needMore = link.decodeFrame(maxFrameSize: 1024, used: &used, limit: nodeLimit) else {
            return XCTFail("expected a partial frame")
        }
        XCTAssertEqual(used, 8)
        XCTAssertEqual(link.charged, 8)

        // Exhaustion is backpressure: the byte waits unreserved, the
        // connection stays open, and the reservation never exceeds its limit.
        link.appendReceived(Data([0xaa]))
        guard case .stalled = link.decodeFrame(maxFrameSize: 1024, used: &used, limit: nodeLimit) else {
            return XCTFail("expected the decoder to stall")
        }
        XCTAssertEqual(link.undecodedByteCount, 1)
        XCTAssertEqual(used, 8)
        XCTAssertEqual(link.charged, 8)
    }

    /// closing a partial header releases its reservation
    func testPartialHeaderClose() {
        let sim = Simulation()
        let node = node(sim)
        let connection = sim.openRawConnection(to: node)
        sim.writeRaw(Data([0]), on: connection, to: node)
        XCTAssertEqual(node.core.inboundBytesUsed, 4)
        sim.closeRaw(connection, at: node)
        XCTAssertEqual(node.core.inboundBytesUsed, 0)
    }

    /// byte-at-a-time slowloris input releases its reservation on close
    func testSlowlorisClose() {
        let sim = Simulation()
        let node = node(sim, budget: Int(Self.limit) + 4)
        let connection = sim.openRawConnection(to: node)
        let partial = wireTestFramed(Data(repeating: 0xaa, count: Int(Self.limit))).prefix(12)

        for byte in partial {
            sim.writeRaw(Data([byte]), on: connection, to: node)
        }
        XCTAssertFalse(sim.nodeClosedRaw(connection))
        XCTAssertTrue(sim.takeRawOutput(connection).isEmpty)
        XCTAssertEqual(node.core.inboundBytesUsed, partial.count - 4)

        sim.closeRaw(connection, at: node)
        XCTAssertEqual(node.core.inboundBytesUsed, 0)
    }

    /// An exhausted node-wide budget pauses the connection that ran out,
    /// and the bytes another connection gives back resume it.
    func testExhaustedNodeBudgetPausesReadingUntilBytesAreReleased() {
        let sim = Simulation()
        let node = node(sim, budget: Int(Self.limit) + 4)
        let holder = WireRawPeer(sim, to: node, label: "frame-holder", host: "9.1.0.1")
        XCTAssertTrue(holder.handshake())

        // The application sits on a large delivery, which stays charged.
        node.holdsDeliveries = true
        let held = holder.record(message([UInt8](repeating: 7, count: 60_000)))
        sim.writeRaw(wireTestFramed(held), on: holder.connection, to: node)
        XCTAssertEqual(node.heldDeliveries.count, 1)
        XCTAssertEqual(node.core.inboundBytesUsed, held.count)

        let starved = sim.openRawConnection(to: node, fromHost: "9.2.0.1")
        XCTAssertEqual(readingEffects(sim, starved), [.resumeReading(starved)])
        let part = Data(repeating: 0xaa, count: 20_000)
        XCTAssertGreaterThan(held.count + part.count, node.core.config.maxInboundBufferedBytes)
        sim.writeRaw(wireTestLengthPrefix(Self.limit) + part, on: starved, to: node)
        XCTAssertEqual(readingEffects(sim, starved), [.resumeReading(starved), .pauseReading(starved)])
        XCTAssertFalse(sim.isReading(starved, at: node))
        XCTAssertFalse(sim.nodeClosedRaw(starved))
        // What did not fit is not charged, and what arrives next is not read.
        XCTAssertEqual(node.core.inboundBytesUsed, held.count)
        sim.writeRaw(Data([0xaa]), on: starved, to: node)
        XCTAssertEqual(sim.unreadBytes(on: starved, at: node), 1)

        sim.releaseDeliveries(node)
        XCTAssertEqual(
            readingEffects(sim, starved),
            [.resumeReading(starved), .pauseReading(starved), .resumeReading(starved)])
        XCTAssertTrue(sim.isReading(starved, at: node))
        XCTAssertEqual(sim.unreadBytes(on: starved, at: node), 0)
        XCTAssertEqual(node.core.inboundBytesUsed, part.count + 1)

        sim.closeRaw(starved, at: node)
        XCTAssertEqual(node.core.inboundBytesUsed, 0)
    }

    /// seeded hostile mutations never leak frame budget
    func testSeededHostileMutations() {
        var generator = FramingSeededGenerator(seed: 0x4956_5908)
        let corpus = [
            Message.ping(nonce: 1).serialize(),
            Message.volumeRequest(requestID: 1, rootCID: "root").serialize(),
            Message.peerMessage(topic: "state", payload: Data([1, 2, 3])).serialize(),
        ]
        let sim = Simulation()
        let node = node(sim)

        for iteration in 0..<256 {
            var body = corpus[Int(generator.next() % UInt64(corpus.count))]
            switch generator.next() % 4 {
            case 0 where !body.isEmpty:
                body[Int(generator.next() % UInt64(body.count))] ^= UInt8(1 << (generator.next() % 8))
            case 1 where !body.isEmpty:
                body.removeLast(Int(generator.next() % UInt64(body.count)) + 1)
            case 2:
                body.append(UInt8(truncatingIfNeeded: generator.next()))
            default:
                body = Data((0..<Int(generator.next() % 32)).map { _ in
                    UInt8(truncatingIfNeeded: generator.next())
                })
            }

            if let accepted = Message.deserialize(body) {
                XCTAssert(accepted.serialize() == body, "iteration \(iteration)")
            }

            // The mutated message arrives validly signed on a fresh session,
            // and half the time the frame carrying it is damaged as well.
            let peer = WireRawPeer(
                sim, to: node, label: "frame-hostile-\(iteration)", host: "11.\(iteration).0.1")
            XCTAssertTrue(peer.handshake(), "iteration \(iteration)")
            var bytes = wireTestFramed(peer.record(payload: body.isEmpty ? Data([0]) : body))
            if generator.next() & 1 == 1, !bytes.isEmpty {
                bytes[Int(generator.next() % UInt64(bytes.count))] ^= 1
            }
            sim.writeRaw(bytes, on: peer.connection, to: node)
            sim.run(for: .seconds(1))
            sim.closeRaw(peer.connection, at: node)
            sim.run(for: .seconds(1))

            XCTAssertEqual(node.core.inboundBytesUsed, 0, "iteration \(iteration)")
            XCTAssertTrue(node.core.links.isEmpty, "iteration \(iteration)")
            XCTAssertTrue(node.core.sessions.isEmpty, "iteration \(iteration)")
        }
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(node.core.diagnostics.jobsOutstanding, 0)
        // The corpus is not all rejected: some mutations still deliver.
        XCTAssertFalse(node.received.isEmpty)
    }
}
