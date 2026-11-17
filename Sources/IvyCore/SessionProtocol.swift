import Crypto
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum SessionProtocolError: Error, Equatable {
    case malformed
    case nonCanonicalMetadata
}

public struct ListenAddress: Sendable, Hashable, Comparable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public static func < (lhs: ListenAddress, rhs: ListenAddress) -> Bool {
        lhs.host == rhs.host ? lhs.port < rhs.port : lhs.host < rhs.host
    }
}

public struct PeerMetadata: Sendable, Equatable {
    public static let maxEncodedSize = 64 * 1024

    public let listenAddresses: [ListenAddress]
    /// The maximum wire frame this peer will ACCEPT, advertised so the other side
    /// caps what it sends. Encoded as a trailing UInt32 that is OMITTED when it
    /// equals the default — so a legacy peer (which never sends it) and a
    /// default-configured new peer produce byte-identical metadata, keeping the
    /// canonical-encoding handshake check backward-compatible (no flag-day).
    public let maxFrameSize: UInt32

    public init(
        listenAddresses: [ListenAddress] = [],
        maxFrameSize: UInt32 = IvyConfig.defaultProtocolMaxFrameSize
    ) {
        self.listenAddresses = Array(Set(listenAddresses)).sorted()
        self.maxFrameSize = maxFrameSize
    }

    func encode() -> Data? {
        guard listenAddresses.count <= Int(MessageLimits.maxListenAddrs) else { return nil }

        var bytes = Data()
        bytes.appendUInt16(UInt16(listenAddresses.count))
        for address in listenAddresses {
            guard bytes.appendSessionString(address.host) else { return nil }
            bytes.appendUInt16(address.port)
        }
        if maxFrameSize != IvyConfig.defaultProtocolMaxFrameSize {
            bytes.appendUInt32(maxFrameSize)
        }
        return bytes.count <= Self.maxEncodedSize ? bytes : nil
    }

    static func decodeCanonical(_ data: Data) throws -> PeerMetadata {
        guard data.count <= maxEncodedSize else { throw SessionProtocolError.malformed }
        var reader = SessionReader(data)

        guard let addressCount = reader.readUInt16(), addressCount <= MessageLimits.maxListenAddrs else {
            throw SessionProtocolError.malformed
        }
        var addresses: [ListenAddress] = []
        for _ in 0..<addressCount {
            guard let host = reader.readString(), let port = reader.readUInt16() else {
                throw SessionProtocolError.malformed
            }
            addresses.append(ListenAddress(host: host, port: port))
        }

        // A trailing UInt32, when present, is the peer's advertised frame size;
        // its absence means the default (a legacy peer never encodes it).
        let maxFrameSize: UInt32
        if reader.isAtEnd {
            maxFrameSize = IvyConfig.defaultProtocolMaxFrameSize
        } else {
            guard let advertised = reader.readUInt32() else { throw SessionProtocolError.malformed }
            maxFrameSize = advertised
        }

        guard reader.isAtEnd else { throw SessionProtocolError.malformed }
        let metadata = PeerMetadata(listenAddresses: addresses, maxFrameSize: maxFrameSize)
        // Enforces "present iff non-default": a peer that redundantly encodes the
        // default value is rejected as non-canonical.
        guard metadata.encode() == data else { throw SessionProtocolError.nonCanonicalMetadata }
        return metadata
    }
}

struct SessionHelloInitiator: Sendable, Equatable {
    static let version: UInt16 = 9
    static let encodedOverhead = 2 + (4 * PeerKey.byteCount) + 4

    let routeBinding: Data
    let initiator: PeerKey
    let responder: PeerKey
    let nonce: Data
    let metadata: Data

    func encode() -> Data? {
        guard routeBinding.count == 32, nonce.count == 32,
              metadata.count <= PeerMetadata.maxEncodedSize else { return nil }
        var bytes = Data()
        bytes.appendUInt16(Self.version)
        bytes.append(routeBinding)
        bytes.append(initiator.rawRepresentation)
        bytes.append(responder.rawRepresentation)
        bytes.append(nonce)
        guard bytes.appendSessionData(metadata) else { return nil }
        return bytes
    }

