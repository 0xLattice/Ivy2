import assert from 'node:assert/strict';
import { type ChildProcess, spawn } from 'node:child_process';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { createInterface } from 'node:readline';
import test, { after, afterEach } from 'node:test';

import {
  type PeerEndpoint,
  type TransportSink,
  IvyError,
  WebSocketTransport,
  connectWebSocket,
  memoryPair,
  webSocketDialer,
} from '../src/index.js';
import { Recorder, destroyNodes, endpoint, eventually, node, sleep } from './support.js';

afterEach(destroyNodes);

// MARK: - The transport alone, over a socket made here

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

/// As much of a WebSocket as the transport uses.
class FakeSocket extends EventTarget {
  binaryType = '';
  readyState: number = WebSocket.OPEN;
  bufferedAmount = 0;
  readonly sent: Uint8Array[] = [];
  closes = 0;

  constructor(readonly url = 'ws://203.0.113.7:4001/ivy') {
    super();
  }

  send(data: Uint8Array) {
    this.sent.push(data);
    this.bufferedAmount += data.length;
  }

  close() {
    this.closes += 1;
    if (this.readyState === WebSocket.CLOSED) return;
    this.readyState = WebSocket.CLOSED;
    queueMicrotask(() => this.dispatchEvent(new Event('close')));
  }

  message(data: ArrayBuffer | string) {
    this.dispatchEvent(new MessageEvent('message', { data }));
  }
}

function transportOver(socket: FakeSocket): [WebSocketTransport, Sink] {
  const transport = new WebSocketTransport(socket as unknown as WebSocket);
  const sink = new Sink();
  transport.attach(sink);
  return [transport, sink];
}

const bytes = (length: number, fill = 0) => new Uint8Array(length).fill(fill);

test('a WebSocket delivers only what is asked for, at most 64 KiB a read', async () => {
  const socket = new FakeSocket();
  const [transport, sink] = transportOver(socket);
  assert.equal(socket.binaryType, 'arraybuffer');
  socket.message(bytes(100_000, 1).buffer);
  socket.message(new ArrayBuffer(0));
  socket.message(new Uint8Array([2, 3]).buffer);
  await sleep(5);
  assert.equal(sink.reads.length, 0);

  transport.requestBytes();
  transport.requestBytes();
  await sleep(5);
  assert.deepEqual(sink.reads, [bytes(65_536, 1)]);
  transport.requestBytes();
  await sleep(5);
  assert.deepEqual(sink.reads.slice(1), [bytes(100_000 - 65_536, 1)]);
  transport.requestBytes();
  await sleep(5);
  assert.deepEqual(sink.reads.slice(2), [new Uint8Array([2, 3])]);

  // A request made before the bytes are there is answered when they are.
  transport.requestBytes();
  await sleep(5);
  assert.equal(sink.reads.length, 3);
  socket.message(new Uint8Array([4]).buffer);
  await sleep(5);
  assert.deepEqual(sink.reads.slice(3), [new Uint8Array([4])]);
  assert.equal(sink.closes, 0);
});

test('a WebSocket sends messages of at most 64 KiB and reports when it has drained', async () => {
  const socket = new FakeSocket();
  const [transport, sink] = transportOver(socket);
  transport.send(bytes(1000));
  assert.ok(transport.isWritable);
  transport.send(bytes(150_000, 7));
  assert.deepEqual(
    socket.sent.map((message) => message.length),
    [1000, 65_536, 65_536, 150_000 - 2 * 65_536],
  );
  // Straight after the send, as the shell reads it.
  assert.ok(!transport.isWritable);

  socket.bufferedAmount = 40_000;
  await sleep(100);
  assert.ok(transport.isWritable);
  assert.equal(sink.drains, 0, 'not until the low mark');
  socket.bufferedAmount = 30_000;
  // Past the first turns of the event loop the socket is looked at on a timer.
  assert.ok(await eventually(() => sink.drains === 1));
  await sleep(50);
  assert.equal(sink.drains, 1);

  // A socket that drains at once is seen without waiting for a timer.
  transport.send(bytes(70_000));
  socket.bufferedAmount = 0;
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(sink.drains, 2);
});

