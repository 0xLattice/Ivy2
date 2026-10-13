// Ivy for a JavaScript application: the shell around the core, and the
// counterpart of Sources/Ivy/Ivy.swift. It owns the connections, one timer
// and the calls into the delegate and the content source, and maps each
// request to the caller waiting for it. Every decision is the core's; this
// only carries events in and effects out.

import {
  type Address,
  type AuthenticatedPeer,
  type ConnectError,
  type ContentEntry,
  type Duration,
  type Effect,
  type Event,
  type IvyConfig,
  type Job,
  type JobResult,
  type PeerEndpoint,
  type PeerID,
  type PeerMessage,
  type Request,
  type RequestResult,
  type SendMessageResult,
  type VolumeBundleResponse,
  type VolumeResponse,
  hex,
  unlimited,
} from './codec.js';
import type { Core, IvyModule } from './core.js';
import { Connection, type Transport } from './transport.js';

/// What the application hears. The core holds a session's next record, and
/// does not read its connection, until the promise a callback returned has
/// settled.
export interface IvyDelegate {
  /// Settles before Ivy accepts application records on this session.
  peerConnected?(peer: AuthenticatedPeer): void | Promise<void>;
  deliver?(message: PeerMessage, from: AuthenticatedPeer): void | Promise<void>;
  peerDisconnected?(peer: PeerID): void;
  publicAddressDiscovered?(address: Address): void;
}

/// Where Volumes this node serves come from: IndexedDB, memory, anything.
/// A method left out answers as the native protocol's default does. The
/// signal aborts when the core no longer wants the answer; a method may
/// stop early then, and whatever it returns or throws still counts as its
/// one answer.
export interface ContentSource {
  /// Every entry of the complete Volume rooted at `rootCID`, the root's own
  /// included, or `[]`.
  volume?(rootCID: string, maxDataBytes: number, signal: AbortSignal): Promise<ContentEntry[]>;
  /// Whether `peer` may read the Volume. Left out: anyone may.
  authorizesVolumeRequest?(
    peer: AuthenticatedPeer,
    rootCID: string,
    signal: AbortSignal,
  ): Promise<boolean>;
  /// The roots of the Volumes bundled under `rootCID`, its own first, or
  /// `[]` when there is no bundle for it.
  volumeBundle?(rootCID: string, signal: AbortSignal): Promise<string[]>;
}

export interface IvyOptions {
  delegate?: IvyDelegate;
  contentSource?: ContentSource;
  /// Establishes a stream to an endpoint the core wants dialled: a
  /// bootstrap peer, a carrier, a provider it discovered. Left out, or
  /// rejecting, the dial fails.
  dial?: (endpoint: PeerEndpoint) => Promise<Transport>;
}

export interface RequestOptions {
  /// Aborting cancels the request, which then completes as the core
  /// answers a cancelled one.
  signal?: AbortSignal;
}

export interface FetchVolumeOptions extends RequestOptions {
  /// Ask only this session, the one that advertised the Volume.
  from?: AuthenticatedPeer;
  /// Refuse a response that declares more than this, before allocating it.
  maximumArchiveBytes?: number;
  maximumEntries?: number;
}

/// Why `connect` did not: one of the core's reasons, or `cancelled`.
export class IvyError extends Error {
  constructor(readonly code: ConnectError | 'cancelled' | 'destroyed') {
    super(`Ivy: ${code}`);
    this.name = 'IvyError';
  }
}

/// Peers whose address `reachedAt` keeps.
const maxReached = 256;

const isSession = (peer: PeerID | AuthenticatedPeer): peer is AuthenticatedPeer =>
  typeof peer !== 'string';

export class Ivy {
  delegate: IvyDelegate | null;
  /// This node's public key, as hex: its `PeerID`.
  readonly localID: PeerID;
  /// The address the core was told this node is reachable at, if any.
  publicAddress: Address | null = null;
  private readonly core: Core;
  private readonly dial: IvyOptions['dial'];
  private contentSource: ContentSource | null;
  private readonly origin = performance.now();
  private destroyed = false;

  private readonly queue: Event[] = [];
  private draining = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private lastRequest = 0n;
  private lastConnection = 0n;
  private readonly waiters = new Map<bigint, (result: RequestResult) => void>();
  private readonly connections = new Map<bigint, Connection>();
  private readonly jobs = new Map<bigint, AbortController>();
  /// Where a stream was last opened to each peer, most recent last. The
  /// core keeps no address for a stream it was handed.
  private readonly reached = new Map<PeerID, PeerEndpoint>();

