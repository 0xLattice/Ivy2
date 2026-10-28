#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Tally

struct ProviderHint: Sendable, Equatable {
    let peer: PeerID
    let endpoint: PeerEndpoint?
    let expiresAt: UInt64
    /// The authenticated peer whose quota this record counts against: the
    /// announcer, or the responder that referred it.
    let source: PeerID
}

/// One `findProviders` round for a root, shared by every search asking for it.
struct PendingProviderQuery: Sendable {
    let requestID: UInt64
    var waiters: [OpID]
    var expectedPeers: Set<String>
    var responsesByPeer: [String: [ProviderHint]]
}

enum ProviderSearchWaiter: Sendable, Equatable {
    case request(RequestID, cached: [PeerEndpoint])
    case volumeFetch(OpID)
}

/// A fresh provider lookup: a `findNode` for the root when no connected
/// peer is close to it, then `findProviders` to the closest.
struct ProviderSearch: Sendable {
    let rootCID: String
    let waiter: ProviderSearchWaiter
    var lookup: OpID?
}

extension IvyCore {
    // MARK: - Searching

    mutating func discoverProviders(_ request: RequestID, rootCID: String) {
        guard config.mode.usesOverlayServices, MessageLimits.accepts(rootCID) else {
            return complete(request, .endpoints([]))
        }
        // This node's own record is no answer: a provider looking up a root it
        // provides is looking for the others, so its record neither returns
        // nor stands in for the network's answer.
        let cached = cachedProviderEndpoints(rootCID: rootCID).filter { $0.publicKey != localKey.hex }
        // Nor is a record naming a peer already connected: it tells the
        // caller of no one new, so only a record naming a peer this node has
        // no session with answers without asking the network.
        guard !cached.contains(where: { !hasEndpointSession(PeerID(publicKey: $0.publicKey)) }) else {
            return complete(request, .endpoints(cached))
        }
        startProviderSearch(rootCID: rootCID, waiter: .request(request, cached: cached))
    }

    /// Asks the network who provides `rootCID`. The waiter always hears,
    /// possibly before this returns.
    @discardableResult
    mutating func startProviderSearch(rootCID: String, waiter: ProviderSearchWaiter) -> OpID {
        let id = makeID()
        providerSearches[id] = ProviderSearch(rootCID: rootCID, waiter: waiter)
        if case .request(let request, _) = waiter { requests[request] = .providerSearch(id) }
        guard config.mode.usesOverlayServices, isRunning, MessageLimits.accepts(rootCID) else {
            finishProviderSearch(id, [])
            return id
        }
        freshProviderQueryCount += 1
        if providerLookupTargets(rootCID: rootCID).isEmpty {
            let lookup = startLookup(target: rootCID, waiter: .providerSearch(id))
            if lookups[lookup] != nil { providerSearches[id]?.lookup = lookup }
        } else {
            queryProviders(id)
        }
        return id
    }

    mutating func providerSearchLookupFinished(_ id: OpID) {
        guard providerSearches[id] != nil else { return }
        providerSearches[id]?.lookup = nil
        guard isRunning else { return finishProviderSearch(id, []) }
        queryProviders(id)
    }

    private mutating func queryProviders(_ id: OpID) {
        guard let search = providerSearches[id] else { return }
        let rootCID = search.rootCID
        let targets = providerLookupTargets(rootCID: rootCID)
        guard !targets.isEmpty,
              pendingProviderQueries[rootCID] != nil
                || pendingProviderQueries.count < config.maxPendingRequests else {
            return finishProviderSearch(id, [])
        }
        if var pending = pendingProviderQueries[rootCID] {
            guard pending.waiters.count < config.maxWaitersPerRequest else {
                return finishProviderSearch(id, [])
            }
            pending.waiters.append(id)
            pendingProviderQueries[rootCID] = pending
            return
        }
        let requestID = makeWireOperationID(
            avoiding: Set(pendingProviderQueries.values.map(\.requestID)))
        var expected: Set<String> = []
        for target in targets {
            if case .enqueued = fireToPeer(
                target.id, .findProviders(rootCID: rootCID, requestID: requestID)) {
                expected.insert(target.id.publicKey)
            }
        }
        guard !expected.isEmpty else { return finishProviderSearch(id, []) }
        pendingProviderQueries[rootCID] = PendingProviderQuery(
            requestID: requestID,
            waiters: [id],
            expectedPeers: expected,
            responsesByPeer: [:])
        timers.set(.providerQuery(rootCID), at: now.uptime + Self.lookupResponseTimeout)
    }