test('a WebSocket reports its close once, after the bytes that came before it', async () => {
  const socket = new FakeSocket();
  const [transport, sink] = transportOver(socket);
  socket.message(new Uint8Array([1, 2]).buffer);
  socket.close();
  await sleep(5);
  // What arrived before the close has not been read.
  assert.equal(sink.closes, 0);
  transport.send(bytes(10));
  assert.equal(socket.sent.length, 0);
  transport.requestBytes();
  await sleep(5);
  assert.deepEqual(sink.reads, [new Uint8Array([1, 2])]);
  assert.equal(sink.closes, 1);
  transport.close();
  transport.requestBytes();
  await sleep(5);
  assert.equal(sink.closes, 1);

  // Closed from this side: what was not read is dropped.
  const other = new FakeSocket();
  const [closer, closerSink] = transportOver(other);
  other.message(new Uint8Array([1]).buffer);
  closer.close();
  closer.close();
  closer.requestBytes();
  await sleep(5);
  assert.equal(other.closes, 1);
  assert.equal(closerSink.reads.length, 0);
  assert.equal(closerSink.closes, 1);

  // One that closed before anyone listened says so when someone does.
  const gone = new FakeSocket();
  gone.readyState = WebSocket.CLOSED;
  const late = new WebSocketTransport(gone as unknown as WebSocket);
  const lateSink = new Sink();
  late.attach(lateSink);
  await sleep(5);
  assert.equal(lateSink.closes, 1);
});

test('a text message or an error closes a WebSocket', async () => {
  const texted = new FakeSocket();
  const [, textSink] = transportOver(texted);
  texted.message(new Uint8Array([1]).buffer);
  texted.message('text');
  await sleep(5);
  assert.equal(texted.closes, 1);
  assert.equal(textSink.closes, 1);

  const failed = new FakeSocket();
  const [, failedSink] = transportOver(failed);
  failed.dispatchEvent(new Event('error'));
  await sleep(5);
  assert.equal(failed.closes, 1);
  assert.equal(failedSink.closes, 1);
});

test('a WebSocket that is sent more than it may hold unread is closed', async () => {
  const socket = new FakeSocket();
  const transport = new WebSocketTransport(socket as unknown as WebSocket, 100_000);
  const sink = new Sink();
  transport.attach(sink);
  // Nothing is asked for, so everything queues.
  socket.message(bytes(60_000).buffer);
  await sleep(5);
  assert.equal(socket.closes, 0);
  socket.message(bytes(60_000).buffer);
  await sleep(5);
  assert.equal(socket.closes, 1);
  assert.equal(sink.closes, 1);
});

test('a WebSocket is observed at the host its URL names', () => {
  const observed = (url: string) => new WebSocketTransport(new FakeSocket(url) as unknown as WebSocket).observedHost;
  assert.equal(observed('ws://203.0.113.7:4001/ivy'), '203.0.113.7');
  assert.equal(observed('ws://[2001:db8::1]:4001/ivy'), '2001:db8::1');
  assert.equal(observed('wss://Node.Example/ivy'), 'node.example');
  assert.equal(new WebSocketTransport(new FakeSocket() as unknown as WebSocket).localHost, null);
});

test('the core admits streams observed at a hostname, each name a netgroup of its own', async () => {
  const a = node({}, { maxConnectionsPerNetgroup: 1 });
  const peers = [node(), node(), node()];
  await a.start();
  for (const peer of peers) await peer.start();
  // Two names, one stream each: both are admitted under a limit of one.
  for (const [index, name] of ['one.example', 'two.example'].entries()) {
    const [left, right] = memoryPair({ hosts: ['8.8.1.1', name] });
    peers[index]!.accept(right);
    await a.connect(endpoint(peers[index]!, name), left);
  }
  assert.equal(a.connectedPeers.length, 2);
  // A second stream to a name already connected is over the limit.
  const [left, right] = memoryPair({ hosts: ['8.8.1.1', 'one.example'] });
  peers[2]!.accept(right);
  await assert.rejects(a.connect(endpoint(peers[2]!, 'one.example'), left), IvyError);
  assert.equal(a.connectedPeers.length, 2);
});

