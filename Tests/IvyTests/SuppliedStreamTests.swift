import Crypto
import Foundation
import XCTest
@testable import Ivy
import Tally

/// Ivy over streams it did not establish: the path a WebRTC data channel or
/// any other transport takes. No socket carries these sessions.
final class SuppliedStreamTests: XCTestCase {
    private func makeNode(maxConnectionsPerNetgroup: Int = 16) -> Ivy {
        Ivy(config: IvyConfig(
            signingKey: Curve25519.Signing.PrivateKey(),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            maxConnectionsPerNetgroup: maxConnectionsPerNetgroup))
    }

    private func endpoint(_ node: Ivy, host: String) -> PeerEndpoint {
        PeerEndpoint(publicKey: node.config.publicKey, host: host, port: 4001)
    }

    private func eventually(
        timeout: Duration = .seconds(10),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    /// Joins `a` (initiator) and `b` (responder) over an in-memory pair.
    private func join(_ a: Ivy, _ b: Ivy) async throws -> (MemoryStream, MemoryStream) {
        let (left, right) = MemoryStream.pair(leftHost: "8.8.1.1", rightHost: "8.8.2.1")
        let lease = try XCTUnwrap(b.reserveInboundAdmission(observedHost: right.observedHost))
        b.accept(right, admission: lease)
        try await a.connect(to: endpoint(b, host: "8.8.2.1"), over: left)
        return (left, right)
    }

    func testSessionMessagesAndAVolumeOverSuppliedStreams() async throws {
        let a = makeNode()
        let b = makeNode()
        let recorder = StreamRecorder()
        await b.use(recorder)
        let entries = [ContentEntry(cid: "vol", data: Data(repeating: 1, count: 512))]
            + (0..<12).map { ContentEntry(cid: "vol-\($0)", data: Data(repeating: UInt8($0), count: 1024 * 1024)) }
        await b.setContentSource(StreamStore(volumes: ["vol": entries]))
        try await a.start()
        try await b.start()
        let (left, right) = try await join(a, b)

        let connected = await eventually { await b.connectedPeers == [a.localID] }
        XCTAssertTrue(connected)
        let peers = await a.connectedPeers
        XCTAssertEqual(peers, [b.localID])
        // A supplied stream's address is not one Ivy can dial.
        let known = await a.knownPeerEndpoints
        XCTAssertEqual(known, [])

        let sent = await a.sendMessage(to: b.localID, topic: "t", payload: Data("over a stream".utf8))
        XCTAssertEqual(sent, .enqueued(endpoint: b.localID, route: .direct))
        let delivered = await eventually { await recorder.messages.count == 1 }
        XCTAssertTrue(delivered)

        // Twelve megabytes through a stream that reports itself full past
        // 256 KiB: the chunk cursor has to wait for it and resume.
        let volume = await a.fetchVolume(rootCID: "vol")
        XCTAssertEqual(volume.entries.count, entries.count)
        XCTAssertEqual(volume.entries["vol-11"], entries[12].data)
        XCTAssertEqual(volume.servedBy, b.localID)
        XCTAssertGreaterThan(right.timesSaturated, 0, "the serving side must have been held back")

        await a.disconnect(b.localID)
        let closed = await eventually { left.isClosed && right.isClosed }
        XCTAssertTrue(closed)
        await a.stop()
        await b.stop()
    }

    func testBytesAreRequestedOnlyWhileTheApplicationKeepsUp() async throws {
        let a = makeNode()
        let b = makeNode()
        let gate = StreamGate()
        let recorder = StreamRecorder(gate: gate)
        await b.use(recorder)
        try await a.start()
        try await b.start()
        let (_, right) = try await join(a, b)

        for index in 0..<40 {
            // Past the write high-water mark a send is refused until the
            // stream reports room, as on any transport.
            while await a.sendMessage(
                to: b.localID, topic: "t\(index)", payload: Data(repeating: 1, count: 2_000)
            ) == .backpressured {
                _ = await a.waitUntilWritable(to: b.localID)
            }
        }
        let parked = await eventually { await recorder.entered == 1 }
        XCTAssertTrue(parked)
        try? await Task.sleep(nanoseconds: 100_000_000)
        // The delegate holds one record: nothing more is asked of the stream.
        let requestsWhileHeld = right.requestCount
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(right.requestCount, requestsWhileHeld)
        XCTAssertGreaterThan(right.unreadBytes, 0)
        let seen = await recorder.messages.count
        XCTAssertEqual(seen, 0)

        await gate.open()
        let drained = await eventually { await recorder.messages.count == 40 }
        XCTAssertTrue(drained)
        let topics = await recorder.messages.map(\.topic)
        XCTAssertEqual(topics, (0..<40).map { "t\($0)" })
        await a.stop()
        await b.stop()
    }

    func testAdmissionNeedsARunningNodeAndAnObservedHost() async throws {
        let node = makeNode()
        XCTAssertNil(node.reserveInboundAdmission(observedHost: "8.8.1.1"), "not started")
        try await node.start()
        XCTAssertNil(node.reserveInboundAdmission(observedHost: nil))
        XCTAssertNil(node.reserveInboundAdmission(observedHost: ""))
        XCTAssertNotNil(node.reserveInboundAdmission(observedHost: "8.8.1.1"))
        await node.stop()
        XCTAssertNil(node.reserveInboundAdmission(observedHost: "8.8.1.1"), "stopped")
    }

    func testALeaseAdmitsOneStreamOfItsOwnNetgroup() async throws {
        let node = makeNode()
        try await node.start()

        let lease = try XCTUnwrap(node.reserveInboundAdmission(observedHost: "8.8.1.1"))
        // This stream reports its peer at 9.9.1.1: not the netgroup reserved.
        let other = MemoryStream.pair(leftHost: "9.9.1.1", rightHost: "8.8.2.1").1
        node.accept(other, admission: lease)
        let refused = await eventually { other.isClosed }
        XCTAssertTrue(refused, "a stream of another netgroup is refused")

        let lease2 = try XCTUnwrap(node.reserveInboundAdmission(observedHost: "8.8.1.1"))
        let first = MemoryStream.pair(leftHost: "8.8.1.1", rightHost: "8.8.2.1").1
        let second = MemoryStream.pair(leftHost: "8.8.1.1", rightHost: "8.8.2.1").1
        node.accept(first, admission: lease2)
        node.accept(second, admission: lease2)
        let secondRefused = await eventually { second.isClosed }
        XCTAssertTrue(secondRefused, "a lease admits one stream")
        XCTAssertFalse(first.isClosed)
        await node.stop()
    }

    func testAHostlessStreamIsRefused() async throws {
        let node = makeNode()
        try await node.start()
        let lease = try XCTUnwrap(node.reserveInboundAdmission(observedHost: "8.8.1.1"))
        let hostless = MemoryStream.pair(leftHost: nil, rightHost: "8.8.2.1").1
        node.accept(hostless, admission: lease)
        let refused = await eventually { hostless.isClosed }
        XCTAssertTrue(refused)
        // The slot the lease held is free again.
        let single = makeNode(maxConnectionsPerNetgroup: 1)
        try await single.start()
        let held = try XCTUnwrap(single.reserveInboundAdmission(observedHost: "8.8.1.1"))
        single.accept(MemoryStream.pair(leftHost: nil, rightHost: "8.8.2.1").1, admission: held)
        XCTAssertNotNil(single.reserveInboundAdmission(observedHost: "8.8.1.1"))
        await node.stop()
        await single.stop()
    }

    func testADroppedLeaseFreesItsSlot() async throws {
        let node = makeNode(maxConnectionsPerNetgroup: 1)
        try await node.start()
        var lease = node.reserveInboundAdmission(observedHost: "8.8.1.1")
        XCTAssertNotNil(lease)
        XCTAssertNil(node.reserveInboundAdmission(observedHost: "8.8.9.9"), "the netgroup is full")
        XCTAssertNotNil(node.reserveInboundAdmission(observedHost: "9.9.1.1"), "another netgroup is not")
        lease = nil
        XCTAssertNotNil(node.reserveInboundAdmission(observedHost: "8.8.1.1"))
        await node.stop()
    }

    func testALeaseFromAnEndedRunAdmitsNothing() async throws {
        let node = makeNode()
        try await node.start()
        let lease = try XCTUnwrap(node.reserveInboundAdmission(observedHost: "8.8.1.1"))
        await node.stop()
        try await node.start()
        let stream = MemoryStream.pair(leftHost: "8.8.1.1", rightHost: "8.8.2.1").1
        node.accept(stream, admission: lease)
        let refused = await eventually { stream.isClosed }
        XCTAssertTrue(refused)
        let pending = await node.diagnostics.pendingSessions
        XCTAssertEqual(pending, 0)
        await node.stop()
    }

    func testConnectingOverAHostlessStreamFailsAndClosesIt() async throws {
        let a = makeNode()
        let b = makeNode()
        try await a.start()
        let hostless = MemoryStream.pair(leftHost: "8.8.1.1", rightHost: nil).0
        do {
            try await a.connect(to: endpoint(b, host: "8.8.2.1"), over: hostless)
            XCTFail("connect should fail")
        } catch let error as IvyError {
            XCTAssertEqual(error, .streamHasNoObservedHost)
        }
        let closed = await eventually { hostless.isClosed }
        XCTAssertTrue(closed)
        let dials = await a.diagnostics.outgoingDials
        XCTAssertEqual(dials, 0)
        await a.stop()
    }

    func testConnectingOverAStreamWhileStoppedClosesIt() async throws {
        let a = makeNode()
        let b = makeNode()
        let stream = MemoryStream.pair(leftHost: "8.8.1.1", rightHost: "8.8.2.1").0
        do {
            try await a.connect(to: endpoint(b, host: "8.8.2.1"), over: stream)
            XCTFail("connect should fail")
        } catch let error as IvyError {
            XCTAssertEqual(error, .notRunning)
        }
        let closed = await eventually { stream.isClosed }
        XCTAssertTrue(closed)
    }

    func testAStreamThatDoesNotBecomeTheSessionIsClosed() async throws {
        let a = makeNode()
        let b = makeNode()
        try await a.start()
        try await b.start()
        let (left, _) = try await join(a, b)

        // The peer already has a session: a second stream to it is surplus.
        let (spare, spareFar) = MemoryStream.pair(leftHost: "8.8.1.1", rightHost: "8.8.2.1")
        try await a.connect(to: endpoint(b, host: "8.8.2.1"), over: spare)
        let closed = await eventually { spare.isClosed }
        XCTAssertTrue(closed)
        XCTAssertFalse(left.isClosed, "the session's own stream stays")
        _ = spareFar
        let peers = await a.connectedPeers
        XCTAssertEqual(peers, [b.localID])
        await a.stop()
        await b.stop()
    }
}

// MARK: - An in-memory transport

/// One end of an in-memory byte stream. It delivers only what was asked for
/// and counts what it has been asked, so a test can see the reader hold back.
final class MemoryStream: TransportConnection, @unchecked Sendable {
    static let capacity = 256 * 1024

