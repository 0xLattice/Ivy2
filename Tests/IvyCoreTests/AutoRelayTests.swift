import Crypto
import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation

/// Auto relay: with no declared web addresses, a node advertises up to four
/// relays it is reachable through, as libp2p's AutoRelay picks them.
final class AutoRelayTests: XCTestCase {
    private final class Fixture {
        let sim = Simulation()
        let node: Simulation.Node
        let observer: DiscoveryScriptedPeer
        private var last: [WebAddress] = []
        private var nextIndex = 1

        init() {
            node = sim.node()
            observer = DiscoveryScriptedPeer(sim, to: node, index: 0)
            sim.send(.command(.setAutoRelay(true)), to: node)
        }

        /// A connected peer advertising `addresses`, marked as relaying unless not.
        func peer(_ addresses: [WebAddress]? = nil, relays: Bool = true) -> DiscoveryScriptedPeer {
            let index = nextIndex
            nextIndex += 1
            let peer = DiscoveryScriptedPeer(sim, to: node, index: index)
            peer.send(.webAddresses(addresses ?? [WebAddress(url: "wss://r\(index).example")]))
            if relays { sim.send(.command(.setRelaying(peer.peer, true)), to: node) }
            return peer
        }

        /// What the node last told its sessions.
        func advertised() -> [WebAddress] {
            if let latest = observer.takeWebAddresses().last { last = latest }
            return last
        }

        func rank(_ peer: DiscoveryScriptedPeer) -> [UInt8] {
            Array(SHA256.hash(data: node.key.rawRepresentation + peer.key.rawRepresentation))
        }

        func best(_ peers: [DiscoveryScriptedPeer], _ count: Int) -> Set<PeerKey> {
            Set(peers.sorted { rank($0).lexicographicallyPrecedes(rank($1)) }.prefix(count).map(\.key))
        }
    }

    private func vias(_ addresses: [WebAddress]) -> Set<PeerKey> { Set(addresses.compactMap(\.via)) }

    /// Up to four relaying peers with an address of their own, each at its
    /// first; a peer not marked relaying, or reachable only through another
    /// relay, is never chosen. Among candidates found together the ranking
    /// of both keys' hash decides.
    func testPicksUpToFourRelayingPeersWithDirectAddresses() {
        let f = Fixture()
        f.sim.send(.command(.setAutoRelay(false)), to: f.node)
        _ = f.peer(relays: false)
        _ = f.peer([WebAddress(url: "wss://via.example", via: f.sim.discoveryKey(index: 1))])
        let relays = (0..<6).map { _ in f.peer() }
        XCTAssertEqual(f.advertised(), [])
        f.sim.send(.command(.setAutoRelay(true)), to: f.node)
        let advertised = f.advertised()
        XCTAssertEqual(advertised.count, 4)
        XCTAssertEqual(vias(advertised), f.best(relays, 4))
        for address in advertised {
            let index = relays.firstIndex { $0.key == address.via }! + 3
            XCTAssertEqual(address.url, "wss://r\(index).example")
        }
    }

    /// Choices hold while they stay candidates, whatever arrives; a lost one
    /// is replaced, and a relay's changed addresses or `setRelaying(false)`
    /// take effect at once.
    func testChoicesAreStickyAndFollowEachRelay() {
        let f = Fixture()
        let first = (0..<4).map { _ in f.peer() }
        XCTAssertEqual(vias(f.advertised()), Set(first.map(\.key)))
        let late = (0..<6).map { _ in f.peer() }
        XCTAssertEqual(vias(f.advertised()), Set(first.map(\.key)), "sticky")

        first[0].close()
        f.sim.run(for: .milliseconds(10))
        let replaced = vias(f.advertised())
        XCTAssertEqual(replaced, Set(first.dropFirst().map(\.key)).union(f.best(late, 1)))

        first[1].send(.webAddresses([WebAddress(url: "wss://moved.example")]))
        XCTAssertTrue(f.advertised().contains(WebAddress(url: "wss://moved.example", via: first[1].key)))

        first[2].send(.webAddresses([]))
        XCTAssertFalse(vias(f.advertised()).contains(first[2].key))
        f.sim.send(.command(.setRelaying(first[3].peer, false)), to: f.node)
        let now = vias(f.advertised())
        XCTAssertFalse(now.contains(first[3].key))
        XCTAssertEqual(now.count, 4)
    }

    /// A declared list wins; with auto relay off nothing is advertised.
    func testDeclaredAddressesWinAndOffAdvertisesNothing() {
        let f = Fixture()
        let relays = (0..<2).map { _ in f.peer() }
        XCTAssertEqual(vias(f.advertised()), Set(relays.map(\.key)))
        let declared = [WebAddress(url: "wss://me.example")]
        f.sim.send(.command(.setWebAddresses(declared)), to: f.node)
        XCTAssertEqual(f.advertised(), declared)
        _ = f.peer()
        XCTAssertEqual(f.advertised(), declared)
        f.sim.send(.command(.setWebAddresses([])), to: f.node)
        XCTAssertEqual(f.advertised().count, 3)
        f.sim.send(.command(.setAutoRelay(false)), to: f.node)
        XCTAssertEqual(f.advertised(), [])
    }
}
