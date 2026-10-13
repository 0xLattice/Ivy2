// One node in this page and one elsewhere, reached over WebSocket:
//
//   node.html?node=ws://host:port/ivy&key=<its public key, hex>&volume=<root>
//
// The page connects, fetches the Volume, keeps it in IndexedDB and reads it
// back. Writes PASS or the failure into the document. Nothing here waits on
// a timer, which a browser slows in a tab that is not showing.

import { IndexedDBContentSource, Ivy, IvyModule, connectWebSocket, volumeArchiveBytes } from '../src/index.js';

const log = (line: string) => {
  document.getElementById('log')!.textContent += `${line}\n`;
};

function check(condition: boolean, what: string) {
  if (!condition) throw new Error(what);
  log(`ok  ${what}`);
}

async function run() {
  const query = new URLSearchParams(location.search);
  const [address, key, root] = [query.get('node'), query.get('key'), query.get('volume')];
  if (address === null || key === null || root === null) {
    throw new Error('the address needs ?node=ws://host:port/ivy&key=<hex>&volume=<root>');
  }

  const response = await fetch(new URL('../ivy.wasm', import.meta.url));
  if (!response.ok) throw new Error(`dist/ivy.wasm: ${response.status}; run Web/build.sh`);
  const module = await IvyModule.load(await response.arrayBuffer());
  const ivy = new Ivy(module, { signingKey: crypto.getRandomValues(new Uint8Array(32)), listenPort: 0 });
  await ivy.start();

  const url = new URL(address);
  const port = Number(url.port) || (url.protocol === 'wss:' ? 443 : 80);
  const transport = await connectWebSocket(url);
  await ivy.connect({ publicKey: key, host: transport.observedHost, port }, transport);
  check(ivy.connectedPeers[0] === key, `connected to ${url.host} and it proved its key`);

  const started = performance.now();
  const volume = await ivy.fetchVolume(root);
  check(volume.entries.size > 0, `the Volume ${root} arrived: ${volume.entries.size} entries`);
  check(volume.servedBy === key, 'served by that node');
  const entries = [...volume.entries].map(([cid, data]) => ({ cid, data }));
  const bytes = volumeArchiveBytes(entries);
  log(`${bytes} bytes in ${Math.round(performance.now() - started)} ms`);

  const store = await IndexedDBContentSource.open('ivy-demo', { budget: 256 * 1024 * 1024 });
  await store.put(root, entries);
  check(await store.has(root), 'stored in IndexedDB');
  const kept = await store.volume(root, bytes, new AbortController().signal);
  check(
    kept.length === entries.length &&
      kept.every(({ cid, data }) => {
        const fetched = volume.entries.get(cid);
        return fetched?.length === data.length && fetched.every((byte, index) => byte === data[index]);
      }),
    'every byte read back from it is what was fetched',
  );
  store.close();
  await ivy.destroy();
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
