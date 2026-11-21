import Crypto
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
    /// The web addresses a referral carried. A record a provider gave for
    /// itself holds none: its provider's latest are kept once, in
    /// `announcerWebAddresses`. Part of a route's identity, so a referral
    /// naming a known endpoint with other addresses sits beside it.
    var webAddresses: [WebAddress] = []
}

/// One provider search for a root, shared by every search asking for it.
/// The root's `findNode` walk asks each peer it queries for providers as
/// well, so the answers arrive along the walk.
struct PendingProviderQuery: Sendable {
    let requestID: UInt64
    var waiters: [OpID]
    var expectedPeers: Set<String>
    var responsesByPeer: [String: [ProviderHint]]
    /// Set while the root's walk is still running.
    var walking = true
}

enum ProviderSearchWaiter: Sendable, Equatable {
    case request(RequestID, cached: [DiscoveredProvider], withAddresses: Bool = false)
    case volumeFetch(OpID)
}

/// A fresh provider lookup: one iterative walk toward the root that asks
/// every peer it queries for both closer peers and providers.
struct ProviderSearch: Sendable {
    let rootCID: String
    let waiter: ProviderSearchWaiter
}

extension IvyCore {
    // MARK: - Searching

    mutating func discoverProviders(_ request: RequestID, rootCID: String, withAddresses: Bool) {
        guard config.mode.usesOverlayServices, MessageLimits.accepts(rootCID) else {
            return complete(request, withAddresses ? .providers([]) : .endpoints([]))
        }
        // This node's own record is no answer: a provider looking up a root it
        // provides is looking for the others, so its record neither returns
        // nor stands in for the network's answer.
        let cached = cachedProviders(rootCID: rootCID).filter { $0.endpoint.publicKey != localKey.hex }
        // Nor is a record naming a peer already connected: it tells the
        // caller of no one new, so only a record naming a peer this node has
        // no session with answers without asking the network.
        guard !cached.contains(where: { !hasEndpointSession(PeerID(publicKey: $0.endpoint.publicKey)) }) else {
            return complete(request, withAddresses
                ? .providers(cached)
                : .endpoints(uniqueProviderEndpoints(cached.map(\.endpoint))))
        }
        startProviderSearch(
            rootCID: rootCID,
            waiter: .request(request, cached: cached, withAddresses: withAddresses))
    }

    /// Asks the network who provides `rootCID`. The waiter always hears,
    /// possibly before this returns.
    @discardableResult
    mutating func startProviderSearch(rootCID: String, waiter: ProviderSearchWaiter) -> OpID {
        let id = makeID()
        providerSearches[id] = ProviderSearch(rootCID: rootCID, waiter: waiter)
        if case .request(let request, _, _) = waiter { requests[request] = .providerSearch(id) }
        guard config.mode.usesOverlayServices, isRunning, MessageLimits.accepts(rootCID) else {
            finishProviderSearch(id, [])
            return id
        }
        freshProviderQueryCount += 1
        if var pending = pendingProviderQueries[rootCID] {
            guard pending.waiters.count < config.maxWaitersPerRequest else {
                finishProviderSearch(id, [])
                return id
            }
            pending.waiters.append(id)
            pendingProviderQueries[rootCID] = pending
            return id
        }
        guard pendingProviderQueries.count < config.maxPendingRequests else {
            finishProviderSearch(id, [])
            return id
        }
        let requestID = makeWireOperationID(
            avoiding: Set(pendingProviderQueries.values.map(\.requestID)))
        pendingProviderQueries[rootCID] = PendingProviderQuery(
            requestID: requestID, waiters: [id], expectedPeers: [], responsesByPeer: [:])
        let lookup = startLookup(
            target: rootCID, waiter: .providerSearch(rootCID: rootCID, requestID: requestID))
        if lookups[lookup] != nil, pendingProviderQueries[rootCID]?.requestID == requestID {
            providerLookups[rootCID] = lookup
        }
        return id
    }

