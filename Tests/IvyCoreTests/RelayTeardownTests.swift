import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// How a route ends, who is told, what is left behind, and who is blamed.
final class RelayTeardownTests: XCTestCase {
    private typealias Node = Simulation.Node

    /// A relayed session between real nodes, once with the target treating
    /// the carrier as its configured carrier and once as an ordinary peer.
    private func forEachTriangle(
        _ body: (Simulation, _ carrier: Node, _ a: Node, _ b: Node, _ routeID: Data, _ label: String) -> Void
    ) {
        for targetConfiguresCarrier in [true, false] {
            let sim = Simulation()
            let (c, a, b) = sim.relayTriangle(targetConfiguresCarrier: targetConfiguresCarrier)
            guard let routeID = sim.connectRelayed(a, b) else { continue }
            body(sim, c, a, b, routeID, targetConfiguresCarrier ? "carrier role" : "endpoint role")
        }
    }

    private func assertRouteGoneEverywhere(
        _ nodes: [(Node, String)],
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (node, name) in nodes {
            assertNoRelayState(node, "\(name) (\(label))", file: file, line: line)
            XCTAssertEqual(node.core.diagnostics.pendingSessions, 0, "\(name) (\(label))", file: file, line: line)
            XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0, "\(name) (\(label))", file: file, line: line)
        }
    }

    private func assertCarrierSessionsStand(
        _ c: Node, _ a: Node, _ b: Node, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNotNil(a.core.sessions[c.key], label, file: file, line: line)
        XCTAssertNotNil(b.core.sessions[c.key], label, file: file, line: line)
        XCTAssertEqual(c.core.peerConnectionCount, 2, label, file: file, line: line)
        for (node, others) in [(c, [a, b]), (a, [c, b]), (b, [c, a])] {
            for other in others {
                XCTAssertEqual(node.ledger.violations(of: other.peer), 0, label, file: file, line: line)
            }
        }
    }

    // MARK: - Real nodes

    func testClosingTheSourcesSessionRetiresTheRouteAtEveryNode() {
        forEachTriangle { sim, c, a, b, _, label in
            XCTAssertEqual(sim.await(.disconnectSession(sim.session(a, to: b)), on: a), .flag(true), label)
            sim.run(for: .seconds(1))
            assertRouteGoneEverywhere([(a, "a"), (c, "carrier"), (b, "b")], label)
            XCTAssertEqual(a.disconnected, [b.peer], label)
            XCTAssertEqual(b.disconnected, [a.peer], label)
            XCTAssertEqual(a.core.connectedPeers, [], label)
            XCTAssertFalse(b.core.connectedPeers.contains(a.peer), label)
            assertCarrierSessionsStand(c, a, b, label)
        }
    }

    func testClosingTheTargetsSessionRetiresTheRouteAtEveryNode() {
        forEachTriangle { sim, c, a, b, _, label in
            XCTAssertEqual(sim.await(.disconnectSession(sim.session(b, to: a)), on: b), .flag(true), label)
            sim.run(for: .seconds(1))
            assertRouteGoneEverywhere([(a, "a"), (c, "carrier"), (b, "b")], label)
            XCTAssertEqual(a.disconnected, [b.peer], label)
            XCTAssertEqual(b.disconnected, [a.peer], label)
            assertCarrierSessionsStand(c, a, b, label)
        }
    }

    func testDisconnectingThePeerRetiresTheRoute() {
        forEachTriangle { sim, c, a, b, _, label in
            sim.send(.command(.disconnect(b.peer)), to: a)
            sim.run(for: .seconds(1))
            assertRouteGoneEverywhere([(a, "a"), (c, "carrier"), (b, "b")], label)
            XCTAssertEqual(a.disconnected, [b.peer], label)
            XCTAssertEqual(b.disconnected, [a.peer], label)
            assertCarrierSessionsStand(c, a, b, label)
        }
    }

    func testLosingTheCarrierSessionRetiresTheRoute() {
        forEachTriangle { sim, c, a, b, _, label in
            sim.send(.command(.disconnect(c.peer)), to: a)
            sim.run(for: .seconds(1))
            assertRouteGoneEverywhere([(a, "a"), (c, "carrier"), (b, "b")], label)
            XCTAssertEqual(Set(a.disconnected), [b.peer, c.peer], label)
            XCTAssertEqual(b.disconnected, [a.peer], label)
            XCTAssertEqual(c.disconnected, [a.peer], label)
            XCTAssertNotNil(b.core.sessions[c.key], label)
        }
    }

    func testStoppingTheCarrierEndsTheRelayedSession() {
        forEachTriangle { sim, c, a, b, _, label in
            sim.stop(c)
            sim.run(for: .seconds(1))
            assertRouteGoneEverywhere([(a, "a"), (c, "carrier"), (b, "b")], label)
            XCTAssertEqual(Set(a.disconnected), [b.peer, c.peer], label)
            XCTAssertEqual(Set(b.disconnected), [a.peer, c.peer], label)
            XCTAssertEqual(a.core.connectedPeers, [], label)
            XCTAssertEqual(
                sim.await(.send(to: b.peer, topic: "t", payload: Data([1])), on: a)?.sent,
                .notConnected, label)
        }
    }

    func testStoppingAnEndpointRetiresTheRoute() {
        forEachTriangle { sim, c, a, b, _, label in
            sim.stop(b)
            sim.run(for: .seconds(1))
            assertRouteGoneEverywhere([(a, "a"), (c, "carrier"), (b, "b")], label)
            XCTAssertEqual(a.disconnected, [b.peer], label)
            XCTAssertEqual(c.disconnected, [b.peer], label)
            XCTAssertNotNil(a.core.sessions[c.key], label)
        }
        forEachTriangle { sim, c, a, b, _, label in
            sim.stop(a)
            sim.run(for: .seconds(1))
            assertRouteGoneEverywhere([(a, "a"), (c, "carrier"), (b, "b")], label)
            XCTAssertEqual(b.disconnected, [a.peer], label)
            XCTAssertEqual(c.disconnected, [a.peer], label)
            XCTAssertNotNil(b.core.sessions[c.key], label)
        }
    }

    func testARelayedSessionCanBeReopenedOnAFreshRoute() {
        forEachTriangle { sim, c, a, b, routeID, label in
            XCTAssertEqual(sim.await(.disconnectSession(sim.session(a, to: b)), on: a), .flag(true), label)
            sim.run(for: .seconds(1))

            XCTAssertEqual(sim.await(.connectViaRelay(b.endpoint), on: a), .connect(.connected), label)
            sim.run(for: .seconds(1))
            guard case .relayed(_, let reopened)? = a.core.authenticatedPeer(for: b.peer)?.route else {
                return XCTFail("no relayed session (\(label))")
            }
            XCTAssertNotEqual(reopened, routeID, label)
            XCTAssertEqual(Array(c.core.relayRoutes.keys), [reopened], label)
            XCTAssertEqual(Array(a.core.installedRoutes.keys), [reopened], label)
            XCTAssertEqual(Array(b.core.installedRoutes.keys), [reopened], label)
            XCTAssertEqual(
                b.core.authenticatedPeer(for: a.peer)?.route,
                .relayed(carrier: c.key, routeID: reopened), label)
            XCTAssertEqual(
                a.core.authenticatedPeer(for: b.peer)?.sessionID,
                b.core.authenticatedPeer(for: a.peer)?.sessionID, label)
        }
    }

    // MARK: - A carrier tells the other participant

    private func carriedRoute(
        relayTimeout: Duration = .seconds(5),
        requestTimeout: Duration = .seconds(15),
        accepted: Bool = true
    ) -> (Simulation, Node, source: RawRelayPeer, target: RawRelayPeer, Data) {
        let sim = Simulation()
        let carrier = sim.relayNode(
            relayEnabled: true, requestTimeout: requestTimeout, relayTimeout: relayTimeout)
        sim.run(for: .milliseconds(50))
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let routeID = relayRouteID(1)
        source.send(.relayOpen(routeID: routeID, targetKey: target.key))
        if accepted { target.send(.relayAccept(routeID: routeID, status: 0)) }
        _ = source.take()
        _ = target.take()
        XCTAssertEqual(carrier.core.relayRoutes[routeID]?.ready, accepted)
        return (sim, carrier, source, target, routeID)
    }

    func testCarrierPassesARelayCloseToTheOtherParticipant() {
        for closedBySource in [true, false] {
            let (sim, carrier, source, target, routeID) = carriedRoute()
            let (closer, other) = closedBySource ? (source, target) : (target, source)
            closer.send(.relayClose(routeID: routeID))
            sim.run(for: .zero)
            XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
            XCTAssertFalse(carrier.core.timers.isSet(.relayRoute(routeID)))
            XCTAssertEqual(other.takeCloses(), [routeID], "closed by source: \(closedBySource)")
            XCTAssertTrue(closer.take().isEmpty)
            XCTAssertTrue(source.isConnected)
            XCTAssertTrue(target.isConnected)
        }
    }

    func testCarrierClosesTheRouteForThePeerLeftWhenASessionEnds() {
        for sourceLeaves in [true, false] {
            let (sim, carrier, source, target, routeID) = carriedRoute()
            let (leaver, other) = sourceLeaves ? (source, target) : (target, source)
            sim.closeRaw(leaver.connection, at: carrier)
            sim.run(for: .zero)
            XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
            XCTAssertEqual(carrier.disconnected, [leaver.identity.peer])
            XCTAssertEqual(other.takeCloses(), [routeID], "source leaves: \(sourceLeaves)")
            XCTAssertTrue(other.isConnected)
        }
    }

    func testCarrierClosesTheRouteForBothWhenItExpiresUnready() {
        let (sim, carrier, source, target, routeID) = carriedRoute(relayTimeout: .seconds(3), accepted: false)
        sim.run(for: .milliseconds(3_100))
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        XCTAssertEqual(source.takeCloses(), [routeID])
        XCTAssertEqual(target.takeCloses(), [routeID])
    }

    func testCarrierClosesTheRouteForBothWhenItExpiresIdle() {
        let (sim, carrier, source, target, routeID) = carriedRoute()
        sim.run(for: IvyCore.relayIdleTimeout + .seconds(1))
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        XCTAssertEqual(source.takeCloses(), [routeID])
        XCTAssertEqual(target.takeCloses(), [routeID])
    }

    func testCarrierClosesTheRouteForTheSourceWhenForwardingTimesOut() {
        let (sim, carrier, source, target, routeID) = carriedRoute(requestTimeout: .seconds(2))
        sim.run(for: .milliseconds(50))
        sim.setRawStalled(true, target.connection, at: carrier)
        for marker: UInt8 in 1...3 {
            source.sendPacket(Data(repeating: marker, count: 40_000), on: routeID)
        }
        XCTAssertFalse(sim.isReading(source.connection, at: carrier))
        sim.run(for: .milliseconds(2_100))
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        XCTAssertEqual(source.takeCloses(), [routeID])
    }

    // MARK: - An endpoint tells its carrier

    /// The node under test holds an installed route with a session on it,
    /// carried by a peer the test plays.
    private func installedSession(
        carrierIsConfigured: Bool = true,
        relayTimeout: Duration = .seconds(5),
        frame: UInt32 = IvyConfig.defaultProtocolMaxFrameSize
    ) -> (Simulation, Node, carrier: RawRelayPeer, remote: RelayTestIdentity, Data, RelayTestSession)? {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let remote = sim.relayIdentity(2)
        let node = sim.relayNode(
            carriers: carrierIsConfigured ? [carrierIdentity.endpoint] : [],
            relayTimeout: relayTimeout, frame: frame)
        sim.run(for: .milliseconds(50))
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
        let routeID = relayRouteID(1)
        carrier.send(.relayOffer(routeID: routeID, sourceKey: remote.key))
        XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [0])
        guard let session = carrier.initiateRelayedSession(as: remote, on: routeID) else {
            XCTFail("no relayed session")
            return nil
        }
        XCTAssertEqual(
            node.core.authenticatedPeer(for: remote.peer)?.route,
            .relayed(carrier: carrier.key, routeID: routeID))
        XCTAssertEqual(node.core.sessions[carrier.key]?.role, carrierIsConfigured ? .carrier : .endpoint)
        return (sim, node, carrier, remote, routeID, session)
    }

    func testEndpointTellsAConfiguredCarrierWhenItClosesARoute() {
        guard let (sim, node, carrier, remote, routeID, _) = installedSession() else { return }
        sim.send(.command(.disconnect(remote.peer)), to: node)
        sim.run(for: .zero)
        assertNoRelayState(node, "node")
        XCTAssertEqual(node.disconnected, [remote.peer])
        XCTAssertEqual(carrier.takeCloses(), [routeID])
        XCTAssertTrue(carrier.isConnected)
    }

    func testEndpointTellsAnUnconfiguredCarrierWhenItClosesARoute() {
        // The carrier is an ordinary peer here, as it is for the target of
        // a route whose carrier it never configured.
        guard let (sim, node, carrier, remote, routeID, _) = installedSession(carrierIsConfigured: false) else {
            return
        }
        sim.send(.command(.disconnect(remote.peer)), to: node)
        sim.run(for: .zero)
        assertNoRelayState(node, "node")
        XCTAssertEqual(node.disconnected, [remote.peer])
        XCTAssertEqual(carrier.takeCloses(), [routeID])
        XCTAssertTrue(carrier.isConnected)
    }

    func testEndpointTellsAnUnconfiguredCarrierWhenAnUnusedRouteExpires() {
        let sim = Simulation()
        let node = sim.relayNode(relayTimeout: .seconds(3))
        sim.run(for: .milliseconds(50))
        let carrier = RawRelayPeer(sim, to: node, as: sim.relayIdentity(1))
        let routeID = relayRouteID(1)
        carrier.send(.relayOffer(routeID: routeID, sourceKey: sim.relayIdentity(2).key))
        XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [0])
        sim.run(for: .milliseconds(3_100))
        assertNoRelayState(node, "node")
        XCTAssertEqual(carrier.takeCloses(), [routeID])
    }

    func testACarriersRelayCloseEndsTheSessionWithoutAReply() {
        for carrierIsConfigured in [true, false] {
            guard let (sim, node, carrier, remote, routeID, _) = installedSession(
                carrierIsConfigured: carrierIsConfigured) else { return }
            carrier.send(.relayClose(routeID: routeID))
            sim.run(for: .zero)
            assertNoRelayState(node, "node")
            XCTAssertEqual(node.disconnected, [remote.peer])
            XCTAssertTrue(carrier.take().isEmpty)
            XCTAssertTrue(carrier.isConnected)
            XCTAssertEqual(node.ledger.violations(of: carrier.identity.peer), 0)
            XCTAssertEqual(node.ledger.violations(of: remote.peer), 0)
        }
    }

    func testLosingTheCarrierEndsEverySessionItCarried() {
        guard let (sim, node, carrier, remote, _, _) = installedSession() else { return }
        let second = sim.relayIdentity(3)
        carrier.send(.relayOffer(routeID: relayRouteID(2), sourceKey: second.key))
        _ = carrier.take()
        XCTAssertNotNil(carrier.initiateRelayedSession(as: second, on: relayRouteID(2)))
        // And one more route that never got a session.
        carrier.send(.relayOffer(routeID: relayRouteID(3), sourceKey: sim.relayIdentity(4).key))
        XCTAssertEqual(node.core.installedRoutes.count, 3)

        sim.closeRaw(carrier.connection, at: node)
        sim.run(for: .zero)
        assertNoRelayState(node, "node")
        XCTAssertEqual(Set(node.disconnected), [remote.peer, second.peer, carrier.identity.peer])
        XCTAssertEqual(node.core.connectedPeers, [])
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertFalse(node.core.timers.isSet(.installedRoute(relayRouteID(3))))
    }

    // MARK: - Replacement

    /// Reference: "duplicate cleanup preserves the winning relayed transport".
    func testAReplacementSessionPreservesTheRouteItRidesOn() {
        var replaced = 0
        var kept = 0
        for seed: UInt64 in 1...8 {
            let sim = Simulation(seed: seed)
            let carrierIdentity = sim.relayIdentity(1)
            let remote = sim.relayIdentity(2)
            let node = sim.relayNode(carriers: [carrierIdentity.endpoint])
            sim.run(for: .milliseconds(50))
            let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
            let (firstRoute, secondRoute) = (relayRouteID(1), relayRouteID(2))

            carrier.send(.relayOffer(routeID: firstRoute, sourceKey: remote.key))
            guard let first = carrier.initiateRelayedSession(as: remote, on: firstRoute, nonce: 1) else {
                return XCTFail("no first session")
            }
            // The same peer opens a second session over a second route.
            carrier.send(.relayOffer(routeID: secondRoute, sourceKey: remote.key))
            _ = carrier.take { $0.relayAcceptFields }
            guard let second = carrier.initiateRelayedSession(as: remote, on: secondRoute, nonce: 2) else {
                return XCTFail("no second session")
            }
            XCTAssertEqual(node.core.installedRoutes.count, 1, "seed \(seed)")

            // Simultaneous sessions converge on the smaller session ID.
            let secondWins = second.id < first.id
            if secondWins { replaced += 1 } else { kept += 1 }
            var winner = secondWins ? second : first
            let (winningRoute, losingRoute) = secondWins ? (secondRoute, firstRoute) : (firstRoute, secondRoute)

            XCTAssertEqual(node.core.sessions[remote.key]?.sessionID, winner.id, "seed \(seed)")
            XCTAssertEqual(Array(node.core.installedRoutes.keys), [winningRoute], "seed \(seed)")
            XCTAssertEqual(
                node.core.installedRoutes[winningRoute]?.link, node.core.sessions[remote.key]?.link)
            XCTAssertEqual(
                node.core.authenticatedPeer(for: remote.peer)?.route,
                .relayed(carrier: carrier.key, routeID: winningRoute), "seed \(seed)")
            XCTAssertEqual(node.core.links.values.filter { !$0.isDirect }.count, 1, "seed \(seed)")
            XCTAssertEqual(carrier.takeCloses(), [losingRoute], "seed \(seed)")
            // A replacement is not a disconnect.
            XCTAssertEqual(node.disconnected, [], "seed \(seed)")
            XCTAssertEqual(
                node.connected.filter { $0.id == remote.peer }.map(\.route),
                [.relayed(carrier: carrier.key, routeID: firstRoute)]
                    + (secondWins ? [.relayed(carrier: carrier.key, routeID: secondRoute)] : []),
                "seed \(seed)")
            XCTAssertEqual(node.ledger.violations(of: remote.peer), 0)

            // The surviving session still carries records on its route.
            carrier.sendPacket(winner.seal(.ping(nonce: 3)), on: winningRoute)
            XCTAssertEqual(
                carrier.takePackets(on: winningRoute).map { winner.open($0)?.pongNonce }, [3],
                "seed \(seed)")

            // With nothing to preserve, the route goes with the peer.
            sim.send(.command(.disconnect(remote.peer)), to: node)
            sim.run(for: .zero)
            assertNoRelayState(node, "node")
            XCTAssertEqual(carrier.takeCloses(), [winningRoute], "seed \(seed)")
            XCTAssertEqual(node.disconnected, [remote.peer], "seed \(seed)")
        }
        XCTAssertGreaterThan(replaced, 0, "no seed exercised a replacement")
        XCTAssertGreaterThan(kept, 0, "no seed exercised a kept session")
    }

    func testADirectSessionReplacingARelayedOneClosesItsRoute() {
        // The direct session is kept whichever has the smaller ID.
        var directSmaller = 0
        var relayedSmaller = 0
        for seed: UInt64 in 1...8 {
            let sim = Simulation(seed: seed)
            let carrierIdentity = sim.relayIdentity(1)
            let remote = sim.relayIdentity(2)
            let node = sim.relayNode(carriers: [carrierIdentity.endpoint])
            sim.run(for: .milliseconds(50))
            let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
            let routeID = relayRouteID(1)
            carrier.send(.relayOffer(routeID: routeID, sourceKey: remote.key))
            _ = carrier.take()
            guard let relayed = carrier.initiateRelayedSession(as: remote, on: routeID) else {
                return XCTFail("no relayed session")
            }

            // The same peer then reaches the node directly.
            let direct = RawRelayPeer(sim, to: node, as: remote)
            guard let directID = direct.session?.id else { return XCTFail("no direct session") }
            if directID < relayed.id { directSmaller += 1 } else { relayedSmaller += 1 }
            let directWins = true

            XCTAssertEqual(node.core.sessions[remote.key]?.sessionID, directWins ? directID : relayed.id)
            XCTAssertEqual(
                node.core.authenticatedPeer(for: remote.peer)?.route,
                directWins ? .direct : .relayed(carrier: carrier.key, routeID: routeID),
                "seed \(seed)")
            XCTAssertEqual(Array(node.core.installedRoutes.keys), directWins ? [] : [routeID], "seed \(seed)")
            XCTAssertEqual(carrier.takeCloses(), directWins ? [routeID] : [], "seed \(seed)")
            XCTAssertEqual(direct.nodeClosedConnection, !directWins, "seed \(seed)")
            XCTAssertEqual(node.core.links.values.filter { !$0.isDirect }.count, directWins ? 0 : 1)
            // Either way the peer stayed connected throughout.
            XCTAssertEqual(node.disconnected, [], "seed \(seed)")
            XCTAssertEqual(node.connected.filter { $0.id == remote.peer }.count, directWins ? 2 : 1, "seed \(seed)")
            XCTAssertEqual(node.core.connectedPeers, [remote.peer], "seed \(seed)")
            XCTAssertEqual(node.ledger.violations(of: remote.peer), 0)
            XCTAssertTrue(carrier.isConnected)
        }
        XCTAssertGreaterThan(directSmaller, 0, "no seed gave the direct session the smaller ID")
        XCTAssertGreaterThan(relayedSmaller, 0, "no seed gave the relayed session the smaller ID")
    }

    func testCleanupPreservesOnlyTheRouteOfTheLinkNamed() {
        guard let (_, node, carrier, remote, routeID, _) = installedSession() else { return }
        guard let link = node.core.sessions[remote.key]?.link else { return XCTFail("no session") }

        // As promotion calls it for a session replacing another on this link.
        var preserved = node.core
        preserved.removeRoutes(involving: remote.key, preserving: link)
        XCTAssertEqual(Array(preserved.installedRoutes.keys), [routeID])
        XCTAssertNotNil(preserved.links[link])

        var cleared = node.core
        cleared.removeRoutes(involving: remote.key)
        XCTAssertTrue(cleared.installedRoutes.isEmpty)
        XCTAssertNil(cleared.links[link])
        XCTAssertTrue(carrier.isConnected)
    }

    // MARK: - Relayed link limits

    func testARelayedLinkQueuesFourRecordsBehindABlockedOneThenCloses() {
        let sim = Simulation()
        let (c, a, b) = sim.relayTriangle()
        guard sim.connectRelayed(a, b) != nil,
              let link = b.core.sessions[a.key]?.link else { return XCTFail("no session") }
        XCTAssertEqual(IvyCore.maxInboundBufferedRecords, 4)
        b.holdsDeliveries = true

        // One with the application, four waiting behind it.
        for index: UInt8 in 0..<5 {
            guard case .enqueued? = sim.await(
                .send(to: b.peer, topic: "t", payload: Data([index])), on: a)?.sent else {
                return XCTFail("message \(index) was not sent")
            }
        }
        sim.run(for: .seconds(1))
        XCTAssertEqual(b.received.map(\.message.payload), [Data([0])])
        XCTAssertEqual(b.core.links[link]?.queue.count, 4)
        XCTAssertNotNil(b.core.authenticatedPeer(for: a.peer))
        XCTAssertGreaterThan(b.core.diagnostics.inboundBytesUsed, 0)

        // A fifth does not fit: the link closes, and nobody is blamed for
        // what a carrier could have caused.
        _ = sim.await(.send(to: b.peer, topic: "t", payload: Data([5])), on: a)
        sim.run(for: .seconds(1))
        XCTAssertNil(b.core.links[link])
        XCTAssertNil(b.core.authenticatedPeer(for: a.peer))
        XCTAssertEqual(b.disconnected, [a.peer])
        XCTAssertEqual(b.ledger.violations(of: a.peer), 0)
        XCTAssertEqual(b.ledger.violations(of: c.peer), 0)
        XCTAssertNotNil(b.core.sessions[c.key])
        assertNoRelayState(b, "b")
        XCTAssertEqual(b.core.diagnostics.inboundBytesUsed, 0)
        // The route was handed back to the carrier.
        assertNoRelayState(c, "carrier")

        // Nothing queued is delivered after the close.
        sim.releaseDeliveries(b)
        sim.run(for: .seconds(1))
        XCTAssertEqual(b.received.count, 1)
    }

    func testARelayedLinkOutOfByteBudgetCloses() {
        let frame: UInt32 = 256 * 1024
        guard let (sim, node, carrier, remote, routeID, session) = installedSession(frame: frame),
              let link = node.core.sessions[remote.key]?.link else { return XCTFail("no session") }
        var sender = session
        node.holdsDeliveries = true
        // Each record is most of a frame; the link may hold two frames.
        let payload = Data(repeating: 7, count: Int(frame) - 1_000)
        XCTAssertEqual(node.core.links[link]?.budgetLimit, 2 * Int(frame) + 4)

        carrier.sendPacket(sender.seal(.peerMessage(topic: "t", payload: payload)), on: routeID)
        carrier.sendPacket(sender.seal(.peerMessage(topic: "t", payload: payload)), on: routeID)
        sim.run(for: .zero)
        XCTAssertEqual(node.received.count, 1)
        XCTAssertEqual(node.core.links[link]?.queue.count, 1)
        XCTAssertGreaterThan(node.core.diagnostics.inboundBytesUsed, 2 * payload.count)
        XCTAssertNotNil(node.core.authenticatedPeer(for: remote.peer))

        // Well short of four queued records, but past the byte budget.
        carrier.sendPacket(sender.seal(.peerMessage(topic: "t", payload: payload)), on: routeID)
        sim.run(for: .zero)
        XCTAssertNil(node.core.links[link])
        XCTAssertEqual(node.disconnected, [remote.peer])
        XCTAssertEqual(node.ledger.violations(of: remote.peer), 0)
        XCTAssertEqual(node.ledger.violations(of: carrier.identity.peer), 0)
        XCTAssertTrue(carrier.isConnected)
        XCTAssertEqual(carrier.takeCloses(), [routeID])
        assertNoRelayState(node, "node")
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0)
    }

    func testARelayedRecordLargerThanAFrameClosesTheLink() {
        let frame: UInt32 = 256 * 1024
        guard let (sim, node, carrier, remote, routeID, _) = installedSession(frame: frame) else { return }
        // The carrier's own frame can hold it only when the test lies about sizes;
        // an empty record is the smallest thing a link cannot take.
        carrier.sendPacket(Data(), on: routeID)
        sim.run(for: .zero)
        XCTAssertEqual(node.disconnected, [remote.peer])
        XCTAssertEqual(node.ledger.violations(of: remote.peer), 0)
        XCTAssertEqual(node.ledger.violations(of: carrier.identity.peer), 0)
        XCTAssertEqual(carrier.takeCloses(), [routeID])
        assertNoRelayState(node, "node")
    }

    // MARK: - Attribution

    private func assertSessionEnded(
        _ node: Node,
        carrier: RawRelayPeer,
        remote: RelayTestIdentity,
        routeID: Data,
        blamed: Int,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(node.disconnected, [remote.peer], label, file: file, line: line)
        XCTAssertNil(node.core.authenticatedPeer(for: remote.peer), label, file: file, line: line)
        XCTAssertEqual(node.ledger.violations(of: remote.peer), blamed, label, file: file, line: line)
        // A carrier is never blamed for what it carried.
        XCTAssertEqual(node.ledger.violations(of: carrier.identity.peer), 0, label, file: file, line: line)
        XCTAssertTrue(carrier.isConnected, label, file: file, line: line)
        XCTAssertEqual(carrier.takeCloses(), [routeID], label, file: file, line: line)
        assertNoRelayState(node, "node (\(label))", file: file, line: line)
    }

    func testASignedMalformedPayloadOverRelayIsAttributedToTheEndpoint() {
        guard let (sim, node, carrier, remote, routeID, session) = installedSession() else { return }
        var sender = session

        // A message this version does not know is ignored.
        carrier.sendPacket(sender.seal(payload: Data([200, 1, 2, 3])), on: routeID)
        carrier.sendPacket(sender.seal(.ping(nonce: 4)), on: routeID)
        sim.run(for: .zero)
        XCTAssertEqual(carrier.takePackets(on: routeID).map { sender.open($0)?.pongNonce }, [4])
        XCTAssertEqual(node.ledger.violations(of: remote.peer), 0)

        // A known message that does not decode, under the endpoint's own signature.
        carrier.sendPacket(sender.seal(payload: Data([49])), on: routeID)
        sim.run(for: .zero)
        assertSessionEnded(node, carrier: carrier, remote: remote, routeID: routeID, blamed: 1, "malformed")
    }

    func testAnEndpointSendingRelayControlOverItsRelayedSessionIsAttributed() {
        guard let (sim, node, carrier, remote, routeID, session) = installedSession() else { return }
        var sender = session
        // Relay control rides direct sessions only.
        carrier.sendPacket(sender.seal(.relayClose(routeID: relayRouteID(9))), on: routeID)
        sim.run(for: .zero)
        assertSessionEnded(node, carrier: carrier, remote: remote, routeID: routeID, blamed: 1, "nested control")
    }

    func testReplayAndSequenceFailureOverRelayAreNotAttributed() {
        // A carrier can replay or reorder what it carries.
        let cases: [(String, (inout RelayTestSession) -> [Data])] = [
            ("replay", { session in
                let record = session.seal(.ping(nonce: 1))
                return [record, record]
            }),
            ("stale sequence", { session in
                let first = session.seal(.ping(nonce: 1))
                let second = session.seal(.ping(nonce: 1))
                return [second, first]
            }),
        ]
        for (label, records) in cases {
            guard let (sim, node, carrier, remote, routeID, session) = installedSession() else { return }
            var sender = session
            let sent = records(&sender)
            carrier.sendPacket(sent[0], on: routeID)
            sim.run(for: .zero)
            XCTAssertEqual(carrier.takePackets(on: routeID).map { sender.open($0)?.pongNonce }, [1], label)
            XCTAssertNotNil(node.core.authenticatedPeer(for: remote.peer), label)

            carrier.sendPacket(sent[1], on: routeID)
            sim.run(for: .zero)
            XCTAssertTrue(carrier.takePackets(on: routeID).isEmpty, label)
            assertSessionEnded(node, carrier: carrier, remote: remote, routeID: routeID, blamed: 0, label)
        }
    }

    func testUnsignedOrForgedRecordsOverRelayAreNotAttributed() {
        let cases: [(String, (RelayTestSession, RelayTestIdentity, Simulation.Node) -> Data)] = [
            ("garbage", { _, _, _ in Data([1, 2, 3, 4, 5, 6, 7, 8]) }),
            ("signed by the carrier", { session, carrier, node in
                RelayTestSession(local: carrier, remote: node.key, id: session.id)
                    .seal(payload: Message.ping(nonce: 1).serialize(), sequence: 1)
            }),
            ("another session", { session, _, node in
                RelayTestSession(
                    local: session.local, remote: node.key,
                    id: try! SessionID(bytes: Data(repeating: 3, count: 32)))
                    .seal(payload: Message.ping(nonce: 1).serialize(), sequence: 1)
            }),
            ("a handshake record on a live session", { session, _, node in
                SessionWireRecord.helloInitiator(RelayTestHandshake.hello(
                    from: session.local, to: node.key, routeBinding: relayRouteID(1), nonce: 7)).serialize()
            }),
        ]
        for (label, record) in cases {
            guard let (sim, node, carrier, remote, routeID, session) = installedSession() else { return }
            carrier.sendPacket(record(session, carrier.identity, node), on: routeID)
            sim.run(for: .zero)
            XCTAssertTrue(carrier.takePackets(on: routeID).isEmpty, label)
            assertSessionEnded(node, carrier: carrier, remote: remote, routeID: routeID, blamed: 0, label)
        }
    }

    func testTheSameMalformedPayloadOnADirectSessionIsAttributedToItsSender() {
        let sim = Simulation()
        let node = sim.relayNode()
        let raw = RawRelayPeer(sim, to: node, as: sim.relayIdentity(1))
        raw.send(payload: Data([49]))
        sim.run(for: .zero)
        XCTAssertFalse(raw.isConnected)
        XCTAssertEqual(node.ledger.violations(of: raw.identity.peer), 1)
    }

    // MARK: - The relayed handshake

    func testTheRelayedHandshakeMustMatchTheOfferedRouteAndPeer() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let offered = sim.relayIdentity(2)
        let impostor = sim.relayIdentity(3)
        let node = sim.relayNode(carriers: [carrierIdentity.endpoint])
        sim.run(for: .milliseconds(50))
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)

        func offer(_ marker: UInt8) -> Data {
            let routeID = relayRouteID(marker)
            carrier.send(.relayOffer(routeID: routeID, sourceKey: offered.key))
            XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [0])
            return routeID
        }
        func assertRefused(_ routeID: Data, _ label: String, line: UInt = #line) {
            sim.run(for: .zero)
            XCTAssertTrue(carrier.takePackets(on: routeID).isEmpty, label, line: line)
            XCTAssertEqual(carrier.takeCloses(), [routeID], label, line: line)
            assertNoRelayState(node, "node (\(label))", line: line)
            XCTAssertEqual(node.core.diagnostics.pendingSessions, 0, label, line: line)
        }

        // A hello bound to some other route, or to the direct binding.
        var routeID = offer(1)
        XCTAssertNil(carrier.initiateRelayedSession(as: offered, on: routeID, routeBinding: relayRouteID(9)))
        assertRefused(routeID, "other binding")
        routeID = offer(2)
        XCTAssertNil(carrier.initiateRelayedSession(
            as: offered, on: routeID, routeBinding: IvyCore.directRouteBinding))
        assertRefused(routeID, "direct binding")

        // A hello from someone the route was not offered for.
        routeID = offer(3)
        XCTAssertNil(carrier.initiateRelayedSession(as: impostor, on: routeID))
        assertRefused(routeID, "other initiator")

        // A hello naming the offered peer that the peer did not sign.
        routeID = offer(4)
        let genuine = RelayTestHandshake.hello(from: offered, to: node.key, routeBinding: routeID, nonce: 7)
        let forged = RelayTestHandshake.hello(from: impostor, to: node.key, routeBinding: routeID, nonce: 7)
        carrier.sendPacket(
            SessionWireRecord.helloInitiator(SignedSessionHelloInitiator(
                hello: genuine.hello, signature: forged.signature)).serialize(),
            on: routeID)
        assertRefused(routeID, "forged signature")

        // A hello for another responder.
        routeID = offer(5)
        carrier.sendPacket(
            SessionWireRecord.helloInitiator(RelayTestHandshake.hello(
                from: offered, to: impostor.key, routeBinding: routeID, nonce: 7)).serialize(),
            on: routeID)
        assertRefused(routeID, "other responder")

        // Anything but a hello first.
        routeID = offer(6)
        carrier.sendPacket(Data([1, 2, 3]), on: routeID)
        assertRefused(routeID, "not a hello")

        XCTAssertEqual(node.connected.map(\.key), [carrier.key])
        XCTAssertEqual(node.ledger.violations(of: carrier.identity.peer), 0)
        XCTAssertEqual(node.ledger.violations(of: offered.peer), 0)
        XCTAssertTrue(carrier.isConnected)

        // The offered peer, bound to the offered route, is authenticated.
        routeID = offer(7)
        XCTAssertNotNil(carrier.initiateRelayedSession(as: offered, on: routeID))
        let peer = node.core.authenticatedPeer(for: offered.peer)
        XCTAssertEqual(peer?.key, offered.key)
        XCTAssertEqual(peer?.role, .endpoint)
        XCTAssertEqual(peer?.route, .relayed(carrier: carrier.key, routeID: routeID))
        XCTAssertEqual(node.connected.last, peer)
        // A relayed peer has no address of its own to route to.
        XCTAssertFalse(node.core.knownPeerEndpoints.contains { $0.publicKey == offered.key.hex })
    }

    func testTheNodeAuthenticatesTheTargetItAskedForOverTheRoute() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let target = sim.relayIdentity(2)
        let impostor = sim.relayIdentity(3)

        // The right peer answers.
        do {
            let node = sim.relayNode(carriers: [carrierIdentity.endpoint])
            sim.run(for: .milliseconds(50))
            let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
            let request = sim.request(.connectViaRelay(target.endpoint), on: node)
            guard let routeID = carrier.take({ $0.relayOpenFields }).first?.routeID else {
                return XCTFail("no relayOpen")
            }
            carrier.send(.relayReady(routeID: routeID, status: 0))
            guard var session = carrier.answerRelayedSession(as: target, on: routeID) else {
                return XCTFail("no hello")
            }
            // The node's finish closes the handshake.
            guard case .finish(let finish)? = carrier.takePackets(on: routeID).first.flatMap({
                try? SessionWireRecord.deserialize($0)
            }) else { return XCTFail("no finish") }
            XCTAssertEqual(finish.sessionID, session.id)
            XCTAssertTrue(finish.isValid(using: target.scheme))
            sim.run(for: .milliseconds(50))
            XCTAssertEqual(sim.result(of: request, on: node), .connect(.connected))
            XCTAssertEqual(
                node.core.authenticatedPeer(for: target.peer)?.route,
                .relayed(carrier: carrier.key, routeID: routeID))
            XCTAssertEqual(node.core.authenticatedPeer(for: target.peer)?.sessionID, session.id.bytes)

            carrier.sendPacket(session.seal(.peerMessage(topic: "hi", payload: Data([1]))), on: routeID)
            sim.run(for: .zero)
            XCTAssertEqual(node.received.map(\.message.topic), ["hi"])
            XCTAssertEqual(node.received.first?.peer.id, target.peer)
        }

        // Someone else answers on the route: no session, and the route is returned.
        do {
            let node = sim.relayNode(carriers: [carrierIdentity.endpoint])
            sim.run(for: .milliseconds(50))
            let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
            let request = sim.request(.connectViaRelay(target.endpoint), on: node)
            guard let routeID = carrier.take({ $0.relayOpenFields }).first?.routeID else {
                return XCTFail("no relayOpen")
            }
            carrier.send(.relayReady(routeID: routeID, status: 0))
            _ = carrier.answerRelayedSession(as: impostor, on: routeID)
            sim.run(for: .milliseconds(50))
            XCTAssertEqual(sim.result(of: request, on: node), .connect(.failed(.noRelayAvailable)))
            XCTAssertEqual(carrier.takeCloses(), [routeID])
            XCTAssertTrue(carrier.takePackets(on: routeID).isEmpty)
            assertNoRelayState(node, "node")
            XCTAssertEqual(node.connected.map(\.key), [carrier.key])
            XCTAssertEqual(node.ledger.violations(of: carrier.identity.peer), 0)
        }
    }

    // MARK: - Cancelling a connect

    /// Reference: "task cancellation retires a pending relay open".
    func testCancellationRetiresRelayOpen() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let node = sim.relayNode(carriers: [carrierIdentity.endpoint])
        sim.run(for: .milliseconds(50))
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)

        let request = sim.request(.connectViaRelay(sim.relayIdentity(2).endpoint), on: node)
        XCTAssertEqual(node.core.pendingRelayOpens.count, 1)
        guard let routeID = carrier.take({ $0.relayOpenFields }).first?.routeID else {
            return XCTFail("no relayOpen")
        }

        sim.cancel(request, on: node)
        XCTAssertEqual(sim.result(of: request, on: node), .connect(.cancelled))
        XCTAssertEqual(node.core.pendingRelayOpens.count, 0)
        XCTAssertEqual(carrier.takeCloses(), [routeID])
        XCTAssertFalse(node.core.timers.isSet(.relayOpen(routeID)))
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)

        // The carrier's late answer opens nothing.
        carrier.send(.relayReady(routeID: routeID, status: 0))
        sim.run(for: .seconds(10))
        assertNoRelayState(node, "node")
        XCTAssertTrue(carrier.take().isEmpty)
        XCTAssertTrue(carrier.isConnected)

        sim.send(.command(.disconnect(carrier.identity.peer)), to: node)
        XCTAssertNil(node.core.sessions[carrier.key])
    }

    func testCancellationDuringTheRelayedHandshakeReturnsTheRoute() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let node = sim.relayNode(carriers: [carrierIdentity.endpoint])
        sim.run(for: .milliseconds(50))
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)

        let request = sim.request(.connectViaRelay(sim.relayIdentity(2).endpoint), on: node)
        guard let routeID = carrier.take({ $0.relayOpenFields }).first?.routeID else {
            return XCTFail("no relayOpen")
        }
        carrier.send(.relayReady(routeID: routeID, status: 0))
        XCTAssertEqual(carrier.takePackets(on: routeID).count, 1)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 1)

        sim.cancel(request, on: node)
        XCTAssertEqual(sim.result(of: request, on: node), .connect(.cancelled))
        XCTAssertEqual(carrier.takeCloses(), [routeID])
        assertNoRelayState(node, "node")
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertFalse(node.core.timers.isSet(.installedRoute(routeID)))
    }

    /// Reference: "manual disconnect cannot advance to another carrier".
    func testDisconnectStopsCarrierFailover() {
        let sim = Simulation()
        let identities = [sim.relayIdentity(1), sim.relayIdentity(2)].sorted { $0.key < $1.key }
        let target = sim.relayIdentity(3)
        // Configured in the opposite order: the key decides who is asked first.
        let node = sim.relayNode(carriers: identities.reversed().map(\.endpoint))
        sim.run(for: .milliseconds(50))
        let first = RawRelayPeer(sim, to: node, as: identities[0])
        let second = RawRelayPeer(sim, to: node, as: identities[1])

        let request = sim.request(.connectViaRelay(target.endpoint), on: node)
        XCTAssertEqual(node.core.pendingRelayOpens.count, 1)

        sim.send(.command(.disconnect(target.peer)), to: node)
        XCTAssertNotNil(sim.result(of: request, on: node))
        XCTAssertNotEqual(sim.result(of: request, on: node), .connect(.connected))

        let opens = first.take { $0.relayOpenFields }
        XCTAssertEqual(opens.map(\.target), [target.key])
        XCTAssertEqual(first.takeCloses(), opens.map(\.routeID))
        XCTAssertTrue(second.take().isEmpty)
        XCTAssertEqual(node.core.pendingRelayOpens.count, 0)
        sim.run(for: .seconds(10))
        XCTAssertTrue(second.take().isEmpty)
        assertNoRelayState(node, "node")
    }

    /// Reference: "relay close wins if it arrives before the ready continuation resumes".
    func testRelayCloseAfterReadyRetiresTheRoute() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let target = sim.relayIdentity(2)
        let node = sim.relayNode(carriers: [carrierIdentity.endpoint])
        sim.run(for: .milliseconds(50))
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)

        let request = sim.request(.connectViaRelay(target.endpoint), on: node)
        guard let routeID = carrier.take({ $0.relayOpenFields }).first?.routeID else {
            return XCTFail("no relayOpen")
        }
        // Both arrive before the node does anything else.
        carrier.send(.relayReady(routeID: routeID, status: 0))
        carrier.send(.relayClose(routeID: routeID))
        sim.run(for: .zero)

        XCTAssertEqual(sim.result(of: request, on: node), .connect(.failed(.noRelayAvailable)))
        assertNoRelayState(node, "node")
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertTrue(carrier.takeCloses().isEmpty)

        // The route is gone for good: a handshake reply on it is a no-op.
        _ = carrier.answerRelayedSession(as: target, on: routeID)
        sim.run(for: .zero)
        XCTAssertNil(node.core.authenticatedPeer(for: target.peer))
        XCTAssertTrue(carrier.isConnected)
        XCTAssertEqual(node.ledger.violations(of: carrier.identity.peer), 0)
    }
}
