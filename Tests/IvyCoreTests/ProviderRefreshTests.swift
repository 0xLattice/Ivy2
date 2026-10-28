import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Provider discovery as a fetch and a caller see it: ported from 15.0.1's
/// ProviderRefreshTests.
final class ProviderRefreshTests: XCTestCase {
    private func volume(_ root: String) -> Request {
        .fetchVolume(
            rootCID: root,
            maximumArchiveBytes: MessageLimits.maxVolumeArchiveBytes,
            maximumEntries: Int(MessageLimits.maxVolumeEntryCount))
    }

    private func record(_ endpoint: PeerEndpoint, _ expiresAt: UInt64) -> ProviderRecord {
        ProviderRecord(endpoint: endpoint, expiresAt: expiresAt)
    }

    /// "one flooding responder cannot eclipse an honest provider"
    func testProviderResponsesAreSourceDiverse() {
        let sim = Simulation()
        let node = sim.discoveryNode(kBucketSize: 4, maxContentCandidates: 4)
        let honestResponder = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let floodingResponder = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let finalResponder = DiscoveryScriptedPeer(sim, to: node, index: 2)
        XCTAssertEqual(node.core.knownPeerEndpoints.count, 3)
        let honestProvider = PeerEndpoint(
            publicKey: sim.discoveryKey(index: 0).hex, host: "1.1.1.1", port: 4001)
        let root = "provider-diversity-root"
        let expiry = sim.unixSeconds + 60
        let routes = IvyConfig.defaultMaxRoutesPerIdentity

        let search = sim.request(.discoverProviders(rootCID: root), on: node)
        XCTAssertNotNil(node.core.pendingProviderQueries[root])

        XCTAssertEqual(honestResponder.answerFindProviders([record(honestProvider, expiry)]), 1)
        let poisonedRoutes = (0..<routes).map { index in
            record(
                PeerEndpoint(publicKey: honestProvider.publicKey, host: "8.8.4.\(index + 1)", port: UInt16(3900 + index)),
                expiry)
        }
        let flood = (0..<Int(MessageLimits.maxNeighborCount) - poisonedRoutes.count).map { index in
            record(
                PeerEndpoint(publicKey: sim.discoveryKey(index: 100 + index).hex, host: "8.8.8.8", port: UInt16(index + 1)),
                expiry)
        } + poisonedRoutes
        XCTAssertEqual(flood.count, Int(MessageLimits.maxNeighborCount))
        XCTAssertEqual(floodingResponder.answerFindProviders(flood), 1)
        let held = node.core.pendingProviderQueries[root]?.responsesByPeer[floodingResponder.key.hex]?.count
        XCTAssertNotNil(held)
        XCTAssertLessThanOrEqual(held ?? .max, 4 * routes)
        XCTAssertNil(sim.result(of: search, on: node))
        XCTAssertEqual(finalResponder.answerFindProviders([]), 1)

        let result = sim.result(of: search, on: node)?.endpoints ?? []
        XCTAssertTrue(result.contains(honestProvider))
        XCTAssertTrue(result.prefix(4).contains(honestProvider))
        // The flood's routes for the honest identity share the flood's
        // netgroup and are shed with it; the honest route is what is kept.
        XCTAssertEqual(result.filter { $0.publicKey == honestProvider.publicKey }.first, honestProvider)
        XCTAssertTrue(node.core.providers(for: root).contains(PeerID(publicKey: honestProvider.publicKey)))
        // Bounded per root and per identity.
        XCTAssertLessThanOrEqual(Set(result.map(\.publicKey)).count, 4)
        XCTAssertLessThanOrEqual(node.core.providers(for: root).count, 4)
        for (_, group) in Dictionary(grouping: result, by: \.publicKey) {
            XCTAssertLessThanOrEqual(group.count, routes)
        }
    }

