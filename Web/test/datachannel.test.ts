import assert from 'node:assert/strict';
import test, { afterEach } from 'node:test';

import {
  type ContentEntry,
  type TransportSink,
  DataChannelTransport,
  dataChannelMessageSize,
  dataChannelWindow,
} from '../src/index.js';
import { type FakeDataChannel, fakeChannelPair } from './fakertc.js';
import { destroyNodes, endpoint, eventually, node, sleep } from './support.js';

afterEach(destroyNodes);

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
  get bytes(): number {
    return this.reads.reduce((sum, read) => sum + read.length, 0);
  }
}

interface End {
  channel: FakeDataChannel;
  transport: DataChannelTransport;
  sink: Sink;
}

function pair(): [End, End] {
  const ends = fakeChannelPair().map((channel) => {
    const transport = new DataChannelTransport(channel, '8.8.1.1');
    const sink = new Sink();
    transport.attach(sink);
    return { channel, transport, sink };
  });
  return [ends[0]!, ends[1]!];
}

function pattern(length: number, salt = 0): Uint8Array {
  const bytes = new Uint8Array(length);
  for (let offset = 0; offset < length; offset++) bytes[offset] = (offset * 31 + (offset >> 8) + salt) & 0xff;
  return bytes;
}

/// Until neither end has anything on its way to the other.
const settled = (...ends: End[]) => eventually(() => ends.every((end) => end.channel.bufferedAmount === 0));

const data = (length: number) => new Uint8Array(1 + length);
const credit = (grant: number) => {
  const message = new Uint8Array(5).fill(1, 0, 1);
  new DataView(message.buffer).setUint32(1, grant);
  return message;
};

test('bytes cross in order, in messages of at most 16 KiB, and are read only when asked for', async () => {
  const [a, b] = pair();
  const sent = pattern(200_000);
  a.transport.send(sent.subarray(0, 150_000));
  a.transport.send(sent.subarray(150_000, 150_001));
  a.transport.send(sent.subarray(150_001));
  assert.ok(a.transport.isWritable);
  assert.ok(await settled(a));
  assert.equal(a.channel.largestMessage, dataChannelMessageSize);
  // Each array sent is split by itself: 10 messages, 1 and 4.
  assert.equal(a.channel.messagesSent, 15);
  // Nothing was asked for, so nothing was handed over.
  assert.equal(b.sink.reads.length, 0);
  assert.equal(b.transport.queuedBytes, 200_000);

  b.transport.requestBytes();
  assert.equal(b.sink.reads.length, 1);
  assert.equal(b.sink.reads[0]!.length, 64 * 1024);
  while (b.sink.bytes < sent.length) {
    const before: number = b.sink.reads.length;
    b.transport.requestBytes();
    assert.equal(b.sink.reads.length, before + 1);
  }
  assert.ok(b.sink.reads.every((read) => read.length <= 64 * 1024));
  assert.ok(Buffer.concat(b.sink.reads).equals(sent));
  assert.equal(b.transport.queuedBytes, 0);

  // A request made with nothing waiting is answered when bytes arrive.
  // Two requests while one is outstanding are one.
  b.transport.requestBytes();
  b.transport.requestBytes();
  assert.equal(b.sink.reads.length, 4);
  a.transport.send(new Uint8Array([7, 8]));
  assert.ok(await eventually(() => b.sink.reads.length === 5));
  a.transport.send(new Uint8Array([9]));
  assert.ok(await settled(a));
  await sleep(20);
  assert.deepEqual(b.sink.reads.slice(4), [new Uint8Array([7, 8])]);
  assert.equal(b.transport.queuedBytes, 1);
  assert.equal(a.sink.drains + b.sink.drains, 0);
});

