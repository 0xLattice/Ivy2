import assert from 'node:assert/strict';
import test, { afterEach } from 'node:test';

import {
  type AuthenticatedPeer,
  type ContentEntry,
  type Ivy,
  type MemoryTransport,
  type Transport,
  DataChannelTransport,
  RtcConnector,
  hex,
  memoryPair,
  rtcTopic,
} from '../src/index.js';
import { FakeNetwork } from './fakertc.js';
import { setImmediate } from 'node:timers/promises';

import { Recorder, destroyNodes, endpoint, eventually, node, sleep } from './support.js';

const megabyte = 1024 * 1024;
const text = (value: string) => new TextEncoder().encode(value);

const connectors: RtcConnector[] = [];

afterEach(async () => {
  for (const connector of connectors.splice(0)) connector.close();
  await destroyNodes();
});

const entries: ContentEntry[] = [{ cid: 'vol', data: new Uint8Array(512).fill(1) }];
for (let index = 0; index < 4; index++) {
  entries.push({ cid: `vol-${index}`, data: new Uint8Array(megabyte).fill(index + 1) });
}

interface End {
  ivy: Ivy;
  heard: Recorder;
  rtc: RtcConnector;
  /// The session with the other endpoint that the application heard of last.
  session(): AuthenticatedPeer;
  /// The route of each session with the other endpoint it heard of, in order.
  routes(): string[];
}

interface Triangle {
  network: FakeNetwork;
  carrier: Ivy;
  a: End;
  b: End;
  /// Bytes written so far to the four ends of the carrier's two streams.
  carried(): number;
  /// The host Ivy was told the peer of each data channel was observed at.
  observed: (string | null)[];
}

/// A carrier with relaying enabled, and two endpoints joined to it by memory
/// pairs and to each other by a session through it, as two browsers on one
/// node are. `a` configures the carrier; `b` is simply connected to it.
///
/// What is sent to or from the carrier waits `lag` turns of the event loop,
/// where a fake data channel takes one: two hops through a carrier are
/// slower than a path of the peers' own, unless `lag` is zero.
async function triangle(
  {
    lag = 10,
    host,
    ...options
  }: { autoUpgrade?: boolean; deadline?: number; lag?: number; host?: (index: number) => string } = {},
): Promise<Triangle> {
  const network = new FakeNetwork();
  if (host !== undefined) network.host = host;
  const observed: (string | null)[] = [];
  const carrier = node({}, { relayEnabled: true });
  let carriedBytes = 0;
  const counted = (pair: [MemoryTransport, MemoryTransport]) => {
    for (const stream of pair) {
      const send = stream.send.bind(stream);
      let sent = Promise.resolve();
      stream.send = (bytes) => {
        carriedBytes += bytes.length;
        if (lag === 0) return send(bytes);
        sent = sent.then(async () => {
          for (let turn = 0; turn < lag; turn++) await setImmediate();
          send(bytes);
        });
      };
    }
    return pair;
  };

  const end = (ivy: Ivy, other: () => Ivy): End => {
    const heard = new Recorder();
    const rtc = new RtcConnector(ivy, { PeerConnection: network.PeerConnection, ...options });
    connectors.push(rtc);
    ivy.delegate = rtc.delegate(heard);
    const accept = ivy.accept.bind(ivy);
    ivy.accept = (transport: Transport) => {
      if (transport instanceof DataChannelTransport) observed.push(transport.observedHost);
      accept(transport);
    };
    const connect = ivy.connect.bind(ivy);
    ivy.connect = (to, over, options) => {
      if (over instanceof DataChannelTransport) observed.push(over.observedHost);
      return connect(to, over, options);
    };
    const session = () => sessions().at(-1)!;
    const sessions = () => heard.sessions.filter((session) => hex(session.key) === other().localID);
    const routes = () => sessions().map((session) => session.route.kind);
    return { ivy, heard, rtc, session, routes };
  };
  const a: End = end(
    node(
      {
        dial: async () => {
          const [near, far] = counted(memoryPair({ hosts: ['8.1.0.1', '8.9.0.1'] }));
          carrier.accept(far);
          return near;
        },
      },
      { carriers: [endpoint(carrier, '8.9.0.1')] },
    ),
    () => b.ivy,
  );
  const b: End = end(node({ contentSource: { volume: async (rootCID) => (rootCID === 'vol' ? entries : []) } }), () => a.ivy);

  await carrier.start();
  await a.ivy.start();
  await b.ivy.start();
  const [near, far] = counted(memoryPair({ hosts: ['8.2.0.1', '8.9.0.1'] }));
  carrier.accept(far);
  await b.ivy.connect(endpoint(carrier, '8.9.0.1'), near);
  assert.ok(await eventually(() => carrier.connectedPeers.length === 2));

  await a.ivy.connectViaRelay(endpoint(b.ivy));
  assert.ok(await eventually(() => a.session() !== undefined && b.session() !== undefined));
  assert.equal(a.session().route.kind, 'relayed');
  assert.equal(b.session().route.kind, 'relayed');
  return { network, carrier, a, b, carried: () => carriedBytes, observed };
}

