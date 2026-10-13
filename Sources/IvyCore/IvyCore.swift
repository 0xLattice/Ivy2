#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Tally

typealias LinkID = UInt64
typealias OpID = UInt64

/// Ivy as one value. Bytes, time and application requests go in as events;
/// everything Ivy wants done comes out as effects. Nothing in here waits,
/// reads a clock, opens a socket or starts a task, so the same events always
/// give the same effects.
public struct IvyCore: Sendable {
    public let config: IvyConfig
    public let localID: PeerID
    let localKey: PeerKey

    var scheme: any IvySignatureScheme
    var ledger: any PeerLedger
    var random: CoreRandom

    var now = Timestamp(uptime: .zero, unixSeconds: 0)
    var effects: [Effect] = []
    var timers = TimerTable()
    var lastWake: Duration?
    var nextIdentifier: UInt64 = 0

    public internal(set) var isRunning = false
    public internal(set) var publicAddress: ObservedAddress?
    var hasContentSource = false
    /// Connected endpoints the application says relay. A peer that does not
    /// relay ends the session of one that asks it to, so only these are asked.
    var relayingPeers: Set<PeerKey> = []
    var router: Router

    // MARK: Links and sessions

    var links: [LinkID: Link] = [:]
    var linkByConnection: [ConnectionID: LinkID] = [:]
    var inboundBytesUsed = 0
    /// Links whose decoding stopped on the node-wide byte budget.
    var budgetWaiters: Set<LinkID> = []
    var pumpQueue: [LinkID] = []
    /// Handshake outcomes owed to connect operations, applied once the
    /// record that produced them has been fully handled.
    var authResults: [(op: OpID, authenticated: Bool)] = []
    var responderResults: [(op: OpID, connected: Bool)] = []
    /// Peers whose session ended while a verified handshake from them was
    /// still arriving: the disconnect waits to see whether that takes over.
    var heldDisconnects: Set<PeerKey> = []
    /// Connect operations waiting on another attempt to reach the same
    /// peer, and the peers whose attempts may just have ended.
    var connectFollowers: [PeerKey: [OpID]] = [:]
    var followerChecks: Set<PeerKey> = []
    var deliveries: [DeliveryToken: Delivery] = [:]
    var writabilityWaiters: [LinkID: [WritabilityWaiter]] = [:]

    var pendingSessions: [LinkID: PendingSession] = [:]
    var sessions: [PeerKey: Session] = [:]
    var sessionKeyByLink: [LinkID: PeerKey] = [:]
    var health: [PeerID: PeerHealth] = [:]

    // MARK: Connecting

    var connectOps: [OpID: ConnectOp] = [:]
    var connectGroups: [OpID: ConnectGroup] = [:]
    var outgoingDials: [PeerID: OutgoingDial] = [:]
    var dialPeers: [DialID: PeerID] = [:]
    /// Operations waiting for a verified inbound handshake to finish.
    var responderWaiters: [PeerKey: OpID] = [:]
    var reconnectAttempts: [PeerID: Int] = [:]
    var reconnectScheduled: [PeerID: AuthenticatedPeerRole] = [:]
    var reconnectSuppressed: Set<PeerID> = []
    var requests: [RequestID: RequestBinding] = [:]

    // MARK: Relay

    var relayRoutes: [Data: RelayRoute] = [:]
    var installedRoutes: [Data: InstalledRoute] = [:]
    var pendingRelayOpens: [Data: PendingRelayOpen] = [:]

    // MARK: Routing and provider records

    var lookups: [OpID: NodeLookup] = [:]
    var pendingNeighborResponses: [UInt64: PendingNeighborResponse] = [:]
    var nextWireOperationID: UInt64 = 0

    var providerHints: [String: [ProviderHint]] = [:]
    /// Per remote source: roots holding its provider records, and how many.
    var providerRecordsBySource: [PeerID: [String: Int]] = [:]
    var providerRecordCounts: [PeerID: Int] = [:]
    /// Remote sources grouped by record count, to find the heaviest without a scan.
    var providerSourcesByCount: [Int: Set<PeerID>] = [:]
    var providerRecordTotal = 0
    var pendingProviderQueries: [String: PendingProviderQuery] = [:]
    var providerSearches: [OpID: ProviderSearch] = [:]
    /// DHT provider lookups started, for tests that assert one was avoided.
    public internal(set) var freshProviderQueryCount = 0
    var deficientPeerSuppression: [String: [String: Duration]] = [:]