    mutating func resolveProviderQuery(rootCID: String, requestID: UInt64) {
        guard let pending = pendingProviderQueries[rootCID],
              pending.requestID == requestID else { return }
        pendingProviderQueries.removeValue(forKey: rootCID)
        timers.cancel(.providerQuery(rootCID))
        let hints = diversifiedProviderHints(pending.responsesByPeer)
        for hint in hints {
            storeProviderHint(
                rootCID: rootCID,
                peer: hint.peer,
                endpoint: hint.endpoint,
                expiresAt: hint.expiresAt,
                source: hint.source)
        }
        let endpoints = hints.compactMap(\.endpoint)
        for waiter in pending.waiters { finishProviderSearch(waiter, endpoints) }
    }

    /// Ends a search and tells its waiter. Ending the last search of a
    /// round ends the round.
    mutating func finishProviderSearch(_ id: OpID, _ endpoints: [PeerEndpoint]) {
        guard let search = providerSearches.removeValue(forKey: id) else { return }
        if let lookup = search.lookup { finishLookup(lookup, cancelled: true) }
        if var pending = pendingProviderQueries[search.rootCID],
           let index = pending.waiters.firstIndex(of: id) {
            pending.waiters.remove(at: index)
            if pending.waiters.isEmpty {
                pendingProviderQueries.removeValue(forKey: search.rootCID)
                timers.cancel(.providerQuery(search.rootCID))
            } else {
                pendingProviderQueries[search.rootCID] = pending
            }
        }
        switch search.waiter {
        case .request(let request, let cached):
            complete(request, .endpoints(uniqueProviderEndpoints(cached + endpoints)))
        case .volumeFetch(let fetch):
            volumeFetchProviderSearchFinished(fetch, search: id, endpoints: endpoints)
        }
    }

    // MARK: - Records

    mutating func handleFindProviders(rootCID: String, requestID: UInt64, from peer: PeerID) {
        guard config.mode.usesOverlayServices else { return }
        evictExpiredProviders(rootCID: rootCID)
        let records = providerRecordsForWire(providerHints[rootCID] ?? [])
        fireToPeer(
            peer,
            .providers(rootCID: rootCID, requestID: requestID, records: records))
    }

    /// At most `maxNeighborCount` records, every identity's first route
    /// before any identity's second, the identities in a fresh random order:
    /// a key with more providers than one answer holds names a different
    /// sample to each asker, so none is named to every asker, and a key
    /// cannot be held by grinding identities that sort first.
    mutating func providerRecordsForWire(_ hints: [ProviderHint]) -> [ProviderRecord] {
        let records = hints.compactMap { hint -> ProviderRecord? in
            guard let endpoint = hint.endpoint else { return nil }
            return ProviderRecord(endpoint: endpoint, expiresAt: hint.expiresAt)
        }.sorted {
            ($0.endpoint.publicKey, $0.endpoint.host, $0.endpoint.port)
                < ($1.endpoint.publicKey, $1.endpoint.host, $1.endpoint.port)
        }
        let byIdentity = Dictionary(grouping: records, by: \.endpoint.publicKey)
        var selected: [ProviderRecord] = []
        let identities = random.shuffled(byIdentity.keys.sorted())
        for index in 0..<config.maxRoutesPerIdentity {
            for identity in identities
                where selected.count < Int(MessageLimits.maxNeighborCount) {
                let routes = byIdentity[identity] ?? []
                if routes.indices.contains(index) { selected.append(routes[index]) }
            }
        }
        return selected
    }

    mutating func handleProvidersResponse(
        rootCID: String,
        requestID: UInt64,
        records: [ProviderRecord],
        from peer: PeerID
    ) {
        guard config.mode.usesOverlayServices,
              var pending = pendingProviderQueries[rootCID],
              pending.requestID == requestID,
              pending.expectedPeers.remove(peer.publicKey) != nil else { return }

        var accepted: [ProviderHint] = []
        for record in records.prefix(Int(MessageLimits.maxNeighborCount)) {
            let endpoint = record.endpoint
            guard providerExpiryIsValid(record.expiresAt),
                  isAcceptableDiscoveredEndpoint(
                    endpoint,
                    provenance: .referral("provider"),
                    from: peer),
                  let key = try? PeerKey(endpoint.publicKey) else { continue }
            let canonical = PeerEndpoint(
                publicKey: key.hex,
                host: endpoint.host.trimmingWhitespace(),
                port: endpoint.port)
            accepted.append(ProviderHint(
                peer: key.peerID,
                endpoint: canonical,
                expiresAt: record.expiresAt,
                source: peer))
        }

        pending.responsesByPeer[peer.publicKey] = boundedProviderHints(accepted, rootCID: rootCID)
        pendingProviderQueries[rootCID] = pending
        if pending.expectedPeers.isEmpty {
            resolveProviderQuery(rootCID: rootCID, requestID: requestID)
        }
    }

