import Crypto
import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// A peer the test plays by hand over a raw connection: it dials the node,
/// runs the initiator handshake record by record, and signs data records
/// with whatever sequence the test asks for.
final class HandPeer {
    let sim: Simulation
    let node: Simulation.Node
    let key: PeerKey
    let host: String
    let connection: ConnectionID
    private let scheme: SimulatedSignatureScheme
    private var undecoded = Data()
    private(set) var hello: SignedSessionHelloInitiator?
    private(set) var sessionID: SessionID?
    var nextSequence: UInt64 = 1

    /// A key no simulated node holds; the same `index` gives the same key.
    static func key(_ sim: Simulation, index: Int) -> PeerKey {
        try! PeerKey(rawRepresentation: sim.signingKey(index: 10_000 + index).publicKey.rawRepresentation)
    }

    static func endpoint(_ sim: Simulation, index: Int, host: String) -> PeerEndpoint {
        PeerEndpoint(publicKey: key(sim, index: index).hex, host: host, port: 4001)
    }

    init(_ sim: Simulation, to node: Simulation.Node, index: Int, host: String) {
        self.sim = sim
        self.node = node
        self.host = host
        key = Self.key(sim, index: index)
        scheme = SimulatedSignatureScheme(key: key)
        connection = sim.openRawConnection(to: node, fromHost: host)
    }

    var id: PeerID { key.peerID }
    var endpoint: PeerEndpoint { PeerEndpoint(publicKey: key.hex, host: host, port: 4001) }
    var isClosed: Bool { sim.nodeClosedRaw(connection) }
    var isRead: Bool { sim.isReading(connection, at: node) }
    var link: Link? { node.core.linkByConnection[connection].flatMap { node.core.links[$0] } }

    /// Whether the node holds an authenticated session on this connection.
    var isAuthenticated: Bool {
        guard let link = node.core.linkByConnection[connection] else { return false }
        return node.core.sessionKeyByLink[link] == key
    }

    private var maxFrame: UInt32 { node.core.config.protocolMaxFrameSize }

    // MARK: Handshake

    func sendHello(
        nonce: UInt8 = 1,
        metadata: PeerMetadata = PeerMetadata(),
        responder: PeerKey? = nil
    ) {
        let signed = try! SignedSessionHelloInitiator.sign(
            SessionHelloInitiator(
                routeBinding: IvyCore.directRouteBinding,
                initiator: key,
                responder: responder ?? node.key,
                nonce: Data(repeating: nonce, count: 32),
                metadata: metadata.encode()!),
            with: scheme)
        hello = signed
        write(.helloInitiator(signed))
    }

    /// Reads the node's responder hello; true when the session ID is known.
    @discardableResult
    func receiveResponder() -> Bool {
        for record in takeRecords() {
            if case .helloResponder(let responder) = record, let hello {
                sessionID = try? SessionID(initiator: hello, responder: responder)
                return sessionID != nil
            }
        }
        return false
    }

    func sendFinish() {
        guard let sessionID else { return }
        write(.finish(try! SessionFinish.sign(
            sessionID: sessionID, sender: key, receiver: node.key, with: scheme)))
    }

    /// The whole handshake, then lets the node's application see the session.
    @discardableResult
    func authenticate(nonce: UInt8 = 1, metadata: PeerMetadata = PeerMetadata()) -> Bool {
        sendHello(nonce: nonce, metadata: metadata)
        guard receiveResponder() else { return false }
        sendFinish()
        sim.run(for: .zero)
        return isAuthenticated
    }

    // MARK: Records

    /// A signed data record carrying `message`, serialized and unframed.
    func record(_ message: Message, sequence: UInt64? = nil, sessionID override: SessionID? = nil) -> Data {
        let sequence = sequence ?? nextSequence
        nextSequence = sequence &+ 1
        let data = try! SessionDataRecord.sign(
            sessionID: override ?? sessionID!,
            sender: key,
            receiver: node.key,
            sequence: sequence,
            payload: message.serialize(maxFrameSize: maxFrame),
            with: scheme)
        return SessionWireRecord.data(data).serialize(maxPayload: maxFrame)
    }

    func send(_ message: Message, sequence: UInt64? = nil) {
        writeFrames([record(message, sequence: sequence)])
    }

    func sendMessage(_ topic: String, sequence: UInt64? = nil) {
        send(.peerMessage(topic: topic, payload: Data(topic.utf8)), sequence: sequence)
    }

    func write(_ record: SessionWireRecord) {
        writeFrames([record.serialize(maxPayload: maxFrame)])
    }

    /// Writes every payload, each behind its length prefix, as one delivery.
    func writeFrames(_ payloads: [Data]) {
        sim.writeRaw(Self.framed(payloads), on: connection, to: node)
    }

    func writeBytes(_ bytes: Data) {
        sim.writeRaw(bytes, on: connection, to: node)
    }

