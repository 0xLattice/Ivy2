import Foundation
import Ivy
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// Why a WebSocket to a peer could not be opened.
public enum WebSocketConnectError: Error, Sendable, Equatable {
    /// The server answered the upgrade request with this HTTP status.
    case refused(status: UInt)
    /// The connection ended before the upgrade was answered.
    case noAnswer
}

/// Listens and dials over WebSocket for an `Ivy` node, so a peer that cannot
/// open a TCP connection, such as a browser, can reach it. Every upgraded
/// connection is handed to the node the way any supplied stream is.
///
/// There is no TLS here: `wss` is terminated in front of the listener.
public final class WebSocketTransport: @unchecked Sendable {
    private let ivy: Ivy
    private let group: EventLoopGroup
    /// A socket still in the HTTP exchange holds no admission, so those are
    /// bounded here: `maxHandshakes` at once, each for `handshakeTimeout`.
    private let maxHandshakes: Int
    private let handshakeTimeout: TimeAmount
    private let lock = NSLock()
    private var listening = false
    private var listener: Channel?
    private var stunResponder: Channel?
    private var handshakes: [ObjectIdentifier: Channel] = [:]

    public convenience init(
        ivy: Ivy,
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.init(ivy: ivy, group: group, maxHandshakes: 256, handshakeTimeout: .seconds(10))
    }

    init(ivy: Ivy, group: EventLoopGroup, maxHandshakes: Int, handshakeTimeout: TimeAmount) {
        self.ivy = ivy
        self.group = group
        self.maxHandshakes = maxHandshakes
        self.handshakeTimeout = handshakeTimeout
    }

    deinit {
        listener?.close(promise: nil)
        stunResponder?.close(promise: nil)
        for channel in handshakes.values { channel.close(promise: nil) }
    }

    /// The port the listener is bound to; differs from the one asked for only
    /// when that was 0.
    public var boundPort: UInt16? {
        lock.withLock { listener?.localAddress?.port.map(UInt16.init) }
    }