    private let state: PairState
    private let side: Int
    private let host: String?
    private let local: String?

    private init(state: PairState, side: Int, host: String?, local: String?) {
        self.state = state
        self.side = side
        self.host = host
        self.local = local
    }

    /// `leftHost` and `rightHost` are where each end sits; each end observes the other's.
    static func pair(leftHost: String?, rightHost: String?) -> (MemoryStream, MemoryStream) {
        let state = PairState()
        return (
            MemoryStream(state: state, side: 0, host: rightHost, local: leftHost),
            MemoryStream(state: state, side: 1, host: leftHost, local: rightHost))
    }

    var observedHost: String? { host }
    var localHost: String? { local }
    var isActive: Bool { !isClosed }
    var isClosed: Bool { state.lock.withLock { state.closed } }
    var isWritable: Bool { state.lock.withLock { state.queued[side] < Self.capacity } }
    var requestCount: Int { state.lock.withLock { state.requests[side] } }
    var timesSaturated: Int { state.lock.withLock { state.saturations[side] } }
    /// Bytes sent to this end that it has not asked for.
    var unreadBytes: Int { state.lock.withLock { state.inbox[side].reduce(0) { $0 + $1.count } } }

    func attach(_ sink: any TransportConnectionSink) {
        let closed = state.lock.withLock { () -> Bool in
            if state.closed { return true }
            state.sinks[side] = sink
            return false
        }
        if closed { state.queue.async { sink.transportDidClose() } }
    }

