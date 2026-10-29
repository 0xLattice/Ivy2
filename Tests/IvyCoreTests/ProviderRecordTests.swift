import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Provider records: announcing, storing, expiring, querying and bounding
/// them (docs/architecture.md "Routing and content", IVY-013 and IVY-014).
final class ProviderRecordTests: XCTestCase {
    private func record(_ endpoint: PeerEndpoint, _ expiresAt: UInt64) -> ProviderRecord {
        ProviderRecord(endpoint: endpoint, expiresAt: expiresAt)
    }

    private func provider(_ sim: Simulation, _ index: Int) -> PeerEndpoint {
        sim.discoveryUnreachableEndpoint(index: index)
    }

    // MARK: - Announcing

    /// The announcer keeps its own record at its advertised address, looks
    /// the root up, and tells the closest peers the lookup reached.
    func testAnnounceStoresOwnRecordAndTellsConnectedPeers() {
        let sim = Simulation()
        let node = sim.discoveryNode(externalAddress: ("8.44.0.1", 5000))
        let routed = (0..<2).map { DiscoveryScriptedPeer(sim, to: node, index: $0) }
        let unrouted = DiscoveryScriptedPeer(sim, to: node, index: 2, listen: [])
        let root = "announce-root"
        let expiry = sim.unixSeconds + 60

        sim.send(.command(.announceProvider(rootCID: root, expiresAt: expiry)), to: node)
        XCTAssertEqual(node.core.lookups.first?.value.targetHash, Router.hash(root))
        XCTAssertTrue(routed.allSatisfy { $0.takeAnnouncements().isEmpty }, "nobody is told before the lookup ends")
        sim.settleLookups(on: node, answering: routed + [unrouted])

        XCTAssertEqual(node.core.providerHints[root], [ProviderHint(
            peer: node.peer,
            endpoint: PeerEndpoint(publicKey: node.key.hex, host: "8.44.0.1", port: 5000),
            expiresAt: expiry,
            source: node.peer)])
        XCTAssertEqual(node.core.providers(for: root), [node.peer])
        for peer in routed {
            let told = peer.takeAnnouncements()
            XCTAssertEqual(told.map(\.rootCID), [root])
            XCTAssertEqual(told.map(\.expiresAt), [expiry])
        }
        XCTAssertTrue(unrouted.takeAnnouncements().isEmpty, "only peers in the routing table are told")
        // Its own record counts against nobody's quota.
        XCTAssertEqual(node.core.providerRecordTotal, 0)
    }

    /// With no advertised address there is no record to keep, but peers are still told.
    func testAnnounceWithoutAdvertisedAddressStoresNothing() {
        let sim = Simulation()
        let node = sim.node()
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let expiry = sim.unixSeconds + 60

        sim.send(.command(.announceProvider(rootCID: "root", expiresAt: expiry)), to: node)
        sim.settleLookups(on: node, answering: [peer])

        XCTAssertNil(node.core.localProviderEndpoint())
        XCTAssertTrue(node.core.providerHints.isEmpty)
        XCTAssertEqual(peer.takeAnnouncements().map(\.rootCID), ["root"])
    }

    /// A discovered public address serves as the record's address, at the listen port.
    func testAnnounceUsesTheDiscoveredPublicAddress() {
        let sim = Simulation()
        let node = sim.discoveryNode(stunServers: [("stun.test", 3478)], start: false)
        node.observedPublicAddress = ObservedAddress(host: "8.8.8.8", port: 59_999)
        sim.start(node)
        sim.run(for: .seconds(1))
        let expiry = sim.unixSeconds + 60

        sim.send(.command(.announceProvider(rootCID: "root", expiresAt: expiry)), to: node)

        XCTAssertEqual(
            node.core.providerHints["root"]?.map(\.endpoint),
            [PeerEndpoint(publicKey: node.key.hex, host: "8.8.8.8", port: 4001)])
    }

    /// Only the `kBucketSize` peers closest to the root are told.
    func testAnnounceTellsOnlyTheClosestPeers() {
        let sim = Simulation()
        let node = sim.node(kBucketSize: 2)
        let peers = (0..<6).map { DiscoveryScriptedPeer(sim, to: node, index: $0) }
        let held = node.core.router.allPeers().map(\.id.publicKey)
        XCTAssertGreaterThan(held.count, 2)
        let root = "closest-root"

        sim.send(.command(.announceProvider(rootCID: root, expiresAt: sim.unixSeconds + 60)), to: node)
        sim.settleLookups(on: node, answering: peers)

        let told = Set(peers.filter { !$0.takeAnnouncements().isEmpty }.map(\.key.hex))
        XCTAssertEqual(told, Set(discoveryClosest(held, to: root).prefix(2)))
    }

    /// An announcement that is expired, too long-lived, or not a usable root goes nowhere.
    func testInvalidLocalAnnouncementIsDropped() {
        let sim = Simulation()
        let node = sim.discoveryNode(maxProviderTTLSeconds: 100, externalAddress: ("8.44.0.1", 5000))
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let now = sim.unixSeconds

        for (root, expiry) in [("past", now - 1), ("now", now), ("far", now + 101), ("", now + 50),
                               ("caf\u{e9}", now + 50)] {
            sim.send(.command(.announceProvider(rootCID: root, expiresAt: expiry)), to: node)
        }
        XCTAssertTrue(node.core.providerHints.isEmpty)
        XCTAssertTrue(node.core.lookups.isEmpty, "nothing is looked up")
        XCTAssertTrue(peer.takeAnnouncements().isEmpty)

        sim.send(.command(.announceProvider(rootCID: "edge", expiresAt: now + 100)), to: node)
        sim.settleLookups(on: node, answering: [peer])
        XCTAssertEqual(node.core.providers(for: "edge"), [node.peer])
        XCTAssertEqual(peer.takeAnnouncements().map(\.rootCID), ["edge"])
    }

    // MARK: - Receiving an announcement