    /// Accepts WebSocket upgrades of `path`; anything else gets an HTTP
    /// error. The node must be started: it refuses admission until it is.
    /// Does nothing while already listening.
    ///
    /// `trustForwardedFor` takes the peer's address from the last hop of
    /// `X-Forwarded-For` instead of from the socket. Set it only behind a
    /// proxy that writes that hop itself, and that nothing can bypass: the
    /// address decides netgroup admission, and a peer that can reach the
    /// listener directly would choose its own.
    ///
    /// With `stun`, STUN Binding requests are answered on the same port over
    /// UDP, which is where a browser connected here asks for its own address
    /// before it connects to another browser. Behind a proxy, that is the
    /// port the browser dials, and its UDP must be passed on to this one.
    public func listen(
        host: String = "0.0.0.0",
        port: UInt16,
        path: String = "/ivy",
        trustForwardedFor: Bool = false,
        stun: Bool = true
    ) async throws {
        let starting = lock.withLock { () -> Bool in
            defer { listening = true }
            return !listening
        }
        guard starting else { return }
        let ivy = self.ivy
        let timeout = handshakeTimeout
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let transport = self, transport.beginHandshake(channel) else {
                    return channel.close()
                }
                let handshake = ServerHandshake(
                    ivy: ivy, path: path, trustForwardedFor: trustForwardedFor, timeout: timeout)
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: WebSocketStream.maxInboundFrame,
                    shouldUpgrade: { channel, head in
                        channel.eventLoop.makeSucceededFuture(
                            handshake.admit(head, from: channel) ? HTTPHeaders() : nil)
                    },
                    upgradePipelineHandler: { channel, _ in
                        // From here the socket is read only when Ivy asks.
                        channel.setOption(.autoRead, value: false).flatMap {
                            channel.pipeline.removeHandler(handshake)
                        }.flatMapThrowing {
                            transport.endHandshake(channel)
                            guard let (host, lease) = handshake.takeAdmission() else {
                                return channel.close(promise: nil)
                            }
                            let stream = WebSocketStream(
                                channel: channel, observedHost: host, isClient: false)
                            try channel.pipeline.syncOperations.addHandler(stream)
                            ivy.accept(stream, admission: lease)
                        }
                    })
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                ).flatMap {
                    channel.pipeline.addHandler(handshake)
                }
            }
        do {
            // A port of the system's choosing is free for TCP and may not be
            // for UDP, so another is asked for.
            var attempts = port == 0 && stun ? 8 : 1
            while true {
                attempts -= 1
                let channel = try await bootstrap.bind(host: host, port: Int(port)).get()
                guard stun else { return lock.withLock { listener = channel } }
                do {
                    let responder = try await DatagramBootstrap(group: group)
                        .channelInitializer { $0.pipeline.addHandler(STUNResponder()) }
                        .bind(host: host, port: channel.localAddress?.port ?? Int(port)).get()
                    return lock.withLock {
                        listener = channel
                        stunResponder = responder
                    }
                } catch {
                    try? await channel.close().get()
                    if attempts == 0 { throw error }
                }
            }
        } catch {
            lock.withLock { listening = false }
            throw error
        }
    }

    /// Closes the listener, the STUN responder and every socket that has not
    /// been upgraded yet.
    /// Upgraded connections are the node's, and close with it.
    public func stopListening() async {
        let (listener, responder, waiting) = lock.withLock { () -> (Channel?, Channel?, [Channel]) in
            defer {
                listening = false
                self.listener = nil
                stunResponder = nil
                handshakes = [:]
            }
            return (self.listener, stunResponder, Array(handshakes.values))
        }
        for channel in waiting { channel.close(promise: nil) }
        try? await responder?.close().get()
        try? await listener?.close().get()
    }

    private func beginHandshake(_ channel: Channel) -> Bool {
        let begun = lock.withLock { () -> Bool in
            guard listening, handshakes.count < maxHandshakes else { return false }
            handshakes[ObjectIdentifier(channel)] = channel
            return true
        }
        if begun { channel.closeFuture.whenComplete { [weak self] _ in self?.endHandshake(channel) } }
        return begun
    }

    private func endHandshake(_ channel: Channel) {
        lock.withLock { handshakes[ObjectIdentifier(channel)] = nil }
    }

    /// Opens a WebSocket to `host:port` at `path` and connects to `endpoint`
    /// over it, with this node as the initiator. Throws what opening the
    /// socket throws, a `WebSocketConnectError` when the upgrade is not
    /// granted, and otherwise what `Ivy.connect(to:over:)` throws.
    public func connect(
        to endpoint: PeerEndpoint,
        host: String,
        port: UInt16,
        path: String = "/ivy"
    ) async throws {
        try await ivy.connect(to: endpoint, over: await open(host: host, port: port, path: path))
    }

    func open(host: String, port: UInt16, path: String) async throws -> WebSocketStream {
        let upgraded = group.next().makePromise(of: WebSocketStream.self)
        let timeout = handshakeTimeout
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                let handshake = ClientHandshake(
                    authority: host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)",
                    path: path, timeout: timeout, upgraded: upgraded)
                let upgrader = NIOWebSocketClientUpgrader(
                    maxFrameSize: WebSocketStream.maxInboundFrame,
                    upgradePipelineHandler: { channel, _ in
                        channel.setOption(.autoRead, value: false).flatMap {
                            channel.pipeline.removeHandler(handshake)
                        }.flatMapThrowing {
                            let stream = WebSocketStream(
                                channel: channel,
                                observedHost: channel.remoteAddress?.ipAddress,
                                isClient: true)
                            try channel.pipeline.syncOperations.addHandler(stream)
                            upgraded.succeed(stream)
                        }
                    })
                return channel.pipeline.addHTTPClientHandlers(
                    withClientUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                ).flatMap {
                    channel.pipeline.addHandler(handshake)
                }
            }
        do {
            _ = try await bootstrap.connect(host: host, port: Int(port)).get()
        } catch {
            upgraded.fail(error)
            throw error
        }
        return try await upgraded.futureResult.get()
    }
}