    mutating func handleAnnounceProvider(rootCID: String, expiresAt: UInt64, from peer: PeerID) {
        guard config.mode.usesOverlayServices,
              providerExpiryIsValid(expiresAt),
              shouldStoreProviderHint(rootCID: rootCID) else { return }
        storeProviderHint(
            rootCID: rootCID,
            peer: peer,
            endpoint: providerEndpoint(for: peer),
            expiresAt: expiresAt,
            source: peer)
    }

    mutating func announceProvider(rootCID: String, expiresAt: UInt64) {
        guard config.mode.usesOverlayServices,
              MessageLimits.accepts(rootCID),
              providerExpiryIsValid(expiresAt) else { return }
        if let endpoint = localProviderEndpoint() {
            storeProviderHint(
                rootCID: rootCID,
                peer: localID,
                endpoint: endpoint,
                expiresAt: expiresAt,
                source: localID)
        }
        let message = Message.announceProvider(rootCID: rootCID, expiresAt: expiresAt)
        for entry in router.closestPeers(to: Router.hash(rootCID), count: config.kBucketSize)
            where hasEndpointSession(entry.id) {
            fireToPeer(entry.id, message)
        }
    }

    mutating func cachedProviderEndpoints(rootCID: String) -> [PeerEndpoint] {
        evictExpiredProviders(rootCID: rootCID)
        return uniqueProviderEndpoints((providerHints[rootCID] ?? []).compactMap(\.endpoint))
    }

    func uniqueProviderEndpoints(_ endpoints: [PeerEndpoint]) -> [PeerEndpoint] {
        var seen: Set<PeerEndpoint> = []
        return endpoints.filter { seen.insert($0).inserted }
    }

    func providerLookupTargets(rootCID: String) -> [Router.BucketEntry] {
        let count = min(6, max(1, config.kBucketSize))
        return router.closestPeers(to: Router.hash(rootCID), count: count).filter {
            hasEndpointSession($0.id)
        }
    }

    mutating func storeProviderHint(
        rootCID: String,
        peer: PeerID,
        endpoint: PeerEndpoint?,
        expiresAt: UInt64,
        source: PeerID? = nil
    ) {
        let source = source ?? peer
        let hint = ProviderHint(
            peer: peer,
            endpoint: endpoint,
            expiresAt: expiresAt,
            source: source)
        evictExpiredProviders(rootCID: rootCID)
        // A referral never overrides what a provider announced for itself.
        if source != peer,
           providerHints[rootCID]?.contains(where: { $0.peer == peer && $0.source == peer }) == true {
            return
        }
        // A provider's own record supersedes the routes others referred for it.
        if source == peer, var hints = providerHints[rootCID],
           hints.contains(where: { $0.peer == peer && $0.source != peer }) {
            hints.removeAll { $0.peer == peer && $0.source != peer }
            setProviderHints(hints, rootCID: rootCID)
        }
        // At its quota a source gives up one of its own records; at the table
        // ceiling the source holding the most records gives one up.
        if source != localID, addsProviderRecord(hint, rootCID: rootCID) {
            if providerRecordCount(of: source) >= config.maxProviderRecordsPerPeer {
                guard evictProviderRecord(of: source, for: hint) else { return }
            } else if providerRecordTotal >= config.maxProviderRecords,
                      let heaviest = providerSourcesByCount.keys.max()
                        .flatMap({ providerSourcesByCount[$0]?.min { $0.publicKey < $1.publicKey } }) {
                guard evictProviderRecord(of: heaviest, for: hint) else { return }
            }
        }
        setProviderHints(
            boundedProviderHints((providerHints[rootCID] ?? []) + [hint], rootCID: rootCID),
            rootCID: rootCID)
    }

    private func addsProviderRecord(_ hint: ProviderHint, rootCID: String) -> Bool {
        let existing = providerHints[rootCID] ?? []
        let next = boundedProviderHints(existing + [hint], rootCID: rootCID)
        return next.filter { $0.source == hint.source }.count
            > existing.filter { $0.source == hint.source }.count
    }

    func providerRecordCount(of source: PeerID) -> Int {
        providerRecordCounts[source] ?? 0
    }

