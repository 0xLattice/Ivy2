import Foundation
import IvyCore
import NIOCore
import NIOPosix

/// The TCP transport under the core: it owns the sockets and turns what
/// happens on them into core events. It decides nothing about the protocol.
///
/// A connection is read only when the core has asked for it, one read at a
/// time: the next is issued once the core has handled the bytes of the last.
/// So a connection the core is holding back stays in the kernel's buffers,
/// and TCP holds the sender.
final class TCPShell: @unchecked Sendable {
    private let group: EventLoopGroup
    private let post: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var handlers: [ConnectionID: TCPConnectionHandler] = [:]
    private var nextConnection: UInt64 = 0
    private var listener: Channel?
    /// Inbound connections accepted and not yet seen by the core, bounded so
    /// a flood of accepts cannot queue without limit.
    private var unseenInbound = 0
    private var unseenByNetgroup: [String: Int] = [:]
    private var unseenNetgroups: [ConnectionID: String] = [:]
    private let maxUnseenInbound: Int
    private let maxUnseenPerNetgroup: Int

    init(
        group: EventLoopGroup,
        maxUnseenInbound: Int,
        maxUnseenPerNetgroup: Int,
        post: @escaping @Sendable (Event) -> Void
    ) {
        self.group = group
        self.maxUnseenInbound = maxUnseenInbound
        self.maxUnseenPerNetgroup = maxUnseenPerNetgroup
        self.post = post
    }

    var boundPort: UInt16? {
        lock.withLock { listener?.localAddress?.port.map(UInt16.init) }
    }

    // MARK: - Listening and dialling

    func listen(port: UInt16) async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.close() }
                let host = channel.remoteAddress?.ipAddress
                guard let id = self.admitInbound(host: host) else { return channel.close() }
                return self.install(channel, id: id, direction: .inbound)
            }
        let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
        lock.withLock { listener = channel }
    }

    func stopListening() async {
        let channel = lock.withLock { () -> Channel? in
            defer { listener = nil }
            return listener
        }
        try? await channel?.close().get()
    }

    func dial(_ dial: DialID, _ endpoint: PeerEndpoint) {
        let id = makeConnectionID()
        ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .channelOption(.autoRead, value: false)
            .channelInitializer { [weak self] channel in
                guard let self else { return channel.close() }
                return self.install(channel, id: id, direction: .outbound(dial))
            }
            .connect(host: endpoint.host, port: Int(endpoint.port))
            .whenFailure { [post] _ in post(.dialFailed(dial)) }
    }

    private func makeConnectionID() -> ConnectionID {
        lock.withLock {
            nextConnection += 1
            return ConnectionID(nextConnection)
        }
    }

    private func admitInbound(host: String?) -> ConnectionID? {
        let netgroup = NetGroup.group(host ?? "unknown")
        return lock.withLock {
            guard unseenInbound < maxUnseenInbound,
                  unseenByNetgroup[netgroup, default: 0] < maxUnseenPerNetgroup else { return nil }
            unseenInbound += 1
            unseenByNetgroup[netgroup, default: 0] += 1
            nextConnection += 1
            let id = ConnectionID(nextConnection)
            unseenNetgroups[id] = netgroup
            return id
        }
    }

    private func install(
        _ channel: Channel,
        id: ConnectionID,
        direction: ConnectionDirection
    ) -> EventLoopFuture<Void> {
        let handler = TCPConnectionHandler(id: id, direction: direction, shell: self)
        lock.withLock { handlers[id] = handler }
        return channel.pipeline.addHandler(handler)
    }

    // MARK: - What the core asks for

    func write(_ id: ConnectionID, _ bytes: Data) {
        handler(id)?.perform { $0.write(bytes) }
    }

    func close(_ id: ConnectionID) {
        handler(id)?.perform { $0.close() }
    }

    func setReading(_ id: ConnectionID, _ reading: Bool) {
        handler(id)?.perform { $0.setReading(reading) }
    }

    /// The core has handled an event about `id`: the bytes of its last read,
    /// or its opening.
    func processed(_ event: Event) {
        switch event {
        case .received(let id, _):
            handler(id)?.perform { $0.readProcessed() }
        case .connectionOpened(let id, .inbound, _, _):
            releaseUnseen(id)
        default:
            return
        }
    }

    /// Closes the listener and every connection, for a shell being discarded.
    func closeAll() {
        let (all, listening) = lock.withLock { () -> ([TCPConnectionHandler], Channel?) in
            defer { listener = nil }
            return (Array(handlers.values), listener)
        }
        listening?.close(promise: nil)
        for handler in all { handler.perform { $0.close() } }
    }

    private func handler(_ id: ConnectionID) -> TCPConnectionHandler? {
        lock.withLock { handlers[id] }
    }

    private func releaseUnseen(_ id: ConnectionID) {
        lock.withLock {
            guard let netgroup = unseenNetgroups.removeValue(forKey: id) else { return }
            unseenInbound -= 1
            let count = unseenByNetgroup[netgroup, default: 0] - 1
            unseenByNetgroup[netgroup] = count > 0 ? count : nil
        }
    }

    // MARK: - What the sockets report

    fileprivate func opened(
        _ id: ConnectionID,
        direction: ConnectionDirection,
        observedHost: String?,
        localHost: String?
    ) {
        post(.connectionOpened(
            id, direction: direction, observedHost: observedHost, localHost: localHost))
    }

    fileprivate func received(_ id: ConnectionID, _ bytes: Data) {
        post(.received(id, bytes))
    }

    fileprivate func drained(_ id: ConnectionID) {
        post(.writable(id))
    }

    fileprivate func ended(_ id: ConnectionID, opened: Bool, direction: ConnectionDirection) {
        lock.withLock { _ = handlers.removeValue(forKey: id) }
        releaseUnseen(id)
        if opened {
            post(.closed(id))
        } else if case .outbound(let dial) = direction {
            post(.dialFailed(dial))
        }
    }
}

