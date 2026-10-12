import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// A carrier forwarding opaque records between two of its peers, and the
/// deadlines that bound a route at each end. The test plays the peers.
final class RelayForwardingTests: XCTestCase {
    private func carrier(
        _ sim: Simulation,
        requestTimeout: Duration = .seconds(15),
        relayTimeout: Duration = .seconds(5)
    ) -> Simulation.Node {
        let node = sim.relayNode(
            relayEnabled: true, requestTimeout: requestTimeout, relayTimeout: relayTimeout)
        sim.run(for: .milliseconds(50))
        return node
    }

    private func endpoint(
        _ sim: Simulation,
        carriers: [RelayTestIdentity],
        relayTimeout: Duration = .seconds(5)
    ) -> Simulation.Node {
        let node = sim.relayNode(carriers: carriers.map(\.endpoint), relayTimeout: relayTimeout)
        sim.run(for: .milliseconds(50))
        return node
    }

    /// Opens a ready route from `source` to `target` on the carrier both reach.
    private func openRoute(
        _ routeID: Data,
        from source: RawRelayPeer,
        to target: RawRelayPeer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        source.send(.relayOpen(routeID: routeID, targetKey: target.key))
        XCTAssertEqual(target.take { $0.relayOfferFields }.map(\.routeID), [routeID], file: file, line: line)
        target.send(.relayAccept(routeID: routeID, status: 0))
        XCTAssertEqual(source.take { $0.relayReadyFields }.map(\.status), [0], file: file, line: line)
    }

    private func packet(_ marker: UInt8, count: Int = 40_000) -> Data {
        Data(repeating: marker, count: count)
    }

    /// Stalls `target` and sends from `source` until the carrier holds a
    /// record: two fill the destination's send buffer, the third waits.
    private func holdSource(
        _ sim: Simulation,
        carrier: Simulation.Node,
        source: RawRelayPeer,
        target: RawRelayPeer,
        routeID: Data
    ) {
        sim.run(for: .milliseconds(50))
        sim.setRawStalled(true, target.connection, at: carrier)
        for marker: UInt8 in 1...3 { source.sendPacket(packet(marker), on: routeID) }
    }

    // MARK: - Forwarding

    func testCarrierForwardsInArrivalOrderToTheExactDestination() {
        let sim = Simulation()
        let carrier = carrier(sim)
        let peers = (1...4).map { RawRelayPeer(sim, to: carrier, as: sim.relayIdentity($0)) }
        let (s1, t1, s2, t2) = (peers[0], peers[1], peers[2], peers[3])
        let (r1, r2, r3) = (relayRouteID(1), relayRouteID(2), relayRouteID(3))
        openRoute(r1, from: s1, to: t1)
        openRoute(r2, from: s2, to: t2)
        // The same source, another destination.
        openRoute(r3, from: s1, to: t2)

        var sent: [Data: [Data]] = [:]
        for index: UInt8 in 0..<10 {
            for (peer, routeID, tag) in [(s1, r1, UInt8(0x10)), (s1, r3, 0x30), (s2, r2, 0x20), (t1, r1, 0x40)] {
                let record = Data([tag, index]) + Data(repeating: index, count: Int(index) * 7)
                peer.sendPacket(record, on: routeID)
                sent[Data([tag]), default: []].append(record)
            }
        }
        sim.run(for: .zero)

        // Opaque bytes, unchanged, in order, on the route's other end only.
        XCTAssertEqual(t1.takePackets(on: r1), sent[Data([0x10])])
        XCTAssertEqual(t2.takePackets(on: r3), sent[Data([0x30])])
        XCTAssertEqual(t2.takePackets(on: r2), sent[Data([0x20])])
        XCTAssertEqual(s1.takePackets(on: r1), sent[Data([0x40])])
        for peer in peers { XCTAssertTrue(peer.take().isEmpty) }

        XCTAssertEqual(carrier.core.relayRoutes.count, 3)
        XCTAssertTrue(carrier.core.links.values.allSatisfy { $0.block == nil })
        XCTAssertEqual(carrier.core.diagnostics.inboundBytesUsed, 0)
        XCTAssertTrue(carrier.received.isEmpty)
        for peer in peers { XCTAssertEqual(carrier.ledger.violations(of: peer.identity.peer), 0) }
    }

