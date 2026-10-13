// A Transport over the standard WebSocket, the one a browser and Node both
// have. The counterpart of Sources/IvyWebSocket/WebSocketStream.swift, and
// what a page uses to reach a node listening with `WebSocketTransport`.

import type { PeerEndpoint } from './codec.js';
import type { Transport, TransportSink } from './transport.js';

/// The largest message sent and the most one read delivers. A node accepts
/// frames up to 1 MiB and sends none larger than this.
const maxMessage = 64 * 1024;
/// Bytes the socket has not sent at which the stream stops reporting itself
/// writable, and the level it must fall to before it says so again. The
/// native streams use the same two.
const highWaterMark = 64 * 1024;
const lowWaterMark = 32 * 1024;
/// How long a full socket is looked at every turn of the event loop before
/// it is looked at on a timer instead.
/// What may wait unread before the stream is closed. It is the core's own
/// budget for Volumes in flight, so a peer answering what it was asked never
/// reaches it; one that keeps sending while it is not being read does.
export const webSocketQueueLimit = 128 * 1024 * 1024;
const drainSpinMilliseconds = 50;
const drainPollMilliseconds = 10;

/// Ivy frames its own records, so the socket is only an ordered byte stream:
/// binary messages are concatenated as they arrive, and where one ends means
/// nothing. A text message closes the stream, as it does at a node.
///
/// A WebSocket here cannot be paused: every message is handed to `onmessage`
/// as it arrives, and TCP flow control does not reach that far. What arrives
/// before it is asked for is held in a queue. The core stops asking for
/// bytes on a connection it is holding back, but the browser keeps
/// receiving, so the queue holds whatever the peer sends faster than the
/// core takes it. A peer cannot be slowed, only dropped: the stream closes
/// when the queue passes `queueLimit`.
export class WebSocketTransport implements Transport {
  readonly localHost = null;
  readonly observedHost: string;

  private sink: TransportSink | null = null;
  private readonly unread: Uint8Array[] = [];
  private unreadBytes = 0;
  private wanted = false;
  private delivering = false;
  private watchingDrain = false;
  /// `ended`: the socket has closed and what it delivered is still to read.
  private state: 'open' | 'ended' | 'closed' = 'open';

  /// `socket` must be open.
  constructor(
    private readonly socket: WebSocket,
    private readonly queueLimit = webSocketQueueLimit,
  ) {
    socket.binaryType = 'arraybuffer';
    // The host as the URL names it, without an IPv6 literal's brackets. A
    // browser does not say which address a name resolved to, so a name is
    // its own netgroup.
    this.observedHost = new URL(socket.url).hostname.replace(/^\[|\]$/g, '');
    socket.addEventListener('message', (event: MessageEvent) => {
      if (this.state !== 'open') return;
      if (!(event.data instanceof ArrayBuffer)) return this.close();
      if (event.data.byteLength === 0) return;
      this.unread.push(new Uint8Array(event.data));
      this.unreadBytes += event.data.byteLength;
      if (this.unreadBytes > this.queueLimit) return this.close();
      this.pump();
    });
    const ended = () => {
      if (this.state !== 'open') return;
      this.state = 'ended';
      this.pump();
    };
    socket.addEventListener('close', ended);
    socket.addEventListener('error', () => {
      socket.close();
      ended();
    });
    if (socket.readyState !== WebSocket.OPEN) ended();
  }

  get isWritable(): boolean {
    return this.socket.bufferedAmount < highWaterMark;
  }

  attach(sink: TransportSink) {
    this.sink = sink;
    this.pump();
  }

  requestBytes() {
    this.wanted = true;
    this.pump();
  }

  send(bytes: Uint8Array) {
    if (this.state !== 'open' || this.socket.readyState !== WebSocket.OPEN) return;
    for (let at = 0; at < bytes.length; at += maxMessage) {
      this.socket.send(bytes.subarray(at, at + maxMessage));
    }
    if (!this.isWritable) this.watchDrain();
  }

  close() {
    if (this.state === 'closed') return;
    // What had not been read is dropped.
    this.unread.length = 0;
    this.unreadBytes = 0;
    this.state = 'closed';
    this.socket.close();
    this.pump();
  }

  /// Delivers what is due, never inside the call that made it due.
  private pump() {
    if (this.delivering || this.sink === null) return;
    const due = this.state !== 'open' ? this.wanted || this.unread.length === 0 : this.wanted && this.unread.length > 0;
    if (!due) return;
    this.delivering = true;
    queueMicrotask(() => {
      this.delivering = false;
      const sink = this.sink;
      if (sink === null) return;
      const head = this.unread[0];
      if (head === undefined) {
        if (this.state === 'open') return;
        // Everything the socket delivered has been read, or was dropped.
        this.state = 'closed';
        this.sink = null;
        return sink.closed();
      }
      if (!this.wanted) return;
      this.wanted = false;
      const bytes = head.subarray(0, maxMessage);
      this.unreadBytes -= bytes.length;
      if (bytes.length === head.length) {
        this.unread.shift();
      } else {
        this.unread[0] = head.subarray(bytes.length);
      }
      sink.received(bytes);
      this.pump();
    });
  }

  /// A WebSocket has no drain event, so `bufferedAmount` is looked at until
  /// it falls to the low mark. First every turn of the event loop, which a
  /// socket to a fast peer needs only a few of; then on a timer, so a slow
  /// one does not spin. A browser slows timers in a tab that is not showing
  /// to one a second, so there a socket that stays full that long is told it
  /// has room once a second.
  private watchDrain() {
    if (this.watchingDrain) return;
    this.watchingDrain = true;
    const started = performance.now();
    const channel = new MessageChannel();
    const look = () => {
      if (this.state === 'open' && this.socket.readyState === WebSocket.OPEN) {
        if (this.socket.bufferedAmount >= lowWaterMark) {
          if (performance.now() - started < drainSpinMilliseconds) channel.port2.postMessage(null);
          else setTimeout(look, drainPollMilliseconds);
          return;
        }
        this.sink?.drained();
      }
      this.watchingDrain = false;
      channel.port1.close();
    };
    channel.port1.onmessage = look;
    look();
  }
}

/// Opens a WebSocket to `url`, a node's `ws://host:port/ivy` or the `wss`
/// address in front of it. Rejects when it does not open.
export function connectWebSocket(url: string | URL): Promise<WebSocketTransport> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    // The transport is made before any message of the socket is dispatched.
    socket.onopen = () => resolve(new WebSocketTransport(socket));
    // Not every WebSocket follows an error with a close: either rejects.
    socket.onerror = socket.onclose = () => reject(new Error(`WebSocket to ${socket.url} did not open`));
  });
}

/// A `dial` for `IvyOptions` that reaches endpoints over WebSocket. `urlFor`
/// says where an endpoint is listening, or `null` when it cannot be reached
/// this way, which fails the dial.
export function webSocketDialer(
  urlFor: (endpoint: PeerEndpoint) => string | URL | null,
): (endpoint: PeerEndpoint) => Promise<Transport> {
  return async (endpoint) => {
    const url = urlFor(endpoint);
    if (url === null) throw new Error(`no WebSocket address for ${endpoint.host}:${endpoint.port}`);
    return connectWebSocket(url);
  };
}
