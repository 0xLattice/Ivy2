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

    /// Runs a `discoverProviderAddresses` for `root` on `node`; each peer in
    /// `answers` answers with its records in tag 44, every other peer asked
    /// with none.
    private func search(
        _ sim: Simulation, _ node: Simulation.Node, root: String,
        peers: [DiscoveryScriptedPeer], answers: [ObjectIdentifier: [ProviderRecord]]
    ) -> [DiscoveredProvider]? {
        let search = sim.request(.discoverProviderAddresses(rootCID: root), on: node)
        sim.settleLookups(on: node, answering: peers)
        for peer in peers {
            for asked in peer.takeFindProviders() {
                peer.send(.providersWithAddresses(
                    rootCID: asked.rootCID, requestID: asked.requestID,
                    records: answers[ObjectIdentifier(peer)] ?? []))
            }
        }
        guard sim.run(until: { sim.result(of: search, on: node) != nil }, timeout: .seconds(5)),
              case .providers(let found) = sim.result(of: search, on: node) else { return nil }
        return found
    }

    /// What `asker` is answered for `root`, as routes.
    private func answer(_ asker: DiscoveryScriptedPeer, root: String) -> [DiscoveredProvider]? {
        asker.send(.findProviders(rootCID: root, requestID: 9))
        return asker.takeProvidersWithAddresses().first?.records.map {
            DiscoveredProvider(endpoint: $0.endpoint, webAddresses: $0.webAddresses)
        }
    }

    /// A record learned from a tag-44 answer keeps its addresses: the
    /// search returns them and the node serves them onward.
    func testAddressesSurviveAReferralHop() throws {
        let sim = Simulation()
        let node = sim.node()
        let responder = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let asker = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let provider = sim.discoveryUnreachableEndpoint(index: 0)
        let addresses = [relayed(sim)]
        let expiry = sim.unixSeconds + 60
        let route = DiscoveredProvider(endpoint: provider, webAddresses: addresses)

        let found = search(sim, node, root: "root", peers: [responder, asker], answers: [
            ObjectIdentifier(responder): [ProviderRecord(endpoint: provider, expiresAt: expiry, webAddresses: addresses)],
        ])
        XCTAssertEqual(found, [route])
        asker.send(.webAddresses([]))
        XCTAssertEqual(answer(asker, root: "root"), [route])
    }

    /// A referral naming a provider's endpoint with other addresses is a
    /// route of its own beside the honest one, never a replacement; and no
    /// referral touches what a provider announced for itself.
    func testAReferralCannotReplaceAProvidersAddresses() throws {
        let sim = Simulation()
        let node = sim.node()
        let honest = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let hostile = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let asker = DiscoveryScriptedPeer(sim, to: node, index: 2)
        let announcer = DiscoveryScriptedPeer(sim, to: node, index: 3)
        let peers = [honest, hostile, asker, announcer]
        let provider = sim.discoveryUnreachableEndpoint(index: 0)
        let expiry = sim.unixSeconds + 60
        asker.send(.webAddresses([]))

        let real = DiscoveredProvider(endpoint: provider, webAddresses: [direct])
        let spoof = DiscoveredProvider(endpoint: provider, webAddresses: [])
        let found = try XCTUnwrap(search(sim, node, root: "referred", peers: peers, answers: [
            ObjectIdentifier(honest): [ProviderRecord(endpoint: provider, expiresAt: expiry, webAddresses: [direct])],
            ObjectIdentifier(hostile): [ProviderRecord(endpoint: provider, expiresAt: expiry)],
        ]))
        XCTAssertEqual(Set(found), [real, spoof])
        XCTAssertEqual(Set(try XCTUnwrap(answer(asker, root: "referred"))), [real, spoof])

        announcer.send(.webAddresses([direct]))
        announcer.send(.announceProvider(rootCID: "announced", expiresAt: expiry))
        _ = search(sim, node, root: "announced", peers: peers, answers: [
            ObjectIdentifier(hostile): [ProviderRecord(endpoint: announcer.endpoint, expiresAt: expiry)],
        ])
        XCTAssertEqual(answer(asker, root: "announced"),
                       [DiscoveredProvider(endpoint: announcer.endpoint, webAddresses: [direct])])
    }

    /// A referred provider at a private or loopback endpoint is kept for its
    /// web addresses, which a browser dials instead; the endpoint itself is
    /// never dialed nor named without them. With no addresses it is dropped.
    func testAnUndialableEndpointIsKeptOnlyForItsWebAddresses() throws {
        let sim = Simulation()
        let node = sim.node()
        let responder = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let asker = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let peers = [responder, asker]
        let expiry = sim.unixSeconds + 60
        let loopback = sim.discoveryUnreachableEndpoint(index: 0, host: "127.0.0.1")
        let homelab = sim.discoveryUnreachableEndpoint(index: 1, host: "192.168.1.20")
        let bare = sim.discoveryUnreachableEndpoint(index: 2, host: "10.0.0.5")
        let addresses = [relayed(sim)]

        let found = try XCTUnwrap(search(sim, node, root: "root", peers: peers, answers: [
            ObjectIdentifier(responder): [
                ProviderRecord(endpoint: loopback, expiresAt: expiry, webAddresses: addresses),
                ProviderRecord(endpoint: homelab, expiresAt: expiry, webAddresses: [direct]),
                ProviderRecord(endpoint: bare, expiresAt: expiry),
                // Only private and loopback hosts are kept for addresses.
                ProviderRecord(endpoint: sim.discoveryUnreachableEndpoint(index: 3, host: "169.254.1.1"),
                               expiresAt: expiry, webAddresses: [direct]),
                ProviderRecord(endpoint: sim.discoveryUnreachableEndpoint(index: 4, host: "provider.example"),
                               expiresAt: expiry, webAddresses: [direct]),
            ],
        ]))
        XCTAssertEqual(Set(found), [
            DiscoveredProvider(endpoint: loopback, webAddresses: addresses),
            DiscoveredProvider(endpoint: homelab, webAddresses: [direct]),
        ])

        // Native callers dial what they are given: none of these.
        XCTAssertEqual(sim.await(.discoverProviders(rootCID: "root"), on: node)?.endpoints, [])
        _ = sim.await(.fetchVolume(rootCID: "root", maximumArchiveBytes: 1 << 20, maximumEntries: 16),
                      on: node, timeout: .seconds(30))
        let dialed = sim.trace.compactMap { entry -> String? in
            if case .dial(_, let endpoint) = entry.effect { return endpoint.host } else { return nil }
        }
        XCTAssertTrue(Set(dialed).isDisjoint(with: ["127.0.0.1", "192.168.1.20", "10.0.0.5"]), "\(dialed)")

        asker.send(.findProviders(rootCID: "root", requestID: 8))
        XCTAssertEqual(asker.takeProviders().first?.records, [], "tag 41 names neither")
        asker.send(.webAddresses([]))
        XCTAssertEqual(Set(try XCTUnwrap(answer(asker, root: "root"))), Set(found))
    }

    /// A provider on a LAN answering for itself is dialable; a referral
    /// copying its route is not. The copy never displaces it, whatever order
    /// the answers are taken in.
    func testACopyOfALANProvidersRouteNeverDisplacesIt() throws {
        let sim = Simulation()
        let node = sim.node()
        let lan = DiscoveryScriptedPeer(sim, to: node, index: 0, host: "192.168.1.30")
        let copier = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let record = ProviderRecord(endpoint: lan.endpoint, expiresAt: sim.unixSeconds + 60, webAddresses: [direct])
        for round in 0..<12 {
            let root = "root-\(round)"
            let search = sim.request(.discoverProviders(rootCID: root), on: node)
            sim.settleLookups(on: node, answering: [lan, copier])
            for peer in [lan, copier] {
                for asked in peer.takeFindProviders() {
                    peer.send(.providersWithAddresses(
                        rootCID: asked.rootCID, requestID: asked.requestID, records: [record]))
                }
            }
            XCTAssertTrue(sim.run(until: { sim.result(of: search, on: node) != nil }, timeout: .seconds(5)))
            XCTAssertEqual(sim.result(of: search, on: node)?.endpoints, [lan.endpoint], root)
        }
    }

    /// Routes that differ only in their addresses are one route to a peer
    /// answered without addresses: each endpoint once, so none crowds out
    /// another.
    func testAnAnswerWithoutAddressesNamesEachEndpointOnce() throws {
        let sim = Simulation()
        let node = sim.node()
        let first = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let second = DiscoveryScriptedPeer(sim, to: node, index: 1)
        let old = DiscoveryScriptedPeer(sim, to: node, index: 2)
        let expiry = sim.unixSeconds + 60
        let shared = sim.discoveryUnreachableEndpoint(index: 0)
        let other = sim.discoveryUnreachableEndpoint(index: 0, host: "7.9.0.1")

        _ = search(sim, node, root: "root", peers: [first, second, old], answers: [
            ObjectIdentifier(first): [
                ProviderRecord(endpoint: shared, expiresAt: expiry, webAddresses: [direct]),
                ProviderRecord(endpoint: other, expiresAt: expiry),
            ],
            ObjectIdentifier(second): [ProviderRecord(endpoint: shared, expiresAt: expiry)],
        ])

        old.send(.findProviders(rootCID: "root", requestID: 9))
        let records = try XCTUnwrap(old.takeProviders().first?.records)
        XCTAssertEqual(Set(records.map(\.endpoint)), [shared, other])
        XCTAssertEqual(records.count, 2)
    }

    /// A provider's records are answered with the addresses it sent last,
    /// whenever it announced them; this node's own with its own.
    func testRecordsCarryTheProvidersLatestAddresses() {
        let sim = Simulation()
        let node = sim.discoveryNode(externalAddress: ("8.44.0.1", 5000))
        let peer = DiscoveryScriptedPeer(sim, to: node, index: 0)
        let asker = DiscoveryScriptedPeer(sim, to: node, index: 1)
        asker.send(.webAddresses([]))
        let expiry = sim.unixSeconds + 60
        let own = PeerEndpoint(publicKey: node.key.hex, host: "8.44.0.1", port: 5000)

        sim.send(.command(.setWebAddresses([direct])), to: node)
        sim.send(.command(.setWebAddresses([WebAddress(url: "ftp://nope")])), to: node)
        XCTAssertEqual(peer.takeWebAddresses(), [[], [direct]], "an invalid set is ignored")
        sim.send(.command(.announceProvider(rootCID: "own", expiresAt: expiry)), to: node)
        XCTAssertEqual(answer(asker, root: "own"), [DiscoveredProvider(endpoint: own, webAddresses: [direct])])
        sim.send(.command(.setWebAddresses([])), to: node)
        XCTAssertEqual(peer.takeWebAddresses(), [[]])
        XCTAssertEqual(answer(asker, root: "own"), [DiscoveredProvider(endpoint: own, webAddresses: [])])

        peer.send(.webAddresses([direct]))
        peer.send(.announceProvider(rootCID: "first", expiresAt: expiry))
        XCTAssertEqual(answer(asker, root: "first"),
                       [DiscoveredProvider(endpoint: peer.endpoint, webAddresses: [direct])])
        peer.send(.webAddresses([relayed(sim)]))
        peer.send(.announceProvider(rootCID: "second", expiresAt: expiry))
        for root in ["first", "second"] {
            XCTAssertEqual(answer(asker, root: root),
                           [DiscoveredProvider(endpoint: peer.endpoint, webAddresses: [relayed(sim)])], root)
        }
    }

    /// An answer too large for the asker's frame size is still sent: the
    /// last records lose their addresses, then the last records go.
    func testAnAnswerIsFittedToTheAskersFrameSize() throws {
        let sim = Simulation()
        let node = sim.node()
        let long = (0..<4).map {
            WebAddress(url: "wss://\($0)" + String(repeating: "a", count: 240), via: sim.discoveryKey(index: 99))
        }
        let announcers = (0..<8).map { DiscoveryScriptedPeer(sim, to: node, index: $0) }
        for announcer in announcers {
            announcer.send(.webAddresses(long))
            announcer.send(.announceProvider(rootCID: "root", expiresAt: sim.unixSeconds + 60))
        }

        for (index, frame, expected) in [(8, UInt32(4096), 8), (9, UInt32(400), 3)] {
            let asker = DiscoveryScriptedPeer(sim, to: node, index: index, maxFrameSize: frame)
            asker.send(.webAddresses([]))
            asker.send(.findProviders(rootCID: "root", requestID: 9))
            let records = try XCTUnwrap(asker.takeProvidersWithAddresses().first?.records, "\(frame)")
            XCTAssertEqual(records.count, expected, "\(frame)")
            let carrying = records.prefix { $0.webAddresses == long }.count
            XCTAssertTrue(records.dropFirst(carrying).allSatisfy(\.webAddresses.isEmpty), "\(frame)")
            XCTAssertEqual(carrying > 0, frame == 4096, "\(frame)")
        }
    }
}