    // MARK: Fetching

    var pendingVolumeRequests: [UInt64: PendingVolumeRequest] = [:]
    var inFlightVolumeBytes = 0
    var reservedVolumeBytes = 0
    var volumeFetches: [OpID: VolumeFetch] = [:]
    /// This node's Volume requests in flight to each peer.
    var outstandingVolumeRequests: [PeerID: Int] = [:]
    /// Consecutive Volume requests each connected peer let time out; cleared
    /// when it serves one, dropped when it disconnects.
    var volumeTimeoutStreaks: [PeerID: Int] = [:]
    /// Volume fetches waiting for a peer below its in-flight limit, oldest first.
    var outstandingVolumeSlotWaiters: [OpID] = []
    var nextConnectedFallbackOffset = 0

    // MARK: Serving

    var jobs: [JobID: JobOwner] = [:]
    var serving: [InboundContentRequest: ServingRequest] = [:]
    /// Requests holding a serving slot.
    var servingContentRequests: Set<InboundContentRequest> = []
    /// Requests waiting for a serving slot; non-empty only under pressure.
    var servingTickets: [InboundContentRequest: UInt64] = [:]
    var nextServingTicketArrival: UInt64 = 0
    var waitingServingPeers: [PeerID: WaitingServingPeer] = [:]
    var servingVirtualTime: Double = 0
    var activeLocalContentRequestCount = 0
    var reservedServingVolumeBytes = 0
    /// Volume reads waiting for serving capacity, in arrival order. Reads are
    /// short and slots are already shared by weight, so reads go first come,
    /// first served: ranking them could starve a peer's read.
    var servingVolumeReadWaiters: [InboundContentRequest] = []

    static let directRouteBinding = Data(repeating: 0, count: 32)
    static let maxRelayRoutes = 64
    static let maxRelayRoutesPerPeer = 8
    /// Peers known to relay that one connect asks, after the carriers.
    static let maxRelayingPeersAsked = 4
    static let relayIdleTimeout: Duration = .seconds(300)
    static let pendingSessionTimeout: Duration = .seconds(30)
    static let reconnectBaseDelayMs: UInt64 = 500
    static let reconnectMaxDelayMs: UInt64 = 30_000
    static let reconnectJitterMs: UInt64 = 250
    static let kademliaLookupParallelism = 3
    static let lookupResponseTimeout: Duration = .milliseconds(500)
    static let routingRefreshInitialDelay: Duration = .seconds(30)
    /// Roots the locally reported deficiency table may hold; its entries come
    /// only from this node's own `reportDeficientContent` and expire on a fixed window.
    static let maxDeficiencySuppressionRoots = 10_000
    static let deficiencySuppressionWindow: Duration = .seconds(30)
    /// A relayed connection's records waiting behind the one being handled.
    static let maxInboundBufferedRecords = 4
    /// Bytes written since the last `writable` above which a connection
    /// takes no more, and so reports backpressure.
    public static let writeHighWaterMark = 64 * 1024

    public init(
        config: IvyConfig,
        scheme: (any IvySignatureScheme)? = nil,
        ledger: any PeerLedger = NullLedger(),
        random: CoreRandom = .system
    ) {
        self.config = config
        self.localID = PeerID(publicKey: config.publicKey)
        self.localKey = config.peerKey
        self.scheme = scheme ?? Ed25519Scheme(signingKey: config.signingKey)
        self.ledger = ledger
        self.random = random
        self.router = Router(localID: PeerID(publicKey: config.publicKey), k: config.kBucketSize)
    }

    // MARK: - The entry point

