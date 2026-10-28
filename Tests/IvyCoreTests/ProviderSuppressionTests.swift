import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// `reportDeficientContent`: the peer is passed over for that root for a
/// while, and nothing else about it changes.
final class ProviderSuppressionTests: XCTestCase {
    private let rootBytes = Data("available".utf8)

    private func volume(_ root: String) -> Request {
        .fetchVolume(
            rootCID: root,
            maximumArchiveBytes: MessageLimits.maxVolumeArchiveBytes,
            maximumEntries: Int(MessageLimits.maxVolumeEntryCount))
    }

    private func served(_ root: String, by peer: PeerID) -> AttributedVolumeResponse {
        AttributedVolumeResponse(rootCID: root, entries: [root: rootBytes], servedBy: peer)
    }

    private func peerID(_ sim: Simulation, _ index: Int) -> PeerID {
        try! PeerKey(rawRepresentation: sim.signingKey(index: 20_000 + index).publicKey.rawRepresentation).peerID
    }

    /// Caller-reported invalid content suppresses only that root, without a
    /// ledger penalty.
    func testInvalidContentIsRootScopedRoutingFeedback() {
        let sim = Simulation()
        let node = sim.fetchNode()
        let peer = FetchRawPeer(sim, to: node, index: 0)
        let expiry = sim.unixSeconds + 60
        peer.send(.announceProvider(rootCID: "root-a", expiresAt: expiry))
        peer.send(.announceProvider(rootCID: "root-b", expiresAt: expiry))
        XCTAssertEqual(node.core.providers(for: "root-a"), [peer.peer])
        XCTAssertEqual(node.core.providers(for: "root-b"), [peer.peer])

        sim.send(.command(.reportDeficientContent(rootCID: "root-a", servedBy: peer.peer)), to: node)

        XCTAssertFalse(node.core.providers(for: "root-a").contains(peer.peer))
        XCTAssertTrue(node.core.providers(for: "root-b").contains(peer.peer))
        XCTAssertTrue(node.core.isDeficiencySuppressed(rootCID: "root-a", peer: peer.peer))
        XCTAssertFalse(node.core.isDeficiencySuppressed(rootCID: "root-b", peer: peer.peer))
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)
        // No disconnect: the session carries on.
        XCTAssertEqual(node.core.connectedPeers, [peer.peer])
        XCTAssertTrue(node.disconnected.isEmpty)
        peer.send(.peerMessage(topic: "still-here", payload: Data([1])))
        sim.settleDue()
        XCTAssertEqual(node.received.map(\.message.topic), ["still-here"])
    }

    /// Provider hints retain original expiry and obey the per-root cap.
    func testProviderHintBoundsAndExpiry() {
        let sim = Simulation()
        let node = sim.fetchNode(kBucketSize: 2)
        let now = sim.unixSeconds
        node.core.storeProviderHint(rootCID: "root", peer: peerID(sim, 99), endpoint: nil, expiresAt: now)

        let retained = (0..<3).map { peerID(sim, $0) }
        for peer in retained {
            node.core.storeProviderHint(rootCID: "root", peer: peer, endpoint: nil, expiresAt: now + 60)
            sim.send(.command(.reportDeficientContent(rootCID: "bad-root", servedBy: peer)), to: node)
        }

        // Two of the three, chosen by the node's secret rank, not recency.
        XCTAssertEqual(node.core.providers(for: "root").count, 2)
        XCTAssertTrue(Set(retained).isSuperset(of: node.core.providers(for: "root")))
        XCTAssertEqual(node.core.providerHints["root"]?.map(\.expiresAt), [now + 60, now + 60])
        XCTAssertEqual(node.core.deficientPeerSuppression["bad-root"]?.count, 2)
    }

    /// Same-root deficiency is honored by last-resort connected fallback,
    /// for thirty seconds.
    func testDeficiencySuppressesConnectedFallback() {
        let sim = Simulation()
        let requester = sim.fetchNode()
        let provider = sim.node()
        for root in ["suppressed-root", "other-root"] {
            provider.volumes[root] = [ContentEntry(cid: root, data: rootBytes)]
        }
        sim.connect(requester, provider)

        sim.send(
            .command(.reportDeficientContent(rootCID: "suppressed-root", servedBy: provider.peer)), to: requester)
        let reported = sim.now
        let response = sim.await(volume("suppressed-root"), on: requester)

        XCTAssertEqual(response, .volume(.empty))
        XCTAssertTrue(provider.startedJobs.isEmpty)

        // Other roots are unaffected.
        XCTAssertEqual(
            sim.await(volume("other-root"), on: requester)?.volume, served("other-root", by: provider.peer))
        let servedOther = provider.startedJobs.count

        // Still passed over just short of the window.
        sim.run(for: .seconds(29) - (sim.now - reported))
        XCTAssertEqual(sim.await(volume("suppressed-root"), on: requester), .volume(.empty))
        XCTAssertEqual(provider.startedJobs.count, servedOther)
        XCTAssertLessThan(sim.now - reported, .seconds(30))

        // And asked again once it has passed.
        sim.run(for: .seconds(30) - (sim.now - reported))
        XCTAssertEqual(
            sim.await(volume("suppressed-root"), on: requester)?.volume,
            served("suppressed-root", by: provider.peer))

        XCTAssertEqual(requester.core.connectedPeers, [provider.peer])
        XCTAssertTrue(requester.disconnected.isEmpty)
        XCTAssertTrue(provider.disconnected.isEmpty)
        XCTAssertEqual(requester.ledger.violations(of: provider.peer), 0)
    }

    /// Provider caching preserves bounded route alternatives per identity.
    func testProviderRouteAlternatives() {
        let sim = Simulation()
        let node = sim.fetchNode(kBucketSize: 2)
        let peer = peerID(sim, 0)
        let first = PeerEndpoint(publicKey: peer.publicKey, host: "1.1.1.1", port: 4001)
        let second = PeerEndpoint(publicKey: peer.publicKey, host: "8.8.8.8", port: 4001)
        let expiry = sim.unixSeconds + 60

        node.core.storeProviderHint(rootCID: "root", peer: peer, endpoint: first, expiresAt: expiry)
        node.core.storeProviderHint(rootCID: "root", peer: peer, endpoint: second, expiresAt: expiry)

        XCTAssertEqual(Set(node.core.cachedProviderEndpoints(rootCID: "root")), [first, second])
        XCTAssertEqual(node.core.providers(for: "root"), [peer])
    }

    /// A later fetch can use another connected provider as a separate
    /// availability zone.
    func testDeficientPeerIsPassedOverWhileOthersAreAsked() throws {
        let sim = Simulation()
        let node = sim.fetchNode()
        let deficient = FetchRawPeer(sim, to: node, index: 0)
        let other = FetchRawPeer(sim, to: node, index: 1)
        sim.send(.command(.reportDeficientContent(rootCID: "root", servedBy: deficient.peer)), to: node)

        let served = sim.request(volume("root"), on: node)
        let servedID = try XCTUnwrap(other.takeVolumeRequest()).requestID
        XCTAssertNil(deficient.takeVolumeRequest())
        XCTAssertEqual(node.core.pendingVolumeRequests[servedID]?.candidateSessions.keys.map { $0 }, [other.peer])
        other.sendVolume(requestID: servedID, root: "root")
        XCTAssertEqual(sim.result(of: served, on: node)?.volume?.servedBy, other.peer)

        // A miss from the other peer does not bring the deficient one back.
        let missed = sim.request(volume("root"), on: node)
        let missedID = try XCTUnwrap(other.takeVolumeRequest()).requestID
        other.send(.contentUnavailable(requestID: missedID))
        XCTAssertEqual(sim.result(of: missed, on: node), .volume(.empty))
        XCTAssertNil(deficient.takeVolumeRequest())

        // Another root asks both, one at a time.
        _ = sim.request(volume("other-root"), on: node)
        var asked: Set<PeerID> = []
        for _ in 0..<2 {
            for peer in [deficient, other] {
                guard let requestID = peer.takeVolumeRequestID() else { continue }
                asked.insert(peer.peer)
                peer.send(.contentUnavailable(requestID: requestID))
            }
        }
        XCTAssertEqual(asked, [deficient.peer, other.peer])
    }

    /// A deficient provider's record is forgotten for that root, so the next
    /// fetch does not start with it as a known provider.
    func testDeficientProviderIsNotAskedAsAKnownProvider() throws {
        let sim = Simulation()
        let node = sim.fetchNode()
        let provider = FetchRawPeer(sim, to: node, index: 0)
        provider.send(.announceProvider(rootCID: "root", expiresAt: sim.unixSeconds + 60))
        sim.send(.command(.reportDeficientContent(rootCID: "root", servedBy: provider.peer)), to: node)

        let fetch = sim.request(volume("root"), on: node)

        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty))
        XCTAssertNil(provider.takeVolumeRequest())

        // An exact fetch names its session; suppression is about selection.
        let exact = sim.request(
            .fetchVolumeFrom(
                provider.authenticated,
                rootCID: "root",
                maximumArchiveBytes: MessageLimits.maxVolumeArchiveBytes,
                maximumEntries: Int(MessageLimits.maxVolumeEntryCount)),
            on: node)
        let requestID = try XCTUnwrap(provider.takeVolumeRequest()).requestID
        provider.sendVolume(requestID: requestID, root: "root")
        XCTAssertEqual(sim.result(of: exact, on: node)?.volume?.servedBy, provider.peer)
    }
}