// MARK: - Against a native node

const executable = process.env.IVY_TEST_NODE;
const skip = executable === undefined ? 'set IVY_TEST_NODE to a built IvyWebSocketTestNode' : false;

interface TestNode {
  child: ChildProcess;
  url: string;
  endpoint: PeerEndpoint;
}

const children: ChildProcess[] = [];

/// Starts a native node, which exits when its standard input closes.
async function startNode(): Promise<TestNode> {
  const child = spawn(executable!, ['2a'.repeat(32)], { stdio: ['pipe', 'pipe', 'inherit'] });
  children.push(child);
  const [line] = (await once(createInterface(child.stdout!), 'line')) as [string];
  const { publicKey, port } = JSON.parse(line) as { publicKey: string; port: number };
  return { child, url: `ws://127.0.0.1:${port}/ivy`, endpoint: { publicKey, host: '127.0.0.1', port } };
}

let sharedNode: Promise<TestNode> | undefined;
const native = () => (sharedNode ??= startNode());

after(() => {
  for (const child of children) child.stdin!.end();
});

/// The entry the native node serves as `cid`: see its `Volumes`.
function served(cid: string, index: number, count: number) {
  const data = new Uint8Array(count);
  for (let offset = 0; offset < count; offset++) data[offset] = (offset * 31 + index) & 0xff;
  return { cid, data };
}

test('a shell authenticates to a native node over WebSocket and hears its echo', { skip }, async () => {
  const peer = await native();
  const heard = new Recorder();
  const ivy = node({ delegate: heard });
  await ivy.start();
  const transport = await connectWebSocket(peer.url);
  assert.equal(transport.observedHost, '127.0.0.1');
  await ivy.connect(peer.endpoint, transport);
  assert.deepEqual(ivy.connectedPeers, [peer.endpoint.publicKey]);

  const payload = new TextEncoder().encode('over a real socket');
  assert.equal((await ivy.sendMessage(peer.endpoint.publicKey, 'hello', payload)).kind, 'enqueued');
  assert.ok(await eventually(() => heard.messages.length === 1));
  assert.deepEqual(heard.messages[0], { topic: 'hello', payload });

  // More than the socket takes at once: sends are refused until it drains.
  let refused = 0;
  for (let index = 0; index < 40; index++) {
    const message = new Uint8Array(200_000).fill(index);
    while ((await ivy.sendMessage(peer.endpoint.publicKey, `t${index}`, message)).kind === 'backpressured') {
      refused += 1;
      assert.ok(await ivy.waitUntilWritable(peer.endpoint.publicKey));
    }
  }
  assert.ok(await eventually(() => heard.messages.length === 41));
  assert.ok(refused > 0, 'the socket was never full');
  for (const [index, message] of heard.messages.slice(1).entries()) {
    assert.equal(message.topic, `t${index}`);
    assert.ok(Buffer.from(message.payload).equals(new Uint8Array(200_000).fill(index)), message.topic);
  }
});

test('a 12 MiB Volume is fetched from a native node over WebSocket', { skip }, async () => {
  const peer = await native();
  const ivy = node();
  await ivy.start();
  await ivy.connect(peer.endpoint, await connectWebSocket(peer.url));

  const volume = await ivy.fetchVolume('large');
  assert.equal(volume.failure, null);
  assert.equal(volume.servedBy, peer.endpoint.publicKey);
  const entries = [served('large', 0, 512)];
  for (let index = 1; index <= 12; index++) entries.push(served(`large-${index}`, index, 1024 * 1024));
  assert.equal(volume.entries.size, entries.length);
  for (const entry of entries) {
    assert.ok(Buffer.from(volume.entries.get(entry.cid)!).equals(entry.data), entry.cid);
  }
});

