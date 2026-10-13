// Browser to browser: moves a session that runs through a carrier onto a
// WebRTC data channel of the two peers' own.
//
// The relayed session carries the signalling, as peer messages on one
// reserved topic. When the channel opens the offerer hands it to
// `Ivy.connect` and the answerer to `Ivy.accept`; the core's handshake runs
// over it and the direct session it makes replaces the relayed one.
//
// A signalling message is
//
//   kind: u8, attempt: u32 big-endian, text: UTF-8 to the end
//
//   0 request    attempt 0, no text. "Offer to me": sent by the peer that
//                wants a channel and is not the one to offer.
//   1 offer      text is the SDP. `attempt` is the offerer's, not zero, and
//                every later message of the attempt repeats it.
//   2 answer     text is the SDP.
//   3 candidate  text is one ICE candidate line, for the only media section.
//   4 abandon    no text. The sender gave the attempt up.
//
// The peer with the smaller public key is always the offerer, so two peers
// that start at once make one connection, not two.

import { type AuthenticatedPeer, type PeerID, hex } from './codec.js';
import { type DataChannel, DataChannelTransport } from './datachannel.js';
import type { Ivy, IvyDelegate } from './shell.js';

/// The topic signalling travels on. The connector takes every message on it.
export const rtcTopic = 'ivy.rtc/1';

interface SessionDescription {
  type: 'offer' | 'answer' | 'pranswer' | 'rollback';
  sdp?: string;
}

/// What the connector needs of an `RTCPeerConnection`, which is one.
export interface PeerConnection {
  readonly connectionState: string;
  createDataChannel(label: string): DataChannel;
  createOffer(): Promise<SessionDescription>;
  createAnswer(): Promise<SessionDescription>;
  setLocalDescription(description: SessionDescription): Promise<void>;
  setRemoteDescription(description: SessionDescription): Promise<void>;
  addIceCandidate(candidate: { candidate: string; sdpMLineIndex: number }): Promise<void>;
  getStats(): Promise<{ forEach(callback: (report: any) => void): void }>;
  close(): void;
  addEventListener(type: string, listener: (event: any) => void): void;
}

export interface RtcOptions {
  /// `RTCPeerConnection`, which is the default.
  PeerConnection?: new (configuration: { iceServers: RTCIceServer[] }) => PeerConnection;
  /// STUN servers, for peers behind different NATs. By default the carrier
  /// the relayed session runs through is asked, on the port it was dialled
  /// at: a node listening for WebSockets answers STUN there over UDP, and
  /// it already knows this peer's address. `[]` asks no one, which connects
  /// peers that can reach each other's own addresses. TURN is not used: a
  /// carrier already relays.
  iceServers?: RTCIceServer[];
  /// Try as soon as a relayed session to an endpoint appears. On by default.
  autoUpgrade?: boolean;
  /// Milliseconds an attempt may take. 20 000 by default.
  deadline?: number;
}

const kindRequest = 0;
const kindOffer = 1;
const kindAnswer = 2;
const kindCandidate = 3;
const kindAbandon = 4;

/// A data-channel offer is under 1 KiB and a candidate under 200 bytes.
const maxSignalBytes = 8 * 1024;
/// Messages taken for one attempt, and candidates sent for one.
const maxSignals = 64;
/// Attempts on one relayed session, whoever asks for them.
const maxAttempts = 3;

/// One peer connection and the stream over it.
interface Link {
  peer: PeerID;
  pc: PeerConnection;
  transport: DataChannelTransport | null;
  /// The stream was given to Ivy.
  handed: boolean;
}

interface Attempt {
  /// Zero until the offer that names it is made or arrives.
  id: number;
  peer: PeerID;
  /// The relayed session the signalling travels on.
  session: AuthenticatedPeer;
  link: Link | null;
  remote: 'none' | 'setting' | 'set';
  /// Candidates that arrived before the remote description was set.
  candidates: string[];
  received: number;
  /// Candidates gathered before this end's description was sent, then null.
  outbox: string[] | null;
  sent: number;
  timer: ReturnType<typeof setTimeout>;
  done: Promise<boolean>;
  finish: (direct: boolean) => void;
}

