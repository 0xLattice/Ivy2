import Foundation
import IvyCore
import NIOCore
import NIOPosix

/// A direct TCP connection between two peers that start at the same moment,
/// each from a port it told the other. Each peer's first packet opens its own
/// NAT for the other's, so neither needs to be reachable beforehand.
///
/// The port is one the system chose, and a NAT is assumed to keep it: one
/// that gives the connection another port outside cannot be reached this way.
/// IPv4 only.
public struct TCPPunch: PunchTransport {
    public let kind: UInt8 = PunchCandidate.tcp
    private let group: EventLoopGroup

    public init(group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.group = group
    }

    public func prepare() async -> (any PunchSocket)? {
        let socket = TCPPunchSocket(group: group)
        return await socket.listen() ? socket : nil
    }
}

final class TCPPunchSocket: PunchSocket, @unchecked Sendable {
    /// Connections taken before the peer's addresses are known.
    static let maxWaiting = 4
    /// One try at a candidate, and the pause before the next.
    static let connectTimeout = TimeAmount.milliseconds(1_500)
    static let retryInterval = Duration.milliseconds(100)

    private let group: EventLoopGroup
    private let lock = NSLock()
    private var listener: Channel?
    private var closed = false
    /// The peer's hosts, once known: a connection from anywhere else is not it.
    private var expected: Set<String>?
    private var waiting: [TCPStream] = []
    private var winner: TCPStream?
    private var claimed = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(group: EventLoopGroup) {
        self.group = group
    }

    var port: UInt16 {
        lock.withLock { listener?.localAddress?.port.flatMap(UInt16.init(exactly:)) } ?? 0
    }

    /// Holds the port, and takes the connection if the peer's packet is the
    /// one that gets through. Both options are what let a connection leave
    /// from a port that is also listened on.
    func listen() async -> Bool {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(.socketOption(.so_reuseport), value: 1)
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { [weak self] channel in
                let stream = TCPStream(channel: channel)
                return channel.pipeline.addHandler(stream).map { [weak self] in
                    if let self { self.arrived(stream) } else { stream.close() }
                }
            }
        guard let channel = try? await bootstrap.bind(host: "0.0.0.0", port: 0).get() else { return false }
        lock.withLock { listener = channel }
        return true
    }

    func connect(
        to candidates: [PunchCandidate],
        deadline: ContinuousClock.Instant
    ) async -> (any TransportConnection)? {
        let targets = candidates.filter { $0.transport == PunchCandidate.tcp && !$0.host.contains(":") }
        guard !targets.isEmpty else { return nil }
        let early = lock.withLock { () -> [TCPStream] in
            expected = Set(targets.map(\.host))
            defer { waiting = [] }
            return waiting
        }
        for stream in early { arrived(stream) }

        let port = self.port
        let dialling = Task {
            while !Task.isCancelled, ContinuousClock.now < deadline {
                for target in targets where !Task.isCancelled {
                    if let stream = await self.dial(target, from: port) { self.arrived(stream) }
                }
                try? await Task.sleep(for: Self.retryInterval)
            }
        }
        let expiry = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            self.wake()
        }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if winner != nil || closed || ContinuousClock.now >= deadline { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        dialling.cancel()
        expiry.cancel()
        return lock.withLock { () -> TCPStream? in
            claimed = winner != nil
            return winner
        }
    }

    func close() {
        let (listener, streams) = lock.withLock { () -> (Channel?, [TCPStream]) in
            closed = true
            defer {
                self.listener = nil
                waiting = []
            }
            // A stream the caller was given is the caller's.
            return (self.listener, waiting + (claimed ? [] : [winner].compactMap { $0 }))
        }
        listener?.close(promise: nil)
        for stream in streams { stream.close() }
        wake()
    }

    private func dial(_ target: PunchCandidate, from port: UInt16) async -> TCPStream? {
        guard let local = try? SocketAddress(ipAddress: "0.0.0.0", port: Int(port)),
              let remote = try? SocketAddress(ipAddress: target.host, port: Int(target.port)) else { return nil }
        return try? await ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(.socketOption(.so_reuseport), value: 1)
            .channelOption(.autoRead, value: false)
            .connectTimeout(Self.connectTimeout)
            .channelInitializer { $0.pipeline.addHandler(TCPStream(channel: $0)) }
            .bind(to: local)
            .connect(to: remote)
            .flatMap { $0.pipeline.handler(type: TCPStream.self) }
            .get()
    }

    /// The first connection with the peer is the one kept. Two ends can only
    /// have made one: both leave from the port the other aims at.
    private func arrived(_ stream: TCPStream) {
        let keep = lock.withLock { () -> Bool in
            guard !closed, winner == nil else { return false }
            guard let expected else {
                guard waiting.count < Self.maxWaiting else { return false }
                waiting.append(stream)
                return true
            }
            guard let host = stream.observedHost, expected.contains(host) else { return false }
            winner = stream
            return true
        }
        if keep { wake() } else { stream.close() }
    }

    private func wake() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }
}