    static func decode(_ data: Data) throws -> Self {
        var reader = SessionReader(data)
        guard reader.readUInt16() == version,
              let routeBinding = reader.read(count: 32),
              let initiatorBytes = reader.read(count: 32),
              let responderBytes = reader.read(count: 32),
              let nonce = reader.read(count: 32),
              let metadata = reader.readData(max: PeerMetadata.maxEncodedSize),
              reader.isAtEnd,
              let initiator = try? PeerKey(rawRepresentation: initiatorBytes),
              let responder = try? PeerKey(rawRepresentation: responderBytes) else {
            throw SessionProtocolError.malformed
        }
        _ = try PeerMetadata.decodeCanonical(metadata)
        return Self(
            routeBinding: routeBinding,
            initiator: initiator,
            responder: responder,
            nonce: nonce,
            metadata: metadata)
    }
}

struct SessionHelloResponder: Sendable, Equatable {
    static let encodedOverhead = 2 + (5 * PeerKey.byteCount) + 4

    let routeBinding: Data
    let responder: PeerKey
    let initiator: PeerKey
    let initiatorNonce: Data
    let responderNonce: Data
    let metadata: Data

    func encode() -> Data? {
        guard routeBinding.count == 32, initiatorNonce.count == 32, responderNonce.count == 32,
              metadata.count <= PeerMetadata.maxEncodedSize else { return nil }
        var bytes = Data()
        bytes.appendUInt16(SessionHelloInitiator.version)
        bytes.append(routeBinding)
        bytes.append(responder.rawRepresentation)
        bytes.append(initiator.rawRepresentation)
        bytes.append(initiatorNonce)
        bytes.append(responderNonce)
        guard bytes.appendSessionData(metadata) else { return nil }
        return bytes
    }

    static func decode(_ data: Data) throws -> Self {
        var reader = SessionReader(data)
        guard reader.readUInt16() == SessionHelloInitiator.version,
              let routeBinding = reader.read(count: 32),
              let responderBytes = reader.read(count: 32),
              let initiatorBytes = reader.read(count: 32),
              let initiatorNonce = reader.read(count: 32),
              let responderNonce = reader.read(count: 32),
              let metadata = reader.readData(max: PeerMetadata.maxEncodedSize),
              reader.isAtEnd,
              let responder = try? PeerKey(rawRepresentation: responderBytes),
              let initiator = try? PeerKey(rawRepresentation: initiatorBytes) else {
            throw SessionProtocolError.malformed
        }
        _ = try PeerMetadata.decodeCanonical(metadata)
        return Self(
            routeBinding: routeBinding,
            responder: responder,
            initiator: initiator,
            initiatorNonce: initiatorNonce,
            responderNonce: responderNonce,
            metadata: metadata)
    }
}

struct SignedSessionHelloInitiator: Sendable, Equatable {
    let hello: SessionHelloInitiator
    let signature: Data

    static func sign(_ hello: SessionHelloInitiator, with key: any IvySignatureScheme) throws -> Self {
        guard let encoded = hello.encode() else { throw SessionProtocolError.malformed }
        return Self(hello: hello, signature: try key.signature(for: SessionDomains.hello + encoded))
    }

    func isValid(using scheme: any IvySignatureScheme = Ed25519Scheme.verifier) -> Bool {
        guard signature.count == 64, let encoded = hello.encode() else { return false }
        return scheme.isValidSignature(
            signature, for: SessionDomains.hello + encoded, publicKey: hello.initiator)
    }

    var transcriptBytes: Data? {
        guard let encoded = hello.encode() else { return nil }
        return encoded + signature
    }
}

struct SignedSessionHelloResponder: Sendable, Equatable {
    let hello: SessionHelloResponder
    let signature: Data

    static func sign(_ hello: SessionHelloResponder, with key: any IvySignatureScheme) throws -> Self {
        guard let encoded = hello.encode() else { throw SessionProtocolError.malformed }
        return Self(hello: hello, signature: try key.signature(for: SessionDomains.hello + encoded))
    }

