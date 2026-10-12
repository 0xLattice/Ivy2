import Crypto
import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

// Helpers for the relay tests: real nodes joined through a carrier, and
// identities the test plays by hand over raw connections.

func relayRouteID(_ marker: UInt8) -> Data {
    Data(repeating: marker, count: 32)
}

/// An identity with no node behind it.
struct RelayTestIdentity {
    let key: PeerKey
    let host: String

    var scheme: SimulatedSignatureScheme { SimulatedSignatureScheme(key: key) }
    var peer: PeerID { key.peerID }
    var endpoint: PeerEndpoint { PeerEndpoint(publicKey: key.hex, host: host, port: 4001) }
}

/// One end of an authenticated session, signed by hand.
struct RelayTestSession {
    let local: RelayTestIdentity
    let remote: PeerKey
    let id: SessionID
    var nextSequence: UInt64 = 1

    mutating func seal(_ message: Message) -> Data {
        seal(payload: message.serialize())
    }

    mutating func seal(payload: Data) -> Data {
        let record = seal(payload: payload, sequence: nextSequence)
        nextSequence += 1
        return record
    }

    func seal(payload: Data, sequence: UInt64) -> Data {
        let record = try! SessionDataRecord.sign(
            sessionID: id,
            sender: local.key,
            receiver: remote,
            sequence: sequence,
            payload: payload,
            with: local.scheme)
        return SessionWireRecord.data(record).serialize(maxPayload: .max)
    }

    /// The message in a record the remote end signed for this session.
    func open(_ record: Data) -> Message? {
        guard case .data(let data)? = try? SessionWireRecord.deserialize(record, maxPayload: .max),
              data.sessionID == id,
              data.isValid(sender: remote, receiver: local.key, using: local.scheme) else {
            return nil
        }
        return Message.deserialize(data.payload, maxDataPayload: .max)
    }
}

enum RelayTestHandshake {
    static func hello(
        from local: RelayTestIdentity,
        to remote: PeerKey,
        routeBinding: Data,
        nonce: UInt8,
        maxFrameSize: UInt32 = IvyConfig.defaultProtocolMaxFrameSize
    ) -> SignedSessionHelloInitiator {
        try! SignedSessionHelloInitiator.sign(
            SessionHelloInitiator(
                routeBinding: routeBinding,
                initiator: local.key,
                responder: remote,
                nonce: Data(repeating: nonce, count: 32),
                metadata: PeerMetadata(maxFrameSize: maxFrameSize).encode()!),
            with: local.scheme)
    }

    static func finish(
        from local: RelayTestIdentity,
        to remote: PeerKey,
        sessionID: SessionID
    ) -> Data {
        SessionWireRecord.finish(try! SessionFinish.sign(
            sessionID: sessionID,
            sender: local.key,
            receiver: remote,
            with: local.scheme)).serialize()
    }
}

/// A peer the test plays over a raw connection to `node`: it authenticates
/// as `identity`, then sends whatever messages the test likes.
final class RawRelayPeer {
    let sim: Simulation
    let node: Simulation.Node
    let identity: RelayTestIdentity
    let connection: ConnectionID
    private(set) var session: RelayTestSession?
    private var unparsed = Data()
    private var buffered: [Message] = []

    var key: PeerKey { identity.key }

    init(
        _ sim: Simulation,
        to node: Simulation.Node,
        as identity: RelayTestIdentity,
        maxFrameSize: UInt32 = IvyConfig.defaultProtocolMaxFrameSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        self.sim = sim
        self.node = node
        self.identity = identity
        connection = sim.openRawConnection(to: node, fromHost: identity.host)
        let hello = RelayTestHandshake.hello(
            from: identity,
            to: node.key,
            routeBinding: IvyCore.directRouteBinding,
            nonce: 1,
            maxFrameSize: maxFrameSize)
        write(record: SessionWireRecord.helloInitiator(hello).serialize())
        if case .helloResponder(let responder)? = readRecords().first,
           let id = try? SessionID(initiator: hello, responder: responder) {
            write(record: RelayTestHandshake.finish(from: identity, to: node.key, sessionID: id))
            session = RelayTestSession(local: identity, remote: node.key, id: id)
            sim.run(for: .zero)
        }
        XCTAssertNotNil(node.core.sessions[identity.key], "raw handshake failed", file: file, line: line)
    }

    /// Whether the node still holds this peer's session.
    var isConnected: Bool {
        guard let session else { return false }
        return node.core.sessions[identity.key]?.sessionID == session.id
    }

    var nodeClosedConnection: Bool { sim.nodeClosedRaw(connection) }

    func write(record: Data) {
        var frame = Data()
        frame.appendUInt32(UInt32(record.count))
        frame.append(record)
        sim.writeRaw(frame, on: connection, to: node)
    }

    func send(_ message: Message) {
        guard let record = session?.seal(message) else { return XCTFail("no raw session") }
        write(record: record)
    }

    func send(payload: Data) {
        guard let record = session?.seal(payload: payload) else { return XCTFail("no raw session") }
        write(record: record)
    }

