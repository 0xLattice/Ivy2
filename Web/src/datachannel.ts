// A Transport over a WebRTC data channel.
//
// A data channel pushes messages at its receiver and cannot be paused, so
// nothing holds a sender back the way TCP does. This adapter adds what is
// missing: every data-channel message starts with a type byte, and a sender
// holds at most `dataChannelWindow` bytes the receiver has not granted back.
//
//   0x00, then 1 to 16 383 bytes of the stream     data
//   0x01, then a big-endian u32, not zero          credit: that many more
//                                                  bytes may be sent
//
// Each end starts with a whole window of credit. The receiver grants back
// what the shell has taken from it, so what it holds unread never exceeds
// the window; a peer that sends past its credit is closed.

import type { Transport, TransportSink } from './transport.js';

/// What this needs of an `RTCDataChannel`, which is one. The channel must be
/// ordered and reliable.
export interface DataChannel {
  binaryType: string;
  readonly readyState: string;
  readonly bufferedAmount: number;
  bufferedAmountLowThreshold: number;
  send(data: Uint8Array<ArrayBuffer>): void;
  close(): void;
  addEventListener(type: string, listener: (event: any) => void): void;
}

/// Bytes a sender may have outstanding, and so the most a receiver holds
/// unread. A sender regains credit once per round trip at best, so the
/// window is what one round trip can carry: 1 MiB keeps a 100 ms path above
/// 10 MiB/s, and is what one slow peer can make a page hold.
export const dataChannelWindow = 1024 * 1024;
/// The largest data-channel message every browser exchanges with every
/// other, type byte included.
export const dataChannelMessageSize = 16 * 1024;

const readSize = 64 * 1024;
/// Consumed bytes are granted back a quarter of the window at a time.
const grantSize = dataChannelWindow / 4;
/// The channel's own send buffer is filled to the first and refilled from
/// the second. Browsers close a channel whose buffer passes 16 MiB.
const bufferHighWaterMark = 256 * 1024;
const bufferLowWaterMark = 64 * 1024;

const typeData = 0;
const typeCredit = 1;

export class DataChannelTransport implements Transport {
  readonly localHost = null;
  /// Called once when the stream has closed, whether or not a sink is
  /// attached: whoever owns the peer connection closes it then.
  onClosed: (() => void) | null = null;

  private sink: TransportSink | null = null;
  /// `closing`: the channel has closed and bytes it delivered are unread.
  private state: 'open' | 'closing' | 'closed' = 'open';
  private reported = false;

  /// Sent bytes waiting for credit or for room in the channel's buffer.
  private readonly unsent: Uint8Array[] = [];
  /// Bytes the peer will still take.
  private credit = dataChannelWindow;
  /// The stream was full, and the sink has not been told it has room.
  private full = false;

  /// Arrived bytes not yet asked for, copied into blocks of one read each so
  /// that many small messages cost no more memory than their bytes. Every
  /// block but the last is full.
  private readonly unread: Uint8Array[] = [];
  private lastBlockLength = 0;
  private unreadBytes = 0;
  /// Bytes the peer may still send.
  private allowance = dataChannelWindow;
  /// Bytes handed to the sink and not yet granted back.
  private consumed = 0;
  private wanted = false;
  private delivering = false;

  /// `observedHost` is the address the peer was observed at: the remote
  /// address of the selected ICE candidate pair. It may be set after the
  /// transport is made, and must be before the transport is handed to Ivy.
  constructor(
    private readonly channel: DataChannel,
    public observedHost: string | null = null,
  ) {
    channel.binaryType = 'arraybuffer';
    channel.bufferedAmountLowThreshold = bufferLowWaterMark;
    channel.addEventListener('message', (event) => this.message(event.data));
    channel.addEventListener('open', () => this.resume());
    channel.addEventListener('bufferedamountlow', () => this.resume());
    channel.addEventListener('close', () => this.channelClosed());
    channel.addEventListener('error', () => this.close());
    if (channel.readyState === 'closing' || channel.readyState === 'closed') this.state = 'closed';
  }

  /// Bytes that arrived and have not been asked for.
  get queuedBytes(): number {
    return this.unreadBytes;
  }

  get isWritable(): boolean {
    return (
      this.state === 'open' &&
      this.unsent.length === 0 &&
      this.credit > 0 &&
      this.channel.bufferedAmount <= bufferHighWaterMark
    );
  }

  attach(sink: TransportSink) {
    this.sink = sink;
    if (this.state === 'closed') this.report();
    else this.pump();
  }

  requestBytes() {
    this.wanted = true;
    this.pump();
  }

