// Events and effects as bytes: the TypeScript half of docs/event-codec.md.
// Sources/IvyCore/EventCodec.swift is the other half, and test/vectors.json
// holds the two together.

export const version = 2;

/// A peer's Ed25519 public key as 64 lowercase hex digits.
export type PeerID = string;

export interface PeerEndpoint {
  publicKey: string;
  host: string;
  port: number;
}

export interface Address {
  host: string;
  port: number;
}

export type AuthenticatedRoute =
  | { kind: 'direct' }
  | { kind: 'relayed'; carrier: Uint8Array; routeID: Uint8Array };

/// One authenticated session. A replacement session for the same key has
/// another `sessionID`.
export interface AuthenticatedPeer {
  key: Uint8Array;
  role: 'endpoint' | 'carrier';
  route: AuthenticatedRoute;
  metadata: { listenAddresses: Address[]; maxFrameSize: number };
  sessionID: Uint8Array;
}

/// As Swift's `Duration.components`: both parts carry the sign.
export interface Duration {
  seconds: bigint;
  attoseconds: bigint;
}

export interface ContentEntry {
  cid: string;
  data: Uint8Array;
}

export interface PeerMessage {
  topic: string;
  payload: Uint8Array;
}

export type VolumeFetchFailure = 'callerBoundaryExceeded' | 'localCapacityUnavailable' | 'notSent';

export interface VolumeResponse {
  rootCID: string;
  entries: Map<string, Uint8Array>;
  servedBy: PeerID | null;
  failure: VolumeFetchFailure | null;
}

export interface VolumeBundleResponse {
  volumes: VolumeResponse[];
  noBundle: boolean;
  ended: boolean;
  failure: VolumeFetchFailure | null;
}

export type ConnectError =
  | 'notRunning'
  | 'invalidPeerKey'
  | 'peerOutsideMode'
  | 'connectionInProgress'
  | 'identityVerificationFailed'
  | 'noRelayAvailable'
  | 'streamHasNoObservedHost';

export type ConnectOutcome =
  | { kind: 'connected' }
  | { kind: 'failed'; error: ConnectError }
  | { kind: 'cancelled' };

export type SendMessageResult =
  | { kind: 'enqueued'; endpoint: PeerID; route: AuthenticatedRoute }
  | { kind: 'backpressured' }
  | { kind: 'notConnected' }
  | { kind: 'locallyRejected' };

// Sizes are 64 bits on the wire and so `bigint` here; `unlimited` is what
// the native shell passes as `Int.max`.
export const unlimited = 0x7fff_ffff_ffff_ffffn;

export type Request =
  | { kind: 'connect'; endpoint: PeerEndpoint }
  | {
      kind: 'connectOver';
      endpoint: PeerEndpoint;
      connection: bigint;
      observedHost: string | null;
      localHost: string | null;
    }
  | { kind: 'connectViaRelay'; endpoint: PeerEndpoint }
  | { kind: 'send'; to: PeerID; topic: string; payload: Uint8Array }
  | { kind: 'sendOnSession'; peer: AuthenticatedPeer; topic: string; payload: Uint8Array }
  | { kind: 'waitUntilWritable'; peer: PeerID }
  | { kind: 'waitUntilSessionWritable'; peer: AuthenticatedPeer }
  | { kind: 'fetchVolume'; rootCID: string; maximumArchiveBytes: bigint; maximumEntries: bigint }
  | {
      kind: 'fetchVolumeFrom';
      peer: AuthenticatedPeer;
      rootCID: string;
      maximumArchiveBytes: bigint;
      maximumEntries: bigint;
    }
  | { kind: 'fetchVolumeBundle'; rootCID: string; from: AuthenticatedPeer[] }
  | { kind: 'findNode'; target: string }
  | { kind: 'discoverProviders'; rootCID: string }
  | { kind: 'recycleSession'; peer: AuthenticatedPeer }
  | { kind: 'disconnectSession'; peer: AuthenticatedPeer }
  | {
      kind: 'fetchVolumeFromSessions';
      from: AuthenticatedPeer[];
      rootCID: string;
      maximumArchiveBytes: bigint;
      maximumEntries: bigint;
    };

export type Command =
  | { kind: 'disconnect'; peer: PeerID }
  | { kind: 'restartConfiguredSession'; peer: PeerID }
  | { kind: 'broadcast'; topic: string; payload: Uint8Array }
  | { kind: 'announceProvider'; rootCID: string; expiresAt: bigint }
  | { kind: 'reportDeficientContent'; rootCID: string; servedBy: PeerID }
  | { kind: 'setContentSource'; present: boolean }
  | { kind: 'setRelaying'; peer: PeerID; relays: boolean };