const isDirect = (end: End) => end.session().route.kind === 'direct';

/// Nothing is on its way through the carrier.
async function quiet(triangle: Triangle) {
  let last = -1;
  assert.ok(
    await eventually(() => {
      const settled = triangle.carried() === last;
      last = triangle.carried();
      return settled;
    }),
  );
  await sleep(50);
  return triangle.carried();
}

/// The relayed session still carries a message each way.
async function relayedStillWorks({ a, b }: Triangle, topic: string) {
  const sent = await a.ivy.sendMessage(b.ivy.localID, topic, text('through the carrier'));
  assert.equal(sent.kind === 'enqueued' && sent.route.kind, 'relayed');
  const back = await b.ivy.sendMessage(a.ivy.localID, topic, text('and back'));
  assert.equal(back.kind === 'enqueued' && back.route.kind, 'relayed');
  assert.ok(
    await eventually(
      () => a.heard.log.includes(`message ${topic}`) && b.heard.log.includes(`message ${topic}`),
    ),
  );
}

test('two peers that met through a carrier move to a data channel of their own', async () => {
  const t = await triangle({ autoUpgrade: false });
  const { network, carrier, a, b } = t;

  assert.equal(await a.rtc.upgrade(a.session()), true);
  assert.ok(await eventually(() => isDirect(a) && isDirect(b)));
  assert.deepEqual(a.session().sessionID, b.session().sessionID);
  // One session took the other's place: no disconnect, and the signalling
  // stayed with the connectors.
  for (const end of [a, b]) {
    assert.deepEqual(end.routes(), ['relayed', 'direct']);
    assert.deepEqual(end.heard.log, ['connected', 'connected', 'connected']);
  }
  // A configured carrier is not counted among a node's peers.
  assert.deepEqual(a.ivy.connectedPeers, [b.ivy.localID]);
  assert.deepEqual(b.ivy.connectedPeers.sort(), [a.ivy.localID, carrier.localID].sort());
  assert.equal(carrier.connectedPeers.length, 2);
  assert.equal(network.connections.length, 2);
  assert.equal(network.open.length, 2);
  // Each end told Ivy the address the other's packets came from.
  assert.deepEqual(t.observed.sort(), ['9.1.0.1', '9.2.0.1']);
  // Asked again, there is nothing to do.
  assert.equal(await a.rtc.upgrade(a.session()), true);
  assert.equal(await b.rtc.upgrade(b.session()), true);
  assert.equal(network.connections.length, 2);

  const before = await quiet(t);
  const sent = await a.ivy.sendMessage(b.ivy.localID, 'direct', text('over the channel'));
  assert.deepEqual(sent, { kind: 'enqueued', endpoint: b.ivy.localID, route: { kind: 'direct' } });
  assert.equal((await b.ivy.sendMessage(a.session(), 'direct', text('and back'))).kind, 'notConnected');
  assert.equal((await b.ivy.sendMessage(b.session(), 'direct', text('and back'))).kind, 'enqueued');
  const volume = await a.ivy.fetchVolume('vol', { from: a.session() });
  assert.equal(volume.servedBy, b.ivy.localID);
  assert.equal(volume.entries.size, entries.length);
  for (const entry of entries) {
    assert.ok(Buffer.from(volume.entries.get(entry.cid)!).equals(entry.data), entry.cid);
  }
  assert.ok(await eventually(() => a.heard.messages.length === 1 && b.heard.messages.length === 1));
  // 4 MiB and two messages later, the carrier's streams have carried nothing.
  assert.equal(await quiet(t), before);
  assert.deepEqual(a.heard.log, ['connected', 'connected', 'connected', 'message direct']);

  // The peer connection goes with the session.
  a.ivy.disconnect(b.ivy.localID);
  assert.ok(await eventually(() => b.heard.log.includes('disconnected')));
  assert.ok(await eventually(() => network.open.length === 0));
});