    func testABlockedDestinationHoldsTheSourceUntilWritable() {
        let sim = Simulation()
        let carrier = carrier(sim)
        let peers = (1...4).map { RawRelayPeer(sim, to: carrier, as: sim.relayIdentity($0)) }
        let (source, target, otherSource, otherTarget) = (peers[0], peers[1], peers[2], peers[3])
        let (routeID, otherRoute) = (relayRouteID(1), relayRouteID(2))
        openRoute(routeID, from: source, to: target)
        openRoute(otherRoute, from: otherSource, to: otherTarget)
        guard let sourceLink = carrier.core.linkByConnection[source.connection],
              let targetLink = carrier.core.linkByConnection[target.connection] else {
            return XCTFail("no links")
        }

        holdSource(sim, carrier: carrier, source: source, target: target, routeID: routeID)

        // The destination took two records and no more.
        XCTAssertEqual(target.takePackets(on: routeID), [packet(1), packet(2)])
        XCTAssertEqual(carrier.core.links[targetLink]?.writable, false)
        // The third is held with the source's connection: nothing more is read from it.
        XCTAssertEqual(
            carrier.core.links[sourceLink]?.block, .relayForward(routeID: routeID, record: packet(3)))
        XCTAssertFalse(sim.isReading(source.connection, at: carrier))
        XCTAssertTrue(carrier.core.timers.isSet(.relayForward(sourceLink)))
        XCTAssertGreaterThan(carrier.core.diagnostics.inboundBytesUsed, packet(3).count)

        source.sendPacket(packet(4), on: routeID)
        source.sendPacket(packet(5), on: routeID)
        source.send(.ping(nonce: 5))
        sim.run(for: .seconds(1))
        XCTAssertGreaterThan(sim.unreadBytes(on: source.connection, at: carrier), 2 * packet(4).count)
        XCTAssertTrue(target.take().isEmpty)
        XCTAssertTrue(source.take().isEmpty)

        // Other connections, and the same route the other way, carry on.
        otherSource.sendPacket(Data([9, 9]), on: otherRoute)
        XCTAssertEqual(otherTarget.takePackets(on: otherRoute), [Data([9, 9])])
        target.sendPacket(Data([8, 8]), on: routeID)
        XCTAssertEqual(source.takePackets(on: routeID), [Data([8, 8])])
        XCTAssertTrue(sim.isReading(target.connection, at: carrier))

        sim.setRawStalled(false, target.connection, at: carrier)
        sim.run(for: .milliseconds(200))

        // Everything arrives, in the order it was sent.
        XCTAssertEqual(target.takePackets(on: routeID), [packet(3), packet(4), packet(5)])
        XCTAssertEqual(source.take { $0.pongNonce }, [5])
        XCTAssertTrue(sim.isReading(source.connection, at: carrier))
        XCTAssertEqual(sim.unreadBytes(on: source.connection, at: carrier), 0)
        XCTAssertNil(carrier.core.links[sourceLink]?.block)
        XCTAssertFalse(carrier.core.timers.isSet(.relayForward(sourceLink)))
        XCTAssertTrue(carrier.core.writabilityWaiters.values.allSatisfy(\.isEmpty))
        XCTAssertEqual(carrier.core.diagnostics.inboundBytesUsed, 0)
        XCTAssertEqual(carrier.core.relayRoutes[routeID]?.ready, true)
        XCTAssertTrue(source.takeCloses().isEmpty)
        for peer in peers {
            XCTAssertTrue(peer.isConnected)
            XCTAssertEqual(carrier.ledger.violations(of: peer.identity.peer), 0)
        }
    }