    /// A record is the announcer's own: it names the announcer at the route its session recorded.
    func testReceivedAnnouncementIsStoredForTheAnnouncer() {
        let sim = Simulation()
        let node = sim.node()
        let announcer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let unrouted = DiscoveryScriptedPeer(sim, to: node, index: 1, listen: [])
        let asker = DiscoveryScriptedPeer(sim, to: node, index: 2)
        let expiry = sim.unixSeconds + 60

        announcer.send(.announceProvider(rootCID: "root", expiresAt: expiry))
        unrouted.send(.announceProvider(rootCID: "root", expiresAt: expiry))

        XCTAssertEqual(node.core.providerHints["root"], [
            ProviderHint(peer: announcer.peer, endpoint: announcer.endpoint, expiresAt: expiry, source: announcer.peer),
            ProviderHint(peer: unrouted.peer, endpoint: nil, expiresAt: expiry, source: unrouted.peer),
        ])
        XCTAssertEqual(node.core.providers(for: "root"), [announcer.peer, unrouted.peer])

        // A record with no address is known here but is nothing to hand on.
        asker.send(.findProviders(rootCID: "root", requestID: 77))
        let answer = asker.takeProviders()
        XCTAssertEqual(answer.count, 1)
        XCTAssertEqual(answer.first?.requestID, 77)
        XCTAssertEqual(answer.first?.records, [record(announcer.endpoint, expiry)])
    }

    /// A receiver keeps every valid announcement, wherever the root falls
    /// among the nodes it knows: the announcer chose it as one of the
    /// root's closest, and its quota bounds what it may place.
    func testReceiverStoresEveryValidAnnouncement() {
        let sim = Simulation()
        let node = sim.discoveryNode(kBucketSize: 2, maxProviderRecordsPerPeer: 150)
        let peers = (0..<6).map { DiscoveryScriptedPeer(sim, to: node, index: $0) }
        XCTAssertGreaterThan(node.core.router.allPeers().count, 2)
        let announcer = peers[0]
        let expiry = sim.unixSeconds + 60
        let roots = (0..<200).map { "store-root-\($0)" }

        for root in roots { announcer.send(.announceProvider(rootCID: root, expiresAt: expiry)) }

        XCTAssertEqual(node.core.providerRecordCount(of: announcer.peer), 150, "up to the quota")
        XCTAssertEqual(roots.filter { node.core.providers(for: $0) == [announcer.peer] }.count, 150)
        XCTAssertTrue(node.core.hasEndpointSession(announcer.peer))
    }

    /// A node that knows fewer than k peers keeps whatever it is told.
    func testReceiverWithASparseTableStoresEverything() {
        let sim = Simulation()
        let node = sim.node()
        let announcer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let expiry = sim.unixSeconds + 60
        for index in 0..<50 { announcer.send(.announceProvider(rootCID: "sparse-\(index)", expiresAt: expiry)) }
        XCTAssertEqual(node.core.providerRecordCount(of: announcer.peer), 50)
    }

    // MARK: - Expiry

    /// Records expire by the wall clock, and an expiry outside the allowed window is refused.
    func testRecordsExpireOnTheUnixClock() {
        let sim = Simulation()
        let node = sim.discoveryNode(maxProviderTTLSeconds: 100)
        let announcer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let asker = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let start = sim.unixSeconds

        announcer.send(.announceProvider(rootCID: "past", expiresAt: start - 1))
        announcer.send(.announceProvider(rootCID: "now", expiresAt: start))
        announcer.send(.announceProvider(rootCID: "too-far", expiresAt: start + 101))
        announcer.send(.announceProvider(rootCID: "short", expiresAt: start + 60))
        announcer.send(.announceProvider(rootCID: "longest", expiresAt: start + 100))
        XCTAssertEqual(Set(node.core.providerHints.keys), ["short", "longest"])
        XCTAssertTrue(node.core.hasEndpointSession(announcer.peer), "a refused record is not a violation")

        sim.run(for: .seconds(59))
        sim.discoveryTouch(node)
        XCTAssertEqual(sim.unixSeconds, start + 59)
        XCTAssertEqual(node.core.providers(for: "short"), [announcer.peer])
        asker.send(.findProviders(rootCID: "short", requestID: 1))
        XCTAssertEqual(asker.takeProviders().first?.records, [record(announcer.endpoint, start + 60)])

        sim.run(for: .seconds(1))
        sim.discoveryTouch(node)
        XCTAssertEqual(node.core.providers(for: "short"), [], "a record is gone at its expiry second")
        asker.send(.findProviders(rootCID: "short", requestID: 2))
        XCTAssertEqual(asker.takeProviders().first?.records, [])
        XCTAssertNil(node.core.providerHints["short"])
        XCTAssertEqual(node.core.providers(for: "longest"), [announcer.peer])
        XCTAssertEqual(node.core.providerRecordCount(of: announcer.peer), 1)

        // An expired cached record neither answers a lookup nor survives it.
        sim.run(for: .seconds(40))
        let search = sim.request(.discoverProviders(rootCID: "longest"), on: node)
        XCTAssertNil(node.core.providerHints["longest"])
        sim.settleLookups(on: node, answering: [announcer, asker])
        XCTAssertEqual(announcer.answerFindProviders([]), 1)
        XCTAssertEqual(asker.answerFindProviders([]), 1)
        XCTAssertEqual(sim.result(of: search, on: node)?.endpoints, [])
    }

    // MARK: - Asking the network