test('a relayed session is upgraded as it appears, from whichever end', async () => {
  // A browser shows a name of its own making, not an address.
  const names = await triangle({ host: (index) => `fake-${index}.local` });
  assert.ok(await eventually(() => isDirect(names.a) && isDirect(names.b)));
  assert.equal(names.network.connections.length, 2);
  for (const end of [names.a, names.b]) {
    assert.deepEqual(end.routes(), ['relayed', 'direct']);
    assert.ok(!end.heard.log.includes('disconnected'));
  }
  // The host Ivy was given stands for the peer, and is not the name.
  assert.deepEqual(
    names.observed.sort(),
    [`${names.a.ivy.localID}.webrtc.invalid`, `${names.b.ivy.localID}.webrtc.invalid`].sort(),
  );
});

test('the upgrade completes when the carrier is the faster path', async () => {
  // The end that finishes the handshake first closes the relayed session,
  // and here the other end hears of that before the handshake's last
  // record. The core holds that disconnect: neither application hears one.
  const { network, a, b } = await triangle({ autoUpgrade: false, lag: 0 });
  assert.equal(await b.rtc.upgrade(b.session()), true);
  assert.ok(await eventually(() => isDirect(a) && isDirect(b)));
  for (const end of [a, b]) assert.ok(!end.heard.log.includes('disconnected'));
  assert.deepEqual(a.session().sessionID, b.session().sessionID);
  assert.equal(network.open.length, 2);
  const sent = await b.ivy.sendMessage(a.ivy.localID, 'direct', text('over the channel'));
  assert.equal(sent.kind === 'enqueued' && sent.route.kind, 'direct');
  assert.ok(await eventually(() => a.heard.log.includes('message direct')));
});

test('both ends starting at once make one connection', async () => {
  const { network, a, b } = await triangle({ autoUpgrade: false });
  assert.deepEqual(await Promise.all([a.rtc.upgrade(a.session()), b.rtc.upgrade(b.session())]), [true, true]);
  assert.ok(await eventually(() => isDirect(a) && isDirect(b)));
  await sleep(50);
  assert.equal(network.connections.length, 2);
  assert.equal(network.open.length, 2);
  for (const end of [a, b]) {
    assert.deepEqual(end.routes(), ['relayed', 'direct']);
    assert.ok(!end.heard.log.includes('disconnected'));
  }
  assert.deepEqual(a.session().sessionID, b.session().sessionID);
});

test('an attempt that cannot connect times out and leaves the relayed session', async () => {
  const t = await triangle({ autoUpgrade: false, deadline: 300 });
  const { network, a, b } = t;
  network.blocked = true;
  for (const [first, second] of [
    [a, b],
    [b, a],
  ] as const) {
    const started = performance.now();
    // The other end joins the attempt; its own deadline is its own.
    const results = [first.rtc.upgrade(first.session()), second.rtc.upgrade(second.session())];
    assert.equal(await results[0], false);
    assert.ok(performance.now() - started >= 250);
    assert.ok(performance.now() - started < 5_000);
    assert.equal(await results[1], false);
    assert.ok(await eventually(() => network.open.length === 0));
  }
  assert.equal(network.connections.length, 4);
  for (const end of [a, b]) {
    assert.deepEqual(end.routes(), ['relayed']);
    assert.ok(!end.heard.log.includes('disconnected'));
  }
  await relayedStillWorks(t, 'still-relayed');

  // The path clears, and the next attempt on the same session connects.
  network.blocked = false;
  assert.equal(await b.rtc.upgrade(b.session()), true);
  assert.ok(await eventually(() => isDirect(a) && isDirect(b)));
  assert.equal(network.open.length, 2);
  // Each session allows three attempts, so a peer cannot ask for them without end.
  assert.equal(network.connections.length, 6);
});