    func isValid(using scheme: any IvySignatureScheme = Ed25519Scheme.verifier) -> Bool {
        guard signature.count == 64, let encoded = hello.encode() else { return false }
        return scheme.isValidSignature(
            signature, for: SessionDomains.hello + encoded, publicKey: hello.responder)
    }

    var transcriptBytes: Data? {
        guard let encoded = hello.encode() else { return nil }
        return encoded + signature
    }
}

struct SessionID: Sendable, Hashable, Comparable {
    let bytes: Data

    init(bytes: Data) throws {
        guard bytes.count == 32 else { throw SessionProtocolError.malformed }
        self.bytes = bytes
    }

    init(initiator: SignedSessionHelloInitiator, responder: SignedSessionHelloResponder) throws {
        guard let helloI = initiator.transcriptBytes, let helloR = responder.transcriptBytes else {
            throw SessionProtocolError.malformed
        }
        var transcript = SessionDomains.transcript
        guard transcript.appendSessionData(helloI), transcript.appendSessionData(helloR) else {
            throw SessionProtocolError.malformed
        }
        self.bytes = Data(SHA256.hash(data: transcript))
    }

    static func < (lhs: SessionID, rhs: SessionID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}

struct SessionFinish: Sendable, Equatable {
    let sessionID: SessionID
    let sender: PeerKey
    let receiver: PeerKey
    let signature: Data

    static func sign(
        sessionID: SessionID,
        sender: PeerKey,
        receiver: PeerKey,
        with key: any IvySignatureScheme
    ) throws -> Self {
        let finish = finishBytes(sessionID: sessionID, sender: sender, receiver: receiver)
        return Self(
            sessionID: sessionID,
            sender: sender,
            receiver: receiver,
            signature: try key.signature(for: SessionDomains.finish + finish))
    }

    func isValid(using scheme: any IvySignatureScheme = Ed25519Scheme.verifier) -> Bool {
        guard signature.count == 64 else { return false }
        return scheme.isValidSignature(
            signature,
            for: SessionDomains.finish + Self.finishBytes(
                sessionID: sessionID, sender: sender, receiver: receiver),
            publicKey: sender)
    }

    private static func finishBytes(
        sessionID: SessionID,
        sender: PeerKey,
        receiver: PeerKey
    ) -> Data {
        var bytes = Data()
        bytes.append(sessionID.bytes)
        bytes.append(sender.rawRepresentation)
        bytes.append(receiver.rawRepresentation)
        return bytes
    }
}

struct SessionDataRecord: Sendable, Equatable {
    let sessionID: SessionID
    let sequence: UInt64
    let payload: Data
    let signature: Data

    static func sign(
        sessionID: SessionID,
        sender: PeerKey,
        receiver: PeerKey,
        sequence: UInt64,
        payload: Data,
        with key: any IvySignatureScheme
    ) throws -> Self {
        guard sequence > 0 else { throw SessionProtocolError.malformed }
        let material = try signingMaterial(
            sessionID: sessionID, sender: sender, receiver: receiver, sequence: sequence, payload: payload)
        return Self(
            sessionID: sessionID,
            sequence: sequence,
            payload: payload,
            signature: try key.signature(for: material))
    }

    func isValid(
        sender: PeerKey,
        receiver: PeerKey,
        using scheme: any IvySignatureScheme = Ed25519Scheme.verifier
    ) -> Bool {
        guard sequence > 0, signature.count == 64,
              let material = try? Self.signingMaterial(
                sessionID: sessionID, sender: sender, receiver: receiver, sequence: sequence, payload: payload) else {
            return false
        }
        return scheme.isValidSignature(signature, for: material, publicKey: sender)
    }

