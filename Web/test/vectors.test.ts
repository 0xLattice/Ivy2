import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { decodeEffect, decodeEvent, encodeEffect, encodeEvent, fromHex, hex, version } from '../src/index.js';

// Written by the Swift suite (EventCodecTests), which fails if this file
// and its own encoder disagree. Reproducing every vector here is what keeps
// the two codecs the same.
interface Vectors {
  version: number;
  events: { description: string; hex: string }[];
  effects: { description: string; hex: string }[];
}

const vectors: Vectors = JSON.parse(
  await readFile(new URL('../../test/vectors.json', import.meta.url), 'utf8'),
);

test('the vectors are of this codec version', () => {
  assert.equal(vectors.version, version);
  assert.ok(vectors.events.length > 0 && vectors.effects.length > 0);
});

test('every event vector decodes and encodes to the same bytes', () => {
  for (const vector of vectors.events) {
    assert.equal(hex(encodeEvent(decodeEvent(fromHex(vector.hex)))), vector.hex, vector.description);
  }
});

test('every effect vector decodes and encodes to the same bytes', () => {
  for (const vector of vectors.effects) {
    assert.equal(hex(encodeEffect(decodeEffect(fromHex(vector.hex)))), vector.hex, vector.description);
  }
});

test('a vector decodes to what its description says', () => {
  const find = (list: Vectors['events'], description: string) =>
    fromHex(list.find((vector) => vector.description === description)!.hex);
  assert.deepEqual(decodeEvent(find(vectors.events, 'request: fetchVolume, limited')), {
    kind: 'request',
    id: 9n,
    request: { kind: 'fetchVolume', rootCID: 'root', maximumArchiveBytes: 1048576n, maximumEntries: 16n },
  });
  const sessions = decodeEvent(find(vectors.events, 'request: fetchVolumeFromSessions, two sessions'));
  assert.ok(sessions.kind === 'request' && sessions.request.kind === 'fetchVolumeFromSessions');
  assert.equal(sessions.id, 17n);
  assert.equal(sessions.request.from.length, 2);
  assert.deepEqual(
    [sessions.request.rootCID, sessions.request.maximumArchiveBytes, sessions.request.maximumEntries],
    ['root', 4096n, 1n],
  );
  const preferring = decodeEvent(find(vectors.events, 'request: fetchVolumePreferring, two peers'));
  assert.ok(preferring.kind === 'request' && preferring.request.kind === 'fetchVolumePreferring');
  assert.equal(preferring.request.preferred.length, 2);
  assert.deepEqual(
    [preferring.request.rootCID, preferring.request.maximumArchiveBytes, preferring.request.maximumEntries],
    ['root', 4096n, 1n],
  );
  assert.deepEqual(decodeEffect(find(vectors.effects, 'wakeAt: 90.5 seconds')), {
    kind: 'wakeAt',
    deadline: { seconds: 90n, attoseconds: 500_000_000_000_000_000n },
  });
  const volume = decodeEffect(find(vectors.effects, 'completed: volume, three entries in identifier order'));
  assert.ok(volume.kind === 'completed' && volume.result.kind === 'volume');
  assert.deepEqual([...volume.result.response.entries.keys()], ['leaf', 'root', 'root-0']);
  assert.deepEqual(volume.result.response.entries.get('root'), new Uint8Array([1, 2, 3]));
});

test('volume entries are encoded in byte order whatever order they were added in', () => {
  const entries = new Map([
    ['b', new Uint8Array([2])],
    ['\u{10000}', new Uint8Array([4])],
    ['\u{ff5e}', new Uint8Array([3])],
    ['a', new Uint8Array([1])],
  ]);
  const decoded = decodeEffect(
    encodeEffect({
      kind: 'completed',
      id: 1n,
      result: { kind: 'volume', response: { rootCID: 'a', entries, servedBy: null, failure: null } },
    }),
  );
  assert.ok(decoded.kind === 'completed' && decoded.result.kind === 'volume');
  // UTF-8 order, which is not the order of UTF-16 code units.
  assert.deepEqual([...decoded.result.response.entries.keys()], ['a', 'b', '\u{ff5e}', '\u{10000}']);
});

test('truncated and malformed bytes are refused', () => {
  for (const vector of [...vectors.events, ...vectors.effects]) {
    const bytes = fromHex(vector.hex);
    const decode = vectors.events.includes(vector) ? decodeEvent : decodeEffect;
    for (let length = 0; length < bytes.length; length++) {
      assert.throws(() => decode(bytes.subarray(0, length)), `${vector.description} cut to ${length}`);
    }
    assert.throws(() => decode(new Uint8Array([...bytes, 0])), vector.description);
  }
  assert.throws(() => decodeEvent(new Uint8Array([version + 1, 0])), 'another version');
  assert.throws(() => decodeEvent(new Uint8Array([1, 14])), 'unknown event');
  assert.throws(() => decodeEffect(new Uint8Array([1, 14])), 'unknown effect');
  // A topic that is not UTF-8.
  assert.throws(() => decodeEvent(new Uint8Array([1, 10, 2, 0, 0, 0, 1, 0xff, 0, 0, 0, 0])));
});

test('a number that does not fit its field is refused, not wrapped', () => {
  assert.throws(() =>
    encodeEvent({ kind: 'publicAddress', address: { host: '8.8.1.1', port: 70000 } }),
  );
});