    /// A referral never evicts an announcement. The source giving up a record
    /// loses an expired one first, then its soonest-expiring referral, then
    /// its soonest-expiring announcement, and that last only to an incoming
    /// announcement: false means an incoming referral is dropped instead.
    private mutating func evictProviderRecord(of source: PeerID, for incoming: ProviderHint) -> Bool {
        let now = nowUnix()
        func rank(_ hint: ProviderHint, _ rootCID: String) -> (Int, UInt64, String) {
            (hint.expiresAt <= now ? 0 : hint.source != hint.peer ? 1 : 2, hint.expiresAt, rootCID)
        }
        var soonest: (rootCID: String, hint: ProviderHint)?
        for rootCID in (providerRecordsBySource[source] ?? [:]).keys {
            for hint in providerHints[rootCID] ?? [] where hint.source == source {
                if let current = soonest,
                   rank(current.hint, current.rootCID) <= rank(hint, rootCID) {
                    continue
                }
                soonest = (rootCID, hint)
            }
        }
        guard let soonest,
              rank(soonest.hint, soonest.rootCID).0 < 2 || incoming.source == incoming.peer,
              var hints = providerHints[soonest.rootCID],
              let index = hints.firstIndex(of: soonest.hint) else { return false }
        hints.remove(at: index)
        setProviderHints(hints, rootCID: soonest.rootCID)
        return true
    }

    /// The single writer of `providerHints`; keeps the per-source counts exact.
    private mutating func setProviderHints(_ hints: [ProviderHint], rootCID: String) {
        for hint in providerHints[rootCID] ?? [] where hint.source != localID {
            countProviderRecord(source: hint.source, rootCID: rootCID, delta: -1)
        }
        for hint in hints where hint.source != localID {
            countProviderRecord(source: hint.source, rootCID: rootCID, delta: 1)
        }
        providerHints[rootCID] = hints.isEmpty ? nil : hints
    }

    private mutating func countProviderRecord(source: PeerID, rootCID: String, delta: Int) {
        var roots = providerRecordsBySource[source] ?? [:]
        let count = (roots[rootCID] ?? 0) + delta
        roots[rootCID] = count > 0 ? count : nil
        providerRecordsBySource[source] = roots.isEmpty ? nil : roots
        let old = providerRecordCounts[source] ?? 0
        let new = old + delta
        providerRecordCounts[source] = new > 0 ? new : nil
        providerSourcesByCount[old]?.remove(source)
        if providerSourcesByCount[old]?.isEmpty == true { providerSourcesByCount[old] = nil }
        if new > 0 { providerSourcesByCount[new, default: []].insert(source) }
        providerRecordTotal += delta
    }

    /// At most `kBucketSize` providers of `rootCID`, each with at most
    /// `maxRoutesPerIdentity` routes. A full root keeps the providers that
    /// announced themselves with a route, then those that announced with
    /// none, then those only referred; among each the ones this node's
    /// secret ranks first: who is kept depends on who is
    /// listed, not on when, how often or from what address they announced,
    /// and differs from node to node, so no provider is named by every node
    /// holding the root. A kept provider that goes away keeps its place until
    /// its record expires.
    private func boundedProviderHints(_ input: [ProviderHint], rootCID: String) -> [ProviderHint] {
        var peerOrder: [PeerID] = []
        var routesByPeer: [PeerID: [ProviderHint]] = [:]
        for hint in input {
            peerOrder.removeAll { $0 == hint.peer }
            peerOrder.append(hint.peer)
            var routes = routesByPeer[hint.peer] ?? []
            routes.removeAll { $0.endpoint == hint.endpoint }
            routes.append(hint)
            routesByPeer[hint.peer] = Array(routes.suffix(config.maxRoutesPerIdentity))
        }
        if peerOrder.count > config.kBucketSize {
            let kept = Set(peerOrder.map { peer in
                (peer: peer, tier: providerTier(routesByPeer[peer] ?? [], of: peer),
                 rank: sheddingRank(peer, rootCID))
            }.sorted {
                $0.tier != $1.tier ? $0.tier < $1.tier : $0.rank.lexicographicallyPrecedes($1.rank)
            }.prefix(config.kBucketSize).map(\.peer))
            peerOrder.removeAll { !kept.contains($0) }
        }
        return peerOrder.flatMap { routesByPeer[$0] ?? [] }
    }

    /// Announced with a route, then announced with none, then only referred:
    /// one that no answer can carry holds no place from one that could, and
    /// what a peer said for itself still outranks what others said for it.
    private func providerTier(_ routes: [ProviderHint], of peer: PeerID) -> Int {
        guard routes.contains(where: { $0.source == peer }) else { return 2 }
        return routes.contains { $0.source == peer && $0.endpoint != nil } ? 0 : 1
    }

