import Foundation
import IvyCore
import NIOCore
import NIOPosix

/// A TCP connection as a `TransportConnection`: the stream Ivy supplies
/// itself. The socket is read only when bytes are requested, so a consumer
/// that stops asking leaves the data in the kernel and TCP holds the sender.
final class TCPStream: ChannelInboundHandler, TransportConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// Queued bytes at which the stream stops reporting itself writable, and
    /// the level it must drain to before it says so again.
    static let highWaterMark = 64 * 1024
    static let lowWaterMark = 32 * 1024

    private let channel: Channel
    private let lock = NSLock()
    private var sink: (any TransportConnectionSink)?
    private var closeReported = false
    private var queuedBytes = 0
    private var saturated = false

    // Touched only on the channel's event loop.
    private var context: ChannelHandlerContext?
    private var requested = false
    private var pending = Data()

    init(channel: Channel) {
        self.channel = channel
    }

    var observedHost: String? { channel.remoteAddress?.ipAddress }
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
            } else if self.channel.isActive {
                self.context?.read()
            }
            // A socket that is not active yet is read when it becomes so.
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
            self.channel.writeAndFlush(buffer, promise: promise)
        }
    }

    func close() {
        channel.close(promise: nil)
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

    // MARK: ChannelInboundHandler

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        reportClosed()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            pending.append(contentsOf: bytes)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if pending.isEmpty {
            if requested { context.read() }
        } else {
            deliver()
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        // A request made before the socket was active could not be read then.
        if requested, pending.isEmpty { context.read() }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        reportClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Listens and dials over TCP, handing every connection to the stream shell
/// the same way any other supplier of streams would.
final class TCPTransport: @unchecked Sendable {
    private let group: EventLoopGroup
    private let shell: StreamShell
    private let lock = NSLock()
    private var listener: Channel?

    init(group: EventLoopGroup, shell: StreamShell) {
        self.group = group
        self.shell = shell
    }

    var boundPort: UInt16? {
        lock.withLock { listener?.localAddress?.port.map(UInt16.init) }
    }

    func listen(port: UInt16) async throws {
        let shell = self.shell
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { channel in
                // Admission comes first: a refused socket is closed before
                // anything is read from it.
                guard let lease = shell.reserve(
                    observedHost: channel.remoteAddress?.ipAddress) else {
                    return channel.close()
                }
                let stream = TCPStream(channel: channel)
                return channel.pipeline.addHandler(stream).map {
                    shell.accept(stream, admission: lease)
                }
            }
        let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
        lock.withLock { listener = channel }
    }

    func stopListening() async {
        try? await takeListener()?.close().get()
    }

    func closeListener() {
        takeListener()?.close(promise: nil)
    }

    private func takeListener() -> Channel? {
        lock.withLock {
            defer { listener = nil }
            return listener
        }
    }

    func dial(_ dial: DialID, _ endpoint: PeerEndpoint) {
        let shell = self.shell
        ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .channelOption(.autoRead, value: false)
            .channelInitializer { channel in
                channel.pipeline.addHandler(TCPStream(channel: channel))
            }
            .connect(host: endpoint.host, port: Int(endpoint.port))
            .flatMap { $0.pipeline.handler(type: TCPStream.self) }
            .whenComplete { result in
                switch result {
                case .success(let stream):
                    shell.opened(stream, for: dial)
                case .failure:
                    shell.dialFailed(dial)
                }
            }
    }
}
