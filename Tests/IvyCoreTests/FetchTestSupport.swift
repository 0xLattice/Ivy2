import Crypto
import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// A peer played by hand over a raw connection: it authenticates as an
/// ordinary endpoint, then sends whatever messages the test likes and
/// collects what the node sends it. Nothing it does is automatic, so it can
/// be a silent, slow or misbehaving provider, or a requester.
final class FetchRawPeer {
    let sim: Simulation
    let node: Simulation.Node
    let key: PeerKey
    let host: String
    let listen: ListenAddress?
    private let scheme: SimulatedSignatureScheme
    private(set) var connection = ConnectionID(0)
    private(set) var sessionID = Data()
    private var nextSequence: UInt64 = 1
    private var undecoded = Data()
    private var inbox: [Message] = []
    private var attempts: UInt64 = 0
    /// The ID of the Volume request `takeVolumeRequestID` last took.
    private(set) var lastVolumeRequestID: UInt64 = 0

    /// Connects raw peer number `index` to `node`. With `listen`, the peer
    /// advertises that address and so enters the node's routing table.
    init(
        _ sim: Simulation,
        to node: Simulation.Node,
        index: Int,
        advertises listen: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        self.sim = sim
        self.node = node
        self.host = "9.\(index + 1).0.1"
        self.listen = listen ? ListenAddress(host: "9.\(index + 1).0.1", port: 4001) : nil
        let signingKey = sim.signingKey(index: 10_000 + index)
        self.key = try! PeerKey(rawRepresentation: signingKey.publicKey.rawRepresentation)
        self.scheme = SimulatedSignatureScheme(key: key)
        XCTAssertTrue(handshake(), "raw peer did not authenticate", file: file, line: line)
    }

    var peer: PeerID { key.peerID }

    var endpoint: PeerEndpoint {
        PeerEndpoint(publicKey: key.hex, host: host, port: 4001)
    }

    /// The node's view of this peer's current session.
    var authenticated: AuthenticatedPeer {
        node.core.authenticatedPeer(for: peer)!
    }

    private static func frame(_ payload: Data) -> Data {
        var frame = Data()
        let count = UInt32(payload.count)
        frame.append(contentsOf: [
            UInt8(count >> 24), UInt8((count >> 16) & 0xff), UInt8((count >> 8) & 0xff), UInt8(count & 0xff),
        ])
        frame.append(payload)
        return frame
    }

    /// One initiator handshake on a new connection. True when the node now
    /// uses the session it made.
    @discardableResult
    func handshake() -> Bool {
        attempts += 1
        let connection = sim.openRawConnection(to: node, fromHost: host)
        let metadata = PeerMetadata(listenAddresses: listen.map { [$0] } ?? []).encode()!
        let hello = try! SignedSessionHelloInitiator.sign(
            SessionHelloInitiator(
                routeBinding: IvyCore.directRouteBinding,
                initiator: key,
                responder: node.key,
                nonce: Data((0..<4).flatMap { _ in withUnsafeBytes(of: attempts.bigEndian) { Array($0) } }),
                metadata: metadata),
            with: scheme)
        sim.writeRaw(Self.frame(SessionWireRecord.helloInitiator(hello).serialize()), on: connection, to: node)
        let answer = sim.takeRawOutput(connection)
        guard answer.count > 4,
              case .helloResponder(let responder)? = try? SessionWireRecord.deserialize(
                Data(answer.dropFirst(4))),
              let sessionID = try? SessionID(initiator: hello, responder: responder),
              let finish = try? SessionFinish.sign(
                sessionID: sessionID, sender: key, receiver: node.key, with: scheme) else {
            return false
        }
        sim.writeRaw(Self.frame(SessionWireRecord.finish(finish).serialize()), on: connection, to: node)
        // The node holds the session's records until its application has seen it.
        sim.run(for: .zero)
        guard node.core.authenticatedPeer(for: peer)?.sessionID == sessionID.bytes else { return false }
        self.connection = connection
        self.sessionID = sessionID.bytes
        nextSequence = 1
        undecoded = Data()
        inbox = []
        return true
    }

    /// Replaces this peer's session with a new one on a new connection.
    /// Simultaneous sessions converge on the smaller ID, so this retries
    /// until the node prefers the new one.
    func replaceSession(file: StaticString = #filePath, line: UInt = #line) {
        let old = sessionID
        for _ in 0..<4_096 where sessionID == old { handshake() }
        XCTAssertNotEqual(sessionID, old, "the node kept the old session", file: file, line: line)
    }

    func send(_ message: Message, file: StaticString = #filePath, line: UInt = #line) {
        // The codec refuses to encode some malformed messages; those cannot
        // be sent this way.
        XCTAssertFalse(message.serialize().isEmpty, "message does not encode", file: file, line: line)
        sendPayload(message.serialize())
    }

    /// Sends a signed record carrying `payload`, whatever it is.
    func sendPayload(_ payload: Data) {
        let record = try! SessionDataRecord.sign(
            sessionID: try! SessionID(bytes: sessionID),
            sender: key,
            receiver: node.key,
            sequence: nextSequence,
            payload: payload,
            with: scheme)
        nextSequence += 1
        sim.writeRaw(Self.frame(SessionWireRecord.data(record).serialize()), on: connection, to: node)
    }