    /// Equal queries in flight share one `findProviders` round.
    func testEqualProviderQueriesCoalesce() {
        let sim = Simulation()
        let node = sim.node()
        let responder = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let found = provider(sim, 0)
        let expiry = sim.unixSeconds + 60

        let first = sim.request(.discoverProviders(rootCID: "root"), on: node)
        let second = sim.request(.discoverProviders(rootCID: "root"), on: node)
        let other = sim.request(.discoverProviders(rootCID: "other-root"), on: node)
        XCTAssertEqual(node.core.lookups.count, 2, "one lookup per root")
        sim.settleLookups(on: node, answering: [responder])
        let asked = responder.takeFindProviders()
        XCTAssertEqual(asked.map(\.rootCID), ["root", "other-root"], "one question per root")
        XCTAssertNotEqual(asked[0].requestID, asked[1].requestID)
        XCTAssertEqual(node.core.pendingProviderQueries.count, 2)
        XCTAssertEqual(node.core.pendingProviderQueries["root"]?.waiters.count, 2)

        responder.send(.providers(rootCID: "root", requestID: asked[0].requestID, records: [record(found, expiry)]))
        XCTAssertEqual(sim.result(of: first, on: node)?.endpoints, [found])
        XCTAssertEqual(sim.result(of: second, on: node)?.endpoints, [found])
        XCTAssertNil(sim.result(of: other, on: node))

        responder.send(.providers(rootCID: "other-root", requestID: asked[1].requestID, records: []))
        XCTAssertEqual(sim.result(of: other, on: node)?.endpoints, [])
        XCTAssertTrue(node.core.pendingProviderQueries.isEmpty)
        XCTAssertTrue(node.core.providerSearches.isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)

        // The answer is cached, and names a peer not connected: no further round trip.
        let cached = sim.request(.discoverProviders(rootCID: "root"), on: node)
        XCTAssertEqual(sim.result(of: cached, on: node)?.endpoints, [found])
        XCTAssertTrue(responder.takeFindProviders().isEmpty)
    }

    /// Cancelling one of two coalesced queries leaves the round to the other.
    func testCancellingOneCoalescedQueryKeepsTheRound() {
        let sim = Simulation()
        let node = sim.node()
        let responder = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let found = provider(sim, 0)

        let first = sim.request(.discoverProviders(rootCID: "root"), on: node)
        let second = sim.request(.discoverProviders(rootCID: "root"), on: node)
        sim.cancel(first, on: node)
        XCTAssertEqual(sim.result(of: first, on: node)?.endpoints, [])
        XCTAssertEqual(node.core.lookups.count, 1, "the lookup is left to the other")
        sim.settleLookups(on: node, answering: [responder])
        XCTAssertNotNil(node.core.pendingProviderQueries["root"])

        XCTAssertEqual(responder.answerFindProviders([record(found, sim.unixSeconds + 60)]), 1)
        XCTAssertEqual(sim.result(of: second, on: node)?.endpoints, [found])

        // Cancelling the last one ends the round and its deadline.
        let third = sim.request(.discoverProviders(rootCID: "lonely-root"), on: node)
        sim.settleLookups(on: node, answering: [responder])
        XCTAssertTrue(node.core.timers.isSet(.providerQuery("lonely-root")))
        sim.cancel(third, on: node)
        XCTAssertEqual(sim.result(of: third, on: node)?.endpoints, [])
        XCTAssertTrue(node.core.pendingProviderQueries.isEmpty)
        XCTAssertFalse(node.core.timers.isSet(.providerQuery("lonely-root")))
    }

    /// An answer with the wrong request ID, or from a peer that was not asked, is ignored;
    /// a responder that never answers costs 500 ms.
    func testOnlyTheAskedPeersAnswerAndSilenceCostsHalfASecond() {
        let sim = Simulation()
        let node = sim.node()
        let asked = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let silent = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let bystander = DiscoveryScriptedPeer(sim, to: node, index: 2, listen: [])
        let honest = provider(sim, 0)
        let forged = provider(sim, 1)
        let expiry = sim.unixSeconds + 60

        // Nobody asked: nothing is stored.
        asked.send(.providers(rootCID: "root", requestID: 1, records: [record(forged, expiry)]))
        XCTAssertTrue(node.core.providerHints.isEmpty)

        let started = sim.now
        let search = sim.request(.discoverProviders(rootCID: "root"), on: node)
        sim.settleLookups(on: node, answering: [asked, silent, bystander])
        guard let requestID = asked.takeFindProviders().first?.requestID else { return XCTFail("not asked") }
        XCTAssertEqual(silent.takeFindProviders().count, 1)
        XCTAssertTrue(bystander.takeFindProviders().isEmpty)

        bystander.send(.providers(rootCID: "root", requestID: requestID, records: [record(forged, expiry)]))
        asked.send(.providers(rootCID: "root", requestID: requestID &+ 1, records: [record(forged, expiry)]))
        asked.send(.providers(rootCID: "another-root", requestID: requestID, records: [record(forged, expiry)]))
        XCTAssertEqual(node.core.pendingProviderQueries["root"]?.expectedPeers.count, 2)

        asked.send(.providers(rootCID: "root", requestID: requestID, records: [record(honest, expiry)]))
        // A second answer from the same peer is no longer expected.
        asked.send(.providers(rootCID: "root", requestID: requestID, records: [record(forged, expiry)]))
        XCTAssertNil(sim.result(of: search, on: node), "one responder is still awaited")

        XCTAssertTrue(sim.run(until: { sim.result(of: search, on: node) != nil }, timeout: .seconds(5)))
        XCTAssertEqual(sim.now - started, .milliseconds(500))
        XCTAssertEqual(sim.result(of: search, on: node)?.endpoints, [honest])
        XCTAssertEqual(node.core.providers(for: "root"), [PeerID(publicKey: honest.publicKey)])
        XCTAssertEqual(node.core.peerConnectionCount, 3)
    }