test('signalling from anywhere but the relayed session, or malformed, costs no session', async () => {
  const t = await triangle({ autoUpgrade: false, deadline: 60_000 });
  const { network, carrier, a, b } = t;
  const [small, large] = a.ivy.localID < b.ivy.localID ? [a, b] : [b, a];
  const signal = (kind: number, attempt: number, body: string | Uint8Array = '') => {
    const bytes = typeof body === 'string' ? text(body) : body;
    const payload = new Uint8Array(5 + bytes.length);
    payload[0] = kind;
    new DataView(payload.buffer).setUint32(1, attempt);
    payload.set(bytes, 5);
    return payload;
  };
  const send = async (from: Ivy, to: Ivy, payload: Uint8Array) =>
    assert.equal((await from.sendMessage(to.localID, rtcTopic, payload)).kind, 'enqueued');

  // The carrier is a direct peer of both, and the configured carrier of one.
  for (const to of [a, b]) {
    await send(carrier, to.ivy, signal(1, 7, 'fake 0'));
    await send(carrier, to.ivy, signal(0, 0));
    await send(carrier, to.ivy, new Uint8Array(0));
  }
  await relayedStillWorks(t, 'after-the-carrier');
  assert.equal(network.connections.length, 0);

  // With no attempt running, nothing malformed starts one.
  const malformed = [
    new Uint8Array(0),
    new Uint8Array([1, 0, 0]),
    signal(9, 1, 'no such kind'),
    signal(0, 1),
    signal(0, 0, 'a request says nothing'),
    signal(1, 0, 'fake 0'),
    signal(1, 1),
    signal(2, 1, 'an answer to nothing'),
    signal(3, 1, 'candidate:1 1 udp 1 9.1.0.1 9 typ host'),
    signal(4, 1),
    signal(1, 1, new Uint8Array([0xff, 0xfe])),
    signal(1, 1, new Uint8Array(9000)),
  ];
  for (const payload of malformed) {
    await send(small.ivy, large.ivy, payload);
    await send(large.ivy, small.ivy, payload);
  }
  // An offer from the end that does not offer is dropped, well formed or not.
  await send(large.ivy, small.ivy, signal(1, 1, 'fake 0'));
  await relayedStillWorks(t, 'after-malformed');
  assert.equal(network.connections.length, 0);

  // A description the peer connection refuses ends that attempt, and so
  // does anything malformed sent to an attempt that is running.
  await send(small.ivy, large.ivy, signal(1, 5, 'not a description'));
  assert.ok(await eventually(() => network.connections.length === 1 && network.open.length === 0));
  network.blocked = true;
  const attempt = small.rtc.upgrade(small.session());
  assert.ok(await eventually(() => network.open.length === 2));
  await send(large.ivy, small.ivy, signal(9, 0));
  assert.equal(await attempt, false);
  assert.equal(network.connections.length, 3);
  assert.ok(await eventually(() => network.open.length === 0));
  // More signalling than an attempt can need ends it too.
  const flooded = small.rtc.upgrade(small.session());
  assert.ok(await eventually(() => network.open.length === 2));
  for (let count = 0; count < 70; count++) {
    await send(large.ivy, small.ivy, signal(3, 2, 'candidate:1 1 udp 1 9.5.0.1 9 typ host'));
  }
  assert.equal(await flooded, false);
  assert.ok(await eventually(() => network.open.length === 0));

  await relayedStillWorks(t, 'after-all');
  for (const end of [a, b]) {
    assert.ok(!end.heard.log.includes('disconnected'));
    assert.ok(!end.heard.log.includes(`message ${rtcTopic}`));
    assert.equal(end.session().route.kind, 'relayed');
  }
  assert.equal(carrier.connectedPeers.length, 2);
});