  /// Throws if the core does not accept `config`.
  constructor(
    private readonly module: IvyModule,
    config: IvyConfig,
    options: IvyOptions = {},
  ) {
    this.core = module.createCore(config);
    this.localID = hex(this.core.publicKey);
    this.delegate = options.delegate ?? null;
    this.dial = options.dial;
    this.contentSource = options.contentSource ?? null;
    if (this.contentSource !== null) this.command({ kind: 'setContentSource', present: true });
  }

  /// Says whether a connected peer relays, so the core may ask it for a
  /// route to a peer it cannot dial. Say so only of a peer that said it
  /// does: one that does not relay ends the session of a peer that asks.
  setRelaying(peer: PeerID, relays: boolean) {
    this.command({ kind: 'setRelaying', peer, relays });
  }

  setContentSource(source: ContentSource | null) {
    this.contentSource = source;
    this.command({ kind: 'setContentSource', present: source !== null });
  }

  // MARK: - Stepping the core

  private uptimeNanoseconds(): bigint {
    return BigInt(Math.round((performance.now() - this.origin) * 1e6));
  }

  /// Events are applied one at a time, in the order they were made. One
  /// that arrives while another's effects are being performed (a transport
  /// that answers inside `requestBytes`, a delegate that sends from its
  /// callback) waits its turn, so effects are never performed out of order.
  private apply(event: Event) {
    this.held(() => this.queue.push(event));
  }

  /// Runs `body` and then applies what it and anything it called queued,
  /// in order.
  private held(body: () => void) {
    if (this.destroyed) return;
    if (this.draining) return body();
    this.draining = true;
    try {
      body();
      for (let event = this.queue.shift(); event !== undefined; event = this.queue.shift()) {
        const now = {
          uptimeNanoseconds: this.uptimeNanoseconds(),
          unixSeconds: BigInt(Math.floor(Date.now() / 1000)),
        };
        for (const effect of this.core.step(event, now)) this.perform(effect);
        // The bytes of this read are handled: the next may be asked for.
        if (event.kind === 'received') this.connections.get(event.connection)?.readProcessed();
        if (event.kind === 'stop') {
          // The run's deadlines and jobs are gone from the core.
          clearTimeout(this.timer);
          for (const job of this.jobs.values()) job.abort();
        }
      }
    } finally {
      this.draining = false;
    }
  }

  private perform(effect: Effect) {
    switch (effect.kind) {
      case 'dial':
        return this.startDial(effect.dial, effect.endpoint);
      case 'write':
        return this.connections.get(effect.connection)?.write(effect.bytes);
      case 'close':
        return this.connections.get(effect.connection)?.close();
      case 'pauseReading':
        return this.connections.get(effect.connection)?.setReading(false);
      case 'resumeReading':
        return this.connections.get(effect.connection)?.setReading(true);

      case 'deliver': {
        const { peer, message } = effect;
        return this.deliver(effect.token, (delegate) => delegate.deliver?.(message, peer));
      }
      case 'peerConnected': {
        const { peer } = effect;
        return this.deliver(effect.token, (delegate) => delegate.peerConnected?.(peer));
      }
      case 'peerDisconnected': {
        const { peer } = effect;
        return this.notify((delegate) => delegate.peerDisconnected?.(peer));
      }
      case 'publicAddressDiscovered': {
        const { address } = effect;
        this.publicAddress = address;
        return this.notify((delegate) => delegate.publicAddressDiscovered?.(address));
      }

      case 'completed': {
        const waiter = this.waiters.get(effect.id);
        this.waiters.delete(effect.id);
        return waiter?.(effect.result);
      }

      case 'startJob':
        return this.startJob(effect.job, effect.work);
      case 'cancelJob':
        return this.jobs.get(effect.job)?.abort();

      case 'discoverPublicAddress':
        // A configuration made here names no STUN server, so the core does
        // not ask; `reportPublicAddress` is how it learns one.
        return;

      case 'wakeAt':
        return this.wake(effect.deadline);
    }
  }

