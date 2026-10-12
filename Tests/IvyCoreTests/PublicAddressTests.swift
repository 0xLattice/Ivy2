import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// This node's public address and what it advertises: the parts of 15.0.1's
/// NATTraversalTests that are not STUN packet parsing.
final class PublicAddressTests: XCTestCase {
    private let stun = [("stun.test", 3478)]

    private func discoverEffects(_ sim: Simulation, _ node: Simulation.Node) -> Int {
        sim.discoveryEffects(of: node).filter { $0 == .discoverPublicAddress }.count
    }

    // MARK: - Ported from 15.0.1

    /// "startup does not wait for discovery and stale results cannot cross runs"
    ///
    /// The core half of it: start asks without waiting, a stopped node takes
    /// no answer, and a new run starts without an address and asks again.
    /// Keeping one run's late answer from the next is the shell's part, as
    /// `publicAddress` carries nothing naming the run that asked.
    func testStartupAndRestartFenceDiscovery() {
        let sim = Simulation()
        let oldAddress = ObservedAddress(host: "203.0.113.10", port: 40_001)
        let currentAddress = ObservedAddress(host: "203.0.113.20", port: 40_002)
        let node = sim.discoveryNode(stunServers: stun, start: false)
        node.observedPublicAddress = oldAddress

        sim.start(node)
        XCTAssertTrue(node.core.isRunning)
        XCTAssertEqual(discoverEffects(sim, node), 1)
        XCTAssertNil(node.core.publicAddress, "start does not wait for the answer")

        // The first run ends with its answer still on the way.
        sim.stop(node)
        sim.run(for: .seconds(1))
        XCTAssertNil(node.core.publicAddress)
        XCTAssertTrue(node.publicAddresses.isEmpty)

        node.observedPublicAddress = currentAddress
        sim.start(node)
        XCTAssertEqual(discoverEffects(sim, node), 2)
        XCTAssertNil(node.core.publicAddress)
        sim.run(for: .seconds(1))
        XCTAssertEqual(node.core.publicAddress, currentAddress)
        XCTAssertEqual(node.publicAddresses, [currentAddress])
    }

    /// "stop cancels an in-flight discovery"
    func testStopCancelsDiscovery() {
        let sim = Simulation()
        let node = sim.discoveryNode(stunServers: stun, start: false)
        node.observedPublicAddress = ObservedAddress(host: "8.8.8.8", port: 40_001)
        sim.start(node)
        XCTAssertEqual(discoverEffects(sim, node), 1)

        sim.stop(node)
        sim.run(for: .seconds(5))

        XCTAssertNil(node.core.publicAddress)
        XCTAssertTrue(node.publicAddresses.isEmpty)
    }

