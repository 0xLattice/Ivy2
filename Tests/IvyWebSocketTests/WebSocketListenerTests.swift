import Foundation
import Ivy
import NIOCore
import NIOPosix
import XCTest
@testable import IvyWebSocket

/// The listener against a WebSocket client written by hand.
final class WebSocketListenerTests: XCTestCase {
    private func listening(
        _ node: Ivy,
        trustForwardedFor: Bool = false,
        maxHandshakes: Int = 256,
        handshakeTimeout: TimeAmount = .seconds(10)
    ) async throws -> (WebSocketTransport, UInt16) {
        let listener = WebSocketTransport(
            ivy: node, group: MultiThreadedEventLoopGroup.singleton,
            maxHandshakes: maxHandshakes, handshakeTimeout: handshakeTimeout)
        try await node.start()
        try await listener.listen(host: "127.0.0.1", port: 0, trustForwardedFor: trustForwardedFor)
        return (listener, try XCTUnwrap(listener.boundPort))
    }

    /// Sends `request` on a new socket and returns it once it is answered and closed.
    private func refused(_ request: String, port: UInt16) async throws -> RawSocket {
        let socket = try await RawSocket.connect(port: port)
        socket.write(request)
        let closed = await eventually { socket.isClosed }
        XCTAssertTrue(closed, "a request that is not upgraded ends the connection")
        return socket
    }

    func testAnythingButAnUpgradeOfThePathIsRefused() async throws {
        let node = makeNode()
        let (listener, port) = try await listening(node)

        let elsewhere = try await refused(RawSocket.upgradeRequest(path: "/other"), port: port)
        XCTAssertEqual(elsewhere.status, 404)
        let plain = try await refused("GET /ivy HTTP/1.1\r\nHost: node\r\n\r\n", port: port)
        XCTAssertEqual(plain.status, 426)
        let oldVersion = try await refused(
            RawSocket.upgradeRequest().replacingOccurrences(of: "Version: 13", with: "Version: 8"), port: port)
        XCTAssertEqual(oldVersion.status, 426)
        let notHTTP = try await refused("\u{1}\u{2}\u{3} nonsense\r\n\r\n", port: port)
        XCTAssertEqual(notHTTP.status, 400)

        let pending = await node.diagnostics.pendingSessions
        XCTAssertEqual(pending, 0, "none of them reached the node")
        // The path may carry a query.
        let upgraded = try await RawSocket.upgraded(port: port, path: "/ivy?v=1")
        upgraded.close()
        await listener.stopListening()
        await node.stop()
    }

    func testRefusedAdmissionAnswers503AndNeverUpgrades() async throws {
        let node = makeNode(maxConnectionsPerNetgroup: 1)
        let (listener, port) = try await listening(node)

        // The loopback netgroup's one slot is taken.
        var lease = node.reserveInboundAdmission(observedHost: "127.0.0.1")
        XCTAssertNotNil(lease)
        let full = try await refused(RawSocket.upgradeRequest(), port: port)
        XCTAssertEqual(full.status, 503)
        XCTAssertEqual(full.frames, [])
        let pending = await node.diagnostics.pendingSessions
        XCTAssertEqual(pending, 0)

        lease = nil
        let admitted = try await RawSocket.upgraded(port: port)
        let taken = await eventually { await node.diagnostics.pendingSessions == 1 }
        XCTAssertTrue(taken)
        admitted.close()
        await listener.stopListening()

        // A node that is not running admits nobody.
        await node.stop()
        let stopped = WebSocketTransport(ivy: node)
        try await stopped.listen(host: "127.0.0.1", port: 0)
        let late = try await refused(RawSocket.upgradeRequest(), port: try XCTUnwrap(stopped.boundPort))
        XCTAssertEqual(late.status, 503)
        await stopped.stopListening()
    }

