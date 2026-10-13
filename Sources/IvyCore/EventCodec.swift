#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Tally

/// `Event` and `Effect` as bytes, for a host that cannot hold the Swift
/// values: JavaScript driving the core as WebAssembly. The format is in
/// docs/event-codec.md. Decoding takes untrusted bytes and answers nil for
/// anything it does not accept; it never traps, whatever the word size.
/// Encoding traps on a string or byte field of 4 GiB or more.
public enum EventCodec {
    /// The first byte of every encoding.
    public static let version: UInt8 = 2

    /// A list of peers, as the core's read-only views return them.
    public static func encoded(peers: [PeerID]) -> Data {
        var writer = CodecWriter()
        writer.list(peers) { $0.string($1.publicKey) }
        return writer.bytes
    }

    public static func decodePeers(_ bytes: Data) -> [PeerID]? {
        decode(bytes) { try $0.list { PeerID(publicKey: try $0.string()) } }
    }

    public static func encoded(endpoints: [PeerEndpoint]) -> Data {
        var writer = CodecWriter()
        writer.list(endpoints) { $0.endpoint($1) }
        return writer.bytes
    }

    public static func decodeEndpoints(_ bytes: Data) -> [PeerEndpoint]? {
        decode(bytes) { try $0.list { try $0.endpoint() } }
    }

    static func decode<Value>(
        _ bytes: Data,
        _ body: (inout CodecReader) throws -> Value
    ) -> Value? {
        var reader = CodecReader(bytes)
        guard (try? reader.uint8()) == version,
              let value = try? body(&reader),
              reader.remaining == 0 else { return nil }
        return value
    }
}

public extension Event {
    func encoded() -> Data {
        var writer = CodecWriter()
        writer.event(self)
        return writer.bytes
    }

    init?(encoded bytes: Data) {
        guard let event = EventCodec.decode(bytes, { try $0.event() }) else { return nil }
        self = event
    }
}

public extension Effect {
    func encoded() -> Data {
        var writer = CodecWriter()
        writer.effect(self)
        return writer.bytes
    }

    init?(encoded bytes: Data) {
        guard let effect = EventCodec.decode(bytes, { try $0.effect() }) else { return nil }
        self = effect
    }

    /// What one step returned, in order.
    static func encoded(_ effects: [Effect]) -> Data {
        var writer = CodecWriter()
        writer.list(effects) { $0.effect($1) }
        return writer.bytes
    }

    static func decodeList(_ bytes: Data) -> [Effect]? {
        EventCodec.decode(bytes) { try $0.list { try $0.effect() } }
    }
}

// MARK: - Writing

struct CodecWriter {
    private(set) var bytes = Data([EventCodec.version])

