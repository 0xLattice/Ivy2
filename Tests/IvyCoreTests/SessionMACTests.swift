import Crypto
import Foundation
import XCTest
@testable import IvyCore
import IvySimulation
import Tally

/// Records MACed under keys from an X25519 exchange made in the first signed
/// records, between peers that both send a share; signed records otherwise.
final class SessionMACTests: XCTestCase {
    private func peerKey(_ byte: UInt8) -> PeerKey {
        let identity = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
        return try! PeerKey(rawRepresentation: identity.publicKey.rawRepresentation)
    }

    private func share(_ byte: UInt8) -> Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private let sessionID = try! SessionID(bytes: Data(repeating: 7, count: 32))

    private func keys(
        _ local: UInt8, _ remote: UInt8, sessionID: SessionID? = nil
    ) -> SessionMACKeys {
        SessionMACKeys(
            localShare: share(local),
            remoteShare: share(remote).publicKey.rawRepresentation,
            sessionID: sessionID ?? self.sessionID,
            localKey: peerKey(local),
            remoteKey: peerKey(remote))!
    }

    private func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Keys and records

    func testEachDirectionHasItsOwnKeyAndBothSidesAgree() {
        let a = keys(1, 2)
        let b = keys(2, 1)
        XCTAssertEqual(bytes(a.send), bytes(b.receive))
        XCTAssertEqual(bytes(a.receive), bytes(b.send))
        XCTAssertNotEqual(bytes(a.send), bytes(a.receive))
        // Another session's keys differ.
        let other = keys(1, 2, sessionID: try! SessionID(bytes: Data(repeating: 8, count: 32)))
        XCTAssertNotEqual(bytes(other.send), bytes(a.send))
    }

    func testALowOrderShareGivesNoKeys() {
        for lowOrder in [Data(count: 32), Data([1] + Array(repeating: 0, count: 31))] {
            XCTAssertNil(SessionMACKeys(
                localShare: share(1), remoteShare: lowOrder, sessionID: sessionID,
                localKey: peerKey(1), remoteKey: peerKey(2)))
        }
    }

    func testAnAlteredRecordDoesNotVerify() throws {
        let key = keys(1, 2).send
        let record = try SessionMACRecord.seal(
            sessionID: sessionID, sequence: 5, payload: Data("payload".utf8), key: key)
        XCTAssertTrue(record.isValid(key: key))
        let wire = SessionWireRecord.macData(record).serialize()
        XCTAssertEqual(try SessionWireRecord.deserialize(wire), .macData(record))

        var payload = record.payload
        payload[payload.startIndex] ^= 1
        var mac = record.mac
        mac[mac.startIndex] ^= 1
        let altered = [
            SessionMACRecord(sessionID: record.sessionID, sequence: 5, payload: payload, mac: record.mac),
            SessionMACRecord(sessionID: record.sessionID, sequence: 6, payload: record.payload, mac: record.mac),
            SessionMACRecord(
                sessionID: try SessionID(bytes: Data(repeating: 8, count: 32)),
                sequence: 5, payload: record.payload, mac: record.mac),
            SessionMACRecord(sessionID: record.sessionID, sequence: 5, payload: record.payload, mac: mac),
            SessionMACRecord(sessionID: record.sessionID, sequence: 5, payload: record.payload, mac: record.mac.prefix(31)),
        ]
        for record in altered { XCTAssertFalse(record.isValid(key: key)) }
        // The other direction's key, as for a reflected record.
        XCTAssertFalse(record.isValid(key: keys(1, 2).receive))
        // Sequence zero is never sealed or read.
        XCTAssertThrowsError(try SessionMACRecord.seal(
            sessionID: sessionID, sequence: 0, payload: Data(), key: key))
    }

    func testTheShareMessageIsExactlyThirtyTwoBytes() {
        let share = Data(repeating: 9, count: 32)
        let encoded = Message.sessionKey(share).serialize()
        XCTAssertEqual(encoded, Data([7]) + share)
        guard case .sessionKey(let decoded)? = Message.deserialize(encoded) else { return XCTFail() }
        XCTAssertEqual(decoded, share)
        XCTAssertNil(Message.deserialize(encoded.dropLast()))
        XCTAssertNil(Message.deserialize(encoded + Data([0])))
        XCTAssertTrue(Message.sessionKey(Data(count: 31)).serialize().isEmpty)
    }

