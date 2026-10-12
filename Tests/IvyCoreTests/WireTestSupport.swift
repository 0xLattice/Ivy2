import Crypto
import Foundation
import XCTest
@testable import IvyCore
import IvySimulation
import Tally

func wireTestSigningKey(_ label: String) -> Curve25519.Signing.PrivateKey {
    try! Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(SHA256.hash(data: Data(label.utf8))))
}

func wireTestPeerKey(_ label: String) -> String {
    try! PeerKey(rawRepresentation: wireTestSigningKey(label).publicKey.rawRepresentation).hex
}

/// A record behind its four-byte big-endian length, as it travels on a connection.
func wireTestFramed(_ record: Data) -> Data {
    wireTestLengthPrefix(UInt32(record.count)) + record
}

func wireTestLengthPrefix(_ length: UInt32) -> Data {
    Data([
        UInt8(truncatingIfNeeded: length >> 24),
        UInt8(truncatingIfNeeded: length >> 16),
        UInt8(truncatingIfNeeded: length >> 8),
        UInt8(truncatingIfNeeded: length),
    ])
}

/// The test's end of a raw connection, speaking the session protocol by
/// hand: it is the initiator of a direct session with `node`, and signs with
/// the simulation's scheme, so the node authenticates it as an ordinary peer.
final class WireRawPeer {
    let sim: Simulation
    let node: Simulation.Node
    let key: PeerKey
    let connection: ConnectionID
    private let scheme: SimulatedSignatureScheme
    private let nonce: Data
    private(set) var sessionID: SessionID?
    private var nextSequence: UInt64 = 1
    private var output = Data()

    var id: PeerID { key.peerID }

    /// Opens the connection. `attempt` varies the handshake nonce, and so
    /// the session ID, between connections of one identity.
    init(_ sim: Simulation, to node: Simulation.Node, label: String, host: String = "9.9.0.1", attempt: Int = 0) {
        self.sim = sim
        self.node = node
        key = try! PeerKey(rawRepresentation: wireTestSigningKey(label).publicKey.rawRepresentation)
        scheme = SimulatedSignatureScheme(key: key)
        nonce = Data(SHA256.hash(data: Data("\(label) nonce \(attempt)".utf8)))
        connection = sim.openRawConnection(to: node, fromHost: host)
    }

    /// Runs the initiator handshake and lets the node's application see the
    /// session. False when the node did not keep this connection's session.
    @discardableResult
    func handshake() -> Bool {
        let hello = SessionHelloInitiator(
            routeBinding: IvyCore.directRouteBinding,
            initiator: key,
            responder: node.key,
            nonce: nonce,
            metadata: PeerMetadata().encode()!)
        guard let signedHello = try? SignedSessionHelloInitiator.sign(hello, with: scheme) else {
            return false
        }
        sim.writeRaw(
            wireTestFramed(SessionWireRecord.helloInitiator(signedHello).serialize()),
            on: connection, to: node)
        guard case .helloResponder(let responder)? = takeRecords().first,
              let sessionID = try? SessionID(initiator: signedHello, responder: responder),
              let finish = try? SessionFinish.sign(
                sessionID: sessionID, sender: key, receiver: node.key, with: scheme) else {
            return false
        }
        self.sessionID = sessionID
        sim.writeRaw(
            wireTestFramed(SessionWireRecord.finish(finish).serialize()),
            on: connection, to: node)
        // The `peerConnected` delivery is acknowledged without the clock moving.
        sim.run(for: .zero)
        return node.core.sessions[key]?.sessionID == sessionID
    }

    /// A signed data record carrying `payload`, taking the next sequence number.
    func record(payload: Data) -> Data {
        let record = try! SessionDataRecord.sign(
            sessionID: sessionID!,
            sender: key,
            receiver: node.key,
            sequence: nextSequence,
            payload: payload,
            with: scheme)
        nextSequence += 1
        return SessionWireRecord.data(record).serialize()
    }

    func record(_ message: Message) -> Data {
        record(payload: message.serialize())
    }

    func send(_ message: Message) {
        sim.writeRaw(wireTestFramed(record(message)), on: connection, to: node)
    }

    /// The complete records the node has written since the last call.
    func takeRecords() -> [SessionWireRecord] {
        output.append(sim.takeRawOutput(connection))
        var records: [SessionWireRecord] = []
        while output.count >= 4 {
            let length = output.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard output.count >= 4 + length else { break }
            let body = Data(output.dropFirst(4).prefix(length))
            output = Data(output.dropFirst(4 + length))
            if let record = try? SessionWireRecord.deserialize(body) { records.append(record) }
        }
        return records
    }

    /// The messages the node has sent on the session since the last call.
    func takeMessages() -> [Message] {
        takeRecords().compactMap { record in
            guard case .data(let data) = record else { return nil }
            return Message.deserialize(data.payload)
        }
    }
}
