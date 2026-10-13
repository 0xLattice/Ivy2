import Foundation
import Ivy
import NIOCore
import NIOWebSocket

/// A WebSocket connection as a `TransportConnection`. Ivy frames its own
/// records, so the socket is only an ordered byte stream: binary payloads are
/// concatenated as they arrive, and where one message ends means nothing.
///
/// As with `TCPStream`, the socket is read only when bytes are requested, so
/// a consumer that stops asking leaves the data in the kernel and TCP holds
/// the sender. Control frames are behind that data: a ping is answered when
/// the stream is next read.
final class WebSocketStream: ChannelInboundHandler, TransportConnection, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    /// Queued bytes at which the stream stops reporting itself writable, and
    /// the level it must drain to before it says so again.
    static let highWaterMark = 64 * 1024
    static let lowWaterMark = 32 * 1024

    /// The largest frame sent. A receiver holds a frame until it has all of
    /// it, and a control frame cannot interrupt one, so a record is sent as
    /// frames no larger than the write high-water mark.
    static let maxOutboundFrame = 64 * 1024
    /// The largest frame accepted. A frame is buffered whole before any of it
    /// is delivered, so this is what a peer can make one connection hold
    /// beyond a socket read. It is well above what this stream sends because
    /// a browser sends each message as one frame of its own choosing.
    static let maxInboundFrame = 1024 * 1024

    let observedHost: String?
    private let channel: Channel
    /// The end that asked for the upgrade. It masks every frame it sends and
    /// is sent none that are masked; the server end is the reverse.
    private let isClient: Bool
    private let lock = NSLock()
    private var sink: (any TransportConnectionSink)?
    private var closeReported = false
    private var queuedBytes = 0
    private var saturated = false

    // Touched only on the channel's event loop.
    private var context: ChannelHandlerContext?
    private var requested = false
    private var pending = Data()
    private var midMessage = false
    private var closing = false
    private var pongInFlight = false
    private var owedPong: ByteBuffer?

    /// The channel is already upgraded, so it is active and stays unread
    /// until bytes are requested.
    init(channel: Channel, observedHost: String?, isClient: Bool) {
        self.channel = channel
        self.observedHost = observedHost
        self.isClient = isClient
    }

    var localHost: String? { channel.localAddress?.ipAddress }
    var isActive: Bool { channel.isActive }
    var isWritable: Bool { lock.withLock { queuedBytes < Self.highWaterMark } }

    func attach(_ sink: any TransportConnectionSink) {
        let alreadyClosed = lock.withLock { () -> Bool in
            if closeReported { return true }
            self.sink = sink
            return false
        }
        if alreadyClosed { sink.transportDidClose() }
    }

    func requestBytes() {
        channel.eventLoop.execute {
            self.requested = true
            if !self.pending.isEmpty {
                self.deliver()
            } else {
                self.context?.read()
            }
        }
    }

    func send(_ bytes: Data) {
        let becameSaturated = lock.withLock { () -> Bool in
            queuedBytes += bytes.count
            guard !saturated, queuedBytes >= Self.highWaterMark else { return false }
            saturated = true
            return true
        }
        channel.eventLoop.execute {
            if becameSaturated { self.currentSink?.transportWritabilityChanged(isWritable: false) }
            var buffer = self.channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            let promise = self.channel.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { _ in self.flushed(bytes.count) }
            // Each piece is a message of its own: the peer joins them anyway.
            while buffer.readableBytes > Self.maxOutboundFrame,
                  let piece = buffer.readSlice(length: Self.maxOutboundFrame) {
                self.channel.write(self.frame(.binary, piece), promise: nil)
            }
            self.channel.writeAndFlush(self.frame(.binary, buffer), promise: promise)
        }
    }

    func close() {
        channel.eventLoop.execute { self.shutDown(.normalClosure) }
    }

    private var currentSink: (any TransportConnectionSink)? {
        lock.withLock { sink }
    }

    private func flushed(_ count: Int) {
        let drained = lock.withLock { () -> Bool in
            queuedBytes -= count
            guard saturated, queuedBytes < Self.lowWaterMark else { return false }
            saturated = false
            return true
        }
        if drained { currentSink?.transportWritabilityChanged(isWritable: true) }
    }

    private func deliver() {
        guard requested, !pending.isEmpty else { return }
        requested = false
        let bytes = pending
        pending = Data()
        currentSink?.transportDidReceive(bytes)
    }

    private func reportClosed() {
        let sink = lock.withLock { () -> (any TransportConnectionSink)? in
            guard !closeReported else { return nil }
            closeReported = true
            defer { self.sink = nil }
            return self.sink
        }
        sink?.transportDidClose()
    }

    private func frame(_ opcode: WebSocketOpcode, _ data: ByteBuffer) -> WebSocketFrame {
        WebSocketFrame(fin: true, opcode: opcode, maskKey: isClient ? .random() : nil, data: data)
    }

    /// Says why and closes. The close frame goes as far as the socket takes
    /// it at once: a peer that is not reading is not waited for.
    private func shutDown(_ code: WebSocketErrorCode) {
        guard !closing else { return }
        closing = true
        var data = channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: code)
        channel.writeAndFlush(frame(.connectionClose, data), promise: nil)
        channel.close(promise: nil)
    }

    /// One pong is in flight at a time and the latest ping replaces any still
    /// waiting, as the protocol allows, so a peer that pings without reading
    /// cannot queue answers here.
    private func pong(_ payload: ByteBuffer) {
        guard !pongInFlight else {
            owedPong = payload
            return
        }
        pongInFlight = true
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { _ in
            self.pongInFlight = false
            guard let next = self.owedPong else { return }
            self.owedPong = nil
            self.pong(next)
        }
        channel.writeAndFlush(frame(.pong, payload), promise: promise)
    }

    // MARK: ChannelInboundHandler

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        reportClosed()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard !closing else { return }
        // No extension was negotiated, so no reserved bit has a meaning.
        guard !frame.rsv1, !frame.rsv2, !frame.rsv3, (frame.maskKey == nil) == isClient else {
            return shutDown(.protocolError)
        }
        switch frame.opcode {
        case .binary where !midMessage, .continuation where midMessage:
            midMessage = !frame.fin
            frame.unmaskedData.withUnsafeReadableBytes { pending.append(contentsOf: $0) }
        case .ping:
            pong(frame.unmaskedData)
        case .pong:
            break
        case .connectionClose:
            var payload = frame.unmaskedData
            shutDown(payload.readWebSocketErrorCode() ?? .normalClosure)
        case .text:
            shutDown(.unacceptableData)
        default:
            shutDown(.protocolError)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if pending.isEmpty {
            // Part of a frame, or only control frames: the request stands.
            if requested, !closing { context.read() }
        } else {
            deliver()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        reportClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