    /// A responder that disconnects is no longer awaited.
    func testDisconnectingResponderEndsTheWait() {
        let sim = Simulation()
        let node = sim.node()
        let leaving = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let search = sim.request(.discoverProviders(rootCID: "root"), on: node)
        sim.settleLookups(on: node, answering: [leaving])
        XCTAssertEqual(leaving.takeFindProviders().count, 1)

        leaving.close()

        XCTAssertEqual(sim.result(of: search, on: node)?.endpoints, [])
        XCTAssertTrue(node.core.pendingProviderQueries.isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
    }

    /// Records in an answer are referrals: each must name someone else at a
    /// routable address with a valid expiry.
    func testProviderAnswersAreFilteredLikeReferrals() {
        let sim = Simulation()
        let node = sim.discoveryNode(maxProviderTTLSeconds: 100)
        let responder = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let now = sim.unixSeconds
        let good = provider(sim, 0)
        let padded = PeerEndpoint(publicKey: sim.discoveryKey(index: 9).hex, host: " 8.60.0.1 ", port: 4001)
        let records = [
            record(PeerEndpoint(publicKey: sim.discoveryKey(index: 1).hex, host: "10.0.0.1", port: 4001), now + 60),
            record(PeerEndpoint(publicKey: sim.discoveryKey(index: 2).hex, host: "127.0.0.1", port: 4001), now + 60),
            record(PeerEndpoint(publicKey: sim.discoveryKey(index: 3).hex, host: "provider.example", port: 4001), now + 60),
            record(PeerEndpoint(publicKey: sim.discoveryKey(index: 4).hex, host: "8.61.0.1", port: 0), now + 60),
            record(PeerEndpoint(publicKey: "not-a-key", host: "8.62.0.1", port: 4001), now + 60),
            record(PeerEndpoint(publicKey: node.key.hex, host: "8.63.0.1", port: 4001), now + 60),
            record(provider(sim, 5), now),
            record(provider(sim, 6), now + 101),
            record(good, now + 100),
            record(padded, now + 60),
        ]

        let search = sim.request(.discoverProviders(rootCID: "root"), on: node)
        sim.settleLookups(on: node, answering: [responder])
        XCTAssertEqual(responder.answerFindProviders(records), 1)

        XCTAssertEqual(
            sim.result(of: search, on: node)?.endpoints,
            [good, PeerEndpoint(publicKey: padded.publicKey, host: "8.60.0.1", port: 4001)])
        XCTAssertEqual(node.core.providers(for: "root").count, 2)
        XCTAssertTrue(node.core.hasEndpointSession(responder.peer))
    }

    /// A query first looks the root up, reaching peers it has no session with.
    func testQueryLooksTheRootUpFirst() {
        let sim = Simulation()
        let node = sim.node()
        let holder = sim.node()
        let found = provider(sim, 0)
        holder.core.storeProviderHint(
            rootCID: "root", peer: PeerID(publicKey: found.publicKey), endpoint: found,
            expiresAt: sim.unixSeconds + 60)
        // A route with no session behind it: nobody to ask until the lookup connects.
        node.core.router.addPeer(holder.peer, endpoint: holder.endpoint)
        XCTAssertFalse(node.core.hasEndpointSession(holder.peer))

        let search = sim.request(.discoverProviders(rootCID: "root"), on: node)
        XCTAssertEqual(node.core.lookups.count, 1)
        XCTAssertEqual(node.core.lookups.first?.value.targetHash, Router.hash("root"))
        XCTAssertEqual(node.core.pendingProviderQueries["root"]?.walking, true)
        XCTAssertEqual(node.core.pendingProviderQueries["root"]?.expectedPeers, [], "nobody to ask yet")

        XCTAssertTrue(sim.run(until: { sim.result(of: search, on: node) != nil }, timeout: .seconds(5)))
        XCTAssertEqual(sim.result(of: search, on: node)?.endpoints, [found])
        XCTAssertTrue(node.core.hasEndpointSession(holder.peer))
        XCTAssertTrue(node.core.lookups.isEmpty)
        XCTAssertEqual(node.core.freshProviderQueryCount, 1)
    }

    /// With nobody to ask even after the lookup, the answer is empty and immediate.
    func testQueryWithNobodyToAskAnswersEmpty() {
        let sim = Simulation()
        let node = sim.node()
        let search = sim.request(.discoverProviders(rootCID: "root"), on: node)
        XCTAssertEqual(sim.result(of: search, on: node)?.endpoints, [])
        XCTAssertEqual(node.core.freshProviderQueryCount, 1)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)

        // A root that cannot go on the wire is never looked up.
        XCTAssertEqual(sim.await(.discoverProviders(rootCID: ""), on: node)?.endpoints, [])
        XCTAssertEqual(node.core.freshProviderQueryCount, 1)
    }

    /// Cancelling a query that is still looking its root up cancels the lookup and its dial.
    func testCancellingAQueryCancelsItsLookup() {
        let sim = Simulation()
        let node = sim.node()
        let holder = sim.node()
        node.core.router.addPeer(holder.peer, endpoint: holder.endpoint)

        let search = sim.request(.discoverProviders(rootCID: "root"), on: node)
        XCTAssertEqual(node.core.lookups.count, 1)
        sim.cancel(search, on: node)

        XCTAssertEqual(sim.result(of: search, on: node)?.endpoints, [])
        XCTAssertTrue(node.core.lookups.isEmpty)
        XCTAssertTrue(node.core.providerSearches.isEmpty)
        sim.run(for: .seconds(2))
        XCTAssertFalse(node.core.hasEndpointSession(holder.peer))
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertTrue(holder.core.connectedPeers.isEmpty)
    }

    /// Search is one walk: every peer the walk asks for closer peers is
    /// asked for providers in the same round, once.
    func testEveryPeerTheWalkAsksIsAskedForProviders() {
        let sim = Simulation()
        let node = sim.node()
        let peers = (0..<9).map { DiscoveryScriptedPeer(sim, to: node, index: $0) }

        _ = sim.request(.discoverProviders(rootCID: "walk-root"), on: node)
        let firstRound = peers.filter { !$0.takeFindProviders().isEmpty }.map(\.key.hex)
        XCTAssertEqual(
            Set(firstRound),
            Set(discoveryClosest(peers.map(\.key.hex), to: "walk-root").prefix(IvyCore.kademliaLookupParallelism)))
        sim.settleLookups(on: node, answering: peers)

        let later = peers.filter { !$0.takeFindProviders().isEmpty }.map(\.key.hex)
        XCTAssertEqual(Set(firstRound + later), Set(peers.map(\.key.hex)))
        XCTAssertEqual(firstRound.count + later.count, peers.count, "each is asked once")
        XCTAssertEqual(node.core.pendingProviderQueries["walk-root"]?.expectedPeers.count, peers.count)
    }

