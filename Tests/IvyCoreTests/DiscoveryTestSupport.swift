import Crypto
import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// A peer the test plays by hand over a raw connection: it authenticates as
/// its own identity, then says whatever the test tells it to. It stands in
/// for a remote node whose answers the test wants to choose, delay, or forge.
final class DiscoveryScriptedPeer {
    let sim: Simulation
    let node: Simulation.Node
    let key: PeerKey
    let host: String
    let connection: ConnectionID
    private let scheme: SimulatedSignatureScheme
    private var sessionID: SessionID?
    private var nextSequence: UInt64 = 1
    private var unparsed = Data()
    /// Messages the node sent that the test has not taken yet.
    private(set) var inbox: [Message] = []

    var peer: PeerID { key.peerID }
    var isAuthenticated: Bool { sessionID != nil }
    /// The address this peer claims in referrals about itself.
    var endpoint: PeerEndpoint { PeerEndpoint(publicKey: key.hex, host: host, port: 4001) }

    /// Connects to `node` from `host` and authenticates. `listen` is what the
    /// peer advertises in its handshake metadata: nil advertises
    /// `host:4001`, an empty list advertises nothing (a session with no
    /// routing entry).
    init(
        _ sim: Simulation,
        to node: Simulation.Node,
        index: Int,
        host: String? = nil,
        listen: [ListenAddress]? = nil
    ) {
        self.sim = sim
        self.node = node
        let signingKey = sim.signingKey(index: 10_000 + index)
        key = try! PeerKey(rawRepresentation: signingKey.publicKey.rawRepresentation)
        scheme = SimulatedSignatureScheme(key: key)
        let host = host ?? "9.\(index + 1).0.1"
        self.host = host
        connection = sim.openRawConnection(to: node, fromHost: host)

        let metadata = PeerMetadata(
            listenAddresses: listen ?? [ListenAddress(host: host, port: 4001)])
        guard let encoded = metadata.encode(),
              let hello = try? SignedSessionHelloInitiator.sign(
                SessionHelloInitiator(
                    routeBinding: IvyCore.directRouteBinding,
                    initiator: key,
                    responder: node.key,
                    nonce: Data(SHA256.hash(data: Data("nonce-\(index)".utf8))),
                    metadata: encoded),
                with: scheme) else { return }
        writeRecord(.helloInitiator(hello))
        guard let reply = readRecords().first, case .helloResponder(let responder) = reply,
              let id = try? SessionID(initiator: hello, responder: responder),
              let finish = try? SessionFinish.sign(
                sessionID: id, sender: key, receiver: node.key, with: scheme) else { return }
        writeRecord(.finish(finish))
        // The node reads this connection again once its application has seen the session.
        sim.run(for: .zero)
        guard node.core.connectedPeers.contains(peer) else { return }
        sessionID = id
    }

    private func writeRecord(_ record: SessionWireRecord) {
        let payload = record.serialize()
        var frame = Data()
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Array($0) })
        frame.append(payload)
        sim.writeRaw(frame, on: connection, to: node)
    }

    private func readRecords() -> [SessionWireRecord] {
        unparsed.append(sim.takeRawOutput(connection))
        var records: [SessionWireRecord] = []
        while unparsed.count >= 4 {
            let header = [UInt8](unparsed.prefix(4))
            let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard unparsed.count >= 4 + length else { break }
            let body = Data(unparsed.dropFirst(4).prefix(length))
            unparsed = Data(unparsed.dropFirst(4 + length))
            if let record = try? SessionWireRecord.deserialize(body) { records.append(record) }
        }
        return records
    }

    /// Sends `message` to the node, signed as this peer.
    func send(_ message: Message) {
        guard let sessionID,
              let record = try? SessionDataRecord.sign(
                sessionID: sessionID,
                sender: key,
                receiver: node.key,
                sequence: nextSequence,
                payload: message.serialize(),
                with: scheme) else {
            XCTFail("scripted peer is not authenticated")
            return
        }
        nextSequence += 1
        writeRecord(.data(record))
    }

    /// Moves what the node has written into `inbox`.
    func poll() {
        for record in readRecords() {
            guard case .data(let data) = record, let message = Message.deserialize(data.payload) else { continue }
            inbox.append(message)
        }
    }

    /// Removes and returns the messages `pick` maps to a value, oldest first.
    func take<T>(_ pick: (Message) -> T?) -> [T] {
        poll()
        var taken: [T] = []
        inbox.removeAll { message in
            guard let value = pick(message) else { return false }
            taken.append(value)
            return true
        }
        return taken
    }

    func takeFindNodes() -> [(target: Data, nonce: UInt64)] {
        take { if case .findNode(let target, let nonce) = $0 { return (target, nonce) } else { return nil } }
    }

    func takeFindProviders() -> [(rootCID: String, requestID: UInt64)] {
        take { if case .findProviders(let root, let id) = $0 { return (root, id) } else { return nil } }
    }

    func takeAnnouncements() -> [(rootCID: String, expiresAt: UInt64)] {
        take { if case .announceProvider(let root, let expiry) = $0 { return (root, expiry) } else { return nil } }
    }

    func takeProviders() -> [(rootCID: String, requestID: UInt64, records: [ProviderRecord])] {
        take {
            if case .providers(let root, let id, let records) = $0 { return (root, id, records) } else { return nil }
        }
    }

    func takeNeighbors() -> [(endpoints: [PeerEndpoint], nonce: UInt64)] {
        take { if case .neighbors(let endpoints, let nonce) = $0 { return (endpoints, nonce) } else { return nil } }
    }

    /// Answers every `findNode` waiting in the inbox with `endpoints`.
    @discardableResult
    func answerFindNodes(_ endpoints: [PeerEndpoint]) -> Int {
        let asked = takeFindNodes()
        for request in asked { send(.neighbors(endpoints, nonce: request.nonce)) }
        return asked.count
    }

    /// Answers every `findProviders` waiting in the inbox with `records`.
    @discardableResult
    func answerFindProviders(_ records: [ProviderRecord]) -> Int {
        let asked = takeFindProviders()
        for request in asked {
            send(.providers(rootCID: request.rootCID, requestID: request.requestID, records: records))
        }
        return asked.count
    }

    func close() {
        sim.closeRaw(connection, at: node)
    }
}

