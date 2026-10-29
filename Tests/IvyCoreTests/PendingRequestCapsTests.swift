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

    private func volumeFrom(_ peer: FetchRawPeer, _ root: String) -> Request {
        .fetchVolumeFrom(
            peer.authenticated,
            rootCID: root,
            maximumArchiveBytes: MessageLimits.maxVolumeArchiveBytes,
            maximumEntries: Int(MessageLimits.maxVolumeEntryCount))
    }

    private func volume(_ root: String) -> Request {
        .fetchVolume(
            rootCID: root,
            maximumArchiveBytes: MessageLimits.maxVolumeArchiveBytes,
            maximumEntries: Int(MessageLimits.maxVolumeEntryCount))
    }

    /// Distinct requests stop at the global cap.
    func testGlobalCap() {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(1), maxPendingRequests: 2, maxWaitersPerRequest: 8)
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let first = sim.request(volumeFrom(peer, "root-a"), on: node)
        XCTAssertEqual(node.core.pendingVolumeRequests.count, 1)
        let second = sim.request(volumeFrom(peer, "root-b"), on: node)
        XCTAssertEqual(node.core.pendingVolumeRequests.count, 2)

        let rejected = sim.request(volumeFrom(peer, "root-c"), on: node)

        XCTAssertEqual(sim.result(of: rejected, on: node), .volume(.localCapacityUnavailable))
        XCTAssertEqual(sim.now, .zero)
        XCTAssertEqual(node.core.pendingVolumeRequests.count, 2)
        XCTAssertEqual(peer.takeMessages().count, 2)

        sim.stop(node)
        XCTAssertEqual(sim.result(of: first, on: node), .volume(.empty))
        XCTAssertEqual(sim.result(of: second, on: node), .volume(.empty))
        XCTAssertTrue(node.core.pendingVolumeRequests.isEmpty)
    }

    /// Wire requests have one owner and stop at the global cap.
    func testWireRequestOwnership() {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(1), maxPendingRequests: 2, maxWaitersPerRequest: 2)
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let first = sim.request(volumeFrom(peer, "root"), on: node)
        XCTAssertEqual(node.core.pendingVolumeRequests.count, 1)
        // An equal request from an exact session is its own wire request.
        let second = sim.request(volumeFrom(peer, "root"), on: node)
        XCTAssertEqual(node.core.pendingVolumeRequests.count, 2)

        let rejected = sim.request(volumeFrom(peer, "root"), on: node)

        XCTAssertEqual(sim.result(of: rejected, on: node), .volume(.localCapacityUnavailable))
        XCTAssertEqual(sim.now, .zero)
        XCTAssertEqual(node.core.pendingVolumeRequests.count, 2)
        let wire = [peer.takeVolumeRequest(), peer.takeVolumeRequest()].compactMap { $0 }
        XCTAssertEqual(wire.map(\.rootCID), ["root", "root"])
        XCTAssertEqual(Set(wire.map(\.requestID)).count, 2)
        XCTAssertNil(peer.takeVolumeRequest())

        // Each answer goes to the request it names.
        peer.send(.contentUnavailable(requestID: wire[1].requestID))
        XCTAssertEqual(sim.result(of: second, on: node), .volume(.empty))
        XCTAssertNil(sim.result(of: first, on: node))
        sim.stop(node)
        XCTAssertEqual(sim.result(of: first, on: node), .volume(.empty))
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

        // The searches share the root's lookup, and its waiters are bounded too.
        let first = sim.request(.discoverProviders(rootCID: "root"), on: node)
        let second = sim.request(.discoverProviders(rootCID: "root"), on: node)
        let third = sim.request(.discoverProviders(rootCID: "root"), on: node)
        XCTAssertEqual(sim.result(of: third, on: node), .endpoints([]))
        XCTAssertEqual(node.core.lookups.count, 1)
        sim.settleLookups(on: node, answering: peers)
        XCTAssertEqual(node.core.pendingProviderQueries["root"]?.waiters.count, 2)
        let fourth = sim.request(.discoverProviders(rootCID: "root"), on: node)
        XCTAssertEqual(sim.result(of: fourth, on: node), .endpoints([]))

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
    func testPublicFetchProviderCancellation() throws {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(5), maxPendingRequests: 1)
        let peer = FetchRawPeer(sim, to: node, index: 0, advertises: true)

        // The connected peer misses, so the fetch goes on to discovery.
        let fetch = sim.request(volume("cancelled-root"), on: node)
        peer.send(.contentUnavailable(requestID: try XCTUnwrap(peer.takeVolumeRequestID())))
        sim.settleLookups(on: node, answering: [peer])
        XCTAssertNotNil(node.core.pendingProviderQueries["cancelled-root"])
        XCTAssertEqual(peer.takeProviderQuery()?.rootCID, "cancelled-root")
        XCTAssertEqual(node.core.volumeFetches.values.map(\.phase), [.searching])

        sim.cancel(fetch, on: node)
        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty))
        XCTAssertNil(node.core.pendingProviderQueries["cancelled-root"])
        XCTAssertTrue(node.core.volumeFetches.isEmpty)
        XCTAssertTrue(node.core.providerSearches.isEmpty)

        let replacement = sim.request(volume("replacement-root"), on: node)
        peer.send(.contentUnavailable(requestID: try XCTUnwrap(peer.takeVolumeRequestID())))
        // Cancelled while still looking the root up, the lookup goes with it.
        XCTAssertEqual(node.core.lookups.count, 1)
        sim.cancel(replacement, on: node)
        XCTAssertTrue(node.core.lookups.isEmpty)
        XCTAssertEqual(sim.result(of: replacement, on: node), .volume(.empty))
        XCTAssertTrue(node.core.volumeFetches.isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
    }
}