    /// Applies one event at `now` and returns what Ivy wants done, in order.
    public mutating func step(_ event: Event, now: Timestamp) -> [Effect] {
        self.now = Timestamp(
            uptime: max(now.uptime, self.now.uptime),
            unixSeconds: now.unixSeconds)

        switch event {
        case .start:
            start()
        case .stop:
            stop()
        case .tick:
            fireExpiredTimers()
        case let .connectionOpened(connection, direction, observedHost, localHost):
            connectionOpened(
                connection,
                direction: direction,
                observedHost: observedHost,
                localHost: localHost)
        case .dialFailed(let dial):
            dialFailed(dial)
        case .received(let connection, let bytes):
            received(bytes, on: connection)
        case .writable(let connection):
            transportBecameWritable(connection)
        case .closed(let connection):
            if let link = linkByConnection[connection] { removeLink(link, notifyTransport: false) }
        case .request(let id, let request):
            handleRequest(id, request)
        case .cancel(let id):
            cancelRequest(id)
        case .command(let command):
            handleCommand(command)
        case .delivered(let token):
            delivered(token)
        case .jobFinished(let job, let result):
            jobFinished(job, result)
        case .publicAddress(let address):
            guard isRunning, publicAddress == nil, let address else { break }
            publicAddress = address
            emit(.publicAddressDiscovered(address))
        }

        while !pumpQueue.isEmpty || !authResults.isEmpty || !responderResults.isEmpty
                || !followerChecks.isEmpty {
            drainPumps()
            let responders = responderResults
            responderResults.removeAll()
            for result in responders { responderFinished(result.op, connected: result.connected) }
            let handshakes = authResults
            authResults.removeAll()
            for result in handshakes {
                authenticationFinished(result.op, authenticated: result.authenticated)
            }
            let peers = followerChecks.sorted()
            followerChecks.removeAll()
            for peer in peers { settleFollowers(of: peer) }
        }
        if let earliest = timers.earliest, earliest != lastWake {
            lastWake = earliest
            effects.append(.wakeAt(earliest))
        } else if timers.earliest == nil {
            lastWake = nil
        }
        let produced = effects
        effects.removeAll(keepingCapacity: true)
        return produced
    }

    mutating func emit(_ effect: Effect) {
        effects.append(effect)
    }

    mutating func makeID() -> UInt64 {
        nextIdentifier &+= 1
        return nextIdentifier
    }

    mutating func complete(_ request: RequestID, _ result: RequestResult) {
        requests.removeValue(forKey: request)
        emit(.completed(request, result))
    }

    // MARK: - Lifecycle

    private mutating func start() {
        guard !isRunning, (try? config.validate()) != nil else { return }
        isRunning = true
        publicAddress = nil
        reconnectSuppressed.removeAll()
        nextConnectedFallbackOffset = 0

        if config.healthConfig.enabled {
            timers.set(.health, at: now.uptime + config.healthConfig.keepaliveInterval)
        }
        if let externalAddress = config.externalAddress {
            let address = ObservedAddress(host: externalAddress.host, port: externalAddress.port)
            publicAddress = address
            emit(.publicAddressDiscovered(address))
        } else if !config.stunServers.isEmpty {
            emit(.discoverPublicAddress)
        }
        for peer in configuredPeerKeys(role: .endpoint) {
            maintainConfiguredConnection(peer: peer, role: .endpoint)
        }
        for peer in configuredPeerKeys(role: .carrier) {
            maintainConfiguredConnection(peer: peer, role: .carrier)
        }
        if config.mode.participatesInPublicDiscovery {
            timers.set(.routingRefresh, at: now.uptime + Self.routingRefreshInitialDelay)
        }
    }

    /// Ends the run. Every request is answered, every connection closed and
    /// every deadline dropped; nothing from this run can act on the next.
    /// Sessions end without `peerDisconnected`, as the application asked for it.
    private mutating func stop() {
        isRunning = false
        timers.removeAll()

        failAllServing()
        for id in volumeFetches.keys.sorted() { finishVolumeFetch(id, .empty) }
        for id in pendingVolumeRequests.keys.sorted() { resolveVolumeRequest(requestID: id) }
        for id in lookups.keys.sorted() { finishLookup(id, cancelled: true) }
        for id in providerSearches.keys.sorted() { finishProviderSearch(id, []) }
        pendingProviderQueries.removeAll()
        for id in connectGroups.keys.sorted() { connectGroups.removeValue(forKey: id) }
        for id in connectOps.keys.sorted() { finishConnectOp(id, .cancelled) }
        for (request, binding) in requests.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if case .writable = binding { complete(request, .writable(false)) }
        }
        requests.removeAll()
        pendingNeighborResponses.removeAll()
        outstandingVolumeSlotWaiters.removeAll()
        outstandingVolumeRequests.removeAll()
        inFlightVolumeBytes = 0
        reservedVolumeBytes = 0

        pendingSessions.removeAll()
        sessions.removeAll()
        sessionKeyByLink.removeAll()
        health.removeAll()
        deliveries.removeAll()
        writabilityWaiters.removeAll()
        relayRoutes.removeAll()
        installedRoutes.removeAll()
        pendingRelayOpens.removeAll()
        responderWaiters.removeAll()
        reconnectScheduled.removeAll()
        connectFollowers.removeAll()
        followerChecks.removeAll()
        heldDisconnects.removeAll()
        reconnectAttempts.removeAll()
        // A dial in flight keeps its entry so its connection, when the shell
        // reports it, is recognised and closed.
        for peer in Array(outgoingDials.keys) {
            if outgoingDials[peer]?.link != nil {
                outgoingDials.removeValue(forKey: peer)
            } else {
                outgoingDials[peer]?.abandoned = true
            }
        }
        dialPeers = dialPeers.filter { outgoingDials[$0.value] != nil }