    static func framed(_ payloads: [Data]) -> Data {
        var bytes = Data()
        for payload in payloads {
            bytes.appendUInt32(UInt32(payload.count))
            bytes.append(payload)
        }
        return bytes
    }

    /// Every complete record the node has written since the last call.
    func takeRecords() -> [SessionWireRecord] {
        undecoded.append(sim.takeRawOutput(connection))
        var records: [SessionWireRecord] = []
        while undecoded.count >= 4 {
            let length = undecoded.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard undecoded.count >= 4 + length else { break }
            let body = Data(undecoded.dropFirst(4).prefix(length))
            undecoded = Data(undecoded.dropFirst(4 + length))
            if let record = try? SessionWireRecord.deserialize(body, maxPayload: .max) {
                records.append(record)
            }
        }
        return records
    }

    func takeDataRecords() -> [SessionDataRecord] {
        takeRecords().compactMap {
            if case .data(let record) = $0 { return record }
            return nil
        }
    }

    func takeMessages() -> [Message] {
        takeDataRecords().compactMap { Message.deserialize($0.payload, maxDataPayload: .max) }
    }

    func close() {
        sim.closeRaw(connection, at: node)
    }
}

extension Simulation {
    /// A node whose connection limits the test chooses, including the
    /// outbound reservation `node(...)` does not expose.
    @discardableResult
    func capacityNode(
        host: String? = nil,
        bootstrap: [PeerEndpoint] = [],
        maxConnections: Int,
        reservedOutboundConnectionSlots: Int = 0,
        maxConnectionsPerNetgroup: Int = 2
    ) -> Node {
        let node = addNode(host: host) { key in
            IvyConfig(
                signingKey: key,
                listenPort: 4001,
                bootstrapPeers: bootstrap,
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                maxConnections: maxConnections,
                reservedOutboundConnectionSlots: reservedOutboundConnectionSlots,
                maxConnectionsPerNetgroup: maxConnectionsPerNetgroup)
        }
        start(node)
        return node
    }

    func effects(of node: Node) -> [Effect] {
        trace.filter { $0.node == node.id }.map(\.effect)
    }

    /// Every dial the node has asked for, with the time it asked.
    func dials(from node: Node) -> [(time: Duration, dial: DialID, endpoint: PeerEndpoint)] {
        trace.compactMap { entry in
            guard entry.node == node.id, case .dial(let dial, let endpoint) = entry.effect else { return nil }
            return (entry.time, dial, endpoint)
        }
    }

    func closes(by node: Node) -> [ConnectionID] {
        effects(of: node).compactMap {
            if case .close(let connection) = $0 { return connection }
            return nil
        }
    }

    func resumeCount(_ connection: ConnectionID, at node: Node) -> Int {
        effects(of: node).filter { $0 == .resumeReading(connection) }.count
    }

    func writeCount(by node: Node) -> Int {
        effects(of: node).filter {
            if case .write = $0 { return true }
            return false
        }.count
    }

    /// Acknowledges only the held deliveries that came from `peer`.
    func releaseDeliveries(_ node: Node, from peer: PeerID) {
        let tokens = Set(trace.compactMap { entry -> DeliveryToken? in
            guard entry.node == node.id else { return nil }
            switch entry.effect {
            case .deliver(let token, let sender, _) where sender.id == peer:
                return token
            case .peerConnected(let token, let sender) where sender.id == peer:
                return token
            default:
                return nil
            }
        })
        let released = node.heldDeliveries.filter(tokens.contains)
        node.heldDeliveries.removeAll(where: tokens.contains)
        for token in released { send(.delivered(token), to: node) }
    }

    /// Stops holding deliveries and acknowledges the ones held.
    func openDeliveries(_ node: Node) {
        node.holdsDeliveries = false
        releaseDeliveries(node)
    }

    func topics(_ node: Node, from peer: PeerID) -> [String] {
        node.received.filter { $0.peer.id == peer }.map(\.message.topic)
    }
}

extension RequestResult {
    var isFailedConnect: Bool {
        if case .connect(.failed) = self { return true }
        return false
    }
}

extension Simulation {
    /// Sends messages to `peer` until the node reports backpressure, and
    /// returns how many it took. The peer's connection must not be draining.
    @discardableResult
    func saturate(_ node: Node, toward peer: PeerID, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let payload = Data(repeating: 0x5A, count: 16 * 1024)
        var enqueued = 0
        while enqueued < 64 {
            let result = self.await(.send(to: peer, topic: "fill", payload: payload), on: node)?.sent
            if result == .backpressured { return enqueued }
            XCTAssertEqual(result, .enqueued(endpoint: peer, route: .direct), file: file, line: line)
            enqueued += 1
        }
        XCTFail("the connection never reported backpressure", file: file, line: line)
        return enqueued
    }
}