    private func readRecords() -> [SessionWireRecord] {
        unparsed.append(sim.takeRawOutput(connection))
        var records: [SessionWireRecord] = []
        while unparsed.count >= 4 {
            let length = unparsed.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard unparsed.count >= 4 + length else { break }
            let frame = Data(unparsed.dropFirst(4).prefix(length))
            unparsed = Data(unparsed.dropFirst(4 + length))
            guard let record = try? SessionWireRecord.deserialize(frame, maxPayload: .max) else {
                XCTFail("node wrote an undecodable record")
                continue
            }
            records.append(record)
        }
        return records
    }

    private func pull() {
        for record in readRecords() {
            guard case .data(let data) = record, let session else { continue }
            // Every record is signed for exactly this session.
            XCTAssertEqual(data.sessionID, session.id)
            XCTAssertTrue(data.isValid(sender: node.key, receiver: identity.key, using: identity.scheme))
            guard let message = Message.deserialize(data.payload, maxDataPayload: .max) else {
                XCTFail("node wrote an undecodable message")
                continue
            }
            buffered.append(message)
        }
    }

    /// Everything the node sent since the last take, in order.
    func take() -> [Message] {
        pull()
        defer { buffered.removeAll() }
        return buffered
    }

    /// The values `pick` finds in what the node sent, leaving the rest.
    func take<T>(_ pick: (Message) -> T?) -> [T] {
        pull()
        var picked: [T] = []
        var rest: [Message] = []
        for message in buffered {
            if let value = pick(message) { picked.append(value) } else { rest.append(message) }
        }
        buffered = rest
        return picked
    }

    /// The opaque records the node forwarded or sent on `routeID`.
    func takePackets(on routeID: Data) -> [Data] {
        take { $0.relayPacketFields.flatMap { $0.routeID == routeID ? $0.record : nil } }
    }

    func takeCloses() -> [Data] {
        take { $0.relayCloseRoute }
    }

    func sendPacket(_ record: Data, on routeID: Data) {
        send(.relayPacket(routeID: routeID, opaqueEndpointRecord: record))
    }

    /// Plays `remote` opening a session with the node over a route this
    /// peer carries. Nil when the node did not answer the hello.
    func initiateRelayedSession(
        as remote: RelayTestIdentity,
        on routeID: Data,
        nonce: UInt8 = 7,
        routeBinding: Data? = nil
    ) -> RelayTestSession? {
        let hello = RelayTestHandshake.hello(
            from: remote, to: node.key, routeBinding: routeBinding ?? routeID, nonce: nonce)
        sendPacket(SessionWireRecord.helloInitiator(hello).serialize(), on: routeID)
        guard let reply = takePackets(on: routeID).first,
              case .helloResponder(let responder)? = try? SessionWireRecord.deserialize(reply),
              let id = try? SessionID(initiator: hello, responder: responder) else { return nil }
        sendPacket(RelayTestHandshake.finish(from: remote, to: node.key, sessionID: id), on: routeID)
        sim.run(for: .zero)
        return RelayTestSession(local: remote, remote: node.key, id: id)
    }

    /// Plays `remote` answering the hello the node sent over a route this
    /// peer carries. Nil when the node sent no hello.
    func answerRelayedSession(as remote: RelayTestIdentity, on routeID: Data) -> RelayTestSession? {
        guard let packet = takePackets(on: routeID).first,
              case .helloInitiator(let hello)? = try? SessionWireRecord.deserialize(packet),
              let signed = try? SignedSessionHelloResponder.sign(
                SessionHelloResponder(
                    routeBinding: hello.hello.routeBinding,
                    responder: remote.key,
                    initiator: hello.hello.initiator,
                    initiatorNonce: hello.hello.nonce,
                    responderNonce: Data(repeating: 9, count: 32),
                    metadata: PeerMetadata().encode()!),
                with: remote.scheme),
              let id = try? SessionID(initiator: hello, responder: signed) else { return nil }
        sendPacket(SessionWireRecord.helloResponder(signed).serialize(), on: routeID)
        sim.run(for: .zero)
        return RelayTestSession(local: remote, remote: node.key, id: id)
    }
}

extension Message {
    var relayOpenFields: (routeID: Data, target: PeerKey)? {
        if case .relayOpen(let routeID, let target) = self { return (routeID, target) }
        return nil
    }

    var relayOfferFields: (routeID: Data, source: PeerKey)? {
        if case .relayOffer(let routeID, let source) = self { return (routeID, source) }
        return nil
    }

    var relayAcceptFields: (routeID: Data, status: UInt8)? {
        if case .relayAccept(let routeID, let status) = self { return (routeID, status) }
        return nil
    }

    var relayReadyFields: (routeID: Data, status: UInt8)? {
        if case .relayReady(let routeID, let status) = self { return (routeID, status) }
        return nil
    }

    var relayPacketFields: (routeID: Data, record: Data)? {
        if case .relayPacket(let routeID, let record) = self { return (routeID, record) }
        return nil
    }

