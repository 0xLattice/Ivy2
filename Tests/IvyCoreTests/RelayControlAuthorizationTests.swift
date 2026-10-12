import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Who may send which relay control message, and how many routes a node
/// will hold. The test plays the peers by hand over raw connections.
final class RelayControlAuthorizationTests: XCTestCase {
    /// A node with `carriers` configured, once its first dials to them have failed.
    private func node(
        _ sim: Simulation,
        carriers: [RelayTestIdentity] = [],
        relayEnabled: Bool = false,
        mode: IvyMode = .overlay,
        maxConnections: Int = IvyConfig.defaultMaxConnections
    ) -> Simulation.Node {
        let node = sim.relayNode(
            carriers: carriers.map(\.endpoint), relayEnabled: relayEnabled, mode: mode,
            maxConnections: maxConnections)
        sim.run(for: .milliseconds(50))
        return node
    }

    /// Fills `node` with `count` installed routes offered by ordinary peers,
    /// eight to a peer. Identities from `firstIdentity` up are used.
    private func installFillerRoutes(
        _ count: Int,
        on node: Simulation.Node,
        sim: Simulation,
        firstIdentity: Int = 100
    ) {
        let source = sim.relayIdentity(99)
        var marker: UInt8 = 0
        var peer: RawRelayPeer?
        for index in 0..<count {
            if index % IvyCore.maxRelayRoutesPerPeer == 0 {
                peer = RawRelayPeer(
                    sim, to: node,
                    as: sim.relayIdentity(firstIdentity + index / IvyCore.maxRelayRoutesPerPeer))
            }
            marker += 1
            peer?.send(.relayOffer(routeID: relayRouteID(marker), sourceKey: source.key))
        }
        XCTAssertEqual(node.core.installedRoutes.count, count)
    }

    private func assertRejected(
        _ raw: RawRelayPeer,
        violations: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(raw.isConnected, file: file, line: line)
        XCTAssertTrue(raw.nodeClosedConnection, file: file, line: line)
        XCTAssertEqual(
            raw.node.ledger.violations(of: raw.identity.peer), violations, file: file, line: line)
        XCTAssertTrue(raw.node.disconnected.contains(raw.identity.peer), file: file, line: line)
    }

    private func assertUnharmed(_ raw: RawRelayPeer, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(raw.isConnected, file: file, line: line)
        XCTAssertFalse(raw.nodeClosedConnection, file: file, line: line)
        XCTAssertEqual(raw.node.ledger.violations(of: raw.identity.peer), 0, file: file, line: line)
    }

    // MARK: - relayOpen

    func testRelayOpenIsAViolationWhereRelayIsDisabled() {
        let sim = Simulation()
        let node = node(sim)
        let source = RawRelayPeer(sim, to: node, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: node, as: sim.relayIdentity(2))

        source.send(.relayOpen(routeID: relayRouteID(1), targetKey: target.key))
        sim.run(for: .zero)
        assertRejected(source)
        XCTAssertTrue(source.take().isEmpty)
        XCTAssertTrue(target.take().isEmpty)
        assertUnharmed(target)
        assertNoRelayState(node, "node")
    }

    func testRelayOpenRefusalsAnswerStatusOne() {
        let sim = Simulation()
        let carrier = node(sim, relayEnabled: true)
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let other = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(3))
        let stranger = sim.relayIdentity(4)

