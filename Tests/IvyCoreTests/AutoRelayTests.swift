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
            node = sim.discoveryNode()
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

        /// What the node last told its sessions, once changes other peers
        /// caused have waited out their interval.
        func advertised() -> [WebAddress] {
            sim.run(for: IvyCore.webAddressesInterval + .seconds(1))
            if let latest = observer.takeWebAddresses().last { last = latest }
            return last
        }

        func rank(_ peer: DiscoveryScriptedPeer) -> [UInt8] {
            Array(SHA256.hash(data: node.key.rawRepresentation + peer.key.rawRepresentation))
        }

        func best(_ peers: [DiscoveryScriptedPeer], _ count: Int) -> Set<PeerKey> {
            Set(peers.sorted { rank($0).lexicographicallyPrecedes(rank($1)) }.prefix(count).map(\.key))
        }

        func peers(_ all: [DiscoveryScriptedPeer], excluding keys: Set<PeerKey>) -> [DiscoveryScriptedPeer] {
            all.filter { !keys.contains($0.key) }
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

    /// Half the slots hold their relays, the oldest first, while they stay
    /// candidates; the other half always go to the best-ranked, so relays
    /// that arrive first cannot keep them all. A lost relay is replaced, and
    /// a relay's changed addresses or `setRelaying(false)` take effect.
    func testHalfTheSlotsAreStickyAndEachRelayIsFollowed() {
        let f = Fixture()
        let first = (0..<4).map { _ in f.peer() }
        let initial = f.advertised().compactMap(\.via)
        XCTAssertEqual(Set(initial), Set(first.map(\.key)))

        let late = (0..<6).map { _ in f.peer() }
        let all = first + late
        let kept = Set(initial.prefix(2))
        let now = f.advertised()
        XCTAssertEqual(vias(now), kept.union(f.best(f.peers(all, excluding: kept), 2)))

        let lost = all.first { $0.key == now[0].via }!
        lost.close()
        let replaced = vias(f.advertised())
        XCTAssertEqual(replaced.count, 4)
        XCTAssertFalse(replaced.contains(lost.key))

        let moving = all.first { $0.key == f.advertised()[0].via }!
        moving.send(.webAddresses([WebAddress(url: "wss://moved.example")]))
        XCTAssertTrue(f.advertised().contains(WebAddress(url: "wss://moved.example", via: moving.key)))
        moving.send(.webAddresses([]))
        XCTAssertFalse(vias(f.advertised()).contains(moving.key))
        let unmarked = all.first { $0.key == f.advertised()[0].via }!
        f.sim.send(.command(.setRelaying(unmarked.peer, false)), to: f.node)
        XCTAssertFalse(vias(f.advertised()).contains(unmarked.key))
    }

    /// A relay that flaps makes the node tell its sessions at most once an
    /// interval, and the last state always goes out.
    func testAFlappingRelayIsCoalesced() throws {
        let f = Fixture()
        let relay = f.peer()
        XCTAssertEqual(vias(f.advertised()), [relay.key])
        for index in 0..<5 {
            relay.send(.webAddresses([WebAddress(url: "wss://flap\(index).example")]))
            f.sim.run(for: .milliseconds(100))
        }
        f.sim.run(for: IvyCore.webAddressesInterval + .seconds(1))
        let sent = f.observer.takeWebAddresses()
        XCTAssertLessThanOrEqual(sent.count, 2)
        XCTAssertEqual(sent.last, [WebAddress(url: "wss://flap4.example", via: relay.key)])
    }

    /// A session that opens is told this node's addresses exactly once.
    func testANewSessionIsToldOnce() {
        let f = Fixture()
        let relay = f.peer()
        let current = f.advertised()
        XCTAssertEqual(vias(current), [relay.key])
        let newcomer = DiscoveryScriptedPeer(f.sim, to: f.node, index: 50)
        f.sim.run(for: IvyCore.webAddressesInterval + .seconds(1))
        XCTAssertEqual(newcomer.takeWebAddresses(), [current])
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