  /// One timer, set to the core's earliest deadline.
  private wake(deadline: Duration) {
    // Rounded up, so a tick is never a fraction of a nanosecond early.
    const at = deadline.seconds * 1_000_000_000n + (deadline.attoseconds + 999_999_999n) / 1_000_000_000n;
    const schedule = () => {
      clearTimeout(this.timer);
      const delay = Number(at - this.uptimeNanoseconds()) / 1e6;
      // setTimeout holds at most 2^31 - 1 ms, and may fire a little early.
      // The core announces a deadline once, so an early tick would lose it.
      this.timer = setTimeout(
        () => (this.uptimeNanoseconds() < at ? schedule() : this.apply({ kind: 'tick' })),
        Math.min(Math.max(0, Math.ceil(delay)), 0x7fff_ffff),
      );
    };
    schedule();
  }

  /// Runs a delegate callback and tells the core when it has finished,
  /// which it does whatever the callback did.
  private deliver(token: bigint, call: (delegate: IvyDelegate) => void | Promise<void>) {
    const finish = () => this.apply({ kind: 'delivered', token });
    const delegate = this.delegate;
    if (delegate === null) return finish();
    new Promise<void>((resolve) => resolve(call(delegate))).catch(rethrowLater).then(finish);
  }

  /// Runs a delegate callback the core does not wait for. Its error must
  /// not stop the effects that follow it.
  private notify(call: (delegate: IvyDelegate) => void) {
    try {
      if (this.delegate !== null) call(this.delegate);
    } catch (error) {
      rethrowLater(error);
    }
  }

  /// Runs one storage or authorization call. It always answers, even when
  /// cancelled: the core counts the job until it does.
  private startJob(id: bigint, job: Job) {
    const controller = new AbortController();
    this.jobs.set(id, controller);
    const source = this.contentSource;
    const { signal } = controller;
    const run = async (): Promise<JobResult> => {
      switch (job.kind) {
        case 'readVolume':
          return {
            kind: 'entries',
            entries: (await source?.volume?.(job.rootCID, Number(job.maxDataBytes), signal)) ?? [],
          };
        case 'readVolumeBundle':
          return { kind: 'roots', roots: (await source?.volumeBundle?.(job.rootCID, signal)) ?? [] };
        case 'authorizeVolume':
          return {
            kind: 'authorized',
            authorized:
              source === null
                ? false
                : ((await source.authorizesVolumeRequest?.(job.peer, job.rootCID, signal)) ?? true),
          };
      }
    };
    const failed = (error: unknown): JobResult => {
      // An abort the core asked for is not the source's failure.
      if (!signal.aborted) rethrowLater(error);
      if (job.kind === 'readVolume') return { kind: 'entries', entries: [] };
      if (job.kind === 'readVolumeBundle') return { kind: 'roots', roots: [] };
      return { kind: 'authorized', authorized: false };
    };
    run()
      .catch(failed)
      .then((result) => {
        this.jobs.delete(id);
        this.apply({ kind: 'jobFinished', job: id, result });
      });
  }

  private startDial(dial: bigint, endpoint: PeerEndpoint) {
    const failed = () => this.apply({ kind: 'dialFailed', dial });
    if (this.dial === undefined) return failed();
    // The core counts a dial until it hears how it ended, so it always does.
    new Promise<Transport>((resolve) => resolve(this.dial!(endpoint))).then((transport) => {
      if (this.destroyed) return transport.close();
      this.remember(endpoint);
      this.open(transport, (connection) =>
        this.apply({
          kind: 'connectionOpened',
          connection,
          direction: { kind: 'outbound', dial },
          observedHost: transport.observedHost,
          localHost: transport.localHost,
        }),
      );
    }, failed);
  }

  /// Takes a stream and tells the core of it with `announce`, which is
  /// given its connection. The stream is attached only after that is
  /// queued, so one that has already closed reports it after the core has
  /// heard of the connection, not before.
  private open(transport: Transport, announce: (connection: bigint) => void) {
    const id = ++this.lastConnection;
    const connection = new Connection(
      id,
      transport,
      this.module.writeHighWaterMark,
      (event) => this.apply(event),
      (id) => this.connections.delete(id),
    );
    this.connections.set(id, connection);
    this.held(() => {
      announce(id);
      transport.attach(connection);
    });
  }

  private command(command: Extract<Event, { kind: 'command' }>['command']) {
    this.apply({ kind: 'command', command });
  }