    private static func signingMaterial(
        sessionID: SessionID,
        sender: PeerKey,
        receiver: PeerKey,
        sequence: UInt64,
        payload: Data
    ) throws -> Data {
        var bytes = SessionDomains.data
        bytes.append(sessionID.bytes)
        bytes.append(sender.rawRepresentation)
        bytes.append(receiver.rawRepresentation)
        bytes.appendUInt64(sequence)
        guard bytes.appendSessionData(payload) else { throw SessionProtocolError.malformed }
        return bytes
    }
}

/// The two directions' record MAC keys, from both sides' X25519 shares. The
/// shares travel in signed records, which bind them to the session and to
/// both identities, so only the two peers can derive these keys, and the
/// key for each direction is distinct: a record cannot be reflected.
struct SessionMACKeys: Sendable {
    let send: SymmetricKey
    let receive: SymmetricKey

    /// Nil when the peer's share yields no usable secret; the session then
    /// stays signed.
    init?(
        localShare: Curve25519.KeyAgreement.PrivateKey,
        remoteShare: Data,
        sessionID: SessionID,
        localKey: PeerKey,
        remoteKey: PeerKey
    ) {
        guard let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteShare),
              let secret = try? localShare.sharedSecretFromKeyAgreement(with: remote),
              // A low-order share gives the all-zero secret, known to anyone.
              secret.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { return nil }
        let localPublic = localShare.publicKey.rawRepresentation
        func key(sender: PeerKey, receiver: PeerKey, senderShare: Data, receiverShare: Data) -> SymmetricKey {
            var info = SessionDomains.mac
            info.append(sender.rawRepresentation)
            info.append(receiver.rawRepresentation)
            info.append(senderShare)
            info.append(receiverShare)
            return secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: sessionID.bytes, sharedInfo: info, outputByteCount: 32)
        }
        send = key(sender: localKey, receiver: remoteKey, senderShare: localPublic, receiverShare: remoteShare)
        receive = key(sender: remoteKey, receiver: localKey, senderShare: remoteShare, receiverShare: localPublic)
    }
}

/// A data record authenticated by the session's MAC instead of a signature.
struct SessionMACRecord: Sendable, Equatable {
    let sessionID: SessionID
    let sequence: UInt64
    let payload: Data
    let mac: Data

    static func seal(sessionID: SessionID, sequence: UInt64, payload: Data, key: SymmetricKey) throws -> Self {
        guard sequence > 0 else { throw SessionProtocolError.malformed }
        return Self(
            sessionID: sessionID,
            sequence: sequence,
            payload: payload,
            mac: Data(code(sessionID: sessionID, sequence: sequence, payload: payload, key: key)))
    }

    func isValid(key: SymmetricKey) -> Bool {
        guard sequence > 0, mac.count == 32 else { return false }
        // Constant-time comparison.
        return Self.code(sessionID: sessionID, sequence: sequence, payload: payload, key: key) == mac
    }

    private static func code(
        sessionID: SessionID, sequence: UInt64, payload: Data, key: SymmetricKey
    ) -> HMAC<SHA256>.MAC {
        var header = SessionDomains.mac
        header.append(sessionID.bytes)
        header.appendUInt64(sequence)
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: header)
        hmac.update(data: payload)
        return hmac.finalize()
    }
}

struct SessionSequenceState: Sendable, Equatable {
    private(set) var nextToSend: UInt64
    private(set) var lastReceived: UInt64
    private(set) var sendExhausted: Bool

    init(nextToSend: UInt64 = 1, lastReceived: UInt64 = 0, sendExhausted: Bool = false) {
        self.nextToSend = nextToSend
        self.lastReceived = lastReceived
        self.sendExhausted = sendExhausted
    }

    mutating func takeNextOutgoing() -> UInt64? {
        guard !sendExhausted, nextToSend > 0 else { return nil }
        let sequence = nextToSend
        if sequence == UInt64.max {
            sendExhausted = true
        } else {
            nextToSend += 1
        }
        return sequence
    }

    mutating func acceptIncoming(_ sequence: UInt64) -> Bool {
        guard canAcceptIncoming(sequence) else { return false }
        lastReceived = sequence
        return true
    }

    func canAcceptIncoming(_ sequence: UInt64) -> Bool {
        sequence > lastReceived
    }
}

