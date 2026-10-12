import Crypto
import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// A requesting peer played by the test over a raw connection: it runs the
/// handshake by hand, sends whatever requests it likes with the request IDs
/// it likes, and can stop taking bytes.
final class ServingRawPeer {
    struct Chunk: Equatable {
        let requestID: UInt64
        let rootCID: String
        let index: Int
        let count: Int
        let totalEntries: Int
        let totalBytes: Int
        let payload: Data
    }

    let sim: Simulation
    let server: Simulation.Node
    let key: PeerKey
    let connection: ConnectionID
    private let scheme: SimulatedSignatureScheme
    private var sessionID: SessionID?
    private var sequence: UInt64 = 0
    private var unparsed = Data()
    /// The size of every frame body the server wrote, the handshake's included.
    private(set) var frameSizes: [Int] = []
    /// Every message the server sent on the session, in order.
    private(set) var inbox: [Message] = []

    var peer: PeerID { key.peerID }

    /// `index` names the identity: two peers with one index are one peer
    /// connecting twice.
    init(
        _ sim: Simulation,
        to server: Simulation.Node,
        index: Int,
        maxFrameSize: UInt32 = IvyConfig.defaultProtocolMaxFrameSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        self.sim = sim
        self.server = server
        let signingKey = sim.signingKey(index: 10_000 + index)
        key = try! PeerKey(rawRepresentation: signingKey.publicKey.rawRepresentation)
        scheme = SimulatedSignatureScheme(key: key)
        connection = sim.openRawConnection(to: server, fromHost: "20.\(index % 250 + 1).0.1")

        let hello = SessionHelloInitiator(
            routeBinding: IvyCore.directRouteBinding,
            initiator: key,
            responder: server.key,
            nonce: Data(repeating: UInt8(truncatingIfNeeded: index), count: 32),
            metadata: PeerMetadata(maxFrameSize: maxFrameSize).encode()!)
        let signed = try! SignedSessionHelloInitiator.sign(hello, with: scheme)
        write(SessionWireRecord.helloInitiator(signed).serialize())
        var responder: SignedSessionHelloResponder?
        for record in takeRecords() {
            if case .helloResponder(let answer) = record { responder = answer }
        }
        guard let responder, let sessionID = try? SessionID(initiator: signed, responder: responder) else {
            XCTFail("the server did not answer the hello", file: file, line: line)
            return
        }
        self.sessionID = sessionID
        let finish = try! SessionFinish.sign(
            sessionID: sessionID, sender: key, receiver: server.key, with: scheme)
        write(SessionWireRecord.finish(finish).serialize())
        // The application sees the session, and the handshake's bytes flush.
        sim.run(for: .milliseconds(20))
        XCTAssertTrue(server.core.connectedPeers.contains(peer), file: file, line: line)
    }