    /// The root's walk asked `peer` for closer peers: ask it for providers too.
    mutating func askForProviders(rootCID: String, peer: PeerID) {
        let key = peer.publicKey
        guard var pending = pendingProviderQueries[rootCID], pending.walking,
              !pending.expectedPeers.contains(key), pending.responsesByPeer[key] == nil,
              case .enqueued = fireToPeer(
                peer, .findProviders(rootCID: rootCID, requestID: pending.requestID)) else { return }
        pending.expectedPeers.insert(key)
        pendingProviderQueries[rootCID] = pending
    }

    /// The root's walk ended. The search ends once the peers it asked have
    /// answered, or after one response timeout. A walk for a round already
    /// over touches nothing of the round after it.
    mutating func providerSearchLookupFinished(rootCID: String, requestID: UInt64) {
        guard var pending = pendingProviderQueries[rootCID], pending.requestID == requestID,
              pending.walking else { return }
        providerLookups.removeValue(forKey: rootCID)
        pending.walking = false
        pendingProviderQueries[rootCID] = pending
        guard isRunning, !pending.expectedPeers.isEmpty else {
            return resolveProviderQuery(rootCID: rootCID, requestID: pending.requestID)
        }
        timers.set(.providerQuery(rootCID), at: now.uptime + Self.lookupResponseTimeout)
    }

    mutating func resolveProviderQuery(rootCID: String, requestID: UInt64) {
        guard let pending = pendingProviderQueries[rootCID],
              pending.requestID == requestID else { return }
        pendingProviderQueries.removeValue(forKey: rootCID)
        timers.cancel(.providerQuery(rootCID))
        // A search ended by its last waiter or by `stop` ends its walk.
        if let lookup = providerLookups.removeValue(forKey: rootCID) {
            finishLookup(lookup, cancelled: true)
        }
        let hints = diversifiedProviderHints(pending.responsesByPeer)
        for hint in hints {
            storeProviderHint(
                rootCID: rootCID,
                peer: hint.peer,
                endpoint: hint.endpoint,
                expiresAt: hint.expiresAt,
                source: hint.source,
                webAddresses: hint.webAddresses)
        }
        let providers = hints.compactMap { hint in
            hint.endpoint.map { DiscoveredProvider(endpoint: $0, webAddresses: hint.webAddresses) }
        }
        for waiter in pending.waiters { finishProviderSearch(waiter, providers) }
    }

    /// Ends a search and tells its waiter. Ending the last search for a
    /// root ends its walk and its round.
    mutating func finishProviderSearch(_ id: OpID, _ providers: [DiscoveredProvider]) {
        guard let search = providerSearches.removeValue(forKey: id) else { return }
        if var pending = pendingProviderQueries[search.rootCID],
           let index = pending.waiters.firstIndex(of: id) {
            pending.waiters.remove(at: index)
            if pending.waiters.isEmpty {
                pendingProviderQueries.removeValue(forKey: search.rootCID)
                timers.cancel(.providerQuery(search.rootCID))
                if let lookup = providerLookups.removeValue(forKey: search.rootCID) {
                    finishLookup(lookup, cancelled: true)
                }
            } else {
                pendingProviderQueries[search.rootCID] = pending
            }
        }
        switch search.waiter {
        case .request(let request, let cached, let withAddresses):
            let found = uniqueProviders(cached + providers)
            complete(request, withAddresses
                ? .providers(found)
                : .endpoints(uniqueProviderEndpoints(found.map(\.endpoint))))
        case .volumeFetch(let fetch):
            volumeFetchProviderSearchFinished(
                fetch, search: id, endpoints: providers.map(\.endpoint))
        }
    }

    // MARK: - Records

    mutating func handleFindProviders(rootCID: String, requestID: UInt64, from peer: PeerID) {
        guard config.mode.usesOverlayServices else { return }
        evictExpiredProviders(rootCID: rootCID)
        let hints = providerHints[rootCID] ?? []
        // Only a peer that has sent `webAddresses` knows the answer with them.
        guard let session = endpointSession(for: peer), session.webAddresses != nil else {
            fireToPeer(peer, .providers(
                rootCID: rootCID, requestID: requestID, records: providerRecordsForWire(hints)))
            return
        }
        fireToPeer(peer, .providersWithAddresses(
            rootCID: rootCID,
            requestID: requestID,
            records: fittingProviderRecords(
                providerRecordsForWire(hints, withAddresses: true), rootCID: rootCID, link: session.link)))
    }

