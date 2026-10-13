import Foundation
import IvyCore
import NIOCore
import NIOPosix
import Tally

/// Records the core's traffic evidence in a `Tally`.
struct TallyLedger: PeerLedger {
    let tally: Tally

    func recordSent(peer: PeerID, bytes: Int) { tally.recordSent(peer: peer, bytes: bytes) }
    func recordReceived(peer: PeerID, bytes: Int) { tally.recordReceived(peer: peer, bytes: bytes) }
    func recordProtocolViolation(peer: PeerID) { tally.recordProtocolViolation(peer: peer) }
    func servingPriority(for peer: PeerID) -> Double { tally.servingPriority(for: peer) }
}

/// Ivy for an application: the shell around `IvyCore`. It owns the sockets,
/// one timer and the calls into the delegate and the content source, and
/// maps each request to the caller waiting for it. Every decision is the
/// core's; this type only carries events in and effects out.
public actor Ivy {
    public let config: IvyConfig
    public let tally: Tally
    public let localID: PeerID

    public weak var delegate: IvyDelegate?

    private var contentSource: (any IvyContentSource)?
    public func setContentSource(_ source: IvyContentSource?) {
        contentSource = source
        apply(.command(.setContentSource(source != nil)))
    }

    private var core: IvyCore
    private let group: EventLoopGroup
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private nonisolated let streams: StreamShell
    private nonisolated let tcp: TCPTransport
    private let stunClient: STUNClient

    private var driver: Task<Void, Never>?
    private var lifecycleTail: Task<Void, Never>?
    private var listening = false
    private var timer: Scheduled<Void>?
    private var nextRequest: UInt64 = 0
    private var waiters: [RequestID: CheckedContinuation<RequestResult, Never>] = [:]
    /// Results of requests the core answered within the step that made them.
    private var immediate: [RequestID: RequestResult] = [:]
    private var jobTasks: [JobID: Task<Void, Never>] = [:]
    private var addressDiscovery: Task<Void, Never>?

    public init(
        config: IvyConfig,
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        tally: Tally? = nil
    ) {
        let tally = tally ?? Tally(config: config.tallyConfig)
        self.config = config
        self.tally = tally
        self.localID = PeerID(publicKey: config.publicKey)
        self.group = group
        self.origin = clock.now
        self.core = IvyCore(config: config, ledger: TallyLedger(tally: tally))
        self.stunClient = STUNClient(group: group, servers: config.stunServers)

        // Transport callbacks arrive on event loops; one stream puts them in
        // order for the driver, which is the only thing that steps the core
        // on their behalf.
        let (events, continuation) = AsyncStream<Event>.makeStream()
        let streams = StreamShell(
            maxInbound: config.maxConnections,
            maxInboundPerNetgroup: config.maxConnectionsPerNetgroup,
            post: { continuation.yield($0) })
        self.streams = streams
        self.tcp = TCPTransport(group: group, shell: streams)
        Task { await self.runDriver(events) }
    }

    deinit {
        driver?.cancel()
        timer?.cancel()
        addressDiscovery?.cancel()
        for task in jobTasks.values { task.cancel() }
        for waiter in waiters.values { waiter.resume(returning: .flag(false)) }
        tcp.closeListener()
        streams.closeAll()
    }

    private func runDriver(_ events: AsyncStream<Event>) {
        driver = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.applyFromTransport(event)
            }
        }
    }

    private func applyFromTransport(_ event: Event) {
        apply(event)
        streams.processed(event)
    }

    // MARK: - Stepping the core

    private var timestamp: Timestamp {
        Timestamp(
            uptime: origin.duration(to: clock.now),
            unixSeconds: UInt64(max(0, Date().timeIntervalSince1970)))
    }

    private func apply(_ event: Event) {
        for effect in core.step(event, now: timestamp) { perform(effect) }
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .dial(let dial, let endpoint):
#if DEBUG || IVY_TESTING
            tcp.dial(dial, dialEndpointRewrite?(endpoint) ?? endpoint)
#else
            tcp.dial(dial, endpoint)
#endif
        case .write(let connection, let bytes):
            streams.write(connection, bytes)
        case .close(let connection):
            streams.close(connection)
        case .pauseReading(let connection):
            streams.setReading(connection, false)
        case .resumeReading(let connection):
            streams.setReading(connection, true)

        case .deliver(let token, let peer, let message):
            Task { [weak self] in
                guard let self else { return }
                await self.delegate?.ivy(self, didReceiveMessage: message, from: peer)
                await self.apply(.delivered(token))
            }
        case .peerConnected(let token, let peer):
            Task { [weak self] in
                guard let self else { return }
                await self.delegate?.ivy(self, didConnect: peer)
                await self.apply(.delivered(token))
            }
        case .peerDisconnected(let peer):
            delegate?.ivy(self, didDisconnect: peer)
        case .publicAddressDiscovered(let address):
            delegate?.ivy(self, didDiscoverPublicAddress: address)

        case .completed(let request, let result):
            if let waiter = waiters.removeValue(forKey: request) {
                waiter.resume(returning: result)
            } else {
                immediate[request] = result
            }

        case .startJob(let id, let job):
            startJob(id, job)
        case .cancelJob(let id):
            jobTasks[id]?.cancel()

        case .discoverPublicAddress:
            addressDiscovery?.cancel()
            addressDiscovery = Task { [weak self, stunClient] in
                let address = await stunClient.discoverPublicAddress()
                guard !Task.isCancelled else { return }
                await self?.apply(.publicAddress(address))
            }

        case .wakeAt(let deadline):
            timer?.cancel()
            let delay = max(.zero, deadline - origin.duration(to: clock.now))
            timer = group.next().scheduleTask(in: TimeAmount(delay)) { [weak self] in
                Task { await self?.apply(.tick) }
            }
        }
    }

    /// Runs one storage or authorization call. It always answers, even when
    /// cancelled: the core counts the job until it does.
    private func startJob(_ id: JobID, _ job: Job) {
        let source = contentSource
        jobTasks[id] = Task { [weak self] in
            let result: JobResult
            switch job {
            case let .readVolume(rootCID, maxDataBytes):
                result = .entries(await source?.volume(
                    rootCID: rootCID, maxDataBytes: maxDataBytes) ?? [])
            case .readVolumeBundle(let rootCID):
                result = .roots(await source?.volumeBundle(rootCID: rootCID) ?? [])
            case let .authorizeVolume(peer, rootCID):
                result = .authorized(await source?.authorizesVolumeRequest(
                    from: peer, rootCID: rootCID) ?? false)
            }
            await self?.finishJob(id, result)
        }
    }

    private func finishJob(_ id: JobID, _ result: JobResult) {
        jobTasks.removeValue(forKey: id)
        apply(.jobFinished(id, result))
    }

    private func makeRequestID() -> RequestID {
        nextRequest &+= 1
        return RequestID(nextRequest)
    }

    /// A request the core answers within the step.
    private func ask(_ request: Request) -> RequestResult? {
        let id = makeRequestID()
        apply(.request(id, request))
        return immediate.removeValue(forKey: id)
    }

    /// A request whose answer may take time. Cancelling the caller cancels it.
    private func await(_ request: Request) async -> RequestResult {
        let id = makeRequestID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                apply(.request(id, request))
            }
        } onCancel: {
            Task { await self.apply(.cancel(id)) }
        }
    }

    // MARK: - Lifecycle

    /// Lifecycle calls execute in order.
    public func start() async throws {
        let previous = lifecycleTail
        let operation = Task { [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            try await self.startNow()
        }
        lifecycleTail = Task { _ = try? await operation.value }
        try await operation.value
    }

    private func startNow() async throws {
        guard !listening else { return }
        try config.validate()
        streams.openGate()
        do {
            try await tcp.listen(port: config.listenPort)
        } catch {
            streams.closeGate()
            throw error
        }
        listening = true
        apply(.start)
    }

    public func stop() async {
        let previous = lifecycleTail
        let operation = Task { [weak self] in
            await previous?.value
            await self?.stopNow()
        }
        lifecycleTail = operation
        await operation.value
    }

    private func stopNow() async {
        apply(.stop)
        timer?.cancel()
        timer = nil
        addressDiscovery?.cancel()
        addressDiscovery = nil
        for task in jobTasks.values { task.cancel() }
        guard listening else { return }
        listening = false
        streams.closeGate()
        await tcp.stopListening()
    }

    /// The port the listener is bound to; differs from `config.listenPort`
    /// only when that is 0.
    public var boundPort: UInt16? { tcp.boundPort }

    // MARK: - Supplied streams

    /// Reserves inbound admission for a peer observed at `observedHost`, or
    /// returns nil when the node is not accepting it. A supplier of inbound
    /// streams calls this before it spends anything on the peer, then hands
    /// the stream to `accept(_:admission:)`. `observedHost` must be the host
    /// the stream will report: the lease admits only a stream of the netgroup
    /// it was reserved for. A peer with no observed host is not admitted.
    public nonisolated func reserveInboundAdmission(
        observedHost: String?
    ) -> InboundAdmissionLease? {
        guard let observedHost, !observedHost.isEmpty else { return nil }
        return streams.reserve(observedHost: observedHost)
    }

    /// Accepts a stream the caller established, with this node as the
    /// responder. Nothing is requested from the stream until the node has
    /// admitted it. Refusal is reported only by closing the stream.
    public nonisolated func accept(
        _ stream: any TransportConnection,
        admission: InboundAdmissionLease
    ) {
        guard let host = stream.observedHost, !host.isEmpty else {
            admission.release()
            stream.close()
            return
        }
        streams.accept(stream, admission: admission)
    }

    /// Connects to `endpoint` over a stream the caller established, with this
    /// node as the initiator. The stream is closed unless it becomes the
    /// peer's session, and it must report the host its peer was observed at.
    public func connect(
        to endpoint: PeerEndpoint,
        over stream: any TransportConnection
    ) async throws {
        let connection = streams.hold(stream)
        try Self.unwrap(await self.await(.connectOver(
            endpoint,
            connection,
            observedHost: stream.observedHost,
            localHost: stream.localHost)))
    }

    // MARK: - Peers

    public var connectedPeers: [PeerID] { core.connectedPeers }
    public var connectedPeerEndpoints: [PeerEndpoint] { core.connectedPeerEndpoints }
    public var knownPeerEndpoints: [PeerEndpoint] { core.knownPeerEndpoints }
    public var peerConnectionCount: Int { core.peerConnectionCount }
    public var publicAddress: ObservedAddress? { core.publicAddress }
    /// The session the node has with `peer` now, if any: its route says
    /// whether the peer is reached directly or through a carrier.
    public func session(with peer: PeerID) -> AuthenticatedPeer? { core.authenticatedPeer(for: peer) }
    /// Whether `host` is an IP literal anyone on the internet could be
    /// reached at.
    public func isGloballyRoutable(_ host: String) -> Bool { core.isGloballyRoutable(host) }

    public func connect(to endpoint: PeerEndpoint) async throws {
        try Self.unwrap(await self.await(.connect(endpoint)))
    }

    public func connectViaRelay(to endpoint: PeerEndpoint) async throws {
        try Self.unwrap(await self.await(.connectViaRelay(endpoint)))
    }

    private static func unwrap(_ result: RequestResult) throws {
        guard case .connect(let outcome) = result else { throw IvyError.notRunning }
        switch outcome {
        case .connected:
            return
        case .failed(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }

    /// Says whether a connected peer relays. When a peer cannot be dialled,
    /// the node asks the peers it was told relay for a route to it, after
    /// its configured carriers. Say so only of a peer that said it does: one
    /// that does not relay ends the session of a peer that asks. Forgotten
    /// when the peer's session ends.
    public func setRelaying(_ peer: PeerID, _ relays: Bool) {
        apply(.command(.setRelaying(peer, relays)))
    }

    public func disconnect(_ peer: PeerID) {
        apply(.command(.disconnect(peer)))
    }

    /// Restart a configured peer without turning off its automatic reconnect.
    /// Prefer the exact-session overload when handling an authenticated callback.
    @available(*, deprecated, message: "Use recycleSession(ifCurrent:)")
    public func restartConfiguredSession(with peer: PeerID) {
        apply(.command(.restartConfiguredSession(peer)))
    }

    /// Close only the represented authenticated session. Configured peers
    /// reconnect automatically; unconfigured peers may reconnect themselves.
    /// A stale callback cannot close a replacement session for the same key.
    @discardableResult
    public func recycleSession(ifCurrent peer: AuthenticatedPeer) -> Bool {
        ask(.recycleSession(peer)) == .flag(true)
    }

    /// Permanently close only the represented authenticated session. A stale
    /// callback cannot suppress or close its replacement for the same key.
    @discardableResult
    public func disconnectSession(ifCurrent peer: AuthenticatedPeer) -> Bool {
        ask(.disconnectSession(peer)) == .flag(true)
    }

    // MARK: - Messages

    public func sendMessage(to peer: PeerID, topic: String, payload: Data) -> SendMessageResult {
        guard case .send(let result) = ask(.send(to: peer, topic: topic, payload: payload)) else {
            return .notConnected
        }
        return result
    }

    /// Sends only if `peer` still names the selected authenticated session.
    public func sendMessage(
        to peer: AuthenticatedPeer,
        topic: String,
        payload: Data
    ) -> SendMessageResult {
        guard case .send(let result) = ask(.sendOnSession(peer, topic: topic, payload: payload)) else {
            return .notConnected
        }
        return result
    }

    public func broadcastMessage(topic: String, payload: Data) {
        apply(.command(.broadcast(topic: topic, payload: payload)))
    }

    /// Wait until the live route to `peer` can accept another outbound record.
    /// Returns false when that route closes before it becomes writable.
    public func waitUntilWritable(to peer: PeerID) async -> Bool {
        await self.await(.waitUntilWritable(peer)) == .writable(true)
    }

    /// Waits only on the transport represented by `peer`, never a replacement.
    public func waitUntilWritable(to peer: AuthenticatedPeer) async -> Bool {
        await self.await(.waitUntilSessionWritable(peer)) == .writable(true)
    }

    // MARK: - Content

    /// Fetches one complete Volume. Provider selection may use any connected
    /// endpoint advertising the root.
    public func fetchVolume(rootCID: String) async -> AttributedVolumeResponse {
        await fetchVolume(rootCID: rootCID, maximumArchiveBytes: .max, maximumEntries: .max)
    }

    /// Fetches one complete Volume without accepting a response whose declared
    /// archive or entry count exceeds the caller's local capacity.
    public func fetchVolume(
        rootCID: String,
        maximumArchiveBytes: Int,
        maximumEntries: Int
    ) async -> AttributedVolumeResponse {
        guard case .volume(let response) = await self.await(.fetchVolume(
            rootCID: rootCID,
            maximumArchiveBytes: maximumArchiveBytes,
            maximumEntries: maximumEntries)) else { return .empty }
        return response
    }

    /// Fetches one complete Volume from the exact authenticated endpoint
    /// session that advertised it.
    public func fetchVolume(
        rootCID: String,
        from peer: AuthenticatedPeer
    ) async -> AttributedVolumeResponse {
        await fetchVolume(
            rootCID: rootCID, from: peer, maximumArchiveBytes: .max, maximumEntries: .max)
    }

    /// Fetches one complete Volume from an exact session while rejecting a
    /// response whose advertised boundary exceeds the caller's needs before
    /// allocating its archive.
    public func fetchVolume(
        rootCID: String,
        from peer: AuthenticatedPeer,
        maximumArchiveBytes: Int,
        maximumEntries: Int
    ) async -> AttributedVolumeResponse {
        guard case .volume(let response) = await self.await(.fetchVolumeFrom(
            peer,
            rootCID: rootCID,
            maximumArchiveBytes: maximumArchiveBytes,
            maximumEntries: maximumEntries)) else { return .empty }
        return response
    }

    /// Fetches the Volumes a peer bundles under `rootCID` with one request:
    /// every Volume the peer sent before its answer ended, the root's own
    /// first. Only the sessions named are asked, one at a time, until one
    /// sends a Volume.
    public func fetchVolumeBundle(
        rootCID: String,
        from peers: [AuthenticatedPeer]
    ) async -> AttributedVolumeBundleResponse {
        guard case .volumeBundle(let response) = await self.await(
            .fetchVolumeBundle(rootCID: rootCID, from: peers)) else { return .empty }
        return response
    }

    public func reportDeficientContent(rootCID: String, servedBy peer: PeerID) {
        apply(.command(.reportDeficientContent(rootCID: rootCID, servedBy: peer)))
    }

    // MARK: - Discovery

    public func findNode(target: String) async -> [PeerEndpoint] {
        guard case .endpoints(let endpoints) = await self.await(.findNode(target: target)) else {
            return []
        }
        return endpoints
    }

    public func announceProvider(rootCID: String, expiresAt: UInt64) {
        apply(.command(.announceProvider(rootCID: rootCID, expiresAt: expiresAt)))
    }

    public func discoverProviders(rootCID: String) async -> [PeerEndpoint] {
        guard case .endpoints(let endpoints) = await self.await(
            .discoverProviders(rootCID: rootCID)) else { return [] }
        return endpoints
    }

    public func providers(for rootCID: String) -> [PeerID] {
        core.providers(for: rootCID)
    }

    /// The core's counters, for tests and operators.
    public var diagnostics: IvyCore.Diagnostics { core.diagnostics }

#if DEBUG || IVY_TESTING
    private var dialEndpointRewrite: (@Sendable (PeerEndpoint) -> PeerEndpoint)?

    /// Redirects where the shell dials, leaving what the core believes it
    /// dialled alone: nodes on one machine can then advertise routable
    /// addresses, which is the only kind a referral may carry.
    func setDialEndpointRewriteForTesting(
        _ rewrite: (@Sendable (PeerEndpoint) -> PeerEndpoint)?
    ) {
        dialEndpointRewrite = rewrite
    }
#endif
}
