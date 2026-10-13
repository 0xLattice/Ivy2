import assert from 'node:assert/strict';
import test from 'node:test';

import { type TransportSink, memoryPair } from '../src/index.js';
import { sleep } from './support.js';

class Sink implements TransportSink {
  readonly reads: Uint8Array[] = [];
  drains = 0;
  closes = 0;
  received(bytes: Uint8Array) {
    this.reads.push(bytes);
  }
  drained() {
    this.drains += 1;
  }
  closed() {
    this.closes += 1;
  }
}

test('bytes are delivered only when asked for, one read a request', async () => {
  const [a, b] = memoryPair({ readSize: 4 });
  const sink = new Sink();
  a.attach(new Sink());
  b.attach(sink);
  a.send(new Uint8Array([1, 2, 3, 4, 5, 6]));
  a.send(new Uint8Array([7]));
  await sleep(5);
  assert.equal(sink.reads.length, 0);

  b.requestBytes();
  await sleep(5);
  assert.deepEqual(sink.reads, [new Uint8Array([1, 2, 3, 4])]);
  b.requestBytes();
  b.requestBytes();
  await sleep(5);
  // Two requests while one was outstanding are one request.
  assert.deepEqual(sink.reads.slice(1), [new Uint8Array([5, 6])]);
  b.requestBytes();
  await sleep(5);
  assert.deepEqual(sink.reads.slice(2), [new Uint8Array([7])]);
  assert.equal(b.requests, 4);
  assert.equal(b.observedHost, '8.8.1.1');
  assert.equal(a.observedHost, '8.8.2.1');
});

test('a full stream says so and reports when it has room', async () => {
  const [a, b] = memoryPair({ capacity: 8, readSize: 4 });
  const writer = new Sink();
  a.attach(writer);
  b.attach(new Sink());
  a.send(new Uint8Array(6));
  assert.ok(a.isWritable);
  a.send(new Uint8Array(6));
  assert.ok(!a.isWritable);
  assert.equal(a.queuedBytes, 12);

  b.requestBytes();
  await sleep(5);
  assert.ok(!a.isWritable);
  assert.equal(writer.drains, 0);
  b.requestBytes();
  await sleep(5);
  assert.ok(a.isWritable);
  assert.equal(writer.drains, 1);
});

test('a close is reported once to each end, after what was sent before it', async () => {
  const [a, b] = memoryPair();
  const closer = new Sink();
  const other = new Sink();
  a.attach(closer);
  b.attach(other);
  a.send(new Uint8Array([1, 2]));
  a.close();
  a.close();
  await sleep(5);
  assert.equal(closer.closes, 1);
  // The other end has not read what was sent before the close.
  assert.equal(other.closes, 0);
  b.requestBytes();
  await sleep(5);
  assert.deepEqual(other.reads, [new Uint8Array([1, 2])]);
  assert.equal(other.closes, 1);
  b.close();
  b.send(new Uint8Array([3]));
  await sleep(5);
  assert.equal(other.closes, 1);
  assert.equal(closer.closes, 1);
  assert.equal(closer.reads.length, 0);

  // One that closed before anyone listened says so when someone does.
  const [c] = memoryPair();
  c.close();
  const late = new Sink();
  c.attach(late);
  await sleep(5);
  assert.equal(late.closes, 1);
});
