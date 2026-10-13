@preconcurrency import Crypto
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Tally

// MARK: - Identifiers

/// A transport connection, named by the shell that owns it.
public struct ConnectionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "conn#\(rawValue)" }
}

/// An outbound dial the core asked for; answered by `connectionOpened` or `dialFailed`.
public struct DialID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "dial#\(rawValue)" }
}

/// An application request, named by the caller; answered by exactly one `completed`.
public struct RequestID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "req#\(rawValue)" }
}

/// Work the core hands to the shell; answered by exactly one `jobFinished`,
/// even after `cancelJob`.
public struct JobID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "job#\(rawValue)" }
}

/// A delivery to the application; the connection's next record is held
/// until the matching `delivered`.
public struct DeliveryToken: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "delivery#\(rawValue)" }
}

// MARK: - Time

/// The instant a step runs at. Both clocks are inputs: the core never reads one.
public struct Timestamp: Sendable, Equatable {
    /// Monotonic time since an arbitrary origin; every deadline is one of these.
    public var uptime: Duration
    /// Wall-clock seconds since the Unix epoch; only provider expiry uses it.
    public var unixSeconds: UInt64

    public init(uptime: Duration, unixSeconds: UInt64) {
        self.uptime = uptime
        self.unixSeconds = unixSeconds
    }
}

public struct ObservedAddress: Sendable, Equatable, Hashable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

// MARK: - Events

public enum ConnectionDirection: Sendable, Equatable {
    case inbound
    case outbound(DialID)
}

public enum Request: Sendable, Equatable {
    case connect(PeerEndpoint)
    /// Connects to the peer over a connection the shell already holds and
    /// has not yet reported, with this node as the initiator. The core
    /// closes the connection unless it becomes the peer's session.
    case connectOver(
        PeerEndpoint,
        ConnectionID,
        observedHost: String?,
        localHost: String?)
    case connectViaRelay(PeerEndpoint)
    case send(to: PeerID, topic: String, payload: Data)
    case sendOnSession(AuthenticatedPeer, topic: String, payload: Data)
    case waitUntilWritable(PeerID)
    case waitUntilSessionWritable(AuthenticatedPeer)
    case fetchVolume(rootCID: String, maximumArchiveBytes: Int, maximumEntries: Int)
    case fetchVolumeFrom(
        AuthenticatedPeer, rootCID: String, maximumArchiveBytes: Int, maximumEntries: Int)
    case fetchVolumeBundle(rootCID: String, from: [AuthenticatedPeer])
    case findNode(target: String)
    case discoverProviders(rootCID: String)
    case recycleSession(AuthenticatedPeer)
    case disconnectSession(AuthenticatedPeer)
}

/// Application input that has no answer.
public enum Command: Sendable, Equatable {
    case disconnect(PeerID)
    case restartConfiguredSession(PeerID)
    case broadcast(topic: String, payload: Data)
    case announceProvider(rootCID: String, expiresAt: UInt64)
    case reportDeficientContent(rootCID: String, servedBy: PeerID)
    /// Whether the shell has a content source to run jobs against.
    case setContentSource(Bool)
    /// Whether a connected peer is known to relay, and so may be asked for a
    /// route. Forgotten when the peer's session ends.
    case setRelaying(PeerID, Bool)
}

public enum JobResult: Sendable, Equatable {
    case entries([ContentEntry])
    case roots([String])
    case authorized(Bool)
}

public enum Event: Sendable, Equatable {
    case start
    case stop
    /// Expires every deadline that has passed.
    case tick

    /// A transport connection exists and is not being read; the core answers
    /// with `resumeReading` or `close`.
    case connectionOpened(
        ConnectionID,
        direction: ConnectionDirection,
        observedHost: String?,
        localHost: String?)
    case dialFailed(DialID)
    case received(ConnectionID, Data)
    /// Every earlier `write` has left the transport's send buffer and there
    /// is room for more. The core counts what it wrote since the last one and
    /// holds further writes past its high-water mark until the next.
    case writable(ConnectionID)
    case closed(ConnectionID)

    case request(RequestID, Request)
    case cancel(RequestID)
    case command(Command)

    case delivered(DeliveryToken)
    case jobFinished(JobID, JobResult)
    case publicAddress(ObservedAddress?)
}

// MARK: - Effects

public enum Job: Sendable, Equatable {
    case readVolume(rootCID: String, maxDataBytes: Int)
    case readVolumeBundle(rootCID: String)
    case authorizeVolume(AuthenticatedPeer, rootCID: String)
}

public enum ConnectOutcome: Sendable, Equatable {
    case connected
    case failed(IvyError)
    case cancelled
}