    private func write(_ record: Data) {
        var frame = Data()
        withUnsafeBytes(of: UInt32(record.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(record)
        sim.writeRaw(frame, on: connection, to: server)
    }

    func send(_ message: Message) {
        guard let sessionID else { return }
        let payload = message.serialize()
        precondition(!payload.isEmpty, "the message does not encode")
        sequence += 1
        let record = try! SessionDataRecord.sign(
            sessionID: sessionID,
            sender: key,
            receiver: server.key,
            sequence: sequence,
            payload: payload,
            with: scheme)
        write(SessionWireRecord.data(record).serialize())
    }

    private func takeRecords() -> [SessionWireRecord] {
        unparsed.append(sim.takeRawOutput(connection))
        var records: [SessionWireRecord] = []
        while unparsed.count >= 4 {
            let length = unparsed.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard unparsed.count >= 4 + length else { break }
            let body = Data(unparsed.dropFirst(4).prefix(length))
            unparsed = Data(unparsed.dropFirst(4 + length))
            frameSizes.append(length)
            if let record = try? SessionWireRecord.deserialize(body) { records.append(record) }
        }
        return records
    }

    /// Reads what the server has written so far into `inbox`.
    @discardableResult
    func read() -> [Message] {
        var new: [Message] = []
        for record in takeRecords() {
            guard case .data(let data) = record,
                  let message = Message.deserialize(data.payload) else { continue }
            new.append(message)
        }
        inbox.append(contentsOf: new)
        return new
    }

    var chunks: [Chunk] {
        inbox.compactMap {
            guard case let .volumeChunk(requestID, rootCID, index, count, totalEntries, totalBytes, payload) = $0 else {
                return nil
            }
            return Chunk(
                requestID: requestID,
                rootCID: rootCID,
                index: Int(index),
                count: Int(count),
                totalEntries: Int(totalEntries),
                totalBytes: Int(totalBytes),
                payload: payload)
        }
    }

    var unavailable: [UInt64] {
        inbox.compactMap {
            if case .contentUnavailable(let requestID) = $0 { return requestID }
            return nil
        }
    }

    var bundleEnds: [UInt64] {
        inbox.compactMap {
            if case .volumeBundleEnd(let requestID) = $0 { return requestID }
            return nil
        }
    }

    /// The order in which answers to requests arrived: one entry per request,
    /// at its first record.
    var answeredRequestIDs: [UInt64] {
        var seen = Set<UInt64>()
        var order: [UInt64] = []
        for message in inbox {
            let id: UInt64
            switch message {
            case .volumeChunk(let requestID, _, _, _, _, _, _): id = requestID
            case .contentUnavailable(let requestID): id = requestID
            case .volumeBundleEnd(let requestID): id = requestID
            default: continue
            }
            if seen.insert(id).inserted { order.append(id) }
        }
        return order
    }

    /// The archive the chunks of one request carry for `rootCID`, if they
    /// are complete and in order.
    func archive(requestID: UInt64, rootCID: String) -> Data? {
        let parts = chunks.filter { $0.requestID == requestID && $0.rootCID == rootCID }
        guard let first = parts.first, parts.count == first.count,
              parts.map(\.index) == Array(0..<first.count) else { return nil }
        let data = parts.reduce(into: Data()) { $0.append($1.payload) }
        return data.count == first.totalBytes ? data : nil
    }

    /// The server stops hearing `writable` from this peer, and then fills
    /// its send buffer past the high-water mark: every later record waits.
    func stopReading(file: StaticString = #filePath, line: UInt = #line) {
        sim.setRawStalled(true, connection, at: server)
        let filler = Data(repeating: 0x5a, count: IvyCore.writeHighWaterMark + 1)
        let sent = sim.await(.send(to: peer, topic: "fill", payload: filler), on: server)
        XCTAssertEqual(sent?.sent, .enqueued(endpoint: peer, route: .direct), file: file, line: line)
        read()
    }

    func resumeReading() {
        sim.setRawStalled(false, connection, at: server)
    }

    func close() {
        sim.closeRaw(connection, at: server)
    }
}

extension Simulation.Node {
    var volumeAuthorizations: [String] {
        startedJobs.compactMap {
            if case .authorizeVolume(_, let rootCID) = $0.job { return rootCID }
            return nil
        }
    }

    /// The peers whose Volume requests reached authorization, in order:
    /// the order in which requests were given a serving slot.
    var volumeAuthorizationPeers: [PeerID] {
        startedJobs.compactMap {
            if case .authorizeVolume(let peer, _) = $0.job { return peer.id }
            return nil
        }
    }

    var volumeReads: [String] {
        startedJobs.compactMap {
            if case .readVolume(let rootCID, _) = $0.job { return rootCID }
            return nil
        }
    }

    var bundleListings: [String] {
        startedJobs.compactMap {
            if case .readVolumeBundle(let rootCID) = $0.job { return rootCID }
            return nil
        }
    }

    /// The jobs storage is holding, oldest first.
    var servingStalledJobs: [(id: JobID, job: Job)] {
        stalledJobs.map { ($0.0, $0.1) }
    }

    /// What this node's store answers a job with.
    func servingAnswer(_ job: Job) -> JobResult {
        switch job {
        case .readVolume(let rootCID, _):
            return .entries(volumes[rootCID] ?? [])
        case .readVolumeBundle(let rootCID):
            return .roots(bundles[rootCID] ?? [])
        case .authorizeVolume(let peer, let rootCID):
            return .authorized(authorize(peer, rootCID))
        }
    }
}

func servingJobIsRead(_ job: Job) -> Bool {
    switch job {
    case .readVolume: return true
    case .readVolumeBundle, .authorizeVolume: return false
    }
}

extension Simulation {
    /// Answers the jobs `node`'s storage is holding that `matches` picks,
    /// oldest first, and leaves the rest held. `limit` stops after that many.
    @discardableResult
    func answerStalledJobs(
        _ node: Node,
        limit: Int = .max,
        where matches: (Job) -> Bool = { _ in true }
    ) -> Int {
        var answered: [(JobID, Job)] = []
        var kept: [(JobID, Job)] = []
        for entry in node.stalledJobs {
            if answered.count < limit, matches(entry.1) {
                answered.append(entry)
            } else {
                kept.append(entry)
            }
        }
        node.stalledJobs = kept
        for (id, job) in answered { send(.jobFinished(id, node.servingAnswer(job)), to: node) }
        return answered.count
    }

    /// Runs with `node`'s reads held and every other job answered: a
    /// content source whose reads block until released.
    func runHoldingReads(_ node: Node, for duration: Duration = .milliseconds(60)) {
        node.stallsStorage = true
        let end = now + duration
        while true {
            while answerStalledJobs(node, where: { !servingJobIsRead($0) }) > 0 {}
            guard now < end else { return }
            run(for: .milliseconds(10))
        }
    }

    /// Lets the oldest held read finish, and holds the reads that follow.
    func releaseNextRead(_ node: Node, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            answerStalledJobs(node, limit: 1, where: servingJobIsRead), 1,
            "no read was held", file: file, line: line)
        runHoldingReads(node)
    }

    func fetchVolume(_ root: String, from server: Node, on client: Node) -> RequestID {
        request(
            .fetchVolumeFrom(
                session(client, to: server),
                rootCID: root, maximumArchiveBytes: .max, maximumEntries: .max),
            on: client)
    }

    func volume(_ request: RequestID, on node: Node) -> AttributedVolumeResponse? {
        result(of: request, on: node)?.volume
    }
}

/// A two-member Volume named by its root.
func servingSmallVolume(_ root: String) -> [ContentEntry] {
    [
        ContentEntry(cid: root, data: Data("\(root) bytes".utf8)),
        ContentEntry(cid: "\(root)-child", data: Data("\(root) child".utf8)),
    ]
}

func servingExpectedVolume(_ root: String, servedBy peer: PeerID) -> AttributedVolumeResponse {
    AttributedVolumeResponse(
        rootCID: root,
        entries: Dictionary(uniqueKeysWithValues: servingSmallVolume(root).map { ($0.cid, $0.data) }),
        servedBy: peer)
}

/// Nothing is held for serving: no slot, no reservation, no waiter, no job.
func XCTAssertServingIdle(
    _ node: Simulation.Node,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let diagnostics = node.core.diagnostics
    XCTAssertEqual(diagnostics.reservedServingVolumeBytes, 0, "reserved bytes", file: file, line: line)
    XCTAssertEqual(diagnostics.servingSlotsHeld, 0, "slots held", file: file, line: line)
    XCTAssertEqual(diagnostics.servingRequestsWaiting, 0, "requests waiting", file: file, line: line)
    XCTAssertEqual(diagnostics.servingVolumeReadsWaiting, 0, "reads waiting", file: file, line: line)
    XCTAssertEqual(diagnostics.jobsOutstanding, 0, "jobs outstanding", file: file, line: line)
    XCTAssertTrue(node.core.serving.isEmpty, "requests being served", file: file, line: line)
    XCTAssertTrue(node.core.waitingServingPeers.isEmpty, "waiting peers", file: file, line: line)
}