const same = (left: Uint8Array, right: Uint8Array) =>
  left.length === right.length && left.every((byte, index) => byte === right[index]);

const isAddress = (host: string) => /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.includes(':');

/// The address the connection's packets come from.
async function remoteAddress(pc: PeerConnection): Promise<string | null> {
  const reports = new Map<string, any>();
  (await pc.getStats()).forEach((report) => reports.set(report.id, report));
  let pair: any;
  for (const report of reports.values()) {
    if (report.type === 'transport' && report.selectedCandidatePairId) {
      pair = reports.get(report.selectedCandidatePairId);
    }
  }
  // Where the transport does not name its pair, the pair says it is the one.
  for (const report of reports.values()) {
    if (pair === undefined && report.type === 'candidate-pair' && (report.selected || report.nominated)) {
      pair = report;
    }
  }
  const remote = reports.get(pair?.remoteCandidateId);
  // A browser that hides an address reports an empty one.
  return remote?.address || remote?.ip || null;
}

/// Drives the upgrade for one `Ivy`. Install its delegate before the node
/// starts: `ivy.delegate = connector.delegate(application)`.
export class RtcConnector {
  private readonly PeerConnection: NonNullable<RtcOptions['PeerConnection']>;
  private readonly iceServers: RTCIceServer[] | undefined;
  private readonly autoUpgrade: boolean;
  private readonly deadline: number;

  /// The session each peer has now, and the attempts made on it.
  private readonly sessions = new Map<PeerID, { session: AuthenticatedPeer; attempts: number }>();
  private readonly attempts = new Map<PeerID, Attempt>();
  private readonly links = new Set<Link>();
  private lastAttempt = 0;
  private closed = false;

  constructor(
    private readonly ivy: Ivy,
    options: RtcOptions = {},
  ) {
    this.PeerConnection = options.PeerConnection ?? globalThis.RTCPeerConnection;
    this.iceServers = options.iceServers;
    this.autoUpgrade = options.autoUpgrade ?? true;
    this.deadline = options.deadline ?? 20_000;
  }

  /// The delegate to give Ivy. It takes the signalling topic and passes
  /// everything else to `inner`.
  delegate(inner: IvyDelegate = {}): IvyDelegate {
    return {
      peerConnected: (peer) => {
        this.connected(peer);
        return inner.peerConnected?.(peer);
      },
      deliver: (message, from) =>
        message.topic === rtcTopic ? this.signalled(message.payload, from) : inner.deliver?.(message, from),
      peerDisconnected: (peer) => {
        this.disconnected(peer);
        inner.peerDisconnected?.(peer);
      },
      publicAddressDiscovered: (address) => inner.publicAddressDiscovered?.(address),
    };
  }

  /// Tries to move the peer of a relayed session onto a data channel.
  /// Resolves true when the peer's session is direct, and false when it is
  /// not: the attempt failed or timed out, `session` is no longer the
  /// peer's, or too many attempts were made on it. The relayed session is
  /// left as it was. An attempt already running is joined, not repeated.
  async upgrade(session: AuthenticatedPeer): Promise<boolean> {
    const peer = hex(session.key);
    const known = this.sessions.get(peer);
    if (this.closed || known === undefined || known.session.role !== 'endpoint') return false;
    if (known.session.route.kind === 'direct') return true;
    if (!same(known.session.sessionID, session.sessionID)) return false;
    const running = this.attempts.get(peer);
    if (running !== undefined) return running.done;
    const attempt = this.begin(peer);
    if (attempt === null) return false;
    if (this.offers(peer)) void this.offer(attempt);
    else this.signal(attempt, kindRequest).catch(() => this.end(attempt, false));
    return attempt.done;
  }

