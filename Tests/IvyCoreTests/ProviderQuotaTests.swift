import Foundation
import XCTest
@testable import IvyCore
import Tally

private extension IvyCore {
    func hasProviderRecord(rootCID: String, peer: PeerID) -> Bool {
        providerHints[rootCID]?.contains { $0.peer == peer } == true
    }

    func providerRecords(rootCID: String, peer: PeerID) -> [ProviderHint] {
        providerHints[rootCID]?.filter { $0.peer == peer } ?? []
    }

    func storedProviderRecordCount() -> Int {
        providerHints.values.reduce(0) { $0 + $1.count }
    }
}

/// Provider record quota. The handlers are called on a core value directly,
/// as 15.0.1's tests called them on the actor.
final class ProviderQuotaTests: XCTestCase {
    private func node(
        _ label: String, quota: Int, maxConnections: Int = 256, kBucketSize: Int = 20
    ) -> IvyCore {
        var core = IvyCore(config: IvyConfig(
            signingKey: wireTestSigningKey(label),
            listenPort: 0,
            kBucketSize: kBucketSize,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            maxConnections: maxConnections,
            maxProviderRecordsPerPeer: quota))
        // Provider expiry is judged against the wall clock the core was last stepped at.
        _ = core.step(.start, now: Timestamp(uptime: .zero, unixSeconds: 1_800_000_000))
        return core
    }

    private func peer(_ label: String) -> PeerID {
        PeerID(publicKey: wireTestPeerKey(label))
    }

    /// a flood from one peer cannot evict another peer's records
    func testFloodCannotEvictOthers() throws {
        var node = node("quota-flood-node", quota: 4)
        let honest = peer("quota-flood-honest")
        let flooder = peer("quota-flood-flooder")
        let expiry = node.nowUnix() + 60
        node.handleAnnounceProvider(rootCID: "honest-root", expiresAt: expiry, from: honest)

        let maxExpiry = node.nowUnix() + IvyConfig.defaultMaxProviderTTLSeconds
        for index in 0..<200 {
            node.handleAnnounceProvider(
                rootCID: "junk-\(index)", expiresAt: maxExpiry, from: flooder)
        }

        XCTAssert(node.hasProviderRecord(rootCID: "honest-root", peer: honest))
        XCTAssert(node.providerRecordCount(of: flooder) == 4)
        XCTAssert(node.storedProviderRecordCount() == 5)
    }

    /// a peer at its quota replaces only its own soonest-expiring record
    func testQuotaReplacesOwnSoonest() throws {
        var node = node("quota-replace-node", quota: 3)
        let honest = peer("quota-replace-honest")
        let announcer = peer("quota-replace-announcer")
        let now = node.nowUnix()
        node.handleAnnounceProvider(rootCID: "honest-root", expiresAt: now + 5, from: honest)
        node.handleAnnounceProvider(rootCID: "a", expiresAt: now + 30, from: announcer)
        node.handleAnnounceProvider(rootCID: "b", expiresAt: now + 10, from: announcer)
        node.handleAnnounceProvider(rootCID: "c", expiresAt: now + 20, from: announcer)
        node.handleAnnounceProvider(rootCID: "d", expiresAt: now + 40, from: announcer)

        XCTAssert(!node.hasProviderRecord(rootCID: "b", peer: announcer))
        for root in ["a", "c", "d"] {
            XCTAssert(node.hasProviderRecord(rootCID: root, peer: announcer))
        }
        XCTAssert(node.hasProviderRecord(rootCID: "honest-root", peer: honest))
        XCTAssert(node.providerRecordCount(of: announcer) == 3)
    }

