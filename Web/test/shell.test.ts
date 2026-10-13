import assert from 'node:assert/strict';
import test, { afterEach } from 'node:test';

import { type ContentEntry, type Transport, IvyError, hex, memoryPair } from '../src/index.js';
import { Recorder, destroyNodes, endpoint, eventually, join, module, node, seed, sleep } from './support.js';

const text = (value: string) => new TextEncoder().encode(value);

afterEach(destroyNodes);

test('two shells complete the handshake and each hears peerConnected first', async () => {
  const heardByA = new Recorder();
  const heardByB = new Recorder();
  const a = node({ delegate: heardByA });
  const b = node({ delegate: heardByB });
  await a.start();
  await b.start();
  const [left, right] = await join(a, b);

  assert.ok(await eventually(() => b.connectedPeers.length === 1));
  assert.deepEqual(a.connectedPeers, [b.localID]);
  assert.deepEqual(b.connectedPeers, [a.localID]);
  assert.equal(a.peerConnectionCount, 1);
  // A supplied stream's address is not one Ivy can dial.
  assert.deepEqual(a.knownPeerEndpoints, []);

  assert.deepEqual(await a.sendMessage(b.localID, 'hello', text('from a')), {
    kind: 'enqueued',
    endpoint: b.localID,
    route: { kind: 'direct' },
  });
  assert.equal((await b.sendMessage(a.localID, 'hello', text('from b'))).kind, 'enqueued');
  assert.ok(await eventually(() => heardByA.messages.length === 1 && heardByB.messages.length === 1));
  assert.deepEqual(heardByA.log, ['connected', 'message hello']);
  assert.deepEqual(heardByB.log, ['connected', 'message hello']);
  assert.deepEqual(heardByB.messages[0]!.payload, text('from a'));
  assert.equal(hex(heardByB.sessions[0]!.key), a.localID);
  assert.equal(hex(heardByA.sessions[0]!.key), b.localID);

  // The session a callback was given is one a reply can be sent on.
  assert.equal((await b.sendMessage(heardByB.sessions[0]!, 'reply', text('on the session'))).kind, 'enqueued');
  assert.ok(await eventually(() => heardByA.messages.length === 2));

  a.disconnect(b.localID);
  assert.ok(await eventually(() => heardByB.log.includes('disconnected')));
  assert.ok(await eventually(() => left.queuedBytes === 0 && right.queuedBytes === 0));
  assert.deepEqual(b.connectedPeers, []);
});

test('messages arrive in order behind a slow delegate, and the transport is not read meanwhile', async () => {
  const heard = new Recorder();
  let open!: () => void;
  heard.gate = new Promise((resolve) => (open = resolve));
  const a = node();
  const b = node({ delegate: heard });
  await a.start();
  await b.start();
  const [left, right] = await join(a, b);

  for (let index = 0; index < 40; index++) {
    // Past the write high-water mark a send is refused until the stream
    // reports room, as on any transport.
    while ((await a.sendMessage(b.localID, `t${index}`, new Uint8Array(2000).fill(1))).kind === 'backpressured') {
      await a.waitUntilWritable(b.localID);
    }
  }
  assert.ok(await eventually(() => heard.entered === 1));
  await sleep(50);
  // The delegate holds one record: nothing more is asked of the stream.
  const requestsWhileHeld = right.requests;
  await sleep(100);
  assert.equal(right.requests, requestsWhileHeld);
  assert.ok(left.queuedBytes > 0, 'what was sent behind the held record stays in the stream');
  assert.equal(heard.entered, 1);
  assert.equal(heard.messages.length, 0);

  open();
  assert.ok(await eventually(() => heard.messages.length === 40));
  assert.deepEqual(
    heard.messages.map((message) => message.topic),
    Array.from({ length: 40 }, (_, index) => `t${index}`),
  );
  assert.ok(right.requests > requestsWhileHeld);
});