    /// Reference: "a stalled relay destination expires and closes its route".
    func testStalledRelayDestinationExpiresAndClosesItsRoute() {
        let sim = Simulation()
        let carrier = carrier(sim, requestTimeout: .seconds(2))
        let peers = (1...4).map { RawRelayPeer(sim, to: carrier, as: sim.relayIdentity($0)) }
        let (source, target, otherSource, otherTarget) = (peers[0], peers[1], peers[2], peers[3])
        let (routeID, otherRoute) = (relayRouteID(1), relayRouteID(2))
        openRoute(routeID, from: source, to: target)
        openRoute(otherRoute, from: otherSource, to: otherTarget)
        guard let sourceLink = carrier.core.linkByConnection[source.connection] else {
            return XCTFail("no link")
        }

        holdSource(sim, carrier: carrier, source: source, target: target, routeID: routeID)
        XCTAssertFalse(sim.isReading(source.connection, at: carrier))
        source.sendPacket(packet(4), on: routeID)
        source.send(.ping(nonce: 6))

        // Held for `requestTimeout`, measured from when the record first waited.
        sim.run(for: .milliseconds(1_900))
        XCTAssertNotNil(carrier.core.relayRoutes[routeID])
        XCTAssertFalse(sim.isReading(source.connection, at: carrier))

        sim.run(for: .milliseconds(200))
        XCTAssertNil(carrier.core.relayRoutes[routeID])
        XCTAssertFalse(carrier.core.timers.isSet(.relayRoute(routeID)))
        XCTAssertFalse(carrier.core.timers.isSet(.relayForward(sourceLink)))
        XCTAssertTrue(carrier.core.writabilityWaiters.values.allSatisfy(\.isEmpty))
        // The source is read again; what it had queued for the dead route is dropped.
        XCTAssertTrue(sim.isReading(source.connection, at: carrier))
        XCTAssertEqual(sim.unreadBytes(on: source.connection, at: carrier), 0)
        XCTAssertNil(carrier.core.links[sourceLink]?.block)
        XCTAssertEqual(carrier.core.diagnostics.inboundBytesUsed, 0)
        XCTAssertEqual(source.take { $0.pongNonce }, [6])

        // Only that route went: both sessions and the other route stand.
        XCTAssertEqual(Array(carrier.core.relayRoutes.keys), [otherRoute])
        otherSource.sendPacket(Data([9]), on: otherRoute)
        XCTAssertEqual(otherTarget.takePackets(on: otherRoute), [Data([9])])
        for peer in peers {
            XCTAssertTrue(peer.isConnected)
            XCTAssertEqual(carrier.ledger.violations(of: peer.identity.peer), 0)
        }

        // The destination wakes to the two records it had taken, nothing later.
        sim.setRawStalled(false, target.connection, at: carrier)
        sim.run(for: .milliseconds(200))
        XCTAssertEqual(target.takePackets(on: routeID), [packet(1), packet(2)])
    }

    func testADestinationThatLeavesReleasesTheHeldSource() {
        let sim = Simulation()
        let carrier = carrier(sim)
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let routeID = relayRouteID(1)
        openRoute(routeID, from: source, to: target)
        guard let sourceLink = carrier.core.linkByConnection[source.connection] else {
            return XCTFail("no link")
        }
        holdSource(sim, carrier: carrier, source: source, target: target, routeID: routeID)
        XCTAssertFalse(sim.isReading(source.connection, at: carrier))

        sim.closeRaw(target.connection, at: carrier)
        sim.run(for: .zero)
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        XCTAssertTrue(sim.isReading(source.connection, at: carrier))
        XCTAssertNil(carrier.core.links[sourceLink]?.block)
        XCTAssertFalse(carrier.core.timers.isSet(.relayForward(sourceLink)))
        XCTAssertTrue(carrier.core.writabilityWaiters.values.allSatisfy(\.isEmpty))
        XCTAssertEqual(carrier.core.diagnostics.inboundBytesUsed, 0)
        XCTAssertTrue(source.isConnected)
        XCTAssertEqual(carrier.ledger.violations(of: source.identity.peer), 0)
    }