test('the core dials a native node through webSocketDialer', { skip }, async () => {
  const peer = await native();
  const asked: PeerEndpoint[] = [];
  const ivy = node({
    dial: webSocketDialer((endpoint) => {
      asked.push(endpoint);
      return `ws://${endpoint.host}:${endpoint.port}/ivy`;
    }),
  });
  await ivy.start();
  await ivy.connect(peer.endpoint);
  assert.deepEqual(asked, [peer.endpoint]);
  assert.deepEqual(ivy.connectedPeers, [peer.endpoint.publicKey]);
  assert.equal((await ivy.fetchVolume('small')).entries.size, 1);
});

test('a native node answers STUN where its WebSocket was reached', { skip }, async () => {
  const peer = await native();
  const ivy = node({ dial: webSocketDialer(() => peer.url) });
  await ivy.start();
  assert.equal(ivy.reachedAt(peer.endpoint.publicKey), undefined);
  await ivy.connect(peer.endpoint);
  const reached = ivy.reachedAt(peer.endpoint.publicKey);
  assert.deepEqual(reached, peer.endpoint);

  // A Binding request, as a browser gathering its addresses sends.
  const transaction = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
  const cookie = [0x21, 0x12, 0xa4, 0x42];
  const socket = createSocket('udp4');
  try {
    socket.bind(0, '127.0.0.1');
    await once(socket, 'listening');
    socket.send(Uint8Array.from([0, 1, 0, 0, ...cookie, ...transaction]), reached!.port, reached!.host);
    const [reply] = (await once(socket, 'message')) as [Buffer];
    // A success response, whose one attribute is XOR-MAPPED-ADDRESS.
    assert.deepEqual([...reply.subarray(0, 20)], [1, 1, 0, 12, ...cookie, ...transaction]);
    assert.deepEqual([...reply.subarray(20, 26)], [0, 0x20, 0, 8, 0, 1]);
    assert.equal(reply.readUInt16BE(26) ^ 0x2112, socket.address().port);
    assert.deepEqual(
      [...reply.subarray(28)].map((byte, index) => byte ^ cookie[index]!),
      [127, 0, 0, 1],
    );
  } finally {
    socket.close();
  }
});

test('a native node that closes ends the session', { skip }, async () => {
  const peer = await startNode();
  const heard = new Recorder();
  const ivy = node({ delegate: heard });
  await ivy.start();
  await ivy.connect(peer.endpoint, await connectWebSocket(peer.url));
  assert.deepEqual(heard.log, ['connected']);

  peer.child.stdin!.end();
  assert.ok(await eventually(() => heard.log.includes('disconnected')));
  assert.deepEqual(ivy.connectedPeers, []);
  if (peer.child.exitCode === null) await once(peer.child, 'exit');
  assert.equal(peer.child.exitCode, 0);
});

test('a dial to a closed port fails', { skip }, async () => {
  const peer = await native();
  // A port nothing listens on: one that was just given back.
  const server = createServer().listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address() as { port: number };
  server.close();
  await once(server, 'close');

  await assert.rejects(connectWebSocket(`ws://127.0.0.1:${port}/ivy`), /did not open/);
  const ivy = node({ dial: webSocketDialer((endpoint) => `ws://${endpoint.host}:${endpoint.port}/ivy`) });
  await ivy.start();
  await assert.rejects(ivy.connect({ ...peer.endpoint, port }), IvyError);
  assert.deepEqual(ivy.connectedPeers, []);
  // An endpoint with no WebSocket address fails the same way.
  const unreachable = node({ dial: webSocketDialer(() => null) });
  await unreachable.start();
  await assert.rejects(unreachable.connect(peer.endpoint), IvyError);
});

test('connecting to a native node under another public key fails and closes the socket', { skip }, async () => {
  const peer = await native();
  const ivy = node();
  const other = node();
  await ivy.start();
  const socket = new WebSocket(peer.url);
  await once(socket, 'open');
  await assert.rejects(
    ivy.connect({ ...peer.endpoint, publicKey: other.localID }, new WebSocketTransport(socket)),
    (error: unknown) => error instanceof IvyError && error.code === 'identityVerificationFailed',
  );
  assert.deepEqual(ivy.connectedPeers, []);
  assert.ok(await eventually(() => socket.readyState === WebSocket.CLOSED));
});
