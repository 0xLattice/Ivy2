import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// The periodic routing refresh, and what each mode leaves switched off.
final class RoutingRefreshAndModeTests: XCTestCase {
    // MARK: - Routing refresh

    /// First at 30 s, then `routingRefreshInterval` after each lookup completes.
    func testRefreshRunsAtThirtySecondsThenAnIntervalAfterEachCompletes() {
        let sim = Simulation()
        let node = sim.discoveryNode(routingRefreshInterval: .seconds(50))
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        XCTAssertEqual(sim.now, .zero)
        XCTAssertEqual(IvyCore.routingRefreshInitialDelay, .seconds(30))

        sim.run(for: .seconds(30) - .milliseconds(1))
        XCTAssertTrue(peer.takeFindNodes().isEmpty)
        sim.run(for: .milliseconds(1))
        let first = peer.takeFindNodes()
        XCTAssertEqual(first.count, 1, "the first refresh starts at 30 s")
        XCTAssertEqual(first.first?.target.count, 32)

        // Unanswered, that lookup ends at 30.5 s; the next is an interval after that.
        sim.run(for: .milliseconds(500) + .seconds(50) - .milliseconds(1))
        XCTAssertTrue(peer.takeFindNodes().isEmpty)
        sim.run(for: .milliseconds(1))
        XCTAssertEqual(sim.now, .milliseconds(80_500))
        let second = peer.takeFindNodes()
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(second.first?.target, first.first?.target, "each refresh looks up a fresh random key")

        // Answered at once, this one completes now: the next is exactly an interval on.
        peer.send(.neighbors([], nonce: second[0].nonce))
        XCTAssertTrue(node.core.lookups.isEmpty)
        sim.run(for: .seconds(50) - .milliseconds(1))
        XCTAssertTrue(peer.takeFindNodes().isEmpty)
        sim.run(for: .milliseconds(1))
        XCTAssertEqual(peer.takeFindNodes().count, 1)
        XCTAssertEqual(sim.now, .milliseconds(130_500))
    }

    /// The refresh follows referrals like any lookup, filling the table.
    func testRefreshConnectsToReferredPeers() {
        let sim = Simulation()
        let node = sim.node()
        let other = sim.node()
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)

