// Three nodes in one page: a carrier with relaying enabled, and two peers
// joined to it by in-memory streams, as two browsers on one node are. The
// peers meet through the carrier, signal over that session, and move to a
// data channel between two real RTCPeerConnections, which reach each other
// inside the page with no server. A 20 MiB Volume then crosses the channel.
// Writes PASS or the failure into the document.

import {
  type AuthenticatedPeer,
  type ContentEntry,
  type MemoryTransport,
  type PeerID,
  type PeerMessage,
  DataChannelTransport,
  Ivy,
  IvyModule,
  RtcConnector,
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
  readonly sessions: AuthenticatedPeer[] = [];
  readonly topics: string[] = [];
  disconnects = 0;
  constructor(private readonly peer: () => PeerID) {}
  peerConnected(peer: AuthenticatedPeer) {
    if (hex(peer.key) === this.peer()) this.sessions.push(peer);
  }
  deliver(message: PeerMessage) {
    this.topics.push(message.topic);
  }
  peerDisconnected(peer: PeerID) {
    if (peer === this.peer()) this.disconnects += 1;
  }
  get session(): AuthenticatedPeer | undefined {
    return this.sessions.at(-1);
  }
}

async function run() {
  if (typeof RTCPeerConnection === 'undefined') throw new Error('this browser has no RTCPeerConnection');
  const response = await fetch(new URL('../ivy.wasm', import.meta.url));
  if (!response.ok) throw new Error(`dist/ivy.wasm: ${response.status}; run Web/build.sh`);
  const module = await IvyModule.load(await response.arrayBuffer());

  const megabyte = 1024 * 1024;
  const entries: ContentEntry[] = [{ cid: 'vol', data: new Uint8Array(512).fill(1) }];
  for (let index = 0; index < 20; index++) {
    const data = new Uint8Array(megabyte);
    for (let offset = 0; offset < megabyte; offset++) data[offset] = (offset * 31 + index) & 0xff;
    entries.push({ cid: `vol-${String(index).padStart(2, '0')}`, data });
  }

  // Everything to or from the carrier is counted.
  let carried = 0;
  const counted = (pair: [MemoryTransport, MemoryTransport]) => {
    for (const stream of pair) {
      const send = stream.send.bind(stream);
      stream.send = (bytes) => {
        carried += bytes.length;
        send(bytes);
      };
    }
    return pair;
  };
  // The host Ivy is told each data channel's peer was observed at.
  const observed: (string | null)[] = [];
  const watched = (ivy: Ivy) => {
    const accept = ivy.accept.bind(ivy);
    ivy.accept = (transport) => {
      if (transport instanceof DataChannelTransport) observed.push(transport.observedHost);
      accept(transport);
    };
    const connect = ivy.connect.bind(ivy);
    ivy.connect = (to, over, options) => {
      if (over instanceof DataChannelTransport) observed.push(over.observedHost);
      return connect(to, over, options);
    };
    return ivy;
  };

  const key = () => crypto.getRandomValues(new Uint8Array(32));
  const carrier = new Ivy(module, { signingKey: key(), listenPort: 0, relayEnabled: true });
  const carrierEndpoint = { publicKey: carrier.localID, host: '8.9.0.1', port: 4001 };
  const a: Ivy = watched(
    new Ivy(
      module,
      { signingKey: key(), listenPort: 0, carriers: [carrierEndpoint] },
      {
        dial: async () => {
          const [near, far] = counted(memoryPair({ hosts: ['8.1.0.1', '8.9.0.1'] }));
          carrier.accept(far);
          return near;
        },
      },
    ),
  );
  const b: Ivy = watched(
    new Ivy(
      module,
      { signingKey: key(), listenPort: 0 },
      { contentSource: { volume: async (rootCID) => (rootCID === 'vol' ? entries : []) } },
    ),
  );
  const heardByA = new Heard(() => b.localID);
  const heardByB = new Heard(() => a.localID);
  // No ICE servers: the two peer connections reach each other's own addresses.
  const rtcA = new RtcConnector(a, { autoUpgrade: false });
  const rtcB = new RtcConnector(b, { autoUpgrade: false });
  a.delegate = rtcA.delegate(heardByA);
  b.delegate = rtcB.delegate(heardByB);

  await carrier.start();
  await a.start();
  await b.start();
  const [near, far] = counted(memoryPair({ hosts: ['8.2.0.1', '8.9.0.1'] }));
  carrier.accept(far);
  await b.connect(carrierEndpoint, near);
  check(await eventually(() => carrier.connectedPeers.length === 2), 'both peers are connected to the carrier');

  await a.connectViaRelay({ publicKey: b.localID, host: 'relay', port: 0 });
  check(
    await eventually(() => heardByA.session !== undefined && heardByB.session !== undefined),
    'they hold a session with each other',
  );
  check(
    heardByA.session!.route.kind === 'relayed' && heardByB.session!.route.kind === 'relayed',
    'it runs through the carrier',
  );
  const relayed = await a.sendMessage(b.localID, 'relayed', new Uint8Array([1]));
  check(relayed.kind === 'enqueued' && relayed.route.kind === 'relayed', 'a message is sent through the carrier');
  check(await eventually(() => heardByB.topics.includes('relayed')), 'and arrives');

  const started = performance.now();
  check(await rtcA.upgrade(heardByA.session!), 'the upgrade reports a direct session');
  check(
    await eventually(() => heardByA.session!.route.kind === 'direct' && heardByB.session!.route.kind === 'direct'),
    'both ends hold a direct session',
  );
  log(`    upgraded in ${Math.round(performance.now() - started)} ms; each observed its peer at ${observed.join(' and ')}`);
  check(
    hex(heardByA.session!.sessionID) === hex(heardByB.session!.sessionID),
    'it is the same session at both ends',
  );
  check(a.connectedPeers.includes(b.localID) && b.connectedPeers.includes(a.localID), 'each still names the other');
  check(heardByA.disconnects === 0 && heardByB.disconnects === 0, 'neither application heard a disconnect');

  // The carrier's streams are idle before they are measured.
  let before = -1;
  await eventually(() => {
    const idle = carried === before;
    before = carried;
    return idle;
  });
  const direct = await a.sendMessage(b.localID, 'direct', new Uint8Array([2]));
  check(direct.kind === 'enqueued' && direct.route.kind === 'direct', 'a message is sent over the data channel');
  const back = await b.sendMessage(heardByB.session!, 'direct', new Uint8Array([3]));
  check(back.kind === 'enqueued', 'and one back, on the direct session');
  check(
    await eventually(() => heardByA.topics.includes('direct') && heardByB.topics.includes('direct')),
    'both arrive',
  );
  check(
    [...heardByA.topics, ...heardByB.topics].every((topic) => topic === 'relayed' || topic === 'direct'),
    'the applications saw none of the signalling',
  );

  const fetchStarted = performance.now();
  const volume = await a.fetchVolume('vol', { from: heardByA.session! });
  const seconds = (performance.now() - fetchStarted) / 1000;
  check(volume.entries.size === entries.length, `a ${entries.length}-entry, 20 MiB Volume arrived over the data channel`);
  check(
    entries.every((entry) => {
      const got = volume.entries.get(entry.cid);
      return got?.length === entry.data.length && got.every((byte, index) => byte === entry.data[index]);
    }),
    'every byte of it is what was served',
  );
  check(volume.servedBy === b.localID, 'served by the other peer');
  log(`    fetched in ${Math.round(seconds * 1000)} ms, ${(20 / seconds).toFixed(1)} MiB/s`);
  check(carried === before, 'the carrier carried none of it');

  rtcA.close();
  check(await eventually(() => !b.connectedPeers.includes(a.localID)), 'closing the connector ends the direct session');
  rtcB.close();
  await a.destroy();
  await b.destroy();
  await carrier.destroy();
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