extension Simulation {
    /// A node with the discovery knobs `node(...)` does not expose.
    @discardableResult
    func discoveryNode(
        host: String? = nil,
        bootstrap: [PeerEndpoint] = [],
        mode: IvyMode = .overlay,
        kBucketSize: Int = 20,
        stunServers: [(String, Int)] = [],
        routingRefreshInterval: Duration = .seconds(120),
        maxConnections: Int = IvyConfig.defaultMaxConnections,
        reservedOutboundConnectionSlots: Int = 0,
        maxConnectionsPerNetgroup: Int = 2,
        maxContentCandidates: Int = 8,
        maxRoutesPerIdentity: Int = IvyConfig.defaultMaxRoutesPerIdentity,
        maxProviderTTLSeconds: UInt64 = IvyConfig.defaultMaxProviderTTLSeconds,
        maxProviderRecordsPerPeer: Int = IvyConfig.defaultMaxProviderRecordsPerPeer,
        providerReach: ProviderReach = .walk,
        maxProviderWalkSessions: Int = IvyConfig.defaultMaxProviderWalkSessions,
        externalAddress: (host: String, port: UInt16)? = nil,
        privateContentExchangeEnabled: Bool = false,
        start: Bool = true
    ) -> Node {
        let node = addNode(host: host) { key in
            IvyConfig(
                signingKey: key,
                listenPort: 4001,
                bootstrapPeers: bootstrap,
                kBucketSize: kBucketSize,
                stunServers: stunServers,
                healthConfig: PeerHealthConfig(enabled: false),
                routingRefreshInterval: routingRefreshInterval,
                maxConnections: maxConnections,
                reservedOutboundConnectionSlots: reservedOutboundConnectionSlots,
                maxConnectionsPerNetgroup: maxConnectionsPerNetgroup,
                maxContentCandidates: maxContentCandidates,
                maxRoutesPerIdentity: maxRoutesPerIdentity,
                maxProviderTTLSeconds: maxProviderTTLSeconds,
                maxProviderRecordsPerPeer: maxProviderRecordsPerPeer,
                providerReach: providerReach,
                maxProviderWalkSessions: maxProviderWalkSessions,
                externalAddress: externalAddress,
                privateContentExchangeEnabled: privateContentExchangeEnabled,
                mode: mode)
        }
        if start { self.start(node) }
        return node
    }

    /// A valid identity nobody answers for, at a public address no node listens on.
    func discoveryUnreachableEndpoint(index: Int, host: String? = nil, port: UInt16 = 4001) -> PeerEndpoint {
        PeerEndpoint(
            publicKey: discoveryKey(index: index).hex,
            host: host ?? "7.\(index + 1).0.1",
            port: port)
    }

    func discoveryKey(index: Int) -> PeerKey {
        try! PeerKey(rawRepresentation: signingKey(index: 20_000 + index).publicKey.rawRepresentation)
    }

    /// Runs in 1 ms steps, letting `service` play the scripted peers between
    /// steps, until `condition` holds or `timeout` of virtual time passes.
    @discardableResult
    func runServicing(
        until condition: () -> Bool,
        timeout: Duration = .seconds(30),
        _ service: () -> Void
    ) -> Bool {
        let end = now + timeout
        while true {
            service()
            if condition() { return true }
            guard now < end else { return false }
            run(for: .milliseconds(1))
        }
    }

    /// Lets `node`'s lookups run to their end, each of `peers` answering
    /// every `findNode` with no one closer. Virtual time does not pass.
    @discardableResult
    func settleLookups(on node: Node, answering peers: [DiscoveryScriptedPeer]) -> Bool {
        settleLookups(on: node) { for peer in peers { peer.answerFindNodes([]) } }
    }

    @discardableResult
    func settleLookups(on node: Node, answering peers: [FetchRawPeer]) -> Bool {
        settleLookups(on: node) { for peer in peers { peer.answerFindNodes() } }
    }

    private func settleLookups(on node: Node, _ answer: () -> Void) -> Bool {
        for _ in 0..<64 {
            answer()
            if node.core.lookups.isEmpty { return true }
        }
        XCTFail("the node's lookups did not end")
        return false
    }

    /// Every endpoint `node` has asked the shell to dial.
    func discoveryDials(by node: Node) -> [PeerEndpoint] {
        trace.compactMap { entry in
            guard entry.node == node.id, case .dial(_, let endpoint) = entry.effect else { return nil }
            return endpoint
        }
    }

    /// Brings the node's clock up to the simulation's, so views that read
    /// the time of its last step see the present.
    func discoveryTouch(_ node: Node) {
        send(.tick, to: node)
    }

    func discoveryEffects(of node: Node) -> [Effect] {
        trace.filter { $0.node == node.id }.map(\.effect)
    }
}

/// Orders identities by XOR distance of their routing hash from `target`'s, closest first.
func discoveryClosest(_ keys: [String], to target: String) -> [String] {
    let targetHash = Router.hash(target)
    return keys.sorted { Router.isCloser(Router.hash($0), than: Router.hash($1), to: targetHash) }
}