    /// `records` cut to fit one `providersWithAddresses` on `link`: the last
    /// records lose their addresses first, then the last records go.
    private func fittingProviderRecords(
        _ records: [ProviderRecord], rootCID: String, link: LinkID
    ) -> [ProviderRecord] {
        let relayed = links[link]?.isDirect == false
        let budget = Int(clamping: effectiveOutboundFrameSize(for: link))
            - SessionWireRecord.dataRecordOverhead
            - (relayed ? Message.relayPacketEnvelopeOverhead + SessionWireRecord.dataRecordOverhead : 0)
            - (1 + 2 + rootCID.utf8.count + 2 + 8)
        func size(_ record: ProviderRecord) -> Int {
            2 + record.endpoint.publicKey.utf8.count + 2 + record.endpoint.host.utf8.count + 2 + 8 + 2
                + record.webAddresses.reduce(0) { $0 + 2 + $1.url.utf8.count + 1 + ($1.via == nil ? 0 : 32) }
        }
        var fitted = records
        var total = fitted.reduce(0) { $0 + size($1) }
        for index in fitted.indices.reversed() where total > budget {
            total -= size(fitted[index])
            fitted[index].webAddresses = []
            total += size(fitted[index])
        }
        while total > budget, let last = fitted.popLast() { total -= size(last) }
        // Routes that differed only in the addresses dropped are one route.
        var seen: Set<DiscoveredProvider> = []
        return fitted.filter {
            seen.insert(DiscoveredProvider(endpoint: $0.endpoint, webAddresses: $0.webAddresses)).inserted
        }
    }

    /// At most `maxNeighborCount` records, every identity's first route
    /// before any identity's second, the identities in a fresh random order:
    /// a key with more providers than one answer holds names a different
    /// sample to each asker, so none is named to every asker, and a key
    /// cannot be held by grinding identities that sort first.
    /// Without addresses, routes that differ only in them are one route:
    /// the first of each endpoint.
    mutating func providerRecordsForWire(
        _ hints: [ProviderHint], withAddresses: Bool = false
    ) -> [ProviderRecord] {
        var seen: Set<PeerEndpoint> = []
        let records = hints.compactMap { hint -> ProviderRecord? in
            guard let endpoint = hint.endpoint,
                  withAddresses || seen.insert(endpoint).inserted else { return nil }
            return ProviderRecord(
                endpoint: endpoint,
                expiresAt: hint.expiresAt,
                webAddresses: withAddresses ? providerWebAddresses(hint) : [])
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
            // A record naming the peer that answers is its own advertisement,
            // as when it announces: a private address it is seen from holds.
            let names = (try? PeerKey(endpoint.publicKey))?.hex == peer.publicKey
            guard providerExpiryIsValid(record.expiresAt),
                  isAcceptableDiscoveredEndpoint(
                    endpoint,
                    provenance: names ? .selfAdvertisement : .referral("provider"),
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
                source: peer,
                webAddresses: record.webAddresses))
        }