  /// Every request is answered by the core exactly once: at once, later,
  /// or when the node stops.
  private request(request: Request, signal?: AbortSignal): Promise<RequestResult> {
    if (this.destroyed) return Promise.reject(new IvyError('destroyed'));
    const id = ++this.lastRequest;
    return new Promise((resolve) => {
      const cancel = () => this.apply({ kind: 'cancel', id });
      this.waiters.set(id, (result) => {
        signal?.removeEventListener('abort', cancel);
        resolve(result);
      });
      this.apply({ kind: 'request', id, request });
      if (!this.waiters.has(id)) return;
      if (signal?.aborted) cancel();
      else signal?.addEventListener('abort', cancel, { once: true });
    });
  }

  // MARK: - Lifecycle

  /// Starts the node. Resolves once the core has started.
  async start(): Promise<void> {
    this.apply({ kind: 'start' });
  }

  /// Stops the node: every pending request is answered and every
  /// connection closed. It may be started again.
  async stop(): Promise<void> {
    this.apply({ kind: 'stop' });
  }

  /// Stops the node and frees its core. Nothing may be asked of it again.
  async destroy(): Promise<void> {
    if (this.destroyed) return;
    await this.stop();
    for (const connection of this.connections.values()) connection.close();
    this.destroyed = true;
    this.core.destroy();
  }

  // MARK: - Supplied streams

  /// Accepts a stream the caller established, with this node as the
  /// responder. Nothing is requested from the stream until the core has
  /// admitted it by its global and netgroup limits. Refusal is reported
  /// only by closing the stream.
  accept(transport: Transport) {
    if (this.destroyed || !transport.observedHost) return transport.close();
    this.open(transport, (connection) =>
      this.apply({
        kind: 'connectionOpened',
        connection,
        direction: { kind: 'inbound' },
        observedHost: transport.observedHost,
        localHost: transport.localHost,
      }),
    );
  }

  /// Connects to `endpoint`. Over a stream the caller established, this
  /// node is the initiator, the stream is closed unless it becomes the
  /// peer's session, and it must report the host its peer was observed at.
  /// With no stream the core dials, through the `dial` option. Rejects
  /// with an `IvyError`.
  async connect(endpoint: PeerEndpoint, over?: Transport, options: RequestOptions = {}): Promise<void> {
    if (over === undefined) return unwrap(await this.request({ kind: 'connect', endpoint }, options.signal));
    if (this.destroyed) {
      over.close();
      throw new IvyError('destroyed');
    }
    this.remember(endpoint);
    let result!: Promise<RequestResult>;
    this.open(over, (connection) => {
      result = this.request(
        {
          kind: 'connectOver',
          endpoint,
          connection,
          observedHost: over.observedHost,
          localHost: over.localHost,
        },
        options.signal,
      );
    });
    unwrap(await result);
  }

  /// The address a stream to `peer` was last opened at, by the `dial`
  /// option or handed to `connect` with it. Not one the core chose: it
  /// says where the peer was reached, not that it is there now.
  reachedAt(peer: PeerID): PeerEndpoint | undefined {
    return this.reached.get(peer);
  }

  private remember(endpoint: PeerEndpoint) {
    if (endpoint.port === 0) return;
    this.reached.delete(endpoint.publicKey);
    this.reached.set(endpoint.publicKey, endpoint);
    if (this.reached.size > maxReached) this.reached.delete(this.reached.keys().next().value!);
  }

  async connectViaRelay(endpoint: PeerEndpoint, options: RequestOptions = {}): Promise<void> {
    unwrap(await this.request({ kind: 'connectViaRelay', endpoint }, options.signal));
  }

  // MARK: - Peers

  get connectedPeers(): PeerID[] {
    return this.core.connectedPeers;
  }

  get connectedPeerEndpoints(): PeerEndpoint[] {
    return this.core.connectedPeerEndpoints;
  }

  get knownPeerEndpoints(): PeerEndpoint[] {
    return this.core.knownPeerEndpoints;
  }

  get peerConnectionCount(): number {
    return this.core.connectedPeers.length;
  }

  disconnect(peer: PeerID) {
    this.command({ kind: 'disconnect', peer });
  }

  /// Closes only the represented session. Configured peers reconnect
  /// automatically. A stale callback cannot close a replacement session.
  async recycleSession(peer: AuthenticatedPeer): Promise<boolean> {
    return flag(await this.request({ kind: 'recycleSession', peer }));
  }

  /// Permanently closes only the represented session.
  async disconnectSession(peer: AuthenticatedPeer): Promise<boolean> {
    return flag(await this.request({ kind: 'disconnectSession', peer }));
  }