    /// "a provider of a root still discovers the other providers of it"
    func testOwnRecordDoesNotAnswerDiscovery() {
        let sim = Simulation()
        let requester = sim.discoveryNode(host: "8.31.0.1", externalAddress: ("8.31.0.1", 4001))
        let router = sim.node()
        let provider = sim.node()
        let root = "own-record-root"
        sim.connect(requester, router)
        sim.connect(provider, router)
        XCTAssertEqual(router.core.peerConnectionCount, 2)

        // The router holds the other provider's record at a routable address.
        let expiry = sim.unixSeconds + 60
        router.core.storeProviderHint(
            rootCID: root,
            peer: provider.peer,
            endpoint: PeerEndpoint(publicKey: provider.key.hex, host: "8.8.8.8", port: 4001),
            expiresAt: expiry)

        // The requester provides the root too: its own record is in its table.
        sim.send(.command(.announceProvider(rootCID: root, expiresAt: expiry)), to: requester)
        XCTAssertEqual(requester.core.providers(for: root), [requester.peer])
        sim.run(for: .seconds(1))
        XCTAssertTrue(router.core.providers(for: root).contains(requester.peer))

        let found = sim.await(.discoverProviders(rootCID: root), on: requester)?.endpoints ?? []
        XCTAssertTrue(
            found.map(\.publicKey).contains(provider.key.hex),
            "a node's own record must not stand in for the network's answer")
        XCTAssertFalse(found.map(\.publicKey).contains(requester.key.hex), "a node never discovers itself")
    }

    /// "a record naming a connected peer does not stand in for the network's answer"
    func testConnectedRecordDoesNotAnswerDiscovery() {
        let sim = Simulation()
        let requester = sim.node()
        let router = sim.node()
        let root = "connected-record-root"
        sim.connect(requester, router)

        // The router holds another provider's record; the requester's only
        // record names the router, which it is connected to.
        let expiry = sim.unixSeconds + 60
        let other = PeerEndpoint(publicKey: sim.discoveryKey(index: 0).hex, host: "8.8.8.8", port: 4001)
        router.core.storeProviderHint(
            rootCID: root, peer: PeerID(publicKey: other.publicKey), endpoint: other, expiresAt: expiry)
        requester.core.storeProviderHint(
            rootCID: root, peer: router.peer, endpoint: router.endpoint, expiresAt: expiry)

        let found = sim.await(.discoverProviders(rootCID: root), on: requester)?.endpoints ?? []
        XCTAssertTrue(found.contains(other), "a lookup must find providers beyond the ones already connected")
        XCTAssertTrue(found.contains(router.endpoint))
        XCTAssertEqual(requester.core.freshProviderQueryCount, 1)

        // A record naming a peer not connected answers without a round trip.
        let cachedOnly = "connected-record-cached-root"
        requester.core.storeProviderHint(
            rootCID: cachedOnly, peer: PeerID(publicKey: other.publicKey), endpoint: other, expiresAt: expiry)
        let cached = sim.request(.discoverProviders(rootCID: cachedOnly), on: requester)
        XCTAssertEqual(sim.result(of: cached, on: requester)?.endpoints, [other])
        XCTAssertEqual(requester.core.freshProviderQueryCount, 1)
    }

    /// "a failed cached hint triggers fresh discovery without deleting the hint"
    ///
    /// A Volume fetch asks the peers already connected before it looks
    /// anything up, so the live provider is one the requester has no session with.
    func testStaleHintFallsBackToFreshQuery() {
        let sim = Simulation()
        let requester = sim.discoveryNode()
        let router = sim.node()
        let provider = sim.node()
        let root = "provider-refresh-root"
        provider.volumes[root] = [ContentEntry(cid: root, data: Data("fresh provider".utf8))]
        sim.connect(requester, router)
        sim.connect(provider, router)

        let expiry = sim.unixSeconds + 60
        sim.send(.command(.announceProvider(rootCID: root, expiresAt: expiry)), to: provider)
        XCTAssertTrue(sim.run(until: { router.core.providers(for: root).contains(provider.peer) }, timeout: .seconds(1)))

        // A provider nobody can reach.
        let staleEndpoint = sim.discoveryUnreachableEndpoint(index: 0)
        let staleID = PeerID(publicKey: staleEndpoint.publicKey)
        requester.core.storeProviderHint(rootCID: root, peer: staleID, endpoint: staleEndpoint, expiresAt: expiry)
        router.core.storeProviderHint(rootCID: root, peer: staleID, endpoint: staleEndpoint, expiresAt: expiry)

        let response = sim.await(volume(root), on: requester)?.volume

        XCTAssertEqual(response?.entries, [root: Data("fresh provider".utf8)])
        XCTAssertEqual(response?.servedBy, provider.peer)
        XCTAssertTrue(requester.core.providers(for: root).contains(staleID))
        XCTAssertEqual(requester.core.freshProviderQueryCount, 1)
        XCTAssertTrue(requester.core.volumeFetches.isEmpty)
    }

