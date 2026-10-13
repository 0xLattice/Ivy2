// Two nodes in one page: a handshake, messages in order, and a 20 MiB
// Volume through a stream that fills at 256 KiB. Writes PASS or the failure
// into the document.

import {
  type AuthenticatedPeer,
  type ContentEntry,
  type PeerMessage,
  Ivy,
  IvyModule,
  hex,
  memoryPair,
} from '../src/index.js';

const log = (line: string) => {
  document.getElementById('log')!.textContent += `${line}\n`;
};

function check(condition: boolean, what: string) {
  if (!condition) throw new Error(what);
  log(`ok  ${what}`);
}

/// A turn of the event loop. Not a timer: a browser slows those to one a
/// second in a tab that is not showing, and the page should pass there too.
function pause(): Promise<void> {
  return new Promise((resolve) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => {
      channel.port1.close();
      resolve();
    };
    channel.port2.postMessage(null);
  });
}

async function eventually(condition: () => boolean): Promise<boolean> {
  const deadline = performance.now() + 10_000;
  while (!condition() && performance.now() < deadline) await pause();
  return condition();
}

class Heard {
  readonly log: string[] = [];
  readonly sessions: AuthenticatedPeer[] = [];
  async peerConnected(peer: AuthenticatedPeer) {
    this.log.push('connected');
    this.sessions.push(peer);
  }
  async deliver(message: PeerMessage) {
    // Slow on purpose: the next record waits for this one.
    for (let turn = 0; turn < 50; turn++) await pause();
    this.log.push(message.topic);
  }
}

async function run() {
  const started = performance.now();
  const response = await fetch(new URL('../ivy.wasm', import.meta.url));
  if (!response.ok) throw new Error(`dist/ivy.wasm: ${response.status}; run Web/build.sh`);
  const module = await IvyModule.load(await response.arrayBuffer());
  log(`module loaded in ${Math.round(performance.now() - started)} ms`);

  const megabyte = 1024 * 1024;
  const entries: ContentEntry[] = [{ cid: 'vol', data: new Uint8Array(512).fill(1) }];
  for (let index = 0; index < 20; index++) {
    entries.push({ cid: `vol-${String(index).padStart(2, '0')}`, data: new Uint8Array(megabyte).fill(index) });
  }

  const heardByA = new Heard();
  const heardByB = new Heard();
  const key = () => crypto.getRandomValues(new Uint8Array(32));
  const a = new Ivy(module, { signingKey: key(), listenPort: 0 }, { delegate: heardByA });
  const b = new Ivy(
    module,
    { signingKey: key(), listenPort: 0 },
    { delegate: heardByB, contentSource: { volume: async (rootCID) => (rootCID === 'vol' ? entries : []) } },
  );
  await a.start();
  await b.start();

  const [left, right] = memoryPair({ capacity: 256 * 1024 });
  b.accept(right);
  await a.connect({ publicKey: b.localID, host: '8.8.2.1', port: 4001 }, left);
  check(await eventually(() => b.connectedPeers.length === 1), 'both sides hold the session');
  check(a.connectedPeers[0] === b.localID && b.connectedPeers[0] === a.localID, 'each names the other');
  check(hex(heardByB.sessions[0]!.key) === a.localID, 'the responder was told who connected');

  const topics = Array.from({ length: 20 }, (_, index) => `t${index}`);
  const sent = [];
  for (const topic of topics) sent.push(await a.sendMessage(b.localID, topic, new TextEncoder().encode(topic)));
  check(sent.every((result) => result.kind === 'enqueued'), `${sent.length} messages were queued`);
  check(await eventually(() => heardByB.log.length === 21), 'every message arrived');
  check(heardByB.log.join() === ['connected', ...topics].join(), 'peerConnected first, then messages in order');

  let timesFull = 0;
  const send = right.send.bind(right);
  right.send = (bytes) => {
    send(bytes);
    if (!right.isWritable) timesFull += 1;
  };
  const fetchStarted = performance.now();
  const volume = await a.fetchVolume('vol');
  check(volume.entries.size === entries.length, `a ${entries.length}-entry, 20 MiB Volume arrived`);
  check(
    entries.every((entry) => {
      const got = volume.entries.get(entry.cid);
      return got?.length === entry.data.length && got.every((byte, index) => byte === entry.data[index]);
    }),
    'every byte of it is what was served',
  );
  check(volume.servedBy === b.localID, 'served by the other node');
  check(timesFull >= 3, `the stream held the sender back (${timesFull} times)`);
  log(`fetched in ${Math.round(performance.now() - fetchStarted)} ms`);

  const controller = new AbortController();
  const aborted = a.fetchVolume('absent-everywhere', { signal: controller.signal });
  controller.abort();
  check((await aborted).entries.size === 0, 'an aborted request completes');

  await a.destroy();
  check(await eventually(() => b.connectedPeers.length === 0), 'stopping one node ends the session');
  await b.destroy();
}

const result = document.getElementById('result')!;
run().then(
  () => {
    result.textContent = 'PASS';
    result.className = 'pass';
  },
  (error: unknown) => {
    result.textContent = `FAIL: ${error instanceof Error ? error.message : String(error)}`;
    result.className = 'fail';
    console.error(error);
  },
);