/// One socket. Everything here runs on the channel's event loop.
private final class TCPConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let id: ConnectionID
    private let direction: ConnectionDirection
    private weak var shell: TCPShell?
    private var context: ChannelHandlerContext?
    private var eventLoop: EventLoop?
    private var opened = false
    /// The core wants this connection read.
    private var wantsRead = false
    /// A read's bytes are with the core and not yet handled.
    private var readOutstanding = false
    private var pendingBytes = Data()
    private var pendingWrites = 0

    init(id: ConnectionID, direction: ConnectionDirection, shell: TCPShell) {
        self.id = id
        self.direction = direction
        self.shell = shell
    }

    /// Runs `body` on the event loop, if the handler is in a pipeline.
    func perform(_ body: @escaping @Sendable (TCPConnectionHandler) -> Void) {
        guard let eventLoop else { return }
        if eventLoop.inEventLoop {
            body(self)
        } else {
            eventLoop.execute { body(self) }
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        eventLoop = context.eventLoop
        if context.channel.isActive { announce(context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        announce(context)
        context.fireChannelActive()
    }

    private func announce(_ context: ChannelHandlerContext) {
        guard !opened else { return }
        opened = true
        shell?.opened(
            id,
            direction: direction,
            observedHost: context.channel.remoteAddress?.ipAddress,
            localHost: context.channel.localAddress?.ipAddress)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            pendingBytes.append(contentsOf: bytes)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        guard !pendingBytes.isEmpty else {
            if wantsRead, !readOutstanding { context.read() }
            return
        }
        let bytes = pendingBytes
        pendingBytes = Data()
        readOutstanding = true
        shell?.received(id, bytes)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.context = nil
        context.fireChannelInactive()
    }

    /// The pipeline is gone, whether or not the socket ever connected.
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        shell?.ended(id, opened: opened, direction: direction)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func setReading(_ reading: Bool) {
        wantsRead = reading
        if reading, !readOutstanding { context?.read() }
    }

    func readProcessed() {
        readOutstanding = false
        if wantsRead { context?.read() }
    }

    func write(_ bytes: Data) {
        guard let context else { return }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        pendingWrites += 1
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak self] _ in
            guard let self else { return }
            self.pendingWrites -= 1
            // Everything written has left the send buffer: the core may write more.
            if self.pendingWrites == 0, self.context != nil { self.shell?.drained(self.id) }
        }
        context.writeAndFlush(wrapOutboundOut(buffer), promise: promise)
    }

    func close() {
        context?.close(promise: nil)
    }
}