    /// Answers from the walk's first round, however many providers they
    /// name, do not end it: the walk still reaches the peers nearer the root.
    func testAFloodOfProvidersDoesNotEndTheWalk() {
        let sim = Simulation()
        let node = sim.discoveryNode()
        let peers = (0..<6).map { DiscoveryScriptedPeer(sim, to: node, index: $0) }
        let expiry = sim.unixSeconds + 60

        let search = sim.request(.discoverProviders(rootCID: "flood-root"), on: node)
        let first = peers.filter { !$0.takeFindProviders().isEmpty }
        XCTAssertEqual(first.count, IvyCore.kademliaLookupParallelism)
        let requestID = node.core.pendingProviderQueries["flood-root"]!.requestID
        for (index, peer) in first.enumerated() {
            peer.send(.providers(
                rootCID: "flood-root", requestID: requestID,
                records: (0..<20).map { record(provider(sim, index * 20 + $0), expiry) }))
        }
        XCTAssertNil(sim.result(of: search, on: node), "the walk is still running")
        XCTAssertFalse(node.core.lookups.isEmpty)

        sim.settleLookups(on: node, answering: peers)
        let rest = peers.filter { peer in !first.contains { $0 === peer } }
        XCTAssertTrue(rest.allSatisfy { $0.answerFindProviders([]) == 1 }, "every peer walked is asked")
        XCTAssertNotNil(sim.result(of: search, on: node))
    }

    /// In a star, where every leaf holds a session with the hub alone, an
    /// announcement reaches the leaves closest to the root and a search from
    /// another leaf finds it there: neither stops at the peers it is connected to.
    func testAnnounceAndSearchReachTheClosestPeersBeyondTheirSessions() {
        let sim = Simulation(seed: 7)
        let k = 3
        let hub = sim.node(kBucketSize: k)
        let leaves = (0..<12).map { _ in sim.node(kBucketSize: k) }
        for leaf in leaves { sim.connect(leaf, hub) }
        let announcer = leaves[0]
        // Two hops reach the hub and the leaves its buckets hold.
        let reachable = ([hub.key.hex] + hub.core.router.allPeers().map(\.id.publicKey))
            .filter { $0 != announcer.key.hex }

        // A root whose closest nodes are all leaves the announcer has never met.
        let root = (0..<1000).map { "star-root-\($0)" }.first { root in
            !discoveryClosest(reachable, to: root).prefix(k).contains(hub.key.hex)
        }!
        let closest = discoveryClosest(reachable, to: root).prefix(k)
        let holders = leaves.filter { closest.contains($0.key.hex) }
        XCTAssertEqual(announcer.core.connectedPeers, [hub.peer])

        sim.send(.command(.announceProvider(rootCID: root, expiresAt: sim.unixSeconds + 600)), to: announcer)
        XCTAssertTrue(sim.run(until: {
            holders.allSatisfy { $0.core.providers(for: root).contains(announcer.peer) }
        }, timeout: .seconds(5)))
        XCTAssertEqual(hub.core.providers(for: root), [], "the hub is not among the closest")

        let reader = leaves.first { $0.peer != announcer.peer && !closest.contains($0.key.hex) }!
        XCTAssertEqual(reader.core.connectedPeers, [hub.peer])
        let found = sim.await(.discoverProviders(rootCID: root), on: reader, timeout: .seconds(5))?.endpoints
        XCTAssertEqual(found?.map(\.publicKey), [announcer.key.hex])
    }

    /// Fetches that find nobody each search once, and searches for one root
    /// that overlap share one question on the wire.
    func testFetchRunsAtMostOneFreshQuery() {
        let sim = Simulation()
        let node = sim.node()
        let responder = DiscoveryScriptedPeer(sim, to: node, index: 0)

        let missing = Request.fetchVolume(
            rootCID: "missing-root",
            maximumArchiveBytes: MessageLimits.maxVolumeArchiveBytes,
            maximumEntries: Int(MessageLimits.maxVolumeEntryCount))
        let first = sim.request(missing, on: node)
        let second = sim.request(missing, on: node)
        var questions = 0
        XCTAssertTrue(sim.runServicing(until: {
            sim.result(of: first, on: node) != nil && sim.result(of: second, on: node) != nil
        }) {
            responder.answerFindNodes([])
            questions += responder.answerFindProviders([])
            for request in responder.take({ message -> UInt64? in
                if case .volumeRequest(let id, _) = message { return id } else { return nil }
            }) {
                responder.send(.contentUnavailable(requestID: request))
            }
        })

        XCTAssertEqual(sim.result(of: first, on: node)?.volume, .empty)
        XCTAssertEqual(sim.result(of: second, on: node)?.volume, .empty)
        XCTAssertEqual(questions, 1)
        XCTAssertEqual(node.core.freshProviderQueryCount, 2)
        XCTAssertTrue(node.core.providerSearches.isEmpty)
    }

    // MARK: - Bounds and precedence