export type JobResult =
  | { kind: 'entries'; entries: ContentEntry[] }
  | { kind: 'roots'; roots: string[] }
  | { kind: 'authorized'; authorized: boolean };

export type ConnectionDirection = { kind: 'inbound' } | { kind: 'outbound'; dial: bigint };

export type Event =
  | { kind: 'start' }
  | { kind: 'stop' }
  | { kind: 'tick' }
  | {
      kind: 'connectionOpened';
      connection: bigint;
      direction: ConnectionDirection;
      observedHost: string | null;
      localHost: string | null;
    }
  | { kind: 'dialFailed'; dial: bigint }
  | { kind: 'received'; connection: bigint; bytes: Uint8Array }
  | { kind: 'writable'; connection: bigint }
  | { kind: 'closed'; connection: bigint }
  | { kind: 'request'; id: bigint; request: Request }
  | { kind: 'cancel'; id: bigint }
  | { kind: 'command'; command: Command }
  | { kind: 'delivered'; token: bigint }
  | { kind: 'jobFinished'; job: bigint; result: JobResult }
  | { kind: 'publicAddress'; address: Address | null };

export type Job =
  | { kind: 'readVolume'; rootCID: string; maxDataBytes: bigint }
  | { kind: 'readVolumeBundle'; rootCID: string }
  | { kind: 'authorizeVolume'; peer: AuthenticatedPeer; rootCID: string };

export type RequestResult =
  | { kind: 'connect'; outcome: ConnectOutcome }
  | { kind: 'send'; result: SendMessageResult }
  | { kind: 'writable'; writable: boolean }
  | { kind: 'volume'; response: VolumeResponse }
  | { kind: 'volumeBundle'; response: VolumeBundleResponse }
  | { kind: 'endpoints'; endpoints: PeerEndpoint[] }
  | { kind: 'flag'; flag: boolean };

export type Effect =
  | { kind: 'dial'; dial: bigint; endpoint: PeerEndpoint }
  | { kind: 'write'; connection: bigint; bytes: Uint8Array }
  | { kind: 'close'; connection: bigint }
  | { kind: 'pauseReading'; connection: bigint }
  | { kind: 'resumeReading'; connection: bigint }
  | { kind: 'deliver'; token: bigint; peer: AuthenticatedPeer; message: PeerMessage }
  | { kind: 'peerConnected'; token: bigint; peer: AuthenticatedPeer }
  | { kind: 'peerDisconnected'; peer: PeerID }
  | { kind: 'publicAddressDiscovered'; address: Address }
  | { kind: 'completed'; id: bigint; result: RequestResult }
  | { kind: 'startJob'; job: bigint; work: Job }
  | { kind: 'cancelJob'; job: bigint }
  | { kind: 'discoverPublicAddress' }
  | { kind: 'wakeAt'; deadline: Duration };

/// A node's configuration. Everything but the key may be left out and then
/// has `IvyConfig`'s default. Durations are in milliseconds.
export interface IvyConfig {
  /// The 32-byte Ed25519 seed.
  signingKey: Uint8Array;
  listenPort?: number;
  bootstrapPeers?: PeerEndpoint[];
  carriers?: PeerEndpoint[];
  relayEnabled?: boolean;
  mode?: { kind: 'overlay' } | { kind: 'privateNetwork' } | { kind: 'pinned'; peer: string };
  privateContentExchangeEnabled?: boolean;
  requestTimeout?: number;
  keepaliveInterval?: number;
  staleTimeout?: number;
  maxMissedPongs?: number;
  healthEnabled?: boolean;
  protocolMaxFrameSize?: number;
  maxConnections?: number;
  maxConnectionsPerNetgroup?: number;
  maxPendingRequests?: number;
  maxConcurrentContentRequests?: number;
  maxInboundBufferedBytes?: number;
  maxInFlightVolumeBytes?: number;
}

const connectErrors: ConnectError[] = [
  'notRunning',
  'invalidPeerKey',
  'peerOutsideMode',
  'connectionInProgress',
  'identityVerificationFailed',
  'noRelayAvailable',
  'streamHasNoObservedHost',
];
const failures: VolumeFetchFailure[] = ['callerBoundaryExceeded', 'localCapacityUnavailable', 'notSent'];
const keyLength = 32;
const attosecondsPerSecond = 1_000_000_000_000_000_000n;

const utf8 = new TextEncoder();
// A byte-order mark is part of the string, and bytes that are not UTF-8
// are an error, as on the Swift side.
const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });

