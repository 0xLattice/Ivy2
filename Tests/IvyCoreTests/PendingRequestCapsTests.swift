import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// The bounds on what a node has pending: wire requests, provider queries
/// and the waiters sharing them.
final class PendingRequestCapsTests: XCTestCase {
    /// Wire operation IDs skip zero and live IDs after wrap.
    func testWireOperationIDWrapsWithoutCollision() {
        var core = IvyCore(config: IvyConfig(signingKey: Simulation().signingKey(index: 0), stunServers: []))
        core.nextWireOperationID = .max

        XCTAssertEqual(core.makeWireOperationID(avoiding: [1]), 2)
    }

    /// Distinct selections stop at the global cap.
    func testGlobalCap() {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(1), maxPendingRequests: 2, maxWaitersPerRequest: 8)
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let first = sim.request(.fetchContentFrom(peer.authenticated, rootCID: "root-a", cids: []), on: node)
        XCTAssertEqual(node.core.pendingContentRequests.count, 1)
        let second = sim.request(.fetchContentFrom(peer.authenticated, rootCID: "root-b", cids: []), on: node)
        XCTAssertEqual(node.core.pendingContentRequests.count, 2)

        let rejected = sim.request(.fetchContentFrom(peer.authenticated, rootCID: "root-c", cids: []), on: node)

        XCTAssertEqual(sim.result(of: rejected, on: node), .content(.empty))
        XCTAssertEqual(sim.now, .zero)
        XCTAssertEqual(node.core.pendingContentRequests.count, 2)
        XCTAssertEqual(peer.takeMessages().count, 2)