    /// A root keeps at most `kBucketSize` providers and `maxRoutesPerIdentity` routes for each.
    func testRootIsBoundedPerIdentityAndPerRoot() {
        let sim = Simulation()
        let node = sim.discoveryNode(kBucketSize: 4, maxRoutesPerIdentity: 2)
        let responder = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let expiry = sim.unixSeconds + 60
        let records = (0..<10).flatMap { identity in
            (0..<5).map { route in
                self.record(
                    PeerEndpoint(
                        publicKey: sim.discoveryKey(index: identity).hex,
                        host: "8.\(100 + identity).0.\(route + 1)",
                        port: 4001),
                    expiry)
            }
        }

        let search = sim.request(.discoverProviders(rootCID: "root"), on: node)
        sim.settleLookups(on: node, answering: [responder])
        XCTAssertEqual(responder.answerFindProviders(records), 1)

        let result = sim.result(of: search, on: node)?.endpoints ?? []
        XCTAssertEqual(Set(result.map(\.publicKey)).count, 4)
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(node.core.providers(for: "root").count, 4)
        XCTAssertEqual(node.core.providerHints["root"]?.count, 8)
        for (_, routes) in Dictionary(grouping: node.core.providerHints["root"] ?? [], by: \.peer) {
            XCTAssertEqual(routes.count, 2)
        }
    }

    /// A full root sheds a referred-only provider before one that announced itself.
    func testFullRootKeepsAnnouncementsOverReferrals() {
        let sim = Simulation()
        let node = sim.discoveryNode(kBucketSize: 2)
        let announcer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let expiry = sim.unixSeconds + 60
        announcer.send(.announceProvider(rootCID: "root", expiresAt: expiry))
        XCTAssertEqual(node.core.providers(for: "root"), [announcer.peer])

        let search = sim.request(.discoverProviders(rootCID: "root"), on: node)
        sim.settleLookups(on: node, answering: [announcer])
        XCTAssertEqual(announcer.answerFindProviders((0..<2).map { record(provider(sim, $0), expiry) }), 1)
        XCTAssertNotNil(sim.result(of: search, on: node))

        let kept = node.core.providers(for: "root")
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.contains(announcer.peer), "the announced record outlives the referrals that filled the root")
        XCTAssertTrue(kept.contains(PeerID(publicKey: provider(sim, 1).publicKey)))
    }

    /// A referral never overrides what a provider announced for itself, and
    /// an announcement replaces the routes others referred for it.
    func testReferralNeverOverridesAnAnnouncement() {
        let sim = Simulation()
        let node = sim.node()
        let announcer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let referrer = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let later = DiscoveryScriptedPeer(sim, to: node, index: 2)
        let expiry = sim.unixSeconds + 60
        let forged = PeerEndpoint(publicKey: announcer.key.hex, host: "8.99.0.1", port: 4001)
        let referredRoute = PeerEndpoint(publicKey: later.key.hex, host: "8.98.0.1", port: 4001)

        announcer.send(.announceProvider(rootCID: "root", expiresAt: expiry))
        let announced = ProviderHint(
            peer: announcer.peer, endpoint: announcer.endpoint, expiresAt: expiry, source: announcer.peer)
        XCTAssertEqual(node.core.providerHints["root"], [announced])

        // Every record names a connected peer, so the network is asked.
        let search = sim.request(.discoverProviders(rootCID: "root"), on: node)
        sim.settleLookups(on: node, answering: [announcer, referrer, later])
        XCTAssertEqual(referrer.answerFindProviders([record(forged, expiry + 10), record(referredRoute, expiry)]), 1)
        XCTAssertEqual(announcer.answerFindProviders([]), 1)
        XCTAssertEqual(later.answerFindProviders([]), 1)
        XCTAssertNotNil(sim.result(of: search, on: node))

        XCTAssertEqual(node.core.providerHints["root"], [
            announced,
            ProviderHint(peer: later.peer, endpoint: referredRoute, expiresAt: expiry, source: referrer.peer),
        ])
        XCTAssertEqual(node.core.providerRecordCount(of: referrer.peer), 1)

        // The referred peer announces: its own record supersedes the referral.
        later.send(.announceProvider(rootCID: "root", expiresAt: expiry))
        XCTAssertEqual(node.core.providerHints["root"], [
            announced,
            ProviderHint(peer: later.peer, endpoint: later.endpoint, expiresAt: expiry, source: later.peer),
        ])
        XCTAssertEqual(node.core.providerRecordCount(of: referrer.peer), 0)
        XCTAssertEqual(node.core.providerRecordTotal, 2)
    }

    /// At its quota a source gives up its soonest-expiring record for a new announcement.
    func testPerSourceQuotaEvictsTheSoonestExpiring() {
        let sim = Simulation()
        let node = sim.discoveryNode(maxProviderRecordsPerPeer: 2)
        let announcer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let other = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let now = sim.unixSeconds

        other.send(.announceProvider(rootCID: "theirs", expiresAt: now + 10))
        announcer.send(.announceProvider(rootCID: "r1", expiresAt: now + 100))
        announcer.send(.announceProvider(rootCID: "r2", expiresAt: now + 50))
        XCTAssertEqual(node.core.providerRecordCount(of: announcer.peer), 2)

        announcer.send(.announceProvider(rootCID: "r3", expiresAt: now + 200))

        XCTAssertEqual(node.core.providerRecordCount(of: announcer.peer), 2)
        XCTAssertEqual(node.core.providers(for: "r1"), [announcer.peer])
        XCTAssertEqual(node.core.providers(for: "r2"), [])
        XCTAssertEqual(node.core.providers(for: "r3"), [announcer.peer])
        XCTAssertEqual(node.core.providers(for: "theirs"), [other.peer], "one source's quota costs another nothing")

        // Re-announcing a root it already holds takes no extra slot.
        announcer.send(.announceProvider(rootCID: "r3", expiresAt: now + 300))
        XCTAssertEqual(node.core.providers(for: "r1"), [announcer.peer])
        XCTAssertEqual(node.core.providerHints["r3"]?.map(\.expiresAt), [now + 300])
        XCTAssertEqual(node.core.providerRecordTotal, 3)
    }

    /// At its quota a source's referral displaces its own earlier referral,
    /// but never an announcement: then the referral is the one dropped.
    func testReferralNeverEvictsAnAnnouncement() {
        let sim = Simulation()
        let node = sim.discoveryNode(maxProviderRecordsPerPeer: 2)
        let source = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let now = sim.unixSeconds
        func refer(_ root: String, _ endpoint: PeerEndpoint) -> [PeerEndpoint]? {
            let search = sim.request(.discoverProviders(rootCID: root), on: node)
            sim.settleLookups(on: node, answering: [source])
            XCTAssertEqual(source.answerFindProviders([record(endpoint, now + 60)]), 1)
            return sim.result(of: search, on: node)?.endpoints
        }

        source.send(.announceProvider(rootCID: "announced-1", expiresAt: now + 100))
        XCTAssertEqual(refer("referred-1", provider(sim, 0)), [provider(sim, 0)])
        XCTAssertEqual(node.core.providerRecordCount(of: source.peer), 2)

        // A second referral takes the place of the first, not of the announcement.
        XCTAssertEqual(refer("referred-2", provider(sim, 1)), [provider(sim, 1)])
        XCTAssertEqual(node.core.providers(for: "referred-1"), [])
        XCTAssertEqual(node.core.providers(for: "referred-2"), [PeerID(publicKey: provider(sim, 1).publicKey)])
        XCTAssertEqual(node.core.providers(for: "announced-1"), [source.peer])

        // An announcement takes the referral's place.
        source.send(.announceProvider(rootCID: "announced-2", expiresAt: now + 200))
        XCTAssertEqual(node.core.providers(for: "referred-2"), [])
        XCTAssertEqual(node.core.providers(for: "announced-2"), [source.peer])

        // Only announcements are left: a referral is dropped rather than evict one.
        XCTAssertEqual(
            refer("referred-3", provider(sim, 2)), [provider(sim, 2)],
            "the caller still gets the answer it asked for")
        XCTAssertEqual(node.core.providers(for: "referred-3"), [])
        XCTAssertEqual(node.core.providers(for: "announced-1"), [source.peer])
        XCTAssertEqual(node.core.providers(for: "announced-2"), [source.peer])
        XCTAssertEqual(node.core.providerRecordCount(of: source.peer), 2)
    }

    /// The whole table holds `maxConnections * maxProviderRecordsPerPeer` records; past
    /// that the source holding the most gives one up.
    func testTableCeilingEvictsFromTheHeaviestSource() {
        let sim = Simulation()
        let node = sim.discoveryNode(maxConnections: 2, maxProviderRecordsPerPeer: 2)
        XCTAssertEqual(node.core.config.maxProviderRecords, 4)
        let now = sim.unixSeconds

        // Sources come and go; their records stay until they expire.
        let heavy = DiscoveryScriptedPeer(sim, to: node, index: 0)
        heavy.send(.announceProvider(rootCID: "heavy-1", expiresAt: now + 100))
        heavy.send(.announceProvider(rootCID: "heavy-2", expiresAt: now + 50))
        heavy.close()
        let light = DiscoveryScriptedPeer(sim, to: node, index: 1)
        light.send(.announceProvider(rootCID: "light-1", expiresAt: now + 10))
        light.close()
        let third = DiscoveryScriptedPeer(sim, to: node, index: 2)
        third.send(.announceProvider(rootCID: "third-1", expiresAt: now + 10))
        third.close()
        XCTAssertEqual(node.core.providerRecordTotal, 4)

        let newcomer = DiscoveryScriptedPeer(sim, to: node, index: 3)
        XCTAssertTrue(newcomer.isAuthenticated)
        newcomer.send(.announceProvider(rootCID: "new-1", expiresAt: now + 100))

        XCTAssertEqual(node.core.providerRecordTotal, 4)
        XCTAssertEqual(node.core.providers(for: "new-1"), [newcomer.peer])
        XCTAssertEqual(node.core.providers(for: "heavy-2"), [], "the heaviest source lost its soonest-expiring record")
        XCTAssertEqual(node.core.providers(for: "heavy-1"), [heavy.peer])
        XCTAssertEqual(node.core.providers(for: "light-1"), [light.peer])
        XCTAssertEqual(node.core.providers(for: "third-1"), [third.peer])
    }

    /// `findProviders` is answered from the table, in a fixed order, with this node's own record among them.
    func testFindProvidersIsAnsweredFromTheTable() {
        let sim = Simulation()
        let node = sim.discoveryNode(externalAddress: ("8.44.0.1", 5000))
        let announcer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let asker = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let expiry = sim.unixSeconds + 60
        announcer.send(.announceProvider(rootCID: "root", expiresAt: expiry))
        sim.send(.command(.announceProvider(rootCID: "root", expiresAt: expiry + 5)), to: node)
        sim.settleLookups(on: node, answering: [announcer, asker])
        _ = asker.takeAnnouncements()

        asker.send(.findProviders(rootCID: "root", requestID: 42))
        asker.send(.findProviders(rootCID: "unknown-root", requestID: 43))

        let answers = asker.takeProviders()
        XCTAssertEqual(answers.map(\.requestID), [42, 43])
        XCTAssertEqual(answers.map(\.rootCID), ["root", "unknown-root"])
        let own = record(PeerEndpoint(publicKey: node.key.hex, host: "8.44.0.1", port: 5000), expiry + 5)
        let theirs = record(announcer.endpoint, expiry)
        XCTAssertEqual(
            answers[0].records,
            [own, theirs].sorted { $0.endpoint.publicKey < $1.endpoint.publicKey })
        XCTAssertEqual(answers[1].records, [])
    }
}

