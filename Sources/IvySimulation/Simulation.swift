@preconcurrency import Crypto
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import IvyCore
import Tally

/// Signatures that repeat: a digest of the signer's key and the message.
/// Anyone can forge one, so this is for simulation only. It exists because
/// a session ID covers both handshake signatures, and which of two
/// simultaneous sessions survives depends on it.
public struct SimulatedSignatureScheme: IvySignatureScheme {
    private let key: PeerKey

    public init(key: PeerKey) {
        self.key = key
    }

    private static func tag(_ key: PeerKey, _ message: Data) -> Data {
        var first = SHA256()
        first.update(data: Data("ivy.sim.a".utf8))
        first.update(data: key.rawRepresentation)
        first.update(data: message)
        var second = SHA256()
        second.update(data: Data("ivy.sim.b".utf8))
        second.update(data: key.rawRepresentation)
        second.update(data: message)
        return Data(first.finalize()) + Data(second.finalize())
    }

    public func signature(for message: Data) throws -> Data {
        Self.tag(key, message)
    }

    public func isValidSignature(_ signature: Data, for message: Data, publicKey: PeerKey) -> Bool {
        signature == Self.tag(publicKey, message)
    }
}

/// Serving priority and standing a test sets by hand; served Volume bytes
/// debit the standing, as Tally's does. Like the simulation, it is
/// used from one thread.
public final class SimulatedLedger: PeerLedger, @unchecked Sendable {
    private var credit: [PeerID: Double] = [:]
    private var standings: [PeerID: Int] = [:]
    private var violationCounts: [PeerID: Int] = [:]

    public init() {}

    public func setServingPriority(_ value: Double, for peer: PeerID) {
        credit[peer] = value
    }

    public func setStanding(_ bytes: Int, for peer: PeerID) {
        standings[peer] = bytes
    }

    public func standing(for peer: PeerID) -> Int {
        standings[peer] ?? 0
    }

    public func violations(of peer: PeerID) -> Int {
        violationCounts[peer] ?? 0
    }

    public func recordSent(peer: PeerID, bytes: Int) {}
    public func recordReceived(peer: PeerID, bytes: Int) {}

    public func recordProtocolViolation(peer: PeerID) {
        violationCounts[peer, default: 0] += 1
    }

    public func servingPriority(for peer: PeerID) -> Double {
        (credit[peer] ?? 0) + Double(standings[peer] ?? 0)
    }

    public func recordServed(peer: PeerID, bytes: Int) {
        guard bytes > 0, let current = standings[peer] else { return }
        standings[peer] = current > bytes ? current - bytes : nil
    }
}

/// Many Ivy cores on one virtual clock, joined by a simulated network. The
/// simulation plays the shell for each: it carries bytes, answers jobs from
/// an in-memory store, and sends `tick` at each core's next deadline. A run
/// is a function of its seed and the calls made on it, so it repeats.
public final class Simulation {
    public struct NodeID: Hashable, Sendable, CustomStringConvertible {
        public let index: Int
        public var description: String { "node\(index)" }
    }

    public struct TraceEntry: Sendable, Equatable {
        public let time: Duration
        public let node: NodeID
        public let effect: Effect
    }

    /// What a node's application saw and what it serves.
    public final class Node {
        public let id: NodeID
        public let host: String
        public internal(set) var core: IvyCore
        public let ledger: SimulatedLedger

        public var volumes: [String: [ContentEntry]] = [:]
        public var bundles: [String: [String]] = [:]
        /// Answers `authorize` jobs; everyone is authorized by default.
        public var authorize: (AuthenticatedPeer, String) -> Bool = { _, _ in true }
        /// How long a storage job takes to answer.
        public var storageDelay: Duration = .zero
        /// Jobs are started but never answered while true.
        public var stallsStorage = false
        /// How long the application takes with each delivery.
        public var deliveryDelay: Duration = .zero
        /// Deliveries are held, unacknowledged, while true.
        public var holdsDeliveries = false
        public var observedPublicAddress: ObservedAddress?

