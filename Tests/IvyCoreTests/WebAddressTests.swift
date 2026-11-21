import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation

/// Web addresses: peers tell their sessions where browsers can reach them
/// (tag 43), and provider answers to peers that did carry each record's
/// addresses (tag 44). Peers that never sent tag 43 get tag 41 as before.
final class WebAddressTests: XCTestCase {
    private let direct = WebAddress(url: "wss://a.example/ivy")

    private func relayed(_ sim: Simulation) -> WebAddress {
        WebAddress(url: "wss://relay.example/ivy", via: sim.discoveryKey(index: 99))
    }

    /// Every session is told this node's addresses, empty until set.
    /// An announcement is stored with the announcer's addresses; a peer
    /// that sent tag 43 is answered with them, one that did not with tag 41.
    func testAnswersCarryTheAnnouncersAddressesOnlyToPeersThatSentThem() {
        let sim = Simulation()
        let node = sim.node()
        let announcer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let browser = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let old = DiscoveryScriptedPeer(sim, to: node, index: 2)
        let addresses = [direct, relayed(sim)]
        let expiry = sim.unixSeconds + 60
        XCTAssertEqual(old.takeWebAddresses(), [[]])

        announcer.send(.webAddresses(addresses))
        announcer.send(.announceProvider(rootCID: "root", expiresAt: expiry))
        browser.send(.webAddresses([]))
        XCTAssertEqual(node.core.webAddresses(of: announcer.peer), addresses)
        XCTAssertEqual(node.core.webAddresses(of: browser.peer), [])
        XCTAssertNil(node.core.webAddresses(of: old.peer), "never sent any")

        browser.send(.findProviders(rootCID: "root", requestID: 7))
        old.send(.findProviders(rootCID: "root", requestID: 8))

        let withAddresses = browser.takeProvidersWithAddresses()
        XCTAssertEqual(withAddresses.map(\.requestID), [7])
        XCTAssertEqual(withAddresses.first?.records, [
            ProviderRecord(endpoint: announcer.endpoint, expiresAt: expiry, webAddresses: addresses),
        ])
        XCTAssertTrue(browser.takeProviders().isEmpty)
        let plain = old.takeProviders()
        XCTAssertEqual(plain.map(\.requestID), [8])
        XCTAssertEqual(plain.first?.records, [ProviderRecord(endpoint: announcer.endpoint, expiresAt: expiry)])
        XCTAssertTrue(old.takeProvidersWithAddresses().isEmpty)
    }

    /// A record learned from a tag-44 answer keeps its addresses: the
    /// search returns them and the node serves them onward.
    func testAddressesSurviveAReferralHop() {
        let sim = Simulation()
        let node = sim.node()
        let responder = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let asker = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let provider = sim.discoveryUnreachableEndpoint(index: 0)
        let addresses = [relayed(sim)]
        let expiry = sim.unixSeconds + 60

        let search = sim.request(.discoverProviderAddresses(rootCID: "root"), on: node)
        sim.settleLookups(on: node, answering: [responder, asker])
        for peer in [responder, asker] {
            for asked in peer.takeFindProviders() {
                let records = peer === responder
                    ? [ProviderRecord(endpoint: provider, expiresAt: expiry, webAddresses: addresses)]
                    : []
                peer.send(.providersWithAddresses(
                    rootCID: asked.rootCID, requestID: asked.requestID, records: records))
            }
        }
        XCTAssertTrue(sim.run(until: { sim.result(of: search, on: node) != nil }, timeout: .seconds(5)))
        guard case .providers(let found) = sim.result(of: search, on: node) else {
            return XCTFail("no providers result")
        }
        XCTAssertEqual(found, [DiscoveredProvider(endpoint: provider, webAddresses: addresses)])

        asker.send(.webAddresses([]))
        asker.send(.findProviders(rootCID: "root", requestID: 9))
        XCTAssertEqual(asker.takeProvidersWithAddresses().first?.records, [
            ProviderRecord(endpoint: provider, expiresAt: expiry, webAddresses: addresses),
        ])
    }

    /// Setting addresses tells every session again, and this node's own
    /// records carry the new set. On the receiving side, an announcement
    /// carries what the announcer last sent.
    func testChangingAddressesIsResentAndCarriedByLaterAnnouncements() {
        let sim = Simulation()
        let node = sim.discoveryNode(externalAddress: ("8.44.0.1", 5000))
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let expiry = sim.unixSeconds + 60

        sim.send(.command(.setWebAddresses([direct])), to: node)
        sim.send(.command(.setWebAddresses([WebAddress(url: "ftp://nope")])), to: node)
        XCTAssertEqual(peer.takeWebAddresses(), [[], [direct]], "an invalid set is ignored")
        sim.send(.command(.announceProvider(rootCID: "own", expiresAt: expiry)), to: node)
        XCTAssertEqual(node.core.providerHints["own"]?.map(\.webAddresses), [[direct]])
        sim.send(.command(.setWebAddresses([])), to: node)
        XCTAssertEqual(peer.takeWebAddresses(), [[]])
        XCTAssertEqual(node.core.providerHints["own"]?.map(\.webAddresses), [[]])

        peer.send(.webAddresses([direct]))
        peer.send(.announceProvider(rootCID: "first", expiresAt: expiry))
        peer.send(.webAddresses([relayed(sim)]))
        peer.send(.announceProvider(rootCID: "second", expiresAt: expiry))
        XCTAssertEqual(node.core.providerHints["first"]?.map(\.webAddresses), [[direct]])
        XCTAssertEqual(node.core.providerHints["second"]?.map(\.webAddresses), [[relayed(sim)]])
    }
}