    func testWhatFitsAFrameDoesNotDependOnTheRecordKind() throws {
        // A carrier re-wraps a relayed record in its own session's kind, which
        // may differ from the sender's hop: what one hop accepts the other must.
        let frame: UInt32 = 4096
        for size in 3900...4096 {
            let payload = Data(repeating: 1, count: size)
            let signed = SessionWireRecord.data(SessionDataRecord(
                sessionID: sessionID, sequence: 1, payload: payload, signature: Data(count: 64)))
            let maced = SessionWireRecord.macData(try SessionMACRecord.seal(
                sessionID: sessionID, sequence: 1, payload: payload, key: keys(1, 2).send))
            XCTAssertEqual(
                signed.serialize(maxPayload: frame).isEmpty, maced.serialize(maxPayload: frame).isEmpty,
                "payload \(size)")
        }
    }

    /// For other implementations: identities from Ed25519 seeds of 0x01 and
    /// 0x02 bytes, shares from X25519 private keys of the same bytes,
    /// session ID 0x07 bytes; the keys of identity 1 and its record of
    /// `ping(1)` at sequence 1. Checked against an independent implementation.
    func testFrozenVector() throws {
        let keys = keys(1, 2)
        XCTAssertEqual(share(1).publicKey.rawRepresentation.hex, "a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209")
        XCTAssertEqual(share(2).publicKey.rawRepresentation.hex, "ce8d3ad1ccb633ec7b70c17814a5c76ecd029685050d344745ba05870e587d59")
        XCTAssertEqual(bytes(keys.send).hex, "79e8f1930e52e0aae9e8e19894a0979d18dc95e355318cec82d06f79a5a4b348")
        XCTAssertEqual(bytes(keys.receive).hex, "80d957e334e0c5ba2f2de3251751b53f5bf8ba9e7c39c012bdee14b695a3508d")
        let record = try SessionMACRecord.seal(
            sessionID: sessionID, sequence: 1, payload: Message.ping(nonce: 1).serialize(), key: keys.send)
        XCTAssertEqual(SessionWireRecord.macData(record).serialize().hex,
            "495659090507070707070707070707070707070707070707070707070707070707070707070000000000000001000000090000000000000000017465db96b955711fe5e6905fd4fb2ecd1be0d78d002a63b4d73167fd6751ca86")
    }

    // MARK: - Between nodes of this version

    /// The tags of the session records `node` wrote, in order.
    private func recordTags(_ sim: Simulation, by node: Simulation.Node, since start: Int) -> [UInt8] {
        sim.trace[start...].flatMap { entry -> [UInt8] in
            guard entry.node == node.id, case .write(_, let bytes) = entry.effect else { return [] }
            var tags: [UInt8] = []
            var rest = bytes[...]
            while rest.count >= 9 {
                let length = rest.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                tags.append(rest[rest.startIndex + 8])
                rest = rest.dropFirst(4 + length)
            }
            return tags
        }
    }

    func testNodesSwitchToMACedRecordsOnceBothSharesAreIn() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        let start = sim.trace.count
        sim.connect(a, b)
        sim.run(for: .milliseconds(100))
        XCTAssertNotNil(a.core.sessions[b.key]?.macKeys)
        XCTAssertNotNil(b.core.sessions[a.key]?.macKeys)
        XCTAssertNil(a.core.sessions[b.key]?.keyShare)

        for index in 0..<3 {
            XCTAssertEqual(
                sim.await(.send(to: b.peer, topic: "m", payload: Data([UInt8(index)])), on: a)?.sent,
                .enqueued(endpoint: b.peer, route: .direct))
        }
        XCTAssertEqual(
            sim.await(.send(to: a.peer, topic: "r", payload: Data([9])), on: b)?.sent,
            .enqueued(endpoint: a.peer, route: .direct))
        sim.run(for: .milliseconds(100))
        XCTAssertEqual(b.received.map(\.message.payload), [Data([0]), Data([1]), Data([2])])
        XCTAssertEqual(a.received.map(\.message.payload), [Data([9])])