    func close() {
        sim.closeRaw(connection, at: node)
    }

    private func drain() {
        undecoded.append(sim.takeRawOutput(connection))
        while undecoded.count >= 4 {
            let header = [UInt8](undecoded.prefix(4))
            let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard undecoded.count >= 4 + length else { return }
            let body = Data(undecoded.dropFirst(4).prefix(length))
            undecoded = Data(undecoded.dropFirst(4 + length))
            if case .data(let record)? = try? SessionWireRecord.deserialize(body),
               let message = Message.deserialize(record.payload) {
                inbox.append(message)
            }
        }
    }

    /// Everything the node has sent since the last call.
    func takeMessages() -> [Message] {
        drain()
        defer { inbox = [] }
        return inbox
    }

    private func takeFirst<T>(_ match: (Message) -> T?) -> T? {
        drain()
        for (index, message) in inbox.enumerated() {
            if let value = match(message) {
                inbox.remove(at: index)
                return value
            }
        }
        return nil
    }

    /// The oldest Volume or bundle request the node sent.
    func takeVolumeRequest() -> (requestID: UInt64, rootCID: String, bundle: Bool)? {
        takeFirst {
            switch $0 {
            case let .volumeRequest(requestID, rootCID): return (requestID, rootCID, false)
            case let .volumeBundleRequest(requestID, rootCID): return (requestID, rootCID, true)
            default: return nil
            }
        }
    }

    /// Takes the oldest Volume request and remembers its ID.
    func takeVolumeRequestID() -> UInt64? {
        guard let request = takeVolumeRequest() else { return nil }
        lastVolumeRequestID = request.requestID
        return request.requestID
    }

    func takeProviderQuery() -> (requestID: UInt64, rootCID: String)? {
        takeFirst {
            if case let .findProviders(rootCID, requestID) = $0 { return (requestID, rootCID) }
            return nil
        }
    }

    /// Sends `root`'s Volume: whole, or only the first `prefix` bytes of its
    /// archive as chunk 0 of `count`.
    func sendVolume(
        requestID: UInt64,
        root: String,
        entries: [ContentEntry]? = nil,
        count: UInt16 = 1,
        prefix: Int? = nil
    ) {
        let archive = VolumeArchive.encode(
            entries: entries ?? [ContentEntry(cid: root, data: Data(root.utf8))], rootCID: root)!
        send(.volumeChunk(
            requestID: requestID,
            rootCID: root,
            index: 0,
            count: count,
            totalEntries: UInt16(archive.entries.count),
            totalBytes: UInt64(archive.data.count),
            payload: Data(archive.data.prefix(prefix ?? archive.data.count))))
    }
}

extension Simulation {
    /// A node for fetch tests: every limit the fetch side has, and no local
    /// content source unless asked for, so a fetch goes straight to the wire.
    @discardableResult
    func fetchNode(
        requestTimeout: Duration = .seconds(15),
        maxPendingRequests: Int = 4_096,
        maxWaitersPerRequest: Int = 64,
        maxConcurrentContentRequests: Int = 64,
        maxOutstandingVolumeRequestsPerPeer: Int = 16,
        maxContentCandidates: Int = 8,
        maxInFlightVolumeBytes: Int = IvyConfig.defaultMaxInFlightVolumeBytes,
        kBucketSize: Int = 20,
        mode: IvyMode = .overlay,
        privateContentExchangeEnabled: Bool = false,
        contentSource: Bool = false,
        start: Bool = true
    ) -> Node {
        let node = addNode { key in
            IvyConfig(
                signingKey: key,
                listenPort: 4001,
                kBucketSize: kBucketSize,
                requestTimeout: requestTimeout,
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                maxPendingRequests: maxPendingRequests,
                maxWaitersPerRequest: maxWaitersPerRequest,
                maxConcurrentContentRequests: maxConcurrentContentRequests,
                maxOutstandingVolumeRequestsPerPeer: maxOutstandingVolumeRequestsPerPeer,
                maxContentCandidates: maxContentCandidates,
                maxInFlightVolumeBytes: maxInFlightVolumeBytes,
                privateContentExchangeEnabled: privateContentExchangeEnabled,
                mode: mode)
        }
        if start { self.start(node) }
        send(.command(.setContentSource(contentSource)), to: node)
        return node
    }

    /// Runs everything due now without moving the clock.
    func settleDue() {
        run(for: .zero)
    }
}

extension Simulation.Node {
    var volumeReadsStarted: [String] {
        startedJobs.compactMap {
            if case .readVolume(let rootCID, _) = $0.job { return rootCID }
            return nil
        }
    }

    var authorizationsStarted: Int {
        startedJobs.filter {
            if case .authorizeVolume = $0.job { return true }
            return false
        }.count
    }
}

/// The assertion every Volume scenario ends on: nothing stays reserved.
func assertHoldsNoVolumeBytes(
    _ node: Simulation.Node,
    pending: Int = 0,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, 0, file: file, line: line)
    XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, 0, file: file, line: line)
    XCTAssertEqual(node.core.pendingVolumeRequests.count, pending, file: file, line: line)
}