    var relayCloseRoute: Data? {
        if case .relayClose(let routeID) = self { return routeID }
        return nil
    }

    var pongNonce: UInt64? {
        if case .pong(let nonce) = self { return nonce }
        return nil
    }
}

extension Simulation {
    func relayIdentity(_ index: Int) -> RelayTestIdentity {
        let key = try! PeerKey(
            rawRepresentation: signingKey(index: 1_000 + index).publicKey.rawRepresentation)
        return RelayTestIdentity(key: key, host: "9.\(index).0.1")
    }

    /// A started node with the knobs relay tests turn.
    @discardableResult
    func relayNode(
        carriers: [PeerEndpoint] = [],
        relayEnabled: Bool = false,
        bootstrap: [PeerEndpoint] = [],
        mode: IvyMode = .overlay,
        requestTimeout: Duration = .seconds(15),
        relayTimeout: Duration = .seconds(5),
        maxConnections: Int = IvyConfig.defaultMaxConnections,
        frame: UInt32 = IvyConfig.defaultProtocolMaxFrameSize,
        start: Bool = true
    ) -> Node {
        let node = addNode { key in
            IvyConfig(
                signingKey: key,
                listenPort: 4001,
                bootstrapPeers: bootstrap,
                requestTimeout: requestTimeout,
                relayTimeout: relayTimeout,
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                maxConnections: maxConnections,
                protocolMaxFrameSize: frame,
                relayEnabled: relayEnabled,
                carriers: carriers,
                mode: mode)
        }
        if start { self.start(node) }
        return node
    }

    /// Runs until both endpoints hold a session with the carrier.
    func attach(_ endpoints: [Node], to carrier: Node, file: StaticString = #filePath, line: UInt = #line) {
        let attached = run(until: {
            endpoints.allSatisfy { node in
                node.core.sessions[carrier.key] != nil
                    && carrier.core.connectedPeers.contains(node.peer)
            }
        })
        XCTAssertTrue(attached, "endpoints did not reach the carrier", file: file, line: line)
        run(for: .milliseconds(100))
    }

    /// A relay-enabled carrier with endpoints `a` and `b` attached to it and
    /// unable to dial each other. `a` always configures the carrier; `b`
    /// either does too, or connects to it as an ordinary peer.
    func relayTriangle(
        frame: UInt32 = IvyConfig.defaultProtocolMaxFrameSize,
        carrierFrame: UInt32? = nil,
        targetConfiguresCarrier: Bool = true,
        pinSource: Bool = false,
        requestTimeout: Duration = .seconds(15),
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (carrier: Node, a: Node, b: Node) {
        let carrier = relayNode(
            relayEnabled: true, requestTimeout: requestTimeout, frame: carrierFrame ?? frame)
        let b = relayNode(
            carriers: targetConfiguresCarrier ? [carrier.endpoint] : [],
            requestTimeout: requestTimeout,
            frame: frame)
        let a = relayNode(
            carriers: [carrier.endpoint],
            mode: pinSource ? .pinned(peer: b.key.hex) : .overlay,
            requestTimeout: requestTimeout,
            frame: frame)
        setPartitioned(true, a, b)
        if !targetConfiguresCarrier { connect(b, carrier, file: file, line: line) }
        attach([a, b], to: carrier, file: file, line: line)
        return (carrier, a, b)
    }

    /// Opens a relayed session from `a` to `b` and returns its route ID.
    @discardableResult
    func connectRelayed(
        _ a: Node,
        _ b: Node,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Data? {
        let result = self.await(.connectViaRelay(b.endpoint), on: a)
        XCTAssertEqual(result, .connect(.connected), file: file, line: line)
        run(until: { b.core.connectedPeers.contains(a.peer) })
        run(for: .milliseconds(100))
        guard case .relayed(_, let routeID)? = a.core.authenticatedPeer(for: b.peer)?.route else {
            XCTFail("no relayed session", file: file, line: line)
            return nil
        }
        return routeID
    }

    /// Sends, waiting out backpressure on the way.
    func sendWhenWritable(
        from a: Node,
        to peer: PeerID,
        topic: String,
        payload: Data
    ) -> SendMessageResult? {
        for _ in 0..<64 {
            let result = self.await(.send(to: peer, topic: topic, payload: payload), on: a)?.sent
            guard result == .backpressured else { return result }
            guard self.await(.waitUntilWritable(peer), on: a) == .writable(true) else { return result }
        }
        return .backpressured
    }
}

/// Asserts the node holds no route, no pending open and no relayed link.
func assertNoRelayState(
    _ node: Simulation.Node,
    _ name: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(node.core.relayRoutes.isEmpty, "\(name) relayRoutes", file: file, line: line)
    XCTAssertTrue(node.core.installedRoutes.isEmpty, "\(name) installedRoutes", file: file, line: line)
    XCTAssertTrue(node.core.pendingRelayOpens.isEmpty, "\(name) pendingRelayOpens", file: file, line: line)
    XCTAssertTrue(
        node.core.links.values.allSatisfy(\.isDirect), "\(name) relayed links", file: file, line: line)
}