        XCTAssertTrue(sim.runServicing(until: { node.core.hasEndpointSession(other.peer) }, timeout: .seconds(40)) {
            peer.answerFindNodes([other.endpoint])
        })
        XCTAssertGreaterThanOrEqual(sim.now, .seconds(30))
        XCTAssertTrue(node.core.knownPeerEndpoints.contains(other.endpoint))
    }

    /// Only overlay mode refreshes.
    func testOnlyOverlayModeRefreshes() {
        let sim = Simulation()
        let pinnedKey = sim.signingKeyHex(scripted: 0)
        let pinned = sim.discoveryNode(mode: .pinned(peer: pinnedKey), routingRefreshInterval: .seconds(50))
        let pinnedPeer = DiscoveryScriptedPeer(sim, to: pinned, index: 0)
        let privateNode = sim.discoveryNode(mode: .privateNetwork, routingRefreshInterval: .seconds(50))
        let privatePeer = DiscoveryScriptedPeer(sim, to: privateNode, index: 1)
        XCTAssertTrue(pinnedPeer.isAuthenticated)
        XCTAssertTrue(privatePeer.isAuthenticated)
        XCTAssertEqual(pinned.core.knownPeerEndpoints, [pinnedPeer.endpoint])

        sim.run(for: .seconds(600))

        XCTAssertTrue(pinnedPeer.takeFindNodes().isEmpty)
        XCTAssertTrue(privatePeer.takeFindNodes().isEmpty)
        XCTAssertFalse(pinned.core.timers.isSet(.routingRefresh))
        XCTAssertFalse(privateNode.core.timers.isSet(.routingRefresh))
        XCTAssertTrue(pinned.core.lookups.isEmpty)
        XCTAssertTrue(privateNode.core.lookups.isEmpty)
    }

    /// A stopped node refreshes nothing, and a restart counts 30 s afresh.
    func testRefreshIsRunScoped() {
        let sim = Simulation()
        let node = sim.discoveryNode(routingRefreshInterval: .seconds(50))
        sim.run(for: .seconds(20))
        sim.stop(node)
        XCTAssertEqual(node.core.diagnostics.deadlines, 0)
        sim.run(for: .seconds(100))
        XCTAssertTrue(node.core.lookups.isEmpty)

        sim.start(node)
        let restarted = sim.now
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        sim.run(for: .seconds(30) - .milliseconds(1))
        XCTAssertTrue(peer.takeFindNodes().isEmpty)
        sim.run(for: .milliseconds(1))
        XCTAssertEqual(peer.takeFindNodes().count, 1)
        XCTAssertEqual(sim.now - restarted, .seconds(30))
    }

    /// A refresh cut short by `stop` does not arm the next one.
    func testStopDuringRefreshArmsNothing() {
        let sim = Simulation()
        let node = sim.discoveryNode(routingRefreshInterval: .seconds(50))
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        sim.run(for: .seconds(30))
        XCTAssertEqual(peer.takeFindNodes().count, 1)
        XCTAssertEqual(node.core.lookups.count, 1)

        sim.stop(node)

        XCTAssertTrue(node.core.lookups.isEmpty)
        XCTAssertEqual(node.core.diagnostics.deadlines, 0)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
    }

    // MARK: - Private network

    /// A private network answers none of the overlay's questions.
    func testPrivateNetworkIgnoresOverlayMessages() {
        let sim = Simulation()
        let node = sim.discoveryNode(mode: .privateNetwork)
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let other = sim.discoveryUnreachableEndpoint(index: 0)
        XCTAssertTrue(peer.isAuthenticated)
        XCTAssertTrue(node.core.knownPeerEndpoints.isEmpty, "a private network keeps no routing table")
        let expiry = sim.unixSeconds + 60

        peer.send(.findNode(target: Data(Router.hash("x")), nonce: 1))
        peer.send(.neighbors([other], nonce: 1))
        peer.send(.findProviders(rootCID: "root", requestID: 2))
        peer.send(.providers(
            rootCID: "root", requestID: 2, records: [ProviderRecord(endpoint: other, expiresAt: expiry)]))
        peer.send(.announceProvider(rootCID: "root", expiresAt: expiry))
        peer.send(.relayOpen(routeID: Data(repeating: 7, count: 32), targetKey: sim.discoveryKey(index: 1)))
        peer.send(.volumeRequest(requestID: 3, rootCID: "root"))
        sim.run(for: .seconds(1))

        peer.poll()
        XCTAssertTrue(peer.inbox.isEmpty, "nothing is answered")
        XCTAssertTrue(node.core.providerHints.isEmpty)
        XCTAssertEqual(node.core.providers(for: "root"), [])
        XCTAssertEqual(node.core.diagnostics.relayRoutes, 0)
        XCTAssertTrue(node.startedJobs.isEmpty)
        XCTAssertTrue(sim.discoveryDials(by: node).isEmpty)

        // The session itself is untouched: keepalive and application messages still flow.
        XCTAssertTrue(node.core.hasEndpointSession(peer.peer))
        peer.send(.ping(nonce: 9))
        XCTAssertEqual(peer.take { message -> UInt64? in
            if case .pong(let nonce) = message { return nonce } else { return nil }
        }, [9])
        peer.send(.peerMessage(topic: "hello", payload: Data("x".utf8)))
        sim.run(for: .zero)
        XCTAssertEqual(node.received.map(\.message), [PeerMessage(topic: "hello", payload: Data("x".utf8))])
    }

    /// A private network runs no discovery, provider records, or broadcast of its own.
    func testPrivateNetworkRunsNoOverlayServices() {
        let sim = Simulation()
        let node = sim.discoveryNode(mode: .privateNetwork, stunServers: [("stun.test", 3478)])
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        XCTAssertFalse(sim.discoveryEffects(of: node).contains(.discoverPublicAddress))
        XCTAssertNil(node.core.publicAddress)

        XCTAssertEqual(sim.await(.findNode(target: peer.key.hex), on: node)?.endpoints, [])
        XCTAssertEqual(sim.await(.discoverProviders(rootCID: "root"), on: node)?.endpoints, [])
        sim.send(.command(.announceProvider(rootCID: "root", expiresAt: sim.unixSeconds + 60)), to: node)
        sim.send(.command(.broadcast(topic: "t", payload: Data("x".utf8))), to: node)
        sim.run(for: .seconds(60))

        peer.poll()
        XCTAssertTrue(peer.inbox.isEmpty)
        XCTAssertTrue(node.core.providerHints.isEmpty)
        XCTAssertEqual(node.core.freshProviderQueryCount, 0)
        XCTAssertTrue(node.core.lookups.isEmpty)

        // Addressed messages are the one thing it carries.
        XCTAssertEqual(
            sim.await(.send(to: peer.peer, topic: "t", payload: Data("x".utf8)), on: node)?.sent,
            .enqueued(endpoint: peer.peer, route: .direct))
        XCTAssertEqual(peer.take { message -> String? in
            if case .peerMessage(let topic, _) = message { return topic } else { return nil }
        }, ["t"])
    }

    /// A private network fetches from nobody unless content exchange is enabled, and never searches.
    func testPrivateNetworkFetchNeverSearchesForProviders() {
        let sim = Simulation()
        let node = sim.discoveryNode(mode: .privateNetwork, privateContentExchangeEnabled: true)
        let server = sim.discoveryNode(mode: .privateNetwork, privateContentExchangeEnabled: true)
        server.volumes["root"] = [ContentEntry(cid: "root", data: Data("r".utf8))]
        sim.connect(node, server)

        let response = sim.await(
            .fetchVolume(rootCID: "root", maximumArchiveBytes: .max, maximumEntries: .max), on: node)?.volume
        XCTAssertEqual(response?.entries, ["root": Data("r".utf8)])
        XCTAssertEqual(response?.servedBy, server.peer)
        XCTAssertEqual(node.core.freshProviderQueryCount, 0)
        XCTAssertTrue(node.core.providerHints.isEmpty)
    }

    // MARK: - Pinned

    /// Pinned mode admits the one identity it names, inbound and outbound.
    func testPinnedModeAdmitsOneIdentity() {
        let sim = Simulation()
        let node = sim.discoveryNode(mode: .pinned(peer: sim.signingKeyHex(scripted: 0)))
        let stranger = DiscoveryScriptedPeer(sim, to: node, index: 1)
        XCTAssertFalse(stranger.isAuthenticated)
        XCTAssertTrue(sim.nodeClosedRaw(stranger.connection))
        XCTAssertEqual(node.core.peerConnectionCount, 0)
        XCTAssertTrue(node.connected.isEmpty)

        let pinned = DiscoveryScriptedPeer(sim, to: node, index: 0)
        XCTAssertTrue(pinned.isAuthenticated)
        XCTAssertEqual(node.core.connectedPeers, [pinned.peer])

        let other = sim.node()
        XCTAssertEqual(sim.await(.connect(other.endpoint), on: node), .connect(.failed(.peerOutsideMode)))
        XCTAssertTrue(sim.discoveryDials(by: node).isEmpty)
        XCTAssertEqual(node.core.connectedPeers, [pinned.peer])
    }

    /// Pinned mode keeps overlay services with its peer but takes no referrals from it.
    func testPinnedModeTakesNoReferrals() {
        let sim = Simulation()
        let node = sim.discoveryNode(mode: .pinned(peer: sim.signingKeyHex(scripted: 0)))
        let pinned = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let other = sim.node()
        let expiry = sim.unixSeconds + 60

        // It answers its peer's lookup.
        pinned.send(.findNode(target: Data(Router.hash("x")), nonce: 5))
        XCTAssertEqual(pinned.takeNeighbors().map(\.nonce), [5])

        let lookup = sim.request(.findNode(target: other.key.hex), on: node)
        XCTAssertEqual(pinned.answerFindNodes([other.endpoint]), 1)
        XCTAssertEqual(sim.result(of: lookup, on: node)?.endpoints, [pinned.endpoint])

        // A provider record naming anyone else is a referral too.
        let search = sim.request(.discoverProviders(rootCID: "root"), on: node)
        XCTAssertEqual(pinned.answerFindProviders([ProviderRecord(endpoint: other.endpoint, expiresAt: expiry)]), 1)
        XCTAssertEqual(sim.result(of: search, on: node)?.endpoints, [])

        // Its peer's own announcement is not a referral.
        pinned.send(.announceProvider(rootCID: "root", expiresAt: expiry))
        XCTAssertEqual(node.core.providers(for: "root"), [pinned.peer])

        sim.run(for: .seconds(2))
        XCTAssertTrue(sim.discoveryDials(by: node).isEmpty)
        XCTAssertTrue(other.core.connectedPeers.isEmpty)
    }
}