        public internal(set) var received: [(peer: AuthenticatedPeer, message: PeerMessage)] = []
        public internal(set) var connected: [AuthenticatedPeer] = []
        public internal(set) var disconnected: [PeerID] = []
        public internal(set) var publicAddresses: [ObservedAddress] = []
        public internal(set) var startedJobs: [(id: JobID, job: Job)] = []
        public internal(set) var cancelledJobs: [JobID] = []
        public internal(set) var heldDeliveries: [DeliveryToken] = []
        var stalledJobs: [(JobID, Job)] = []
        var results: [RequestID: RequestResult] = [:]
        var wake: Duration?
        var connections: [ConnectionID: Endpoint] = [:]

        public var key: PeerKey { core.config.peerKey }
        public var peer: PeerID { core.localID }
        public var endpoint: PeerEndpoint {
            PeerEndpoint(publicKey: key.hex, host: host, port: core.config.listenPort)
        }

        init(id: NodeID, host: String, core: IvyCore, ledger: SimulatedLedger) {
            self.id = id
            self.host = host
            self.core = core
            self.ledger = ledger
        }
    }

    /// One end of a simulated connection.
    struct Endpoint {
        let pipe: Int
        /// Nil for a raw connection, whose far end is the test itself.
        let remoteNode: NodeID?
        let remoteConnection: ConnectionID
        var reading = false
        /// Bytes that arrived while the core was not reading.
        var inbox: [Data] = []
        /// Bytes written and not yet taken by the remote core.
        var undelivered = 0
        /// The far end closed; the core hears once it has read what arrived first.
        var remoteClosed = false
        /// Added to the latency of what this end writes.
        var extraDelay: Duration = .zero
    }

    private enum Action {
        case event(Event)
        case arrive(ConnectionID, Data)
        case remoteClosed(ConnectionID)
        case drained(ConnectionID)
    }

    private struct Scheduled {
        let time: Duration
        let order: UInt64
        let node: NodeID
        let action: Action
    }

    public let seed: UInt64
    /// One-way delay of every byte, dial and close.
    public var latency: Duration = .milliseconds(10)
    /// Writes reach the remote core in pieces of at most this many bytes.
    public var segmentSize = 64 * 1024
    public private(set) var now: Duration = .zero
    public private(set) var trace: [TraceEntry] = []
    public private(set) var nodes: [Node] = []
    /// Pairs of nodes that cannot reach each other.
    private var partitions: Set<[Int]> = []

    private var queue: [Scheduled] = []
    private var nextOrder: UInt64 = 0
    private var nextConnection: UInt64 = 0
    private var nextRequest: UInt64 = 0
    private var nextPipe = 0
    private var digest = SHA256()
    /// The two ends of the connection the last successful dial made.
    public private(set) var lastDialledConnections: (dialer: ConnectionID, listener: ConnectionID)?
    private var rawOutput: [ConnectionID: Data] = [:]
    private var rawStalled: Set<ConnectionID> = []
    private var rawClosed: Set<ConnectionID> = []
    private let epoch: UInt64 = 1_800_000_000

    public init(seed: UInt64 = 1) {
        self.seed = seed
    }

    public var unixSeconds: UInt64 {
        epoch + UInt64(now.components.seconds)
    }

    // MARK: - Building a network