    /// "a connected unavailable hint cannot suppress fresh discovery"
    func testConnectedHintFallsBackToFreshQuery() {
        let sim = Simulation()
        let requester = sim.node()
        let router = sim.node()
        let stale = sim.node()
        let provider = sim.node()
        let root = "provider-connected-root"
        stale.stallsStorage = true
        provider.volumes[root] = [ContentEntry(cid: root, data: Data("fresh after unavailable".utf8))]
        sim.connect(requester, router)
        sim.connect(requester, stale)
        sim.connect(provider, router)

        let expiry = sim.unixSeconds + 60
        sim.send(.command(.announceProvider(rootCID: root, expiresAt: expiry)), to: provider)
        XCTAssertTrue(sim.run(until: { router.core.providers(for: root).contains(provider.peer) }, timeout: .seconds(1)))
        requester.core.storeProviderHint(
            rootCID: root, peer: stale.peer, endpoint: stale.endpoint, expiresAt: expiry)

        let fetch = sim.request(volume(root), on: requester)
        XCTAssertTrue(sim.run(until: { stale.startedJobs.count == 1 }, timeout: .seconds(1)))
        XCTAssertEqual(requester.core.freshProviderQueryCount, 0)
        sim.releaseStorage(stale)

        XCTAssertTrue(sim.run(until: { sim.result(of: fetch, on: requester) != nil }, timeout: .seconds(5)))
        let response = sim.result(of: fetch, on: requester)?.volume
        XCTAssertEqual(response?.entries, [root: Data("fresh after unavailable".utf8)])
        XCTAssertEqual(response?.servedBy, provider.peer)
        XCTAssertEqual(requester.core.freshProviderQueryCount, 1)
    }

    /// "fresh discovery preserves replacement endpoints until exclusion"
    func testReplacementEndpointSurvivesExclusion() {
        let sim = Simulation()
        let node = sim.discoveryNode(externalAddress: ("9.9.9.9", 4001))
        let responder = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let providerKey = sim.discoveryKey(index: 0).hex
        let failed = PeerEndpoint(publicKey: providerKey, host: "1.1.1.1", port: 4001)
        let replacement = PeerEndpoint(publicKey: providerKey, host: "8.8.8.8", port: 4001)
        let root = "provider-endpoint-root"
        let expiry = sim.unixSeconds + 60

        let search = sim.request(.discoverProviders(rootCID: root), on: node)
        XCTAssertEqual(responder.answerFindProviders([record(replacement, expiry), record(failed, expiry)]), 1)

        let found = sim.result(of: search, on: node)?.endpoints
        XCTAssertEqual(found?.count, 2)
        XCTAssertEqual(found?.filter { $0 != failed }, [replacement])
    }

    /// "provider address alternatives are tried for one identity"
    func testProviderAddressFailover() {
        let sim = Simulation()
        let requester = sim.node()
        let provider = sim.node()
        let root = "provider-route-root"
        provider.volumes[root] = [ContentEntry(cid: root, data: Data("alternate provider route".utf8))]
        let dead = PeerEndpoint(publicKey: provider.key.hex, host: "1.1.1.1", port: 4001)
        let live = provider.endpoint
        let expiry = sim.unixSeconds + 60
        requester.core.storeProviderHint(rootCID: root, peer: provider.peer, endpoint: dead, expiresAt: expiry)
        requester.core.storeProviderHint(rootCID: root, peer: provider.peer, endpoint: live, expiresAt: expiry)

        let response = sim.await(volume(root), on: requester)?.volume

        XCTAssertTrue(requester.core.hasEndpointSession(provider.peer))
        XCTAssertEqual(response?.entries, [root: Data("alternate provider route".utf8)])
        XCTAssertEqual(response?.servedBy, provider.peer)
        XCTAssertEqual(sim.discoveryDials(by: requester), [dead, live])
        XCTAssertEqual(requester.core.freshProviderQueryCount, 0, "a known provider that serves needs no search")
    }

