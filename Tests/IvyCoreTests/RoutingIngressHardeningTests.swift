import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// What a hand-installed `findNode` query collected. The lookup is held in
/// its starting phase, so an answer is recorded and nothing acts on it.
private extension Simulation.Node {
    static let testLookup: OpID = 0xfeed_0001

    func awaitTestNeighbors(nonce: UInt64, from peer: PeerID) {
        var lookup = core.lookups[Self.testLookup] ?? NodeLookup(
            id: Self.testLookup, targetHash: Router.hash("routing-test-target"), waiter: .refresh,
            dials: true)
        lookup.starting = true
        lookup.awaiting.insert(nonce)
        core.lookups[Self.testLookup] = lookup
        core.pendingNeighborResponses[nonce] = PendingNeighborResponse(
            peer: peer, lookup: Self.testLookup)
    }

    func hasPendingTestNeighbors(nonce: UInt64) -> Bool {
        core.pendingNeighborResponses[nonce] != nil
    }

    var returnedTestNeighbors: [PeerEndpoint] {
        core.lookups[Self.testLookup]?.responses.flatMap { $0.1 } ?? []
    }

    /// Handles `message` as received on the session with `peer`.
    func handle(_ message: Message, from peer: Simulation.Node) {
        core.handleMessage(message, from: core.sessions[peer.key]!.ref)
    }
}

/// Routing ingress hardening
final class RoutingIngressHardeningTests: XCTestCase {
    /// Solicited neighbors obey identity, address, and key-work policy
    func testSolicitedNeighborsAreValidated() {
        let requiredBits = 2
        // The node holds its peers to the key-work threshold too, so the
        // simulation is seeded to give the peer a key that meets it.
        let seed = (1...10_000).first { seed in
            let key = Simulation(seed: UInt64(seed)).signingKey(index: 1).publicKey.rawRepresentation
            return KeyDifficulty.trailingZeroBits(of: try! PeerKey(rawRepresentation: key).hex) >= requiredBits
        }!
        let sim = Simulation(seed: UInt64(seed))
        let node = sim.addNode { key in
            IvyConfig(
                signingKey: key,
                listenPort: 4001,
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                minPeerKeyBits: requiredBits,
                externalAddress: (host: "10.0.0.10", port: 4001))
        }
        sim.start(node)
        let peer = sim.node()
        sim.connect(node, peer)
        let nonce: UInt64 = 1
        node.awaitTestNeighbors(nonce: nonce, from: peer.peer)
        XCTAssert(node.hasPendingTestNeighbors(nonce: nonce))

        let lowWork = keyWithWork(lessThan: requiredBits)
        let valid = keyWithWork(atLeast: requiredBits)
        let unusable = keyWithWork(atLeast: requiredBits, seed: "unusable")
        node.handle(.neighbors([
            PeerEndpoint(publicKey: "not-a-peer-key", host: "1.1.1.1", port: 4001),
            PeerEndpoint(publicKey: lowWork, host: "1.1.1.2", port: 4001),
            PeerEndpoint(publicKey: unusable, host: "1.1.1.3", port: 0),
            PeerEndpoint(publicKey: valid, host: "1.1.1.4", port: 4001),
        ], nonce: nonce), from: peer)
        let returned = node.returnedTestNeighbors

        let routed = Set(node.core.knownPeerEndpoints.map(\.publicKey))
        XCTAssert(!node.hasPendingTestNeighbors(nonce: nonce))
        XCTAssert(returned.map(\.publicKey) == [valid])
        XCTAssert(routed == Set([peer.peer.publicKey]))
    }