        pending.responsesByPeer[peer.publicKey] = boundedProviderHints(accepted, rootCID: rootCID)
        pendingProviderQueries[rootCID] = pending
        if pending.expectedPeers.isEmpty, !pending.walking {
            resolveProviderQuery(rootCID: rootCID, requestID: requestID)
        }
    }

    mutating func handleAnnounceProvider(rootCID: String, expiresAt: UInt64, from peer: PeerID) {
        guard config.mode.usesOverlayServices,
              providerExpiryIsValid(expiresAt) else { return }
        // The announcer chose this node as one of the root's closest; the
        // per-source quota and the table ceiling bound what it may place.
        storeProviderHint(
            rootCID: rootCID,
            peer: peer,
            endpoint: providerEndpoint(for: peer),
            expiresAt: expiresAt,
            source: peer,
            webAddresses: endpointSession(for: peer)?.webAddresses ?? [])
    }

    /// The addresses a record is answered with: a provider's own record
    /// carries its latest, a referral what it was referred with.
    func providerWebAddresses(_ hint: ProviderHint) -> [WebAddress] {
        guard hint.source == hint.peer else { return hint.webAddresses }
        return hint.peer == localID ? localWebAddresses : announcerWebAddresses[hint.peer] ?? []
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
        guard isRunning else { return }
        // A walk already running for the root announces the newest expiry.
        let walking = announceWalks[rootCID] != nil
        announceWalks[rootCID] = expiresAt
        if !walking { startLookup(target: rootCID, waiter: .announce(rootCID: rootCID)) }
    }

    /// The root's walk ended: the closest peers that answered are told. With
    /// none, the closest peers already connected are, so an announcement is
    /// never dropped while this node has anyone to tell.
    mutating func announceLookupFinished(rootCID: String, closest: [PeerEndpoint]) {
        guard let expiresAt = announceWalks.removeValue(forKey: rootCID), isRunning else { return }
        var targets = closest.prefix(config.kBucketSize)
            .map { PeerID(publicKey: $0.publicKey) }
            .filter(hasEndpointSession)
        if targets.isEmpty {
            targets = router.closestPeers(to: Router.hash(rootCID), count: config.kBucketSize)
                .map(\.id)
                .filter(hasEndpointSession)
        }
        let message = Message.announceProvider(rootCID: rootCID, expiresAt: expiresAt)
        for peer in targets { fireToPeer(peer, message) }
    }

    public func isProviderWalkSession(_ peer: AuthenticatedPeer) -> Bool {
        providerWalkSessions[peer.key] == peer.sessionID
    }

    /// Replaces this node's declared web addresses.
    mutating func setWebAddresses(_ addresses: [WebAddress]) {
        guard WebAddress.isValidList(addresses) else { return }
        declaredWebAddresses = addresses
        refreshWebAddresses(immediately: true)
    }

    mutating func setAutoRelay(_ enabled: Bool) {
        autoRelay = enabled
        refreshWebAddresses(immediately: true)
    }

    /// The least time between two re-advertisements other peers' changes
    /// cause: a relay that flaps does not make this node flood its sessions.
    static let webAddressesInterval: Duration = .seconds(10)

    /// Recomputes what this node advertises: its declared addresses, or with
    /// none and auto relay on, relays it can be reached through. On a change
    /// every session is told, and this node's own records carry the new set.
    /// A change other peers caused waits out `webAddressesInterval` since the
    /// last, then the state at that time is sent. True when sessions were told.
    @discardableResult
    mutating func refreshWebAddresses(immediately: Bool = false) -> Bool {
        let addresses = !declaredWebAddresses.isEmpty ? declaredWebAddresses
            : autoRelay ? autoRelayAddresses() : []
        guard addresses != localWebAddresses else { return false }
        guard isRunning else {
            localWebAddresses = addresses
            return false
        }
        if !immediately, let last = webAddressesSentAt,
           now.uptime < last + Self.webAddressesInterval {
            if !timers.isSet(.webAddresses) {
                timers.set(.webAddresses, at: last + Self.webAddressesInterval)
            }
            return false
        }
        localWebAddresses = addresses
        webAddressesSentAt = now.uptime
        for key in sessions.keys.sorted() {
            if let ref = sessions[key]?.ref { sendWebAddresses(on: ref) }
        }
        return true
    }

    /// Up to `WebAddress.maxCount` relays, as libp2p's AutoRelay picks them:
    /// direct sessions the application says relay that advertise an address
    /// of their own, each reached at its first. Choices are kept while they
    /// stay candidates; vacancies go by a hash of both keys, so no key can
    /// be ground to be every node's relay, and nodes spread over relays.
    private func autoRelayAddresses() -> [WebAddress] {
        var urls: [PeerKey: String] = [:]
        for key in relayingPeers {
            guard let session = endpointSession(for: key), links[session.link]?.isDirect == true,
                  let url = session.webAddresses?.first(where: { $0.via == nil })?.url else { continue }
            urls[key] = url
        }
        // Only half the slots are kept, by the first relays in the current
        // list: the rest
        // always go by rank, so relays that hold on cannot fill them all.
        var chosen = Array(localWebAddresses.compactMap(\.via).filter { urls[$0] != nil }
            .prefix(WebAddress.maxCount / 2))
        let rank = { (key: PeerKey) in
            Array(SHA256.hash(data: self.localKey.rawRepresentation + key.rawRepresentation))
        }
        let ranked = urls.keys.filter { !chosen.contains($0) }
            .map { (key: $0, rank: rank($0)) }
            .sorted { $0.rank.lexicographicallyPrecedes($1.rank) }
        chosen += ranked.prefix(WebAddress.maxCount - chosen.count).map(\.key)
        return chosen.prefix(WebAddress.maxCount).compactMap { key in
            urls[key].map { WebAddress(url: $0, via: key) }
        }
    }

    /// Stops announcing `rootCID`: drops this node's own record of it and
    /// any announcement its walk has not sent yet. Records already sent stay
    /// on their holders until they expire; the wire has no withdrawal.
    mutating func stopProviding(rootCID: String) {
        announceWalks.removeValue(forKey: rootCID)
        guard let hints = providerHints[rootCID] else { return }
        setProviderHints(hints.filter { $0.source != localID }, rootCID: rootCID)
    }

    mutating func cachedProviderEndpoints(rootCID: String) -> [PeerEndpoint] {
        uniqueProviderEndpoints(cachedProviders(rootCID: rootCID).map(\.endpoint))
    }

    mutating func cachedProviders(rootCID: String) -> [DiscoveredProvider] {
        evictExpiredProviders(rootCID: rootCID)
        return uniqueProviders((providerHints[rootCID] ?? []).compactMap { hint in
            hint.endpoint.map { DiscoveredProvider(endpoint: $0, webAddresses: providerWebAddresses(hint)) }
        })
    }

    /// The first of each route: an endpoint with its addresses.
    func uniqueProviders(_ providers: [DiscoveredProvider]) -> [DiscoveredProvider] {
        var seen: Set<DiscoveredProvider> = []
        return providers.filter { seen.insert($0).inserted }
    }

    func uniqueProviderEndpoints(_ endpoints: [PeerEndpoint]) -> [PeerEndpoint] {
        var seen: Set<PeerEndpoint> = []
        return endpoints.filter { seen.insert($0).inserted }
    }

    mutating func storeProviderHint(
        rootCID: String,
        peer: PeerID,
        endpoint: PeerEndpoint?,
        expiresAt: UInt64,
        source: PeerID? = nil,
        webAddresses: [WebAddress] = []
    ) {
        let source = source ?? peer
        // A provider's own record reads its provider's latest addresses,
        // kept once below; only a referral holds its own.
        let hint = ProviderHint(
            peer: peer,
            endpoint: endpoint,
            expiresAt: expiresAt,
            source: source,
            webAddresses: source == peer ? [] : webAddresses)
        defer {
            if source == peer, peer != localID, providerRecordCounts[peer] != nil {
                announcerWebAddresses[peer] = webAddresses
            }
        }
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
        let old = providerHints[rootCID] ?? []
        for hint in old where hint.source != localID {
            countProviderRecord(source: hint.source, rootCID: rootCID, delta: -1)
        }
        for hint in hints where hint.source != localID {
            countProviderRecord(source: hint.source, rootCID: rootCID, delta: 1)
        }
        providerHints[rootCID] = hints.isEmpty ? nil : hints
        // A peer's addresses go with its last record.
        for hint in old where providerRecordCounts[hint.source] == nil {
            announcerWebAddresses[hint.source] = nil
        }
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
            routes.removeAll { $0.endpoint == hint.endpoint && $0.webAddresses == hint.webAddresses }
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
        var seenRoutes: Set<DiscoveredProvider> = []
        for routeIndex in 0..<config.maxRoutesPerIdentity {
            for peer in peers {
                for source in sources {
                    let routes = (responses[source] ?? []).filter { $0.peer == peer }
                    guard routes.indices.contains(routeIndex),
                          selected.lazy.filter({ $0.peer == peer }).count
                            < config.maxRoutesPerIdentity else { continue }
                    let hint = routes[routeIndex]
                    guard let endpoint = hint.endpoint,
                          seenRoutes.insert(DiscoveredProvider(
                            endpoint: endpoint, webAddresses: hint.webAddresses)).inserted else { continue }
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
