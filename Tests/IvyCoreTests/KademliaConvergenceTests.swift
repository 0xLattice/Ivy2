import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// The iterative `findNode`: ported from 15.0.1's KademliaConvergenceTests,
/// plus the lookup rules in docs/architecture.md "Routing and content".
final class KademliaConvergenceTests: XCTestCase {
    private func endpoints(_ sim: Simulation, _ id: RequestID, on node: Simulation.Node) -> [PeerEndpoint]? {
        sim.result(of: id, on: node)?.endpoints
    }

    // MARK: - Ported from 15.0.1

    /// "seeded reply ordering and one partition still converge"
    func testSeededAdversarialSchedule() {
        for seed: UInt64 in [0x1A17, 7, 99, 4242] {
            let sim = Simulation(seed: seed)
            let node = sim.node()
            let target = sim.node()
            let initial = (0..<3).map { DiscoveryScriptedPeer(sim, to: node, index: $0) }
            var generator = CoreRandom.seeded(seed)
            let partitioned = initial[Int(generator.next() % UInt64(initial.count))]
            let order = initial.shuffled(using: &generator)

            let started = sim.now
            let lookup = sim.request(.findNode(target: target.key.hex), on: node)
            let nonces = initial.map { $0.takeFindNodes() }
            XCTAssertEqual(nonces.map(\.count), [1, 1, 1], "seed \(seed)")
            for peer in order where peer !== partitioned {
                let index = initial.firstIndex { $0 === peer }!
                peer.send(.neighbors([target.endpoint], nonce: nonces[index][0].nonce))
            }
            XCTAssertNil(sim.result(of: lookup, on: node), "the partitioned peer is still awaited")

            XCTAssertTrue(sim.run(until: { sim.result(of: lookup, on: node) != nil }, timeout: .seconds(5)))
            XCTAssertEqual(endpoints(sim, lookup, on: node)?.contains(target.endpoint), true, "seed \(seed)")
            XCTAssertGreaterThanOrEqual(sim.now - started, .milliseconds(500))
            XCTAssertLessThan(sim.now - started, .seconds(1))
        }
    }

    /// "findNode follows deterministic multi-hop referrals"
    func testSuccessfulMultiHopLookup() {
        let sim = Simulation()
        let node = sim.node()
        let first = DiscoveryScriptedPeer(sim, to: node, index: 0)
        // Connected, but with no advertised address they hold no routing entry.
        let second = DiscoveryScriptedPeer(sim, to: node, index: 1, listen: [])
        let target = DiscoveryScriptedPeer(sim, to: node, index: 2, listen: [])
        XCTAssertEqual(node.core.knownPeerEndpoints, [first.endpoint])

        let lookup = sim.request(.findNode(target: target.key.hex), on: node)
        XCTAssertTrue(sim.runServicing(until: { sim.result(of: lookup, on: node) != nil }) {
            first.answerFindNodes([second.endpoint])
            second.answerFindNodes([target.endpoint])
            target.answerFindNodes([])
        })

        XCTAssertEqual(endpoints(sim, lookup, on: node)?.contains(target.endpoint), true)
        // A referral is a candidate, never a routing entry.
        XCTAssertEqual(node.core.knownPeerEndpoints, [first.endpoint])
    }

    /// "authenticated network referrals converge across multiple hops"
    func testAuthenticatedMultiHopNetworkLookup() {
        let sim = Simulation()
        let source = sim.node()
        let first = sim.node()
        let second = sim.node()
        let target = sim.node()
        sim.connect(second, target)
        sim.connect(first, second)
        sim.connect(source, first)
        XCTAssertEqual(source.core.knownPeerEndpoints, [first.endpoint])

        let result = sim.await(.findNode(target: target.key.hex), on: source)?.endpoints

        XCTAssertEqual(result?.contains(target.endpoint), true)
        XCTAssertEqual(source.core.peerConnectionCount, 3)
        XCTAssertEqual(Set(source.connected.map(\.id)), [first.peer, second.peer, target.peer])
        // Each entry came from a session this node authenticated itself.
        XCTAssertEqual(
            Set(source.core.knownPeerEndpoints),
            [first.endpoint, second.endpoint, target.endpoint])
    }

    /// "a public lookup cannot cross stop and restart"
    func testPublicLookupIsRunScoped() {
        let sim = Simulation()
        let node = sim.node()
        let first = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let stale = sim.node()

        let lookup = sim.request(.findNode(target: stale.key.hex), on: node)
        let asked = first.takeFindNodes()
        XCTAssertEqual(asked.count, 1)

        sim.stop(node)
        sim.start(node)
        first.send(.neighbors([stale.endpoint], nonce: asked[0].nonce))
        sim.run(for: .seconds(2))

        XCTAssertEqual(endpoints(sim, lookup, on: node), [])
        XCTAssertFalse(node.core.knownPeerEndpoints.contains(stale.endpoint))
        XCTAssertTrue(node.core.lookups.isEmpty)
        XCTAssertTrue(node.core.pendingNeighborResponses.isEmpty)
        XCTAssertTrue(sim.discoveryDials(by: node).isEmpty)
        XCTAssertTrue(stale.core.connectedPeers.isEmpty)
    }

