import Foundation
import Ivy
import NIOCore
import NIOPosix
import XCTest
@testable import IvyWebSocket

/// The stream a dial opens, against a WebSocket server written by hand.
final class WebSocketStreamTests: XCTestCase {
    private func dialler(handshakeTimeout: TimeAmount = .seconds(10)) -> WebSocketTransport {
        WebSocketTransport(
            ivy: makeNode(), group: MultiThreadedEventLoopGroup.singleton,
            maxHandshakes: 256, handshakeTimeout: handshakeTimeout)
    }

    func testFragmentsAreJoinedInOrderAndDeliveredOnlyWhenAsked() async throws {
        let server = try await RawServer.upgrading()
        let stream = try await dialler().open(host: "127.0.0.1", port: server.port, path: "/ivy")
        let sink = Sink()
        stream.attach(sink)
        XCTAssertEqual(stream.observedHost, "127.0.0.1")

        let frames = [
            RawFrame(opcode: RawFrame.binary, fin: false, payload: Array("he".utf8)),
            // A control frame may come between the fragments of a message.
            RawFrame(opcode: RawFrame.ping, payload: [7]),
            RawFrame(opcode: RawFrame.continuation, fin: false, payload: Array("ll".utf8)),
            RawFrame(opcode: RawFrame.continuation, fin: false),
            RawFrame(opcode: RawFrame.continuation, payload: Array("o".utf8)),
            RawFrame(opcode: RawFrame.binary, payload: Array(", world".utf8)),
        ]
        for frame in frames { server.sockets.first?.write(frame) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sink.deliveries, 0, "nothing is delivered that was not asked for")
        XCTAssertEqual(server.sockets.first?.frames, [], "and the socket is not read: the ping is unanswered")

        // Each request permits one delivery, however much is waiting.
        while sink.bytes.count < 12 {
            let before = sink.deliveries
            stream.requestBytes()
            let delivered = await eventually(timeout: .seconds(5)) { sink.deliveries == before + 1 }
            XCTAssertTrue(delivered)
            guard delivered else { break }
        }
        XCTAssertEqual(String(decoding: sink.bytes, as: UTF8.self), "hello, world")
        let ponged = await eventually { server.sockets.first?.frames.count == 1 }
        XCTAssertTrue(ponged)
        XCTAssertEqual(
            server.sockets.first?.frames, [RawFrame(opcode: RawFrame.pong, masked: true, payload: [7])])

        stream.close()
        stream.close()
        let closed = await eventually { sink.closes == 1 && server.sockets.first?.isClosed == true }
        XCTAssertTrue(closed)
        XCTAssertEqual(server.sockets.first?.frames.last?.closeCode, 1000)
        XCTAssertEqual(server.sockets.first?.frames.last?.masked, true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sink.closes, 1, "the close is reported once")
        await server.stop()
    }

    func testSentBytesAreMaskedSplitAndCountedUntilFlushed() async throws {
        let server = try await RawServer.upgrading()
        let stream = try await dialler().open(host: "127.0.0.1", port: server.port, path: "/ivy")
        let sink = Sink()
        stream.attach(sink)
        XCTAssertTrue(stream.isWritable)

        let bytes = Data((0..<200 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        stream.send(bytes)
        XCTAssertFalse(stream.isWritable, "what was passed to send counts at once")
        stream.send(Data([1, 2, 3]))

        let arrived = await eventually { server.sockets.first?.frames.count == 5 }
        XCTAssertTrue(arrived)
        let frames = server.sockets.first?.frames ?? []
        XCTAssertEqual(frames.map(\.payload.count), [65_536, 65_536, 65_536, 8_192, 3])
        XCTAssertTrue(frames.allSatisfy { $0.masked && $0.fin && $0.opcode == RawFrame.binary })
        XCTAssertEqual(Data(frames.flatMap(\.payload)), bytes + Data([1, 2, 3]))

        let drained = await eventually { stream.isWritable && sink.writability == [false, true] }
        XCTAssertTrue(drained)
        stream.close()
        await server.stop()
    }

    func testARefusedUpgradeThrowsItsStatusAndClosesTheSocket() async throws {
        let server = try await RawServer.start { _ in
            Array("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n".utf8)
        }
        let transport = dialler()
        let endpoint = PeerEndpoint(publicKey: makeNode().publicKey, host: "127.0.0.1", port: server.port)
        do {
            try await transport.connect(to: endpoint, host: "127.0.0.1", port: server.port)
            XCTFail("connect should fail")
        } catch let error as WebSocketConnectError {
            XCTAssertEqual(error, .refused(status: 503))
        }
        let closed = await eventually { server.sockets.first?.isClosed == true }
        XCTAssertTrue(closed)
        await server.stop()
    }

    func testAnUpgradeThatIsNeverAnsweredFailsAtTheDeadline() async throws {
        let server = try await RawServer.start { _ in nil }
        do {
            _ = try await dialler(handshakeTimeout: .milliseconds(200))
                .open(host: "127.0.0.1", port: server.port, path: "/ivy")
            XCTFail("open should fail")
        } catch let error as WebSocketConnectError {
            XCTAssertEqual(error, .noAnswer)
        }
        let closed = await eventually { server.sockets.first?.isClosed == true }
        XCTAssertTrue(closed)
        await server.stop()
    }

    func testConnectingThrowsWhatTheNodeThrows() async throws {
        let node = makeNode()
        let listener = WebSocketTransport(ivy: node)
        try await node.start()
        try await listener.listen(host: "127.0.0.1", port: 0)
        let port = try XCTUnwrap(listener.boundPort)
        // The dialling node was never started.
        do {
            try await dialler().connect(
                to: PeerEndpoint(publicKey: node.publicKey, host: "127.0.0.1", port: port),
                host: "127.0.0.1", port: port)
            XCTFail("connect should fail")
        } catch let error as IvyError {
            XCTAssertEqual(error, .notRunning)
        }
        let dropped = await eventually { await node.diagnostics.pendingSessions == 0 }
        XCTAssertTrue(dropped, "the stream that did not become a session is closed")
        await listener.stopListening()
        await node.stop()
    }
}

private final class Sink: TransportConnectionSink, @unchecked Sendable {
    private let lock = NSLock()
    private var received = Data()
    private var deliveryCount = 0
    private var closeCount = 0
    private var changes: [Bool] = []

    var bytes: Data { lock.withLock { received } }
    var deliveries: Int { lock.withLock { deliveryCount } }
    var closes: Int { lock.withLock { closeCount } }
    var writability: [Bool] { lock.withLock { changes } }

    func transportDidReceive(_ bytes: Data) {
        lock.withLock {
            received.append(bytes)
            deliveryCount += 1
        }
    }

    func transportWritabilityChanged(isWritable: Bool) {
        lock.withLock { changes.append(isWritable) }
    }

    func transportDidClose() {
        lock.withLock { closeCount += 1 }
    }
}
