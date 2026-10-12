import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Ports of 15.0.1's InboundAdmissionTests: capacity is taken before a
/// connection is read (IVY-001), inbound and outbound share it, and a dial
/// keeps its place until the shell reports how it ended.
final class InboundAdmissionSimulationTests: XCTestCase {
    private func assertRefused(
        _ connection: ConnectionID,
        at node: Simulation.Node,
        in sim: Simulation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(sim.nodeClosedRaw(connection), file: file, line: line)
        XCTAssertEqual(sim.resumeCount(connection, at: node), 0, file: file, line: line)
    }

    private func assertAdmitted(
        _ connection: ConnectionID,
        at node: Simulation.Node,
        in sim: Simulation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(sim.nodeClosedRaw(connection), file: file, line: line)
        XCTAssertTrue(sim.isReading(connection, at: node), file: file, line: line)
    }

    private func testLink(observedHost: String, endpoint: PeerEndpoint) -> Link {
        Link(
            id: 9_999,
            transport: .direct(ConnectionID(9_999)),
            endpoint: endpoint,
            observedHost: observedHost,
            localHost: nil,
            localMaxFrameSize: IvyConfig.defaultProtocolMaxFrameSize)
    }

    // "synchronous leases enforce global and netgroup limits"
    func testGlobalAndNetgroupLimitsGateInboundConnections() {
        let sim = Simulation()
        let node = sim.capacityNode(maxConnections: 3, maxConnectionsPerNetgroup: 2)

        let first = sim.openRawConnection(to: node, fromHost: "10.1.1.1")
        let second = sim.openRawConnection(to: node, fromHost: "10.1.2.1")
        assertAdmitted(first, at: node, in: sim)
        assertAdmitted(second, at: node, in: sim)
        assertRefused(sim.openRawConnection(to: node, fromHost: "10.1.3.1"), at: node, in: sim)

        assertAdmitted(sim.openRawConnection(to: node, fromHost: "10.2.1.1"), at: node, in: sim)
        assertRefused(sim.openRawConnection(to: node, fromHost: "10.3.1.1"), at: node, in: sim)

        sim.closeRaw(first, at: node)
        assertAdmitted(sim.openRawConnection(to: node, fromHost: "10.1.4.1"), at: node, in: sim)

        sim.stop(node)
        assertRefused(sim.openRawConnection(to: node, fromHost: "10.4.1.1"), at: node, in: sim)
    }