  /// Ends every attempt and closes every peer connection. Sessions that ran
  /// over one close with it.
  close() {
    this.closed = true;
    for (const attempt of [...this.attempts.values()]) this.end(attempt, false);
    for (const link of [...this.links]) this.release(link);
    this.sessions.clear();
  }

  // MARK: - Sessions

  private connected(session: AuthenticatedPeer) {
    if (this.closed) return;
    const peer = hex(session.key);
    this.sessions.set(peer, { session, attempts: 0 });
    // Whatever was being tried was for the session this one replaced.
    const attempt = this.attempts.get(peer);
    if (attempt !== undefined) this.end(attempt, false, session.route.kind === 'direct');
    if (this.autoUpgrade && session.role === 'endpoint' && session.route.kind === 'relayed') {
      void this.upgrade(session);
    }
  }

  private disconnected(peer: PeerID) {
    this.sessions.delete(peer);
    // The peer that finishes the handshake first closes the relayed session,
    // and the carrier may tell this end of that before the handshake's last
    // record has crossed the channel. The stream Ivy holds is left to it.
    const attempt = this.attempts.get(peer);
    const handshaking = attempt?.link?.handed ? attempt.link : null;
    if (attempt !== undefined && handshaking === null) this.end(attempt, false);
    for (const link of [...this.links]) {
      if (link.peer === peer && link !== handshaking) this.release(link);
    }
  }

  // MARK: - Attempts

  /// One of two peers offers, and both know which.
  private offers(peer: PeerID): boolean {
    return this.ivy.localID < peer;
  }

  private begin(peer: PeerID): Attempt | null {
    const known = this.sessions.get(peer)!;
    if (known.attempts >= maxAttempts) return null;
    known.attempts += 1;
    let finish!: (direct: boolean) => void;
    const attempt: Attempt = {
      id: 0,
      peer,
      session: known.session,
      link: null,
      remote: 'none',
      candidates: [],
      received: 0,
      outbox: [],
      sent: 0,
      timer: setTimeout(() => this.end(attempt, true), this.deadline),
      done: new Promise((resolve) => (finish = resolve)),
      finish,
    };
    this.attempts.set(peer, attempt);
    return attempt;
  }

  private live(attempt: Attempt): boolean {
    return this.attempts.get(attempt.peer) === attempt;
  }

  /// Ends an attempt. Unless the peer's session is now direct over this
  /// attempt's stream, the peer connection goes with it.
  private end(attempt: Attempt, tell: boolean, direct = false) {
    if (!this.live(attempt)) return;
    this.attempts.delete(attempt.peer);
    clearTimeout(attempt.timer);
    if (attempt.link !== null && !(direct && attempt.link.handed)) this.release(attempt.link);
    if (tell && attempt.id !== 0) this.signal(attempt, kindAbandon).catch(() => {});
    attempt.finish(direct);
  }

  private release(link: Link) {
    if (!this.links.delete(link)) return;
    link.transport?.close();
    link.pc.close();
  }

  /// The stream or the peer connection ended by itself.
  private dropped(attempt: Attempt, link: Link) {
    this.end(attempt, true);
    this.release(link);
  }

  /// The carrier of the attempt's session, as a STUN server.
  private carrierServers(session: AuthenticatedPeer): RTCIceServer[] {
    if (session.route.kind !== 'relayed') return [];
    const carrier = this.ivy.reachedAt(hex(session.route.carrier));
    if (carrier === undefined) return [];
    const host = carrier.host.includes(':') ? `[${carrier.host}]` : carrier.host;
    return [{ urls: `stun:${host}:${carrier.port}` }];
  }