enum SessionWireRecord: Sendable, Equatable {
    private static let magic = Data([0x49, 0x56, 0x59, 0x09])
    /// Bounds both data records: a MAC record's 32-byte code is smaller
    /// than a signature.
    static let dataRecordOverhead = magic.count + 1 + 32 + 8 + 4 + 64
    /// Envelope bytes wrapping a signed hello: magic + tag + the 4-byte
    /// length prefix `appendSessionData` writes + the 64-byte signature.
    static let helloRecordEnvelopeOverhead = magic.count + 1 + 4 + 64
    /// Largest handshake record on a *direct* connection: a responder hello (the
    /// larger of the two — it pins one extra key) at full metadata, wrapped in the
    /// signed-record envelope.
    static let maxHandshakeRecordSize =
        PeerMetadata.maxEncodedSize
        + SessionHelloResponder.encodedOverhead
        + helloRecordEnvelopeOverhead
    /// Largest handshake a node must carry once *relayed*: the direct handshake
    /// record wrapped in a relayPacket and then in the carrier's own signed data
    /// record. A `protocolMaxFrameSize` below this passes a direct handshake but
    /// cannot forward the legal maximum handshake for another peer over a relay.
    static let maxRelayedHandshakeRecordSize =
        maxHandshakeRecordSize
        + Message.relayPacketEnvelopeOverhead
        + dataRecordOverhead

    case helloInitiator(SignedSessionHelloInitiator)
    case helloResponder(SignedSessionHelloResponder)
    case finish(SessionFinish)
    case data(SessionDataRecord)
    case macData(SessionMACRecord)

    func serialize(maxPayload: UInt32 = IvyConfig.defaultProtocolMaxFrameSize) -> Data {
        var bytes = Self.magic
        switch self {
        case .helloInitiator(let signed):
            guard let hello = signed.hello.encode(), signed.signature.count == 64 else { return Data() }
            bytes.appendUInt8(1)
            guard bytes.appendSessionData(hello) else { return Data() }
            bytes.append(signed.signature)
        case .helloResponder(let signed):
            guard let hello = signed.hello.encode(), signed.signature.count == 64 else { return Data() }
            bytes.appendUInt8(2)
            guard bytes.appendSessionData(hello) else { return Data() }
            bytes.append(signed.signature)
        case .finish(let finish):
            guard finish.signature.count == 64 else { return Data() }
            bytes.appendUInt8(3)
            bytes.append(finish.sessionID.bytes)
            bytes.append(finish.sender.rawRepresentation)
            bytes.append(finish.receiver.rawRepresentation)
            bytes.append(finish.signature)
        case .data(let record):
            guard record.payload.count <= Int(clamping: maxPayload), record.signature.count == 64 else { return Data() }
            bytes.appendUInt8(4)
            bytes.append(record.sessionID.bytes)
            bytes.appendUInt64(record.sequence)
            guard bytes.appendSessionData(record.payload) else { return Data() }
            bytes.append(record.signature)
        case .macData(let record):
            guard record.payload.count <= Int(clamping: maxPayload), record.mac.count == 32 else { return Data() }
            bytes.appendUInt8(5)
            bytes.append(record.sessionID.bytes)
            bytes.appendUInt64(record.sequence)
            guard bytes.appendSessionData(record.payload) else { return Data() }
            bytes.append(record.mac)
        }
        return bytes.count <= Int(clamping: maxPayload) ? bytes : Data()
    }