    func testAHeldSourceThatLeavesFreesWhatItHeld() {
        let sim = Simulation()
        let carrier = carrier(sim, requestTimeout: .seconds(2))
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let routeID = relayRouteID(1)
        openRoute(routeID, from: source, to: target)
        guard let sourceLink = carrier.core.linkByConnection[source.connection] else {
            return XCTFail("no link")
        }
        holdSource(sim, carrier: carrier, source: source, target: target, routeID: routeID)
        XCTAssertGreaterThan(carrier.core.diagnostics.inboundBytesUsed, 0)

        sim.closeRaw(source.connection, at: carrier)
        sim.run(for: .zero)
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        XCTAssertFalse(carrier.core.timers.isSet(.relayForward(sourceLink)))
        XCTAssertTrue(carrier.core.writabilityWaiters.values.allSatisfy(\.isEmpty))
        XCTAssertEqual(carrier.core.diagnostics.inboundBytesUsed, 0)

        // Nothing fires later for the link that is gone.
        sim.setRawStalled(false, target.connection, at: carrier)
        sim.run(for: .seconds(5))
        XCTAssertEqual(target.takePackets(on: routeID), [packet(1), packet(2)])
        XCTAssertTrue(target.isConnected)
        XCTAssertEqual(carrier.ledger.violations(of: target.identity.peer), 0)
    }

    // MARK: - Deadlines

    func testAnUnansweredRelayOpenTimesOutAfterRelayTimeout() {
        let sim = Simulation()
        let identities = [sim.relayIdentity(1), sim.relayIdentity(2)].sorted { $0.key < $1.key }
        let node = endpoint(sim, carriers: identities, relayTimeout: .seconds(3))
        let first = RawRelayPeer(sim, to: node, as: identities[0])
        let second = RawRelayPeer(sim, to: node, as: identities[1])
        let target = sim.relayIdentity(3)

        let request = sim.request(.connectViaRelay(target.endpoint), on: node)
        guard let firstRoute = first.take({ $0.relayOpenFields }).first?.routeID else {
            return XCTFail("no relayOpen")
        }
        XCTAssertTrue(node.core.timers.isSet(.relayOpen(firstRoute)))

        sim.run(for: .milliseconds(2_900))
        XCTAssertEqual(Array(node.core.pendingRelayOpens.keys), [firstRoute])
        XCTAssertTrue(first.take().isEmpty)
        XCTAssertTrue(second.take().isEmpty)

        // The silent carrier is told to forget the route; the next is asked.
        sim.run(for: .milliseconds(200))
        XCTAssertEqual(first.takeCloses(), [firstRoute])
        let secondOpens = second.take { $0.relayOpenFields }
        XCTAssertEqual(secondOpens.map(\.target), [target.key])
        guard let secondRoute = secondOpens.first?.routeID else { return XCTFail("no second relayOpen") }
        XCTAssertNotEqual(secondRoute, firstRoute)
        XCTAssertEqual(Array(node.core.pendingRelayOpens.keys), [secondRoute])
        XCTAssertNil(sim.result(of: request, on: node))

        // A reply for the route that timed out no longer opens anything.
        first.send(.relayReady(routeID: firstRoute, status: 0))
        sim.run(for: .milliseconds(2_700))
        XCTAssertNil(sim.result(of: request, on: node))
        XCTAssertTrue(node.core.installedRoutes.isEmpty)

        sim.run(for: .milliseconds(400))
        XCTAssertEqual(second.takeCloses(), [secondRoute])
        XCTAssertEqual(sim.result(of: request, on: node), .connect(.failed(.noRelayAvailable)))
        assertNoRelayState(node, "node")
        XCTAssertFalse(node.core.timers.isSet(.relayOpen(firstRoute)))
        XCTAssertFalse(node.core.timers.isSet(.relayOpen(secondRoute)))
        XCTAssertTrue(first.isConnected)
        XCTAssertTrue(second.isConnected)
        XCTAssertEqual(node.ledger.violations(of: first.identity.peer), 0)
        XCTAssertEqual(node.ledger.violations(of: second.identity.peer), 0)
    }

