// Two transports joined in memory, for tests and demos.

import type { Transport, TransportSink } from './transport.js';

export interface MemoryPairOptions {
  /// Bytes one direction holds before it reports itself full. Bytes sent
  /// past it are still queued, as on any transport.
  capacity?: number;
  /// The most one read delivers.
  readSize?: number;
  /// The host each end observes its peer at.
  hosts?: [string, string];
}

export class MemoryTransport implements Transport {
  readonly localHost = null;
  /// How many times bytes were asked for.
  requests = 0;
  /** @internal */
  peer!: MemoryTransport;

  private sink: TransportSink | null = null;
  private readonly unread: Uint8Array[] = [];
  private unreadBytes = 0;
  private wanted = false;
  private delivering = false;
  private state: 'open' | 'closing' | 'closed' = 'open';

  /** @internal */
  constructor(
    readonly observedHost: string,
    private readonly capacity: number,
    private readonly readSize: number,
  ) {}

  /// Bytes sent from this end that the other has not read.
  get queuedBytes(): number {
    return this.peer.unreadBytes;
  }

  get isWritable(): boolean {
    return this.queuedBytes < this.capacity;
  }

  attach(sink: TransportSink) {
    this.sink = sink;
    this.pump();
  }

  requestBytes() {
    this.requests += 1;
    this.wanted = true;
    this.pump();
  }

  send(bytes: Uint8Array) {
    if (this.state !== 'open' || this.peer.state === 'closed') return;
    this.peer.unread.push(bytes);
    this.peer.unreadBytes += bytes.length;
    this.peer.pump();
  }

  close() {
    if (this.state === 'closed') return;
    // What this end had not read is dropped; what it sent is still read.
    this.unread.length = 0;
    this.unreadBytes = 0;
    this.state = 'closed';
    this.pump();
    if (this.peer.state === 'open') {
      this.peer.state = 'closing';
      this.peer.pump();
    }
  }

  /// Delivers what is due, never inside the call that made it due.
  private pump() {
    if (this.delivering || this.sink === null) return;
    const due =
      this.state === 'closed' ||
      (this.wanted && this.unread.length > 0) ||
      (this.state === 'closing' && this.unread.length === 0);
    if (!due) return;
    this.delivering = true;
    queueMicrotask(() => {
      this.delivering = false;
      const sink = this.sink;
      if (sink === null) return;
      if (this.state === 'closed' || this.unread.length === 0) {
        if (this.state === 'open') return;
        this.state = 'closed';
        this.sink = null;
        return sink.closed();
      }
      if (!this.wanted) return;
      this.wanted = false;
      const wasFull = !this.peer.isWritable;
      const head = this.unread[0]!;
      const bytes = head.subarray(0, this.readSize);
      if (bytes.length === head.length) {
        this.unread.shift();
      } else {
        this.unread[0] = head.subarray(bytes.length);
      }
      this.unreadBytes -= bytes.length;
      // A copy, so the reader does not hold the writer's whole array.
      sink.received(bytes.slice());
      if (wasFull && this.peer.isWritable) this.peer.sink?.drained();
      this.pump();
    });
  }
}

/// Two ends of one stream: what either sends, the other reads.
export function memoryPair(options: MemoryPairOptions = {}): [MemoryTransport, MemoryTransport] {
  const capacity = options.capacity ?? 1024 * 1024;
  const readSize = options.readSize ?? 64 * 1024;
  const [left, right] = options.hosts ?? ['8.8.1.1', '8.8.2.1'];
  const a = new MemoryTransport(right, capacity, readSize);
  const b = new MemoryTransport(left, capacity, readSize);
  a.peer = b;
  b.peer = a;
  return [a, b];
}