    mutating func uint8(_ value: UInt8) { bytes.append(value) }
    mutating func uint16(_ value: UInt16) { bytes.appendUInt16(value) }
    mutating func uint32(_ value: UInt32) { bytes.appendUInt32(value) }
    mutating func uint64(_ value: UInt64) { bytes.appendUInt64(value) }
    mutating func int64(_ value: Int64) { bytes.appendUInt64(UInt64(bitPattern: value)) }
    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }

    mutating func data(_ value: Data) {
        uint32(UInt32(value.count))
        bytes.append(value)
    }

    mutating func string(_ value: String) {
        let utf8 = value.utf8
        uint32(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func duration(_ value: Duration) {
        int64(value.components.seconds)
        int64(value.components.attoseconds)
    }

    mutating func optional<Value>(_ value: Value?, _ write: (inout CodecWriter, Value) -> Void) {
        guard let value else { return uint8(0) }
        uint8(1)
        write(&self, value)
    }

    mutating func list<Value>(_ values: [Value], _ write: (inout CodecWriter, Value) -> Void) {
        uint32(UInt32(values.count))
        for value in values { write(&self, value) }
    }

    mutating func endpoint(_ value: PeerEndpoint) {
        string(value.publicKey)
        string(value.host)
        uint16(value.port)
    }

    mutating func address(_ value: ObservedAddress) {
        string(value.host)
        uint16(value.port)
    }

    mutating func route(_ value: AuthenticatedRoute) {
        switch value {
        case .direct:
            uint8(0)
        case let .relayed(carrier, routeID):
            uint8(1)
            bytes.append(carrier.rawRepresentation)
            data(routeID)
        }
    }

    mutating func peer(_ value: AuthenticatedPeer) {
        bytes.append(value.key.rawRepresentation)
        uint8(value.role == .endpoint ? 0 : 1)
        route(value.route)
        list(value.metadata.listenAddresses) {
            $0.string($1.host)
            $0.uint16($1.port)
        }
        uint32(value.metadata.maxFrameSize)
        data(value.sessionID)
    }

    mutating func failure(_ value: VolumeFetchFailure?) {
        optional(value) {
            switch $1 {
            case .callerBoundaryExceeded: $0.uint8(0)
            case .localCapacityUnavailable: $0.uint8(1)
            case .notSent: $0.uint8(2)
            }
        }
    }

    mutating func volume(_ value: AttributedVolumeResponse) {
        string(value.rootCID)
        // A dictionary has no order of its own; the encoding does.
        let entries = value.entries.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        list(entries) {
            $0.string($1.key)
            $0.data($1.value)
        }
        optional(value.servedBy) { $0.string($1.publicKey) }
        failure(value.failure)
    }

    mutating func event(_ value: Event) {
        switch value {
        case .start:
            uint8(0)
        case .stop:
            uint8(1)
        case .tick:
            uint8(2)
        case let .connectionOpened(connection, direction, observedHost, localHost):
            uint8(3)
            uint64(connection.rawValue)
            switch direction {
            case .inbound:
                uint8(0)
            case .outbound(let dial):
                uint8(1)
                uint64(dial.rawValue)
            }
            optional(observedHost) { $0.string($1) }
            optional(localHost) { $0.string($1) }
        case .dialFailed(let dial):
            uint8(4)
            uint64(dial.rawValue)
        case let .received(connection, received):
            uint8(5)
            uint64(connection.rawValue)
            data(received)
        case .writable(let connection):
            uint8(6)
            uint64(connection.rawValue)
        case .closed(let connection):
            uint8(7)
            uint64(connection.rawValue)
        case let .request(id, request):
            uint8(8)
            uint64(id.rawValue)
            self.request(request)
        case .cancel(let id):
            uint8(9)
            uint64(id.rawValue)
        case .command(let command):
            uint8(10)
            self.command(command)
        case .delivered(let token):
            uint8(11)
            uint64(token.rawValue)
        case let .jobFinished(job, result):
            uint8(12)
            uint64(job.rawValue)
            switch result {
            case .entries(let entries):
                uint8(0)
                list(entries) {
                    $0.string($1.cid)
                    $0.data($1.data)
                }
            case .roots(let roots):
                uint8(1)
                list(roots) { $0.string($1) }
            case .authorized(let authorized):
                uint8(2)
                bool(authorized)
            }
        case .publicAddress(let address):
            uint8(13)
            optional(address) { $0.address($1) }
        }
    }

    private mutating func request(_ value: Request) {
        switch value {
        case .connect(let endpoint):
            uint8(0)
            self.endpoint(endpoint)
        case let .connectOver(endpoint, connection, observedHost, localHost):
            uint8(1)
            self.endpoint(endpoint)
            uint64(connection.rawValue)
            optional(observedHost) { $0.string($1) }
            optional(localHost) { $0.string($1) }
        case .connectViaRelay(let endpoint):
            uint8(2)
            self.endpoint(endpoint)
        case let .send(peer, topic, payload):
            uint8(3)
            string(peer.publicKey)
            string(topic)
            data(payload)
        case let .sendOnSession(peer, topic, payload):
            uint8(4)
            self.peer(peer)
            string(topic)
            data(payload)
        case .waitUntilWritable(let peer):
            uint8(5)
            string(peer.publicKey)
        case .waitUntilSessionWritable(let peer):
            uint8(6)
            self.peer(peer)
        case let .fetchVolume(rootCID, maximumArchiveBytes, maximumEntries):
            uint8(7)
            string(rootCID)
            int64(Int64(maximumArchiveBytes))
            int64(Int64(maximumEntries))
        case let .fetchVolumeFrom(peer, rootCID, maximumArchiveBytes, maximumEntries):
            uint8(8)
            self.peer(peer)
            string(rootCID)
            int64(Int64(maximumArchiveBytes))
            int64(Int64(maximumEntries))
        case let .fetchVolumeBundle(rootCID, peers):
            uint8(9)
            string(rootCID)
            list(peers) { $0.peer($1) }
        case .findNode(let target):
            uint8(10)
            string(target)
        case .discoverProviders(let rootCID):
            uint8(11)
            string(rootCID)
        case .recycleSession(let peer):
            uint8(12)
            self.peer(peer)
        case .disconnectSession(let peer):
            uint8(13)
            self.peer(peer)
        }
    }

    private mutating func command(_ value: Command) {
        switch value {
        case .disconnect(let peer):
            uint8(0)
            string(peer.publicKey)
        case .restartConfiguredSession(let peer):
            uint8(1)
            string(peer.publicKey)
        case let .broadcast(topic, payload):
            uint8(2)
            string(topic)
            data(payload)
        case let .announceProvider(rootCID, expiresAt):
            uint8(3)
            string(rootCID)
            uint64(expiresAt)
        case let .reportDeficientContent(rootCID, peer):
            uint8(4)
            string(rootCID)
            string(peer.publicKey)
        case .setContentSource(let present):
            uint8(5)
            bool(present)
        case let .setRelaying(peer, relays):
            uint8(6)
            string(peer.publicKey)
            bool(relays)
        }
    }

    mutating func effect(_ value: Effect) {
        switch value {
        case let .dial(dial, endpoint):
            uint8(0)
            uint64(dial.rawValue)
            self.endpoint(endpoint)
        case let .write(connection, written):
            uint8(1)
            uint64(connection.rawValue)
            data(written)
        case .close(let connection):
            uint8(2)
            uint64(connection.rawValue)
        case .pauseReading(let connection):
            uint8(3)
            uint64(connection.rawValue)
        case .resumeReading(let connection):
            uint8(4)
            uint64(connection.rawValue)
        case let .deliver(token, peer, message):
            uint8(5)
            uint64(token.rawValue)
            self.peer(peer)
            string(message.topic)
            data(message.payload)
        case let .peerConnected(token, peer):
            uint8(6)
            uint64(token.rawValue)
            self.peer(peer)
        case .peerDisconnected(let peer):
            uint8(7)
            string(peer.publicKey)
        case .publicAddressDiscovered(let address):
            uint8(8)
            self.address(address)
        case let .completed(request, result):
            uint8(9)
            uint64(request.rawValue)
            self.result(result)
        case let .startJob(id, job):
            uint8(10)
            uint64(id.rawValue)
            switch job {
            case let .readVolume(rootCID, maxDataBytes):
                uint8(0)
                string(rootCID)
                int64(Int64(maxDataBytes))
            case .readVolumeBundle(let rootCID):
                uint8(1)
                string(rootCID)
            case let .authorizeVolume(peer, rootCID):
                uint8(2)
                self.peer(peer)
                string(rootCID)
            }
        case .cancelJob(let id):
            uint8(11)
            uint64(id.rawValue)
        case .discoverPublicAddress:
            uint8(12)
        case .wakeAt(let deadline):
            uint8(13)
            duration(deadline)
        }
    }

    private mutating func result(_ value: RequestResult) {
        switch value {
        case .connect(let outcome):
            uint8(0)
            switch outcome {
            case .connected:
                uint8(0)
            case .failed(let error):
                uint8(1)
                switch error {
                case .notRunning: uint8(0)
                case .invalidPeerKey: uint8(1)
                case .peerOutsideMode: uint8(2)
                case .connectionInProgress: uint8(3)
                case .identityVerificationFailed: uint8(4)
                case .noRelayAvailable: uint8(5)
                case .streamHasNoObservedHost: uint8(6)
                }
            case .cancelled:
                uint8(2)
            }
        case .send(let sent):
            uint8(1)
            switch sent {
            case let .enqueued(endpoint, route):
                uint8(0)
                string(endpoint.publicKey)
                self.route(route)
            case .backpressured:
                uint8(1)
            case .notConnected:
                uint8(2)
            case .locallyRejected:
                uint8(3)
            }
        case .writable(let writable):
            uint8(2)
            bool(writable)
        case .volume(let response):
            uint8(3)
            volume(response)
        case .volumeBundle(let response):
            uint8(4)
            list(response.volumes) { $0.volume($1) }
            bool(response.noBundle)
            bool(response.ended)
            failure(response.failure)
        case .endpoints(let endpoints):
            uint8(5)
            list(endpoints) { $0.endpoint($1) }
        case .flag(let flag):
            uint8(6)
            bool(flag)
        }
    }
}

// MARK: - Reading

struct CodecReader {
    struct Malformed: Error {}

    private let bytes: Data
    private var offset = 0

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    /// A length or count is a `UInt32` and `Int` may be 32 bits, so it is
    /// compared with what is left before it becomes one.
    private mutating func take(_ count: UInt32) throws -> Data {
        guard UInt64(count) <= UInt64(remaining) else { throw Malformed() }
        let start = bytes.startIndex + offset
        offset += Int(count)
        return bytes[start..<start + Int(count)]
    }

    private mutating func integer<Value: FixedWidthInteger>(_: Value.Type) throws -> Value {
        try take(UInt32(Value.bitWidth / 8)).reduce(0) { $0 << 8 | Value($1) }
    }

    mutating func uint8() throws -> UInt8 { try integer(UInt8.self) }
    mutating func uint16() throws -> UInt16 { try integer(UInt16.self) }
    mutating func uint32() throws -> UInt32 { try integer(UInt32.self) }
    mutating func uint64() throws -> UInt64 { try integer(UInt64.self) }
    mutating func int64() throws -> Int64 { Int64(bitPattern: try uint64()) }

    /// A size the core holds as an `Int`: clamped where `Int` is narrower.
    mutating func size() throws -> Int { Int(clamping: try int64()) }

    mutating func bool() throws -> Bool {
        switch try uint8() {
        case 0: return false
        case 1: return true
        default: throw Malformed()
        }
    }

    mutating func data() throws -> Data {
        Data(try take(try uint32()))
    }

    mutating func string() throws -> String {
        let utf8 = try take(try uint32())
        let string = String(decoding: utf8, as: UTF8.self)
        // Decoding repairs invalid UTF-8; a repaired string spells other bytes.
        guard string.utf8.elementsEqual(utf8) else { throw Malformed() }
        return string
    }

    mutating func duration() throws -> Duration {
        let seconds = try int64()
        let attoseconds = try int64()
        let duration = Duration(secondsComponent: seconds, attosecondsComponent: attoseconds)
        // One duration has one encoding: the components it reports.
        guard duration.components == (seconds, attoseconds) else { throw Malformed() }
        return duration
    }

    mutating func optional<Value>(_ read: (inout CodecReader) throws -> Value) throws -> Value? {
        try bool() ? try read(&self) : nil
    }

    mutating func list<Value>(_ read: (inout CodecReader) throws -> Value) throws -> [Value] {
        let count = try uint32()
        // Every element is at least a byte, so a count beyond what is left
        // is refused before anything is allocated for it.
        guard UInt64(count) <= UInt64(remaining) else { throw Malformed() }
        var values: [Value] = []
        for _ in 0..<count { values.append(try read(&self)) }
        return values
    }

    mutating func endpoint() throws -> PeerEndpoint {
        PeerEndpoint(publicKey: try string(), host: try string(), port: try uint16())
    }

    mutating func address() throws -> ObservedAddress {
        ObservedAddress(host: try string(), port: try uint16())
    }

    mutating func fixed(_ count: UInt32) throws -> Data {
        Data(try take(count))
    }

    private mutating func key() throws -> PeerKey {
        try PeerKey(rawRepresentation: try fixed(UInt32(PeerKey.byteCount)))
    }

    private mutating func route() throws -> AuthenticatedRoute {
        switch try uint8() {
        case 0: return .direct
        case 1: return .relayed(carrier: try key(), routeID: try data())
        default: throw Malformed()
        }
    }

    private mutating func peer() throws -> AuthenticatedPeer {
        let key = try key()
        let role: AuthenticatedPeerRole
        switch try uint8() {
        case 0: role = .endpoint
        case 1: role = .carrier
        default: throw Malformed()
        }
        let route = try route()
        let addresses = try list { ListenAddress(host: try $0.string(), port: try $0.uint16()) }
        let metadata = PeerMetadata(listenAddresses: addresses, maxFrameSize: try uint32())
        // `PeerMetadata` sorts its addresses and drops repeats; anything it
        // would change is not an encoding of one.
        guard metadata.listenAddresses == addresses else { throw Malformed() }
        return AuthenticatedPeer(
            key: key, role: role, route: route, metadata: metadata, sessionID: try data())
    }

    private mutating func failure() throws -> VolumeFetchFailure? {
        try optional {
            switch try $0.uint8() {
            case 0: return .callerBoundaryExceeded
            case 1: return .localCapacityUnavailable
            case 2: return .notSent
            default: throw Malformed()
            }
        }
    }

    private mutating func volume() throws -> AttributedVolumeResponse {
        let rootCID = try string()
        var entries: [String: Data] = [:]
        var previous: String?
        for entry in try list({ (cid: try $0.string(), data: try $0.data()) }) {
            // Strictly ascending, and distinct as Swift compares strings.
            guard previous.map({ $0.utf8.lexicographicallyPrecedes(entry.cid.utf8) }) ?? true,
                  entries.updateValue(entry.data, forKey: entry.cid) == nil else {
                throw Malformed()
            }
            previous = entry.cid
        }
        return AttributedVolumeResponse(
            rootCID: rootCID,
            entries: entries,
            servedBy: try optional { PeerID(publicKey: try $0.string()) },
            failure: try failure())
    }

    mutating func event() throws -> Event {
        switch try uint8() {
        case 0:
            return .start
        case 1:
            return .stop
        case 2:
            return .tick
        case 3:
            let connection = ConnectionID(try uint64())
            let direction: ConnectionDirection
            switch try uint8() {
            case 0: direction = .inbound
            case 1: direction = .outbound(DialID(try uint64()))
            default: throw Malformed()
            }
            return .connectionOpened(
                connection,
                direction: direction,
                observedHost: try optional { try $0.string() },
                localHost: try optional { try $0.string() })
        case 4:
            return .dialFailed(DialID(try uint64()))
        case 5:
            return .received(ConnectionID(try uint64()), try data())
        case 6:
            return .writable(ConnectionID(try uint64()))
        case 7:
            return .closed(ConnectionID(try uint64()))
        case 8:
            return .request(RequestID(try uint64()), try request())
        case 9:
            return .cancel(RequestID(try uint64()))
        case 10:
            return .command(try command())
        case 11:
            return .delivered(DeliveryToken(try uint64()))
        case 12:
            let job = JobID(try uint64())
            switch try uint8() {
            case 0:
                return .jobFinished(job, .entries(try list {
                    ContentEntry(cid: try $0.string(), data: try $0.data())
                }))
            case 1:
                return .jobFinished(job, .roots(try list { try $0.string() }))
            case 2:
                return .jobFinished(job, .authorized(try bool()))
            default:
                throw Malformed()
            }
        case 13:
            return .publicAddress(try optional { try $0.address() })
        default:
            throw Malformed()
        }
    }

    private mutating func request() throws -> Request {
        switch try uint8() {
        case 0:
            return .connect(try endpoint())
        case 1:
            return .connectOver(
                try endpoint(),
                ConnectionID(try uint64()),
                observedHost: try optional { try $0.string() },
                localHost: try optional { try $0.string() })
        case 2:
            return .connectViaRelay(try endpoint())
        case 3:
            return .send(
                to: PeerID(publicKey: try string()), topic: try string(), payload: try data())
        case 4:
            return .sendOnSession(try peer(), topic: try string(), payload: try data())
        case 5:
            return .waitUntilWritable(PeerID(publicKey: try string()))
        case 6:
            return .waitUntilSessionWritable(try peer())
        case 7:
            return .fetchVolume(
                rootCID: try string(), maximumArchiveBytes: try size(), maximumEntries: try size())
        case 8:
            return .fetchVolumeFrom(
                try peer(),
                rootCID: try string(),
                maximumArchiveBytes: try size(),
                maximumEntries: try size())
        case 9:
            return .fetchVolumeBundle(rootCID: try string(), from: try list { try $0.peer() })
        case 10:
            return .findNode(target: try string())
        case 11:
            return .discoverProviders(rootCID: try string())
        case 12:
            return .recycleSession(try peer())
        case 13:
            return .disconnectSession(try peer())
        default:
            throw Malformed()
        }
    }

    private mutating func command() throws -> Command {
        switch try uint8() {
        case 0:
            return .disconnect(PeerID(publicKey: try string()))
        case 1:
            return .restartConfiguredSession(PeerID(publicKey: try string()))
        case 2:
            return .broadcast(topic: try string(), payload: try data())
        case 3:
            return .announceProvider(rootCID: try string(), expiresAt: try uint64())
        case 4:
            return .reportDeficientContent(
                rootCID: try string(), servedBy: PeerID(publicKey: try string()))
        case 5:
            return .setContentSource(try bool())
        case 6:
            return .setRelaying(PeerID(publicKey: try string()), try bool())
        default:
            throw Malformed()
        }
    }

    mutating func effect() throws -> Effect {
        switch try uint8() {
        case 0:
            return .dial(DialID(try uint64()), try endpoint())
        case 1:
            return .write(ConnectionID(try uint64()), try data())
        case 2:
            return .close(ConnectionID(try uint64()))
        case 3:
            return .pauseReading(ConnectionID(try uint64()))
        case 4:
            return .resumeReading(ConnectionID(try uint64()))
        case 5:
            return .deliver(
                DeliveryToken(try uint64()),
                try peer(),
                PeerMessage(topic: try string(), payload: try data()))
        case 6:
            return .peerConnected(DeliveryToken(try uint64()), try peer())
        case 7:
            return .peerDisconnected(PeerID(publicKey: try string()))
        case 8:
            return .publicAddressDiscovered(try address())
        case 9:
            return .completed(RequestID(try uint64()), try result())
        case 10:
            let id = JobID(try uint64())
            switch try uint8() {
            case 0:
                return .startJob(id, .readVolume(rootCID: try string(), maxDataBytes: try size()))
            case 1:
                return .startJob(id, .readVolumeBundle(rootCID: try string()))
            case 2:
                return .startJob(id, .authorizeVolume(try peer(), rootCID: try string()))
            default:
                throw Malformed()
            }
        case 11:
            return .cancelJob(JobID(try uint64()))
        case 12:
            return .discoverPublicAddress
        case 13:
            return .wakeAt(try duration())
        default:
            throw Malformed()
        }
    }

    private mutating func result() throws -> RequestResult {
        switch try uint8() {
        case 0:
            switch try uint8() {
            case 0:
                return .connect(.connected)
            case 1:
                let errors: [IvyError] = [
                    .notRunning, .invalidPeerKey, .peerOutsideMode, .connectionInProgress,
                    .identityVerificationFailed, .noRelayAvailable, .streamHasNoObservedHost,
                ]
                let index = Int(try uint8())
                guard index < errors.count else { throw Malformed() }
                return .connect(.failed(errors[index]))
            case 2:
                return .connect(.cancelled)
            default:
                throw Malformed()
            }
        case 1:
            switch try uint8() {
            case 0:
                return .send(.enqueued(
                    endpoint: PeerID(publicKey: try string()), route: try route()))
            case 1:
                return .send(.backpressured)
            case 2:
                return .send(.notConnected)
            case 3:
                return .send(.locallyRejected)
            default:
                throw Malformed()
            }
        case 2:
            return .writable(try bool())
        case 3:
            return .volume(try volume())
        case 4:
            return .volumeBundle(AttributedVolumeBundleResponse(
                volumes: try list { try $0.volume() },
                noBundle: try bool(),
                ended: try bool(),
                failure: try failure()))
        case 5:
            return .endpoints(try list { try $0.endpoint() })
        case 6:
            return .flag(try bool())
        default:
            throw Malformed()
        }
    }
}