        sim.stop(node)
        XCTAssertEqual(sim.result(of: first, on: node), .content(.empty))
        XCTAssertEqual(sim.result(of: second, on: node), .content(.empty))
        XCTAssertTrue(node.core.pendingContentRequests.isEmpty)
    }

    /// Wire requests have one owner and stop at the global cap.
    func testWireRequestOwnership() {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(1), maxPendingRequests: 2, maxWaitersPerRequest: 2)
        let peer = FetchRawPeer(sim, to: node, index: 0)
        let firstCIDs = ["child-b", "root", "child-a", "child-b"]
        let equivalentCIDs = ["child-a", "child-b"]
        XCTAssertEqual(
            ContentRequestKey(rootCID: "root", cids: firstCIDs),
            ContentRequestKey(rootCID: "root", cids: equivalentCIDs))

        let first = sim.request(.fetchContentFrom(peer.authenticated, rootCID: "root", cids: firstCIDs), on: node)
        XCTAssertEqual(node.core.pendingContentRequests.count, 1)
        // An equal selection from an exact session is its own wire request.
        let second = sim.request(
            .fetchContentFrom(peer.authenticated, rootCID: "root", cids: equivalentCIDs), on: node)
        XCTAssertEqual(node.core.pendingContentRequests.count, 2)

        let rejected = sim.request(
            .fetchContentFrom(peer.authenticated, rootCID: "root", cids: equivalentCIDs), on: node)

        XCTAssertEqual(sim.result(of: rejected, on: node), .content(.empty))
        XCTAssertEqual(sim.now, .zero)
        XCTAssertEqual(node.core.pendingContentRequests.count, 2)
        let wire = [peer.takeContentRequest(), peer.takeContentRequest()].compactMap { $0 }
        XCTAssertEqual(wire.map(\.cids), [equivalentCIDs, equivalentCIDs])
        XCTAssertEqual(Set(wire.map(\.requestID)).count, 2)
        XCTAssertNil(peer.takeContentRequest())

        // Each answer goes to the request it names.
        peer.send(.contentUnavailable(requestID: wire[1].requestID))
        XCTAssertEqual(sim.result(of: second, on: node), .content(.empty))
        XCTAssertNil(sim.result(of: first, on: node))
        sim.stop(node)
        XCTAssertEqual(sim.result(of: first, on: node), .content(.empty))
    }

    /// Provider queries coalesce, correlate, and aggregate bounded waiters.
    func testProviderQueryAggregation() throws {
        let sim = Simulation()
        let node = sim.fetchNode(maxPendingRequests: 8, maxWaitersPerRequest: 2)

        // Nobody to ask.
        let unreachable = sim.request(.discoverProviders(rootCID: "unreachable"), on: node)
        XCTAssertEqual(sim.result(of: unreachable, on: node), .endpoints([]))
        XCTAssertNil(node.core.pendingProviderQueries["unreachable"])

        let peers = (0..<2).map { FetchRawPeer(sim, to: node, index: $0, advertises: true) }
        let endpoints = peers.map(\.endpoint)
        XCTAssertEqual(Set(node.core.knownPeerEndpoints), Set(endpoints))

        let first = sim.request(.discoverProviders(rootCID: "root"), on: node)
        XCTAssertEqual(node.core.pendingProviderQueries["root"]?.waiters.count, 1)
        let second = sim.request(.discoverProviders(rootCID: "root"), on: node)
        XCTAssertEqual(node.core.pendingProviderQueries["root"]?.waiters.count, 2)
        let third = sim.request(.discoverProviders(rootCID: "root"), on: node)
        XCTAssertEqual(sim.result(of: third, on: node), .endpoints([]))

        // One query on the wire for all of them.
        let requestID = try XCTUnwrap(node.core.pendingProviderQueries["root"]?.requestID)
        for peer in peers {
            XCTAssertEqual(peer.takeProviderQuery()?.requestID, requestID)
            XCTAssertNil(peer.takeProviderQuery())
        }
        let expiry = sim.unixSeconds + 60
        peers[0].send(.providers(
            rootCID: "root",
            requestID: requestID &+ 1,
            records: [ProviderRecord(endpoint: endpoints[0], expiresAt: expiry)]))
        XCTAssertEqual(node.core.pendingProviderQueries["root"]?.waiters.count, 2)
        XCTAssertEqual(node.core.pendingProviderQueries["root"]?.expectedPeers.count, 2)

        peers[0].send(.providers(
            rootCID: "root",
            requestID: requestID,
            records: [ProviderRecord(endpoint: endpoints[0], expiresAt: expiry)]))
        XCTAssertEqual(node.core.pendingProviderQueries["root"]?.requestID, requestID)
        XCTAssertNil(sim.result(of: first, on: node))
        peers[1].send(.providers(
            rootCID: "root",
            requestID: requestID,
            records: [ProviderRecord(endpoint: endpoints[1], expiresAt: expiry)]))

        XCTAssertEqual(sim.result(of: first, on: node)?.endpoints.map(Set.init), Set(endpoints))
        XCTAssertEqual(sim.result(of: second, on: node)?.endpoints.map(Set.init), Set(endpoints))
        XCTAssertNil(node.core.pendingProviderQueries["root"])
        XCTAssertEqual(
            node.core.providerHints["root"]?.first { $0.peer == peers[0].peer }?.expiresAt, expiry)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
    }

    /// Cancelling provider discovery promptly releases the public fetch slot.
    func testPublicFetchProviderCancellation() {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(5), maxPendingRequests: 1)
        let peer = FetchRawPeer(sim, to: node, index: 0, advertises: true)

        let fetch = sim.request(.fetchContent(rootCID: "cancelled-root", cids: []), on: node)
        XCTAssertNotNil(node.core.pendingProviderQueries["cancelled-root"])
        XCTAssertEqual(peer.takeProviderQuery()?.rootCID, "cancelled-root")
        XCTAssertEqual(
            node.core.pendingFetches[ContentRequestKey(rootCID: "cancelled-root", cids: [])]?.phase, .searching)

        sim.cancel(fetch, on: node)
        XCTAssertEqual(sim.result(of: fetch, on: node), .content(.empty))
        XCTAssertNil(node.core.pendingProviderQueries["cancelled-root"])
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertTrue(node.core.providerSearches.isEmpty)

        let replacement = sim.request(.fetchContent(rootCID: "replacement-root", cids: []), on: node)
        XCTAssertNotNil(node.core.pendingProviderQueries["replacement-root"])
        sim.cancel(replacement, on: node)
        XCTAssertEqual(sim.result(of: replacement, on: node), .content(.empty))
        XCTAssertEqual(node.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
    }
}
