import Foundation
import IvyCore
import Tally

/// An address a peer can be reached at for one attempt.
public struct PunchCandidate: Sendable, Equatable {
    public static let tcp: UInt8 = 1
    public static let quic: UInt8 = 2

    public let transport: UInt8
    public let host: String
    public let port: UInt16

    public init(transport: UInt8, host: String, port: UInt16) {
        self.transport = transport
        self.host = host
        self.port = port
    }
}

/// One way of making a stream between two peers that both start at once.
public protocol PunchTransport: Sendable {
    /// Its number in a candidate.
    var kind: UInt8 { get }
    /// Readies one attempt, or returns nil when it cannot take part.
    func prepare() async -> (any PunchSocket)?
}

/// What one transport holds for one attempt.
public protocol PunchSocket: Sendable {
    /// The port the peer is to aim at, on each address this node offers.
    var port: UInt16 { get }
    /// Tries the peer's candidates until one stream to it exists or
    /// `deadline` passes. The peer is doing the same at the same moment.
    func connect(
        to candidates: [PunchCandidate],
        deadline: ContinuousClock.Instant
    ) async -> (any TransportConnection)?
    /// Releases everything but a stream `connect` returned.
    func close()
}

/// Moves two peers that met through a carrier onto a connection of their
/// own. Neither has to be reachable: they tell each other where they are over
/// the relayed session and both start at once, so each one's first packet
/// opens its own NAT to the other's. Where that fails the relayed session
/// stays as it was.
///
/// It stands between a node and its delegate, which it must be installed as:
/// it takes the messages on its topic and passes everything else on.
public final class PunchConnector: IvyDelegate, @unchecked Sendable {
    public struct Options: Sendable {
        /// Try as soon as a relayed session to an endpoint appears.
        public var autoUpgrade = true
        /// How long an attempt may take, and how long of that both ends dial.
        public var deadline: Duration = .seconds(15)
        public var dialWindow: Duration = .seconds(6)
        /// The addresses offered to a peer. Nil offers the node's public one.
        public var hosts: [String]?
        /// Dial candidates that are not public addresses: for peers on one
        /// private network, and for tests.
        public var allowPrivateCandidates = false

        public init() {}
    }

    /// The topic the signalling travels on.
    public static let topic = "ivy.punch/1"

    private static let kindRequest: UInt8 = 0
    private static let kindOffer: UInt8 = 1
    private static let kindAnswer: UInt8 = 2
    private static let kindSync: UInt8 = 3
    private static let kindAbandon: UInt8 = 4

    static let maxSignalBytes = 1024
    static let maxCandidates = 8
    /// Messages taken for one attempt.
    static let maxSignals = 8
    /// Attempts on one relayed session, whoever asks for them, and at once.
    static let maxAttempts = 3
    static let maxConcurrentAttempts = 8

    private enum Phase {
        /// The other end was asked to offer.
        case requested
        case preparing
        case awaitingAnswer(sent: ContinuousClock.Instant)
        case awaitingSync
        case dialling
        /// The stream was given to the node, whose handshake decides the rest.
        case handed
    }

    /// Read and written with the connector's lock held.
    private final class Attempt: @unchecked Sendable {
        let peer: String
        let session: AuthenticatedPeer
        /// Zero until the offer that names it is made or arrives.
        var id: UInt32 = 0
        var phase: Phase
        var sockets: [any PunchSocket] = []
        var remote: [PunchCandidate] = []
        var received = 0
        var timer: Task<Void, Never>?
        var waiters: [CheckedContinuation<Bool, Never>] = []

        init(peer: String, session: AuthenticatedPeer, phase: Phase) {
            self.peer = peer
            self.session = session
            self.phase = phase
        }
    }

    private let ivy: Ivy
    private let localKey: String
    private let transports: [any PunchTransport]
    private let options: Options
    private weak var inner: (any IvyDelegate)?

