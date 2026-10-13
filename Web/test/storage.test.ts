import 'fake-indexeddb/auto';

import assert from 'node:assert/strict';
import test, { afterEach } from 'node:test';

import {
  type ContentEntry,
  type VolumeStore,
  type VolumeStoreOptions,
  IndexedDBContentSource,
  MemoryContentSource,
  hex,
  volumeArchiveBytes,
} from '../src/index.js';
import { Recorder, destroyNodes, join, node } from './support.js';

afterEach(destroyNodes);

let databases = 0;

// Every test runs against both stores.
const stores: [string, (options: VolumeStoreOptions) => Promise<VolumeStore>][] = [
  ['memory', async (options) => new MemoryContentSource(options)],
  ['IndexedDB', (options) => IndexedDBContentSource.open(`test-${++databases}`, options)],
];

/// A Volume of a root and one more entry, `size` bytes of data in all.
function volume(root: string, size: number, fill = 1): ContentEntry[] {
  return [
    { cid: root, data: new Uint8Array(16).fill(fill) },
    { cid: `${root}-1`, data: new Uint8Array(size - 16).fill(fill + 1) },
  ];
}

const never = new AbortController().signal;
const unbounded = Number.MAX_SAFE_INTEGER;

for (const [name, open] of stores) {
  test(`${name}: a Volume is stored, read, listed and deleted`, async () => {
    const store = await open({ budget: 1_000_000 });
    assert.deepEqual(await store.volume('a', unbounded, never), []);
    assert.equal(await store.has('a'), false);

    const entries = volume('a', 1000);
    // As a fetched entry is: a view of a larger buffer.
    entries[1]!.data = new Uint8Array(4096).fill(9).subarray(100, 1084);
    await store.put('a', entries);
    await store.put('b', volume('b', 500));
    assert.equal(await store.has('a'), true);
    assert.deepEqual((await store.roots()).sort(), ['a', 'b']);
    const read = await store.volume('a', unbounded, never);
    assert.deepEqual(
      read.map((entry) => [entry.cid, Buffer.from(entry.data).toString('hex')]),
      entries.map((entry) => [entry.cid, Buffer.from(entry.data).toString('hex')]),
    );

    // Storing a root again replaces what was there.
    await store.put('a', volume('a', 200, 5));
    assert.equal((await store.volume('a', unbounded, never))[1]!.data.length, 184);

    await store.delete('a');
    await store.delete('absent');
    assert.equal(await store.has('a'), false);
    assert.deepEqual(await store.volume('a', unbounded, never), []);
    assert.deepEqual(await store.roots(), ['b']);
  });

  test(`${name}: a Volume larger than the caller's bound, or asked for after an abort, is not read`, async () => {
    const store = await open({ budget: 1_000_000 });
    const entries = volume('a', 1000);
    await store.put('a', entries);
    const size = volumeArchiveBytes(entries);
    assert.equal(size, 2 + (2 + 1 + 4 + 16) + (2 + 3 + 4 + 984));
    assert.equal((await store.volume('a', size, never)).length, 2);
    assert.deepEqual(await store.volume('a', size - 1, never), []);

    const aborted = new AbortController();
    aborted.abort();
    assert.deepEqual(await store.volume('a', unbounded, aborted.signal), []);
    const aborting = new AbortController();
    const reading = store.volume('a', unbounded, aborting.signal);
    aborting.abort();
    // Either answer is the one answer; it must not throw or hang.
    assert.ok([0, 2].includes((await reading).length));
  });

  test(`${name}: over its budget, the Volume served longest ago goes first`, async () => {
    const each = volumeArchiveBytes(volume('a', 1000));
    const store = await open({ budget: 3 * each });
    await store.put('a', volume('a', 1000));
    await store.put('b', volume('b', 1000));
    await store.put('c', volume('c', 1000));
    assert.deepEqual((await store.roots()).sort(), ['a', 'b', 'c']);

    // Serving `a` makes `b` the one served longest ago.
    assert.equal((await store.volume('a', unbounded, never)).length, 2);
    await store.put('d', volume('d', 1000));
    assert.deepEqual((await store.roots()).sort(), ['a', 'c', 'd']);

    // One that needs the room of two takes it from the two served longest ago.
    await store.put('e', volume('e', 2000 - 16));
    assert.deepEqual((await store.roots()).sort(), ['d', 'e']);
    // Replacing a Volume counts its new size, not both.
    await store.put('e', volume('e', 2000 - 16, 3));
    assert.deepEqual((await store.roots()).sort(), ['d', 'e']);

    // One that could never fit is refused and nothing is dropped for it.
    await assert.rejects(store.put('f', volume('f', 4000)), RangeError);
    assert.deepEqual((await store.roots()).sort(), ['d', 'e']);
  });

  test(`${name}: a bundle lasts as long as the Volume it is under`, async () => {
    const store = await open({ budget: 1_000_000 });
    assert.equal(await store.putBundle('a', ['a', 'b']), false);
    assert.deepEqual(await store.volumeBundle('a', never), []);
    await store.put('a', volume('a', 100));
    assert.equal(await store.putBundle('a', ['a', 'b']), true);
    assert.deepEqual(await store.volumeBundle('a', never), ['a', 'b']);
    await store.put('a', volume('a', 200));
    assert.deepEqual(await store.volumeBundle('a', never), ['a', 'b']);
    await store.delete('a');
    assert.deepEqual(await store.volumeBundle('a', never), []);
  });

  test(`${name}: one node serves a Volume and a bundle from the store to another`, async () => {
    const megabyte = 1024 * 1024;
    const allowed = new Set(['big', 'second']);
    const asked: string[] = [];
    const store = await open({
      budget: 8 * megabyte,
      authorizes: (peer, rootCID) => {
        asked.push(`${hex(peer.key)} ${rootCID}`);
        return allowed.has(rootCID);
      },
    });
    const entries = volume('big', 3 * megabyte);
    for (let offset = 0; offset < entries[1]!.data.length; offset++) entries[1]!.data[offset] = (offset * 31) & 0xff;
    await store.put('big', entries);
    await store.put('second', volume('second', 1000));
    await store.put('private', volume('private', 1000));
    await store.putBundle('big', ['big', 'second']);

    const heard = new Recorder();
    const a = node({ delegate: heard });
    const b = node({ contentSource: store });
    await a.start();
    await b.start();
    await join(a, b);

    const fetched = await a.fetchVolume('big');
    assert.equal(fetched.servedBy, b.localID);
    assert.equal(fetched.entries.size, 2);
    for (const entry of entries) {
      assert.ok(Buffer.from(fetched.entries.get(entry.cid)!).equals(entry.data), entry.cid);
    }
    assert.ok(asked.includes(`${a.localID} big`));

    const session = heard.sessions[0]!;
    assert.equal((await a.fetchVolume('private', { from: session })).entries.size, 0);
    assert.equal((await a.fetchVolume('absent', { from: session })).entries.size, 0);

    const bundle = await a.fetchVolumeBundle('big', [session]);
    assert.deepEqual(
      bundle.volumes.map((each) => [each.rootCID, each.entries.size]),
      [
        ['big', 2],
        ['second', 2],
      ],
    );

    // What was fetched can be stored and served in turn.
    const kept = await open({ budget: 8 * megabyte });
    await kept.put('big', [...fetched.entries].map(([cid, data]) => ({ cid, data })));
    assert.equal(volumeArchiveBytes(await kept.volume('big', unbounded, never)), volumeArchiveBytes(entries));
  });
}

test('IndexedDB: what is stored is there when the database is opened again', async () => {
  const each = volumeArchiveBytes(volume('a', 1000));
  const first = await IndexedDBContentSource.open('reopened', { budget: 2 * each });
  await first.put('a', volume('a', 1000));
  await first.put('b', volume('b', 1000));
  await first.volume('a', unbounded, never);
  first.close();

  const second = await IndexedDBContentSource.open('reopened', { budget: 2 * each });
  assert.deepEqual((await second.roots()).sort(), ['a', 'b']);
  // The order of serving is kept with the Volumes.
  await second.put('c', volume('c', 1000));
  assert.deepEqual((await second.roots()).sort(), ['a', 'c']);
  second.close();
});
