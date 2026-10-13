import { readFile } from 'node:fs/promises';

import {
  type AuthenticatedPeer,
  type IvyConfig,
  type IvyDelegate,
  type IvyOptions,
  type PeerEndpoint,
  type PeerMessage,
  Ivy,
  IvyModule,
  MemoryTransport,
  memoryPair,
} from '../src/index.js';

// One module for every test: several cores in one instance is how a page
// runs them.
export const module = await IvyModule.load(
  await readFile(process.env.IVY_WASM ?? new URL('../ivy.wasm', import.meta.url)),
);

let lastSeed = 0;

export function seed(): Uint8Array {
  lastSeed += 1;
  return new Uint8Array(32).fill(lastSeed);
}

const nodes: Ivy[] = [];

/// A node as the native suite's tests configure one: no listener, no
/// keepalive.
export function node(options: IvyOptions = {}, config: Partial<IvyConfig> = {}): Ivy {
  const ivy = new Ivy(module, { signingKey: seed(), listenPort: 0, healthEnabled: false, ...config }, options);
  nodes.push(ivy);
  return ivy;
}

/// Frees every node a test made. A node left running keeps its timer, and
/// so the process, alive.
export async function destroyNodes() {
  for (const ivy of nodes.splice(0)) await ivy.destroy();
}

export const endpoint = (ivy: Ivy, host = '8.8.2.1'): PeerEndpoint => ({
  publicKey: ivy.localID,
  host,
  port: 4001,
});

export function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export async function eventually(condition: () => boolean, timeout = 10_000): Promise<boolean> {
  const deadline = performance.now() + timeout;
  while (performance.now() < deadline) {
    if (condition()) return true;
    await sleep(2);
  }
  return condition();
}

/// Joins `a` (initiator) and `b` (responder) over an in-memory pair, and
/// returns each one's end.
export async function join(a: Ivy, b: Ivy, capacity?: number): Promise<[MemoryTransport, MemoryTransport]> {
  const [left, right] = memoryPair(capacity === undefined ? {} : { capacity });
  b.accept(right);
  await a.connect(endpoint(b), left);
  return [left, right];
}

/// A delegate that writes down what it hears, in order.
export class Recorder implements IvyDelegate {
  readonly log: string[] = [];
  readonly messages: PeerMessage[] = [];
  readonly sessions: AuthenticatedPeer[] = [];
  /// A delivery waits on this, when set, before it returns.
  gate: Promise<void> | null = null;
  entered = 0;

  async peerConnected(peer: AuthenticatedPeer) {
    this.log.push('connected');
    this.sessions.push(peer);
  }

  async deliver(message: PeerMessage) {
    this.entered += 1;
    await this.gate;
    this.log.push(`message ${message.topic}`);
    this.messages.push(message);
  }

  peerDisconnected() {
    this.log.push('disconnected');
  }
}