    func requestBytes() {
        state.lock.withLock {
            state.requests[side] += 1
            state.wanted[side] = true
        }
        state.queue.async { self.state.pump() }
    }

    func send(_ bytes: Data) {
        state.lock.withLock {
            guard !state.closed else { return }
            let other = 1 - side
            state.inbox[other].append(bytes)
            let before = state.queued[side]
            state.queued[side] += bytes.count
            if before < Self.capacity, state.queued[side] >= Self.capacity {
                state.saturations[side] += 1
                state.saturated[side] = true
            }
        }
        state.queue.async { self.state.pump() }
    }

    func close() {
        state.queue.async { self.state.close() }
    }

    final class PairState: @unchecked Sendable {
        let lock = NSLock()
        /// Every sink call is made here, so calls arrive one at a time.
        let queue = DispatchQueue(label: "memory-stream")
        var sinks: [(any TransportConnectionSink)?] = [nil, nil]
        var inbox: [[Data]] = [[], []]
        var wanted = [false, false]
        var queued = [0, 0]
        var saturated = [false, false]
        var requests = [0, 0]
        var saturations = [0, 0]
        var closed = false

        func pump() {
            while true {
                var delivery: ((any TransportConnectionSink), Data)?
                var drained: (any TransportConnectionSink)?
                lock.withLock {
                    guard !closed else { return }
                    for side in 0...1 where wanted[side] && !inbox[side].isEmpty {
                        guard let sink = sinks[side] else { continue }
                        let bytes = inbox[side].removeFirst()
                        wanted[side] = false
                        let writer = 1 - side
                        queued[writer] -= bytes.count
                        if saturated[writer], queued[writer] < MemoryStream.capacity / 2 {
                            saturated[writer] = false
                            drained = sinks[writer]
                        }
                        delivery = (sink, bytes)
                        return
                    }
                }
                guard let (sink, bytes) = delivery else { return }
                sink.transportDidReceive(bytes)
                drained?.transportWritabilityChanged(isWritable: true)
            }
        }

        func close() {
            let targets = lock.withLock { () -> [any TransportConnectionSink] in
                guard !closed else { return [] }
                closed = true
                defer { sinks = [nil, nil] }
                return sinks.compactMap { $0 }
            }
            for sink in targets { sink.transportDidClose() }
        }
    }
}

private extension Ivy {
    func use(_ delegate: IvyDelegate) { self.delegate = delegate }
}

private actor StreamGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private actor StreamRecorderState {
    var messages: [PeerMessage] = []
    var entered = 0
    func enter() { entered += 1 }
    func add(_ message: PeerMessage) { messages.append(message) }
}

private final class StreamRecorder: IvyDelegate, Sendable {
    private let state = StreamRecorderState()
    private let gate: StreamGate?

    init(gate: StreamGate? = nil) {
        self.gate = gate
    }

    var messages: [PeerMessage] { get async { await state.messages } }
    var entered: Int { get async { await state.entered } }

    func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        await state.enter()
        await gate?.wait()
        await state.add(message)
    }
}

private struct StreamStore: IvyContentSource {
    var volumes: [String: [ContentEntry]] = [:]

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        volumes[rootCID] ?? []
    }
}