    /// "provider wire limits preserve identities before route alternatives"
    func testProviderWireIdentityFairness() {
        let sim = Simulation()
        let node = sim.node()
        let expiry = sim.unixSeconds + 60
        let hints = (0..<100).flatMap { identity -> [ProviderHint] in
            let peer = PeerID(publicKey: String(format: "wire-provider-%03d", identity))
            return (0..<IvyConfig.defaultMaxRoutesPerIdentity).map { route in
                ProviderHint(
                    peer: peer,
                    endpoint: PeerEndpoint(
                        publicKey: peer.publicKey,
                        host: "8.\(identity / 256).\(identity % 256).\(route + 1)",
                        port: UInt16(4000 + route)),
                    expiresAt: expiry,
                    source: peer)
            }
        }

        let records = node.core.providerRecordsForWire(hints)

        XCTAssertEqual(records.count, Int(MessageLimits.maxNeighborCount))
        XCTAssertEqual(Set(records.map(\.endpoint.publicKey)).count, 100)
    }

    private func keptProviders(_ node: Simulation.Node, _ sim: Simulation, announcing announces: [Int]) -> Set<String> {
        for identity in announces {
            let peer = PeerID(publicKey: String(format: "kept-provider-%03d", identity))
            // One shared /16, as hosts behind one proxy appear.
            node.core.storeProviderHint(
                rootCID: "root", peer: peer,
                endpoint: PeerEndpoint(publicKey: peer.publicKey, host: "66.241.\(identity).1", port: 4000),
                expiresAt: sim.unixSeconds + 600)
        }
        return Set(node.core.providerHints["root"]?.map(\.peer.publicKey) ?? [])
    }

    /// A full root keeps the same providers whatever order or how often they
    /// announce: announcing more often buys no place.
    func testAFullRootsProvidersDoNotDependOnWhoAnnouncesMostOften() {
        // The same node each time: a fresh simulation's first node.
        func kept(_ announces: [Int]) -> Set<String> {
            let sim = Simulation()
            return keptProviders(sim.node(), sim, announcing: announces)
        }
        let once = kept(Array(0..<60))
        // Ten of them re-announce after everyone, again and again.
        let often = kept(Array(0..<60) + Array(repeating: Array(40..<50), count: 5).flatMap { $0 })
        let reversed = kept(Array((0..<60).reversed()))
        XCTAssertEqual(once.count, 20)
        XCTAssertEqual(often, once)
        XCTAssertEqual(reversed, once)
    }

    /// Nodes holding the same full root keep different providers of it, so
    /// no provider is named by every one of them.
    func testNodesHoldingAFullRootKeepDifferentProviders() {
        let sim = Simulation()
        let kept = (0..<4).map { _ in keptProviders(sim.node(), sim, announcing: Array(0..<60)) }
        XCTAssertEqual(Set(kept).count, kept.count)
        XCTAssertGreaterThan(kept.reduce(Set()) { $0.union($1) }.count, 20)
    }

    /// "provider identities each receive bounded route failover"
    func testProviderRoutesFailOverPerIdentity() {
        let sim = Simulation()
        let node = sim.discoveryNode(maxContentCandidates: 2, externalAddress: ("8.90.0.1", 4001))
        let first = sim.discoveryKey(index: 0).hex
        let second = sim.discoveryKey(index: 1).hex
        let endpoints = [
            PeerEndpoint(publicKey: first, host: "7.1.0.1", port: 4001),
            PeerEndpoint(publicKey: first, host: "7.2.0.1", port: 4001),
            PeerEndpoint(publicKey: second, host: "7.3.0.1", port: 4001),
            PeerEndpoint(publicKey: second, host: "7.4.0.1", port: 4001),
        ]
        let root = "provider-route-budget"
        for endpoint in endpoints {
            node.core.storeProviderHint(
                rootCID: root,
                peer: PeerID(publicKey: endpoint.publicKey),
                endpoint: endpoint,
                expiresAt: sim.unixSeconds + 60)
        }

        let response = sim.await(volume(root), on: node)?.volume

        XCTAssertEqual(response, .empty)
        XCTAssertEqual(Set(sim.discoveryDials(by: node)), Set(endpoints))
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
    }
}