/// The server's side of the HTTP exchange: decides whether a request may
/// upgrade, and answers the request that did not.
private final class ServerHandshake: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let ivy: Ivy
    private let path: String
    private let trustForwardedFor: Bool
    private let timeout: TimeAmount

    // Touched only on the channel's event loop.
    private var deadline: Scheduled<Void>?
    private var admission: (host: String, lease: InboundAdmissionLease)?
    private var refused = false
    private var answered = false

    init(ivy: Ivy, path: String, trustForwardedFor: Bool, timeout: TimeAmount) {
        self.ivy = ivy
        self.path = path
        self.trustForwardedFor = trustForwardedFor
        self.timeout = timeout
    }

    /// Admission comes before the upgrade is granted: a refused peer is
    /// never upgraded, and nothing of its stream is read.
    func admit(_ head: HTTPRequestHead, from channel: Channel) -> Bool {
        guard head.path == path else { return false }
        let host = trustForwardedFor
            ? head.headers[canonicalForm: "X-Forwarded-For"].last.flatMap {
                try? SocketAddress(ipAddress: String($0), port: 0).ipAddress
            }
            : channel.remoteAddress?.ipAddress
        guard let host, let lease = ivy.reserveInboundAdmission(observedHost: host) else {
            refused = true
            return false
        }
        admission = (host, lease)
        return true
    }

    func takeAdmission() -> (host: String, lease: InboundAdmissionLease)? {
        defer { admission = nil }
        return admission
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        deadline = context.eventLoop.scheduleTask(in: timeout) { channel.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        deadline?.cancel()
    }

    /// Only a request that was not upgraded gets this far.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(let head) = unwrapInboundIn(data), !answered else { return }
        answered = true
        var headers = HTTPHeaders([("Content-Length", "0")])
        let status: HTTPResponseStatus
        if head.path != path {
            status = .notFound
        } else if refused {
            status = .serviceUnavailable
        } else {
            // Not an upgrade, or not to a WebSocket of the one version there is.
            status = .upgradeRequired
            headers.add(name: "Upgrade", value: "websocket")
            headers.add(name: "Sec-WebSocket-Version", value: "13")
        }
        headers.add(name: "Connection", value: status == .upgradeRequired ? "Upgrade, close" : "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(
            version: .http1_1, status: status, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // A request that does not parse has been answered by the HTTP
        // handlers, which then wait for the peer to hang up. A declined
        // upgrade is also reported here, ahead of its request: that one is
        // answered above.
        if error is HTTPParserError { context.close(promise: nil) }
    }
}

/// The client's side of the HTTP exchange: asks for the upgrade, and fails
/// the dial when the answer is anything else.
private final class ClientHandshake: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let authority: String
    private let path: String
    private let timeout: TimeAmount
    private let upgraded: EventLoopPromise<WebSocketStream>
    private var deadline: Scheduled<Void>?

    init(authority: String, path: String, timeout: TimeAmount, upgraded: EventLoopPromise<WebSocketStream>) {
        self.authority = authority
        self.path = path
        self.timeout = timeout
        self.upgraded = upgraded
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        deadline = context.eventLoop.scheduleTask(in: timeout) { channel.close(promise: nil) }
        // The upgrade handler adds the WebSocket headers on the way out.
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: path)
        head.headers.add(name: "Host", value: authority)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        deadline?.cancel()
    }

    /// Only a response that is not the upgrade gets this far.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(let head) = unwrapInboundIn(data) else { return }
        upgraded.fail(WebSocketConnectError.refused(status: head.status.code))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        upgraded.fail(WebSocketConnectError.noAnswer)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upgraded.fail(error)
        context.close(promise: nil)
    }
}

private extension HTTPRequestHead {
    /// The request target without its query.
    var path: Substring { uri.prefix { $0 != "?" } }
}
