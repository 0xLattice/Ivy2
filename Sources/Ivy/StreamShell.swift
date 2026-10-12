import Foundation
import IvyCore
import NIOCore

/// Every connection the node holds, whoever established it, and the
/// translation between a `TransportConnection` and the core's events and
/// effects. It decides nothing about the protocol.
///
/// A connection is asked for bytes only when the core wants it read, one
/// request at a time: the next is made once the core has handled the bytes of
/// the last. A connection the core is holding back is therefore not read, and
/// its transport holds the sender.
final class StreamShell: @unchecked Sendable {
    private let post: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var connections: [ConnectionID: StreamAdapter] = [:]
    private var nextConnection: UInt64 = 0
    private var gate: InboundAdmissionGate?
    private let maxInbound: Int
    private let maxInboundPerNetgroup: Int

    init(
        maxInbound: Int,
        maxInboundPerNetgroup: Int,
        post: @escaping @Sendable (Event) -> Void
    ) {
        self.maxInbound = maxInbound
        self.maxInboundPerNetgroup = maxInboundPerNetgroup
        self.post = post
    }

    // MARK: - Admission

    /// Starts admitting inbound streams for a run.
    func openGate() {
        let gate = InboundAdmissionGate(
            maxConnections: maxInbound, maxConnectionsPerNetgroup: maxInboundPerNetgroup)
        lock.withLock { self.gate = gate }
    }

    /// Stops admitting; leases of the ended run admit nothing.
    func closeGate() {
        let gate = lock.withLock { () -> InboundAdmissionGate? in
            defer { self.gate = nil }
            return self.gate
        }
        gate?.invalidate()
    }

    func reserve(observedHost: String?) -> InboundAdmissionLease? {
        lock.withLock { gate }?.reserve(observedHost: observedHost)
    }

    // MARK: - Taking streams

    /// Takes a stream with this node as the responder. Nothing is requested
    /// from it until the core has admitted it.
    func accept(_ stream: any TransportConnection, admission: InboundAdmissionLease) {
        guard admission.claim() else { return stream.close() }
        let current = lock.withLock { gate }
        guard let issuer = admission.gate, issuer === current, issuer.isAccepting,
              admission.netgroup == NetGroup.group(stream.observedHost ?? "unknown") else {
            admission.release()
            return stream.close()
        }
        let adapter = register(stream, admission: admission)
        post(.connectionOpened(
            adapter.id,
            direction: .inbound,
            observedHost: stream.observedHost,
            localHost: stream.localHost))
    }

    /// Takes a stream the core will be told about by the caller: the answer
    /// to a dial, or a connection supplied for `connectOver`.
    func hold(_ stream: any TransportConnection) -> ConnectionID {
        register(stream, admission: nil).id
    }

    /// Reports a stream as the answer to a dial the core asked for.
    func opened(_ stream: any TransportConnection, for dial: DialID) {
        let id = hold(stream)
        post(.connectionOpened(
            id,
            direction: .outbound(dial),
            observedHost: stream.observedHost,
            localHost: stream.localHost))
    }

    func dialFailed(_ dial: DialID) {
        post(.dialFailed(dial))
    }

    private func register(
        _ stream: any TransportConnection,
        admission: InboundAdmissionLease?
    ) -> StreamAdapter {
        let adapter = lock.withLock { () -> StreamAdapter in
            nextConnection += 1
            let adapter = StreamAdapter(
                id: ConnectionID(nextConnection), stream: stream, admission: admission, shell: self)
            connections[adapter.id] = adapter
            return adapter
        }
        stream.attach(adapter)
        return adapter
    }

    // MARK: - What the core asks for

    func write(_ id: ConnectionID, _ bytes: Data) {
        adapter(id)?.write(bytes)
    }

    func close(_ id: ConnectionID) {
        adapter(id)?.close()
    }

    func setReading(_ id: ConnectionID, _ reading: Bool) {
        adapter(id)?.setReading(reading)
    }

