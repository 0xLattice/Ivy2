import Crypto
import Foundation
import XCTest
@testable import IvyCore

/// Ivy mode and carrier isolation
final class IvyTopologyTests: XCTestCase {
    private func identity(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func key(_ identity: Curve25519.Signing.PrivateKey) -> String {
        try! PeerKey(rawRepresentation: identity.publicKey.rawRepresentation).hex
    }

    /// private network accepts direct endpoints without public discovery
    func testPrivateNetworkTopology() throws {
        let first = key(identity(2))
        let second = key(identity(3))
        let mode = IvyMode.privateNetwork
        XCTAssert(mode.allowsEndpoint(try PeerKey(first)))
        XCTAssert(mode.allowsEndpoint(try PeerKey(second)))
        XCTAssert(!mode.participatesInPublicDiscovery)
        XCTAssert(!mode.usesOverlayServices)

        let config = IvyConfig(
            signingKey: identity(1),
            bootstrapPeers: [
                PeerEndpoint(publicKey: first, host: "127.0.0.1", port: 4001),
                PeerEndpoint(publicKey: second, host: "127.0.0.1", port: 4002),
            ],
            stunServers: [("stun.example", 3478)],
            minPeerKeyBits: 0,
            mode: mode
        )
        try config.validate()
        XCTAssert(config.stunServers.isEmpty)
    }

    /// private network rejects relay configuration
    func testPrivateNetworkRelayRejected() {
        let remote = key(identity(2))
        let carrier = PeerEndpoint(publicKey: remote, host: "127.0.0.1", port: 4001)
        let relayServer = IvyConfig(
            signingKey: identity(1),
            relayEnabled: true,
            mode: .privateNetwork)
        let relayClient = IvyConfig(
            signingKey: identity(1),
            carriers: [carrier],
            mode: .privateNetwork)

        XCTAssertThrowsError(try relayServer.validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration(
            "private network does not support relay transport"))
        }
        XCTAssertThrowsError(try relayClient.validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration(
            "private network does not support relay transport"))
        }
    }

    /// operator-tunable route/TTL/volume/frame knobs are validated at startup
    func testOperatorKnobValidation() {
        let invalidMessage = "route, provider-TTL, volume, or frame-size limits are invalid"
        // A baseline valid config; each variant below flips one knob to an unusable value.
        XCTAssertNoThrow(try IvyConfig(signingKey: identity(1)).validate())
        XCTAssertThrowsError(try IvyConfig(signingKey: identity(1), maxRoutesPerIdentity: 0).validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration(invalidMessage))
        }
        XCTAssertThrowsError(try IvyConfig(signingKey: identity(1), maxProviderTTLSeconds: 0).validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration(invalidMessage))
        }
        XCTAssertThrowsError(try IvyConfig(signingKey: identity(1), maxProviderRecordsPerPeer: 0).validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration(invalidMessage))
        }
        XCTAssertThrowsError(try IvyConfig(signingKey: identity(1), maxInFlightVolumeBytes: 0).validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration(invalidMessage))
        }
        // A frame too small to carry the largest handshake record breaks every
        // connection before it starts, so it must be rejected up front. A tiny
        // frame also trips the inbound-budget guard first; assert either rejects.
        XCTAssertThrowsError(try IvyConfig(signingKey: identity(1), protocolMaxFrameSize: 16).validate())
    }

    /// protocolMaxFrameSize must carry the largest RELAYED handshake exactly
    func testFrameSizeMustCarryLargestHandshakeRecord() {
        // Direct: responder hello (64 KiB metadata + 5 pinned keys) in the signed
        // envelope = 65536 + 166 + 73 = 65775. Relayed adds a relayPacket (37) and
        // the carrier's signed data record (113): 65775 + 37 + 113 = 65925. The
        // config floor is the relayed maximum, so any node can forward a handshake.
        XCTAssert(SessionWireRecord.maxHandshakeRecordSize == 65_775)
        XCTAssert(SessionWireRecord.maxRelayedHandshakeRecordSize == 65_925)

        let invalidMessage = "route, provider-TTL, volume, or frame-size limits are invalid"
        // The direct maximum is NOT enough — it cannot carry the relayed handshake.
        XCTAssertThrowsError(try IvyConfig(
                signingKey: identity(1),
                protocolMaxFrameSize: UInt32(SessionWireRecord.maxRelayedHandshakeRecordSize - 1)
            ).validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration(invalidMessage))
        }
        // Exactly the relayed boundary is accepted.
        XCTAssertNoThrow(try IvyConfig(
                signingKey: identity(1),
                protocolMaxFrameSize: UInt32(SessionWireRecord.maxRelayedHandshakeRecordSize)
            ).validate())
    }

    /// pinned identity canonicalizes raw and ed01 spellings
    func testPinnedCanonicalization() throws {
        let remote = key(identity(2))
        let mode = IvyMode.pinned(peer: "ed01" + remote.uppercased())
        XCTAssert(mode.allowsEndpoint(try PeerKey(remote)))
        XCTAssert(!mode.allowsEndpoint(try PeerKey(key(identity(3)))))
        XCTAssert(!mode.participatesInPublicDiscovery)
        XCTAssert(mode.usesOverlayServices)
    }

    /// pinned mode keeps public discovery off and listener configuration intact
    func testPinnedConfiguration() throws {
        let local = identity(1)
        let remote = key(identity(2))
        let endpoint = PeerEndpoint(publicKey: remote, host: "127.0.0.1", port: 4001)
        let config = IvyConfig(
            signingKey: local,
            listenPort: 4100,
            bootstrapPeers: [endpoint],
            stunServers: [("stun.example", 3478)],
            mode: .pinned(peer: remote))

        try config.validate()
        XCTAssert(config.listenPort == 4100)
        XCTAssert(config.stunServers.isEmpty)
    }

    /// pinned endpoint and configured carrier identities are disjoint
    func testCarrierIdentityDisjointness() {
        let local = identity(1)
        let remote = key(identity(2))
        let carrier = PeerEndpoint(publicKey: remote, host: "127.0.0.1", port: 5001)
        let config = IvyConfig(
            signingKey: local,
            carriers: [carrier],
            mode: .pinned(peer: remote))

        XCTAssertThrowsError(try config.validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.identityRoleCollision(remote))
        }
    }

    /// pinned mode rejects substitute bootstrap identities
    func testSubstituteBootstrapRejected() {
        let local = identity(1)
        let expected = key(identity(2))
        let substitute = key(identity(3))
        let config = IvyConfig(
            signingKey: local,
            bootstrapPeers: [PeerEndpoint(publicKey: substitute, host: "127.0.0.1", port: 4002)],
            mode: .pinned(peer: expected))

        XCTAssertThrowsError(try config.validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.peerOutsidePinnedMode(expected: expected, actual: substitute))
        }
    }

    /// pinned mode rejects malformed identities
    func testMalformedPinnedIdentityRejected() {
        let config = IvyConfig(
            signingKey: identity(1),
            mode: .pinned(peer: "not-a-peer-key"))

        XCTAssertThrowsError(try config.validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidPinnedIdentity("not-a-peer-key"))
        }
    }

    /// ordinary connect cannot bypass pinned identity
    func testOrdinaryConnectHonorsPinnedIdentity() {
        let local = identity(1)
        let expected = key(identity(2))
        let substitute = key(identity(3))
        var node = IvyCore(config: IvyConfig(
            signingKey: local,
            mode: .pinned(peer: expected)))

        XCTAssertEqual(
            connect(&node, request: 1, to: PeerEndpoint(
                publicKey: substitute,
                host: "127.0.0.1",
                port: 4001)),
            .failed(.peerOutsideMode))
        XCTAssertEqual(
            connect(&node, request: 2, to: PeerEndpoint(
                publicKey: key(local),
                host: "127.0.0.1",
                port: 4001)),
            .failed(.peerOutsideMode))
    }

    /// configured carrier cannot be used as an application endpoint
    func testCarrierCannotBecomeEndpoint() {
        let local = identity(1)
        let carrierKey = key(identity(4))
        let carrier = PeerEndpoint(publicKey: carrierKey, host: "127.0.0.1", port: 5001)
        var node = IvyCore(config: IvyConfig(signingKey: local, carriers: [carrier]))

        XCTAssertEqual(connect(&node, request: 1, to: carrier), .failed(.peerOutsideMode))
        XCTAssert(node.connectedPeers.isEmpty)
    }

    /// The outcome the core gives a `connect` request in the same step, as
    /// 15.0.1's `connect(to:)` threw before it suspended.
    private func connect(
        _ node: inout IvyCore,
        request: UInt64,
        to endpoint: PeerEndpoint
    ) -> ConnectOutcome? {
        let effects = node.step(
            .request(RequestID(request), .connect(endpoint)),
            now: Timestamp(uptime: .zero, unixSeconds: 1_800_000_000))
        for case .completed(RequestID(request), .connect(let outcome)) in effects { return outcome }
        return nil
    }

    /// the protocol frame fits maximum canonical metadata through relay
    func testProtocolFrameFitsMaximumMetadata() throws {
        let initiatorIdentity = identity(2)
        let responderIdentity = identity(3)
        let carrierIdentity = identity(4)
        let initiator = try PeerKey(rawRepresentation: initiatorIdentity.publicKey.rawRepresentation)
        let responder = try PeerKey(rawRepresentation: responderIdentity.publicKey.rawRepresentation)
        let carrier = try PeerKey(rawRepresentation: carrierIdentity.publicKey.rawRepresentation)
        let addresses = (0..<8).map { index in
            let length = index < 6 ? 8_186 : 8_185
            let suffix = "\(index)"
            return ListenAddress(
                host: String(repeating: "a", count: length - suffix.count) + suffix,
                port: UInt16(index + 1))
        }
        let metadata = try XCTUnwrap(PeerMetadata(listenAddresses: addresses).encode())
        XCTAssert(metadata.count == PeerMetadata.maxEncodedSize)
        let initiatorHello = SessionHelloInitiator(
            routeBinding: Data(repeating: 0x11, count: 32),
            initiator: initiator,
            responder: responder,
            nonce: Data(repeating: 0x22, count: 32),
            metadata: metadata)
        let signedInitiator = try SignedSessionHelloInitiator.sign(
            initiatorHello,
            with: Ed25519Scheme(signingKey: initiatorIdentity))
        let initiatorRecord = SessionWireRecord.helloInitiator(signedInitiator).serialize()
        XCTAssert(try SessionWireRecord.deserialize(initiatorRecord) == .helloInitiator(signedInitiator))

        let hello = SessionHelloResponder(
            routeBinding: Data(repeating: 0x11, count: 32),
            responder: responder,
            initiator: initiator,
            initiatorNonce: Data(repeating: 0x22, count: 32),
            responderNonce: Data(repeating: 0x33, count: 32),
            metadata: metadata)
        let signedHello = try SignedSessionHelloResponder.sign(hello, with: Ed25519Scheme(signingKey: responderIdentity))
        let endpointRecord = SessionWireRecord.helloResponder(signedHello).serialize()
        XCTAssert(try SessionWireRecord.deserialize(endpointRecord) == .helloResponder(signedHello))
        let relayPacket = Message.relayPacket(
            routeID: Data(repeating: 0x44, count: 32),
            opaqueEndpointRecord: endpointRecord
        ).serialize()
        let carrierRecord = try SessionDataRecord.sign(
            sessionID: SessionID(bytes: Data(repeating: 0x55, count: 32)),
            sender: carrier,
            receiver: responder,
            sequence: 1,
            payload: relayPacket,
            with: Ed25519Scheme(signingKey: carrierIdentity))
        let wireRecord = SessionWireRecord.data(carrierRecord)

        let serialized = wireRecord.serialize()
        XCTAssert(!serialized.isEmpty)
        XCTAssert(serialized.count <= Int(IvyConfig.defaultProtocolMaxFrameSize))
        guard case .data(let decodedCarrier) = try SessionWireRecord.deserialize(serialized),
              case .relayPacket(_, let opaqueRecord) = Message.deserialize(decodedCarrier.payload) else {
            XCTFail("Expected a nested responder record")
            return
        }
        XCTAssert(try SessionWireRecord.deserialize(opaqueRecord) == .helloResponder(signedHello))
    }

    /// invalid transport capacities fail before the listener starts
    func testInvalidCapacityRejected() {
        let config = IvyConfig(signingKey: identity(1), maxConnections: 0)

        XCTAssertThrowsError(try config.validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration("capacity limits must be positive"))
        }

        let excessiveReservation = IvyConfig(
            signingKey: identity(1),
            maxConnections: 1,
            reservedOutboundConnectionSlots: 2)
        XCTAssertThrowsError(try excessiveReservation.validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration(
            "reserved outbound connection slots must fit within maxConnections"))
        }

        let undersizedInboundBudget = IvyConfig(
            signingKey: identity(1),
            maxInboundBufferedBytes: Int(IvyConfig.defaultProtocolMaxFrameSize))
        XCTAssertThrowsError(try undersizedInboundBudget.validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration(
            "inbound byte budget must hold one maximum frame"))
        }

        let invalidHealth = IvyConfig(
            signingKey: identity(1),
            healthConfig: PeerHealthConfig(keepaliveInterval: .zero))
        XCTAssertThrowsError(try invalidHealth.validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration("peer health limits are invalid"))
        }

        let hostnameAdvertisement = IvyConfig(
            signingKey: identity(1),
            externalAddress: ("node.example.com", 4001))
        XCTAssertThrowsError(try hostnameAdvertisement.validate()) {
            XCTAssertEqual($0 as? IvyModeError, IvyModeError.invalidConfiguration(
            "externalAddress must be an IP literal with a nonzero port"))
        }
    }

}
