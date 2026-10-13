import Crypto
import Foundation
import Ivy
import NIOCore
import NIOPosix
import XCTest

func eventually(
    timeout: Duration = .seconds(10),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

func makeNode(
    maxConnectionsPerNetgroup: Int = 16,
    maxInboundBufferedBytes: Int = IvyConfig.defaultMaxInboundBufferedBytes
) -> Ivy {
    Ivy.forTesting(IvyConfig(
        signingKey: Curve25519.Signing.PrivateKey(),
        listenPort: 0,
        requestTimeout: .seconds(15),
        stunServers: [],
        healthConfig: PeerHealthConfig(enabled: false),
        maxConnectionsPerNetgroup: maxConnectionsPerNetgroup,
        maxInboundBufferedBytes: maxInboundBufferedBytes))
}

extension Ivy {
    func setDelegate(_ delegate: IvyDelegate?) { self.delegate = delegate }
}

// MARK: - A WebSocket peer written by hand

/// One WebSocket frame as it is on the wire.
struct RawFrame: Equatable {
    static let continuation: UInt8 = 0x0, text: UInt8 = 0x1, binary: UInt8 = 0x2
    static let close: UInt8 = 0x8, ping: UInt8 = 0x9, pong: UInt8 = 0xA

    var opcode: UInt8
    var fin = true
    var masked = false
    var payload: [UInt8] = []

    /// A close frame's status code.
    var closeCode: UInt16? {
        opcode == Self.close && payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : nil
    }

    var encoded: [UInt8] {
        var out: [UInt8] = [(fin ? 0x80 : 0) | opcode]
        let maskBit: UInt8 = masked ? 0x80 : 0
        switch payload.count {
        case 0...125:
            out.append(maskBit | UInt8(payload.count))
        case 126...0xFFFF:
            out += [maskBit | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            out.append(maskBit | 127)
            out += (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) }
        }
        guard masked else { return out + payload }
        let key: [UInt8] = [0x1F, 0x2E, 0x3D, 0x4C]
        return out + key + payload.enumerated().map { $1 ^ key[$0 % 4] }
    }

    /// Every whole frame at the start of `bytes`.
    static func parse(_ bytes: [UInt8]) -> [RawFrame] {
        var frames: [RawFrame] = []
        var at = 0
        while bytes.count - at >= 2 {
            let first = bytes[at], second = bytes[at + 1]
            var length = Int(second & 0x7F)
            var header = 2
            if length == 126 {
                guard bytes.count - at >= 4 else { break }
                length = Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
                header = 4
            } else if length == 127 {
                guard bytes.count - at >= 10 else { break }
                length = bytes[(at + 2)..<(at + 10)].reduce(0) { $0 << 8 | Int($1) }
                header = 10
            }
            let masked = second & 0x80 != 0
            let start = at + header + (masked ? 4 : 0)
            guard bytes.count >= start + length else { break }
            var payload = Array(bytes[start..<(start + length)])
            if masked {
                let key = Array(bytes[(start - 4)..<start])
                payload = payload.enumerated().map { $1 ^ key[$0 % 4] }
            }
            frames.append(RawFrame(
                opcode: first & 0x0F, fin: first & 0x80 != 0, masked: masked, payload: payload))
            at = start + length
        }
        return frames
    }
}

/// A bare TCP connection that records what it is sent.
final class RawSocket: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var closed = false
    private var channel: Channel?
    /// Given the bytes so far, what to send back; asked until it answers.
    private var answer: (@Sendable ([UInt8]) -> [UInt8]?)?

    init(answer: (@Sendable ([UInt8]) -> [UInt8]?)? = nil) {
        self.answer = answer
    }

    static func connect(port: UInt16) async throws -> RawSocket {
        let socket = RawSocket()
        _ = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { $0.pipeline.addHandler(socket) }
            .connect(host: "127.0.0.1", port: Int(port)).get()
        return socket
    }

    /// Connects and upgrades to a WebSocket at `path`.
    static func upgraded(port: UInt16, path: String = "/ivy") async throws -> RawSocket {
        let socket = try await connect(port: port)
        socket.write(upgradeRequest(path: path))
        let answered = await eventually { socket.head != nil }
        XCTAssertTrue(answered)
        XCTAssertEqual(socket.status, 101)
        return socket
    }

    static func upgradeRequest(path: String = "/ivy", extraHeaders: String = "") -> String {
        "GET \(path) HTTP/1.1\r\nHost: node\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\nSec-WebSocket-Version: 13\r\n"
            + extraHeaders + "\r\n"
    }

    var received: [UInt8] { lock.withLock { bytes } }
    var isClosed: Bool { lock.withLock { closed } }

    /// The HTTP head received, once all of it has arrived.
    var head: String? {
        let bytes = received
        guard let end = bytes.firstRange(of: Array("\r\n\r\n".utf8)) else { return nil }
        return String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
    }

    var status: Int? {
        head.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) }
    }

    /// The WebSocket frames received after the HTTP head.
    var frames: [RawFrame] {
        let bytes = received
        guard let end = bytes.firstRange(of: Array("\r\n\r\n".utf8)) else { return [] }
        return RawFrame.parse(Array(bytes[end.upperBound...]))
    }

    func write(_ bytes: [UInt8]) {
        guard let channel = lock.withLock({ channel }) else { return }
        channel.writeAndFlush(ByteBuffer(bytes: bytes), promise: nil)
    }

    func write(_ string: String) { write(Array(string.utf8)) }
    func write(_ frame: RawFrame) { write(frame.encoded) }

    func close() {
        lock.withLock { channel }?.close(promise: nil)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        lock.withLock { channel = context.channel }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let reply = lock.withLock { () -> [UInt8]? in
            bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
            guard let reply = answer?(bytes) else { return nil }
            answer = nil
            return reply
        }
        if let reply { context.writeAndFlush(NIOAny(ByteBuffer(bytes: reply)), promise: nil) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.withLock { closed = true }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// A TCP listener whose connections answer the first request as told.
final class RawServer: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted: [RawSocket] = []
    private var listener: Channel?

    /// `answer` sees the request head and returns the bytes to send back.
    static func start(answer: @escaping @Sendable (String) -> [UInt8]?) async throws -> RawServer {
        let server = RawServer()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let socket = RawSocket { bytes in
                    guard let end = bytes.firstRange(of: Array("\r\n\r\n".utf8)) else { return nil }
                    return answer(String(decoding: bytes[..<end.lowerBound], as: UTF8.self))
                }
                server.lock.withLock { server.accepted.append(socket) }
                return channel.pipeline.addHandler(socket)
            }
            .bind(host: "127.0.0.1", port: 0).get()
        server.lock.withLock { server.listener = channel }
        return server
    }

    /// Grants the upgrade, then sends `frames`.
    static func upgrading(then frames: [RawFrame] = []) async throws -> RawServer {
        try await start { head in
            let key = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) }
            let accept = Data(Insecure.SHA1.hash(
                data: Data(((key ?? "") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            ).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            return Array(response.utf8) + frames.flatMap(\.encoded)
        }
    }

    var port: UInt16 { lock.withLock { UInt16(listener?.localAddress?.port ?? 0) } }
    var sockets: [RawSocket] { lock.withLock { accepted } }

    func stop() async {
        for socket in sockets { socket.close() }
        try? await lock.withLock { listener }?.close().get()
    }
}

// MARK: - Recording what a node is told

actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private actor RecorderState {
    var messages: [(AuthenticatedPeer, PeerMessage)] = []
    var entered = 0

    func enter() { entered += 1 }
    func add(_ peer: AuthenticatedPeer, _ message: PeerMessage) { messages.append((peer, message)) }
}

final class Recorder: IvyDelegate, Sendable {
    private let state = RecorderState()
    private let gate: Gate?

    init(gate: Gate? = nil) {
        self.gate = gate
    }

    var messages: [(AuthenticatedPeer, PeerMessage)] { get async { await state.messages } }
    var entered: Int { get async { await state.entered } }

    func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        await state.enter()
        await gate?.wait()
        await state.add(peer, message)
    }
}

struct Store: IvyContentSource {
    var volumes: [String: [ContentEntry]] = [:]

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        volumes[rootCID] ?? []
    }
}