test('a 20 MiB Volume is fetched through a transport that fills at 256 KiB', async () => {
  const megabyte = 1024 * 1024;
  const entries: ContentEntry[] = [{ cid: 'vol', data: new Uint8Array(512).fill(1) }];
  for (let index = 0; index < 20; index++) {
    const data = new Uint8Array(megabyte);
    for (let offset = 0; offset < megabyte; offset++) data[offset] = (offset * 31 + index) & 0xff;
    entries.push({ cid: `vol-${String(index).padStart(2, '0')}`, data });
  }
  let reads = 0;
  const heard = new Recorder();
  const a = node({ delegate: heard });
  const b = node({
    contentSource: {
      async volume(rootCID) {
        reads += 1;
        return rootCID === 'vol' ? entries : [];
      },
    },
  });
  await a.start();
  await b.start();
  const capacity = 256 * 1024;
  const [, right] = await join(a, b, capacity);

  // How full the serving side's stream got, and how often it was full.
  let peak = 0;
  let timesFull = 0;
  const send = right.send.bind(right);
  right.send = (bytes) => {
    send(bytes);
    peak = Math.max(peak, right.queuedBytes);
    if (!right.isWritable) timesFull += 1;
  };

  const volume = await a.fetchVolume('vol');
  assert.equal(volume.failure, null);
  assert.equal(volume.servedBy, b.localID);
  assert.equal(volume.entries.size, entries.length);
  for (const entry of entries) {
    assert.ok(Buffer.from(volume.entries.get(entry.cid)!).equals(entry.data), entry.cid);
  }
  assert.equal(reads, 1);
  // The chunk cursor waited for the stream: it was full again and again, and
  // never held more than a frame past where it reports full.
  assert.ok(timesFull >= 3, `full ${timesFull} times`);
  assert.ok(peak < capacity + 5 * megabyte, `peak ${peak}`);

  // A root the source does not hold is an empty answer, not a failure.
  // Asked of the session itself: a root its source does not hold is an
  // empty answer, and a Volume over the caller's limit is refused unread.
  const session = heard.sessions[0]!;
  assert.equal((await a.fetchVolume('absent', { from: session })).entries.size, 0);
  const bounded = await a.fetchVolume('vol', { from: session, maximumArchiveBytes: megabyte });
  assert.equal(bounded.entries.size, 0);
  assert.equal(bounded.failure, 'callerBoundaryExceeded');
});

test('a request aborted by its signal completes', async () => {
  // b's source never answers, so a's fetch stays in flight until aborted.
  let asked = 0;
  let abortedInSource = false;
  const a = node();
  const b = node({
    contentSource: {
      volume: (_rootCID, _maxDataBytes, signal) =>
        new Promise((resolve) => {
          asked += 1;
          signal.addEventListener('abort', () => {
            abortedInSource = true;
            resolve([]);
          });
        }),
    },
  });
  await a.start();
  await b.start();
  await join(a, b);

  const controller = new AbortController();
  const fetch = a.fetchVolume('vol', { signal: controller.signal });
  assert.ok(await eventually(() => asked === 1));
  controller.abort();
  const volume = await fetch;
  assert.equal(volume.entries.size, 0);

  // Already aborted: the request is made and cancelled at once.
  const already = await a.fetchVolume('vol', { signal: AbortSignal.abort() });
  assert.equal(already.entries.size, 0);

  // A connect over a stream nobody answers on.
  const [silent] = memoryPair();
  const connecting = new AbortController();
  const stranger = node();
  const connect = a.connect(endpoint(stranger, '8.8.3.1'), silent, { signal: connecting.signal });
  await sleep(10);
  connecting.abort();
  await assert.rejects(connect, (error) => error instanceof IvyError && error.code === 'cancelled');

  await stranger.destroy();
  await a.destroy();
  // Stopping the serving side tells its source the answer is not wanted.
  await b.destroy();
  assert.ok(abortedInSource);
});

test('stop answers every pending request', async () => {
  const a = node();
  const b = node({ contentSource: { volume: () => new Promise(() => {}) } });
  await a.start();
  await b.start();
  await join(a, b);

  const [silent] = memoryPair();
  const stranger = node();
  const settled: string[] = [];
  const pending = [
    a.fetchVolume('vol').then((volume) => settled.push(`volume ${volume.entries.size}`)),
    a.fetchVolumeBundle('vol', []).then((bundle) => settled.push(`bundle ${bundle.volumes.length}`)),
    a.findNode(a.localID).then((found) => settled.push(`findNode ${found.length}`)),
    a.discoverProviders('vol').then((found) => settled.push(`providers ${found.length}`)),
    a
      .connect(endpoint(stranger, '8.8.3.1'), silent)
      .catch((error: IvyError) => settled.push(`connect ${error.code}`)),
  ];
  await sleep(20);
  await a.stop();
  await Promise.all(pending);
  assert.deepEqual(settled.sort(), [
    'bundle 0',
    'connect cancelled',
    'findNode 0',
    'providers 0',
    'volume 0',
  ]);
  assert.deepEqual(a.connectedPeers, []);

  // Stopped, a request is refused at once; started again, the node works.
  await assert.rejects(
    a.connect(endpoint(b), memoryPair()[0]),
    (error) => error instanceof IvyError && error.code === 'notRunning',
  );
  await a.start();
  assert.ok(await eventually(() => b.connectedPeers.length === 0));
  await join(a, b);
  assert.deepEqual(a.connectedPeers, [b.localID]);
});

