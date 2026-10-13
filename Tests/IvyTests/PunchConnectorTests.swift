import Crypto
import Foundation
import XCTest
@testable import Ivy
import Tally

private final class Heard: IvyDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _sessions: [AuthenticatedPeer] = []
    private var _disconnects: [PeerID] = []
    private var _messages: [PeerMessage] = []

    var sessions: [AuthenticatedPeer] { lock.withLock { _sessions } }
    var disconnects: [PeerID] { lock.withLock { _disconnects } }
    var messages: [PeerMessage] { lock.withLock { _messages } }

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
        lock.withLock { _sessions.append(peer) }
    }

    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        lock.withLock { _disconnects.append(peer) }
    }

    func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        lock.withLock { _messages.append(message) }
    }
}

/// A transport whose attempts never connect, as between two peers no packet
/// passes between.
private struct NoPath: PunchTransport {
    let kind = PunchCandidate.tcp
    func prepare() async -> (any PunchSocket)? { Socket() }

    struct Socket: PunchSocket {
        let port: UInt16 = 9
        func connect(
            to candidates: [PunchCandidate], initiator: Bool, deadline: ContinuousClock.Instant
        ) async -> (any TransportConnection)? {
            try? await Task.sleep(until: deadline, clock: .continuous)
            return nil
        }
        func close() {}
    }
}

/// Two endpoints that met through a carrier, over real sockets on loopback.
final class PunchConnectorTests: XCTestCase {
    private struct End {
        let node: Ivy
        let heard: Heard
        let punch: PunchConnector
        let other: @Sendable () -> PeerID

        /// The sessions with the other endpoint the application heard of, in order.
        var sessions: [AuthenticatedPeer] { heard.sessions.filter { $0.id == other() } }
        var session: AuthenticatedPeer? { sessions.last }
        var isDirect: Bool { session?.route == .direct }
    }

    private struct Triangle {
        let carrier: Ivy
        let a: End
        let b: End

        /// The end that makes the offer, and the one that asks for it.
        var offerer: End { a.node.publicKey < b.node.publicKey ? a : b }
        var asker: End { a.node.publicKey < b.node.publicKey ? b : a }
    }

    private func config(carriers: [PeerEndpoint] = [], relay: Bool = false) -> IvyConfig {
        IvyConfig(
            signingKey: Curve25519.Signing.PrivateKey(),
            listenPort: 0,
            requestTimeout: .seconds(15),
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            maxConnectionsPerNetgroup: 16,
            relayEnabled: relay,
            carriers: carriers)
    }

    private func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    /// `a` configures the carrier and opens the relayed session; `b` is
    /// simply connected to the carrier.
    private func triangle(
        transports: [any PunchTransport] = [TCPPunch()],
        _ adjust: (inout PunchConnector.Options) -> Void = { _ in }
    ) async throws -> Triangle {
        var options = PunchConnector.Options()
        options.autoUpgrade = false
        options.hosts = ["127.0.0.1"]
        options.allowPrivateCandidates = true
        adjust(&options)

        let carrier = Ivy.forTesting(config(relay: true))
        try await carrier.start()
        let port = await carrier.boundPort ?? 0
        let carrierEndpoint = PeerEndpoint(publicKey: carrier.publicKey, host: "127.0.0.1", port: port)

        let nodes = [Ivy.forTesting(config(carriers: [carrierEndpoint])), Ivy.forTesting(config())]
        let heard = [Heard(), Heard()]
        var ends: [End] = []
        for index in 0..<2 {
            let other = nodes[1 - index].id
            let punch = PunchConnector(
                ivy: nodes[index], localKey: nodes[index].publicKey, transports: transports,
                forwardingTo: heard[index], options: options)
            await nodes[index].setDelegate(punch)
            ends.append(End(node: nodes[index], heard: heard[index], punch: punch, other: { other }))
            try await nodes[index].start()
        }
        let made = ends
        addTeardownBlock {
            for end in made {
                end.punch.close()
                await end.node.stop()
            }
            await carrier.stop()
        }
        try await nodes[1].connect(to: carrierEndpoint)
        let joined = await eventually { await carrier.connectedPeers.count == 2 }
        XCTAssertTrue(joined)

        try await nodes[0].connectViaRelay(
            to: PeerEndpoint(publicKey: nodes[1].publicKey, host: "relay", port: 0))
        let met = await eventually { made[0].session != nil && made[1].session != nil }
        XCTAssertTrue(met)
        if !options.autoUpgrade {
            XCTAssertFalse(made[0].isDirect)
            XCTAssertFalse(made[1].isDirect)
        }
        return Triangle(carrier: carrier, a: made[0], b: made[1])
    }