test('the credit window bounds what a receiver holds while it is not read', async () => {
  const megabyte = 1024 * 1024;
  const [a, b] = pair();
  let peak = 0;
  a.channel.onDelivered = () => (peak = Math.max(peak, b.transport.queuedBytes));

  const sent = pattern(3 * megabyte);
  for (let offset = 0; offset < sent.length; offset += 100_000) {
    a.transport.send(sent.subarray(offset, offset + 100_000));
  }
  assert.ok(!a.transport.isWritable);
  assert.ok(await settled(a));
  await sleep(20);
  // A window crossed and the rest waits at the sender, however long.
  assert.equal(b.transport.queuedBytes, dataChannelWindow);
  assert.ok(!a.transport.isWritable);
  assert.equal(a.sink.drains, 0);

  // Reading a quarter of the window grants that much, and no more crosses.
  const granted = b.channel.messagesSent;
  for (let read = 0; read < 3; read++) b.transport.requestBytes();
  assert.equal(b.channel.messagesSent, granted);
  b.transport.requestBytes();
  assert.equal(b.channel.messagesSent, granted + 1);
  assert.ok(await settled(a, b));
  await sleep(20);
  assert.equal(b.transport.queuedBytes, dataChannelWindow);
  assert.ok(!a.transport.isWritable);

  while (b.sink.bytes < sent.length) {
    b.transport.requestBytes();
    if (b.transport.queuedBytes === 0) await sleep(1);
  }
  assert.ok(await settled(a, b));
  assert.ok(Buffer.concat(b.sink.reads).equals(sent));
  assert.ok(peak <= dataChannelWindow, `peak ${peak}`);
  assert.equal(peak, dataChannelWindow);
  // The sender heard it had room once, when the last of its bytes had gone.
  assert.ok(a.transport.isWritable);
  assert.equal(a.sink.drains, 1);
});

test('a channel whose own buffer is full is not writable until it empties', async () => {
  const [a, b] = pair();
  a.channel.stalled = true;
  const sent = pattern(600_000);
  a.transport.send(sent.subarray(0, 200_000));
  assert.ok(a.transport.isWritable);
  a.transport.send(sent.subarray(200_000));
  // Credit remains; the channel's buffer is what is full.
  assert.ok(!a.transport.isWritable);
  assert.ok(a.channel.bufferedAmount > 256 * 1024);
  assert.ok(a.channel.bufferedAmount <= 256 * 1024 + dataChannelMessageSize);
  await sleep(20);
  assert.equal(a.sink.drains, 0);

  a.channel.stalled = false;
  assert.ok(await eventually(() => a.sink.drains === 1));
  assert.ok(a.transport.isWritable);
  assert.ok(await settled(a));
  assert.equal(a.sink.drains, 1);
  while (b.sink.bytes < sent.length) b.transport.requestBytes();
  assert.ok(Buffer.concat(b.sink.reads).equals(sent));
});

test('a peer that sends past its credit, or anything else out of order, is closed', async () => {
  // More data than the window, to an end that is not reading.
  {
    const [raw, channel] = fakeChannelPair();
    const transport = new DataChannelTransport(channel, '8.8.1.1');
    const sink = new Sink();
    let closed = 0;
    transport.onClosed = () => (closed += 1);
    transport.attach(sink);
    const full = Math.floor(dataChannelWindow / (dataChannelMessageSize - 1));
    for (let message = 0; message < full; message++) raw.send(data(dataChannelMessageSize - 1));
    raw.send(data(dataChannelWindow - full * (dataChannelMessageSize - 1)));
    assert.ok(await eventually(() => raw.bufferedAmount === 0));
    assert.equal(transport.queuedBytes, dataChannelWindow);
    assert.equal(sink.closes, 0);
    raw.send(data(1));
    assert.ok(await eventually(() => sink.closes === 1));
    assert.equal(transport.queuedBytes, 0);
    assert.ok(await eventually(() => raw.readyState === 'closed'));
    assert.equal(closed, 1);
  }

  const refused: [string, Uint8Array<ArrayBuffer> | string][] = [
    ['credit for bytes that were never sent', credit(1)],
    ['a grant of nothing', credit(0)],
    ['a short grant', new Uint8Array([1, 0, 0, 1])],
    ['data with no bytes', data(0)],
    ['an unknown type', new Uint8Array([2, 0])],
    ['a message over 16 KiB', data(dataChannelMessageSize)],
    ['text', 'hello'],
  ];
  for (const [what, message] of refused) {
    const [raw, channel] = fakeChannelPair();
    const transport = new DataChannelTransport(channel, '8.8.1.1');
    const sink = new Sink();
    transport.attach(sink);
    raw.send(message);
    assert.ok(await eventually(() => sink.closes === 1, 1_000), what);
    assert.ok(await eventually(() => raw.readyState === 'closed'), what);
  }

  // A grant for what was sent is taken.
  const [a, b] = pair();
  a.transport.send(new Uint8Array(1000));
  assert.ok(await settled(a));
  b.channel.send(credit(1000));
  b.channel.send(credit(1));
  assert.ok(await eventually(() => a.sink.closes === 1));
});

