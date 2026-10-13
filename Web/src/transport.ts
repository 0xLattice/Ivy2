// What Ivy needs of a byte stream, and the translation between one and the
// core's events and effects. The counterpart of TransportConnection.swift
// and of the adapter in StreamShell.swift.

import type { Event } from './codec.js';

/// Receives everything a `Transport` produces.
export interface TransportSink {
  /// The bytes one `requestBytes()` asked for, in stream order, and no more
  /// than one read of the stream's own: Ivy holds a delivery unreserved
  /// until it is decoded, so the read size is what bounds it. The sink
  /// keeps the array.
  received(bytes: Uint8Array): void;
  /// The stream has room again after `isWritable` was false.
  drained(): void;
  /// The stream ended, whichever side closed it. Reported exactly once;
  /// nothing follows.
  closed(): void;
}

/// An ordered, reliable byte stream to one peer: a WebSocket, a WebRTC data
/// channel, or the in-memory pair in memory.ts. Framing, byte budgets,
/// admission, the handshake and sessions are all above it. Whoever
/// establishes the stream hands it to `Ivy.accept` or `Ivy.connect`.
///
/// A stream whose platform pushes messages at it (both of the above) holds
/// them until they are asked for, and that buffer is what a slow consumer
/// fills; where the platform allows, it stops the sender when it is full.
export interface Transport {
  /// Address the peer was observed at, which netgroup admission keys on.
  /// Ivy refuses a stream without one.
  readonly observedHost: string | null;
  /// Local address the stream is bound to, if it has one.
  readonly localHost: string | null;
  /// Whether the stream has room for more. It must already count bytes
  /// passed to `send`: Ivy reads it straight after sending.
  readonly isWritable: boolean;

  /// Installs the sink. A stream that has already closed reports that.
  attach(sink: TransportSink): void;
  /// Asks for the next bytes. Each call permits one `received`, and nothing
  /// is delivered that was not asked for. The delivery may happen before
  /// this call returns.
  requestBytes(): void;
  /// Sends already-framed bytes in order, and keeps the array. Bytes sent
  /// while the stream is not writable are still queued; `isWritable` is the
  /// signal to stop.
  send(bytes: Uint8Array): void;
  /// Closes the stream. May be called more than once; the sink hears
  /// `closed()` exactly once.
  close(): void;
}

/// One stream's side of the conversation with the core.
///
/// The stream is asked for bytes only while the core wants it read, one
/// request at a time: the next is made once the core has handled the bytes
/// of the last. A connection the core is holding back is therefore not
/// read, and its transport holds the sender.
export class Connection implements TransportSink {
  /// The core wants this connection read.
  private wantsRead = false;
  /// Bytes were asked for, or are with the core and not yet handled.
  private readOutstanding = false;
  /// Bytes written since the core was last told `writable`. The core keeps
  /// the same count and stops writing past its high-water mark, so that is
  /// when it needs to hear again.
  private writtenSinceWritable = 0;
  private owesWritable = false;

  constructor(
    readonly id: bigint,
    readonly transport: Transport,
    private readonly highWaterMark: number,
    private readonly post: (event: Event) => void,
    private readonly forget: (id: bigint) => boolean,
  ) {}

  setReading(reading: boolean) {
    this.wantsRead = reading;
    if (!reading || this.readOutstanding) return;
    this.readOutstanding = true;
    this.transport.requestBytes();
  }

  /// The core has handled the bytes of the last read.
  readProcessed() {
    if (this.wantsRead) {
      this.transport.requestBytes();
    } else {
      this.readOutstanding = false;
    }
  }

  write(bytes: Uint8Array) {
    this.transport.send(bytes);
    this.writtenSinceWritable += bytes.length;
    if (this.writtenSinceWritable <= this.highWaterMark) return;
    // The core now holds its writes. It may resume as soon as the stream
    // has room, which may be at once.
    if (!this.transport.isWritable) {
      this.owesWritable = true;
      return;
    }
    this.writtenSinceWritable = 0;
    this.post({ kind: 'writable', connection: this.id });
  }

  close() {
    this.transport.close();
  }

  received(bytes: Uint8Array) {
    // Nothing to hand over: the request is spent, so ask again.
    if (bytes.length === 0) return this.readProcessed();
    this.post({ kind: 'received', connection: this.id, bytes });
  }

  drained() {
    if (!this.owesWritable) return;
    this.owesWritable = false;
    this.writtenSinceWritable = 0;
    this.post({ kind: 'writable', connection: this.id });
  }

  closed() {
    if (this.forget(this.id)) this.post({ kind: 'closed', connection: this.id });
  }
}
