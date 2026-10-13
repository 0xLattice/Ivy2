import Foundation
import Ivy
import IvyWebSocket
import XCTest

/// Two nodes with a WebSocket between them, over real loopback sockets.
final class WebSocketSessionTests: XCTestCase {
    /// Starts both nodes, `b` listening for WebSockets, and connects `a` to it.
    private func join(_ a: Ivy, _ b: Ivy) async throws -> (WebSocketTransport, WebSocketTransport) {
        let dialler = WebSocketTransport(ivy: a)
        let listener = WebSocketTransport(ivy: b)
        try await a.start()
        try await b.start()
        try await listener.listen(host: "127.0.0.1", port: 0)
        let port = try XCTUnwrap(listener.boundPort)
        try await dialler.connect(
            to: PeerEndpoint(publicKey: b.publicKey, host: "127.0.0.1", port: port),
            host: "127.0.0.1", port: port)
        return (dialler, listener)
    }

    private func stop(_ a: Ivy, _ b: Ivy, _ listener: WebSocketTransport) async {
        await listener.stopListening()
        await a.stop()
        await b.stop()
    }

    func testNodesAuthenticateAndMessagesFlowBothWays() async throws {
        let a = makeNode()
        let b = makeNode()
        let atA = Recorder()
        let atB = Recorder()
        await a.setDelegate(atA)
        await b.setDelegate(atB)
        let (_, listener) = try await join(a, b)

        let connected = await eventually { await b.connectedPeers == [a.id] }
        XCTAssertTrue(connected)
        let peers = await a.connectedPeers
        XCTAssertEqual(peers, [b.id])

        let there = await a.sendMessage(to: b.id, topic: "t", payload: Data("there".utf8))
        XCTAssertEqual(there, .enqueued(endpoint: b.id, route: .direct))
        let back = await b.sendMessage(to: a.id, topic: "t", payload: Data("back".utf8))
        XCTAssertEqual(back, .enqueued(endpoint: a.id, route: .direct))
        let delivered = await eventually {
            let counts = await (atA.messages.count, atB.messages.count)
            return counts == (1, 1)
        }
        XCTAssertTrue(delivered)
        let fromA = await atB.messages.first
        XCTAssertEqual(fromA?.0.id, a.id)
        XCTAssertEqual(fromA?.1, PeerMessage(topic: "t", payload: Data("there".utf8)))
        let fromB = await atA.messages.first
        XCTAssertEqual(fromB?.0.id, b.id)
        XCTAssertEqual(fromB?.1, PeerMessage(topic: "t", payload: Data("back".utf8)))
        await stop(a, b, listener)
    }

    func testLargeVolumeCrossesManyFramesUnderBackpressure() async throws {
        let a = makeNode()
        let b = makeNode()
        // 12 MiB: every record is far over the largest frame the stream sends.
        let entries = [ContentEntry(cid: "vol", data: Data(repeating: 1, count: 1024))]
            + (0..<12).map { ContentEntry(cid: "vol-\($0)", data: Data(repeating: UInt8($0), count: 1024 * 1024)) }
        await b.setContentSource(Store(volumes: ["vol": entries]))
        let (_, listener) = try await join(a, b)

        let response = await a.fetchVolume(rootCID: "vol")
        XCTAssertEqual(response.entries.count, entries.count)
        for entry in entries { XCTAssertEqual(response.entries[entry.cid], entry.data) }
        XCTAssertEqual(response.servedBy, b.id)

        let settled = await eventually {
            let serving = await b.diagnostics
            let fetching = await a.diagnostics
            return serving.reservedServingVolumeBytes == 0 && serving.servingSlotsHeld == 0
                && fetching.inFlightVolumeBytes == 0 && fetching.inboundBytesUsed == 0
        }
        XCTAssertTrue(settled)
        await stop(a, b, listener)
    }