  /// Tells the core the address this node is reachable at, or that none
  /// was found. It takes the first one it hears in a run.
  reportPublicAddress(address: Address | null) {
    this.apply({ kind: 'publicAddress', address });
  }

  // MARK: - Messages

  /// Sends to a peer, or only on the session given if it is still the
  /// peer's. `enqueued` means the local queue took it, not that it arrived.
  async sendMessage(
    to: PeerID | AuthenticatedPeer,
    topic: string,
    payload: Uint8Array,
  ): Promise<SendMessageResult> {
    const result = await this.request(
      isSession(to)
        ? { kind: 'sendOnSession', peer: to, topic, payload }
        : { kind: 'send', to, topic, payload },
    );
    return result.kind === 'send' ? result.result : { kind: 'notConnected' };
  }

  broadcastMessage(topic: string, payload: Uint8Array) {
    this.command({ kind: 'broadcast', topic, payload });
  }

  /// Waits until the live route to `to` can take another record. False
  /// when that route closes first. A session waits only on its own
  /// transport, never a replacement.
  async waitUntilWritable(to: PeerID | AuthenticatedPeer, options: RequestOptions = {}): Promise<boolean> {
    const result = await this.request(
      isSession(to)
        ? { kind: 'waitUntilSessionWritable', peer: to }
        : { kind: 'waitUntilWritable', peer: to },
      options.signal,
    );
    return result.kind === 'writable' && result.writable;
  }

  // MARK: - Content

  /// Fetches one complete Volume: from this node's own source, a known
  /// provider, a connected peer or fresh discovery, or from exactly the
  /// session in `options.from`. The caller validates what comes back.
  async fetchVolume(rootCID: string, options: FetchVolumeOptions = {}): Promise<VolumeResponse> {
    const limits = {
      rootCID,
      maximumArchiveBytes: size(options.maximumArchiveBytes),
      maximumEntries: size(options.maximumEntries),
    };
    const result = await this.request(
      options.from === undefined
        ? { kind: 'fetchVolume', ...limits }
        : { kind: 'fetchVolumeFrom', peer: options.from, ...limits },
      options.signal,
    );
    if (result.kind === 'volume') return result.response;
    return { rootCID: '', entries: new Map(), servedBy: null, failure: null };
  }

  /// Fetches the Volumes a peer bundles under `rootCID` with one request.
  /// Only the sessions named are asked, one at a time, until one sends a
  /// Volume.
  async fetchVolumeBundle(
    rootCID: string,
    from: AuthenticatedPeer[],
    options: RequestOptions = {},
  ): Promise<VolumeBundleResponse> {
    const result = await this.request({ kind: 'fetchVolumeBundle', rootCID, from }, options.signal);
    if (result.kind === 'volumeBundle') return result.response;
    return { volumes: [], noBundle: false, ended: false, failure: null };
  }

  reportDeficientContent(rootCID: string, servedBy: PeerID) {
    this.command({ kind: 'reportDeficientContent', rootCID, servedBy });
  }

  // MARK: - Discovery

  async findNode(target: string, options: RequestOptions = {}): Promise<PeerEndpoint[]> {
    return endpoints(await this.request({ kind: 'findNode', target }, options.signal));
  }

  /// `expiresAt` is in seconds since the Unix epoch.
  announceProvider(rootCID: string, expiresAt: number) {
    this.command({ kind: 'announceProvider', rootCID, expiresAt: BigInt(expiresAt) });
  }

  async discoverProviders(rootCID: string, options: RequestOptions = {}): Promise<PeerEndpoint[]> {
    return endpoints(await this.request({ kind: 'discoverProviders', rootCID }, options.signal));
  }

  providers(rootCID: string): PeerID[] {
    return this.core.providers(rootCID);
  }
}

/// A callback's error belongs to the application: it is thrown where the
/// host reports uncaught errors, not swallowed and not into the core.
function rethrowLater(error: unknown) {
  queueMicrotask(() => {
    throw error;
  });
}

function unwrap(result: RequestResult) {
  if (result.kind !== 'connect') throw new IvyError('notRunning');
  if (result.outcome.kind === 'failed') throw new IvyError(result.outcome.error);
  if (result.outcome.kind === 'cancelled') throw new IvyError('cancelled');
}

const flag = (result: RequestResult) => result.kind === 'flag' && result.flag;
const endpoints = (result: RequestResult) => (result.kind === 'endpoints' ? result.endpoints : []);
const size = (limit: number | undefined) => (limit === undefined ? unlimited : BigInt(limit));