    /// "Equality"
    func testObservedAddressEquality() {
        let a = ObservedAddress(host: "1.2.3.4", port: 4001)
        let b = ObservedAddress(host: "1.2.3.4", port: 4001)
        let c = ObservedAddress(host: "1.2.3.4", port: 4002)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    /// "Hashing"
    func testObservedAddressHashing() {
        let a = ObservedAddress(host: "1.2.3.4", port: 4001)
        let b = ObservedAddress(host: "1.2.3.4", port: 4001)
        var set: Set<ObservedAddress> = [a]
        set.insert(b)
        XCTAssertEqual(set.count, 1)
    }

    /// "STUN contributes the observed host, not its UDP source port"
    func testObservedUDPPortIsNotAdvertisedAsTCP() {
        let sim = Simulation()
        let node = sim.discoveryNode(stunServers: stun, start: false)
        node.observedPublicAddress = ObservedAddress(host: "8.8.8.8", port: 59_999)
        sim.start(node)
        sim.run(for: .seconds(1))
        XCTAssertEqual(node.core.publicAddress, ObservedAddress(host: "8.8.8.8", port: 59_999))

        XCTAssertEqual(
            node.core.advertisedListenAddresses(observedLocalHost: nil),
            [ListenAddress(host: "8.8.8.8", port: 4001)])
        XCTAssertEqual(node.core.localProviderEndpoint()?.port, 4001)
        XCTAssertEqual(node.core.localProviderEndpoint()?.host, "8.8.8.8")
    }

    /// "a new run does not retain an old observed address"
    func testObservedAddressIsRunScoped() {
        let sim = Simulation()
        let node = sim.discoveryNode(stunServers: stun, start: false)
        node.observedPublicAddress = ObservedAddress(host: "8.8.8.8", port: 59_999)
        sim.start(node)
        sim.run(for: .seconds(1))
        XCTAssertNotNil(node.core.publicAddress)

        sim.stop(node)
        node.observedPublicAddress = nil
        sim.start(node)
        XCTAssertNil(node.core.publicAddress)
        sim.run(for: .seconds(1))

        XCTAssertNil(node.core.publicAddress)
        XCTAssertEqual(node.core.advertisedListenAddresses(observedLocalHost: nil), [])
    }

    /// "PeerEndpoint in Set"
    func testPeerEndpointSet() {
        let a = PeerEndpoint(publicKey: "k1", host: "1.2.3.4", port: 4001)
        let b = PeerEndpoint(publicKey: "k1", host: "1.2.3.4", port: 4001)
        var set: Set<PeerEndpoint> = [a]
        set.insert(b)
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - Discovery

    /// A configured `externalAddress` is announced at start and nothing is asked.
    func testExternalAddressIsAnnouncedAtStart() {
        let sim = Simulation()
        let node = sim.discoveryNode(
            stunServers: stun, externalAddress: ("8.44.0.1", 5000), start: false)
        node.observedPublicAddress = ObservedAddress(host: "8.8.8.8", port: 1)

        sim.start(node)

        let external = ObservedAddress(host: "8.44.0.1", port: 5000)
        XCTAssertEqual(node.core.publicAddress, external)
        XCTAssertEqual(node.publicAddresses, [external])
        XCTAssertEqual(discoverEffects(sim, node), 0)

        // An answer nobody asked for does not displace it.
        sim.send(.publicAddress(ObservedAddress(host: "8.8.8.8", port: 1)), to: node)
        XCTAssertEqual(node.core.publicAddress, external)
        XCTAssertEqual(node.publicAddresses, [external])
        XCTAssertEqual(
            node.core.advertisedListenAddresses(observedLocalHost: "8.1.0.1"),
            [ListenAddress(host: "8.44.0.1", port: 5000)],
            "the external address is the only one advertised")
    }

    /// Without one the core asks the shell, and takes the first answer only.
    func testFirstPublicAddressAnswerWins() {
        let sim = Simulation()
        let node = sim.discoveryNode(stunServers: stun)
        XCTAssertEqual(discoverEffects(sim, node), 1)
        XCTAssertNil(node.core.publicAddress)

        // "Nothing found" leaves the question open for a later answer.
        sim.run(for: .seconds(1))
        XCTAssertNil(node.core.publicAddress)
        XCTAssertTrue(node.publicAddresses.isEmpty)

        let first = ObservedAddress(host: "8.8.8.8", port: 1111)
        sim.send(.publicAddress(first), to: node)
        sim.send(.publicAddress(ObservedAddress(host: "9.9.9.9", port: 2222)), to: node)
        sim.send(.publicAddress(nil), to: node)

        XCTAssertEqual(node.core.publicAddress, first)
        XCTAssertEqual(node.publicAddresses, [first])
        XCTAssertEqual(discoverEffects(sim, node), 1)
    }

    /// With no STUN servers nothing is asked and no address is assumed.
    func testNoDiscoveryWithoutSTUNServers() {
        let sim = Simulation()
        let node = sim.discoveryNode(stunServers: [])
        node.observedPublicAddress = ObservedAddress(host: "8.8.8.8", port: 1)
        sim.run(for: .seconds(5))

        XCTAssertEqual(discoverEffects(sim, node), 0)
        XCTAssertNil(node.core.publicAddress)
        XCTAssertTrue(node.publicAddresses.isEmpty)
        XCTAssertNil(node.core.localProviderEndpoint())
    }

    /// Only an overlay node looks for its public address.
    func testOnlyOverlayModeDiscoversItsAddress() {
        let sim = Simulation()
        let pinned = sim.discoveryNode(
            mode: .pinned(peer: sim.signingKeyHex(scripted: 0)), stunServers: stun)
        let privateNode = sim.discoveryNode(mode: .privateNetwork, stunServers: stun)
        sim.run(for: .seconds(1))
        XCTAssertEqual(discoverEffects(sim, pinned), 0)
        XCTAssertEqual(discoverEffects(sim, privateNode), 0)
    }

    // MARK: - Advertised listen addresses

    /// The discovered public host comes first, then the local address of the
    /// connection the handshake runs on, both at the listen port.
    func testAdvertisedListenAddressesFollowThePublicAddress() {
        let sim = Simulation()
        let node = sim.discoveryNode(stunServers: stun, start: false)
        node.observedPublicAddress = ObservedAddress(host: "8.8.8.8", port: 59_999)
        sim.start(node)

        XCTAssertEqual(
            node.core.advertisedListenAddresses(observedLocalHost: "8.1.0.1"),
            [ListenAddress(host: "8.1.0.1", port: 4001)])
        XCTAssertEqual(node.core.advertisedListenAddresses(observedLocalHost: nil), [])
        XCTAssertEqual(node.core.advertisedListenAddresses(observedLocalHost: "0.0.0.0"), [])
        XCTAssertEqual(node.core.advertisedListenAddresses(observedLocalHost: "::"), [])

        sim.run(for: .seconds(1))
        XCTAssertEqual(
            node.core.advertisedListenAddresses(observedLocalHost: "8.1.0.1"),
            [ListenAddress(host: "8.8.8.8", port: 4001), ListenAddress(host: "8.1.0.1", port: 4001)])
        XCTAssertEqual(
            node.core.advertisedListenAddresses(observedLocalHost: "0.0.0.0"),
            [ListenAddress(host: "8.8.8.8", port: 4001)])
    }

    /// A peer records the route this node advertises: its external address
    /// when it has one, whatever address it was dialled at.
    func testPeersRecordTheExternalAddress() {
        let sim = Simulation()
        let listener = sim.discoveryNode(externalAddress: ("8.44.0.1", 5000))
        let dialer = sim.node()

        sim.connect(dialer, listener)

        XCTAssertEqual(
            dialer.core.knownPeerEndpoints,
            [PeerEndpoint(publicKey: listener.key.hex, host: "8.44.0.1", port: 5000)])
        XCTAssertEqual(listener.core.knownPeerEndpoints, [dialer.endpoint])
    }

    /// A node behind NAT advertises its discovered public host beside its
    /// private one; a peer records the first it can believe, in the
    /// metadata's canonical (sorted) order.
    func testPeersRecordTheFirstBelievableAdvertisedAddress() {
        let sim = Simulation()
        let natted = sim.discoveryNode(host: "10.9.0.1", stunServers: stun, start: false)
        natted.observedPublicAddress = ObservedAddress(host: "1.55.0.1", port: 59_999)
        sim.start(natted)
        sim.run(for: .seconds(1))
        let listener = sim.node()
        sim.connect(natted, listener)
        XCTAssertEqual(
            listener.core.knownPeerEndpoints,
            [PeerEndpoint(publicKey: natted.key.hex, host: "1.55.0.1", port: 4001)])

        // Sorted after the private address, the public one is not reached:
        // the private address matches where the peer was observed.
        let other = sim.discoveryNode(host: "10.10.0.1", stunServers: stun, start: false)
        other.observedPublicAddress = ObservedAddress(host: "8.55.0.1", port: 59_999)
        sim.start(other)
        sim.run(for: .seconds(1))
        sim.connect(other, listener)
        XCTAssertTrue(listener.core.knownPeerEndpoints.contains(
            PeerEndpoint(publicKey: other.key.hex, host: "10.10.0.1", port: 4001)))
    }
}