    // IVY-001: nothing is read from a connection the node has not admitted.
    func testRefusedConnectionIsNeverRead() {
        let sim = Simulation()
        let node = sim.capacityNode(maxConnections: 1)
        let admitted = sim.openRawConnection(to: node, fromHost: "10.1.0.1")
        let refused = sim.openRawConnection(to: node, fromHost: "10.2.0.1")

        XCTAssertEqual(sim.resumeCount(admitted, at: node), 1)
        XCTAssertEqual(sim.resumeCount(refused, at: node), 0)
        XCTAssertTrue(sim.closes(by: node).contains(refused))
        XCTAssertFalse(sim.closes(by: node).contains(admitted))
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 1)
        XCTAssertEqual(node.core.diagnostics.inboundBytesUsed, 0)
    }

    // "an outbound reservation survives inbound churn"
    func testOutboundReservationSurvivesInboundChurn() {
        let sim = Simulation()
        let node = sim.capacityNode(
            maxConnections: 2, reservedOutboundConnectionSlots: 1, maxConnectionsPerNetgroup: 2)

        let first = sim.openRawConnection(to: node, fromHost: "9.1.0.1")
        assertAdmitted(first, at: node, in: sim)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 1)

        assertRefused(sim.openRawConnection(to: node, fromHost: "9.2.0.1"), at: node, in: sim)

        let parent = HandPeer.endpoint(sim, index: 1, host: "10.1.1.1")
        sim.request(.connect(parent), on: node)
        XCTAssertEqual(sim.dials(from: node).map(\.endpoint), [parent])
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)

        sim.run(for: .seconds(1))
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
    }

    // "inbound promotion cannot consume an outbound reservation"
    func testInboundPromotionKeepsOutboundReservation() {
        let sim = Simulation()
        let node = sim.capacityNode(maxConnections: 2, reservedOutboundConnectionSlots: 1)
        XCTAssertTrue(HandPeer(sim, to: node, index: 1, host: "10.1.0.1").authenticate())

        let candidate = HandPeer.key(sim, index: 2)
        let link = testLink(
            observedHost: "10.7.0.1",
            endpoint: HandPeer.endpoint(sim, index: 2, host: "10.7.0.1"))
        XCTAssertFalse(node.core.canPromote(link, peerKey: candidate, isInbound: true))
        XCTAssertTrue(node.core.canPromote(link, peerKey: candidate, isInbound: false))

        // And the inbound side is refused before it is read.
        assertRefused(sim.openRawConnection(to: node, fromHost: "10.7.0.1"), at: node, in: sim)
    }

    // "session replacement still obeys the destination netgroup cap"
    func testReplacementObeysNetgroupCap() {
        let sim = Simulation()
        let node = sim.capacityNode(maxConnections: 3, maxConnectionsPerNetgroup: 1)
        let replaced = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        let occupying = HandPeer(sim, to: node, index: 2, host: "10.2.0.1")
        XCTAssertTrue(replaced.authenticate())
        XCTAssertTrue(occupying.authenticate())

        let crowded = testLink(observedHost: "10.2.0.2", endpoint: replaced.endpoint)
        XCTAssertFalse(node.core.canPromote(crowded, peerKey: replaced.key, isInbound: true))
        let free = testLink(observedHost: "10.3.0.1", endpoint: replaced.endpoint)
        XCTAssertTrue(node.core.canPromote(free, peerKey: replaced.key, isInbound: true))
        // Its own netgroup is not counted against its replacement.
        let same = testLink(observedHost: "10.1.0.9", endpoint: replaced.endpoint)
        XCTAssertTrue(node.core.canPromote(same, peerKey: replaced.key, isInbound: true))
    }

    // "actor admission rejects stale runs"
    func testConnectionFromStoppedRunIsNotAdmittedToTheNext() {
        let sim = Simulation()
        let node = sim.capacityNode(maxConnections: 3, maxConnectionsPerNetgroup: 1)
        let current = sim.openRawConnection(to: node, fromHost: "10.1.0.1")
        assertAdmitted(current, at: node, in: sim)

        sim.stop(node)
        XCTAssertTrue(sim.nodeClosedRaw(current))
        sim.start(node)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)

        // Bytes and a close for the old connection mean nothing to the new run.
        let before = sim.effects(of: node).count
        sim.send(.received(current, Data([0, 0, 0, 1, 7])), to: node)
        sim.send(.writable(current), to: node)
        sim.send(.closed(current), to: node)
        XCTAssertEqual(sim.effects(of: node).count, before)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)

        // The netgroup place the old connection held is free again.
        assertAdmitted(sim.openRawConnection(to: node, fromHost: "10.1.0.2"), at: node, in: sim)
    }

    // "stop and restart serialize with an in-flight start"
    func testStopAndRestartLeaveTheNodeRunning() {
        let sim = Simulation()
        let node = sim.node(start: false)
        XCTAssertFalse(node.core.isRunning)
        sim.start(node)
        sim.stop(node)
        XCTAssertFalse(node.core.isRunning)
        sim.start(node)
        sim.start(node)
        XCTAssertTrue(node.core.isRunning)
        assertAdmitted(sim.openRawConnection(to: node, fromHost: "10.1.0.1"), at: node, in: sim)
    }

    // "an in-flight dial keeps its capacity reservation across restart"
    func testInFlightDialRemainsCountedAcrossRestart() {
        let sim = Simulation()
        let node = sim.capacityNode(maxConnections: 1, maxConnectionsPerNetgroup: 1)
        let first = HandPeer.endpoint(sim, index: 1, host: "10.1.0.1")
        let second = HandPeer.endpoint(sim, index: 2, host: "10.2.0.1")

        let firstConnect = sim.request(.connect(first), on: node)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)
        sim.stop(node)
        XCTAssertNotNil(sim.result(of: firstConnect, on: node))
        XCTAssertNotEqual(sim.result(of: firstConnect, on: node), .connect(.connected))

        sim.start(node)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)
        let refused = sim.request(.connect(second), on: node)
        XCTAssertEqual(sim.dials(from: node).count, 1)
        XCTAssertEqual(sim.result(of: refused, on: node)?.isFailedConnect, true)

        // The shell reports the old dial; only then is its place free.
        sim.run(for: .seconds(1))
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        sim.request(.connect(second), on: node)
        XCTAssertEqual(sim.dials(from: node).count, 2)
    }

    // "stale dial success schedules the restarted run's configured reconnect"
    func testStaleDialSuccessReconnectsCurrentRun() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node(bootstrap: [server.endpoint])
        XCTAssertEqual(client.core.diagnostics.outgoingDials, 1)

        // The run that asked for the dial ends before the shell answers it.
        sim.stop(client)
        sim.start(client)
        XCTAssertEqual(client.core.diagnostics.outgoingDials, 1)

        sim.run(for: .milliseconds(100))
        XCTAssertEqual(client.core.diagnostics.outgoingDials, 0)
        XCTAssertFalse(client.core.connectedPeers.contains(server.peer))
        XCTAssertNotNil(
            client.core.reconnectScheduled[server.peer],
            "the old run's dial ended without a session, so the configured peer is owed a reconnect")

        XCTAssertTrue(sim.run(
            until: { client.core.connectedPeers.contains(server.peer) }, timeout: .seconds(60)))
    }

    // The same, when the old run's dial fails instead of connecting.
    func testStaleDialFailureReconnectsCurrentRun() {
        let sim = Simulation()
        let ghost = HandPeer.endpoint(sim, index: 1, host: "10.1.0.1")
        let node = sim.node(bootstrap: [ghost])
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)

        sim.stop(node)
        sim.start(node)
        sim.run(for: .milliseconds(100))

        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertNotNil(node.core.reconnectScheduled[PeerID(publicKey: ghost.publicKey)])
        sim.run(for: .seconds(5))
        XCTAssertGreaterThan(sim.dials(from: node).count, 1)
    }

    // "a concurrent dial is not reported as an identity failure"
    func testConcurrentDialHasAccurateError() {
        let sim = Simulation()
        let node = sim.node()
        let endpoint = HandPeer.endpoint(sim, index: 1, host: "10.1.0.1")

        sim.request(.connect(endpoint), on: node)
        let second = sim.request(.connect(endpoint), on: node)

        XCTAssertEqual(sim.result(of: second, on: node), .connect(.failed(.connectionInProgress)))
        XCTAssertEqual(sim.dials(from: node).count, 1)
    }

    // "dial success requires a live authenticated session"
    func testDialWithoutSessionSchedulesConfiguredReconnect() {
        let sim = Simulation()
        let endpoint = HandPeer.endpoint(sim, index: 1, host: "10.1.0.1")
        let peer = PeerID(publicKey: endpoint.publicKey)
        let node = sim.node(bootstrap: [endpoint])

        sim.run(for: .milliseconds(100))

        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertFalse(node.core.connectedPeers.contains(peer))
        XCTAssertNotNil(node.core.reconnectScheduled[peer])
    }

    // "a competing authenticated session satisfies an outgoing dial"
    func testCompetingSessionSatisfiesOutgoingDial() {
        let sim = Simulation()
        let endpoint = HandPeer.endpoint(sim, index: 1, host: "10.5.0.1")
        let node = sim.node(bootstrap: [endpoint])
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)

        let peer = HandPeer(sim, to: node, index: 1, host: "10.5.0.1")
        XCTAssertTrue(peer.authenticate())
        sim.run(for: .seconds(1))

        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertNil(node.core.reconnectScheduled[peer.id])
        XCTAssertTrue(node.core.hasEndpointSession(peer.id))
        sim.run(for: .seconds(60))
        XCTAssertEqual(sim.dials(from: node).count, 1)
    }

    /// A node dialling a hand-played peer that has sent its hello and read
    /// the node's reply: a verified responder still owed its Finish.
    private func pendingCrossDial() -> (Simulation, Simulation.Node, HandPeer, RequestID) {
        let sim = Simulation()
        let node = sim.node(maxConnectionsPerNetgroup: 4)
        let peer = HandPeer(sim, to: node, index: 1, host: "10.5.0.1")
        let request = sim.request(.connect(peer.endpoint), on: node)
        peer.sendHello()
        XCTAssertTrue(peer.receiveResponder())
        sim.run(for: .milliseconds(50))
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertNil(sim.result(of: request, on: node))
        XCTAssertNotNil(node.core.responderWaiters[peer.key])
        return (sim, node, peer, request)
    }

    // "a responder awaiting Finish satisfies its losing outgoing dial"
    func testPendingCompetingSessionSatisfiesOutgoingDial() {
        let (sim, node, peer, request) = pendingCrossDial()

        peer.sendFinish()
        sim.run(for: .zero)

        XCTAssertEqual(sim.result(of: request, on: node), .connect(.connected))
        XCTAssertTrue(node.core.hasEndpointSession(peer.id))
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertTrue(node.core.responderWaiters.isEmpty)
    }

    // "any verified responder can satisfy a peer-level cross-dial"
    func testAlternatePendingResponderSatisfiesOutgoingDial() {
        let sim = Simulation()
        let node = sim.node(maxConnectionsPerNetgroup: 4)
        let peer = HandPeer(sim, to: node, index: 1, host: "10.5.0.1")
        let alternate = HandPeer(sim, to: node, index: 1, host: "10.6.0.1")
        let request = sim.request(.connect(peer.endpoint), on: node)
        peer.sendHello(nonce: 1)
        alternate.sendHello(nonce: 2)
        XCTAssertTrue(peer.receiveResponder())
        XCTAssertTrue(alternate.receiveResponder())
        sim.run(for: .milliseconds(50))
        XCTAssertNil(sim.result(of: request, on: node))

        alternate.sendFinish()
        sim.run(for: .zero)

        XCTAssertEqual(sim.result(of: request, on: node), .connect(.connected))
        XCTAssertTrue(alternate.isAuthenticated)
        XCTAssertTrue(node.core.hasEndpointSession(peer.id))
    }

    // "cancelling a cross-dial wait preserves its responder"
    func testCancellingPendingResponderWait() {
        let (sim, node, peer, request) = pendingCrossDial()

        sim.cancel(request, on: node)

        XCTAssertEqual(sim.result(of: request, on: node), .connect(.cancelled))
        XCTAssertTrue(node.core.responderWaiters.isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 1)
        peer.sendFinish()
        sim.run(for: .zero)
        XCTAssertTrue(node.core.hasEndpointSession(peer.id))
    }

    // "disconnect cancels a cross-dial wait and its responder"
    func testDisconnectCancelsPendingResponderWait() {
        let (sim, node, peer, request) = pendingCrossDial()

        sim.send(.command(.disconnect(peer.id)), to: node)

        XCTAssertNotNil(sim.result(of: request, on: node))
        XCTAssertNotEqual(sim.result(of: request, on: node), .connect(.connected))
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertTrue(node.core.responderWaiters.isEmpty)
        XCTAssertTrue(peer.isClosed)
        peer.sendFinish()
        sim.run(for: .seconds(1))
        XCTAssertFalse(node.core.hasEndpointSession(peer.id))
        XCTAssertTrue(node.connected.isEmpty)
    }

    // "stop drains a cross-dial wait"
    func testStopDrainsPendingResponderWait() {
        let (sim, node, peer, request) = pendingCrossDial()

        sim.stop(node)

        XCTAssertNotNil(sim.result(of: request, on: node))
        XCTAssertNotEqual(sim.result(of: request, on: node), .connect(.connected))
        XCTAssertTrue(node.core.responderWaiters.isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 0)
        XCTAssertTrue(peer.isClosed)
    }

    // "a failed reserved dial rearms a reconnect consumed by that reservation"
    func testReservedDialFailureRearmsReconnect() {
        let sim = Simulation()
        let endpoint = HandPeer.endpoint(sim, index: 1, host: "10.1.0.1")
        let peer = PeerID(publicKey: endpoint.publicKey)
        let node = sim.node(bootstrap: [endpoint])
        sim.run(for: .milliseconds(100))
        XCTAssertNotNil(node.core.reconnectScheduled[peer])

        // A dial the application asks for is still out when the reconnect
        // comes due; the reconnect finds the peer's place taken.
        sim.latency = .seconds(5)
        sim.request(.connect(endpoint), on: node)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)
        sim.run(for: .seconds(2))
        XCTAssertNil(node.core.reconnectScheduled[peer])
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)
        XCTAssertEqual(sim.dials(from: node).count, 2)

        sim.run(for: .milliseconds(3_200))
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertNotNil(node.core.reconnectScheduled[peer])
    }

    // "inbound handshakes and outbound reservations share one netgroup cap"
    func testMixedDirectionNetgroupAdmission() {
        let sim = Simulation()
        let node = sim.capacityNode(maxConnections: 4, maxConnectionsPerNetgroup: 1)
        sim.request(.connect(HandPeer.endpoint(sim, index: 1, host: "10.1.0.2")), on: node)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)

        assertRefused(sim.openRawConnection(to: node, fromHost: "10.1.0.1"), at: node, in: sim)

        sim.run(for: .milliseconds(50))
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        assertAdmitted(sim.openRawConnection(to: node, fromHost: "10.1.0.1"), at: node, in: sim)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 1)

        let second = sim.request(
            .connect(HandPeer.endpoint(sim, index: 2, host: "10.1.0.3")), on: node)
        XCTAssertEqual(sim.dials(from: node).count, 1)
        XCTAssertEqual(sim.result(of: second, on: node)?.isFailedConnect, true)
    }

    // "a cross-dial reservation remains physical capacity after its peer authenticates"
    func testCrossDialCountsBothTransports() {
        let sim = Simulation()
        let node = sim.capacityNode(maxConnections: 2, maxConnectionsPerNetgroup: 4)
        let peer = HandPeer(sim, to: node, index: 1, host: "10.5.0.1")
        sim.request(.connect(peer.endpoint), on: node)
        XCTAssertTrue(peer.authenticate())
        XCTAssertTrue(node.core.hasEndpointSession(peer.id))
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)

        let excess = sim.request(
            .connect(HandPeer.endpoint(sim, index: 2, host: "10.9.1.1")), on: node)

        XCTAssertEqual(sim.dials(from: node).count, 1)
        XCTAssertEqual(sim.result(of: excess, on: node)?.isFailedConnect, true)
    }

    // "DNS aliases cannot evade the observed netgroup cap"
    func testObservedAddressRebindsNetgroupReservation() {
        let sim = Simulation()
        let node = sim.capacityNode(maxConnections: 4, maxConnectionsPerNetgroup: 1)
        let first = HandPeer.endpoint(sim, index: 1, host: "first.example")
        let second = HandPeer.endpoint(sim, index: 2, host: "second.example")

        // Both names resolve into one /16; the shell reports where each landed.
        sim.request(.connect(first), on: node)
        let firstConnection = ConnectionID(900_001)
        sim.send(.connectionOpened(
            firstConnection,
            direction: .outbound(sim.dials(from: node)[0].dial),
            observedHost: "10.1.0.1",
            localHost: nil), to: node)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 1)

        let secondConnect = sim.request(.connect(second), on: node)
        XCTAssertEqual(sim.dials(from: node).count, 2)
        let secondConnection = ConnectionID(900_002)
        sim.send(.connectionOpened(
            secondConnection,
            direction: .outbound(sim.dials(from: node)[1].dial),
            observedHost: "10.1.0.2",
            localHost: nil), to: node)

        XCTAssertEqual(sim.result(of: secondConnect, on: node)?.isFailedConnect, true)
        XCTAssertTrue(sim.closes(by: node).contains(secondConnection))
        XCTAssertFalse(sim.closes(by: node).contains(firstConnection))
        XCTAssertEqual(sim.resumeCount(secondConnection, at: node), 0)
        XCTAssertEqual(node.core.diagnostics.pendingSessions, 1)
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)
    }

    // "manual disconnect fences an already-started configured dial"
    func testDisconnectSuppressesInFlightReconnect() {
        let sim = Simulation()
        let endpoint = HandPeer.endpoint(sim, index: 1, host: "10.1.0.1")
        let peer = PeerID(publicKey: endpoint.publicKey)
        let node = sim.node(bootstrap: [endpoint])
        XCTAssertEqual(node.core.diagnostics.outgoingDials, 1)

        sim.send(.command(.disconnect(peer)), to: node)
        sim.run(for: .seconds(60))

        XCTAssertEqual(node.core.diagnostics.outgoingDials, 0)
        XCTAssertNil(node.core.reconnectScheduled[peer])
        XCTAssertEqual(sim.dials(from: node).count, 1)
    }

    // The same fence when the dial lands: its connection is closed unread.
    func testDisconnectClosesAnInFlightDialThatConnects() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node(bootstrap: [server.endpoint])
        XCTAssertEqual(client.core.diagnostics.outgoingDials, 1)

        sim.send(.command(.disconnect(server.peer)), to: client)
        sim.run(for: .seconds(60))

        XCTAssertEqual(client.core.diagnostics.outgoingDials, 0)
        XCTAssertEqual(client.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(server.core.diagnostics.pendingSessions, 0)
        XCTAssertTrue(client.connected.isEmpty)
        XCTAssertTrue(server.connected.isEmpty)
        XCTAssertEqual(sim.closes(by: client).count, 1)
        XCTAssertEqual(sim.dials(from: client).count, 1)
    }
}