    static func deserialize(_ data: Data, maxPayload: UInt32 = IvyConfig.defaultProtocolMaxFrameSize) throws -> Self {
        var reader = SessionReader(data)
        guard reader.read(count: magic.count) == magic, let tag = reader.readUInt8() else {
            throw SessionProtocolError.malformed
        }
        switch tag {
        case 1:
            guard let bytes = reader.readData(
                    max: PeerMetadata.maxEncodedSize + SessionHelloInitiator.encodedOverhead),
                  let signature = reader.read(count: 64), reader.isAtEnd else {
                throw SessionProtocolError.malformed
            }
            return .helloInitiator(SignedSessionHelloInitiator(
                hello: try SessionHelloInitiator.decode(bytes), signature: signature))
        case 2:
            guard let bytes = reader.readData(
                    max: PeerMetadata.maxEncodedSize + SessionHelloResponder.encodedOverhead),
                  let signature = reader.read(count: 64), reader.isAtEnd else {
                throw SessionProtocolError.malformed
            }
            return .helloResponder(SignedSessionHelloResponder(
                hello: try SessionHelloResponder.decode(bytes), signature: signature))
        case 3:
            guard let sidBytes = reader.read(count: 32),
                  let senderBytes = reader.read(count: 32),
                  let receiverBytes = reader.read(count: 32),
                  let signature = reader.read(count: 64), reader.isAtEnd,
                  let sender = try? PeerKey(rawRepresentation: senderBytes),
                  let receiver = try? PeerKey(rawRepresentation: receiverBytes) else {
                throw SessionProtocolError.malformed
            }
            return .finish(SessionFinish(
                sessionID: try SessionID(bytes: sidBytes),
                sender: sender,
                receiver: receiver,
                signature: signature))
        case 4:
            guard let sidBytes = reader.read(count: 32),
                  let sequence = reader.readUInt64(), sequence > 0,
                  let payload = reader.readData(max: Int(clamping: maxPayload)),
                  let signature = reader.read(count: 64), reader.isAtEnd else {
                throw SessionProtocolError.malformed
            }
            return .data(SessionDataRecord(
                sessionID: try SessionID(bytes: sidBytes),
                sequence: sequence,
                payload: payload,
                signature: signature))
        case 5:
            guard let sidBytes = reader.read(count: 32),
                  let sequence = reader.readUInt64(), sequence > 0,
                  let payload = reader.readData(max: Int(clamping: maxPayload)),
                  let mac = reader.read(count: 32), reader.isAtEnd else {
                throw SessionProtocolError.malformed
            }
            return .macData(SessionMACRecord(
                sessionID: try SessionID(bytes: sidBytes),
                sequence: sequence,
                payload: payload,
                mac: mac))
        default:
            throw SessionProtocolError.malformed
        }
    }
}

private enum SessionDomains {
    static let hello = lengthPrefixed("ivy.session.hello.v1")
    static let transcript = lengthPrefixed("ivy.session.transcript.v1")
    static let finish = lengthPrefixed("ivy.session.finish.v1")
    static let data = lengthPrefixed("ivy.session.data.v1")
    static let mac = lengthPrefixed("ivy.session.mac.v1")

    private static func lengthPrefixed(_ string: String) -> Data {
        var bytes = Data()
        _ = bytes.appendSessionData(Data(string.utf8))
        return bytes
    }
}

private extension Data {
    mutating func appendSessionData(_ value: Data) -> Bool {
        guard let count = UInt32(exactly: value.count) else { return false }
        appendUInt32(count)
        append(value)
        return true
    }

    mutating func appendSessionString(_ value: String) -> Bool {
        let bytes = Data(value.utf8)
        guard bytes.count <= Int(MessageLimits.maxStringLength) else { return false }
        return appendSessionData(bytes)
    }
}

private struct SessionReader {
    let data: Data
    var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { remaining == 0 }

    mutating func readUInt8() -> UInt8? {
        guard let bytes = read(count: 1) else { return nil }
        return bytes[bytes.startIndex]
    }

    mutating func readUInt16() -> UInt16? {
        guard let bytes = read(count: 2) else { return nil }
        return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = read(count: 4) else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() -> UInt64? {
        guard let bytes = read(count: 8) else { return nil }
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func read(count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        let start = data.startIndex + offset
        return Data(data[start..<start + count])
    }

    mutating func readData(max: Int) -> Data? {
        guard let count = readUInt32(), count <= UInt32(max) else { return nil }
        return read(count: Int(count))
    }

    mutating func readString() -> String? {
        guard let bytes = readData(max: Int(MessageLimits.maxStringLength)) else { return nil }
        return validUTF8String(bytes)
    }
}