test('a close is reported once to each end, after what was sent before it', async () => {
  const [a, b] = pair();
  let released = 0;
  b.transport.onClosed = () => (released += 1);
  a.transport.send(pattern(100_000));
  a.transport.close();
  a.transport.close();
  a.transport.send(new Uint8Array([9]));
  assert.ok(await eventually(() => a.sink.closes === 1));
  assert.ok(!a.transport.isWritable);
  assert.ok(await eventually(() => b.channel.readyState === 'closed'));
  await sleep(20);
  // The other end has not read what was sent before the close.
  assert.equal(b.sink.closes, 0);
  assert.equal(released, 0);
  b.transport.requestBytes();
  await sleep(20);
  assert.equal(b.sink.closes, 0);
  b.transport.requestBytes();
  assert.ok(await eventually(() => b.sink.closes === 1));
  assert.ok(Buffer.concat(b.sink.reads).equals(pattern(100_000)));
  assert.equal(released, 1);
  b.transport.close();
  b.transport.requestBytes();
  await sleep(20);
  assert.equal(b.sink.closes, 1);
  assert.equal(a.sink.closes, 1);
  assert.equal(a.sink.reads.length, 0);
  assert.equal(released, 1);

  // What an end had not read when it closed is dropped.
  const [c, d] = pair();
  c.transport.send(new Uint8Array(10));
  assert.ok(await settled(c));
  d.transport.close();
  d.transport.requestBytes();
  assert.ok(await eventually(() => c.sink.closes === 1 && d.sink.closes === 1));
  assert.equal(d.sink.reads.length, 0);

  // One that closed before anyone listened says so when someone does, and
  // so does one made on a channel that had already closed.
  const [e, f] = fakeChannelPair();
  const early = new DataChannelTransport(e, '8.8.1.1');
  early.close();
  assert.ok(await eventually(() => f.readyState === 'closed'));
  const late = new DataChannelTransport(f, '8.8.1.1');
  const sinks = [new Sink(), new Sink()];
  early.attach(sinks[0]!);
  late.attach(sinks[1]!);
  await sleep(20);
  assert.deepEqual(sinks.map((sink) => sink.closes), [1, 1]);
});

test('a 20 MiB Volume is fetched over a data channel by a slow reader', async () => {
  const megabyte = 1024 * 1024;
  const entries: ContentEntry[] = [{ cid: 'vol', data: new Uint8Array(512).fill(1) }];
  for (let index = 0; index < 20; index++) {
    entries.push({ cid: `vol-${String(index).padStart(2, '0')}`, data: pattern(megabyte, index) });
  }
  const a = node();
  const b = node({ contentSource: { volume: async (rootCID) => (rootCID === 'vol' ? entries : []) } });
  await a.start();
  await b.start();
  const [near, far] = fakeChannelPair();
  const reader = new DataChannelTransport(near, '8.8.2.1');
  const server = new DataChannelTransport(far, '8.8.1.1');

  // The reader takes one read every few turns of the event loop, far
  // slower than the channel delivers.
  const request = reader.requestBytes.bind(reader);
  reader.requestBytes = () => void sleep(1).then(request);
  let peak = 0;
  far.onDelivered = () => (peak = Math.max(peak, reader.queuedBytes));
  let timesFull = 0;
  let buffered = 0;
  const send = server.send.bind(server);
  server.send = (bytes) => {
    send(bytes);
    buffered = Math.max(buffered, far.bufferedAmount);
    if (!server.isWritable) timesFull += 1;
  };

  b.accept(server);
  await a.connect(endpoint(b), reader);
  const volume = await a.fetchVolume('vol');
  assert.equal(volume.failure, null);
  assert.equal(volume.servedBy, b.localID);
  assert.equal(volume.entries.size, entries.length);
  for (const entry of entries) {
    assert.ok(Buffer.from(volume.entries.get(entry.cid)!).equals(entry.data), entry.cid);
  }
  // The reader never held more than the window, the channel's buffer never
  // more than its mark and a message, and the server waited again and again.
  assert.equal(peak, dataChannelWindow);
  assert.ok(buffered <= 256 * 1024 + dataChannelMessageSize, `buffered ${buffered}`);
  assert.ok(timesFull >= 3, `full ${timesFull} times`);
  assert.equal(far.largestMessage, dataChannelMessageSize);
});
