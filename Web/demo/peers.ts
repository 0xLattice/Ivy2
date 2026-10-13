// Two pages, each with a node, and a node elsewhere that both reach over
// WebSocket. One page serves a Volume it keeps in IndexedDB; the other
// meets it through the node, moves to a WebRTC data channel between the two
// pages, and fetches the Volume over that.
//
//   peers.html?node=ws://host:port/ivy&key=<the node's public key>&role=serve
//   peers.html?node=…&key=…&role=fetch&peer=<the serving page's public key>
//
// The node must carry sessions between its peers (`relayEnabled`). Open the
// serving page first: it shows its public key. The fetching page writes PASS
// or the failure. Nothing here waits on a timer, which a browser slows in a
// tab that is not showing.

import {
  type AuthenticatedPeer,
  type ContentEntry,
  IndexedDBContentSource,
  Ivy,
  IvyModule,
  RtcConnector,
  connectWebSocket,
  hex,
  webSocketDialer,
} from '../src/index.js';

const root = 'page-volume';
const megabyte = 1024 * 1024;

const log = (line: string) => {
  document.getElementById('log')!.textContent += `${line}\n`;
};

function check(condition: boolean, what: string) {
  if (!condition) throw new Error(what);
  log(`ok  ${what}`);
}

/// The Volume the serving page makes and the fetching page expects.
function volume(): ContentEntry[] {
  const entries: ContentEntry[] = [{ cid: root, data: new Uint8Array(512).fill(7) }];
  for (let index = 0; index < 8; index++) {
    const data = new Uint8Array(megabyte);
    for (let offset = 0; offset < data.length; offset++) data[offset] = (offset * 31 + index) & 0xff;
    entries.push({ cid: `${root}-${index}`, data });
  }
  return entries;
}

/// Resolves with the first session reported that `wanted` accepts.
class Sessions {
  private readonly seen: AuthenticatedPeer[] = [];
  private readonly waiting: { wanted: (peer: AuthenticatedPeer) => boolean; resolve: (peer: AuthenticatedPeer) => void }[] = [];

  peerConnected(peer: AuthenticatedPeer) {
    this.seen.push(peer);
    for (const waiter of this.waiting.splice(0)) {
      if (waiter.wanted(peer)) waiter.resolve(peer);
      else this.waiting.push(waiter);
    }
    log(`    session with ${hex(peer.key).slice(0, 12)}… (${peer.role}, ${peer.route.kind})`);
  }

  next(wanted: (peer: AuthenticatedPeer) => boolean): Promise<AuthenticatedPeer> {
    const already = this.seen.find(wanted);
    if (already !== undefined) return Promise.resolve(already);
    return new Promise((resolve) => this.waiting.push({ wanted, resolve }));
  }
}

async function run(): Promise<string> {
  const query = new URLSearchParams(location.search);
  const [address, key, role, peer] = [query.get('node'), query.get('key'), query.get('role'), query.get('peer')];
  if (address === null || key === null || (role !== 'serve' && role !== 'fetch') || (role === 'fetch' && peer === null)) {
    throw new Error('the address needs ?node=ws://host:port/ivy&key=<hex>&role=serve, or &role=fetch&peer=<hex>');
  }
  const url = new URL(address);
  const port = Number(url.port) || (url.protocol === 'wss:' ? 443 : 80);
  const node = { publicKey: key, host: url.hostname, port };

  const response = await fetch(new URL('../ivy.wasm', import.meta.url));
  if (!response.ok) throw new Error(`dist/ivy.wasm: ${response.status}; run Web/build.sh`);
  const module = await IvyModule.load(await response.arrayBuffer());
  const sessions = new Sessions();

  if (role === 'serve') {
    const store = await IndexedDBContentSource.open('ivy-peers-demo', { budget: 64 * megabyte });
    await store.put(root, volume());
    const ivy = new Ivy(
      module,
      { signingKey: crypto.getRandomValues(new Uint8Array(32)), listenPort: 0 },
      { contentSource: store },
    );
    const rtc = new RtcConnector(ivy);
    ivy.delegate = rtc.delegate(sessions);
    await ivy.start();
    await ivy.connect(node, await connectWebSocket(url));
    check(ivy.connectedPeers.includes(key), 'connected to the node');
    check(await store.has(root), `the Volume ${root} is in IndexedDB`);
    log(`public key: ${ivy.localID}`);
    const page = new URL(location.href);
    page.searchParams.set('role', 'fetch');
    page.searchParams.set('peer', ivy.localID);
    log(`open in another tab: ${page.href}`);
    await sessions.next((session) => session.role === 'endpoint' && session.route.kind === 'direct' && hex(session.key) !== key);
    return 'SERVING, peer to peer';
  }

  // The node is this page's carrier: the core keeps a session with it and
  // asks it for a route to the other page.
  const ivy = new Ivy(
    module,
    { signingKey: crypto.getRandomValues(new Uint8Array(32)), listenPort: 0, carriers: [node] },
    { dial: webSocketDialer((endpoint) => (endpoint.publicKey === key ? url : null)) },
  );
  const rtc = new RtcConnector(ivy);
  ivy.delegate = rtc.delegate(sessions);
  await ivy.start();
  await sessions.next((session) => hex(session.key) === key);
  log('ok  the node is this page\'s carrier');

  await ivy.connectViaRelay({ publicKey: peer!, host: 'relay', port: 0 });
  const relayed = await sessions.next((session) => hex(session.key) === peer);
  check(relayed.route.kind === 'relayed', 'met the other page through the node');

  const started = performance.now();
  check(await rtc.upgrade(relayed), 'moved to a data channel between the two pages');
  const direct = await sessions.next((session) => hex(session.key) === peer && session.route.kind === 'direct');
  log(`    in ${Math.round(performance.now() - started)} ms`);

  const fetchStarted = performance.now();
  const fetched = await ivy.fetchVolume(root, { from: direct });
  const expected = volume();
  check(fetched.entries.size === expected.length, `the Volume arrived: ${fetched.entries.size} entries`);
  check(
    expected.every(({ cid, data }) => {
      const got = fetched.entries.get(cid);
      return got?.length === data.length && got.every((byte, index) => byte === data[index]);
    }),
    'every byte of it is what the other page made',
  );
  check(fetched.servedBy === peer, 'served by the other page, from its IndexedDB');
  log(`    8 MiB in ${Math.round(performance.now() - fetchStarted)} ms`);
  rtc.close();
  await ivy.destroy();
  return 'PASS';
}

const result = document.getElementById('result')!;
run().then(
  (verdict) => {
    result.textContent = verdict;
    result.className = 'pass';
  },
  (error: unknown) => {
    result.textContent = `FAIL: ${error instanceof Error ? error.message : String(error)}`;
    result.className = 'fail';
    console.error(error);
  },
);