    /// The core has handled an event about a connection: the bytes of its
    /// last read, or its opening.
    func processed(_ event: Event) {
        switch event {
        case .received(let id, _):
            adapter(id)?.readProcessed()
        case .connectionOpened(let id, .inbound, _, _):
            adapter(id)?.releaseAdmission()
        default:
            return
        }
    }

    func closeAll() {
        closeGate()
        let all = lock.withLock { Array(connections.values) }
        for adapter in all { adapter.close() }
    }

    private func adapter(_ id: ConnectionID) -> StreamAdapter? {
        lock.withLock { connections[id] }
    }

    // MARK: - What a stream reports

    fileprivate func received(_ id: ConnectionID, _ bytes: Data) {
        post(.received(id, bytes))
    }

    fileprivate func writable(_ id: ConnectionID) {
        post(.writable(id))
    }

    fileprivate func closed(_ id: ConnectionID) {
        let known = lock.withLock { connections.removeValue(forKey: id) != nil }
        if known { post(.closed(id)) }
    }
}

/// One stream's side of the conversation with the core.
private final class StreamAdapter: TransportConnectionSink, @unchecked Sendable {
    let id: ConnectionID
    private let stream: any TransportConnection
    private weak var shell: StreamShell?
    private let lock = NSLock()
    private var admission: InboundAdmissionLease?
    /// The core wants this connection read.
    private var wantsRead = false
    /// Bytes were asked for, or are with the core and not yet handled.
    private var readOutstanding = false
    /// Bytes written since the core was last told `writable`. The core keeps
    /// the same count and stops writing past its high-water mark, so that is
    /// when it needs to hear again.
    private var writtenSinceWritable = 0
    private var owesWritable = false

    init(
        id: ConnectionID,
        stream: any TransportConnection,
        admission: InboundAdmissionLease?,
        shell: StreamShell
    ) {
        self.id = id
        self.stream = stream
        self.admission = admission
        self.shell = shell
    }

    func releaseAdmission() {
        let lease = lock.withLock { () -> InboundAdmissionLease? in
            defer { admission = nil }
            return admission
        }
        lease?.release()
    }

    func setReading(_ reading: Bool) {
        let request = lock.withLock { () -> Bool in
            wantsRead = reading
            guard reading, !readOutstanding else { return false }
            readOutstanding = true
            return true
        }
        if request { stream.requestBytes() }
    }

    func readProcessed() {
        let request = lock.withLock { () -> Bool in
            guard wantsRead else {
                readOutstanding = false
                return false
            }
            return true
        }
        if request { stream.requestBytes() }
    }

    func write(_ bytes: Data) {
        stream.send(bytes)
        let tell = lock.withLock { () -> Bool in
            writtenSinceWritable += bytes.count
            guard writtenSinceWritable > IvyCore.writeHighWaterMark else { return false }
            // The core now holds its writes. It may resume as soon as the
            // stream has room, which may be at once.
            guard stream.isWritable else {
                owesWritable = true
                return false
            }
            writtenSinceWritable = 0
            return true
        }
        if tell { shell?.writable(id) }
    }

    func close() {
        stream.close()
    }

    // MARK: TransportConnectionSink

    func transportDidReceive(_ bytes: Data) {
        guard !bytes.isEmpty else {
            // Nothing to hand over: the request is spent, so ask again.
            let request = lock.withLock { wantsRead }
            if request {
                stream.requestBytes()
            } else {
                lock.withLock { readOutstanding = false }
            }
            return
        }
        shell?.received(id, bytes)
    }

    func transportWritabilityChanged(isWritable: Bool) {
        let tell = lock.withLock { () -> Bool in
            guard isWritable, owesWritable else { return false }
            owesWritable = false
            writtenSinceWritable = 0
            return true
        }
        if tell { shell?.writable(id) }
    }

    func transportDidClose() {
        releaseAdmission()
        shell?.closed(id)
    }
}