        // A handshake record, the signed share, then MACed records only.
        let tags = recordTags(sim, by: a, since: start)
        XCTAssertEqual(Array(tags.prefix(3)), [1, 3, 4], "\(tags)")
        XCTAssertEqual(Set(tags.dropFirst(3)), [5], "\(tags)")
        XCTAssertEqual(a.ledger.violations(of: b.peer), 0)
        XCTAssertEqual(b.ledger.violations(of: a.peer), 0)
    }

    func testARelayedSessionAndItsCarrierSessionBothMAC() {
        let sim = Simulation()
        let (carrier, a, b) = sim.relayTriangle()
        sim.connectRelayed(a, b)
        XCTAssertNotNil(a.core.sessions[b.key]?.macKeys)
        XCTAssertNotNil(b.core.sessions[a.key]?.macKeys)
        XCTAssertNotNil(a.core.sessions[carrier.key]?.macKeys)
        XCTAssertNotNil(carrier.core.sessions[b.key]?.macKeys)
        guard case .enqueued? = sim.await(.send(to: b.peer, topic: "t", payload: Data([1])), on: a)?.sent else {
            return XCTFail("not sent")
        }
        sim.run(until: { !b.received.isEmpty })
        XCTAssertEqual(b.received.first?.message, PeerMessage(topic: "t", payload: Data([1])))
    }

    // MARK: - With a peer from before

    func testAPeerThatSendsNoShareKeepsASignedSession() {
        let sim = Simulation()
        let node = sim.node()
        let old = WireRawPeer(sim, to: node, label: "old-peer")
        XCTAssertTrue(old.handshake())
        // The node offered its share; the old peer ignores it.
        sim.run(for: .milliseconds(100))
        XCTAssertNil(node.core.sessions[old.key]?.macKeys)

        old.send(.ping(nonce: 4))
        old.send(.peerMessage(topic: "t", payload: Data([4])))
        sim.run(for: .milliseconds(100))
        XCTAssertEqual(node.received.map(\.message), [PeerMessage(topic: "t", payload: Data([4]))])
        XCTAssertEqual(
            sim.await(.send(to: old.id, topic: "back", payload: Data([5])), on: node)?.sent,
            .enqueued(endpoint: old.id, route: .direct))
        let records = old.takeRecords()
        XCTAssertFalse(records.isEmpty)
        for record in records {
            guard case .data(let data) = record else { return XCTFail("a record that is not signed") }
            XCTAssertTrue(data.isValid(
                sender: node.key, receiver: old.key, using: SimulatedSignatureScheme(key: old.key)))
        }
        XCTAssertNotNil(node.core.sessions[old.key])
    }

    func testAMixedNetworkMACsOnlyBetweenPeersOfThisVersion() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        sim.connect(a, b)
        let old = WireRawPeer(sim, to: a, label: "old-peer")
        XCTAssertTrue(old.handshake())
        sim.run(for: .milliseconds(100))
        XCTAssertNotNil(a.core.sessions[b.key]?.macKeys)
        XCTAssertNil(a.core.sessions[old.key]?.macKeys)

        old.send(.peerMessage(topic: "from-old", payload: Data([1])))
        _ = sim.await(.send(to: a.peer, topic: "from-b", payload: Data([2])), on: b)
        _ = sim.await(.send(to: old.id, topic: "to-old", payload: Data([3])), on: a)
        _ = sim.await(.send(to: b.peer, topic: "to-b", payload: Data([4])), on: a)
        sim.run(for: .milliseconds(100))
        XCTAssertEqual(Set(a.received.map(\.message.topic)), ["from-old", "from-b"])
        XCTAssertEqual(b.received.map(\.message.topic), ["to-b"])
        let toOld = old.takeMessages().compactMap { message -> String? in
            if case .peerMessage(let topic, _) = message { return topic }
            return nil
        }
        XCTAssertEqual(toOld, ["to-old"])
        XCTAssertEqual(a.core.peerConnectionCount, 2)
    }

    // MARK: - A peer of this version, played by hand

    private func macPeer(_ sim: Simulation, _ node: Simulation.Node) -> WireRawPeer {
        let peer = WireRawPeer(sim, to: node, label: "mac-peer")
        XCTAssertTrue(peer.handshake())
        XCTAssertTrue(peer.exchangeKeys())
        XCTAssertNotNil(node.core.sessions[peer.key]?.macKeys)
        return peer
    }

    private func assertEnded(
        _ peer: WireRawPeer, at node: Simulation.Node, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNil(node.core.sessions[peer.key], file: file, line: line)
        XCTAssertTrue(sim(peer).nodeClosedRaw(peer.connection), file: file, line: line)
        // Like a bad signature, a bad MAC proves nothing about the peer.
        XCTAssertEqual(node.ledger.violations(of: peer.id), 0, file: file, line: line)
    }

    private func sim(_ peer: WireRawPeer) -> Simulation { peer.sim }

    private func pongs(_ peer: WireRawPeer) -> [UInt64] {
        peer.takeMessages().compactMap { $0.pongNonce }
    }

    func testMACedRecordsAreAnsweredInKind() {
        let sim = Simulation()
        let node = sim.node()
        let peer = macPeer(sim, node)
        peer.write(peer.macRecord(payload: Message.ping(nonce: 11).serialize()))
        sim.run(for: .milliseconds(10))
        let records = peer.takeRecords()
        XCTAssertEqual(records.count, 1)
        guard case .macData? = records.first else { return XCTFail("the reply is not MACed") }
        peer.write(peer.macRecord(payload: Message.ping(nonce: 12).serialize()))
        sim.run(for: .milliseconds(10))
        XCTAssertEqual(pongs(peer), [12])
    }

    func testSignedRecordsAreStillAcceptedOnceKeysAreSet() {
        // A peer's signed records may still be in flight when it switches.
        let sim = Simulation()
        let node = sim.node()
        let peer = macPeer(sim, node)
        peer.send(.ping(nonce: 21))
        peer.write(peer.macRecord(payload: Message.ping(nonce: 22).serialize()))
        peer.send(.ping(nonce: 23))
        sim.run(for: .milliseconds(10))
        XCTAssertEqual(pongs(peer), [21, 22, 23])
    }

    func testATamperedRecordEndsTheSession() {
        for offset in [9, 4 + 1 + 32 + 2, 4 + 1 + 32 + 8 + 4 + 1, -1] {
            let sim = Simulation()
            let node = sim.node()
            let peer = macPeer(sim, node)
            var record = peer.macRecord(payload: Message.ping(nonce: 1).serialize())
            let index = offset >= 0 ? record.startIndex + offset : record.endIndex - 1
            record[index] ^= 0x01
            peer.write(record)
            sim.run(for: .milliseconds(10))
            assertEnded(peer, at: node)
        }
    }

    func testAReplayedRecordEndsTheSession() {
        let sim = Simulation()
        let node = sim.node()
        let peer = macPeer(sim, node)
        let record = peer.macRecord(payload: Message.ping(nonce: 1).serialize())
        peer.write(record)
        sim.run(for: .milliseconds(10))
        XCTAssertEqual(pongs(peer), [1])
        peer.write(record)
        sim.run(for: .milliseconds(10))
        assertEnded(peer, at: node)
    }

    func testReorderedRecordsEndTheSession() {
        let sim = Simulation()
        let node = sim.node()
        let peer = macPeer(sim, node)
        let first = peer.macRecord(payload: Message.ping(nonce: 1).serialize())
        let second = peer.macRecord(payload: Message.ping(nonce: 2).serialize())
        peer.write(second)
        peer.write(first)
        sim.run(for: .milliseconds(10))
        XCTAssertEqual(pongs(peer), [2])
        assertEnded(peer, at: node)
    }

    func testAMalformedMACedMessageIsChargedToThePeer() {
        // Only the two ends hold the peer's direction key, and the node never
        // MACs with it, so a valid MAC is the peer's word, as a signature is.
        let sim = Simulation()
        let node = sim.node()
        let peer = macPeer(sim, node)
        // A ping without its nonce: a known tag that does not decode.
        peer.write(peer.macRecord(payload: Data([0])))
        sim.run(for: .milliseconds(10))
        XCTAssertNil(node.core.sessions[peer.key])
        XCTAssertEqual(node.ledger.violations(of: peer.id), 1)
    }

    func testAMACedRecordBeforeTheKeysEndsTheSession() {
        let sim = Simulation()
        let node = sim.node()
        let peer = WireRawPeer(sim, to: node, label: "early-mac")
        XCTAssertTrue(peer.handshake())
        // The peer has sent no share, so the node has no key to check with.
        peer.write(peer.macRecord(
            payload: Message.ping(nonce: 1).serialize(), sequence: 1,
            key: SymmetricKey(data: Data(repeating: 0, count: 32))))
        sim.run(for: .milliseconds(10))
        assertEnded(peer, at: node)
    }

    func testAReflectedRecordEndsTheSession() {
        let sim = Simulation()
        let node = sim.node()
        let peer = macPeer(sim, node)
        // Make the node write a MACed record, then send it back to the node
        // under a sequence the node has not yet seen from the peer.
        peer.write(peer.macRecord(payload: Message.ping(nonce: 1).serialize()))
        sim.run(for: .milliseconds(10))
        guard case .macData(let nodeRecord)? = peer.takeRecords().first else { return XCTFail("no reply") }
        XCTAssertTrue(nodeRecord.sequence > 0)
        let reflected = try! SessionMACRecord.seal(
            sessionID: nodeRecord.sessionID, sequence: 100, payload: nodeRecord.payload,
            key: peer.macKeys!.receive)
        peer.write(SessionWireRecord.macData(reflected).serialize())
        sim.run(for: .milliseconds(10))
        assertEnded(peer, at: node)
    }

    func testARecordFromAnotherSessionEndsTheSession() {
        let sim = Simulation()
        let node = sim.node()
        let first = macPeer(sim, node)
        let staleKey = first.macKeys!.send
        // The same identity's next session, on a new connection.
        sim.closeRaw(first.connection, at: node)
        sim.run(for: .milliseconds(10))
        let second = WireRawPeer(sim, to: node, label: "mac-peer", attempt: 1)
        XCTAssertTrue(second.handshake())
        XCTAssertTrue(second.exchangeKeys(attempt: 1))
        // The new session's ID and sequence under the old session's key: only
        // the key tells them apart.
        second.write(second.macRecord(payload: Message.ping(nonce: 1).serialize(), key: staleKey))
        sim.run(for: .milliseconds(10))
        assertEnded(second, at: node)
    }

    func testALowOrderShareKeepsTheSessionSigned() {
        let sim = Simulation()
        let node = sim.node()
        let peer = WireRawPeer(sim, to: node, label: "low-order")
        XCTAssertTrue(peer.handshake())
        // u = 0 has order 1: the secret would be all zeros, known to anyone.
        peer.send(.sessionKey(Data(count: 32)))
        sim.run(for: .milliseconds(10))
        XCTAssertNil(node.core.sessions[peer.key]?.macKeys)
        _ = peer.takeRecords()
        peer.send(.ping(nonce: 41))
        sim.run(for: .milliseconds(10))
        let records = peer.takeRecords()
        XCTAssertEqual(records.count, 1)
        guard case .data(let reply)? = records.first else { return XCTFail("the reply is not signed") }
        XCTAssertEqual(Message.deserialize(reply.payload)?.pongNonce, 41)
        XCTAssertNotNil(node.core.sessions[peer.key])
        XCTAssertEqual(node.ledger.violations(of: peer.id), 0)
    }

    func testASecondShareIsIgnored() {
        let sim = Simulation()
        let node = sim.node()
        let peer = macPeer(sim, node)
        let receive = node.core.sessions[peer.key]?.macKeys.map { bytes($0.receive) }
        peer.send(.sessionKey(share(9).publicKey.rawRepresentation))
        sim.run(for: .milliseconds(10))
        XCTAssertEqual(node.core.sessions[peer.key]?.macKeys.map { bytes($0.receive) }, receive)
        peer.write(peer.macRecord(payload: Message.ping(nonce: 31).serialize()))
        sim.run(for: .milliseconds(10))
        XCTAssertEqual(pongs(peer), [31])
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