public enum RequestResult: Sendable, Equatable {
    case connect(ConnectOutcome)
    case send(SendMessageResult)
    case writable(Bool)
    case volume(AttributedVolumeResponse)
    case volumeBundle(AttributedVolumeBundleResponse)
    case endpoints([PeerEndpoint])
    case flag(Bool)
}

public enum Effect: Sendable, Equatable {
    case dial(DialID, PeerEndpoint)
    /// Bytes for the wire, already framed.
    case write(ConnectionID, Data)
    case close(ConnectionID)
    case pauseReading(ConnectionID)
    case resumeReading(ConnectionID)

    case deliver(DeliveryToken, AuthenticatedPeer, PeerMessage)
    case peerConnected(DeliveryToken, AuthenticatedPeer)
    case peerDisconnected(PeerID)
    case publicAddressDiscovered(ObservedAddress)
    case completed(RequestID, RequestResult)

    case startJob(JobID, Job)
    case cancelJob(JobID)
    /// Ask the shell to find this node's public address (STUN).
    case discoverPublicAddress

    /// The earliest deadline; the shell sends `tick` at or after it.
    case wakeAt(Duration)
}

public enum IvyError: Error, Sendable, Equatable {
    case notRunning
    case invalidPeerKey
    case peerOutsideMode
    case connectionInProgress
    case identityVerificationFailed
    case noRelayAvailable
    /// A supplied stream did not report the host its peer was observed at,
    /// which netgroup admission keys on.
    case streamHasNoObservedHost
}

// MARK: - Injected dependencies

/// Signs this node's records and verifies its peers'. Injected so a
/// simulation's signatures, and so its session IDs, repeat exactly.
public protocol IvySignatureScheme: Sendable {
    func signature(for message: Data) throws -> Data
    func isValidSignature(_ signature: Data, for message: Data, publicKey: PeerKey) -> Bool
}

public struct Ed25519Scheme: IvySignatureScheme {
    private let key: Curve25519.Signing.PrivateKey?

    public init(signingKey: Curve25519.Signing.PrivateKey) {
        key = signingKey
    }

    private init() {
        key = nil
    }

    /// Verifies only; signing throws.
    public static let verifier = Ed25519Scheme()

    public func signature(for message: Data) throws -> Data {
        guard let key else { throw SessionProtocolError.malformed }
        return try key.signature(for: message)
    }

    public func isValidSignature(
        _ signature: Data,
        for message: Data,
        publicKey: PeerKey
    ) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(
            rawRepresentation: publicKey.rawRepresentation) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

/// Peer-global traffic evidence. The core records into it and reads only
/// `servingPriority`, when content requests contend for serving slots.
public protocol PeerLedger: Sendable {
    func recordSent(peer: PeerID, bytes: Int)
    func recordReceived(peer: PeerID, bytes: Int)
    func recordProtocolViolation(peer: PeerID)
    func servingPriority(for peer: PeerID) -> Double
}

public struct NullLedger: PeerLedger {
    public init() {}
    public func recordSent(peer: PeerID, bytes: Int) {}
    public func recordReceived(peer: PeerID, bytes: Int) {}
    public func recordProtocolViolation(peer: PeerID) {}
    public func servingPriority(for peer: PeerID) -> Double { 0 }
}

/// The core's only source of randomness: the system generator, or a seeded
/// one whose output repeats.
public struct CoreRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64?

    public static var system: CoreRandom { CoreRandom(state: nil) }

    public static func seeded(_ seed: UInt64) -> CoreRandom {
        CoreRandom(state: seed)
    }

    private init(state: UInt64?) {
        self.state = state
    }

    public mutating func next() -> UInt64 {
        guard var value = state else {
            var system = SystemRandomNumberGenerator()
            return system.next()
        }
        // SplitMix64.
        value &+= 0x9E37_79B9_7F4A_7C15
        state = value
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func bytes32() -> Data {
        Data((0..<32).map { _ in UInt8(truncatingIfNeeded: next()) })
    }

    /// A value in `0..<bound`, drawn the same way whatever the platform's
    /// word size. The standard library's ranged draws go through `Int`,
    /// which is 32 bits on WebAssembly, so a seeded run would differ there.
    mutating func below(_ bound: UInt64) -> UInt64 {
        precondition(bound > 0)
        // Rejection sampling keeps the draw unbiased.
        let limit = UInt64.max - UInt64.max % bound
        var value = next()
        while value >= limit { value = next() }
        return value % bound
    }

    /// Fisher-Yates, on `below`.
    mutating func shuffled<Element>(_ elements: [Element]) -> [Element] {
        var result = elements
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            result.swapAt(index, Int(below(UInt64(index) + 1)))
        }
        return result
    }
}