    func testTwoPeersThatMetThroughACarrierMoveToAConnectionOfTheirOwn() async throws {
        let t = try await triangle()
        let upgraded = await t.offerer.punch.upgrade(try XCTUnwrap(t.offerer.session))
        XCTAssertTrue(upgraded)
        let direct = await eventually { t.a.isDirect && t.b.isDirect }
        XCTAssertTrue(direct)
        XCTAssertEqual(t.a.session?.sessionID, t.b.session?.sessionID)

        // One session took the other's place: no disconnect, and the
        // signalling stayed with the connectors.
        for end in [t.a, t.b] {
            XCTAssertEqual(end.sessions.map(\.route).map { $0 == .direct }, [false, true])
            XCTAssertEqual(end.heard.disconnects, [])
            XCTAssertEqual(end.heard.messages, [])
        }

        let sent = await t.a.node.sendMessage(to: t.b.node.id, topic: "t", payload: Data("direct".utf8))
        XCTAssertEqual(sent, .enqueued(endpoint: t.b.node.id, route: .direct))
        let delivered = await eventually { t.b.heard.messages == [PeerMessage(topic: "t", payload: Data("direct".utf8))] }
        XCTAssertTrue(delivered)

        // Asked again, there is nothing to do.
        let again = await t.a.punch.upgrade(try XCTUnwrap(t.a.session))
        XCTAssertTrue(again)
    }

    func testTheEndThatDoesNotOfferAsksForOne() async throws {
        let t = try await triangle()
        let upgraded = await t.asker.punch.upgrade(try XCTUnwrap(t.asker.session))
        XCTAssertTrue(upgraded)
        let direct = await eventually { t.a.isDirect && t.b.isDirect }
        XCTAssertTrue(direct)
        XCTAssertEqual(t.a.heard.disconnects + t.b.heard.disconnects, [])
    }

    func testBothEndsStartingAtOnceMakeOneConnection() async throws {
        let t = try await triangle()
        async let first = t.a.punch.upgrade(try XCTUnwrap(t.a.session))
        async let second = t.b.punch.upgrade(try XCTUnwrap(t.b.session))
        let results = try await [first, second]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(t.a.session?.sessionID, t.b.session?.sessionID)
        XCTAssertEqual(t.a.sessions.count, 2)
        XCTAssertEqual(t.b.sessions.count, 2)
    }

    func testARelayedSessionIsUpgradedAsItAppears() async throws {
        let t = try await triangle { $0.autoUpgrade = true }
        let direct = await eventually { t.a.isDirect && t.b.isDirect }
        XCTAssertTrue(direct)
        XCTAssertEqual(t.a.heard.disconnects + t.b.heard.disconnects, [])
    }

    func testAnAttemptThatCannotConnectLeavesTheRelayedSession() async throws {
        let t = try await triangle(transports: [NoPath()]) {
            $0.dialWindow = .milliseconds(200)
            $0.deadline = .seconds(2)
        }
        let session = try XCTUnwrap(t.offerer.session)
        // Three attempts on one relayed session, and then no more.
        for _ in 0..<PunchConnector.maxAttempts {
            let upgraded = await t.offerer.punch.upgrade(session)
            XCTAssertFalse(upgraded)
        }
        let started = ContinuousClock.now
        let refused = await t.offerer.punch.upgrade(session)
        XCTAssertFalse(refused)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(150), "a fourth is not made")