    /// at the ceiling the heaviest source gives up a record, so honest peers still get in
    func testCeilingEvictsFromHeaviestSource() throws {
        // Ceiling = maxConnections * quota = 2 * 3.
        var node = node("quota-ceiling-node", quota: 3, maxConnections: 2)
        let honest = peer("quota-ceiling-honest")
        let lateHonest = peer("quota-ceiling-late-honest")
        let flooderA = peer("quota-ceiling-flooder-a")
        let flooderB = peer("quota-ceiling-flooder-b")
        let now = node.nowUnix()
        let maxExpiry = now + IvyConfig.defaultMaxProviderTTLSeconds
        node.handleAnnounceProvider(rootCID: "honest", expiresAt: now + 60, from: honest)
        for index in 0..<50 {
            node.handleAnnounceProvider(
                rootCID: "a-\(index)", expiresAt: maxExpiry, from: flooderA)
            node.handleAnnounceProvider(
                rootCID: "b-\(index)", expiresAt: maxExpiry, from: flooderB)
        }
        XCTAssert(node.storedProviderRecordCount() == 6)

        node.handleAnnounceProvider(rootCID: "late", expiresAt: now + 60, from: lateHonest)
        for index in 50..<100 {
            node.handleAnnounceProvider(
                rootCID: "a-\(index)", expiresAt: maxExpiry, from: flooderA)
        }

        XCTAssert(node.hasProviderRecord(rootCID: "honest", peer: honest))
        XCTAssert(node.hasProviderRecord(rootCID: "late", peer: lateHonest))
        XCTAssert(node.storedProviderRecordCount() == 6)
    }

    /// admission at the ceiling does not sweep the whole table
    func testCeilingAdmissionIsNotATableSweep() throws {
        var node = node("quota-sweep-node", quota: 3, maxConnections: 2)
        let stale = peer("quota-sweep-stale")
        let flooder = peer("quota-sweep-flooder")
        let honest = peer("quota-sweep-honest")
        let now = node.nowUnix()
        node.storeProviderHint(rootCID: "stale", peer: stale, endpoint: nil, expiresAt: now - 1)
        for index in 0..<3 {
            node.handleAnnounceProvider(
                rootCID: "f-\(index)", expiresAt: now + 600, from: flooder)
        }
        for index in 0..<2 {
            node.handleAnnounceProvider(
                rootCID: "h-\(index)", expiresAt: now + 600, from: honest)
        }
        XCTAssert(node.storedProviderRecordCount() == 6)

        node.handleAnnounceProvider(rootCID: "h-2", expiresAt: now + 600, from: honest)

        // The expired record in an untouched root is still there: no global sweep ran;
        // the heaviest source (the flooder) gave up one record instead.
        XCTAssert(node.hasProviderRecord(rootCID: "stale", peer: stale))
        XCTAssert(node.providerRecordCount(of: flooder) == 2)
        XCTAssert(node.providerRecordCount(of: honest) == 3)
    }

    /// referred records count against the responder that relayed them
    func testReferralFloodIsBounded() throws {
        var node = node("quota-referral-node", quota: 5)
        let honest = peer("quota-referral-honest")
        let responder = peer("quota-referral-responder")
        let expiry = node.nowUnix() + 60
        node.handleAnnounceProvider(rootCID: "honest-root", expiresAt: expiry, from: honest)

        for rootIndex in 0..<3 {
            let root = "referral-root-\(rootIndex)"
            let requestID = UInt64(100 + rootIndex)
            let records = (0..<20).map { index in
                ProviderRecord(
                    endpoint: PeerEndpoint(
                        publicKey: wireTestPeerKey("fake-\(rootIndex)-\(index)"),
                        host: "8.8.\(rootIndex + 1).\(index + 1)",
                        port: 4001),
                    expiresAt: expiry)
            }
            let endpoints = try refer(
                &node, root: root, requestID: requestID, records: records, from: responder)
            XCTAssert(endpoints.count == 20)
        }

        XCTAssert(node.providerRecordCount(of: responder) == 5)
        XCTAssert(node.storedProviderRecordCount() == 6)
        XCTAssert(node.hasProviderRecord(rootCID: "honest-root", peer: honest))
    }