    /// A signing key that depends only on the seed and the node's index.
    public func signingKey(index: Int) -> Curve25519.Signing.PrivateKey {
        var material = SHA256()
        material.update(data: Data("ivy.sim.key".utf8))
        withUnsafeBytes(of: seed.bigEndian) { material.update(bufferPointer: $0) }
        withUnsafeBytes(of: UInt64(index).bigEndian) { material.update(bufferPointer: $0) }
        return try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(material.finalize()))
    }

    /// Adds a node. `configure` builds its config from the key the
    /// simulation assigns; hosts default to distinct public /16 networks.
    @discardableResult
    public func addNode(
        host: String? = nil,
        realSignatures: Bool = false,
        configure: (Curve25519.Signing.PrivateKey) -> IvyConfig
    ) -> Node {
        let index = nodes.count
        let config = configure(signingKey(index: index))
        let ledger = SimulatedLedger()
        let core = IvyCore(
            config: config,
            scheme: realSignatures ? nil : SimulatedSignatureScheme(key: config.peerKey),
            ledger: ledger,
            random: .seeded(seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(index)))
        let node = Node(
            id: NodeID(index: index),
            host: host ?? "8.\(index + 1).0.1",
            core: core,
            ledger: ledger)
        nodes.append(node)
        return node
    }

    public func setPartitioned(_ partitioned: Bool, _ a: Node, _ b: Node) {
        let pair = [a.id.index, b.id.index].sorted()
        if partitioned { partitions.insert(pair) } else { partitions.remove(pair) }
    }

    // MARK: - Driving

    public func start(_ node: Node) {
        send(.command(.setContentSource(true)), to: node)
        send(.start, to: node)
    }

    public func stop(_ node: Node) {
        send(.stop, to: node)
    }

    /// Applies `event` to the node's core now.
    public func send(_ event: Event, to node: Node) {
        apply(event, to: node)
    }

    @discardableResult
    public func request(_ request: Request, on node: Node) -> RequestID {
        nextRequest += 1
        let id = RequestID(nextRequest)
        apply(.request(id, request), to: node)
        return id
    }

    /// Joins two nodes with a connection neither dialled, as a transport
    /// that establishes its own streams would: `b` is told of it as inbound,
    /// and `a` is asked to connect to `b` over it. `expecting` names a peer
    /// other than `b` as the one `a` believes it reaches. `observedHost`
    /// overrides the host `a` is told its peer was observed at.
    @discardableResult
    public func requestConnectOver(
        from a: Node,
        to b: Node,
        expecting endpoint: PeerEndpoint? = nil,
        observedHost: String?? = nil
    ) -> (request: RequestID, connection: ConnectionID) {
        nextPipe += 1
        let near = makeConnectionID()
        let far = makeConnectionID()
        a.connections[near] = Endpoint(pipe: nextPipe, remoteNode: b.id, remoteConnection: far)
        b.connections[far] = Endpoint(pipe: nextPipe, remoteNode: a.id, remoteConnection: near)
        apply(
            .connectionOpened(far, direction: .inbound, observedHost: a.host, localHost: b.host),
            to: b)
        let id = request(
            .connectOver(
                endpoint ?? b.endpoint, near, observedHost: observedHost ?? b.host, localHost: a.host),
            on: a)
        return (id, near)
    }

    /// Slows what `node` writes on `connection`, so that another path to the
    /// same peer is the faster one.
    public func delayWrites(by delay: Duration, on connection: ConnectionID, at node: Node) {
        node.connections[connection]?.extraDelay = delay
    }

    /// Whether the node still holds its end of `connection`.
    public func isOpen(_ connection: ConnectionID, at node: Node) -> Bool {
        node.connections[connection] != nil
    }

    public func cancel(_ request: RequestID, on node: Node) {
        apply(.cancel(request), to: node)
    }

    public func result(of request: RequestID, on node: Node) -> RequestResult? {
        node.results[request]
    }

    /// Releases the deliveries a node was holding.
    public func releaseDeliveries(_ node: Node) {
        let held = node.heldDeliveries
        node.heldDeliveries = []
        for token in held { apply(.delivered(token), to: node) }
    }

    /// Answers the jobs a node's storage stalled on.
    public func releaseStorage(_ node: Node) {
        node.stallsStorage = false
        let stalled = node.stalledJobs
        node.stalledJobs = []
        for (id, job) in stalled { schedule(.event(.jobFinished(id, answer(job, on: node))), for: node) }
    }

    /// Runs every event due within `duration`, then leaves the clock there.
    public func run(for duration: Duration) {
        let end = now + duration
        while let next = nextTime(), next <= end {
            now = max(now, next)
            runDue()
        }
        now = end
    }

    /// Runs until `condition` holds or `timeout` of virtual time passes.
    @discardableResult
    public func run(until condition: () -> Bool, timeout: Duration = .seconds(120)) -> Bool {
        let end = now + timeout
        while !condition() {
            guard let next = nextTime(), next <= end else {
                now = end
                return condition()
            }
            now = max(now, next)
            runDue()
        }
        return true
    }

    /// Runs a request to completion and returns its result.
    public func await(_ request: Request, on node: Node, timeout: Duration = .seconds(120)) -> RequestResult? {
        let id = self.request(request, on: node)
        run(until: { node.results[id] != nil }, timeout: timeout)
        return node.results[id]
    }

    /// A digest of every effect so far, in order: equal for equal runs.
    public var traceDigest: String {
        return Data(digest.finalize()).map { hexByte($0) }.joined()
    }

    // MARK: - The event loop

    private func nextTime() -> Duration? {
        let queued = queue.map(\.time).min()
        let wake = nodes.compactMap(\.wake).min()
        switch (queued, wake) {
        case let (queued?, wake?): return min(queued, wake)
        case let (queued?, nil): return queued
        case let (nil, wake?): return wake
        case (nil, nil): return nil
        }
    }

    private func runDue() {
        while true {
            if let index = queue.indices
                .filter({ queue[$0].time <= now })
                .min(by: { (queue[$0].time, queue[$0].order) < (queue[$1].time, queue[$1].order) }) {
                let item = queue.remove(at: index)
                let node = nodes[item.node.index]
                switch item.action {
                case .event(let event):
                    apply(event, to: node)
                case .arrive(let connection, let bytes):
                    arrive(bytes, on: connection, at: node)
                case .drained(let connection):
                    // Only if nothing was written since: a later write has its own drain.
                    if node.connections[connection]?.undelivered == 0 {
                        apply(.writable(connection), to: node)
                    }
                case .remoteClosed(let connection):
                    guard node.connections[connection] != nil else { break }
                    node.connections[connection]?.remoteClosed = true
                    drainInbox(connection, at: node)
                }
                continue
            }
            if let node = nodes.first(where: { $0.wake.map { $0 <= now } ?? false }) {
                node.wake = nil
                apply(.tick, to: node)
                continue
            }
            return
        }
    }

    private func schedule(_ action: Action, for node: Node, after delay: Duration = .zero) {
        nextOrder += 1
        queue.append(Scheduled(time: now + delay, order: nextOrder, node: node.id, action: action))
    }

    private func apply(_ event: Event, to node: Node) {
        let effects = node.core.step(event, now: Timestamp(uptime: now, unixSeconds: unixSeconds))
        for effect in effects {
            record(effect, node: node)
            perform(effect, on: node)
        }
    }

    // MARK: - Playing the shell

    private func perform(_ effect: Effect, on node: Node) {
        switch effect {
        case .dial(let dial, let endpoint):
            guard let target = nodes.first(where: {
                      $0.host == endpoint.host && $0.core.config.listenPort == endpoint.port
                  }),
                  target.core.isRunning,
                  !partitions.contains([node.id.index, target.id.index].sorted()) else {
                schedule(.event(.dialFailed(dial)), for: node, after: latency)
                return
            }
            nextPipe += 1
            let near = makeConnectionID()
            let far = makeConnectionID()
            node.connections[near] = Endpoint(
                pipe: nextPipe, remoteNode: target.id, remoteConnection: far)
            lastDialledConnections = (near, far)
            target.connections[far] = Endpoint(
                pipe: nextPipe, remoteNode: node.id, remoteConnection: near)
            schedule(.event(.connectionOpened(
                far, direction: .inbound, observedHost: node.host, localHost: target.host)),
                for: target, after: latency)
            schedule(.event(.connectionOpened(
                near, direction: .outbound(dial), observedHost: target.host, localHost: node.host)),
                for: node, after: latency)

        case .write(let connection, let bytes):
            guard let endpoint = node.connections[connection] else { return }
            guard let remoteNode = endpoint.remoteNode else {
                rawOutput[connection, default: Data()].append(bytes)
                if !rawStalled.contains(connection) {
                    schedule(.event(.writable(connection)), for: node, after: latency)
                }
                return
            }
            node.connections[connection]?.undelivered += bytes.count
            let remote = nodes[remoteNode.index]
            var offset = bytes.startIndex
            while offset < bytes.endIndex {
                let end = min(offset + segmentSize, bytes.endIndex)
                schedule(
                    .arrive(endpoint.remoteConnection, Data(bytes[offset..<end])),
                    for: remote, after: latency + endpoint.extraDelay)
                offset = end
            }

        case .close(let connection):
            guard let endpoint = node.connections.removeValue(forKey: connection) else { return }
            guard let remoteNode = endpoint.remoteNode else {
                rawClosed.insert(connection)
                return
            }
            let remote = nodes[remoteNode.index]
            guard remote.connections[endpoint.remoteConnection] != nil else { return }
            schedule(.remoteClosed(endpoint.remoteConnection), for: remote, after: latency)

        case .pauseReading(let connection):
            node.connections[connection]?.reading = false

        case .resumeReading(let connection):
            guard node.connections[connection] != nil else { return }
            node.connections[connection]?.reading = true
            drainInbox(connection, at: node)

        case .deliver(let token, let peer, let message):
            node.received.append((peer, message))
            acknowledge(token, on: node)

        case .peerConnected(let token, let peer):
            node.connected.append(peer)
            acknowledge(token, on: node)

        case .peerDisconnected(let peer):
            node.disconnected.append(peer)

        case .publicAddressDiscovered(let address):
            node.publicAddresses.append(address)

        case .completed(let request, let result):
            node.results[request] = result

        case .startJob(let id, let job):
            node.startedJobs.append((id, job))
            if node.stallsStorage {
                node.stalledJobs.append((id, job))
            } else {
                schedule(
                    .event(.jobFinished(id, answer(job, on: node))),
                    for: node, after: node.storageDelay)
            }

        case .cancelJob(let id):
            node.cancelledJobs.append(id)

        case .discoverPublicAddress:
            schedule(.event(.publicAddress(node.observedPublicAddress)), for: node, after: latency)

        case .wakeAt(let deadline):
            node.wake = deadline
        }
    }

    private func makeConnectionID() -> ConnectionID {
        nextConnection += 1
        return ConnectionID(nextConnection)
    }

    private func acknowledge(_ token: DeliveryToken, on node: Node) {
        if node.holdsDeliveries {
            node.heldDeliveries.append(token)
        } else {
            schedule(.event(.delivered(token)), for: node, after: node.deliveryDelay)
        }
    }

    private func arrive(_ bytes: Data, on connection: ConnectionID, at node: Node) {
        guard node.connections[connection] != nil else { return }
        node.connections[connection]?.inbox.append(bytes)
        drainInbox(connection, at: node)
    }

    /// Hands waiting bytes to the core while it is reading, and tells the
    /// writer once everything it wrote has been taken.
    private func drainInbox(_ connection: ConnectionID, at node: Node) {
        while let endpoint = node.connections[connection], endpoint.reading, !endpoint.inbox.isEmpty {
            let bytes = node.connections[connection]!.inbox.removeFirst()
            if let remoteNode = endpoint.remoteNode,
               var far = nodes[remoteNode.index].connections[endpoint.remoteConnection] {
                let writer = nodes[remoteNode.index]
                far.undelivered -= bytes.count
                writer.connections[endpoint.remoteConnection] = far
                if far.undelivered == 0 {
                    schedule(.drained(endpoint.remoteConnection), for: writer, after: latency)
                }
            }
            apply(.received(connection, bytes), to: node)
        }
        // As with TCP, bytes sent before a close are read before the close is seen.
        if let endpoint = node.connections[connection], endpoint.remoteClosed, endpoint.inbox.isEmpty {
            node.connections.removeValue(forKey: connection)
            apply(.closed(connection), to: node)
        }
    }

    private func answer(_ job: Job, on node: Node) -> JobResult {
        switch job {
        case .readVolume(let rootCID, _):
            return .entries(node.volumes[rootCID] ?? [])
        case .readVolumeBundle(let rootCID):
            return .roots(node.bundles[rootCID] ?? [])
        case .authorizeVolume(let peer, let rootCID):
            return .authorized(node.authorize(peer, rootCID))
        }
    }

    // MARK: - Raw connections

    /// Opens an inbound connection to `node` whose far end is the test: what
    /// the node writes is collected, and the test writes whatever bytes it
    /// likes. For malformed input and hand-driven handshakes.
    public func openRawConnection(to node: Node, fromHost host: String = "9.9.0.1") -> ConnectionID {
        let id = makeConnectionID()
        nextPipe += 1
        node.connections[id] = Endpoint(pipe: nextPipe, remoteNode: nil, remoteConnection: id)
        apply(
            .connectionOpened(id, direction: .inbound, observedHost: host, localHost: node.host),
            to: node)
        return id
    }

    /// Delivers `bytes` to the node on a raw connection, held while the
    /// node is not reading it.
    public func writeRaw(_ bytes: Data, on connection: ConnectionID, to node: Node) {
        arrive(bytes, on: connection, at: node)
    }

    /// Bytes delivered to the node on `connection` that it has not read.
    public func unreadBytes(on connection: ConnectionID, at node: Node) -> Int {
        node.connections[connection]?.inbox.reduce(0) { $0 + $1.count } ?? 0
    }

    public func isReading(_ connection: ConnectionID, at node: Node) -> Bool {
        node.connections[connection]?.reading ?? false
    }

    /// Everything the node has written to a raw connection, removed as read.
    public func takeRawOutput(_ connection: ConnectionID) -> Data {
        rawOutput.removeValue(forKey: connection) ?? Data()
    }

    /// While stalled, a raw connection never reports `writable`: the node
    /// sees a peer that has stopped taking bytes.
    public func setRawStalled(_ stalled: Bool, _ connection: ConnectionID, at node: Node) {
        if stalled {
            rawStalled.insert(connection)
        } else if rawStalled.remove(connection) != nil {
            schedule(.event(.writable(connection)), for: node)
        }
    }

    public func closeRaw(_ connection: ConnectionID, at node: Node) {
        guard node.connections.removeValue(forKey: connection) != nil else { return }
        apply(.closed(connection), to: node)
    }

    /// Whether the node closed the raw connection.
    public func nodeClosedRaw(_ connection: ConnectionID) -> Bool {
        rawClosed.contains(connection)
    }

    // MARK: - Trace

    private func record(_ effect: Effect, node: Node) {
        trace.append(TraceEntry(time: now, node: node.id, effect: effect))
        var line = "\(now.components.seconds).\(now.components.attoseconds) \(node.id.index) "
        switch effect {
        case .write(let connection, let bytes):
            line += "write \(connection.rawValue) "
            digest.update(data: Data(line.utf8))
            digest.update(data: bytes)
            return
        case .completed(let request, let result):
            line += "completed \(request.rawValue) \(Self.canonical(result))"
        default:
            line += String(reflecting: effect)
        }
        digest.update(data: Data(line.utf8))
    }

    /// Results hold dictionaries, whose printed order varies between
    /// processes; this spells them in key order.
    private static func canonical(_ result: RequestResult) -> String {
        func entries(_ entries: [String: Data]) -> String {
            entries.keys.sorted().map { "\($0)=\(entries[$0]!.count)" }.joined(separator: ",")
        }
        func volume(_ volume: AttributedVolumeResponse) -> String {
            "\(volume.rootCID)[\(entries(volume.entries))]by:\(volume.servedBy?.publicKey ?? "-")"
                + "fail:\(String(describing: volume.failure))"
        }
        switch result {
        case .volume(let response):
            return "volume " + volume(response)
        case .volumeBundle(let response):
            return "bundle " + response.volumes.map(volume).joined(separator: ";")
                + " \(response.noBundle) \(response.ended) \(String(describing: response.failure))"
        default:
            return String(reflecting: result)
        }
    }
}