    /// "findNode does not dial private third-party referrals"
    func testFindNodeRejectsPrivateThirdPartyRoutes() {
        let sim = Simulation()
        let nodes = (0..<4).map { sim.node(host: "10.\($0 + 1).0.1") }
        for index in 0..<3 { sim.connect(nodes[index], nodes[index + 1]) }
        XCTAssertEqual(nodes.map(\.core.peerConnectionCount), [1, 2, 2, 1])
        // A private address is believed from the peer it was observed at.
        XCTAssertEqual(nodes[0].core.knownPeerEndpoints, [nodes[1].endpoint])

        let target = nodes[3].key.hex
        let result = sim.await(.findNode(target: target), on: nodes[0])?.endpoints

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.map(\.publicKey).contains(target), false)
        XCTAssertEqual(result?.map(\.publicKey).contains(nodes[2].key.hex), false)
        XCTAssertEqual(nodes[0].core.peerConnectionCount, 1)
        XCTAssertEqual(sim.discoveryDials(by: nodes[0]), [nodes[1].endpoint])
    }

    /// "Concurrent neighbor requests correlate reversed responses by nonce"
    func testConcurrentLookupsCorrelateByNonce() {
        let sim = Simulation()
        let node = sim.node()
        let referrer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let resultA = DiscoveryScriptedPeer(sim, to: node, index: 1, listen: [])
        let resultB = DiscoveryScriptedPeer(sim, to: node, index: 2, listen: [])
        let targetA = "nonce-target-a"
        let targetB = "nonce-target-b"

        let lookupA = sim.request(.findNode(target: targetA), on: node)
        let lookupB = sim.request(.findNode(target: targetB), on: node)
        let asked = referrer.takeFindNodes()
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(node.core.pendingNeighborResponses.count, 2)
        guard let nonceA = asked.first(where: { $0.target == Data(Router.hash(targetA)) })?.nonce,
              let nonceB = asked.first(where: { $0.target == Data(Router.hash(targetB)) })?.nonce else {
            return XCTFail("each lookup asks for its own target")
        }
        XCTAssertNotEqual(nonceA, nonceB)

        // Answered in the reverse of the order asked.
        referrer.send(.neighbors([resultB.endpoint], nonce: nonceB))
        referrer.send(.neighbors([resultA.endpoint], nonce: nonceA))
        XCTAssertTrue(sim.runServicing(until: {
            sim.result(of: lookupA, on: node) != nil && sim.result(of: lookupB, on: node) != nil
        }) {
            resultA.answerFindNodes([])
            resultB.answerFindNodes([])
        })

        let a = endpoints(sim, lookupA, on: node) ?? []
        let b = endpoints(sim, lookupB, on: node) ?? []
        XCTAssertTrue(a.contains(resultA.endpoint))
        XCTAssertFalse(a.contains(resultB.endpoint))
        XCTAssertTrue(b.contains(resultB.endpoint))
        XCTAssertFalse(b.contains(resultA.endpoint))
    }

    /// "failed routing endpoints are evicted"
    func testFailedEndpointIsEvicted() {
        let sim = Simulation()
        let node = sim.node()
        let dead = sim.discoveryUnreachableEndpoint(index: 0)
        node.core.router.addPeer(PeerID(publicKey: dead.publicKey), endpoint: dead)
        XCTAssertTrue(node.core.knownPeerEndpoints.contains(dead))

        let result = sim.await(.findNode(target: dead.publicKey), on: node)?.endpoints

        XCTAssertEqual(result?.contains(dead), false)
        XCTAssertFalse(node.core.knownPeerEndpoints.contains(dead))
        XCTAssertEqual(sim.discoveryDials(by: node), [dead])
    }

    /// "local dial deferral preserves routing evidence"
    func testLocallyDeferredEndpointIsRetained() {
        let sim = Simulation()
        let node = sim.discoveryNode(maxConnections: 2)
        let referrer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let deferred = sim.discoveryUnreachableEndpoint(index: 0)

        // A dial to the same identity is already out: the lookup's own
        // attempt is not admitted, which is not a failed route.
        let dial = sim.request(.connect(deferred), on: node)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)

        let lookup = sim.request(.findNode(target: deferred.publicKey), on: node)
        XCTAssertEqual(referrer.answerFindNodes([deferred]), 1)

        XCTAssertNil(sim.result(of: dial, on: node), "the earlier dial is still out")
        XCTAssertEqual(endpoints(sim, lookup, on: node)?.contains(deferred), true)
        XCTAssertEqual(sim.discoveryDials(by: node), [deferred])
        sim.run(for: .seconds(1))
    }

    /// "stale dial completion cannot mutate a newer run"
    func testStaleDialCompletionIsRunScoped() {
        let sim = Simulation()
        let node = sim.discoveryNode(maxConnections: 1)
        let endpoint = sim.discoveryUnreachableEndpoint(index: 0)
        let peer = PeerID(publicKey: endpoint.publicKey)

        let old = sim.request(.connect(endpoint), on: node)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)
        sim.stop(node)
        XCTAssertEqual(sim.result(of: old, on: node), .connect(.cancelled))

        sim.start(node)
        node.core.router.addPeer(peer, endpoint: endpoint)
        // The old run's dial still holds its place until the shell reports it.
        let blocked = sim.request(.connect(endpoint), on: node)
        XCTAssertEqual(sim.result(of: blocked, on: node), .connect(.failed(.connectionInProgress)))
        XCTAssertEqual(sim.discoveryDials(by: node).count, 1)

        // Its failure belongs to the old run: nothing of the new run changes.
        sim.run(for: sim.latency + sim.latency)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertTrue(node.core.knownPeerEndpoints.contains(endpoint))

        _ = sim.request(.connect(endpoint), on: node)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)
        XCTAssertEqual(sim.discoveryDials(by: node).count, 2)
    }

    /// "cancelling a lookup stops future referral rounds"
    func testCancellationStopsLookupRounds() {
        let sim = Simulation()
        let node = sim.node()
        let first = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let referred = sim.node()

        let lookup = sim.request(.findNode(target: referred.key.hex), on: node)
        let asked = first.takeFindNodes()
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(node.core.timers.isSet(.neighbor(asked[0].nonce)))

        sim.cancel(lookup, on: node)
        XCTAssertEqual(endpoints(sim, lookup, on: node), [])
        XCTAssertTrue(node.core.lookups.isEmpty)
        XCTAssertTrue(node.core.pendingNeighborResponses.isEmpty)
        XCTAssertFalse(node.core.timers.isSet(.neighbor(asked[0].nonce)))

        first.send(.neighbors([referred.endpoint], nonce: asked[0].nonce))
        sim.run(for: .seconds(2))

        XCTAssertFalse(node.core.hasEndpointSession(referred.peer))
        XCTAssertTrue(sim.discoveryDials(by: node).isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
    }

    /// "cancelling a lookup closes a stalled authentication"
    func testCancellationClosesStalledAuthentication() {
        let sim = Simulation()
        let node = sim.node()
        let stalled = sim.node()
        node.core.router.addPeer(stalled.peer, endpoint: stalled.endpoint)

        let lookup = sim.request(.findNode(target: stalled.key.hex), on: node)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)
        // The connection is up and this node's hello is on the wire, unanswered.
        XCTAssertTrue(sim.run(until: { node.core.diagnostics.pendingSessions == 1 }, timeout: .seconds(1)))
        XCTAssertNil(sim.result(of: lookup, on: node))

        sim.cancel(lookup, on: node)

        XCTAssertEqual(endpoints(sim, lookup, on: node), [])
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertTrue(sim.discoveryEffects(of: node).contains { effect in
            if case .close = effect { return true } else { return false }
        })
        sim.run(for: .seconds(2))
        XCTAssertFalse(node.core.hasEndpointSession(stalled.peer))
        XCTAssertTrue(stalled.core.connectedPeers.isEmpty)
        XCTAssertEqual(stalled.core.diagnostics.pendingSessions, 0)
    }

    /// "a new route is retried after the old session disconnects"
    func testNewRouteAfterDisconnectIsQueryable() {
        let sim = Simulation()
        let source = sim.node()
        let target = sim.node()
        let referrer = DiscoveryScriptedPeer(sim, to: source, index: 0)
        sim.connect(source, target)
        guard let connections = sim.lastDialledConnections else { return XCTFail("no connection") }
        // The session's recorded route is one that no longer answers.
        let oldRoute = PeerEndpoint(publicKey: target.key.hex, host: "1.1.1.1", port: 4001)
        source.core.router.addPeer(target.peer, endpoint: oldRoute)

        let lookup = sim.request(.findNode(target: target.key.hex), on: source)
        let asked = referrer.takeFindNodes()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(source.core.pendingNeighborResponses.count, 2, "both connected peers are asked")

        // The transport to the target goes away with its question unanswered.
        sim.send(.closed(connections.dialer), to: source)
        sim.send(.closed(connections.listener), to: target)
        XCTAssertFalse(source.core.hasEndpointSession(target.peer))
        referrer.send(.neighbors([target.endpoint], nonce: asked[0].nonce))

        XCTAssertTrue(sim.run(until: { sim.result(of: lookup, on: source) != nil }, timeout: .seconds(5)))
        XCTAssertTrue(source.core.hasEndpointSession(target.peer))
        XCTAssertEqual(endpoints(sim, lookup, on: source)?.contains(target.endpoint), true)
    }

    /// "lookup preserves alternate routes for one referred identity"
    func testReferralRouteAlternatives() {
        let sim = Simulation()
        let source = sim.node()
        let target = sim.node()
        let initial = DiscoveryScriptedPeer(sim, to: source, index: 0)
        let live = target.endpoint
        // Sorts ahead of the live route, so it is the one tried first.
        let dead = PeerEndpoint(publicKey: target.key.hex, host: "1.1.1.1", port: 4001)

        let lookup = sim.request(.findNode(target: target.key.hex), on: source)
        XCTAssertEqual(initial.answerFindNodes([live, dead]), 1)
        XCTAssertTrue(sim.run(until: { sim.result(of: lookup, on: source) != nil }, timeout: .seconds(5)))

        XCTAssertEqual(endpoints(sim, lookup, on: source)?.contains(live), true)
        XCTAssertTrue(source.core.hasEndpointSession(target.peer))
        XCTAssertEqual(sim.discoveryDials(by: source), [dead, live])
    }

    /// "an authenticated route survives referral alternatives"
    func testAuthenticatedRouteIsPreserved() {
        let sim = Simulation()
        let key = sim.discoveryKey(index: 0).hex
        let trusted = PeerEndpoint(publicKey: key, host: "1.1.1.1", port: 4001)
        var routes = [LookupRoute(endpoint: trusted, source: .authenticated)]
        for index in 0..<4 {
            routes = selectedLookupRoutes(
                routes + [LookupRoute(
                    endpoint: PeerEndpoint(publicKey: key, host: "8.8.8.\(index + 1)", port: UInt16(4100 + index)),
                    source: .referral(sim.discoveryKey(index: 1).hex))],
                preferred: trusted,
                maxRoutesPerIdentity: IvyConfig.defaultMaxRoutesPerIdentity)
        }

        XCTAssertEqual(routes.first?.endpoint, trusted)
        XCTAssertEqual(routes.count, IvyConfig.defaultMaxRoutesPerIdentity)
    }

    /// "route source diversity survives lookup rounds"
    func testReferralRoutesPreserveSourceDiversity() {
        let sim = Simulation()
        let limit = IvyConfig.defaultMaxRoutesPerIdentity
        let key = sim.discoveryKey(index: 0).hex
        let honest = sim.discoveryKey(index: 1).hex
        let flooding = sim.discoveryKey(index: 2).hex
        let live = PeerEndpoint(publicKey: key, host: "1.1.1.1", port: 4001)
        let poisoned = (1...3).map {
            PeerEndpoint(publicKey: key, host: "8.8.8.\($0)", port: UInt16(4100 + $0))
        }

        var selected = selectedLookupRoutes(
            [LookupRoute(endpoint: live, source: .referral(honest))],
            preferred: nil, maxRoutesPerIdentity: limit)
        for endpoint in poisoned {
            selected = selectedLookupRoutes(
                selected + [LookupRoute(endpoint: endpoint, source: .referral(flooding))],
                preferred: nil, maxRoutesPerIdentity: limit)
        }
        XCTAssertEqual(selected.count, limit)
        XCTAssertTrue(selected.contains { $0.endpoint == live })

        let retired = LookupRoute(endpoint: live, source: .authenticated)
        let alternative = LookupRoute(endpoint: poisoned[0], source: .referral(honest))
        XCTAssertEqual(
            selectedLookupRoutes([retired, alternative], preferred: live, maxRoutesPerIdentity: limit)
                .first?.endpoint,
            live)
        XCTAssertEqual(
            selectedLookupRoutes([retired, alternative], preferred: nil, maxRoutesPerIdentity: limit)
                .first?.endpoint,
            alternative.endpoint)

        let attacker = String(repeating: "0", count: honest.count)
        let repeated = [LookupRoute(endpoint: live, source: .referral(attacker))]
            + (1...3).map {
                LookupRoute(
                    endpoint: PeerEndpoint(publicKey: key, host: "0.0.0.\($0)", port: UInt16(4200 + $0)),
                    source: .referral(attacker))
            }
        let deduplicated = selectedLookupRoutes(
            [LookupRoute(endpoint: live, source: .referral(honest))] + repeated,
            preferred: nil, maxRoutesPerIdentity: limit)
        XCTAssertTrue(deduplicated.contains { $0.endpoint == live && $0.source == .referral(honest) })
        XCTAssertEqual(
            selectedLookupRoutes(
                [LookupRoute(endpoint: live, source: .authenticated)] + repeated,
                preferred: live, maxRoutesPerIdentity: limit).first?.source,
            .authenticated)
    }

    /// "later lookup rounds cannot replace every route from an earlier source"
    func testReferralProvenanceSurvivesLookupRounds() {
        let sim = Simulation()
        let node = sim.discoveryNode(maxConnections: 3)
        // The honest referrer sorts first, as in the reference.
        let indices = [0, 1].sorted { sim.signingKeyHex(scripted: $0) < sim.signingKeyHex(scripted: $1) }
        let honest = DiscoveryScriptedPeer(sim, to: node, index: indices[0])
        let flooding = DiscoveryScriptedPeer(sim, to: node, index: indices[1], listen: [])
        XCTAssertLessThan(honest.key.hex, flooding.key.hex)
        let live = sim.discoveryUnreachableEndpoint(index: 0, host: "1.1.1.1", port: 4100)
        let poisoned = (1...3).map {
            PeerEndpoint(publicKey: live.publicKey, host: "8.8.8.\($0)", port: UInt16(4200 + $0))
        }

        // A dial to the target is already out, so every lookup attempt is deferred.
        _ = sim.request(.connect(live), on: node)
        let lookup = sim.request(.findNode(target: live.publicKey), on: node)
        XCTAssertEqual(honest.answerFindNodes([live, flooding.endpoint]), 1)
        XCTAssertEqual(flooding.answerFindNodes(poisoned), 1)

        XCTAssertEqual(endpoints(sim, lookup, on: node)?.contains(live), true)
        XCTAssertEqual(sim.discoveryDials(by: node), [live])
        sim.run(for: .seconds(1))
    }

    // MARK: - Lookup rules

    /// A network bootstrapped off two seeds: every node's lookup for a key
    /// returns the k nodes closest to it.
    func testLookupsConvergeOnTheClosestNodesAcrossANetwork() {
        let sim = Simulation(seed: 11)
        let k = 8
        let seedA = sim.node(kBucketSize: k)
        let seedB = sim.node(bootstrap: [seedA.endpoint], kBucketSize: k)
        var nodes = [seedA, seedB]
        for index in 0..<28 {
            let bootstrap = index % 2 == 0 ? seedA : seedB
            nodes.append(sim.node(bootstrap: [bootstrap.endpoint], kBucketSize: k))
        }
        XCTAssertTrue(sim.run(until: {
            nodes.dropFirst().allSatisfy { $0.core.peerConnectionCount >= 1 }
        }, timeout: .seconds(10)))

        // Each node joins by looking itself up.
        for node in nodes {
            XCTAssertNotNil(sim.await(.findNode(target: node.key.hex), on: node, timeout: .seconds(30)))
        }

        let everyone = nodes.map(\.key.hex)
        for (querier, target) in [(nodes[5], "content-key-one"), (nodes[17], "content-key-two"),
                                  (nodes[29], nodes[3].key.hex), (nodes[0], "content-key-three")] {
            let result = sim.await(.findNode(target: target), on: querier, timeout: .seconds(30))?.endpoints ?? []
            let expected = Array(
                discoveryClosest(everyone.filter { $0 != querier.key.hex }, to: target).prefix(k))
            XCTAssertEqual(result.map(\.publicKey), expected, "lookup for \(target)")
            // Every answer names the address its node really listens on.
            for endpoint in result {
                XCTAssertEqual(endpoint, nodes.first { $0.key.hex == endpoint.publicKey }?.endpoint)
            }
        }
        for node in nodes {
            XCTAssertTrue(node.core.lookups.isEmpty)
            XCTAssertTrue(node.core.pendingNeighborResponses.isEmpty)
            // No routing entry without a session behind it.
            XCTAssertTrue(node.core.router.allPeers().allSatisfy { node.core.hasEndpointSession($0.id) })
        }
    }

    /// Each round asks the three closest candidates not yet asked.
    func testEachRoundAsksTheThreeClosestUnqueriedCandidates() {
        let sim = Simulation()
        let node = sim.node()
        let peers = (0..<7).map { DiscoveryScriptedPeer(sim, to: node, index: $0) }
        let target = "parallelism-target"
        let order = discoveryClosest(peers.map(\.key.hex), to: target)

        let lookup = sim.request(.findNode(target: target), on: node)
        var pending = peers.map { $0.takeFindNodes() }
        XCTAssertEqual(
            Set(zip(peers, pending).filter { !$0.1.isEmpty }.map(\.0.key.hex)),
            Set(order[0..<3]))
        XCTAssertEqual(IvyCore.kademliaLookupParallelism, 3)

        for round in 1..<3 {
            for (peer, requests) in zip(peers, pending) {
                for request in requests { peer.send(.neighbors([], nonce: request.nonce)) }
            }
            pending = peers.map { $0.takeFindNodes() }
            let expected = Set(order[(round * 3)..<min(round * 3 + 3, order.count)])
            XCTAssertEqual(
                Set(zip(peers, pending).filter { !$0.1.isEmpty }.map(\.0.key.hex)),
                expected,
                "round \(round + 1)")
        }
        for (peer, requests) in zip(peers, pending) {
            for request in requests { peer.send(.neighbors([], nonce: request.nonce)) }
        }
        XCTAssertEqual(endpoints(sim, lookup, on: node)?.map(\.publicKey), order)
        XCTAssertTrue(peers.allSatisfy { $0.takeFindNodes().isEmpty }, "nobody is asked twice")
    }

    /// A lookup runs at most `kBucketSize` rounds however long the referral chain.
    func testLookupStopsAfterKBucketSizeRounds() {
        let sim = Simulation()
        let node = sim.node(kBucketSize: 2)
        let target = "round-cap-target"
        // A chain in which each peer refers one closer than itself.
        var ranked: [(index: Int, key: String)] = (0..<5).map { ($0, sim.signingKeyHex(scripted: $0)) }
        let farthestFirst = Array(discoveryClosest(ranked.map(\.key), to: target).reversed())
        ranked.sort { farthestFirst.firstIndex(of: $0.key)! < farthestFirst.firstIndex(of: $1.key)! }
        let chain = ranked.enumerated().map { position, entry in
            DiscoveryScriptedPeer(sim, to: node, index: entry.index, listen: position == 0 ? nil : [])
        }
        XCTAssertEqual(node.core.knownPeerEndpoints, [chain[0].endpoint])

        let lookup = sim.request(.findNode(target: target), on: node)
        var questions = 0
        XCTAssertTrue(sim.runServicing(until: { sim.result(of: lookup, on: node) != nil }) {
            for (position, peer) in chain.enumerated() {
                let next = position + 1 < chain.count ? [chain[position + 1].endpoint] : []
                questions += peer.answerFindNodes(next)
            }
        })

        XCTAssertEqual(questions, 2, "one question per round, two rounds")
        let result = endpoints(sim, lookup, on: node) ?? []
        XCTAssertEqual(result.map(\.publicKey), [chain[2].key.hex, chain[1].key.hex])
        XCTAssertTrue(chain[2].takeFindNodes().isEmpty)
    }

    /// A referral must be a globally routable IP literal naming someone else.
    func testReferralsMustBeGloballyRoutable() {
        let sim = Simulation()
        let node = sim.node()
        let referrer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        func key(_ index: Int) -> String { sim.discoveryKey(index: index).hex }
        let rejected = [
            PeerEndpoint(publicKey: key(0), host: "10.0.0.9", port: 4001),
            PeerEndpoint(publicKey: key(1), host: "127.0.0.1", port: 4001),
            PeerEndpoint(publicKey: key(2), host: "192.168.1.4", port: 4001),
            PeerEndpoint(publicKey: key(3), host: "172.16.0.4", port: 4001),
            PeerEndpoint(publicKey: key(4), host: "169.254.1.1", port: 4001),
            PeerEndpoint(publicKey: key(5), host: "100.64.0.1", port: 4001),
            PeerEndpoint(publicKey: key(6), host: "192.0.2.7", port: 4001),
            PeerEndpoint(publicKey: key(7), host: "224.0.0.1", port: 4001),
            PeerEndpoint(publicKey: key(8), host: "0.0.0.0", port: 4001),
            PeerEndpoint(publicKey: key(9), host: "example.com", port: 4001),
            PeerEndpoint(publicKey: key(10), host: "", port: 4001),
            PeerEndpoint(publicKey: key(11), host: "8.200.0.1", port: 0),
            PeerEndpoint(publicKey: key(12), host: "::1", port: 4001),
            PeerEndpoint(publicKey: key(13), host: "fd00::1", port: 4001),
            PeerEndpoint(publicKey: key(14), host: "2001:db8::1", port: 4001),
            PeerEndpoint(publicKey: "not-a-key", host: "8.201.0.1", port: 4001),
            PeerEndpoint(publicKey: node.key.hex, host: "8.202.0.1", port: 4001),
        ]
        let accepted = [
            PeerEndpoint(publicKey: key(20), host: "8.203.0.1", port: 4001),
            PeerEndpoint(publicKey: key(21), host: "2606:4700::1111", port: 4001),
        ]
        // Surrounding whitespace is not part of the address.
        let padded = PeerEndpoint(publicKey: key(22), host: " 8.204.0.1 ", port: 4001)
        let trimmed = PeerEndpoint(publicKey: key(22), host: "8.204.0.1", port: 4001)

        let lookup = sim.request(.findNode(target: "routable-target"), on: node)
        XCTAssertEqual(referrer.answerFindNodes(rejected + accepted + [padded]), 1)
        XCTAssertTrue(sim.run(until: { sim.result(of: lookup, on: node) != nil }, timeout: .seconds(5)))

        XCTAssertEqual(Set(sim.discoveryDials(by: node)), Set(accepted + [trimmed]))
        // None answered, and a referral alone installs nothing.
        XCTAssertEqual(endpoints(sim, lookup, on: node), [referrer.endpoint])
        XCTAssertEqual(node.core.knownPeerEndpoints, [referrer.endpoint])
        XCTAssertTrue(node.core.hasEndpointSession(referrer.peer), "an unusable referral is not a violation")
    }

    /// A private or loopback address a peer advertises for itself is believed
    /// only when it is the address the peer was observed at.
    func testSelfAdvertisedPrivateAddressMustMatchObservedAddress() {
        let sim = Simulation()
        let node = sim.node(maxConnectionsPerNetgroup: 8)
        func listen(_ host: String) -> [ListenAddress] { [ListenAddress(host: host, port: 4001)] }

        let matchingPrivate = DiscoveryScriptedPeer(sim, to: node, index: 0, host: "10.5.0.5")
        let lyingPrivate = DiscoveryScriptedPeer(
            sim, to: node, index: 1, host: "9.50.0.1", listen: listen("10.6.0.5"))
        let matchingLoopback = DiscoveryScriptedPeer(sim, to: node, index: 2, host: "127.0.0.1")
        let lyingLoopback = DiscoveryScriptedPeer(
            sim, to: node, index: 3, host: "9.51.0.1", listen: listen("127.0.0.1"))
        let otherPrivate = DiscoveryScriptedPeer(
            sim, to: node, index: 4, host: "10.7.0.5", listen: listen("10.7.0.6"))
        let linkLocal = DiscoveryScriptedPeer(sim, to: node, index: 5, host: "169.254.1.1")
        let publicElsewhere = DiscoveryScriptedPeer(
            sim, to: node, index: 6, host: "9.52.0.1", listen: listen("8.77.0.1"))
        let firstAcceptable = DiscoveryScriptedPeer(
            sim, to: node, index: 7, host: "9.53.0.1",
            listen: listen("10.8.0.1") + listen("192.0.2.1") + listen("8.78.0.1"))
        let all = [matchingPrivate, lyingPrivate, matchingLoopback, lyingLoopback, otherPrivate,
                   linkLocal, publicElsewhere, firstAcceptable]
        XCTAssertTrue(all.allSatisfy(\.isAuthenticated), "an unusable advertisement does not refuse the session")

        func route(_ peer: DiscoveryScriptedPeer) -> PeerEndpoint? {
            node.core.router.allPeers().first { $0.id == peer.peer }?.endpoint
        }
        XCTAssertEqual(route(matchingPrivate), matchingPrivate.endpoint)
        XCTAssertNil(route(lyingPrivate))
        XCTAssertEqual(route(matchingLoopback), matchingLoopback.endpoint)
        XCTAssertNil(route(lyingLoopback))
        XCTAssertNil(route(otherPrivate))
        XCTAssertNil(route(linkLocal), "link-local is never believed")
        XCTAssertEqual(
            route(publicElsewhere),
            PeerEndpoint(publicKey: publicElsewhere.key.hex, host: "8.77.0.1", port: 4001))
        XCTAssertEqual(
            route(firstAcceptable),
            PeerEndpoint(publicKey: firstAcceptable.key.hex, host: "8.78.0.1", port: 4001))
        XCTAssertEqual(node.core.peerConnectionCount, all.count)
    }

    /// `neighbors` nobody asked for, with the wrong nonce, or from a peer
    /// other than the one asked, change nothing.
    func testUnsolicitedAndMismatchedNeighborsAreIgnored() {
        let sim = Simulation()
        let node = sim.node()
        let bait = sim.node()
        let first = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let second = DiscoveryScriptedPeer(sim, to: node, index: 1)

        first.send(.neighbors([bait.endpoint], nonce: 0))
        first.send(.neighbors([bait.endpoint], nonce: 1))
        sim.run(for: .seconds(1))
        XCTAssertTrue(sim.discoveryDials(by: node).isEmpty)
        XCTAssertEqual(Set(node.core.knownPeerEndpoints), [first.endpoint, second.endpoint])

        let started = sim.now
        let lookup = sim.request(.findNode(target: bait.key.hex), on: node)
        guard let askedFirst = first.takeFindNodes().first?.nonce,
              let askedSecond = second.takeFindNodes().first?.nonce else {
            return XCTFail("both peers are asked")
        }
        // A nonce nobody holds, then each peer answering the other's question.
        first.send(.neighbors([bait.endpoint], nonce: askedFirst &+ askedSecond &+ 1_000))
        first.send(.neighbors([bait.endpoint], nonce: askedSecond))
        second.send(.neighbors([bait.endpoint], nonce: askedFirst))
        XCTAssertEqual(node.core.pendingNeighborResponses.count, 2, "both questions are still open")
        XCTAssertNil(sim.result(of: lookup, on: node))

        XCTAssertTrue(sim.run(until: { sim.result(of: lookup, on: node) != nil }, timeout: .seconds(5)))
        XCTAssertEqual(sim.now - started, .milliseconds(500))
        XCTAssertEqual(endpoints(sim, lookup, on: node)?.contains(bait.endpoint), false)
        XCTAssertTrue(sim.discoveryDials(by: node).isEmpty)
        XCTAssertTrue(bait.core.connectedPeers.isEmpty)
        XCTAssertEqual(node.core.peerConnectionCount, 2, "a stray answer is not a violation")
    }

    /// A neighbor that never answers holds its round for 500 ms and no longer.
    func testSilentNeighborCostsHalfASecond() {
        let sim = Simulation()
        let node = sim.node()
        let silent = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let prompt = DiscoveryScriptedPeer(sim, to: node, index: 1)

        let started = sim.now
        let lookup = sim.request(.findNode(target: "silent-target"), on: node)
        XCTAssertEqual(prompt.answerFindNodes([]), 1)
        XCTAssertEqual(silent.takeFindNodes().count, 1)
        XCTAssertEqual(IvyCore.lookupResponseTimeout, .milliseconds(500))

        sim.run(for: .milliseconds(499))
        XCTAssertNil(sim.result(of: lookup, on: node))
        sim.run(for: .milliseconds(1))
        XCTAssertEqual(sim.now - started, .milliseconds(500))

        // A lookup ends on the peers that answered; silence is not a failed
        // route, so the silent peer keeps its routing entry.
        XCTAssertEqual(endpoints(sim, lookup, on: node), [prompt.endpoint])
        XCTAssertEqual(Set(node.core.knownPeerEndpoints), [silent.endpoint, prompt.endpoint])
        XCTAssertTrue(node.core.pendingNeighborResponses.isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
    }

    /// A peer that closes with its question open ends that wait at once.
    func testDisconnectingNeighborDoesNotHoldTheRound() {
        let sim = Simulation()
        let node = sim.node()
        let leaving = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let staying = DiscoveryScriptedPeer(sim, to: node, index: 1)

        let started = sim.now
        let lookup = sim.request(.findNode(target: "leaving-target"), on: node)
        XCTAssertEqual(staying.answerFindNodes([]), 1)
        XCTAssertNil(sim.result(of: lookup, on: node))
        leaving.close()

        // It stays a candidate of this lookup, as in 15.0.1; only its routing entry goes.
        XCTAssertEqual(endpoints(sim, lookup, on: node)?.contains(staying.endpoint), true)
        XCTAssertEqual(sim.now, started)
        XCTAssertTrue(node.core.pendingNeighborResponses.isEmpty)
        XCTAssertEqual(node.core.knownPeerEndpoints, [staying.endpoint])
    }

    /// A lookup started while stopped, or outside the overlay, answers empty.
    func testFindNodeAnswersEmptyWhenNotRunning() {
        let sim = Simulation()
        let node = sim.node(start: false)
        XCTAssertEqual(sim.await(.findNode(target: "anything"), on: node)?.endpoints, [])
        sim.start(node)
        XCTAssertEqual(sim.await(.findNode(target: "anything"), on: node)?.endpoints, [])
        XCTAssertTrue(node.core.lookups.isEmpty)
    }

    /// A node answers `findNode` with the closest peers it holds routes for.
    func testFindNodeIsAnsweredFromTheRoutingTable() {
        let sim = Simulation()
        let node = sim.node(kBucketSize: 3)
        let peers = (0..<5).map { DiscoveryScriptedPeer(sim, to: node, index: $0) }
        let unrouted = DiscoveryScriptedPeer(sim, to: node, index: 5, listen: [])
        let target = Data(Router.hash("answer-target"))

        unrouted.send(.findNode(target: target, nonce: 77))
        let answers = unrouted.takeNeighbors()
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.nonce, 77)

        let held = node.core.router.allPeers().map(\.id.publicKey)
        XCTAssertEqual(
            answers.first?.endpoints.map(\.publicKey),
            Array(discoveryClosest(held, to: "answer-target").prefix(3)))
        XCTAssertEqual(answers.first?.endpoints.contains { $0.publicKey == unrouted.key.hex }, false)
        XCTAssertTrue(Set(held).isSubset(of: Set(peers.map(\.key.hex))))
    }
}

extension Simulation {
    /// The identity `DiscoveryScriptedPeer(index:)` will have.
    func signingKeyHex(scripted index: Int) -> String {
        try! PeerKey(rawRepresentation: signingKey(index: 10_000 + index).publicKey.rawRepresentation).hex
    }
}
