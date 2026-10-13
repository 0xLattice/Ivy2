// WebRTC in memory, as much of it as the data-channel transport and the
// connector use: Node has none. Two peer connections of one `FakeNetwork`
// reach each other when their descriptions and a candidate each way have
// been exchanged, as real ones do over loopback.

import { setImmediate } from 'node:timers';

import type { DataChannel, PeerConnection } from '../src/index.js';

const event = (type: string, fields: object = {}) => Object.assign(new Event(type), fields);

export class FakeDataChannel extends EventTarget implements DataChannel {
  binaryType = 'blob';
  readyState: 'connecting' | 'open' | 'closing' | 'closed' = 'connecting';
  bufferedAmount = 0;
  bufferedAmountLowThreshold = 0;
  peer!: FakeDataChannel;

  messagesSent = 0;
  largestMessage = 0;
  /// Called with each message as it reaches the other end.
  onDelivered: (() => void) | null = null;

  private readonly buffer: ArrayBuffer[] = [];
  private scheduled = false;
  private held = false;

  /// While stalled, what is sent stays in the buffer, as on a slow path.
  set stalled(stalled: boolean) {
    this.held = stalled;
    this.schedule();
  }

  send(data: Uint8Array<ArrayBuffer> | string) {
    if (this.readyState !== 'open') throw new Error('the channel is not open');
    if (typeof data === 'string') {
      // Text never comes from the transport; a test sends it as a peer would.
      setImmediate(() => this.peer.dispatchEvent(event('message', { data })));
      return;
    }
    this.messagesSent += 1;
    this.largestMessage = Math.max(this.largestMessage, data.length);
    this.bufferedAmount += data.length;
    this.buffer.push(data.slice().buffer);
    this.schedule();
  }

  close() {
    if (this.readyState === 'closing' || this.readyState === 'closed') return;
    this.readyState = 'closing';
    this.schedule();
  }

  open() {
    if (this.readyState !== 'connecting') return;
    this.readyState = 'open';
    this.dispatchEvent(event('open'));
  }

  /// As when the peer connection under the channel is closed: this end
  /// hears nothing, the other end's channel closes.
  abort() {
    if (this.readyState === 'closed') return;
    this.readyState = 'closed';
    this.buffer.length = 0;
    this.peer.ended();
  }

  private ended() {
    if (this.readyState === 'closed') return;
    this.readyState = 'closed';
    this.buffer.length = 0;
    this.dispatchEvent(event('close'));
  }

  /// One message crosses in each turn of the event loop.
  private schedule() {
    if (this.scheduled || this.held) return;
    if (this.buffer.length === 0 && this.readyState !== 'closing') return;
    this.scheduled = true;
    setImmediate(() => {
      this.scheduled = false;
      if (this.held) return;
      const data = this.buffer.shift();
      if (data === undefined) {
        // Closing, and everything sent before the close has crossed.
        if (this.readyState !== 'closing') return;
        this.peer.ended();
        return this.ended();
      }
      const before = this.bufferedAmount;
      this.bufferedAmount -= data.byteLength;
      if (this.peer.readyState === 'open') {
        this.peer.dispatchEvent(event('message', { data }));
        this.onDelivered?.();
      }
      if (before > this.bufferedAmountLowThreshold && this.bufferedAmount <= this.bufferedAmountLowThreshold) {
        this.dispatchEvent(event('bufferedamountlow'));
      }
      this.schedule();
    });
  }
}

/// Two open ends of one channel.
export function fakeChannelPair(): [FakeDataChannel, FakeDataChannel] {
  const [a, b] = unopenedPair();
  a.open();
  b.open();
  return [a, b];
}

function unopenedPair(): [FakeDataChannel, FakeDataChannel] {
  const a = new FakeDataChannel();
  const b = new FakeDataChannel();
  a.peer = b;
  b.peer = a;
  return [a, b];
}

interface Description {
  type: 'offer' | 'answer' | 'pranswer' | 'rollback';
  sdp?: string;
}

export class FakePeerConnection extends EventTarget implements PeerConnection {
  connectionState: 'new' | 'connected' | 'closed' = 'new';
  readonly host: string;
  private readonly index: number;
  private remote: FakePeerConnection | null = null;
  private described = false;
  private remoteCandidates = 0;
  /// The ends of the channel this connection offered.
  private offered: [FakeDataChannel, FakeDataChannel] | null = null;
  private channel: FakeDataChannel | null = null;