/// How far provider walks reach, what they may dial, and what an
/// announcement does when its walk ends.
final class ProviderWalkTests: XCTestCase {
    private func star(_ sim: Simulation, leaves count: Int) -> (hub: Simulation.Node, leaves: [Simulation.Node]) {
        let hub = sim.node()
        let leaves = (0..<count).map { _ in sim.node() }
        for leaf in leaves { sim.connect(leaf, hub) }
        return (hub, leaves)
    }

    /// Kept among connected peers, an announcement dials no one and tells
    /// the closest it is already connected to.
    func testConnectedPeersReachNeverDials() {
        let sim = Simulation(seed: 5)
        let (hub, leaves) = star(sim, leaves: 8)
        let node = sim.discoveryNode(providerReach: .connectedPeers)
        sim.connect(node, hub)
        let dialsBefore = sim.discoveryDials(by: node).count

        sim.send(.command(.announceProvider(rootCID: "kept-close", expiresAt: sim.unixSeconds + 60)), to: node)
        XCTAssertTrue(sim.run(until: { hub.core.providers(for: "kept-close") == [node.peer] }, timeout: .seconds(5)))

        XCTAssertEqual(sim.discoveryDials(by: node).count, dialsBefore)
        XCTAssertEqual(node.core.connectedPeers, [hub.peer])
        XCTAssertTrue(leaves.allSatisfy { $0.core.providers(for: "kept-close").isEmpty })
        XCTAssertTrue(node.core.providerWalkSessions.isEmpty)
    }