  send(bytes: Uint8Array) {
    if (this.state !== 'open' || bytes.length === 0) return;
    this.unsent.push(bytes);
    this.flush();
  }

  /// Bytes still waiting for credit are dropped, as a closed socket drops
  /// what it had not sent; what the channel took, it sends before it closes.
  close() {
    if (this.state === 'closed') return;
    this.unsent.length = 0;
    this.unread.length = 0;
    this.unreadBytes = 0;
    this.channel.close();
    this.finish();
  }

  // MARK: - Sending

  /// Moves what was sent into the channel, as far as credit and the
  /// channel's buffer allow.
  private flush() {
    const open = this.channel.readyState === 'open';
    while (open && this.unsent.length > 0 && this.credit > 0 && this.channel.bufferedAmount <= bufferHighWaterMark) {
      const head = this.unsent[0]!;
      const length = Math.min(head.length, dataChannelMessageSize - 1, this.credit);
      const message = new Uint8Array(1 + length);
      message[0] = typeData;
      message.set(head.subarray(0, length), 1);
      if (length === head.length) this.unsent.shift();
      else this.unsent[0] = head.subarray(length);
      this.credit -= length;
      this.channel.send(message);
    }
    if (!this.isWritable) this.full = true;
  }

  /// Credit or buffer room arrived.
  private resume() {
    this.flush();
    if (!this.full || !this.isWritable) return;
    this.full = false;
    this.sink?.drained();
  }

  // MARK: - Receiving

  private message(data: unknown) {
    if (this.state !== 'open') return;
    if (!(data instanceof ArrayBuffer) || data.byteLength < 2 || data.byteLength > dataChannelMessageSize) {
      return this.close();
    }
    const bytes = new Uint8Array(data);
    if (bytes[0] === typeData) {
      const payload = bytes.subarray(1);
      // More than was granted: the bound on `unread` is gone.
      if (payload.length > this.allowance) return this.close();
      this.allowance -= payload.length;
      this.hold(payload);
      this.pump();
    } else if (bytes[0] === typeCredit && bytes.length === 5) {
      const grant = new DataView(data).getUint32(1);
      // A grant is for bytes that were sent, so credit never passes a window.
      if (grant === 0 || grant > dataChannelWindow - this.credit) return this.close();
      this.credit += grant;
      this.resume();
    } else {
      this.close();
    }
  }

  private hold(payload: Uint8Array) {
    this.unreadBytes += payload.length;
    while (payload.length > 0) {
      if (this.unread.length === 0 || this.lastBlockLength === readSize) {
        this.unread.push(new Uint8Array(readSize));
        this.lastBlockLength = 0;
      }
      const part = payload.subarray(0, readSize - this.lastBlockLength);
      this.unread[this.unread.length - 1]!.set(part, this.lastBlockLength);
      this.lastBlockLength += part.length;
      payload = payload.subarray(part.length);
    }
  }

  /// Delivers what is due. A sink that asks again from inside `received` is
  /// answered by the loop, not by a deeper call.
  private pump() {
    if (this.delivering || this.sink === null) return;
    this.delivering = true;
    while (this.wanted && this.unread.length > 0 && this.state !== 'closed') {
      this.wanted = false;
      let bytes = this.unread.shift()!;
      // The last block is partly filled: hand over what it holds.
      if (this.unread.length === 0) bytes = bytes.slice(0, this.lastBlockLength);
      this.unreadBytes -= bytes.length;
      this.grant(bytes.length);
      this.sink.received(bytes);
    }
    this.delivering = false;
    if (this.state === 'closing' && this.unread.length === 0) this.finish();
  }

  private grant(consumed: number) {
    this.consumed += consumed;
    if (this.consumed < grantSize || this.channel.readyState !== 'open') return;
    const message = new Uint8Array(5);
    message[0] = typeCredit;
    new DataView(message.buffer).setUint32(1, this.consumed);
    this.allowance += this.consumed;
    this.consumed = 0;
    this.channel.send(message);
  }

  // MARK: - Closing

  private channelClosed() {
    if (this.state !== 'open') return;
    this.unsent.length = 0;
    // What arrived before the close is still read.
    if (this.unread.length > 0) this.state = 'closing';
    else this.finish();
  }

  private finish() {
    this.state = 'closed';
    this.report();
    this.onClosed?.();
  }

  /// Tells the sink of the close, once, and never inside the call that
  /// caused it.
  private report() {
    if (this.reported || this.sink === null) return;
    this.reported = true;
    const sink = this.sink;
    queueMicrotask(() => sink.closed());
  }
}