        // A target the carrier holds no session with.
        source.send(.relayOpen(routeID: relayRouteID(1), targetKey: stranger.key))
        // Itself.
        source.send(.relayOpen(routeID: relayRouteID(2), targetKey: source.key))
        XCTAssertEqual(
            source.take { $0.relayReadyFields }.map { [$0.routeID, Data([$0.status])] },
            [[relayRouteID(1), Data([1])], [relayRouteID(2), Data([1])]])
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)

        // A good one is offered to the target and answered only once accepted.
        source.send(.relayOpen(routeID: relayRouteID(3), targetKey: target.key))
        let offers = target.take { $0.relayOfferFields }
        XCTAssertEqual(offers.map(\.routeID), [relayRouteID(3)])
        XCTAssertEqual(offers.map(\.source), [source.key])
        XCTAssertTrue(source.take().isEmpty)
        XCTAssertEqual(carrier.core.relayRoutes[relayRouteID(3)]?.ready, false)

        // A route ID in use, by its owner or by anyone, is a violation that
        // leaves the route and the session alone.
        source.send(.relayOpen(routeID: relayRouteID(3), targetKey: target.key))
        other.send(.relayOpen(routeID: relayRouteID(3), targetKey: target.key))
        other.send(.relayOpen(routeID: IvyCore.directRouteBinding, targetKey: target.key))
        sim.run(for: .zero)
        XCTAssertEqual(carrier.ledger.violations(of: source.identity.peer), 1)
        XCTAssertEqual(carrier.ledger.violations(of: other.identity.peer), 2)
        XCTAssertTrue(source.isConnected)
        XCTAssertTrue(other.isConnected)
        XCTAssertTrue(source.take().isEmpty)
        XCTAssertTrue(other.take().isEmpty)
        XCTAssertTrue(target.take().isEmpty)
        XCTAssertEqual(carrier.core.relayRoutes.count, 1)
        XCTAssertEqual(carrier.core.relayRoutes[relayRouteID(3)]?.source, source.key)

        // The target's refusal travels back with its status and ends the route.
        target.send(.relayAccept(routeID: relayRouteID(3), status: 7))
        XCTAssertEqual(source.take { $0.relayReadyFields }.map(\.status), [7])
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        XCTAssertFalse(carrier.core.timers.isSet(.relayRoute(relayRouteID(3))))
        assertUnharmed(target)
    }

    // MARK: - relayAccept

    func testRelayAcceptOnlyFromTheRoutesTarget() {
        let sim = Simulation()
        let carrier = node(sim, relayEnabled: true)
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let bystander = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(3))

        source.send(.relayOpen(routeID: relayRouteID(1), targetKey: target.key))
        bystander.send(.relayAccept(routeID: relayRouteID(1), status: 0))
        sim.run(for: .zero)
        assertRejected(bystander)
        XCTAssertEqual(carrier.core.relayRoutes[relayRouteID(1)]?.ready, false)
        XCTAssertTrue(source.take().isEmpty)

        target.send(.relayAccept(routeID: relayRouteID(1), status: 0))
        XCTAssertEqual(source.take { $0.relayReadyFields }.map(\.status), [0])
        XCTAssertEqual(carrier.core.relayRoutes[relayRouteID(1)]?.ready, true)

        // Nor may the source accept its own route.
        source.send(.relayOpen(routeID: relayRouteID(2), targetKey: target.key))
        source.send(.relayAccept(routeID: relayRouteID(2), status: 0))
        sim.run(for: .zero)
        assertRejected(source)
        XCTAssertTrue(source.take { $0.relayReadyFields }.isEmpty)
        // Its routes went with its session.
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        assertUnharmed(target)
    }

    func testRelayAcceptForNoRouteIsAViolationWhereRelayIsDisabled() {
        let sim = Simulation()
        let node = node(sim)
        let raw = RawRelayPeer(sim, to: node, as: sim.relayIdentity(1))
        raw.send(.relayAccept(routeID: relayRouteID(1), status: 0))
        sim.run(for: .zero)
        assertRejected(raw)
    }

    /// Reference: "configured carrier cannot accept in the wrong route direction".
    func testConfiguredCarrierCannotAcceptInTheWrongRouteDirection() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let node = node(sim, carriers: [carrierIdentity], relayEnabled: true)
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
        let target = RawRelayPeer(sim, to: node, as: sim.relayIdentity(2))
        XCTAssertEqual(node.core.sessions[carrier.key]?.role, .carrier)

        // The configured carrier is the source of a route this node carries.
        carrier.send(.relayOpen(routeID: relayRouteID(0x72), targetKey: target.key))
        XCTAssertEqual(target.take { $0.relayOfferFields }.map(\.source), [carrier.key])
        XCTAssertEqual(node.core.relayRoutes[relayRouteID(0x72)]?.source, carrier.key)

        carrier.send(.relayAccept(routeID: relayRouteID(0x72), status: 0))
        sim.run(for: .zero)
        assertRejected(carrier)
        XCTAssertTrue(node.core.relayRoutes.isEmpty)
        assertUnharmed(target)
    }

    // MARK: - relayReady

    /// Reference: "unconfigured overlay peers cannot inject unrelated relay state".
    func testUnrelatedRelayControlIsRejected() {
        let sim = Simulation()
        let node = node(sim)
        let raw = RawRelayPeer(sim, to: node, as: sim.relayIdentity(1))
        XCTAssertEqual(node.connected.map(\.id), [raw.identity.peer])

        raw.send(.relayReady(routeID: relayRouteID(1), status: 0))
        sim.run(for: .zero)
        assertRejected(raw)
        XCTAssertEqual(node.disconnected, [raw.identity.peer])
        XCTAssertEqual(node.core.peerConnectionCount, 0)
        assertNoRelayState(node, "node")
    }

    /// Reference: "a relay reply from the wrong carrier cannot consume pending state".
    func testRelayReadyIsCarrierScoped() {
        let sim = Simulation()
        let identities = [sim.relayIdentity(1), sim.relayIdentity(2)].sorted { $0.key < $1.key }
        let node = node(sim, carriers: identities)
        let expected = RawRelayPeer(sim, to: node, as: identities[0])
        let wrong = RawRelayPeer(sim, to: node, as: identities[1])
        let bystander = RawRelayPeer(sim, to: node, as: sim.relayIdentity(3))
        let target = sim.relayIdentity(4)

        let request = sim.request(.connectViaRelay(target.endpoint), on: node)
        let opens = expected.take { $0.relayOpenFields }
        XCTAssertEqual(opens.map(\.target), [target.key])
        XCTAssertTrue(wrong.take().isEmpty)
        guard let routeID = opens.first?.routeID else { return XCTFail("no relayOpen") }
        XCTAssertEqual(routeID.count, 32)
        XCTAssertEqual(node.core.pendingRelayOpens[routeID]?.carrier, expected.key)
        XCTAssertEqual(node.core.pendingRelayOpens[routeID]?.target, target.key)

        // Neither an ordinary peer nor another configured carrier may answer.
        bystander.send(.relayReady(routeID: routeID, status: 0))
        wrong.send(.relayReady(routeID: routeID, status: 0))
        sim.run(for: .zero)
        assertRejected(bystander)
        assertRejected(wrong)
        XCTAssertEqual(node.core.pendingRelayOpens.count, 1)
        XCTAssertTrue(node.core.installedRoutes.isEmpty)
        XCTAssertNil(sim.result(of: request, on: node))

        expected.send(.relayReady(routeID: routeID, status: 1))
        sim.run(for: .zero)
        XCTAssertEqual(sim.result(of: request, on: node), .connect(.failed(.noRelayAvailable)))
        assertNoRelayState(node, "node")
        XCTAssertFalse(node.core.timers.isSet(.relayOpen(routeID)))
        // A refusal needs no close.
        XCTAssertTrue(expected.takeCloses().isEmpty)
        assertUnharmed(expected)

        // A reply that arrives after the open is gone is ignored.
        expected.send(.relayReady(routeID: routeID, status: 0))
        sim.run(for: .zero)
        assertUnharmed(expected)
        assertNoRelayState(node, "node")
    }

    // MARK: - relayPacket and relayClose

    func testPacketsAndCloseOnlyFromParticipantsOfACarriedRoute() {
        let sim = Simulation()
        let carrier = node(sim, relayEnabled: true)
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let first = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(3))
        let second = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(4))
        let routeID = relayRouteID(1)
        source.send(.relayOpen(routeID: routeID, targetKey: target.key))
        target.send(.relayAccept(routeID: routeID, status: 0))
        _ = source.take()
        _ = target.take()

        first.sendPacket(Data([1, 2, 3]), on: routeID)
        second.send(.relayClose(routeID: routeID))
        sim.run(for: .zero)
        assertRejected(first)
        assertRejected(second)
        XCTAssertEqual(carrier.core.relayRoutes[routeID]?.ready, true)
        XCTAssertTrue(source.take().isEmpty)
        XCTAssertTrue(target.take().isEmpty)

        source.sendPacket(Data([4, 5, 6]), on: routeID)
        XCTAssertEqual(target.takePackets(on: routeID), [Data([4, 5, 6])])
        assertUnharmed(source)
        assertUnharmed(target)
    }

    func testPacketsAndCloseOnlyFromTheCarrierOfAnInstalledOrPendingRoute() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let node = node(sim, carriers: [carrierIdentity])
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
        let remote = sim.relayIdentity(2)
        let installed = relayRouteID(1)
        carrier.send(.relayOffer(routeID: installed, sourceKey: remote.key))
        XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [0])
        sim.request(.connectViaRelay(sim.relayIdentity(3).endpoint), on: node)
        guard let pending = carrier.take({ $0.relayOpenFields }).first?.routeID else {
            return XCTFail("no relayOpen")
        }

        for (index, message) in [
            Message.relayPacket(routeID: installed, opaqueEndpointRecord: Data([1])),
            .relayClose(routeID: installed),
            .relayPacket(routeID: pending, opaqueEndpointRecord: Data([1])),
            .relayClose(routeID: pending),
            .relayAccept(routeID: installed, status: 0),
        ].enumerated() {
            let intruder = RawRelayPeer(sim, to: node, as: sim.relayIdentity(10 + index))
            intruder.send(message)
            sim.run(for: .zero)
            assertRejected(intruder)
        }
        XCTAssertEqual(Array(node.core.installedRoutes.keys), [installed])
        XCTAssertEqual(Array(node.core.pendingRelayOpens.keys), [pending])
        XCTAssertTrue(carrier.take().isEmpty)
        assertUnharmed(carrier)

        // The carrier itself may close both.
        carrier.send(.relayClose(routeID: installed))
        carrier.send(.relayClose(routeID: pending))
        sim.run(for: .zero)
        assertNoRelayState(node, "node")
        XCTAssertTrue(carrier.takeCloses().isEmpty)
        assertUnharmed(carrier)
    }

    /// Reference: "late route frames are idempotent after route retirement".
    func testLateRouteFramesAreNoOps() {
        let sim = Simulation()
        let carrier = node(sim, relayEnabled: true)
        let endpoint = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let neverExisted = relayRouteID(0x71)

        // A route that lived and was retired.
        let retired = relayRouteID(0x70)
        endpoint.send(.relayOpen(routeID: retired, targetKey: target.key))
        target.send(.relayAccept(routeID: retired, status: 0))
        endpoint.send(.relayClose(routeID: retired))
        sim.run(for: .zero)
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        _ = endpoint.take()
        _ = target.take()

        for routeID in [neverExisted, retired] {
            for peer in [endpoint, target] {
                peer.send(.relayAccept(routeID: routeID, status: 0))
                peer.send(.relayPacket(routeID: routeID, opaqueEndpointRecord: Data([1])))
                peer.send(.relayClose(routeID: routeID))
            }
        }
        endpoint.send(.peerMessage(topic: "after-late-route", payload: Data()))
        sim.run(for: .zero)
        XCTAssertEqual(carrier.received.map(\.message), [PeerMessage(topic: "after-late-route", payload: Data())])
        XCTAssertEqual(carrier.received.first?.peer.id, endpoint.identity.peer)
        assertUnharmed(endpoint)
        assertUnharmed(target)
        XCTAssertTrue(endpoint.take().isEmpty)
        XCTAssertTrue(target.take().isEmpty)
        assertNoRelayState(carrier, "carrier")

        // The direct binding is never a route.
        endpoint.send(.relayPacket(routeID: IvyCore.directRouteBinding, opaqueEndpointRecord: Data([1])))
        sim.run(for: .zero)
        assertRejected(endpoint)
        target.send(.relayClose(routeID: IvyCore.directRouteBinding))
        sim.run(for: .zero)
        assertRejected(target)
    }

    func testPacketsOnAnUnreadyRouteAreDropped() {
        let sim = Simulation()
        let carrier = node(sim, relayEnabled: true)
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        source.send(.relayOpen(routeID: relayRouteID(1), targetKey: target.key))
        _ = target.take()

        source.sendPacket(Data([1]), on: relayRouteID(1))
        target.sendPacket(Data([2]), on: relayRouteID(1))
        sim.run(for: .zero)
        XCTAssertTrue(source.take().isEmpty)
        XCTAssertTrue(target.take().isEmpty)
        assertUnharmed(source)
        assertUnharmed(target)
        XCTAssertEqual(carrier.core.relayRoutes[relayRouteID(1)]?.ready, false)
    }

    // MARK: - Limits as a carrier

    func testCarrierHoldsAtMostEightRoutesPerSource() {
        let sim = Simulation()
        let carrier = node(sim, relayEnabled: true)
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let limit = IvyCore.maxRelayRoutesPerPeer
        XCTAssertEqual(limit, 8)

        for marker in 1...(limit + 1) {
            source.send(.relayOpen(routeID: relayRouteID(UInt8(marker)), targetKey: target.key))
        }
        XCTAssertEqual(carrier.core.relayRoutes.count, limit)
        XCTAssertEqual(target.take { $0.relayOfferFields }.map(\.routeID), (1...limit).map { relayRouteID(UInt8($0)) })
        let refusals = source.take { $0.relayReadyFields }
        XCTAssertEqual(refusals.map(\.routeID), [relayRouteID(UInt8(limit + 1))])
        XCTAssertEqual(refusals.map(\.status), [1])
        assertUnharmed(source)

        // The limit is per source: the target may open routes of its own.
        target.send(.relayOpen(routeID: relayRouteID(100), targetKey: source.key))
        XCTAssertEqual(source.take { $0.relayOfferFields }.map(\.routeID), [relayRouteID(100)])
        XCTAssertEqual(carrier.core.relayRoutes.count, limit + 1)

        // Closing one makes room for one.
        source.send(.relayClose(routeID: relayRouteID(1)))
        source.send(.relayOpen(routeID: relayRouteID(UInt8(limit + 1)), targetKey: target.key))
        XCTAssertEqual(target.take { $0.relayOfferFields }.map(\.routeID), [relayRouteID(UInt8(limit + 1))])
        XCTAssertEqual(carrier.core.relayRoutes.count, limit + 1)
        XCTAssertNil(carrier.core.relayRoutes[relayRouteID(1)])
    }

    func testCarrierHoldsAtMostSixtyFourRoutes() {
        let sim = Simulation()
        let carrier = node(sim, relayEnabled: true)
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        XCTAssertEqual(IvyCore.maxRelayRoutes, 64)
        let perPeer = IvyCore.maxRelayRoutesPerPeer
        var marker: UInt8 = 0
        for index in 0..<(IvyCore.maxRelayRoutes / perPeer) {
            let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(10 + index))
            for _ in 0..<perPeer {
                marker += 1
                source.send(.relayOpen(routeID: relayRouteID(marker), targetKey: target.key))
            }
            XCTAssertTrue(source.take().isEmpty)
        }
        XCTAssertEqual(carrier.core.relayRoutes.count, IvyCore.maxRelayRoutes)
        XCTAssertEqual(target.take { $0.relayOfferFields }.count, IvyCore.maxRelayRoutes)

        let late = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(50))
        late.send(.relayOpen(routeID: relayRouteID(200), targetKey: target.key))
        let refusals = late.take { $0.relayReadyFields }
        XCTAssertEqual(refusals.map(\.routeID), [relayRouteID(200)])
        XCTAssertEqual(refusals.map(\.status), [1])
        XCTAssertTrue(target.take().isEmpty)
        XCTAssertEqual(carrier.core.relayRoutes.count, IvyCore.maxRelayRoutes)
        assertUnharmed(late)
    }

    // MARK: - Limits as an endpoint

    /// Reference: "inbound offers from one authenticated carrier remain bounded".
    func testInboundOfferCap() {
        let sim = Simulation()
        let node = node(sim)
        // Any direct peer may offer: an offer grants transport, not authority.
        let carrier = RawRelayPeer(sim, to: node, as: sim.relayIdentity(1))
        let source = sim.relayIdentity(2)
        XCTAssertEqual(node.core.sessions[carrier.key]?.role, .endpoint)

        carrier.send(.relayOffer(routeID: IvyCore.directRouteBinding, sourceKey: source.key))
        carrier.send(.relayOffer(routeID: relayRouteID(0xff), sourceKey: carrier.key))
        XCTAssertEqual(node.core.installedRoutes.count, 0)
        XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [1, 1])

        let limit = IvyCore.maxRelayRoutesPerPeer
        for marker in 1...(limit + 1) {
            carrier.send(.relayOffer(routeID: relayRouteID(UInt8(marker)), sourceKey: source.key))
        }
        XCTAssertEqual(node.core.installedRoutes.count, limit)
        let answers = carrier.take { $0.relayAcceptFields }
        XCTAssertEqual(answers.map(\.routeID), (1...(limit + 1)).map { relayRouteID(UInt8($0)) })
        XCTAssertEqual(answers.map(\.status), Array(repeating: 0, count: limit) + [1])
        XCTAssertTrue(node.core.installedRoutes.values.allSatisfy {
            $0.carrier == carrier.key && $0.remote == source.key && $0.link == nil
        })
        assertUnharmed(carrier)
        // An offer is not a session.
        XCTAssertEqual(node.core.connectedPeers, [carrier.identity.peer])

        sim.send(.command(.disconnect(carrier.identity.peer)), to: node)
        assertNoRelayState(node, "node")
        XCTAssertEqual(node.core.diagnostics.deadlines, 1)
        XCTAssertTrue(node.core.timers.isSet(.routingRefresh))
    }

    func testOfferRefusals() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let pinned = sim.relayIdentity(2)
        let stranger = sim.relayIdentity(3)

        // Offers naming this node, or a configured carrier, as their source.
        let node = node(sim, carriers: [carrierIdentity])
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
        let other = RawRelayPeer(sim, to: node, as: sim.relayIdentity(4))
        carrier.send(.relayOffer(routeID: relayRouteID(1), sourceKey: node.key))
        other.send(.relayOffer(routeID: relayRouteID(2), sourceKey: carrierIdentity.key))
        XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [1])
        XCTAssertEqual(other.take { $0.relayAcceptFields }.map(\.status), [1])
        // A route ID already in use.
        carrier.send(.relayOffer(routeID: relayRouteID(3), sourceKey: stranger.key))
        other.send(.relayOffer(routeID: relayRouteID(3), sourceKey: stranger.key))
        XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [0])
        XCTAssertEqual(other.take { $0.relayAcceptFields }.map(\.status), [1])
        XCTAssertEqual(node.core.installedRoutes[relayRouteID(3)]?.carrier, carrier.key)
        XCTAssertEqual(node.core.installedRoutes.count, 1)
        assertUnharmed(carrier)
        assertUnharmed(other)

        // A pinned node takes offers from its one peer only.
        let pinnedNode = self.node(sim, carriers: [carrierIdentity], mode: .pinned(peer: pinned.key.hex))
        let pinnedCarrier = RawRelayPeer(sim, to: pinnedNode, as: carrierIdentity)
        pinnedCarrier.send(.relayOffer(routeID: relayRouteID(4), sourceKey: stranger.key))
        pinnedCarrier.send(.relayOffer(routeID: relayRouteID(5), sourceKey: pinned.key))
        XCTAssertEqual(pinnedCarrier.take { $0.relayAcceptFields }.map(\.status), [1, 0])
        XCTAssertEqual(Array(pinnedNode.core.installedRoutes.keys), [relayRouteID(5)])
    }

    func testEndpointHoldsAtMostSixtyFourInstalledRoutes() {
        let sim = Simulation()
        let node = node(sim)
        installFillerRoutes(IvyCore.maxRelayRoutes, on: node, sim: sim)

        let late = RawRelayPeer(sim, to: node, as: sim.relayIdentity(1))
        late.send(.relayOffer(routeID: relayRouteID(200), sourceKey: sim.relayIdentity(2).key))
        let answers = late.take { $0.relayAcceptFields }
        XCTAssertEqual(answers.map(\.routeID), [relayRouteID(200)])
        XCTAssertEqual(answers.map(\.status), [1])
        XCTAssertEqual(node.core.installedRoutes.count, IvyCore.maxRelayRoutes)
        assertUnharmed(late)
    }

    /// Reference: "pending relay opens reserve route capacity".
    func testPendingRelayOpenReservesCapacity() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let source = sim.relayIdentity(2)
        let node = node(sim, carriers: [carrierIdentity])
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
        installFillerRoutes(IvyCore.maxRelayRoutes - 1, on: node, sim: sim)

        let request = sim.request(.connectViaRelay(source.endpoint), on: node)
        XCTAssertEqual(node.core.pendingRelayOpens.count, 1)
        guard let pendingRoute = carrier.take({ $0.relayOpenFields }).first?.routeID else {
            return XCTFail("no relayOpen")
        }

        // The pending open holds the last slot.
        carrier.send(.relayOffer(routeID: relayRouteID(0xfd), sourceKey: source.key))
        XCTAssertEqual(node.core.installedRoutes.count, IvyCore.maxRelayRoutes - 1)
        XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [1])

        // A route installed past the reservation (as the reference test
        // forces one) leaves the reply nowhere to go.
        node.core.installedRoutes[relayRouteID(0xfc)] = InstalledRoute(
            carrier: sim.relayIdentity(90).key, remote: source.key)
        carrier.send(.relayReady(routeID: pendingRoute, status: 0))
        sim.run(for: .zero)
        XCTAssertEqual(sim.result(of: request, on: node), .connect(.failed(.noRelayAvailable)))
        XCTAssertEqual(carrier.takeCloses(), [pendingRoute])
        XCTAssertTrue(node.core.pendingRelayOpens.isEmpty)
        XCTAssertNil(node.core.installedRoutes[pendingRoute])
        XCTAssertEqual(node.core.installedRoutes.count, IvyCore.maxRelayRoutes)
        XCTAssertTrue(node.core.links.values.allSatisfy(\.isDirect))
        assertUnharmed(carrier)
    }

    /// Reference: "pending relay opens reserve per-carrier capacity".
    func testPendingRelayOpenReservesCarrierCapacity() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let source = sim.relayIdentity(2)
        let node = node(sim, carriers: [carrierIdentity])
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
        let limit = IvyCore.maxRelayRoutesPerPeer
        for marker in 1..<limit {
            carrier.send(.relayOffer(routeID: relayRouteID(UInt8(marker)), sourceKey: source.key))
        }
        XCTAssertEqual(node.core.installedRoutes.count, limit - 1)
        _ = carrier.take()

        let request = sim.request(.connectViaRelay(sim.relayIdentity(3).endpoint), on: node)
        XCTAssertEqual(node.core.pendingRelayOpens.count, 1)
        guard let pendingRoute = carrier.take({ $0.relayOpenFields }).first?.routeID else {
            return XCTFail("no relayOpen")
        }

        carrier.send(.relayOffer(routeID: relayRouteID(0x82), sourceKey: source.key))
        XCTAssertEqual(node.core.installedRoutes.count, limit - 1)
        XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [1])

        carrier.send(.relayReady(routeID: pendingRoute, status: 1))
        sim.run(for: .zero)
        XCTAssertEqual(sim.result(of: request, on: node), .connect(.failed(.noRelayAvailable)))
        XCTAssertTrue(node.core.pendingRelayOpens.isEmpty)

        // With the carrier's eight slots taken, it is not asked at all.
        carrier.send(.relayOffer(routeID: relayRouteID(0x83), sourceKey: source.key))
        XCTAssertEqual(node.core.installedRoutes.count, limit)
        _ = carrier.take()
        XCTAssertEqual(
            sim.await(.connectViaRelay(sim.relayIdentity(3).endpoint), on: node),
            .connect(.failed(.noRelayAvailable)))
        XCTAssertTrue(carrier.take().isEmpty)
    }

    /// Reference: "carrier retry rechecks global route capacity".
    func testCarrierRetryRechecksGlobalCapacity() {
        let sim = Simulation()
        let identities = [sim.relayIdentity(1), sim.relayIdentity(2)].sorted { $0.key < $1.key }
        let target = sim.relayIdentity(3)
        let node = node(sim, carriers: identities)
        let first = RawRelayPeer(sim, to: node, as: identities[0])
        let second = RawRelayPeer(sim, to: node, as: identities[1])
        installFillerRoutes(IvyCore.maxRelayRoutes - 1, on: node, sim: sim)

        let request = sim.request(.connectViaRelay(target.endpoint), on: node)
        XCTAssertEqual(node.core.pendingRelayOpens.count, 1)
        guard let pendingRoute = first.take({ $0.relayOpenFields }).first?.routeID else {
            return XCTFail("the first carrier in key order was not asked")
        }

        // The table fills while the first carrier is deciding.
        node.core.installedRoutes[relayRouteID(0xf0)] = InstalledRoute(
            carrier: sim.relayIdentity(90).key, remote: target.key)
        first.send(.relayReady(routeID: pendingRoute, status: 1))
        sim.run(for: .zero)

        XCTAssertEqual(sim.result(of: request, on: node), .connect(.failed(.noRelayAvailable)))
        XCTAssertTrue(first.takeCloses().isEmpty)
        XCTAssertTrue(second.take().isEmpty)
        XCTAssertTrue(node.core.pendingRelayOpens.isEmpty)
        assertUnharmed(first)
        assertUnharmed(second)
    }

    /// Reference: "a relayed initiator cannot bypass the global connection cap".
    func testRelayedInitiatorObeysConnectionCapacity() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let target = sim.relayIdentity(2)
        // Room for the carrier and one peer.
        let node = node(sim, carriers: [carrierIdentity], maxConnections: 2)
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
        let existing = RawRelayPeer(sim, to: node, as: sim.relayIdentity(3))
        XCTAssertEqual(node.core.connectionCapacityUsed, 2)

        let request = sim.request(.connectViaRelay(target.endpoint), on: node)
        guard let routeID = carrier.take({ $0.relayOpenFields }).first?.routeID else {
            return XCTFail("no relayOpen")
        }
        carrier.send(.relayReady(routeID: routeID, status: 0))
        sim.run(for: .zero)

        XCTAssertEqual(sim.result(of: request, on: node), .connect(.failed(.noRelayAvailable)))
        // No handshake was started; the route was handed back.
        XCTAssertTrue(carrier.takePackets(on: routeID).isEmpty)
        XCTAssertEqual(carrier.takeCloses(), [routeID])
        assertNoRelayState(node, "node")
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(node.core.connectionCapacityUsed, 2)
        assertUnharmed(carrier)
        assertUnharmed(existing)
    }
}
