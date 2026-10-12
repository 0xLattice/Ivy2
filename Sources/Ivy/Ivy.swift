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
    public nonisolated let config: IvyConfig
    public nonisolated let tally: Tally
    public nonisolated let localID: PeerID

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
    private nonisolated let shell: TCPShell
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
        self.shell = TCPShell(
            group: group,
            maxUnseenInbound: config.maxConnections,
            maxUnseenPerNetgroup: config.maxConnectionsPerNetgroup,
            post: { continuation.yield($0) })
        Task { await self.runDriver(events) }
    }

    deinit {
        driver?.cancel()
        timer?.cancel()
        addressDiscovery?.cancel()
        for task in jobTasks.values { task.cancel() }
        for waiter in waiters.values { waiter.resume(returning: .flag(false)) }
        shell.closeAll()
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
        shell.processed(event)
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
            shell.dial(dial, endpoint)
        case .write(let connection, let bytes):
            shell.write(connection, bytes)
        case .close(let connection):
            shell.close(connection)
        case .pauseReading(let connection):
            shell.setReading(connection, false)
        case .resumeReading(let connection):
            shell.setReading(connection, true)

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
            case let .readContent(rootCID, cids, maxDataBytes):
                result = .entries(await source?.content(
                    rootCID: rootCID, cids: cids, maxDataBytes: maxDataBytes) ?? [])
            case let .readVolume(rootCID, maxDataBytes):
                result = .entries(await source?.volume(
                    rootCID: rootCID, maxDataBytes: maxDataBytes) ?? [])
            case .readVolumeBundle(let rootCID):
                result = .roots(await source?.volumeBundle(rootCID: rootCID) ?? [])
            case let .authorizeContent(peer, rootCID, cids):
                result = .authorized(await source?.authorizesContentRequest(
                    from: peer, rootCID: rootCID, cids: cids) ?? false)
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
        try await shell.listen(port: config.listenPort)
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
        await shell.stopListening()
    }

    /// The port the listener is bound to; differs from `config.listenPort`
    /// only when that is 0.
    public var boundPort: UInt16? { shell.boundPort }

    // MARK: - Peers

    public var connectedPeers: [PeerID] { core.connectedPeers }
    public var connectedPeerEndpoints: [PeerEndpoint] { core.connectedPeerEndpoints }
    public var knownPeerEndpoints: [PeerEndpoint] { core.knownPeerEndpoints }
    public var peerConnectionCount: Int { core.peerConnectionCount }
    public var publicAddress: ObservedAddress? { core.publicAddress }

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

    /// Fetches an exact content selection. The root is always included; `cids`
    /// names any additional entries. The response is attributed but unvalidated.
    public func fetchContent(rootCID: String, cids: [String] = []) async -> AttributedContentResponse {
        guard case .content(let response) = await self.await(
            .fetchContent(rootCID: rootCID, cids: cids)) else { return .empty }
        return response
    }

    /// Fetches one exact selection from the specified authenticated endpoint
    /// session. A replacement connection for the same key cannot receive or
    /// satisfy the request.
    public func fetchContent(
        rootCID: String,
        cids: [String] = [],
        from peer: AuthenticatedPeer
    ) async -> AttributedContentResponse {
        guard case .content(let response) = await self.await(
            .fetchContentFrom(peer, rootCID: rootCID, cids: cids)) else { return .empty }
        return response
    }

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
}