    private let lock = NSLock()
    /// The session each peer has now, and the attempts made on it.
    private var sessions: [String: (session: AuthenticatedPeer, attempts: Int)] = [:]
    private var attempts: [String: Attempt] = [:]
    private var lastAttempt: UInt32 = 0
    private var closed = false

    /// `localKey` is the node's own public key, `IvyConfig.publicKey`.
    /// `inner` is the application's delegate, held as weakly as a node holds
    /// its own.
    public init(
        ivy: Ivy,
        localKey: String,
        transports: [any PunchTransport] = [TCPPunch()],
        forwardingTo inner: (any IvyDelegate)? = nil,
        options: Options = Options()
    ) {
        self.ivy = ivy
        self.localKey = localKey
        self.transports = transports
        self.inner = inner
        self.options = options
    }

    // MARK: - IvyDelegate

    public func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
        connected(peer)
        await inner?.ivy(ivy, didConnect: peer)
    }

    public func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        disconnected(peer.publicKey)
        inner?.ivy(ivy, didDisconnect: peer)
    }

    public func ivy(_ ivy: Ivy, didDiscoverPublicAddress address: ObservedAddress) {
        inner?.ivy(ivy, didDiscoverPublicAddress: address)
    }

    public func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        guard message.topic == Self.topic else {
            await inner?.ivy(ivy, didReceiveMessage: message, from: peer)
            return
        }
        await signalled(message.payload, from: peer)
    }

    // MARK: - Upgrading

    /// Tries to move the peer of a relayed session onto a connection of its
    /// own. True when the peer's session is direct, and false when it is not:
    /// the attempt failed or ran out of time, `session` is no longer the
    /// peer's, or too many attempts were made on it. The relayed session is
    /// left as it was. An attempt already running is joined, not repeated.
    public func upgrade(_ session: AuthenticatedPeer) async -> Bool {
        let peer = session.key.hex
        enum Start { case done(Bool), join(Attempt), offer(Attempt), request(Attempt) }
        let start = lock.withLock { () -> Start in
            guard !closed, let known = sessions[peer], known.session.role == .endpoint else { return .done(false) }
            if known.session.route == .direct { return .done(true) }
            guard known.session.sessionID == session.sessionID else { return .done(false) }
            if let running = attempts[peer] { return .join(running) }
            guard let attempt = begin(peer, phase: offers(peer) ? .preparing : .requested) else {
                return .done(false)
            }
            return offers(peer) ? .offer(attempt) : .request(attempt)
        }
        switch start {
        case .done(let direct):
            return direct
        case .join(let attempt):
            return await outcome(of: attempt)
        case .offer(let attempt):
            Task { await self.offer(attempt) }
            return await outcome(of: attempt)
        case .request(let attempt):
            Task {
                if await !self.send(attempt, Self.kindRequest) { self.end(attempt, tell: false) }
            }
            return await outcome(of: attempt)
        }
    }

    /// Ends every attempt. Sessions already direct are the node's.
    public func close() {
        let running = lock.withLock { () -> [Attempt] in
            closed = true
            sessions = [:]
            return Array(attempts.values)
        }
        for attempt in running { end(attempt, tell: false) }
    }

    // MARK: - Sessions

    private func connected(_ session: AuthenticatedPeer) {
        let peer = session.key.hex
        let replaced = lock.withLock { () -> Attempt? in
            guard !closed else { return nil }
            sessions[peer] = (session, 0)
            return attempts[peer]
        }
        // Whatever was being tried was for the session this one replaced.
        if let replaced { end(replaced, tell: false, direct: session.route == .direct) }
        if options.autoUpgrade, session.role == .endpoint, session.route != .direct {
            Task { _ = await self.upgrade(session) }
        }
    }

    private func disconnected(_ peer: String) {
        let ending = lock.withLock { () -> Attempt? in
            sessions[peer] = nil
            guard let attempt = attempts[peer] else { return nil }
            // The end that finishes the handshake first closes the relayed
            // session, and that can be heard of here before the handshake's
            // last record has crossed. A stream the node holds is left to it.
            if case .handed = attempt.phase { return nil }
            return attempt
        }
        if let ending { end(ending, tell: false) }
    }

    // MARK: - Attempts

    /// One of two peers offers, and both know which.
    private func offers(_ peer: String) -> Bool { localKey < peer }

    /// Call with the lock held.
    private func begin(_ peer: String, phase: Phase) -> Attempt? {
        guard var known = sessions[peer], known.attempts < Self.maxAttempts,
              attempts.count < Self.maxConcurrentAttempts else { return nil }
        known.attempts += 1
        sessions[peer] = known
        let attempt = Attempt(peer: peer, session: known.session, phase: phase)
        attempts[peer] = attempt
        let deadline = options.deadline
        attempt.timer = Task { [weak self] in
            guard (try? await Task.sleep(for: deadline)) != nil else { return }
            self?.end(attempt, tell: true)
        }
        return attempt
    }

    private func isLive(_ attempt: Attempt) -> Bool {
        lock.withLock { attempts[attempt.peer] === attempt }
    }

    private func outcome(of attempt: Attempt) async -> Bool {
        await withCheckedContinuation { continuation in
            let over = lock.withLock { () -> Bool? in
                guard attempts[attempt.peer] === attempt else {
                    return sessions[attempt.peer]?.session.route == .direct
                }
                attempt.waiters.append(continuation)
                return nil
            }
            if let over { continuation.resume(returning: over) }
        }
    }

    /// Ends an attempt. A stream already given to the node is the node's.
    private func end(_ attempt: Attempt, tell: Bool, direct: Bool = false) {
        let ended = lock.withLock { () -> (id: UInt32, waiters: [CheckedContinuation<Bool, Never>])? in
            guard attempts[attempt.peer] === attempt else { return nil }
            attempts[attempt.peer] = nil
            defer { attempt.waiters = [] }
            return (attempt.id, attempt.waiters)
        }
        guard let ended else { return }
        attempt.timer?.cancel()
        for socket in lock.withLock({ attempt.sockets }) { socket.close() }
        if tell, ended.id != 0 {
            Task { _ = await self.send(attempt, Self.kindAbandon, id: ended.id) }
        }
        for waiter in ended.waiters { waiter.resume(returning: direct) }
    }

    /// Readies every transport and returns what to tell the peer, or nil
    /// when the attempt is over or there is nothing to tell.
    private func prepare(_ attempt: Attempt) async -> [PunchCandidate]? {
        var sockets: [(kind: UInt8, socket: any PunchSocket)] = []
        for transport in transports {
            if let socket = await transport.prepare() { sockets.append((transport.kind, socket)) }
        }
        let kept = lock.withLock { () -> Bool in
            guard attempts[attempt.peer] === attempt else { return false }
            attempt.sockets = sockets.map(\.socket)
            return true
        }
        guard kept else {
            for (_, socket) in sockets { socket.close() }
            return nil
        }
        var hosts = options.hosts ?? []
        if options.hosts == nil, let host = await ivy.publicAddress?.host { hosts = [host] }
        let candidates = hosts.flatMap { host in
            sockets.compactMap { $0.socket.port == 0 ? nil : PunchCandidate(transport: $0.kind, host: host, port: $0.socket.port) }
        }
        return candidates.isEmpty ? nil : Array(candidates.prefix(Self.maxCandidates))
    }

    private func offer(_ attempt: Attempt) async {
        guard let candidates = await prepare(attempt) else { return end(attempt, tell: false) }
        let id = lock.withLock { () -> UInt32? in
            guard attempts[attempt.peer] === attempt else { return nil }
            lastAttempt = lastAttempt % .max + 1
            attempt.id = lastAttempt
            attempt.phase = .awaitingAnswer(sent: .now)
            return lastAttempt
        }
        guard let id else { return }
        if await !send(attempt, Self.kindOffer, id: id, body: Self.encode(candidates)) {
            end(attempt, tell: false)
        }
    }

    private func answer(_ attempt: Attempt, id: UInt32) async {
        guard let candidates = await prepare(attempt) else { return end(attempt, tell: true) }
        let live = lock.withLock { () -> Bool in
            guard attempts[attempt.peer] === attempt else { return false }
            attempt.phase = .awaitingSync
            return true
        }
        guard live else { return }
        if await !send(attempt, Self.kindAnswer, id: id, body: Self.encode(candidates)) {
            end(attempt, tell: false)
        }
    }

    /// Both ends are here at about the same moment.
    private func dial(_ attempt: Attempt) async {
        let (sockets, remote) = lock.withLock { (attempt.sockets, attempt.remote) }
        let deadline = ContinuousClock.now + options.dialWindow
        let stream = await withTaskGroup(of: (any TransportConnection)?.self) { group in
            for socket in sockets {
                group.addTask { await socket.connect(to: remote, deadline: deadline) }
            }
            var first: (any TransportConnection)?
            for await stream in group {
                // One is enough, and the transports that lost are told so.
                if first == nil, let stream {
                    first = stream
                    for socket in sockets { socket.close() }
                } else {
                    stream?.close()
                }
            }
            return first
        }
        let handed = lock.withLock { () -> Bool in
            guard attempts[attempt.peer] === attempt, stream != nil else { return false }
            attempt.phase = .handed
            return true
        }
        guard handed, let stream else {
            stream?.close()
            return end(attempt, tell: true)
        }
        guard offers(attempt.peer) else {
            // The other end's handshake arrives on it; `connected` hears of
            // the session it makes, and the deadline of one that never does.
            guard let lease = ivy.reserveInboundAdmission(observedHost: stream.observedHost) else {
                stream.close()
                return end(attempt, tell: true)
            }
            return ivy.accept(stream, admission: lease)
        }
        let endpoint = PeerEndpoint(publicKey: attempt.peer, host: stream.observedHost ?? "", port: 0)
        try? await ivy.connect(to: endpoint, over: stream)
        // `connect` reports a peer that is connected, by either route.
        let direct = lock.withLock { sessions[attempt.peer]?.session.route == .direct }
        end(attempt, tell: !direct, direct: direct)
    }

    // MARK: - Signalling

    private func send(_ attempt: Attempt, _ kind: UInt8, id: UInt32 = 0, body: Data = Data()) async -> Bool {
        var payload = Data([kind])
        payload.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Array($0) })
        payload.append(body)
        if case .enqueued = await ivy.sendMessage(to: attempt.session, topic: Self.topic, payload: payload) {
            return true
        }
        return false
    }

    private func signalled(_ payload: Data, from: AuthenticatedPeer) async {
        let peer = from.key.hex
        let payload = Data(payload)
        let (known, attempt) = lock.withLock { (sessions[peer], attempts[peer]) }
        guard from.role == .endpoint, from.route != .direct,
              let known, known.session.sessionID == from.sessionID else { return }
        func malformed() {
            if let attempt { end(attempt, tell: true) }
        }
        guard payload.count >= 5, payload.count <= Self.maxSignalBytes else { return malformed() }
        let kind = payload[0]
        guard kind <= Self.kindAbandon else { return malformed() }
        let id = payload[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let body = payload.dropFirst(5)

        if kind == Self.kindRequest {
            guard id == 0, body.isEmpty else { return malformed() }
            if attempt == nil, offers(peer) { Task { _ = await self.upgrade(known.session) } }
            return
        }
        if kind == Self.kindOffer {
            // This end is the one that offers: the peer's offer is dropped,
            // and its own attempt goes on.
            if offers(peer) { return }
            guard id != 0, let candidates = Self.decode(body) else { return malformed() }
            let remote = await acceptable(candidates)
            let answering = lock.withLock { () -> Attempt? in
                guard !closed, sessions[peer]?.session.sessionID == from.sessionID else { return nil }
                // One attempt at a time. An offer joins the attempt waiting for it.
                if let running = attempts[peer] {
                    guard case .requested = running.phase else { return nil }
                    running.phase = .preparing
                    running.id = id
                    running.remote = remote
                    return running
                }
                guard let begun = begin(peer, phase: .preparing) else { return nil }
                begun.id = id
                begun.remote = remote
                return begun
            }
            guard let answering else { return }
            guard !remote.isEmpty else { return end(answering, tell: true) }
            return await answer(answering, id: id)
        }

        // The rest belong to an attempt, and one that is over is not an error.
        guard let attempt, id != 0 else { return }
        let phase = lock.withLock { () -> Phase? in
            guard attempts[peer] === attempt, attempt.id == id else { return nil }
            attempt.received += 1
            return attempt.phase
        }
        guard let phase else { return }
        guard lock.withLock({ attempt.received }) <= Self.maxSignals else { return malformed() }

        switch (kind, phase) {
        case (Self.kindAbandon, _) where body.isEmpty:
            end(attempt, tell: false)
        case (Self.kindAnswer, .awaitingAnswer(let sent)) where offers(peer):
            guard let candidates = Self.decode(body) else { return malformed() }
            let remote = await acceptable(candidates)
            guard !remote.isEmpty else { return end(attempt, tell: true) }
            let live = lock.withLock { () -> Bool in
                guard attempts[peer] === attempt else { return false }
                attempt.remote = remote
                attempt.phase = .dialling
                return true
            }
            guard live else { return }
            guard await send(attempt, Self.kindSync, id: id) else { return end(attempt, tell: false) }
            // The sync takes half the round trip to arrive, and the other
            // end dials when it does.
            let wait = (ContinuousClock.now - sent) / 2
            Task {
                try? await Task.sleep(for: wait)
                await self.dial(attempt)
            }
        case (Self.kindSync, .awaitingSync) where body.isEmpty && !offers(peer):
            lock.withLock { attempt.phase = .dialling }
            Task { await self.dial(attempt) }
        default:
            malformed()
        }
    }

    // MARK: - Candidates

    /// The candidates this node will dial. A peer names its own addresses, so
    /// without this it could aim a dial at a host inside this node's network.
    private func acceptable(_ candidates: [PunchCandidate]) async -> [PunchCandidate] {
        var accepted: [PunchCandidate] = []
        for candidate in candidates where candidate.port != 0 {
            guard transports.contains(where: { $0.kind == candidate.transport }) else { continue }
            if options.allowPrivateCandidates {
                accepted.append(candidate)
            } else if await ivy.isGloballyRoutable(candidate.host) {
                accepted.append(candidate)
            }
        }
        return accepted
    }

    /// A count, then for each candidate its transport, its port and its host
    /// behind a length.
    static func encode(_ candidates: [PunchCandidate]) -> Data {
        var data = Data([UInt8(candidates.count)])
        for candidate in candidates {
            let host = Array(candidate.host.utf8)
            data.append(candidate.transport)
            data.append(contentsOf: [UInt8(candidate.port >> 8), UInt8(candidate.port & 0xff)])
            data.append(UInt8(host.count))
            data.append(contentsOf: host)
        }
        return data
    }

    static func decode(_ data: Data) -> [PunchCandidate]? {
        var bytes = Array(data)[...]
        guard let count = bytes.popFirst(), count >= 1, count <= maxCandidates else { return nil }
        var candidates: [PunchCandidate] = []
        for _ in 0..<count {
            guard bytes.count >= 4 else { return nil }
            let transport = bytes.removeFirst()
            let port = UInt16(bytes.removeFirst()) << 8 | UInt16(bytes.removeFirst())
            let length = Int(bytes.removeFirst())
            guard length >= 1, length <= 64, bytes.count >= length,
                  let host = String(bytes: bytes.prefix(length), encoding: .utf8) else { return nil }
            bytes.removeFirst(length)
            candidates.append(PunchCandidate(transport: transport, host: host, port: port))
        }
        return bytes.isEmpty ? candidates : nil
    }
}