    /// a referral cannot rewrite, push out, or adopt a provider's direct record
    func testReferralCannotTakeOverDirectRecord() throws {
        var node = node("quota-takeover-node", quota: 1)
        let honest = peer("quota-takeover-honest")
        let responder = peer("quota-takeover-responder")
        let now = node.nowUnix()
        let direct = PeerEndpoint(publicKey: honest.publicKey, host: "1.1.1.1", port: 4001)
        node.storeProviderHint(
            rootCID: "root", peer: honest, endpoint: direct, expiresAt: now + 600)

        // Same endpoint with a short expiry, plus alternative routes for the same identity.
        let records = [ProviderRecord(endpoint: direct, expiresAt: now + 5)]
            + (1...IvyConfig.defaultMaxRoutesPerIdentity).map { index in
                ProviderRecord(
                    endpoint: PeerEndpoint(
                        publicKey: honest.publicKey, host: "8.8.8.\(index)", port: 4001),
                    expiresAt: now + 5)
            }
        try refer(&node, root: "root", requestID: 200, records: records, from: responder)
        XCTAssert(node.providerRecords(rootCID: "root", peer: honest)
            == [ProviderHint(peer: honest, endpoint: direct, expiresAt: now + 600, source: honest)])
        XCTAssert(node.providerRecordCount(of: responder) == 0)

        // The responder's own quota eviction cannot reach the honest record either.
        let other = PeerEndpoint(
            publicKey: wireTestPeerKey("quota-takeover-other"), host: "8.8.4.4", port: 4001)
        for (index, root) in ["other-1", "other-2"].enumerated() {
            try refer(
                &node, root: root, requestID: UInt64(201 + index),
                records: [ProviderRecord(endpoint: other, expiresAt: now + 60)], from: responder)
        }
        XCTAssert(node.providerRecordCount(of: responder) == 1)
        XCTAssert(node.hasProviderRecord(rootCID: "root", peer: honest))
    }

    /// a provider's re-announcement replaces routes referred for it after its record expired
    func testDirectRecordReplacesReferredRoutes() throws {
        var node = node("quota-supersede-node", quota: 100)
        let honest = peer("quota-supersede-honest")
        let responder = peer("quota-supersede-responder")
        let now = node.nowUnix()
        node.storeProviderHint(
            rootCID: "root",
            peer: honest,
            endpoint: PeerEndpoint(publicKey: honest.publicKey, host: "1.1.1.1", port: 4001),
            expiresAt: now)

        let wrong = (1...IvyConfig.defaultMaxRoutesPerIdentity).map { index in
            ProviderRecord(
                endpoint: PeerEndpoint(
                    publicKey: honest.publicKey, host: "8.8.8.\(index)", port: 4001),
                expiresAt: now + 600)
        }
        try refer(&node, root: "root", requestID: 400, records: wrong, from: responder)
        XCTAssert(node.providerRecordCount(of: responder) == wrong.count)

        let moved = PeerEndpoint(publicKey: honest.publicKey, host: "1.0.0.1", port: 4002)
        node.storeProviderHint(
            rootCID: "root", peer: honest, endpoint: moved, expiresAt: now + 600)

        XCTAssert(node.providerRecords(rootCID: "root", peer: honest)
            == [ProviderHint(peer: honest, endpoint: moved, expiresAt: now + 600, source: honest)])
        XCTAssert(node.providerRecordCount(of: responder) == 0)
        XCTAssert(node.providerRecordCount(of: honest) == 1)
    }

    /// a full root sheds referred-only providers before self-announced ones
    func testFullRootShedsReferredFirst() throws {
        var node = node("quota-shed-node", quota: 100, kBucketSize: 2)
        let honest = peer("quota-shed-honest")
        let responder = peer("quota-shed-responder")
        let now = node.nowUnix()
        node.handleAnnounceProvider(rootCID: "root", expiresAt: now + 600, from: honest)
        let records = (0..<4).map { index in
            ProviderRecord(
                endpoint: PeerEndpoint(
                    publicKey: wireTestPeerKey("quota-shed-fake-\(index)"),
                    host: "8.8.8.\(index + 1)",
                    port: 4001),
                expiresAt: now + 600)
        }
        try refer(&node, root: "root", requestID: 300, records: records, from: responder)

        XCTAssert(node.hasProviderRecord(rootCID: "root", peer: honest))
        XCTAssert(node.storedProviderRecordCount() == 2)
    }