        for id in links.keys.sorted() {
            if case .direct(let connection) = links[id]?.transport { emit(.close(connection)) }
        }
        links.removeAll()
        linkByConnection.removeAll()
        budgetWaiters.removeAll()
        pumpQueue.removeAll()
        authResults.removeAll()
        responderResults.removeAll()
        inboundBytesUsed = 0
    }

    // MARK: - Timers

    private mutating func fireExpiredTimers() {
        // Stopping drops every deadline of the run, so whatever is due here
        // is current.
        for kind in timers.popExpired(at: now.uptime) {
            switch kind {
            case .health:
                runHealthCycle()
            case .routingRefresh:
                refreshRoutingTable()
            case .pendingSession(let link):
                failPendingSession(link)
            case .reconnect(let peer):
                runScheduledReconnect(peer)
            case .relayOpen(let routeID):
                timeoutRelayOpen(routeID)
            case .relayRoute(let routeID):
                relayRouteTimerFired(routeID)
            case .installedRoute(let routeID):
                expireIdleInstalledRoute(routeID)
            case .relayForward(let link):
                relayForwardTimedOut(link)
            case .neighbor(let nonce):
                resolveNeighborResponse(nonce: nonce, endpoints: [])
            case .providerQuery(let rootCID):
                if let pending = pendingProviderQueries[rootCID] {
                    resolveProviderQuery(rootCID: rootCID, requestID: pending.requestID)
                }
            case .volumeRequest(let requestID):
                timeOutVolumeRequest(requestID: requestID)
            case .volumeWritable(let fetch):
                volumeFetchBecameWritable(fetch, writable: false)
            case .serving(let request):
                servingTimedOut(request)
            }
        }
    }

    // MARK: - Application input

    private mutating func handleRequest(_ id: RequestID, _ request: Request) {
        guard requests[id] == nil else { return }
        switch request {
        case .connect(let endpoint):
            guard let key = try? PeerKey(endpoint.publicKey) else {
                return complete(id, .connect(.failed(.invalidPeerKey)))
            }
            reconnectSuppressed.remove(key.peerID)
            startConnect(to: [endpoint], role: .endpoint, relayOnly: false, waiter: .request(id))
        case let .connectOver(endpoint, connection, observedHost, localHost):
            guard linkByConnection[connection] == nil else {
                return complete(id, .connect(.failed(.connectionInProgress)))
            }
            guard let key = try? PeerKey(endpoint.publicKey) else {
                emit(.close(connection))
                return complete(id, .connect(.failed(.invalidPeerKey)))
            }
            reconnectSuppressed.remove(key.peerID)
            startConnect(
                to: [endpoint],
                role: .endpoint,
                relayOnly: false,
                waiter: .request(id),
                over: SuppliedConnection(
                    connection: connection, observedHost: observedHost, localHost: localHost))
        case .connectViaRelay(let endpoint):
            guard let key = try? PeerKey(endpoint.publicKey) else {
                return complete(id, .connect(.failed(.invalidPeerKey)))
            }
            reconnectSuppressed.remove(key.peerID)
            startConnect(to: [endpoint], role: .endpoint, relayOnly: true, waiter: .request(id))
        case let .send(peer, topic, payload):
            complete(id, .send(enqueueEndpoint(.peerMessage(topic: topic, payload: payload), to: peer)))
        case let .sendOnSession(peer, topic, payload):
            guard let session = endpointSession(for: peer.key),
                  session.sessionID.bytes == peer.sessionID else {
                return complete(id, .send(.notConnected))
            }
            complete(id, .send(enqueue(.peerMessage(topic: topic, payload: payload), on: session.ref)))
        case .waitUntilWritable(let peer):
            guard let key = try? PeerKey(peer.publicKey),
                  let session = endpointSession(for: key) else {
                return complete(id, .writable(false))
            }
            waitUntilWritable(session.link, for: id)
        case .waitUntilSessionWritable(let peer):
            guard let session = endpointSession(for: peer.key),
                  session.sessionID.bytes == peer.sessionID else {
                return complete(id, .writable(false))
            }
            waitUntilWritable(session.link, for: id)
        case let .fetchVolume(rootCID, maximumArchiveBytes, maximumEntries):
            fetchVolume(
                id,
                rootCID: rootCID,
                maximumArchiveBytes: maximumArchiveBytes,
                maximumEntries: maximumEntries)
        case let .fetchVolumeFrom(peer, rootCID, maximumArchiveBytes, maximumEntries):
            fetchVolume(
                id,
                rootCID: rootCID,
                from: peer,
                maximumArchiveBytes: maximumArchiveBytes,
                maximumEntries: maximumEntries)
        case let .fetchVolumeBundle(rootCID, peers):
            fetchVolumeBundle(id, rootCID: rootCID, from: peers)
        case .findNode(let target):
            guard config.mode.usesOverlayServices, isRunning else {
                return complete(id, .endpoints([]))
            }
            startLookup(target: target, waiter: .request(id))
        case .discoverProviders(let rootCID):
            discoverProviders(id, rootCID: rootCID)
        case .recycleSession(let peer):
            complete(id, .flag(recycleSession(ifCurrent: peer)))
        case .disconnectSession(let peer):
            complete(id, .flag(disconnectSession(ifCurrent: peer)))
        }
    }

    private mutating func cancelRequest(_ id: RequestID) {
        guard let binding = requests[id] else { return }
        switch binding {
        case .connect(let op):
            cancelConnectOp(op)
        case .writable:
            removeWritabilityWaiter(.request(id))
            complete(id, .writable(false))
        case .volumeFetch(let op):
            finishVolumeFetch(op, .empty)
        case .lookup(let op):
            finishLookup(op, cancelled: true)
        case .providerSearch(let op):
            finishProviderSearch(op, [])
        }
    }

    private mutating func handleCommand(_ command: Command) {
        switch command {
        case .disconnect(let peer):
            disconnect(peer)
        case .restartConfiguredSession(let peer):
            guard let key = try? PeerKey(peer.publicKey),
                  let session = sessions[key],
                  !configuredEndpoints(for: key, role: session.role).isEmpty else { return }
            teardownSession(session.ref, reconnect: true)
            removeLink(session.link, notifyTransport: true)
        case let .broadcast(topic, payload):
            guard config.mode.usesOverlayServices else { return }
            let message = Message.peerMessage(topic: topic, payload: payload)
            for key in sessions.keys.sorted() where sessions[key]?.role == .endpoint {
                if let ref = sessions[key]?.ref { _ = enqueue(message, on: ref) }
            }
        case let .announceProvider(rootCID, expiresAt):
            announceProvider(rootCID: rootCID, expiresAt: expiresAt)
        case let .reportDeficientContent(rootCID, peer):
            reportDeficientContent(rootCID: rootCID, servedBy: peer)
        case .setContentSource(let present):
            hasContentSource = present
        case let .setRelaying(peer, relays):
            guard let key = try? PeerKey(peer.publicKey) else { return }
            if relays, endpointSession(for: key) != nil {
                relayingPeers.insert(key)
            } else {
                relayingPeers.remove(key)
            }
        }
    }

    // MARK: - Read-only views

    public var connectedPeers: [PeerID] { connectedEndpointPeers }

    var connectedEndpointPeers: [PeerID] {
        sessions.keys.sorted().compactMap {
            sessions[$0]?.role == .endpoint ? $0.peerID : nil
        }
    }

    public var connectedPeerEndpoints: [PeerEndpoint] {
        sessions.keys.sorted().compactMap { key in
            guard let session = sessions[key], session.role == .endpoint else { return nil }
            return links[session.link]?.endpoint
        }
    }

    public var knownPeerEndpoints: [PeerEndpoint] {
        router.allPeers().map(\.endpoint)
    }

    public var peerConnectionCount: Int {
        sessions.values.lazy.filter { $0.role == .endpoint }.count
    }

    /// The peers with an unexpired provider record for `rootCID`.
    public func providers(for rootCID: String) -> [PeerID] {
        guard config.mode.usesOverlayServices else { return [] }
        var seen: Set<PeerID> = []
        return (providerHints[rootCID] ?? []).compactMap { hint in
            hint.expiresAt > now.unixSeconds && seen.insert(hint.peer).inserted ? hint.peer : nil
        }
    }

    /// The authenticated session currently selected for `peer`, if any.
    public func authenticatedPeer(for peer: PeerID) -> AuthenticatedPeer? {
        guard let key = try? PeerKey(peer.publicKey), let session = sessions[key] else { return nil }
        return authenticatedPeer(session)
    }

    /// Counters a harness asserts on after a scenario; all return to zero
    /// once nothing is in flight.
    public var diagnostics: Diagnostics {
        Diagnostics(
            inboundBytesUsed: inboundBytesUsed,
            pendingSessions: pendingSessions.count,
            outgoingDials: outgoingDials.count,
            relayRoutes: relayRoutes.count,
            installedRoutes: installedRoutes.count,
            pendingRelayOpens: pendingRelayOpens.count,
            inFlightVolumeBytes: inFlightVolumeBytes,
            reservedVolumeBytes: reservedVolumeBytes,
            reservedServingVolumeBytes: reservedServingVolumeBytes,
            servingSlotsHeld: servingContentRequests.count + activeLocalContentRequestCount,
            servingRequestsWaiting: servingTickets.count,
            servingVolumeReadsWaiting: servingVolumeReadWaiters.count,
            jobsOutstanding: jobs.count,
            deadlines: timers.count,
            pendingRequests: requests.count
                + pendingVolumeRequests.count
                + pendingNeighborResponses.count
                + pendingProviderQueries.count)
    }

    public struct Diagnostics: Sendable, Equatable {
        public let inboundBytesUsed: Int
        public let pendingSessions: Int
        public let outgoingDials: Int
        public let relayRoutes: Int
        public let installedRoutes: Int
        public let pendingRelayOpens: Int
        public let inFlightVolumeBytes: Int
        public let reservedVolumeBytes: Int
        public let reservedServingVolumeBytes: Int
        public let servingSlotsHeld: Int
        public let servingRequestsWaiting: Int
        public let servingVolumeReadsWaiting: Int
        public let jobsOutstanding: Int
        public let deadlines: Int
        public let pendingRequests: Int
    }
}