test('a second core in the same module is independent of the first', async () => {
  const heard = new Recorder();
  const a = node();
  const b = node({ delegate: heard });
  const c = node();
  await a.start();
  await b.start();
  await join(a, b);

  // c shares the module with a and b and knows nothing of their session.
  assert.notEqual(c.localID, a.localID);
  assert.deepEqual(c.connectedPeers, []);
  assert.equal((await c.sendMessage(b.localID, 't', text('x'))).kind, 'notConnected');
  await c.start();
  await c.stop();
  await c.destroy();

  // Nor did stopping and freeing it disturb them.
  assert.deepEqual(a.connectedPeers, [b.localID]);
  assert.equal((await a.sendMessage(b.localID, 't', text('still here'))).kind, 'enqueued');
  assert.ok(await eventually(() => heard.messages.length === 1));

  // A key is the node's identity: the same seed is the same node.
  const key = seed();
  const first = module.createCore({ signingKey: key });
  const second = module.createCore({ signingKey: key });
  assert.deepEqual(first.publicKey, second.publicKey);
  assert.equal(first.publicKey.length, 32);
  first.destroy();
  assert.deepEqual(second.connectedPeers, []);
  assert.throws(() => first.connectedPeers);
  second.destroy();
});

test('the core dials through the shell and is told how each dial ended', async () => {
  const b = node();
  const dialled: string[] = [];
  const a = node({
    dial: async (target) => {
      dialled.push(target.host);
      if (target.host !== '8.8.2.1') throw new Error('unreachable');
      const [left, right] = memoryPair();
      b.accept(right);
      return left;
    },
  });
  await a.start();
  await b.start();
  await a.connect(endpoint(b));
  assert.deepEqual(a.connectedPeers, [b.localID]);
  await assert.rejects(a.connect(endpoint(node(), '8.8.9.1')));
  assert.deepEqual(dialled, ['8.8.2.1', '8.8.9.1']);

  // With no way to dial, a dial fails and the request is answered.
  const alone = node();
  await alone.start();
  await assert.rejects(alone.connect(endpoint(b)));
});

test('a configuration reaches the core, and one it refuses throws', async () => {
  const b = node();
  const other = node();
  const pinned = node({}, { mode: { kind: 'pinned', peer: b.localID } });
  await pinned.start();
  await assert.rejects(
    pinned.connect(endpoint(other), memoryPair()[0]),
    (error) => error instanceof IvyError && error.code === 'peerOutsideMode',
  );
  await pinned.destroy();

  // A short request timeout is the one that fires.
  const stalled = node({ contentSource: { volume: () => new Promise(() => {}) } });
  const hasty = node({}, { requestTimeout: 100 });
  await stalled.start();
  await hasty.start();
  await join(hasty, stalled);
  const before = performance.now();
  assert.equal((await hasty.fetchVolume('vol')).entries.size, 0);
  assert.ok(performance.now() - before < 5_000);
  await hasty.destroy();
  await stalled.destroy();

  assert.throws(() => node({}, { mode: { kind: 'privateNetwork' }, relayEnabled: true }));
  assert.throws(() => node({}, { maxConnections: 0 }));
  assert.throws(() => node({}, { signingKey: new Uint8Array(31) }));
});

test('a stream that is refused or already closed is closed, once', async () => {
  const a = node();
  const closes = (transport: Transport) => {
    let count = 0;
    const attach = transport.attach.bind(transport);
    transport.attach = (sink) =>
      attach({
        received: (bytes) => sink.received(bytes),
        drained: () => sink.drained(),
        closed: () => {
          count += 1;
          sink.closed();
        },
      });
    return () => count;
  };

  // Not started: the core refuses the connection.
  const [early, earlyPeer] = memoryPair();
  const earlyCloses = closes(early);
  a.accept(early);
  let peerClosed = false;
  earlyPeer.attach({ received() {}, drained() {}, closed: () => (peerClosed = true) });
  assert.ok(await eventually(() => earlyCloses() === 1 && peerClosed));

  await a.start();
  // Closed before it was handed over.
  const [dead] = memoryPair();
  dead.close();
  const deadCloses = closes(dead);
  a.accept(dead);
  await sleep(20);
  assert.equal(deadCloses(), 1);
  assert.deepEqual(a.connectedPeers, []);
});