  private open(attempt: Attempt): Link {
    const pc = new this.PeerConnection({
      iceServers: this.iceServers ?? this.carrierServers(attempt.session),
    });
    const link: Link = { peer: attempt.peer, pc, transport: null, handed: false };
    attempt.link = link;
    this.links.add(link);
    pc.addEventListener('icecandidate', (event) => {
      const candidate: string | undefined = event.candidate?.candidate;
      if (!candidate || !this.live(attempt)) return;
      if (attempt.outbox !== null) attempt.outbox.push(candidate);
      else this.sendCandidate(attempt, candidate);
    });
    pc.addEventListener('connectionstatechange', () => {
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') this.dropped(attempt, link);
    });
    return link;
  }

  /// Wraps the channel at once, so nothing it delivers is missed, and hands
  /// the stream to Ivy when it is open.
  private carry(attempt: Attempt, link: Link, channel: DataChannel, hand: (transport: DataChannelTransport) => void) {
    const transport = new DataChannelTransport(channel);
    link.transport = transport;
    transport.onClosed = () => this.dropped(attempt, link);
    const opened = async () => {
      const address = await remoteAddress(link.pc).catch(() => null);
      if (!this.live(attempt)) return;
      // Netgroup admission keys on the host. An address is one; a name is
      // not (a browser hides a local address behind an mDNS name of its own
      // choosing), so the peer the signalling was signed by stands in.
      transport.observedHost =
        address !== null && isAddress(address) ? address : `${attempt.peer}.webrtc.invalid`;
      link.handed = true;
      hand(transport);
    };
    if (channel.readyState === 'open') void opened();
    else channel.addEventListener('open', () => void opened());
  }

  private async offer(attempt: Attempt) {
    attempt.id = this.lastAttempt = (this.lastAttempt % 0xffff_ffff) + 1;
    try {
      const link = this.open(attempt);
      // Ordered and reliable, as a channel is unless asked otherwise.
      this.carry(attempt, link, link.pc.createDataChannel('ivy'), (transport) => {
        const endpoint = { publicKey: attempt.peer, host: transport.observedHost!, port: 0 };
        // The peer is "connected" either way; the session Ivy then reports
        // says whether over this stream, and the stream closes if not.
        this.ivy.connect(endpoint, transport).catch(() => this.end(attempt, true));
      });
      const offer = await link.pc.createOffer();
      await link.pc.setLocalDescription(offer);
      await this.describe(attempt, kindOffer, offer.sdp ?? '');
    } catch {
      this.end(attempt, true);
    }
  }

  private async answer(attempt: Attempt, sdp: string) {
    try {
      const link = this.open(attempt);
      link.pc.addEventListener('datachannel', (event) => {
        if (link.transport !== null || !this.live(attempt)) return event.channel.close();
        this.carry(attempt, link, event.channel, (transport) => this.ivy.accept(transport));
      });
      await this.setRemote(attempt, { type: 'offer', sdp });
      const answer = await link.pc.createAnswer();
      await link.pc.setLocalDescription(answer);
      await this.describe(attempt, kindAnswer, answer.sdp ?? '');
    } catch {
      this.end(attempt, true);
    }
  }

  /// Sends this end's description, then the candidates gathered meanwhile:
  /// the peer drops a candidate for an attempt it has not heard of.
  private async describe(attempt: Attempt, kind: number, sdp: string) {
    if (!this.live(attempt)) return;
    await this.signal(attempt, kind, sdp);
    const waiting = attempt.outbox ?? [];
    attempt.outbox = null;
    for (const candidate of waiting) this.sendCandidate(attempt, candidate);
  }

  private sendCandidate(attempt: Attempt, candidate: string) {
    if (attempt.sent >= maxSignals) return;
    attempt.sent += 1;
    this.signal(attempt, kindCandidate, candidate).catch(() => this.end(attempt, false));
  }