        XCTAssertFalse(t.a.isDirect)
        XCTAssertEqual(t.a.sessions.count, 1)
        XCTAssertEqual(t.a.heard.disconnects + t.b.heard.disconnects, [])
        let sent = await t.a.node.sendMessage(to: t.b.node.id, topic: "t", payload: Data("relayed".utf8))
        guard case .enqueued(_, .relayed) = sent else { return XCTFail("the relayed session is gone: \(sent)") }
    }

    func testAnAddressInsideANetworkIsNotDialledUnlessAllowed() async throws {
        let t = try await triangle { $0.allowPrivateCandidates = false }
        let upgraded = await t.offerer.punch.upgrade(try XCTUnwrap(t.offerer.session))
        XCTAssertFalse(upgraded, "the peer offered 127.0.0.1")
        XCTAssertFalse(t.a.isDirect)
        XCTAssertFalse(t.b.isDirect)
        XCTAssertEqual(t.a.heard.disconnects + t.b.heard.disconnects, [])
    }

    func testSignallingThatIsMalformedOrFromElsewhereCostsNoSession() async throws {
        let t = try await triangle()
        let junk: [Data] = [
            Data(), Data([9, 0, 0, 0, 1]), Data([1, 0, 0, 0, 0]), Data([1, 0, 0, 0, 7, 3]),
            Data([2, 0, 0, 0, 7]), Data([3, 0, 0, 0, 7, 1]), Data(repeating: 1, count: 2048),
        ]
        for payload in junk {
            for (from, to) in [(t.a, t.b), (t.b, t.a)] {
                _ = await from.node.sendMessage(to: to.node.id, topic: PunchConnector.topic, payload: payload)
            }
        }
        // From the carrier, which is a direct session.
        _ = await t.carrier.sendMessage(
            to: t.b.node.id, topic: PunchConnector.topic, payload: Data([0, 0, 0, 0, 0]))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(t.a.heard.disconnects + t.b.heard.disconnects, [])
        XCTAssertEqual(t.a.heard.messages + t.b.heard.messages, [], "the topic is the connector's")

        // And the pair can still be upgraded.
        let upgraded = await t.offerer.punch.upgrade(try XCTUnwrap(t.offerer.session))
        XCTAssertTrue(upgraded)
    }

    func testCandidatesRoundTripAndRefuseWhatIsMalformed() {
        let candidates = [
            PunchCandidate(transport: PunchCandidate.tcp, host: "203.0.113.7", port: 4001),
            PunchCandidate(transport: PunchCandidate.quic, host: "2001:db8::1", port: 65535),
        ]
        let encoded = PunchConnector.encode(candidates)
        XCTAssertEqual(PunchConnector.decode(encoded), candidates)

        XCTAssertNil(PunchConnector.decode(Data()))
        XCTAssertNil(PunchConnector.decode(Data([0])), "none")
        XCTAssertNil(PunchConnector.decode(encoded.dropLast()), "short")
        XCTAssertNil(PunchConnector.decode(encoded + [0]), "long")
        XCTAssertNil(PunchConnector.decode(Data([1, 1, 0, 80, 0])), "no host")
        XCTAssertNil(PunchConnector.decode(Data([1, 1, 0, 80, 2, 0xff, 0xfe])), "not text")
        let many = Array(repeating: candidates[0], count: PunchConnector.maxCandidates + 1)
        XCTAssertNil(PunchConnector.decode(PunchConnector.encode(many)))
    }
}

private extension Ivy {
    func setDelegate(_ delegate: IvyDelegate?) { self.delegate = delegate }
}