    /// Unsolicited and wrong-peer neighbors cannot mutate routing
    func testNeighborsRequireTheExpectedPeerAndNonce() {
        let sim = Simulation()
        let node = sim.addNode { key in
            IvyConfig(
                signingKey: key,
                listenPort: 4001,
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                externalAddress: (host: "10.0.0.10", port: 4001))
        }
        sim.start(node)
        let wrong = sim.node()
        let queried = sim.node()
        sim.connect(node, wrong)
        sim.connect(node, queried)
        let advertised = testRoutingEndpoint("routing-advertised", port: 4001)

        node.handle(.neighbors([advertised], nonce: 0xfeed), from: wrong)
        XCTAssert(!(node.core.knownPeerEndpoints.map(\.publicKey).contains(advertised.publicKey)))

        let nonce: UInt64 = 2
        node.awaitTestNeighbors(nonce: nonce, from: queried.peer)
        XCTAssert(node.hasPendingTestNeighbors(nonce: nonce))
        node.handle(.neighbors([advertised], nonce: nonce), from: wrong)
        XCTAssert(node.hasPendingTestNeighbors(nonce: nonce))
        XCTAssert(node.returnedTestNeighbors.isEmpty)
        XCTAssert(!(node.core.knownPeerEndpoints.map(\.publicKey).contains(advertised.publicKey)))

        node.handle(.neighbors([advertised], nonce: nonce), from: queried)
        XCTAssert(node.returnedTestNeighbors == [advertised])
        XCTAssert(!(node.core.knownPeerEndpoints.map(\.publicKey).contains(advertised.publicKey)))
    }

    /// Public discovery rejects SSRF destinations
    func testPublicDiscoveryRejectsNonGlobalHosts() {
        let node = routingNode(
            "routing-public",
            externalAddress: (host: "8.8.8.8", port: 4001))
        let source = PeerID(publicKey: wireTestPeerKey("routing-source"))
        let endpointKey = wireTestPeerKey("routing-endpoint")

        for host in [
            "127.0.0.1", "10.0.0.1", "169.254.169.254", "192.0.0.1",
            "192.0.2.1", "192.88.99.1", "::1", "fc00::1", "100::1", "4000::1",
            "2001:2::1", "2001:20::1", "2002:0808:0808::1", "3fff::1",
            "64:ff9b::0a00:0001", "example.com",
        ] {
            let endpoint = PeerEndpoint(publicKey: endpointKey, host: host, port: 4001)
            XCTAssert(!(node.isAcceptableDiscoveredEndpoint(
                endpoint,
                provenance: .referral("test"),
                from: source)))
        }

        for host in [
            "1.1.1.1", "192.0.0.9", "2001:3::1", "2606:4700:4700::1111",
            "64:ff9b::0808:0808",
            "::ffff:0808:0808",
        ] {
            let endpoint = PeerEndpoint(publicKey: endpointKey, host: host, port: 4001)
            XCTAssert(node.isAcceptableDiscoveredEndpoint(
                endpoint,
                provenance: .referral("test"),
                from: source))
        }

        let localNode = routingNode(
            "routing-local",
            externalAddress: (host: "10.0.0.10", port: 4001))
        let privateEndpoint = PeerEndpoint(publicKey: endpointKey, host: "10.0.0.1", port: 4001)
        XCTAssert(localNode.isAcceptableDiscoveredEndpoint(
            privateEndpoint,
            provenance: .referral("test"),
            from: source) == false)

        let unknownNode = routingNode("routing-unknown")
        XCTAssert(!(unknownNode.isAcceptableDiscoveredEndpoint(
            privateEndpoint,
            provenance: .referral("test"),
            from: source)))

        let domainNode = routingNode(
            "routing-domain",
            externalAddress: (host: "node.example", port: 4001))
        XCTAssert(!(domainNode.isAcceptableDiscoveredEndpoint(
            privateEndpoint,
            provenance: .referral("test"),
            from: source)))

        for host in ["127.0.0.1", "169.254.169.254", "100.64.0.1", "192.0.2.1", "example.com"] {
            XCTAssert(!(localNode.allowsDiscoveredHost(
                host,
                provenance: .referral("test"),
                fromObservedHost: host)))
        }

        let loopbackNode = routingNode(
            "routing-loopback",
            externalAddress: (host: "127.0.0.1", port: 4001))
        XCTAssert(loopbackNode.allowsDiscoveredHost(
            "127.0.0.2",
            provenance: .selfAdvertisement,
            fromObservedHost: "127.0.0.2"))
        XCTAssert(loopbackNode.allowsDiscoveredHost(
            "::ffff:127.0.0.2",
            provenance: .selfAdvertisement,
            fromObservedHost: "127.0.0.2"))
        XCTAssert(loopbackNode.allowsDiscoveredHost(
            "::ffff:7f00:0002",
            provenance: .selfAdvertisement,
            fromObservedHost: "127.0.0.2"))
        XCTAssert(!(loopbackNode.allowsDiscoveredHost(
            "127.0.0.2",
            provenance: .selfAdvertisement,
            fromObservedHost: "8.8.8.8")))
        XCTAssert(!(loopbackNode.allowsDiscoveredHost(
            "10.0.0.1",
            provenance: .selfAdvertisement,
            fromObservedHost: "127.0.0.3")))

        XCTAssert(localNode.allowsDiscoveredHost(
            "::ffff:10.0.0.1",
            provenance: .selfAdvertisement,
            fromObservedHost: "10.0.0.1"))
        XCTAssert(localNode.allowsDiscoveredHost(
            "::ffff:0a00:0001",
            provenance: .selfAdvertisement,
            fromObservedHost: "10.0.0.1"))
        let mappedPrivateNode = routingNode(
            "routing-mapped-private",
            externalAddress: (host: "::ffff:10.0.0.10", port: 4001))
        XCTAssert(mappedPrivateNode.allowsDiscoveredHost(
            "10.0.0.1",
            provenance: .selfAdvertisement,
            fromObservedHost: "::ffff:10.0.0.1"))

        let ulaNode = routingNode(
            "routing-ula",
            externalAddress: (host: "fd00::10", port: 4001))
        XCTAssert(ulaNode.allowsDiscoveredHost(
            "fc00::1",
            provenance: .selfAdvertisement,
            fromObservedHost: "fc00::1"))
        XCTAssert(!(ulaNode.allowsDiscoveredHost(
            "::1",
            provenance: .selfAdvertisement,
            fromObservedHost: "fd00::2")))
        XCTAssert(!(ulaNode.allowsDiscoveredHost(
            "fe80::1",
            provenance: .selfAdvertisement,
            fromObservedHost: "fe80::1")))
    }