    /// A walk dials at most `maxProviderWalkSessions` peers, and the node can
    /// tell those sessions from the ones it or its peers opened.
    func testWalkDialsStayWithinTheirBudget() throws {
        let sim = Simulation(seed: 5)
        let (hub, _) = star(sim, leaves: 10)
        let node = sim.discoveryNode(maxProviderWalkSessions: 2)
        sim.connect(node, hub)

        XCTAssertNotNil(sim.await(.discoverProviders(rootCID: "budget-root"), on: node, timeout: .seconds(5)))

        XCTAssertEqual(node.core.providerWalkSessions.count, 2)
        XCTAssertEqual(node.core.peerConnectionCount, 3)
        let hubSession = try XCTUnwrap(node.core.authenticatedPeer(for: hub.peer))
        XCTAssertFalse(node.core.isProviderWalkSession(hubSession))
        for key in node.core.providerWalkSessions.keys {
            let session = try XCTUnwrap(node.core.authenticatedPeer(for: key.peerID))
            XCTAssertTrue(node.core.isProviderWalkSession(session))
        }
    }

    /// A walk never dials into the slots held for outbound configured peers.
    func testWalkDialsLeaveTheReservedSlots() {
        let sim = Simulation(seed: 5)
        let (hub, _) = star(sim, leaves: 10)
        let node = sim.discoveryNode(maxConnections: 4, reservedOutboundConnectionSlots: 2)
        sim.connect(node, hub)

        XCTAssertNotNil(sim.await(.discoverProviders(rootCID: "reserved-root"), on: node, timeout: .seconds(5)))

        XCTAssertEqual(node.core.peerConnectionCount, 2, "the hub and one walk dial, leaving two slots")
        XCTAssertEqual(node.core.providerWalkSessions.count, 1)
    }

    /// Stopping a root mid-walk drops this node's record and the
    /// announcement the walk would have sent.
    func testStopProvidingWithdrawsAnUnsentAnnouncement() {
        let sim = Simulation()
        let node = sim.discoveryNode(externalAddress: ("8.44.0.1", 5000))
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)

        sim.send(.command(.announceProvider(rootCID: "withdrawn", expiresAt: sim.unixSeconds + 60)), to: node)
        XCTAssertEqual(node.core.providers(for: "withdrawn"), [node.peer])
        sim.send(.command(.stopProviding(rootCID: "withdrawn")), to: node)
        sim.settleLookups(on: node, answering: [peer])

        XCTAssertTrue(peer.takeAnnouncements().isEmpty)
        XCTAssertEqual(node.core.providers(for: "withdrawn"), [])
        XCTAssertTrue(node.core.announceWalks.isEmpty)
    }

    /// Announcing a root again while its walk runs joins that walk, which
    /// announces the newest expiry once.
    func testRepeatedAnnouncementsShareOneWalk() {
        let sim = Simulation()
        let node = sim.discoveryNode()
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let expiry = sim.unixSeconds + 60

        sim.send(.command(.announceProvider(rootCID: "again", expiresAt: expiry)), to: node)
        sim.send(.command(.announceProvider(rootCID: "again", expiresAt: expiry + 30)), to: node)
        XCTAssertEqual(node.core.lookups.count, 1)
        sim.settleLookups(on: node, answering: [peer])

        XCTAssertEqual(peer.takeAnnouncements().map(\.expiresAt), [expiry + 30])
    }

    /// When no one the walk asked answered, the closest peers already
    /// connected are told, so the announcement is not lost.
    func testAnAnnouncementNobodyAnsweredGoesToConnectedPeers() {
        let sim = Simulation()
        let node = sim.discoveryNode()
        let silent = DiscoveryScriptedPeer(sim, to: node, index: 0)

        sim.send(.command(.announceProvider(rootCID: "unanswered", expiresAt: sim.unixSeconds + 60)), to: node)
        XCTAssertEqual(silent.takeFindNodes().count, 1)
        sim.run(for: IvyCore.lookupResponseTimeout)

        XCTAssertTrue(node.core.lookups.isEmpty)
        XCTAssertEqual(silent.takeAnnouncements().map(\.rootCID), ["unanswered"])
    }

    /// A peer that timed out is not asked again on a route it was already
    /// tried on, however often it is referred.
    func testATimedOutPeerIsNotAskedAgainOnTheSameRoute() {
        let sim = Simulation()
        let node = sim.node()
        let silent = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let referrer = DiscoveryScriptedPeer(sim, to: node, index: 1)

        let lookup = sim.request(.findNode(target: "retry-target"), on: node)
        XCTAssertEqual(silent.takeFindNodes().count, 1)
        XCTAssertEqual(referrer.answerFindNodes([silent.endpoint]), 1)
        sim.run(for: IvyCore.lookupResponseTimeout)
        _ = referrer.answerFindNodes([silent.endpoint])
        XCTAssertTrue(sim.run(until: { sim.result(of: lookup, on: node) != nil }, timeout: .seconds(5)))

        XCTAssertTrue(silent.takeFindNodes().isEmpty)
        XCTAssertEqual(sim.result(of: lookup, on: node)?.endpoints, [referrer.endpoint])
    }
}