    func testAnUnreadyCarriedRouteExpiresAfterRelayTimeout() {
        let sim = Simulation()
        let carrier = carrier(sim, relayTimeout: .seconds(3))
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let routeID = relayRouteID(1)
        source.send(.relayOpen(routeID: routeID, targetKey: target.key))
        _ = target.take()

        sim.run(for: .milliseconds(2_900))
        XCTAssertEqual(carrier.core.relayRoutes[routeID]?.ready, false)
        sim.run(for: .milliseconds(200))
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        XCTAssertFalse(carrier.core.timers.isSet(.relayRoute(routeID)))

        // An acceptance that comes too late finds no route and opens none.
        target.send(.relayAccept(routeID: routeID, status: 0))
        sim.run(for: .zero)
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        XCTAssertTrue(source.take { $0.relayReadyFields }.isEmpty)
        XCTAssertTrue(source.isConnected)
        XCTAssertTrue(target.isConnected)
        XCTAssertEqual(carrier.ledger.violations(of: target.identity.peer), 0)
    }

    func testAnAcceptedRouteNobodyOpensASessionOnExpires() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let node = endpoint(sim, carriers: [carrierIdentity], relayTimeout: .seconds(3))
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
        let routeID = relayRouteID(1)
        carrier.send(.relayOffer(routeID: routeID, sourceKey: sim.relayIdentity(2).key))
        XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [0])
        XCTAssertTrue(node.core.timers.isSet(.installedRoute(routeID)))

        sim.run(for: .milliseconds(2_900))
        XCTAssertEqual(Array(node.core.installedRoutes.keys), [routeID])
        XCTAssertTrue(carrier.take().isEmpty)

        sim.run(for: .milliseconds(200))
        assertNoRelayState(node, "node")
        XCTAssertFalse(node.core.timers.isSet(.installedRoute(routeID)))
        XCTAssertEqual(carrier.takeCloses(), [routeID])
        XCTAssertTrue(carrier.isConnected)
    }

    /// Reference: "an old relay timer cannot expire a reused route ID".
    func testRouteExpiryIsLifecycleScoped() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let node = endpoint(sim, carriers: [carrierIdentity], relayTimeout: .seconds(5))
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
        let routeID = relayRouteID(9)
        let offer = Message.relayOffer(routeID: routeID, sourceKey: sim.relayIdentity(2).key)

        carrier.send(offer)
        sim.run(for: .seconds(3))
        carrier.send(.relayClose(routeID: routeID))
        sim.run(for: .zero)
        XCTAssertTrue(node.core.installedRoutes.isEmpty)
        XCTAssertFalse(node.core.timers.isSet(.installedRoute(routeID)))
        carrier.send(offer)
        XCTAssertEqual(carrier.take { $0.relayAcceptFields }.map(\.status), [0, 0])

        // The first offer's deadline passes: the second stands.
        sim.run(for: .milliseconds(2_100))
        XCTAssertEqual(node.core.installedRoutes.count, 1)
        XCTAssertTrue(carrier.takeCloses().isEmpty)

        // It has its own, measured from when it was accepted.
        sim.run(for: .milliseconds(2_800))
        XCTAssertEqual(node.core.installedRoutes.count, 1)
        sim.run(for: .milliseconds(200))
        XCTAssertTrue(node.core.installedRoutes.isEmpty)
        XCTAssertEqual(carrier.takeCloses(), [routeID])

        sim.send(.command(.disconnect(carrier.identity.peer)), to: node)
        assertNoRelayState(node, "node")
    }

    func testARouteWithASessionOutlivesTheUnusedRouteDeadline() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let remote = sim.relayIdentity(2)
        let node = endpoint(sim, carriers: [carrierIdentity], relayTimeout: .seconds(3))
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)
        let routeID = relayRouteID(1)
        carrier.send(.relayOffer(routeID: routeID, sourceKey: remote.key))
        _ = carrier.take()
        XCTAssertNotNil(carrier.initiateRelayedSession(as: remote, on: routeID))
        XCTAssertEqual(
            node.core.authenticatedPeer(for: remote.peer)?.route,
            .relayed(carrier: carrier.key, routeID: routeID))

        sim.run(for: .seconds(20))
        XCTAssertEqual(Array(node.core.installedRoutes.keys), [routeID])
        XCTAssertNotNil(node.core.authenticatedPeer(for: remote.peer))
        XCTAssertTrue(carrier.takeCloses().isEmpty)
    }

    func testARelayedHandshakeThatNeverFinishesReturnsItsRoute() {
        let sim = Simulation()
        let carrierIdentity = sim.relayIdentity(1)
        let target = sim.relayIdentity(2)
        let node = endpoint(sim, carriers: [carrierIdentity], relayTimeout: .seconds(3))
        let carrier = RawRelayPeer(sim, to: node, as: carrierIdentity)

        let request = sim.request(.connectViaRelay(target.endpoint), on: node)
        guard let routeID = carrier.take({ $0.relayOpenFields }).first?.routeID else {
            return XCTFail("no relayOpen")
        }
        carrier.send(.relayReady(routeID: routeID, status: 0))
        // The node's hello, bound to the route, is its first record on it.
        let packets = carrier.takePackets(on: routeID)
        XCTAssertEqual(packets.count, 1)
        guard case .helloInitiator(let hello)? = packets.first.flatMap({ try? SessionWireRecord.deserialize($0) }) else {
            return XCTFail("the route's first record was not a hello")
        }
        XCTAssertEqual(hello.hello.routeBinding, routeID)
        XCTAssertEqual(hello.hello.initiator, node.key)
        XCTAssertEqual(hello.hello.responder, target.key)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 1)

        // The handshake has its own deadline; the unused-route one does not apply.
        sim.run(for: IvyCore.pendingSessionTimeout - .milliseconds(100))
        XCTAssertEqual(Array(node.core.installedRoutes.keys), [routeID])
        XCTAssertNil(sim.result(of: request, on: node))
        XCTAssertTrue(carrier.takeCloses().isEmpty)

        sim.run(for: .milliseconds(200))
        XCTAssertEqual(sim.result(of: request, on: node), .connect(.failed(.noRelayAvailable)))
        XCTAssertEqual(carrier.takeCloses(), [routeID])
        assertNoRelayState(node, "node")
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertTrue(node.connected.allSatisfy { $0.key == carrier.key })
    }

    func testAReadyCarriedRouteExpiresAfterThreeHundredSecondsIdle() {
        let sim = Simulation()
        let carrier = carrier(sim)
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let routeID = relayRouteID(1)
        XCTAssertEqual(IvyCore.relayIdleTimeout, .seconds(300))
        openRoute(routeID, from: source, to: target)

        // Ready: `relayTimeout` no longer applies.
        sim.run(for: .seconds(299))
        XCTAssertEqual(carrier.core.relayRoutes[routeID]?.ready, true)
        sim.run(for: .seconds(2))
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        XCTAssertFalse(carrier.core.timers.isSet(.relayRoute(routeID)))
        XCTAssertTrue(source.isConnected)
        XCTAssertTrue(target.isConnected)
    }

    func testIdleExpiryIsMeasuredFromTheLastRecordEitherWay() {
        let sim = Simulation()
        let carrier = carrier(sim)
        let source = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(1))
        let target = RawRelayPeer(sim, to: carrier, as: sim.relayIdentity(2))
        let routeID = relayRouteID(1)
        openRoute(routeID, from: source, to: target)

        sim.run(for: .seconds(200))
        source.sendPacket(Data([1]), on: routeID)
        // 301 s after it was readied, 101 s after its last record.
        sim.run(for: .seconds(101))
        XCTAssertNotNil(carrier.core.relayRoutes[routeID])

        sim.run(for: .seconds(99))
        target.sendPacket(Data([2]), on: routeID)
        sim.run(for: .seconds(299))
        XCTAssertNotNil(carrier.core.relayRoutes[routeID])
        XCTAssertEqual(target.takePackets(on: routeID), [Data([1])])
        XCTAssertEqual(source.takePackets(on: routeID), [Data([2])])

        sim.run(for: .seconds(2))
        XCTAssertTrue(carrier.core.relayRoutes.isEmpty)
        XCTAssertFalse(carrier.core.timers.isSet(.relayRoute(routeID)))
    }
}