    func testSlowDelegateHoldsTheSocketNotMemory() async throws {
        let a = makeNode()
        let b = makeNode(maxInboundBufferedBytes: 4 * 1024 * 1024 + 4)
        let gate = Gate()
        let recorder = Recorder(gate: gate)
        await b.setDelegate(recorder)
        let (_, listener) = try await join(a, b)

        // The first message parks in the delegate. Everything after it must
        // stay in the socket: Ivy holds one record and reads no further.
        // Small records and a long wait: masking is slow under a sanitizer,
        // and a slow pipe must not be taken for a full one.
        let payload = Data(repeating: 7, count: 128 * 1024)
        var enqueued = 0
        fill: for _ in 0..<400 {
            switch await a.sendMessage(to: b.id, topic: "bulk", payload: payload) {
            case .enqueued:
                enqueued += 1
            case .backpressured:
                // A pipe that is full because the far side stopped reading
                // does not become writable.
                let writable = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { await a.waitUntilWritable(to: b.id) }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        return false
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                if !writable { break fill }
            default:
                XCTFail("unexpected send result")
                break fill
            }
        }
        XCTAssertGreaterThan(enqueued, 1)
        // The receiver's budget is 4 MiB and the rest is in the kernel's
        // socket buffers. A stream that read without being asked would take
        // everything the sender has.
        XCTAssertLessThan(enqueued, 100, "the sender must be held back by the socket")
        let parked = await eventually { await recorder.entered == 1 }
        XCTAssertTrue(parked)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let held = await b.diagnostics.inboundBytesUsed
        XCTAssertLessThanOrEqual(held, 4 * 1024 * 1024 + 4)
        let seen = await recorder.messages.count
        XCTAssertEqual(seen, 0, "no record is delivered past the one the delegate holds")

        await gate.open()
        let drained = await eventually { await recorder.messages.count >= 2 }
        XCTAssertTrue(drained)
        await stop(a, b, listener)
    }

    func testAMisbehavingSocketIsClosedAndTheSessionBesideItIsNot() async throws {
        let a = makeNode()
        let b = makeNode()
        let recorder = Recorder()
        await b.setDelegate(recorder)
        let (_, listener) = try await join(a, b)
        let port = try XCTUnwrap(listener.boundPort)

        let offences: [(String, [UInt8], UInt16?)] = [
            ("a text frame", RawFrame(opcode: RawFrame.text, masked: true, payload: [0x68, 0x69]).encoded, 1003),
            // A header that announces 2 MiB is enough: the body is never awaited.
            ("an oversized frame", [0x82, 0xFF, 0, 0, 0, 0, 0, 0x20, 0, 0, 1, 2, 3, 4], 1009),
            ("an unmasked frame", RawFrame(opcode: RawFrame.binary, payload: [1, 2, 3]).encoded, 1002),
            ("a continuation of nothing", RawFrame(opcode: RawFrame.continuation, masked: true, payload: [1]).encoded, 1002),
            ("garbage", [UInt8](repeating: 0xFF, count: 64), nil),
        ]
        for (name, bytes, code) in offences {
            let socket = try await RawSocket.upgraded(port: port)
            socket.write(bytes)
            let closed = await eventually { socket.isClosed }
            XCTAssertTrue(closed, "\(name) must close the socket")
            let last = socket.frames.last
            XCTAssertEqual(last?.opcode, RawFrame.close, "\(name) is answered with a close frame")
            if let code { XCTAssertEqual(last?.closeCode, code, name) }
        }

        let peers = await b.connectedPeers
        XCTAssertEqual(peers, [a.id])
        let sent = await a.sendMessage(to: b.id, topic: "t", payload: Data("still here".utf8))
        XCTAssertEqual(sent, .enqueued(endpoint: b.id, route: .direct))
        let delivered = await eventually { await recorder.messages.count == 1 }
        XCTAssertTrue(delivered)
        await stop(a, b, listener)
    }

    func testStoppingClosesTheListenerItsHandshakesAndTheNodesSessions() async throws {
        let a = makeNode()
        let b = makeNode()
        let (_, listener) = try await join(a, b)
        let port = try XCTUnwrap(listener.boundPort)
        let connected = await eventually { await b.connectedPeers == [a.id] }
        XCTAssertTrue(connected)
        // One socket that has asked for nothing yet, and one upgraded.
        let waiting = try await RawSocket.connect(port: port)
        let upgraded = try await RawSocket.upgraded(port: port)

        await listener.stopListening()
        XCTAssertNil(listener.boundPort)
        let dropped = await eventually { waiting.isClosed }
        XCTAssertTrue(dropped, "a socket still in the HTTP exchange goes with the listener")
        do {
            _ = try await RawSocket.connect(port: port)
            XCTFail("nothing listens any more")
        } catch {}
        // What was upgraded is the node's.
        XCTAssertFalse(upgraded.isClosed)
        let peers = await b.connectedPeers
        XCTAssertEqual(peers, [a.id])

        await b.stop()
        let ended = await eventually {
            let peers = await a.connectedPeers
            return upgraded.isClosed && peers.isEmpty
        }
        XCTAssertTrue(ended)
        await a.stop()
    }
}
