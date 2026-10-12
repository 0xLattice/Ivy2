import Crypto
import Foundation
import XCTest
@testable import IvyCore

/// Ivy v9 session protocol
final class SessionProtocolTests: XCTestCase {
    private func identity(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func peerKey(_ identity: Curve25519.Signing.PrivateKey) -> PeerKey {
        try! PeerKey(rawRepresentation: identity.publicKey.rawRepresentation)
    }

    private func transcript() throws -> (
        SignedSessionHelloInitiator,
        SignedSessionHelloResponder,
        SessionID,
        Curve25519.Signing.PrivateKey,
        Curve25519.Signing.PrivateKey
    ) {
        let initiator = identity(1)
        let responder = identity(2)
        let helloI = SessionHelloInitiator(
            routeBinding: Data(repeating: 0x33, count: 32),
            initiator: peerKey(initiator),
            responder: peerKey(responder),
            nonce: Data(repeating: 0x11, count: 32),
            metadata: PeerMetadata(listenAddresses: [
                ListenAddress(host: "a.example", port: 4001),
            ]).encode()!)
        let signedI = try SignedSessionHelloInitiator.sign(helloI, with: Ed25519Scheme(signingKey: initiator))
        let helloR = SessionHelloResponder(
            routeBinding: helloI.routeBinding,
            responder: helloI.responder,
            initiator: helloI.initiator,
            initiatorNonce: helloI.nonce,
            responderNonce: Data(repeating: 0x22, count: 32),
            metadata: PeerMetadata(listenAddresses: [
                ListenAddress(host: "r.example", port: 5001),
            ]).encode()!)
        let signedR = try SignedSessionHelloResponder.sign(helloR, with: Ed25519Scheme(signingKey: responder))
        return (signedI, signedR, try SessionID(initiator: signedI, responder: signedR), initiator, responder)
    }

    /// frozen v9 session vectors
    func testFrozenV9Vectors() throws {
        let route = Data(repeating: 0x11, count: 32)
        let initiatorIdentity = identity(1)
        let responderIdentity = identity(2)
        let initiator = peerKey(initiatorIdentity)
        let responder = peerKey(responderIdentity)
        let metadata = Data([0, 0])
        let helloI = SessionHelloInitiator(
            routeBinding: route,
            initiator: initiator,
            responder: responder,
            nonce: Data(repeating: 0x44, count: 32),
            metadata: metadata)
        let signedI = SignedSessionHelloInitiator(
            hello: helloI,
            signature: try XCTUnwrap(Data(hexString:
                "f08acddddd05639166b5d5b106c1892482eab8d5809b91e52af7cf98e6b0e6b34be2895d6ec8a25a0d8ad36f77a392e40d2979977c51eb164fb3d03d0de61c08")))

        let helloR = SessionHelloResponder(
            routeBinding: route,
            responder: responder,
            initiator: initiator,
            initiatorNonce: Data(repeating: 0x44, count: 32),
            responderNonce: Data(repeating: 0x66, count: 32),
            metadata: metadata)
        let signedR = SignedSessionHelloResponder(
            hello: helloR,
            signature: try XCTUnwrap(Data(hexString:
                "b0a8eff2c26e765dbc08e2688cc1adb58e5419ea8cfc34e412a00dd638324c99d133fdaa46a424de0032fb3fd68264b1fe2614414e58852b1b4f66df91ed1809")))
        let sessionID = try SessionID(initiator: signedI, responder: signedR)
        let finish = SessionFinish(
            sessionID: sessionID,
            sender: initiator,
            receiver: responder,
            signature: try XCTUnwrap(Data(hexString:
                "02d5f2ed6b4ba1cb8b5e1691be1bc38a855c5098152eda591b48118793acf3f46781f4c12d16e5bad2f857cfa9273df000dbb7d0034f5a58c51a6e78c900bd07")))
        let dataRecord = SessionDataRecord(
            sessionID: sessionID,
            sequence: 1,
            payload: Data([0xaa, 0xbb]),
            signature: try XCTUnwrap(Data(hexString:
                "a48a8036da2e5655b4e36f126de51a37ab46ce1fca193b5ca094b3524703e7c4a321cf5859c375297ef800ec76e01496c3484bcfdca0bc1d58bcb62f2efb7306")))

        let vectors = [
            SessionWireRecord.helloInitiator(signedI).serialize(),
            SessionWireRecord.helloResponder(signedR).serialize(),
            sessionID.bytes,
            SessionWireRecord.finish(finish).serialize(),
            SessionWireRecord.data(dataRecord).serialize(),
        ]
        let expectedHex = [
            "495659090100000088000911111111111111111111111111111111111111111111111111111111111111118a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c8139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b3944444444444444444444444444444444444444444444444444444444444444444000000020000f08acddddd05639166b5d5b106c1892482eab8d5809b91e52af7cf98e6b0e6b34be2895d6ec8a25a0d8ad36f77a392e40d2979977c51eb164fb3d03d0de61c08",
            "4956590902000000a8000911111111111111111111111111111111111111111111111111111111111111118139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b3948a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c44444444444444444444444444444444444444444444444444444444444444446666666666666666666666666666666666666666666666666666666666666666000000020000b0a8eff2c26e765dbc08e2688cc1adb58e5419ea8cfc34e412a00dd638324c99d133fdaa46a424de0032fb3fd68264b1fe2614414e58852b1b4f66df91ed1809",
            "590f18273722558b37b755b4c0d1786c992673392f3d8359d17a93519da9ccbd",
            "4956590903590f18273722558b37b755b4c0d1786c992673392f3d8359d17a93519da9ccbd8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c8139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b39402d5f2ed6b4ba1cb8b5e1691be1bc38a855c5098152eda591b48118793acf3f46781f4c12d16e5bad2f857cfa9273df000dbb7d0034f5a58c51a6e78c900bd07",
            "4956590904590f18273722558b37b755b4c0d1786c992673392f3d8359d17a93519da9ccbd000000000000000100000002aabba48a8036da2e5655b4e36f126de51a37ab46ce1fca193b5ca094b3524703e7c4a321cf5859c375297ef800ec76e01496c3484bcfdca0bc1d58bcb62f2efb7306",
        ]
        for (vector, hex) in zip(vectors, expectedHex) {
            let actual = vector.map { String(format: "%02x", $0) }.joined()
            XCTAssert(actual == hex)
        }

        XCTAssert(signedI.isValid())
        XCTAssert(signedR.isValid())
        XCTAssert(finish.isValid())
        XCTAssert(dataRecord.isValid(sender: initiator, receiver: responder))

        var legacyWire = vectors[0]
        legacyWire[legacyWire.startIndex + 3] = 0x08
        XCTAssertThrowsError(try SessionWireRecord.deserialize(legacyWire))
    }

    /// metadata contains only canonical listen addresses
    func testCanonicalMetadata() throws {
        let a = ListenAddress(host: "a.example", port: 4001)
        let z = ListenAddress(host: "z.example", port: 4002)
        let metadata = PeerMetadata(listenAddresses: [z, a, z])
        let encoded = try XCTUnwrap(metadata.encode())

        XCTAssert(metadata.listenAddresses == [a, z])
        XCTAssert(try PeerMetadata.decodeCanonical(encoded) == metadata)
    }

    /// metadata advertises a non-default frame size and omits the default
    func testFrameSizeNegotiation() throws {
        let addr = ListenAddress(host: "a.example", port: 4001)

        // The default frame size is OMITTED, so metadata is byte-identical to a
        // legacy peer's — the canonical handshake check stays backward-compatible.
        let dflt = try XCTUnwrap(PeerMetadata(listenAddresses: [addr]).encode())
        let explicit = try XCTUnwrap(PeerMetadata(
            listenAddresses: [addr],
            maxFrameSize: IvyConfig.defaultProtocolMaxFrameSize).encode())
        XCTAssert(dflt == explicit)
        XCTAssert(try PeerMetadata.decodeCanonical(dflt).maxFrameSize
            == IvyConfig.defaultProtocolMaxFrameSize)

        // A non-default frame size round-trips and costs exactly a trailing UInt32.
        let customEncoded = try XCTUnwrap(PeerMetadata(
            listenAddresses: [addr], maxFrameSize: 8 * 1024 * 1024).encode())
        XCTAssert(customEncoded.count == dflt.count + 4)
        XCTAssert(try PeerMetadata.decodeCanonical(customEncoded).maxFrameSize == 8 * 1024 * 1024)

        // Redundantly encoding the default value is non-canonical → rejected.
        var redundant = dflt
        redundant.appendUInt32(IvyConfig.defaultProtocolMaxFrameSize)
        XCTAssertThrowsError(try PeerMetadata.decodeCanonical(redundant)) { XCTAssert($0 is SessionProtocolError) }
    }

    /// signed responder hello and initiator finish authenticate one transcript
    func testHandshake() throws {
        let (helloI, helloR, sessionID, initiatorIdentity, responderIdentity) = try transcript()
        let initiator = peerKey(initiatorIdentity)
        let responder = peerKey(responderIdentity)
        let finish = try SessionFinish.sign(
            sessionID: sessionID,
            sender: initiator,
            receiver: responder,
            with: Ed25519Scheme(signingKey: initiatorIdentity))

        XCTAssert(helloI.isValid())
        XCTAssert(helloR.isValid())
        XCTAssert(finish.isValid())
        XCTAssert(try SessionID(initiator: helloI, responder: helloR) == sessionID)

        let otherSession = try SessionID(bytes: Data(repeating: 0xaa, count: 32))
        XCTAssert(!SessionFinish(
            sessionID: otherSession,
            sender: finish.sender,
            receiver: finish.receiver,
            signature: finish.signature).isValid())
        XCTAssert(!SessionFinish(
            sessionID: finish.sessionID,
            sender: responder,
            receiver: initiator,
            signature: finish.signature).isValid())

        let records: [SessionWireRecord] = [
            .helloInitiator(helloI),
            .helloResponder(helloR),
            .finish(finish),
        ]
        for record in records {
            XCTAssert(try SessionWireRecord.deserialize(record.serialize()) == record)
        }
    }

    /// hello signatures bind identity and metadata
    func testHelloTampering() throws {
        let (signed, _, _, _, wrongIdentity) = try transcript()
        var signature = signed.signature
        signature[0] ^= 1
        XCTAssert(!SignedSessionHelloInitiator(hello: signed.hello, signature: signature).isValid())
        let signedByWrongIdentity = try SignedSessionHelloInitiator.sign(signed.hello, with: Ed25519Scheme(signingKey: wrongIdentity))
        XCTAssert(!signedByWrongIdentity.isValid())

        var metadata = signed.hello.metadata
        metadata[metadata.startIndex] ^= 1
        let changed = SessionHelloInitiator(
            routeBinding: signed.hello.routeBinding,
            initiator: signed.hello.initiator,
            responder: signed.hello.responder,
            nonce: signed.hello.nonce,
            metadata: metadata)
        XCTAssert(!SignedSessionHelloInitiator(hello: changed, signature: signed.signature).isValid())
    }

    /// signed data is transcript-bound and strictly sequenced
    func testSignedData() throws {
        let (_, _, sessionID, initiatorIdentity, responderIdentity) = try transcript()
        let initiator = peerKey(initiatorIdentity)
        let responder = peerKey(responderIdentity)
        let record = try SessionDataRecord.sign(
            sessionID: sessionID,
            sender: initiator,
            receiver: responder,
            sequence: 9,
            payload: Data("payload".utf8),
            with: Ed25519Scheme(signingKey: initiatorIdentity))

        XCTAssert(record.isValid(sender: initiator, receiver: responder))
        XCTAssert(!record.isValid(sender: responder, receiver: initiator))
        XCTAssert(
            try SessionWireRecord.deserialize(SessionWireRecord.data(record).serialize())
                == SessionWireRecord.data(record))

        var receive = SessionSequenceState()
        let first = receive.acceptIncoming(1)
        let gap = receive.acceptIncoming(9)
        let replay = receive.acceptIncoming(9)
        let earlier = receive.acceptIncoming(2)
        XCTAssert(first)
        XCTAssert(gap)
        XCTAssert(!replay)
        XCTAssert(!earlier)
        XCTAssert(!receive.canAcceptIncoming(9))
        XCTAssert(receive.canAcceptIncoming(10))

        var send = SessionSequenceState(nextToSend: UInt64.max)
        let last = send.takeNextOutgoing()
        let exhausted = send.takeNextOutgoing()
        XCTAssert(last == UInt64.max)
        XCTAssert(exhausted == nil)
    }

    /// direct handshake rejects a mismatched route binding
    func testDirectRouteBindingMismatch() throws {
        let localIdentity = identity(1)
        let remoteIdentity = identity(2)
        let local = peerKey(localIdentity)
        let remote = peerKey(remoteIdentity)
        var ivy = IvyCore(config: IvyConfig(signingKey: localIdentity, stunServers: []))
        let connection = ivy.makeLink(
            .direct(ConnectionID(1)),
            endpoint: PeerEndpoint(publicKey: remote.hex, host: "127.0.0.1", port: 4001))
        let metadata = try XCTUnwrap(PeerMetadata().encode())
        let matching = SessionHelloInitiator(
            routeBinding: IvyCore.directRouteBinding,
            initiator: remote,
            responder: local,
            nonce: Data(repeating: 1, count: 32),
            metadata: metadata)
        let mismatched = SessionHelloInitiator(
            routeBinding: Data(repeating: 1, count: 32),
            initiator: remote,
            responder: local,
            nonce: matching.nonce,
            metadata: metadata)

        let acceptsMatching = ivy.acceptsInboundHello(matching, on: connection)
        let acceptsMismatched = ivy.acceptsInboundHello(mismatched, on: connection)
        XCTAssert(acceptsMatching)
        XCTAssert(!acceptsMismatched)
    }

    /// duplicate sessions prefer the smaller session ID
    func testPreferredSessionID() throws {
        let smaller = try SessionID(bytes: Data(repeating: 1, count: 32))
        let larger = try SessionID(bytes: Data(repeating: 2, count: 32))

        // 15.0.1's `Ivy.preferredSessionID` is `min` over `SessionID` in the core.
        XCTAssert(min(larger, smaller) == smaller)
        XCTAssert(min(smaller, larger) == smaller)
    }

    /// application frames are not session records
    func testRejectsApplicationFrame() {
        XCTAssertThrowsError(try SessionWireRecord.deserialize(Message.ping(nonce: 1).serialize()))
    }

    /// protocol violations require endpoint-authenticated evidence
    func testViolationAttribution() {
        let peer = peerKey(identity(3))

        XCTAssert(IvyCore.attributedPeer(peer, direct: true, evidence: .unverified) == nil)
        XCTAssert(IvyCore.attributedPeer(peer, direct: false, evidence: .unverified) == nil)
        XCTAssert(IvyCore.attributedPeer(peer, direct: true, evidence: .signedTransport) == peer)
        XCTAssert(IvyCore.attributedPeer(peer, direct: false, evidence: .signedTransport) == nil)
        XCTAssert(IvyCore.attributedPeer(peer, direct: true, evidence: .signedPayload) == peer)
        XCTAssert(IvyCore.attributedPeer(peer, direct: false, evidence: .signedPayload) == peer)
    }
}