    /// a responder's referrals at its quota never evict its own announcement
    func testReferralNeverEvictsAnnouncement() throws {
        var node = node("quota-referral-rule-node", quota: 2)
        let responder = peer("quota-referral-rule-responder")
        let now = node.nowUnix()
        // The responder's own announcement is its soonest-expiring record.
        node.handleAnnounceProvider(rootCID: "own", expiresAt: now + 5, from: responder)
        for index in 0..<4 {
            let referred = PeerEndpoint(
                publicKey: wireTestPeerKey("quota-referral-rule-\(index)"),
                host: "8.8.8.\(index + 1)", port: 4001)
            try refer(
                &node, root: "referred-\(index)", requestID: UInt64(500 + index),
                records: [ProviderRecord(endpoint: referred, expiresAt: now + 600)],
                from: responder)
        }
        // Each referral past the quota replaced the previous referral.
        XCTAssert(node.hasProviderRecord(rootCID: "own", peer: responder))
        XCTAssert(node.providerRecordCount(of: responder) == 2)
        XCTAssert(node.storedProviderRecordCount() == 2)
        XCTAssert(node.providers(for: "referred-3").count == 1)

        // With only announcements left to give up, the referral is dropped.
        node.handleAnnounceProvider(rootCID: "own-2", expiresAt: now + 5, from: responder)
        XCTAssert(node.providers(for: "referred-3").isEmpty)
        let late = PeerEndpoint(
            publicKey: wireTestPeerKey("quota-referral-rule-late"),
            host: "8.8.4.4", port: 4001)
        try refer(
            &node, root: "referred-late", requestID: 510,
            records: [ProviderRecord(endpoint: late, expiresAt: now + 600)], from: responder)
        XCTAssert(node.providers(for: "referred-late").isEmpty)
        XCTAssert(node.hasProviderRecord(rootCID: "own", peer: responder))
        XCTAssert(node.hasProviderRecord(rootCID: "own-2", peer: responder))
    }

    /// an announcement at quota evicts a referral before another announcement, an expired record before either
    func testAnnouncementEvictsReferralFirst() throws {
        var node = node("quota-announce-rule-node", quota: 2)
        let responder = peer("quota-announce-rule-responder")
        let now = node.nowUnix()
        node.handleAnnounceProvider(rootCID: "a", expiresAt: now + 5, from: responder)
        let referred = PeerEndpoint(
            publicKey: wireTestPeerKey("quota-announce-rule-referred"),
            host: "8.8.8.8", port: 4001)
        try refer(
            &node, root: "referred", requestID: 600,
            records: [ProviderRecord(endpoint: referred, expiresAt: now + 600)], from: responder)

        // The referral goes, though the announcement "a" expires sooner.
        node.handleAnnounceProvider(rootCID: "b", expiresAt: now + 600, from: responder)
        XCTAssert(node.providers(for: "referred").isEmpty)
        XCTAssert(node.hasProviderRecord(rootCID: "a", peer: responder))
        XCTAssert(node.hasProviderRecord(rootCID: "b", peer: responder))

        // With only announcements, the soonest-expiring one goes.
        node.handleAnnounceProvider(rootCID: "c", expiresAt: now + 600, from: responder)
        XCTAssert(!node.hasProviderRecord(rootCID: "a", peer: responder))
        XCTAssert(node.providerRecordCount(of: responder) == 2)

        // An expired announcement goes before a live referral, to a referral too.
        var expired = self.node("quota-expired-rule-node", quota: 2)
        expired.storeProviderHint(
            rootCID: "expired", peer: responder, endpoint: nil, expiresAt: now - 1)
        try refer(
            &expired, root: "referred", requestID: 601,
            records: [ProviderRecord(endpoint: referred, expiresAt: now + 5)], from: responder)
        try refer(
            &expired, root: "referred-2", requestID: 602,
            records: [ProviderRecord(endpoint: referred, expiresAt: now + 600)], from: responder)
        XCTAssert(!expired.hasProviderRecord(rootCID: "expired", peer: responder))
        XCTAssert(expired.providers(for: "referred").count == 1)
        XCTAssert(expired.providers(for: "referred-2").count == 1)
    }

    /// Delivers `records` as `responder`'s answer to a provider query for
    /// `root`, and returns what the search waiting on it was told.
    @discardableResult
    private func refer(
        _ node: inout IvyCore,
        root: String,
        requestID: UInt64,
        records: [ProviderRecord],
        from responder: PeerID
    ) throws -> [PeerEndpoint] {
        let search: OpID = node.makeID()
        let request = RequestID(requestID)
        node.providerSearches[search] = ProviderSearch(
            rootCID: root, waiter: .request(request, cached: []))
        node.pendingProviderQueries[root] = PendingProviderQuery(
            requestID: requestID,
            waiters: [search],
            expectedPeers: [responder.publicKey],
            responsesByPeer: [:])
        node.handleProvidersResponse(
            rootCID: root, requestID: requestID, records: records, from: responder)
        XCTAssertNil(node.pendingProviderQueries[root])
        let effects = node.effects
        node.effects.removeAll()
        for case .completed(request, .endpoints(let endpoints)) in effects { return endpoints }
        XCTFail("the provider search was not answered")
        return []
    }
}