// MARK: - Deadlines

enum TimerKind: Hashable, Sendable {
    case health
    case routingRefresh
    case pendingSession(LinkID)
    case reconnect(PeerID)
    case relayOpen(Data)
    case relayRoute(Data)
    case installedRoute(Data)
    case relayForward(LinkID)
    case neighbor(UInt64)
    case providerQuery(String)
    case volumeRequest(UInt64)
    case volumeWritable(OpID)
    case serving(InboundContentRequest)
}

/// Every deadline Ivy holds. The shell keeps one timer, set to `earliest`.
struct TimerTable: Sendable {
    private var deadlines: [TimerKind: (at: Duration, order: UInt64)] = [:]
    private var nextOrder: UInt64 = 0
    private var cachedEarliest: Duration?
    private var earliestIsStale = false

    var count: Int { deadlines.count }

    var earliest: Duration? {
        mutating get {
            if earliestIsStale {
                cachedEarliest = deadlines.values.lazy.map(\.at).min()
                earliestIsStale = false
            }
            return cachedEarliest
        }
    }

    mutating func set(_ kind: TimerKind, at deadline: Duration) {
        cancel(kind)
        nextOrder &+= 1
        deadlines[kind] = (deadline, nextOrder)
        if !earliestIsStale, cachedEarliest.map({ deadline < $0 }) ?? true {
            cachedEarliest = deadline
        }
    }

    mutating func cancel(_ kind: TimerKind) {
        guard let removed = deadlines.removeValue(forKey: kind) else { return }
        if removed.at == cachedEarliest { earliestIsStale = true }
    }

    func isSet(_ kind: TimerKind) -> Bool {
        deadlines[kind] != nil
    }

    /// Removes and returns what is due, earliest first, ties in the order set.
    mutating func popExpired(at now: Duration) -> [TimerKind] {
        guard let earliest, earliest <= now else { return [] }
        let due = deadlines.filter { $0.value.at <= now }
            .sorted { ($0.value.at, $0.value.order) < ($1.value.at, $1.value.order) }
            .map(\.key)
        for kind in due { deadlines.removeValue(forKey: kind) }
        earliestIsStale = true
        return due
    }

    mutating func removeAll() {
        deadlines.removeAll()
        cachedEarliest = nil
        earliestIsStale = false
    }
}

/// What an application request is waiting on, so `cancel` can find it.
enum RequestBinding: Sendable, Equatable {
    case connect(OpID)
    case writable(LinkID)
    case volumeFetch(OpID)
    case lookup(OpID)
    case providerSearch(OpID)
}