    func testForwardedAddressIsUsedOnlyWhenTrusted() async throws {
        let node = makeNode(maxConnectionsPerNetgroup: 1)
        let (listener, port) = try await listening(node, trustForwardedFor: true)
        let lease = node.reserveInboundAdmission(observedHost: "8.8.1.1")
        XCTAssertNotNil(lease)

        // The last hop is the one the proxy wrote; earlier ones are the peer's claim.
        let sameNetgroup = try await refused(
            RawSocket.upgradeRequest(extraHeaders: "X-Forwarded-For: 9.9.1.1, 8.8.1.7\r\n"), port: port)
        XCTAssertEqual(sameNetgroup.status, 503)
        let absent = try await refused(RawSocket.upgradeRequest(), port: port)
        XCTAssertEqual(absent.status, 503, "behind a proxy, a request without the header has no address")
        let notAnAddress = try await refused(
            RawSocket.upgradeRequest(extraHeaders: "X-Forwarded-For: somewhere\r\n"), port: port)
        XCTAssertEqual(notAnAddress.status, 503)

        let other = try await RawSocket.connect(port: port)
        other.write(RawSocket.upgradeRequest(extraHeaders: "X-Forwarded-For: 8.8.1.7, 9.9.1.1\r\n"))
        let upgraded = await eventually { other.status == 101 }
        XCTAssertTrue(upgraded)
        other.close()
        await listener.stopListening()

        // Untrusted, the header is ignored and the socket's address is used.
        let direct = WebSocketTransport(ivy: node)
        try await direct.listen(host: "127.0.0.1", port: 0)
        let ignored = try await RawSocket.connect(port: try XCTUnwrap(direct.boundPort))
        ignored.write(RawSocket.upgradeRequest(extraHeaders: "X-Forwarded-For: 8.8.1.7\r\n"))
        let admitted = await eventually { ignored.status == 101 }
        XCTAssertTrue(admitted)
        ignored.close()
        await direct.stopListening()
        await node.stop()
    }

    func testPingIsAnsweredAndCloseIsEchoed() async throws {
        let node = makeNode()
        let (listener, port) = try await listening(node)
        let socket = try await RawSocket.upgraded(port: port)

        socket.write(RawFrame(opcode: RawFrame.ping, masked: true, payload: Array("are you there".utf8)))
        socket.write(RawFrame(opcode: RawFrame.pong, masked: true, payload: [9]))
        let answered = await eventually { !socket.frames.isEmpty }
        XCTAssertTrue(answered)
        XCTAssertEqual(socket.frames, [RawFrame(opcode: RawFrame.pong, payload: Array("are you there".utf8))])

        socket.write(RawFrame(opcode: RawFrame.close, masked: true, payload: [0x03, 0xE9]))
        let closed = await eventually { socket.isClosed }
        XCTAssertTrue(closed)
        XCTAssertEqual(socket.frames.last, RawFrame(opcode: RawFrame.close, payload: [0x03, 0xE9]))
        await listener.stopListening()
        await node.stop()
    }

    func testSocketsThatHaveNotUpgradedAreBoundedInNumber() async throws {
        let node = makeNode()
        let (listener, port) = try await listening(node, maxHandshakes: 2)
        var sockets: [RawSocket] = []
        for _ in 0..<6 { sockets.append(try await RawSocket.connect(port: port)) }
        let bounded = await eventually { sockets.filter { !$0.isClosed }.count == 2 }
        XCTAssertTrue(bounded, "the listener keeps two and closes the rest unread")
        let kept = sockets.filter { !$0.isClosed }

        // An upgrade frees its place, and so does a close.
        kept[0].write(RawSocket.upgradeRequest())
        let upgraded = await eventually { kept[0].status == 101 }
        XCTAssertTrue(upgraded)
        kept[1].close()
        var later: [RawSocket] = []
        let freed = await eventually {
            guard let socket = try? await RawSocket.connect(port: port) else { return false }
            socket.write(RawSocket.upgradeRequest())
            _ = await eventually(timeout: .seconds(2)) { socket.status == 101 || socket.isClosed }
            if socket.status == 101 { later.append(socket) }
            return later.count == 2
        }
        XCTAssertTrue(freed)
        for socket in later + [kept[0]] { socket.close() }
        await listener.stopListening()
        await node.stop()
    }

    func testASocketThatNeverAsksIsClosedAtTheDeadline() async throws {
        let node = makeNode()
        let (listener, port) = try await listening(node, handshakeTimeout: .milliseconds(200))
        let idle = try await RawSocket.connect(port: port)
        let half = try await RawSocket.connect(port: port)
        half.write("GET /ivy HTTP/1.1\r\nHost: node\r\n")
        let closed = await eventually { idle.isClosed && half.isClosed }
        XCTAssertTrue(closed)

        // The deadline is the handshake's, not the connection's.
        let upgraded = try await RawSocket.upgraded(port: port)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(upgraded.isClosed)
        upgraded.close()
        await listener.stopListening()
        await node.stop()
    }
}