  private async setRemote(attempt: Attempt, description: SessionDescription) {
    attempt.remote = 'setting';
    await attempt.link!.pc.setRemoteDescription(description);
    attempt.remote = 'set';
    for (const candidate of attempt.candidates.splice(0)) this.addCandidate(attempt, candidate);
  }

  private addCandidate(attempt: Attempt, candidate: string) {
    if (!this.live(attempt)) return;
    attempt.link!.pc.addIceCandidate({ candidate, sdpMLineIndex: 0 }).catch(() => this.end(attempt, true));
  }

  // MARK: - Signalling

  /// Sends on the attempt's session and no other. Rejects if it cannot.
  private async signal(attempt: Attempt, kind: number, text = '') {
    const body = new TextEncoder().encode(text);
    const payload = new Uint8Array(5 + body.length);
    payload[0] = kind;
    new DataView(payload.buffer).setUint32(1, attempt.id);
    payload.set(body, 5);
    if (payload.length > maxSignalBytes) throw new Error('signalling message too large');
    for (;;) {
      const result = await this.ivy.sendMessage(attempt.session, rtcTopic, payload);
      if (result.kind === 'enqueued') return;
      if (result.kind !== 'backpressured' || !(await this.ivy.waitUntilWritable(attempt.session))) {
        throw new Error(`signalling not sent: ${result.kind}`);
      }
      if (kind !== kindAbandon && !this.live(attempt)) return;
    }
  }

  /// Signalling counts only on the relayed session to an endpoint that is
  /// the peer's now. Anything else on the topic is dropped: the session it
  /// came on is not at fault for what an attempt makes of it.
  private signalled(payload: Uint8Array, from: AuthenticatedPeer) {
    const peer = hex(from.key);
    const known = this.sessions.get(peer);
    if (
      this.closed ||
      from.role !== 'endpoint' ||
      from.route.kind !== 'relayed' ||
      known === undefined ||
      !same(known.session.sessionID, from.sessionID)
    ) {
      return;
    }
    const attempt = this.attempts.get(peer);
    const malformed = () => {
      if (attempt !== undefined) this.end(attempt, true);
    };
    if (payload.length < 5 || payload.length > maxSignalBytes) return malformed();
    const kind = payload[0]!;
    if (kind > kindAbandon) return malformed();
    const id = new DataView(payload.buffer, payload.byteOffset, payload.byteLength).getUint32(1);
    let text: string;
    try {
      text = new TextDecoder('utf-8', { fatal: true }).decode(payload.subarray(5));
    } catch {
      return malformed();
    }

    if (kind === kindRequest) {
      if (id !== 0 || text !== '') return malformed();
      if (attempt === undefined && this.offers(peer)) void this.upgrade(known.session);
      return;
    }
    if (kind === kindOffer) {
      // This end is the one that offers: the peer's offer is dropped, and
      // its own attempt goes on.
      if (this.offers(peer)) return;
      if (id === 0 || text === '') return malformed();
      // One attempt at a time. An offer joins the attempt waiting for it.
      if (attempt !== undefined && attempt.id !== 0) return attempt.id === id ? malformed() : undefined;
      const answering = attempt ?? this.begin(peer);
      if (answering === null) return;
      answering.id = id;
      void this.answer(answering, text);
      return;
    }

    // The rest belong to an attempt, and one that is over is not an error.
    if (attempt === undefined || id === 0 || attempt.id !== id) return;
    attempt.received += 1;
    if (attempt.received > maxSignals) return malformed();
    if (kind === kindAbandon && text === '') return this.end(attempt, false);
    if (kind === kindAnswer && text !== '' && this.offers(peer) && attempt.remote === 'none') {
      this.setRemote(attempt, { type: 'answer', sdp: text }).catch(() => this.end(attempt, true));
    } else if (kind === kindCandidate && text !== '' && attempt.link !== null) {
      if (attempt.remote === 'set') this.addCandidate(attempt, text);
      else attempt.candidates.push(text);
    } else {
      malformed();
    }
  }
}