export function hex(bytes: Uint8Array): string {
  let out = '';
  for (const byte of bytes) out += byte.toString(16).padStart(2, '0');
  return out;
}

export function fromHex(digits: string): Uint8Array {
  if (digits.length % 2 !== 0 || /[^0-9a-fA-F]/.test(digits)) throw new Error('not hex');
  const bytes = new Uint8Array(digits.length / 2);
  for (let index = 0; index < bytes.length; index++) {
    bytes[index] = parseInt(digits.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function compare(a: Uint8Array, b: Uint8Array): number {
  const shared = Math.min(a.length, b.length);
  for (let index = 0; index < shared; index++) {
    const difference = a[index]! - b[index]!;
    if (difference !== 0) return difference;
  }
  return a.length - b.length;
}

// MARK: - Writing

class Writer {
  private buffer = new Uint8Array(256);
  private view = new DataView(this.buffer.buffer);
  private length = 0;

  constructor() {
    this.uint8(version);
  }

  get bytes(): Uint8Array {
    return this.buffer.subarray(0, this.length);
  }

  /// Makes room for `count` more bytes and returns where they start. The
  /// buffer and its view may be replaced, so they are read only afterwards.
  private reserve(count: number): number {
    const start = this.length;
    this.length += count;
    if (this.length > this.buffer.length) {
      const grown = new Uint8Array(Math.max(this.length, this.buffer.length * 2));
      grown.set(this.buffer.subarray(0, start));
      this.buffer = grown;
      this.view = new DataView(grown.buffer);
    }
    return start;
  }

  // DataView wraps a value that does not fit; a port of 70000 is a mistake.
  private fits(value: number, bits: number): number {
    if (!Number.isInteger(value) || value < 0 || value >= 2 ** bits) {
      throw new RangeError(`${value} is not an unsigned ${bits}-bit integer`);
    }
    return value;
  }

  uint8(value: number) {
    const start = this.reserve(1);
    this.view.setUint8(start, this.fits(value, 8));
  }
  uint16(value: number) {
    const start = this.reserve(2);
    this.view.setUint16(start, this.fits(value, 16));
  }
  uint32(value: number) {
    const start = this.reserve(4);
    this.view.setUint32(start, this.fits(value, 32));
  }
  uint64(value: bigint) {
    const start = this.reserve(8);
    this.view.setBigUint64(start, value);
  }
  int64(value: bigint) {
    const start = this.reserve(8);
    this.view.setBigInt64(start, value);
  }
  bool(value: boolean) {
    this.uint8(value ? 1 : 0);
  }
  fixed(value: Uint8Array, length: number) {
    if (value.length !== length) throw new Error(`expected ${length} bytes, not ${value.length}`);
    const start = this.reserve(length);
    this.buffer.set(value, start);
  }
  data(value: Uint8Array) {
    this.uint32(value.length);
    const start = this.reserve(value.length);
    this.buffer.set(value, start);
  }
  string(value: string) {
    this.data(utf8.encode(value));
  }
  duration(value: Duration) {
    this.int64(value.seconds);
    this.int64(value.attoseconds);
  }
  optional<Value>(value: Value | null | undefined, write: (value: Value) => void) {
    if (value === null || value === undefined) return this.uint8(0);
    this.uint8(1);
    write(value);
  }
  list<Value>(values: readonly Value[], write: (value: Value) => void) {
    this.uint32(values.length);
    for (const value of values) write(value);
  }

  endpoint(value: PeerEndpoint) {
    this.string(value.publicKey);
    this.string(value.host);
    this.uint16(value.port);
  }
  address(value: Address) {
    this.string(value.host);
    this.uint16(value.port);
  }
  route(value: AuthenticatedRoute) {
    if (value.kind === 'direct') return this.uint8(0);
    this.uint8(1);
    this.fixed(value.carrier, keyLength);
    this.data(value.routeID);
  }
  peer(value: AuthenticatedPeer) {
    this.fixed(value.key, keyLength);
    this.uint8(value.role === 'endpoint' ? 0 : 1);
    this.route(value.route);
    this.list(value.metadata.listenAddresses, (address) => this.address(address));
    this.uint32(value.metadata.maxFrameSize);
    this.data(value.sessionID);
  }
  failure(value: VolumeFetchFailure | null) {
    this.optional(value, (failure) => this.uint8(failures.indexOf(failure)));
  }
  volume(value: VolumeResponse) {
    this.string(value.rootCID);
    // A map has insertion order; the encoding has byte order.
    const entries = [...value.entries].map(([cid, data]) => ({ cid: utf8.encode(cid), data }));
    entries.sort((a, b) => compare(a.cid, b.cid));
    this.list(entries, (entry) => {
      this.data(entry.cid);
      this.data(entry.data);
    });
    this.optional(value.servedBy, (peer) => this.string(peer));
    this.failure(value.failure);
  }

  event(value: Event) {
    switch (value.kind) {
      case 'start':
        return this.uint8(0);
      case 'stop':
        return this.uint8(1);
      case 'tick':
        return this.uint8(2);
      case 'connectionOpened':
        this.uint8(3);
        this.uint64(value.connection);
        if (value.direction.kind === 'inbound') {
          this.uint8(0);
        } else {
          this.uint8(1);
          this.uint64(value.direction.dial);
        }
        this.optional(value.observedHost, (host) => this.string(host));
        return this.optional(value.localHost, (host) => this.string(host));
      case 'dialFailed':
        this.uint8(4);
        return this.uint64(value.dial);
      case 'received':
        this.uint8(5);
        this.uint64(value.connection);
        return this.data(value.bytes);
      case 'writable':
        this.uint8(6);
        return this.uint64(value.connection);
      case 'closed':
        this.uint8(7);
        return this.uint64(value.connection);
      case 'request':
        this.uint8(8);
        this.uint64(value.id);
        return this.request(value.request);
      case 'cancel':
        this.uint8(9);
        return this.uint64(value.id);
      case 'command':
        this.uint8(10);
        return this.command(value.command);
      case 'delivered':
        this.uint8(11);
        return this.uint64(value.token);
      case 'jobFinished':
        this.uint8(12);
        this.uint64(value.job);
        return this.jobResult(value.result);
      case 'publicAddress':
        this.uint8(13);
        return this.optional(value.address, (address) => this.address(address));
    }
  }

  private jobResult(value: JobResult) {
    switch (value.kind) {
      case 'entries':
        this.uint8(0);
        return this.list(value.entries, (entry) => {
          this.string(entry.cid);
          this.data(entry.data);
        });
      case 'roots':
        this.uint8(1);
        return this.list(value.roots, (root) => this.string(root));
      case 'authorized':
        this.uint8(2);
        return this.bool(value.authorized);
    }
  }

  private request(value: Request) {
    switch (value.kind) {
      case 'connect':
        this.uint8(0);
        return this.endpoint(value.endpoint);
      case 'connectOver':
        this.uint8(1);
        this.endpoint(value.endpoint);
        this.uint64(value.connection);
        this.optional(value.observedHost, (host) => this.string(host));
        return this.optional(value.localHost, (host) => this.string(host));
      case 'connectViaRelay':
        this.uint8(2);
        return this.endpoint(value.endpoint);
      case 'send':
        this.uint8(3);
        this.string(value.to);
        this.string(value.topic);
        return this.data(value.payload);
      case 'sendOnSession':
        this.uint8(4);
        this.peer(value.peer);
        this.string(value.topic);
        return this.data(value.payload);
      case 'waitUntilWritable':
        this.uint8(5);
        return this.string(value.peer);
      case 'waitUntilSessionWritable':
        this.uint8(6);
        return this.peer(value.peer);
      case 'fetchVolume':
        this.uint8(7);
        this.string(value.rootCID);
        this.int64(value.maximumArchiveBytes);
        return this.int64(value.maximumEntries);
      case 'fetchVolumeFrom':
        this.uint8(8);
        this.peer(value.peer);
        this.string(value.rootCID);
        this.int64(value.maximumArchiveBytes);
        return this.int64(value.maximumEntries);
      case 'fetchVolumeBundle':
        this.uint8(9);
        this.string(value.rootCID);
        return this.list(value.from, (peer) => this.peer(peer));
      case 'findNode':
        this.uint8(10);
        return this.string(value.target);
      case 'discoverProviders':
        this.uint8(11);
        return this.string(value.rootCID);
      case 'recycleSession':
        this.uint8(12);
        return this.peer(value.peer);
      case 'disconnectSession':
        this.uint8(13);
        return this.peer(value.peer);
      case 'fetchVolumeFromSessions':
        this.uint8(14);
        this.list(value.from, (peer) => this.peer(peer));
        this.string(value.rootCID);
        this.int64(value.maximumArchiveBytes);
        return this.int64(value.maximumEntries);
    }
  }

  private command(value: Command) {
    switch (value.kind) {
      case 'disconnect':
        this.uint8(0);
        return this.string(value.peer);
      case 'restartConfiguredSession':
        this.uint8(1);
        return this.string(value.peer);
      case 'broadcast':
        this.uint8(2);
        this.string(value.topic);
        return this.data(value.payload);
      case 'announceProvider':
        this.uint8(3);
        this.string(value.rootCID);
        return this.uint64(value.expiresAt);
      case 'reportDeficientContent':
        this.uint8(4);
        this.string(value.rootCID);
        return this.string(value.servedBy);
      case 'setContentSource':
        this.uint8(5);
        return this.bool(value.present);
      case 'setRelaying':
        this.uint8(6);
        this.string(value.peer);
        return this.bool(value.relays);
    }
  }

  effect(value: Effect) {
    switch (value.kind) {
      case 'dial':
        this.uint8(0);
        this.uint64(value.dial);
        return this.endpoint(value.endpoint);
      case 'write':
        this.uint8(1);
        this.uint64(value.connection);
        return this.data(value.bytes);
      case 'close':
        this.uint8(2);
        return this.uint64(value.connection);
      case 'pauseReading':
        this.uint8(3);
        return this.uint64(value.connection);
      case 'resumeReading':
        this.uint8(4);
        return this.uint64(value.connection);
      case 'deliver':
        this.uint8(5);
        this.uint64(value.token);
        this.peer(value.peer);
        this.string(value.message.topic);
        return this.data(value.message.payload);
      case 'peerConnected':
        this.uint8(6);
        this.uint64(value.token);
        return this.peer(value.peer);
      case 'peerDisconnected':
        this.uint8(7);
        return this.string(value.peer);
      case 'publicAddressDiscovered':
        this.uint8(8);
        return this.address(value.address);
      case 'completed':
        this.uint8(9);
        this.uint64(value.id);
        return this.result(value.result);
      case 'startJob':
        this.uint8(10);
        this.uint64(value.job);
        return this.job(value.work);
      case 'cancelJob':
        this.uint8(11);
        return this.uint64(value.job);
      case 'discoverPublicAddress':
        return this.uint8(12);
      case 'wakeAt':
        this.uint8(13);
        return this.duration(value.deadline);
    }
  }

  private job(value: Job) {
    switch (value.kind) {
      case 'readVolume':
        this.uint8(0);
        this.string(value.rootCID);
        return this.int64(value.maxDataBytes);
      case 'readVolumeBundle':
        this.uint8(1);
        return this.string(value.rootCID);
      case 'authorizeVolume':
        this.uint8(2);
        this.peer(value.peer);
        return this.string(value.rootCID);
    }
  }

  private result(value: RequestResult) {
    switch (value.kind) {
      case 'connect':
        this.uint8(0);
        if (value.outcome.kind === 'connected') return this.uint8(0);
        if (value.outcome.kind === 'cancelled') return this.uint8(2);
        this.uint8(1);
        return this.uint8(connectErrors.indexOf(value.outcome.error));
      case 'send':
        this.uint8(1);
        this.uint8(
          ['enqueued', 'backpressured', 'notConnected', 'locallyRejected'].indexOf(value.result.kind),
        );
        if (value.result.kind !== 'enqueued') return;
        this.string(value.result.endpoint);
        return this.route(value.result.route);
      case 'writable':
        this.uint8(2);
        return this.bool(value.writable);
      case 'volume':
        this.uint8(3);
        return this.volume(value.response);
      case 'volumeBundle':
        this.uint8(4);
        this.list(value.response.volumes, (volume) => this.volume(volume));
        this.bool(value.response.noBundle);
        this.bool(value.response.ended);
        return this.failure(value.response.failure);
      case 'endpoints':
        this.uint8(5);
        return this.list(value.endpoints, (endpoint) => this.endpoint(endpoint));
      case 'flag':
        this.uint8(6);
        return this.bool(value.flag);
    }
  }
}

// MARK: - Reading

class Reader {
  private readonly view: DataView;
  private offset = 0;

  constructor(private readonly bytes: Uint8Array) {
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  get remaining(): number {
    return this.bytes.length - this.offset;
  }

  private take(count: number): number {
    if (count > this.remaining) throw new Error('truncated');
    const start = this.offset;
    this.offset += count;
    return start;
  }

  uint8(): number {
    return this.view.getUint8(this.take(1));
  }
  uint16(): number {
    return this.view.getUint16(this.take(2));
  }
  uint32(): number {
    return this.view.getUint32(this.take(4));
  }
  uint64(): bigint {
    return this.view.getBigUint64(this.take(8));
  }
  int64(): bigint {
    return this.view.getBigInt64(this.take(8));
  }
  bool(): boolean {
    const value = this.uint8();
    if (value > 1) throw new Error('not a Bool');
    return value === 1;
  }
  // A copy: the input may be the module's memory, which the next call into
  // the module is free to reuse or move.
  fixed(count: number): Uint8Array {
    const start = this.take(count);
    return this.bytes.slice(start, start + count);
  }
  data(): Uint8Array {
    return this.fixed(this.uint32());
  }
  string(): string {
    const count = this.uint32();
    const start = this.take(count);
    return text.decode(this.bytes.subarray(start, start + count));
  }
  duration(): Duration {
    const seconds = this.int64();
    const attoseconds = this.int64();
    const whole = attoseconds > -attosecondsPerSecond && attoseconds < attosecondsPerSecond;
    const sameSign = (seconds <= 0n || attoseconds >= 0n) && (seconds >= 0n || attoseconds <= 0n);
    if (!whole || !sameSign) throw new Error('not the components of a duration');
    return { seconds, attoseconds };
  }
  optional<Value>(read: () => Value): Value | null {
    return this.bool() ? read() : null;
  }
  list<Value>(read: () => Value): Value[] {
    const count = this.uint32();
    if (count > this.remaining) throw new Error('truncated');
    const values: Value[] = [];
    for (let index = 0; index < count; index++) values.push(read());
    return values;
  }
  private tag<Value>(values: readonly Value[]): Value {
    const value = values[this.uint8()];
    if (value === undefined) throw new Error('unknown tag');
    return value;
  }

  endpoint(): PeerEndpoint {
    return { publicKey: this.string(), host: this.string(), port: this.uint16() };
  }
  address(): Address {
    return { host: this.string(), port: this.uint16() };
  }
  private route(): AuthenticatedRoute {
    if (this.tag(['direct', 'relayed'] as const) === 'direct') return { kind: 'direct' };
    return { kind: 'relayed', carrier: this.fixed(keyLength), routeID: this.data() };
  }
  private peer(): AuthenticatedPeer {
    return {
      key: this.fixed(keyLength),
      role: this.tag(['endpoint', 'carrier'] as const),
      route: this.route(),
      metadata: {
        listenAddresses: this.list(() => this.address()),
        maxFrameSize: this.uint32(),
      },
      sessionID: this.data(),
    };
  }
  private failure(): VolumeFetchFailure | null {
    return this.optional(() => this.tag(failures));
  }
  private volume(): VolumeResponse {
    const rootCID = this.string();
    const entries = new Map<string, Uint8Array>();
    for (const entry of this.list(() => ({ cid: this.string(), data: this.data() }))) {
      if (entries.has(entry.cid)) throw new Error('an entry twice');
      entries.set(entry.cid, entry.data);
    }
    return {
      rootCID,
      entries,
      servedBy: this.optional(() => this.string()),
      failure: this.failure(),
    };
  }

  event(): Event {
    const tag = this.uint8();
    switch (tag) {
      case 0:
        return { kind: 'start' };
      case 1:
        return { kind: 'stop' };
      case 2:
        return { kind: 'tick' };
      case 3: {
        const connection = this.uint64();
        const direction: ConnectionDirection =
          this.tag(['inbound', 'outbound'] as const) === 'inbound'
            ? { kind: 'inbound' }
            : { kind: 'outbound', dial: this.uint64() };
        return {
          kind: 'connectionOpened',
          connection,
          direction,
          observedHost: this.optional(() => this.string()),
          localHost: this.optional(() => this.string()),
        };
      }
      case 4:
        return { kind: 'dialFailed', dial: this.uint64() };
      case 5:
        return { kind: 'received', connection: this.uint64(), bytes: this.data() };
      case 6:
        return { kind: 'writable', connection: this.uint64() };
      case 7:
        return { kind: 'closed', connection: this.uint64() };
      case 8:
        return { kind: 'request', id: this.uint64(), request: this.request() };
      case 9:
        return { kind: 'cancel', id: this.uint64() };
      case 10:
        return { kind: 'command', command: this.command() };
      case 11:
        return { kind: 'delivered', token: this.uint64() };
      case 12:
        return { kind: 'jobFinished', job: this.uint64(), result: this.jobResult() };
      case 13:
        return { kind: 'publicAddress', address: this.optional(() => this.address()) };
      default:
        throw new Error(`unknown event ${tag}`);
    }
  }

  private jobResult(): JobResult {
    const tag = this.uint8();
    switch (tag) {
      case 0:
        return {
          kind: 'entries',
          entries: this.list(() => ({ cid: this.string(), data: this.data() })),
        };
      case 1:
        return { kind: 'roots', roots: this.list(() => this.string()) };
      case 2:
        return { kind: 'authorized', authorized: this.bool() };
      default:
        throw new Error(`unknown job result ${tag}`);
    }
  }

  private request(): Request {
    const tag = this.uint8();
    switch (tag) {
      case 0:
        return { kind: 'connect', endpoint: this.endpoint() };
      case 1:
        return {
          kind: 'connectOver',
          endpoint: this.endpoint(),
          connection: this.uint64(),
          observedHost: this.optional(() => this.string()),
          localHost: this.optional(() => this.string()),
        };
      case 2:
        return { kind: 'connectViaRelay', endpoint: this.endpoint() };
      case 3:
        return { kind: 'send', to: this.string(), topic: this.string(), payload: this.data() };
      case 4:
        return {
          kind: 'sendOnSession',
          peer: this.peer(),
          topic: this.string(),
          payload: this.data(),
        };
      case 5:
        return { kind: 'waitUntilWritable', peer: this.string() };
      case 6:
        return { kind: 'waitUntilSessionWritable', peer: this.peer() };
      case 7:
        return {
          kind: 'fetchVolume',
          rootCID: this.string(),
          maximumArchiveBytes: this.int64(),
          maximumEntries: this.int64(),
        };
      case 8:
        return {
          kind: 'fetchVolumeFrom',
          peer: this.peer(),
          rootCID: this.string(),
          maximumArchiveBytes: this.int64(),
          maximumEntries: this.int64(),
        };
      case 9:
        return {
          kind: 'fetchVolumeBundle',
          rootCID: this.string(),
          from: this.list(() => this.peer()),
        };
      case 10:
        return { kind: 'findNode', target: this.string() };
      case 11:
        return { kind: 'discoverProviders', rootCID: this.string() };
      case 12:
        return { kind: 'recycleSession', peer: this.peer() };
      case 13:
        return { kind: 'disconnectSession', peer: this.peer() };
      case 14:
        return {
          kind: 'fetchVolumeFromSessions',
          from: this.list(() => this.peer()),
          rootCID: this.string(),
          maximumArchiveBytes: this.int64(),
          maximumEntries: this.int64(),
        };
      default:
        throw new Error(`unknown request ${tag}`);
    }
  }

  private command(): Command {
    const tag = this.uint8();
    switch (tag) {
      case 0:
        return { kind: 'disconnect', peer: this.string() };
      case 1:
        return { kind: 'restartConfiguredSession', peer: this.string() };
      case 2:
        return { kind: 'broadcast', topic: this.string(), payload: this.data() };
      case 3:
        return { kind: 'announceProvider', rootCID: this.string(), expiresAt: this.uint64() };
      case 4:
        return {
          kind: 'reportDeficientContent',
          rootCID: this.string(),
          servedBy: this.string(),
        };
      case 5:
        return { kind: 'setContentSource', present: this.bool() };
      case 6:
        return { kind: 'setRelaying', peer: this.string(), relays: this.bool() };
      default:
        throw new Error(`unknown command ${tag}`);
    }
  }

  effect(): Effect {
    const tag = this.uint8();
    switch (tag) {
      case 0:
        return { kind: 'dial', dial: this.uint64(), endpoint: this.endpoint() };
      case 1:
        return { kind: 'write', connection: this.uint64(), bytes: this.data() };
      case 2:
        return { kind: 'close', connection: this.uint64() };
      case 3:
        return { kind: 'pauseReading', connection: this.uint64() };
      case 4:
        return { kind: 'resumeReading', connection: this.uint64() };
      case 5:
        return {
          kind: 'deliver',
          token: this.uint64(),
          peer: this.peer(),
          message: { topic: this.string(), payload: this.data() },
        };
      case 6:
        return { kind: 'peerConnected', token: this.uint64(), peer: this.peer() };
      case 7:
        return { kind: 'peerDisconnected', peer: this.string() };
      case 8:
        return { kind: 'publicAddressDiscovered', address: this.address() };
      case 9:
        return { kind: 'completed', id: this.uint64(), result: this.result() };
      case 10:
        return { kind: 'startJob', job: this.uint64(), work: this.job() };
      case 11:
        return { kind: 'cancelJob', job: this.uint64() };
      case 12:
        return { kind: 'discoverPublicAddress' };
      case 13:
        return { kind: 'wakeAt', deadline: this.duration() };
      default:
        throw new Error(`unknown effect ${tag}`);
    }
  }

  private job(): Job {
    const tag = this.uint8();
    switch (tag) {
      case 0:
        return { kind: 'readVolume', rootCID: this.string(), maxDataBytes: this.int64() };
      case 1:
        return { kind: 'readVolumeBundle', rootCID: this.string() };
      case 2:
        return { kind: 'authorizeVolume', peer: this.peer(), rootCID: this.string() };
      default:
        throw new Error(`unknown job ${tag}`);
    }
  }

  private result(): RequestResult {
    const tag = this.uint8();
    switch (tag) {
      case 0: {
        const outcome = this.tag(['connected', 'failed', 'cancelled'] as const);
        if (outcome !== 'failed') return { kind: 'connect', outcome: { kind: outcome } };
        return { kind: 'connect', outcome: { kind: 'failed', error: this.tag(connectErrors) } };
      }
      case 1: {
        const sent = this.tag(['enqueued', 'backpressured', 'notConnected', 'locallyRejected'] as const);
        if (sent !== 'enqueued') return { kind: 'send', result: { kind: sent } };
        return {
          kind: 'send',
          result: { kind: 'enqueued', endpoint: this.string(), route: this.route() },
        };
      }
      case 2:
        return { kind: 'writable', writable: this.bool() };
      case 3:
        return { kind: 'volume', response: this.volume() };
      case 4:
        return {
          kind: 'volumeBundle',
          response: {
            volumes: this.list(() => this.volume()),
            noBundle: this.bool(),
            ended: this.bool(),
            failure: this.failure(),
          },
        };
      case 5:
        return { kind: 'endpoints', endpoints: this.list(() => this.endpoint()) };
      case 6:
        return { kind: 'flag', flag: this.bool() };
      default:
        throw new Error(`unknown result ${tag}`);
    }
  }
}

function decode<Value>(bytes: Uint8Array, read: (reader: Reader) => Value): Value {
  const reader = new Reader(bytes);
  if (reader.uint8() !== version) throw new Error('unknown codec version');
  const value = read(reader);
  if (reader.remaining !== 0) throw new Error('bytes after the end');
  return value;
}

function encode(write: (writer: Writer) => void): Uint8Array {
  const writer = new Writer();
  write(writer);
  return writer.bytes;
}

// Decoding throws on bytes that are not an encoding.

export const encodeEvent = (event: Event) => encode((writer) => writer.event(event));
export const decodeEvent = (bytes: Uint8Array) => decode(bytes, (reader) => reader.event());
export const encodeEffect = (effect: Effect) => encode((writer) => writer.effect(effect));
export const decodeEffect = (bytes: Uint8Array) => decode(bytes, (reader) => reader.effect());
/// What one step returned, in order.
export const decodeEffects = (bytes: Uint8Array) =>
  decode(bytes, (reader) => reader.list(() => reader.effect()));
export const decodePeers = (bytes: Uint8Array) =>
  decode(bytes, (reader) => reader.list(() => reader.string()));
export const decodeEndpoints = (bytes: Uint8Array) =>
  decode(bytes, (reader) => reader.list(() => reader.endpoint()));

export function milliseconds(value: number): Duration {
  const nanoseconds = BigInt(Math.round(value * 1e6));
  return {
    seconds: nanoseconds / 1_000_000_000n,
    attoseconds: (nanoseconds % 1_000_000_000n) * 1_000_000_000n,
  };
}

export function encodeConfig(config: IvyConfig): Uint8Array {
  return encode((writer) => {
    writer.fixed(config.signingKey, 32);
    writer.optional(config.listenPort, (port) => writer.uint16(port));
    writer.optional(config.bootstrapPeers, (peers) =>
      writer.list(peers, (peer) => writer.endpoint(peer)),
    );
    writer.optional(config.carriers, (peers) => writer.list(peers, (peer) => writer.endpoint(peer)));
    writer.optional(config.relayEnabled, (enabled) => writer.bool(enabled));
    writer.optional(config.mode, (mode) => {
      writer.uint8(['overlay', 'privateNetwork', 'pinned'].indexOf(mode.kind));
      if (mode.kind === 'pinned') writer.string(mode.peer);
    });
    writer.optional(config.privateContentExchangeEnabled, (enabled) => writer.bool(enabled));
    for (const duration of [config.requestTimeout, config.keepaliveInterval, config.staleTimeout]) {
      writer.optional(duration, (value) => writer.duration(milliseconds(value)));
    }
    writer.optional(config.maxMissedPongs, (count) => writer.int64(BigInt(count)));
    writer.optional(config.healthEnabled, (enabled) => writer.bool(enabled));
    writer.optional(config.protocolMaxFrameSize, (size) => writer.uint32(size));
    for (const limit of [
      config.maxConnections,
      config.maxConnectionsPerNetgroup,
      config.maxPendingRequests,
      config.maxConcurrentContentRequests,
      config.maxInboundBufferedBytes,
      config.maxInFlightVolumeBytes,
    ]) {
      writer.optional(limit, (value) => writer.int64(BigInt(value)));
    }
  });
}