    /// routing key work uses the canonical validated identity
    func testCanonicalRoutingKeyWork() {
        let (canonical, alternate, threshold) = keyWithPresentationOnlyWork()
        let node = routingNode(
            "routing-canonical-work",
            minPeerKeyBits: threshold,
            externalAddress: (host: "10.0.0.10", port: 4001))
        let source = PeerID(publicKey: wireTestPeerKey("routing-canonical-source"))

        for spelling in [canonical, alternate] {
            let endpoint = PeerEndpoint(publicKey: spelling, host: "8.8.8.8", port: 4001)
            XCTAssert(!(node.isAcceptableDiscoveredEndpoint(
                endpoint,
                provenance: .referral("test"),
                from: source)))
        }
    }
}

private func routingNode(
    _ label: String,
    minPeerKeyBits: Int = 0,
    externalAddress: (host: String, port: UInt16)? = nil
) -> IvyCore {
    IvyCore(config: IvyConfig(
        signingKey: wireTestSigningKey(label),
        listenPort: 0,
        bootstrapPeers: [],
        minPeerKeyBits: minPeerKeyBits,
        externalAddress: externalAddress))
}

private func testRoutingEndpoint(_ label: String, port: UInt16) -> PeerEndpoint {
    PeerEndpoint(publicKey: wireTestPeerKey(label), host: "1.1.1.1", port: port)
}

private func keyWithWork(atLeast target: Int, seed: String = "valid") -> String {
    for index in 0..<10_000 {
        let key = wireTestPeerKey("routing-\(seed)-\(index)")
        if KeyDifficulty.keyWorkBits(key) >= target { return key }
    }
    fatalError("Unable to find key with requested work")
}

private func keyWithWork(lessThan target: Int) -> String {
    for index in 0..<10_000 {
        let key = wireTestPeerKey("routing-low-work-\(index)")
        if KeyDifficulty.keyWorkBits(key) < target { return key }
    }
    fatalError("Unable to find key below requested work")
}

private func keyWithPresentationOnlyWork() -> (canonical: String, alternate: String, threshold: Int) {
    for index in 0..<100_000 {
        let canonical = wireTestPeerKey("routing-presentation-work-\(index)")
        let alternate = "ED01" + canonical.uppercased()
        let canonicalBits = KeyDifficulty.keyWorkBits(canonical)
        let rawPresentationBits = KeyDifficulty.trailingZeroBits(of: alternate)
        if rawPresentationBits > canonicalBits {
            return (canonical, alternate, canonicalBits + 1)
        }
    }
    fatalError("Unable to find presentation-only key work")
}
