import Crypto
import Foundation
import XCTest
@testable import Ivy
import Tally

/// The thin end-to-end tier: the facade and the TCP shell over real sockets.
/// Protocol behaviour is covered on virtual time in `IvyCoreTests`.
final class TCPIntegrationTests: XCTestCase {
    private func makeNode(
        requestTimeout: Duration = .seconds(15),
        maxInboundBufferedBytes: Int = IvyConfig.defaultMaxInboundBufferedBytes
    ) -> Ivy {
        Ivy.forTesting(IvyConfig(
            signingKey: Curve25519.Signing.PrivateKey(),
            listenPort: 0,
            requestTimeout: requestTimeout,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            maxConnectionsPerNetgroup: 16,
            maxInboundBufferedBytes: maxInboundBufferedBytes))
    }

    private func endpoint(_ node: Ivy) async -> PeerEndpoint {
        let port = await node.boundPort
        return PeerEndpoint(publicKey: node.publicKey, host: "127.0.0.1", port: port ?? 0)
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

    func testConnectDeliversMessagesAndReportsDisconnect() async throws {
        let a = makeNode()
        let b = makeNode()
        let recorder = Recorder()
        await b.setDelegate(recorder)
        try await a.start()
        try await b.start()
        try await a.connect(to: await endpoint(b))

        let connected = await eventually { await b.connectedPeers == [a.id] }
        XCTAssertTrue(connected)
        let sent = await a.sendMessage(to: b.id, topic: "t", payload: Data("hi".utf8))
        XCTAssertEqual(sent, .enqueued(endpoint: b.id, route: .direct))
        let delivered = await eventually { await recorder.messages.count == 1 }
        XCTAssertTrue(delivered)
        let message = await recorder.messages.first
        XCTAssertEqual(message?.1, PeerMessage(topic: "t", payload: Data("hi".utf8)))
        XCTAssertEqual(message?.0.id, a.id)
        let connects = await recorder.connects
        XCTAssertEqual(connects.map(\.id), [a.id])

        await a.disconnect(b.id)
        let gone = await eventually { await recorder.disconnects == [a.id] }
        XCTAssertTrue(gone)
        await a.stop()
        await b.stop()
    }

    func testFetchVolumeThroughContentSource() async throws {
        let a = makeNode()
        let b = makeNode()
        await b.setContentSource(Store(volumes: ["root": [
            ContentEntry(cid: "root", data: Data("r".utf8)), ContentEntry(cid: "leaf", data: Data("l".utf8)),
        ]]))
        try await a.start()
        try await b.start()
        try await a.connect(to: await endpoint(b))

        let response = await a.fetchVolume(rootCID: "root")
        XCTAssertEqual(response.entries, ["root": Data("r".utf8), "leaf": Data("l".utf8)])
        XCTAssertEqual(response.servedBy, b.id)
        let missing = await a.fetchVolume(rootCID: "absent")
        XCTAssertEqual(missing, .empty)
        await a.stop()
        await b.stop()
    }

    func testLargeVolumeCrossesManyFramesUnderBackpressure() async throws {
        let a = makeNode()
        let b = makeNode()
        // 24 MiB: six maximum frames, each far over the write high-water mark.
        let entries = [ContentEntry(cid: "vol", data: Data(repeating: 1, count: 1024))]
            + (0..<24).map { ContentEntry(cid: "vol-\($0)", data: Data(repeating: UInt8($0), count: 1024 * 1024)) }
        await b.setContentSource(Store(volumes: ["vol": entries]))
        try await a.start()
        try await b.start()
        try await a.connect(to: await endpoint(b))

        let response = await a.fetchVolume(rootCID: "vol")
        XCTAssertEqual(response.entries.count, entries.count)
        XCTAssertEqual(response.entries["vol-23"], entries[24].data)
        XCTAssertEqual(response.servedBy, b.id)

        let settled = await eventually {
            let serving = await b.diagnostics
            let fetching = await a.diagnostics
            return serving.reservedServingVolumeBytes == 0 && serving.servingSlotsHeld == 0
                && fetching.inFlightVolumeBytes == 0 && fetching.inboundBytesUsed == 0
        }
        XCTAssertTrue(settled)
        await a.stop()
        await b.stop()
    }

    func testSlowDelegateHoldsTheSocketNotMemory() async throws {
        let a = makeNode()
        let b = makeNode(maxInboundBufferedBytes: 4 * 1024 * 1024 + 4)
        let gate = Gate()
        let recorder = Recorder(gate: gate)
        await b.setDelegate(recorder)
        try await a.start()
        try await b.start()
        try await a.connect(to: await endpoint(b))

        // The first message parks in the delegate. Everything after it must
        // stay in the socket: Ivy holds one record and reads no further.
        let payload = Data(repeating: 7, count: 512 * 1024)
        var enqueued = 0
        fill: for _ in 0..<400 {
            switch await a.sendMessage(to: b.id, topic: "bulk", payload: payload) {
            case .enqueued:
                enqueued += 1
            case .backpressured:
                // A pipe that is full because the far side stopped reading
                // does not become writable.
                let writable = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { await a.waitUntilWritable(to: b.id) }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        return false
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                if !writable { break fill }
            default:
                XCTFail("unexpected send result")
                break fill
            }
        }
        XCTAssertGreaterThan(enqueued, 1)
        XCTAssertLessThan(enqueued, 400, "the sender must be held back")
        let parked = await eventually { await recorder.entered == 1 }
        XCTAssertTrue(parked)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let held = await b.diagnostics.inboundBytesUsed
        XCTAssertLessThanOrEqual(held, 4 * 1024 * 1024 + 4)
        let seen = await recorder.messages.count
        XCTAssertEqual(seen, 0, "no record is delivered past the one the delegate holds")

        await gate.open()
        let drained = await eventually { await recorder.messages.count >= 2 }
        XCTAssertTrue(drained)
        await a.stop()
        await b.stop()
    }

    func testStopAnswersWaitersAndRestartServesAgain() async throws {
        let a = makeNode()
        let b = makeNode()
        try await a.start()
        try await b.start()
        try await a.connect(to: await endpoint(b))
        await a.stop()
        let afterStop = await a.connectedPeers
        XCTAssertEqual(afterStop, [])
        let refused = await a.sendMessage(to: b.id, topic: "t", payload: Data())
        XCTAssertEqual(refused, .notConnected)

        try await a.start()
        try await a.connect(to: await endpoint(b))
        let reconnected = await eventually { await b.connectedPeers == [a.id] }
        XCTAssertTrue(reconnected)
        await a.stop()
        await b.stop()
    }

#if DEBUG || IVY_TESTING
    func testDialRewriteRedirectsTheSocketNotTheIdentity() async throws {
        let a = makeNode()
        let b = makeNode()
        try await a.start()
        try await b.start()
        let real = await endpoint(b)
        await a.setDialEndpointRewriteForTesting { dialled in
            dialled.host == "8.8.4.4"
                ? PeerEndpoint(publicKey: dialled.publicKey, host: "127.0.0.1", port: dialled.port)
                : dialled
        }
        // A routable address nobody listens on, redirected to the loopback listener.
        try await a.connect(to: PeerEndpoint(publicKey: real.publicKey, host: "8.8.4.4", port: real.port))
        let connected = await eventually { await b.connectedPeers == [a.id] }
        XCTAssertTrue(connected)
        await a.stop()
        await b.stop()
    }
#endif

    func testDialToClosedPortFails() async throws {
        let a = makeNode()
        try await a.start()
        let nobody = PeerEndpoint(
            publicKey: IvyConfig(signingKey: Curve25519.Signing.PrivateKey()).publicKey,
            host: "127.0.0.1",
            port: 1)
        do {
            try await a.connect(to: nobody)
            XCTFail("connect should fail")
        } catch let error as IvyError {
            XCTAssertEqual(error, .noRelayAvailable)
        }
        let dials = await a.diagnostics.outgoingDials
        XCTAssertEqual(dials, 0)
        await a.stop()
    }
}

private extension Ivy {
    func setDelegate(_ delegate: IvyDelegate?) { self.delegate = delegate }
}

private actor Gate {
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

private actor RecorderState {
    var messages: [(AuthenticatedPeer, PeerMessage)] = []
    var connects: [AuthenticatedPeer] = []
    var disconnects: [PeerID] = []
    var entered = 0

    func enter() { entered += 1 }
    func add(_ peer: AuthenticatedPeer, _ message: PeerMessage) { messages.append((peer, message)) }
    func add(connect peer: AuthenticatedPeer) { connects.append(peer) }
    func add(disconnect peer: PeerID) { disconnects.append(peer) }
}

private final class Recorder: IvyDelegate, Sendable {
    private let state = RecorderState()
    private let gate: Gate?

    init(gate: Gate? = nil) {
        self.gate = gate
    }

    var messages: [(AuthenticatedPeer, PeerMessage)] { get async { await state.messages } }
    var connects: [AuthenticatedPeer] { get async { await state.connects } }
    var disconnects: [PeerID] { get async { await state.disconnects } }
    var entered: Int { get async { await state.entered } }

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
        await state.add(connect: peer)
    }

    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        Task { await state.add(disconnect: peer) }
    }

    func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        await state.enter()
        await gate?.wait()
        await state.add(peer, message)
    }
}

private struct Store: IvyContentSource {
    var volumes: [String: [ContentEntry]] = [:]

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        volumes[rootCID] ?? []
    }
}