    private func sheddingRank(_ peer: PeerID, _ rootCID: String) -> [UInt8] {
        Router.hash("\(providerSheddingSecret):\(rootCID):\(peer.publicKey)")
    }

    /// Responders take turns in a fresh random order, so none is first to
    /// fill the answer by its key.
    private mutating func diversifiedProviderHints(
        _ responses: [String: [ProviderHint]]
    ) -> [ProviderHint] {
        let sources = random.shuffled(responses.keys.sorted())
        var indices = Dictionary(uniqueKeysWithValues: sources.map { ($0, 0) })
        var selectedPeers: Set<PeerID> = []
        var peers: [PeerID] = []

        while selectedPeers.count < config.kBucketSize {
            var madeProgress = false
            for source in sources {
                let hints = responses[source] ?? []
                var index = indices[source] ?? 0
                while index < hints.count {
                    let hint = hints[index]
                    index += 1
                    if selectedPeers.insert(hint.peer).inserted {
                        peers.append(hint.peer)
                        madeProgress = true
                        break
                    }
                }
                indices[source] = index
                if selectedPeers.count == config.kBucketSize { break }
            }
            if !madeProgress { break }
        }

        var selected: [ProviderHint] = []
        var seenEndpoints: Set<PeerEndpoint> = []
        for routeIndex in 0..<config.maxRoutesPerIdentity {
            for peer in peers {
                for source in sources {
                    let routes = (responses[source] ?? []).filter { $0.peer == peer }
                    guard routes.indices.contains(routeIndex),
                          selected.lazy.filter({ $0.peer == peer }).count
                            < config.maxRoutesPerIdentity else { continue }
                    let hint = routes[routeIndex]
                    guard let endpoint = hint.endpoint,
                          seenEndpoints.insert(endpoint).inserted else { continue }
                    selected.append(hint)
                }
            }
        }
        return selected
    }

    mutating func forgetProvider(rootCID: String, peer: PeerID) {
        guard var hints = providerHints[rootCID] else { return }
        hints.removeAll { $0.peer == peer }
        setProviderHints(hints, rootCID: rootCID)
    }

    /// The connected peers a fetch asks for `rootCID`: those with a stored
    /// record, then those in `fresh`. A lookup's answer is used by the fetch
    /// that made it; storing it is only a cache.
    mutating func connectedProviderIDs(
        for rootCID: String,
        including fresh: [PeerEndpoint] = []
    ) -> [PeerID] {
        evictExpiredProviders(rootCID: rootCID)
        var seen: Set<PeerID> = []
        let peers = (providerHints[rootCID] ?? []).map(\.peer)
            + fresh.map { PeerID(publicKey: $0.publicKey) }
        return peers.filter { peer in
            hasEndpointSession(peer)
                && !isDeficiencySuppressed(rootCID: rootCID, peer: peer)
                && seen.insert(peer).inserted
        }
    }

    mutating func evictExpiredProviders(rootCID: String) {
        guard var hints = providerHints[rootCID] else { return }
        let now = nowUnix()
        hints.removeAll { $0.expiresAt <= now }
        setProviderHints(hints, rootCID: rootCID)
    }

    func shouldStoreProviderHint(rootCID: String) -> Bool {
        let keyHash = Router.hash(rootCID)
        let peers = router.allPeers()
        guard peers.count >= config.kBucketSize,
              let farthest = router.closestPeers(to: keyHash, count: config.kBucketSize).last else {
            return true
        }
        return Router.isCloser(router.localHash, than: farthest.hash, to: keyHash)
    }

    func providerExpiryIsValid(_ expiresAt: UInt64) -> Bool {
        let now = nowUnix()
        let (ceiling, overflow) = now.addingReportingOverflow(config.maxProviderTTLSeconds)
        return expiresAt > now && (overflow || expiresAt <= ceiling)
    }

    func localProviderEndpoint() -> PeerEndpoint? {
        guard let address = advertisedListenAddresses(observedLocalHost: nil).first else { return nil }
        return PeerEndpoint(publicKey: localKey.hex, host: address.host, port: address.port)
    }

    func providerEndpoint(for peer: PeerID) -> PeerEndpoint? {
        guard let endpoint = endpointLink(for: peer)?.endpoint,
              !endpoint.host.isEmpty,
              endpoint.host != "unknown",
              endpoint.port != 0 else { return nil }
        return endpoint
    }

    func nowUnix() -> UInt64 {
        now.unixSeconds
    }
}