  constructor(private readonly network: FakeNetwork) {
    super();
    this.index = network.connections.length;
    this.host = network.host(this.index);
    network.connections.push(this);
  }

  createDataChannel(): FakeDataChannel {
    this.offered = unopenedPair();
    this.channel = this.offered[0];
    return this.channel;
  }

  async createOffer(): Promise<Description> {
    return { type: 'offer', sdp: `fake ${this.index}` };
  }

  async createAnswer(): Promise<Description> {
    if (this.remote === null) throw new Error('no offer to answer');
    return { type: 'answer', sdp: `fake ${this.index}` };
  }

  async setLocalDescription(description: Description) {
    if (description.sdp !== `fake ${this.index}`) throw new Error('not this connection');
    this.described = true;
    // Candidates are gathered after the description is set, one at a time.
    for (const priority of [2, 1]) {
      setImmediate(() => {
        if (this.connectionState === 'closed') return;
        const candidate = `candidate:${priority} 1 udp ${priority} ${this.host} 9 typ host`;
        this.dispatchEvent(event('icecandidate', { candidate: { candidate } }));
      });
    }
    setImmediate(() => this.dispatchEvent(event('icecandidate', { candidate: null })));
  }

  async setRemoteDescription(description: Description) {
    const match = /^fake (\d+)$/.exec(description.sdp ?? '');
    const remote = match === null ? undefined : this.network.connections[Number(match[1])];
    if (remote === undefined || remote === this || this.remote !== null) throw new Error('invalid description');
    this.remote = remote;
    this.settle();
  }

  async addIceCandidate(candidate: { candidate: string }) {
    const match = /^candidate:\d+ 1 udp \d+ (\S+) 9 typ host$/.exec(candidate.candidate);
    if (this.remote === null || match === null || match[1] !== this.remote.host) {
      throw new Error('invalid candidate');
    }
    this.remoteCandidates += 1;
    this.settle();
  }

  async getStats() {
    return new Map<string, object>([
      ['T', { id: 'T', type: 'transport', selectedCandidatePairId: 'P' }],
      ['P', { id: 'P', type: 'candidate-pair', remoteCandidateId: 'R' }],
      ['R', { id: 'R', type: 'remote-candidate', address: this.remote?.host }],
    ]);
  }

  close() {
    if (this.connectionState === 'closed') return;
    this.connectionState = 'closed';
    this.channel?.abort();
  }

  private ready(): boolean {
    return this.connectionState === 'new' && this.described && this.remoteCandidates > 0;
  }

  /// Connects the two once each has what it needs of the other.
  private settle() {
    const remote = this.remote;
    if (remote === null || remote.remote !== this || this.network.blocked) return;
    if (!this.ready() || !remote.ready()) return;
    const [offerer, answerer] = this.offered === null ? [remote, this] : [this, remote];
    if (offerer.offered === null) return;
    const [near, far] = offerer.offered;
    for (const end of [offerer, answerer]) {
      end.connectionState = 'connected';
      end.dispatchEvent(event('connectionstatechange'));
    }
    answerer.channel = far;
    answerer.dispatchEvent(event('datachannel', { channel: far }));
    setImmediate(() => {
      near.open();
      far.open();
    });
  }
}

/// Where fake peer connections find each other.
export class FakeNetwork {
  readonly connections: FakePeerConnection[] = [];
  /// No connection is established while set, as between two peers with no
  /// path to each other.
  blocked = false;
  /// The address the connection made `index`th is observed at.
  host = (index: number) => `9.${index + 1}.0.1`;

  /// What each connection was made with, in order.
  readonly configurations: { iceServers: RTCIceServer[] }[] = [];

  /// A constructor to give a connector in place of `RTCPeerConnection`.
  readonly PeerConnection: new (configuration: { iceServers: RTCIceServer[] }) => FakePeerConnection;

  constructor() {
    const network = this;
    this.PeerConnection = class extends FakePeerConnection {
      constructor(configuration: { iceServers: RTCIceServer[] }) {
        super(network);
        network.configurations.push(configuration);
      }
    };
  }

  get open(): FakePeerConnection[] {
    return this.connections.filter((connection) => connection.connectionState !== 'closed');
  }
}
