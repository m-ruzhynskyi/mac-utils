const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
// Модули склеиваются в один скрипт (без import между ними), как в Worker после сборки.
const source = ['limits.js', 'auth.js', 'index.js']
  .map((name) => fs.readFileSync(`${__dirname}/../src/${name}`, 'utf8'))
  .join('\n')
  .replace(/^import .*;$/gm, '')
  .replace('export default', 'const worker =')
  .replace('export class Room', 'class Room')
  .replace(/^export (async function|function|const)/gm, '$1');
function fixture(env) {
  let now = 1_000_000, alarm = null;
  const store = new Map();
  const sockets = [];
  const state = {
    storage: {
      getAlarm: async () => alarm, setAlarm: async (value) => { alarm = value; },
      get: async (key) => store.get(key), put: async (key, value) => { store.set(key, value); },
      delete: async (key) => { store.delete(key); },
    },
    getWebSockets: (tag) => sockets.filter((s) => s.tag === tag),
    getTags: (s) => [s.tag],
    acceptWebSocket: (s, tags) => { s.tag = tags[0]; sockets.push(s); },
  };
  // Response из Node не принимает статус 101, поэтому в песочнице — простой двойник.
  class FakeResponse {
    constructor(body, init = {}) { this.body = body; this.status = init.status ?? 200; this.webSocket = init.webSocket; this.headers = new Map(Object.entries(init.headers || {})); }
    async text() { return String(this.body); }
    async json() { return JSON.parse(String(this.body)); }
    static json(data, init = {}) { return new FakeResponse(JSON.stringify(data), init); }
  }
  class FakePair { constructor() { const mk = () => ({ readyState: 1, info: null, messages: [], closes: [],
      deserializeAttachment() { return this.info; }, serializeAttachment(v) { this.info = v; },
      send(v) { this.messages.push(JSON.parse(v)); }, close(...a) { this.closes.push(a); this.readyState = 2; } });
    this[0] = mk(); this[1] = mk(); } }
  const context = vm.createContext({ Date: { now: () => now }, Response: FakeResponse, URL, WebSocketPair: FakePair, crypto: globalThis.crypto,
    TextEncoder, Headers, Request, page: 'PAGE', landing: 'LANDING' });
  vm.runInContext(`${source}\nthis.Room = Room; this.worker = worker;`, context);
  const room = new context.Room(state, env);
  function socket(tag, info) {
    const s = { tag, readyState: 1, info, messages: [], closes: [],
      deserializeAttachment() { return this.info; },
      serializeAttachment(value) { this.info = value; },
      send(value) { this.messages.push(JSON.parse(value)); },
      close(...args) { this.closes.push(args); this.readyState = 2; },
    };
    sockets.push(s); return s;
  }
  return { room, worker: context.worker, store, context, socket, all: () => sockets, advance(ms) { now += ms; }, get alarm() { return alarm; } };
}
test('stale host releases ID and tells viewers it is reconnecting; late close cannot end new session', async () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const viewer = f.socket('viewer', { approved: true });
  f.advance(120_000);
  const status = await f.room.fetch(new Request('https://room/live'));
  assert.equal(await status.text(), '0');
  assert.equal(host.closes.length, 1);
  assert.equal(viewer.messages[0].type, 'reconnecting');
  const next = f.socket('viewer', { approved: true });
  f.socket('host', { lastSeen: 1_120_000 });
  f.room.webSocketClose(host);
  f.room.webSocketMessage(host, new ArrayBuffer(2));
  assert.equal(next.messages.length, 0);
  assert.equal(f.room.activeHosts().length, 1);
});
test('heartbeat keeps static screen alive and is not forwarded to viewers', async () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const viewer = f.socket('viewer', { approved: true });
  f.advance(110_000);
  f.room.webSocketMessage(host, '{"type":"heartbeat"}');
  f.advance(110_000);
  assert.equal(f.room.activeHosts().length, 1);
  assert.equal(viewer.messages.length, 0);
  const busy = await f.room.fetch(new Request('https://room/123456?role=host'));
  assert.equal(busy.status, 409);
  assert.ok(f.alarm);
});
test('legacy hosts get grace period; alarms prune them without new requests', async () => {
  const f = fixture(), host = f.socket('host', null);
  assert.equal(f.room.activeHosts().length, 1);
  await f.room.alarm();
  assert.equal(host.messages[0].type, 'viewers');
  assert.ok(f.alarm);
  f.advance(120_000);
  await f.room.alarm();
  assert.equal(f.room.activeHosts().length, 0);
});
test('closing socket does not block ID and normal close is idempotent', () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const viewer = f.socket('viewer', { approved: true });
  host.readyState = 2;
  assert.equal(f.room.activeHosts().length, 0);
  f.room.webSocketError(host);
  assert.equal(viewer.messages.length, 1);
});
test('closed viewer never reappears in count on periodic updates', async () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const viewer = f.socket('viewer', { id: '1234567890', approved: true });
  f.room.notifyHost();
  assert.equal(host.messages.at(-1).count, 1);
  f.room.webSocketClose(viewer);
  assert.equal(host.messages.at(-1).count, 0);
  // Simulate runtime retaining the socket, even with an OPEN readyState.
  await f.room.alarm();
  assert.equal(host.messages.at(-1).count, 0);
  assert.equal(f.room.approvedViewers().length, 0);
});
test('same viewer ID counts once; different IDs and anonymous viewers count separately', () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  f.socket('viewer', { id: '1234567890', name: 'Alice', approved: true });
  const duplicate = f.socket('viewer', { id: '1234567890', name: 'Alice', approved: true });
  f.socket('viewer', { id: '9876543210', name: 'Bob', approved: true });
  f.socket('viewer', { id: '', approved: true });
  f.socket('viewer', { id: '', approved: true });
  f.room.notifyHost();
  assert.equal(host.messages.at(-1).count, 4);
  assert.equal(host.messages.at(-1).list.length, 4);
  f.room.webSocketClose(duplicate);
  assert.equal(host.messages.at(-1).count, 4);
});
test('closing and errored viewers are excluded from counts and approval', () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const closing = f.socket('viewer', { id: '1234567890', approved: true });
  closing.readyState = 2;
  const errored = f.socket('viewer', { id: '9876543210', approved: true });
  f.room.webSocketError(errored);
  f.room.notifyHost();
  assert.equal(host.messages.at(-1).count, 0);
  const pending = f.socket('viewer', { id: '1111111111', approved: false });
  f.room.webSocketClose(pending);
  f.room.hostCommand('{"type":"accept","viewer":"1111111111"}', host);
  assert.equal(pending.info.approved, false);
});
test('two silent OPEN ghost viewers expire while one real viewer remains alive', async () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const ghosts = ['1111111111', '2222222222'].map(id => f.socket('viewer', { id, approved: true, lastSeen: 1_000_000 }));
  const real = f.socket('viewer', { id: '3333333333', approved: true, lastSeen: 1_000_000 });
  f.room.notifyHost();
  assert.equal(host.messages.at(-1).count, 3);
  for (let i = 0; i < 4; i++) {
    f.advance(30_000);
    f.room.webSocketMessage(host, '{"type":"heartbeat"}');
    f.room.webSocketMessage(real, '{"type":"heartbeat"}');
    await f.room.alarm();
  }
  assert.equal(host.messages.at(-1).count, 1);
  assert.ok(ghosts.every(s => s.info.ended && s.closes.length === 1));
  assert.equal(real.info.ended, undefined);
  assert.equal(real.messages.at(-1).type, 'heartbeat');
  f.room.webSocketClose(real);
  await f.room.alarm();
  assert.equal(host.messages.at(-1).count, 0);
});
test('waiting viewers answer heartbeat without approval or forwarding', async () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const pending = f.socket('viewer', { id: '1111111111', approved: false, lastSeen: 1_000_000 });
  f.advance(100_000);
  f.room.webSocketMessage(pending, '{"type":"heartbeat"}');
  assert.equal(pending.info.lastSeen, 1_100_000);
  assert.equal(pending.info.approved, false);
  assert.equal(host.messages.length, 0);
});
test('legacy viewer attachments get one persisted grace period', async () => {
  const f = fixture();
  f.socket('host', { lastSeen: 1_000_000 });
  const viewer = f.socket('viewer', { id: '1111111111', approved: true });
  f.room.expireViewers();
  f.advance(120_000);
  f.room.expireViewers();
  assert.equal(viewer.info.ended, true);
});
test('host drop (not code 1000) keeps viewers for 45 s, then ends them', async () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const viewer = f.socket('viewer', { id: '1111111111', approved: true, lastSeen: 1_000_000 });
  f.room.webSocketClose(host, 1006);
  assert.equal(viewer.messages.at(-1).type, 'reconnecting');
  assert.equal(viewer.closes.length, 0);
  f.advance(30_000);
  viewer.info.lastSeen = 1_030_000;
  await f.room.alarm();
  assert.equal(viewer.closes.length, 0);
  f.advance(16_000);
  viewer.info.lastSeen = 1_046_000;
  await f.room.alarm();
  assert.equal(viewer.messages.at(-1).type, 'ended');
  assert.equal(viewer.closes.length, 1);
});
test('host stop (code 1000) ends viewers immediately', () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const viewer = f.socket('viewer', { id: '1111111111', approved: true, lastSeen: 1_000_000 });
  f.room.webSocketClose(host, 1000);
  assert.equal(viewer.messages.at(-1).type, 'ended');
  assert.equal(viewer.closes.length, 1);
});
test('game messages reach only the opponent, with the viewer ID stamped by the relay', () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const alice = f.socket('viewer', { id: '1111111111', name: 'Alice', approved: true });
  const bob = f.socket('viewer', { id: '2222222222', name: 'Bob', approved: true });
  f.room.webSocketMessage(alice, JSON.stringify({ type: 'game', action: 'invite', from: '2222222222' }));
  assert.deepEqual(host.messages.at(-1), { type: 'game', action: 'invite', from: '1111111111', name: 'Alice' });
  assert.equal(bob.messages.length, 0);
  f.room.webSocketMessage(host, JSON.stringify({ type: 'game', action: 'accept', to: '1111111111', name: 'Mac' }));
  assert.deepEqual(alice.messages.at(-1), { type: 'game', action: 'accept', name: 'Mac', from: 'host' });
  assert.equal(bob.messages.length, 0);
});

// ---- Спуфинг и сообщения зрителей (аудит C1, H1, H3, H2) ----
const hostLive = (f) => f.socket('host', { lastSeen: 1_000_000 });
test('C1: viewer with viewer=<roomID> is not approved or sent "accepted" without an explicit host accept', async () => {
  const f = fixture(), host = hostLive(f);
  const res = await f.room.fetch(new Request('https://room/1234567890?role=viewer&viewer=1234567890&name=x'));
  assert.equal(res.status, 101);
  const spoof = f.socket('viewer', { id: '1234567890', name: 'x', approved: false, lastSeen: 1_000_000 });
  assert.equal(host.messages.at(-1).type, 'request');
  assert.equal(host.messages.at(-1).viewer, '1234567890');
  f.room.webSocketMessage(spoof, JSON.stringify({ type: 'ping', x: 0.5, y: 0.5 }));
  f.room.webSocketMessage(spoof, JSON.stringify({ type: 'accept', viewer: '1234567890' }));
  assert.equal(spoof.info.approved, false);
  assert.equal(spoof.messages.some((m) => m.type === 'accepted'), false);
  assert.equal(host.messages.filter((m) => m.type === 'ping').length, 0);
  f.room.webSocketMessage(host, new ArrayBuffer(4));
  assert.equal(spoof.messages.some((m) => !m.type), false);
});
for (const type of ['viewers', 'request', 'cancelled', 'ended', 'accepted', 'declined', 'reconnecting', 'resumed']) {
  test(`H3: approved viewer's {"type":"${type}"} reaches neither the host nor other viewers`, () => {
    const f = fixture(), host = hostLive(f);
    const evil = f.socket('viewer', { id: '1111111111', name: 'Evil', approved: true });
    const other = f.socket('viewer', { id: '2222222222', name: 'Bob', approved: true });
    f.room.webSocketMessage(evil, JSON.stringify({ type, viewer: '2222222222', count: 0, list: [], name: 'Apple Support' }));
    assert.equal(host.messages.length, 0);
    assert.equal(other.messages.length, 0);
  });
}
for (const type of ['ping', 'stroke']) {
  test(`H3: approved viewer's ${type} reaches the host and other approved viewers, not back to the sender`, () => {
    const f = fixture(), host = hostLive(f);
    const a = f.socket('viewer', { id: '1111111111', approved: true });
    const b = f.socket('viewer', { id: '2222222222', approved: true });
    const waiting = f.socket('viewer', { id: '3333333333', approved: false });
    const msg = JSON.stringify(type === 'ping' ? { type, x: 0.1, y: 0.2, color: 'red' } : { type, points: [[0, 0], [1, 1]], color: 'blue' });
    f.room.webSocketMessage(a, msg);
    assert.equal(host.messages.at(-1).type, type);
    assert.equal(b.messages.at(-1).type, type);
    assert.equal(a.messages.length, 0);
    assert.equal(waiting.messages.length, 0);
  });
}
test('H3: unapproved viewer cannot send ping/stroke', () => {
  const f = fixture(), host = hostLive(f);
  const w = f.socket('viewer', { id: '1111111111', approved: false });
  f.room.webSocketMessage(w, '{"type":"ping","x":0,"y":0}');
  assert.equal(host.messages.length, 0);
});
test('H1: host accept for an id with two waiting sockets approves only one of them', () => {
  const f = fixture(), host = hostLive(f);
  const real = f.socket('viewer', { id: '1111111111', name: 'Real', approved: false, lastSeen: 1_000_000 });
  const twin = f.socket('viewer', { id: '1111111111', name: 'Twin', approved: false, lastSeen: 1_000_000 });
  f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: '1111111111', name: 'Mac' }));
  const approved = [real, twin].filter((s) => s.info.approved);
  assert.equal(approved.length, 1);
});
test('host accept still approves a single waiting viewer and decline closes it', () => {
  const f = fixture(), host = hostLive(f);
  const v = f.socket('viewer', { id: '1111111111', approved: false, lastSeen: 1_000_000 });
  const d = f.socket('viewer', { id: '2222222222', approved: false, lastSeen: 1_000_000 });
  f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: '1111111111', name: 'Mac' }));
  f.room.webSocketMessage(host, JSON.stringify({ type: 'decline', viewer: '2222222222' }));
  assert.equal(v.info.approved, true);
  assert.equal(v.messages.at(-1).type, 'accepted');
  assert.equal(d.messages.at(-1).type, 'declined');
  assert.equal(d.closes.length, 1);
});
test('host drop: current behaviour — any client can take the host role during the 45 s grace period', async () => {
  const f = fixture(), host = hostLive(f);
  const viewer = f.socket('viewer', { id: '1111111111', approved: true, lastSeen: 1_000_000 });
  f.room.webSocketClose(host, 1006);
  f.advance(10_000);
  const res = await f.room.fetch(new Request('https://room/1234567890?role=host'));
  assert.equal(res.status, 101);
  assert.equal(viewer.messages.at(-1).type, 'resumed');
});
test('H2, ждёт аутентификации: чужой хост не должен занимать комнату в grace-период', { skip: 'H2, ждёт аутентификации' }, async () => {
  const f = fixture(), host = hostLive(f);
  f.socket('viewer', { id: '1111111111', approved: true, lastSeen: 1_000_000 });
  f.room.webSocketClose(host, 1006);
  const res = await f.room.fetch(new Request('https://room/1234567890?role=host'));
  assert.notEqual(res.status, 101);
});

// ---- Волна 1c: S3 (rid), S5 (частота и поля game) ----
test('S3: "cancelled" for a waiting viewer carries its rid', () => {
  const f = fixture(), host = hostLive(f);
  const waiting = f.socket('viewer', { id: '1111111111', rid: 'rid-1', approved: false, lastSeen: 1_000_000 });
  f.room.webSocketClose(waiting, 1001);
  const cancelled = host.messages.find((m) => m.type === 'cancelled');
  assert.ok(cancelled, 'host must get cancelled');
  assert.equal(cancelled.viewer, '1111111111');
  assert.equal(cancelled.rid, 'rid-1');
});
test('S3: accept with rid approves exactly the socket with that rid, even if it is not the earliest', () => {
  const f = fixture(), host = hostLive(f);
  const first = f.socket('viewer', { id: '1111111111', rid: 'r1', approved: false, lastSeen: 1_000_000 });
  const second = f.socket('viewer', { id: '1111111111', rid: 'r2', approved: false, lastSeen: 1_000_000 });
  f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: '1111111111', rid: 'r2', name: 'Mac' }));
  assert.equal(first.info.approved, false);
  assert.equal(second.info.approved, true);
  assert.equal(second.messages.at(-1).type, 'accepted');
});
for (const rid of [123, null, {}, ['r1'], true]) {
  test(`S3: accept with non-string rid ${JSON.stringify(rid)} approves nothing`, () => {
    const f = fixture(), host = hostLive(f);
    const a = f.socket('viewer', { id: '1111111111', rid: 'r1', approved: false, lastSeen: 1_000_000 });
    const b = f.socket('viewer', { id: '1111111111', rid: 'r2', approved: false, lastSeen: 1_000_000 });
    f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: '1111111111', rid, name: 'Mac' }));
    assert.equal(a.info.approved, false);
    assert.equal(b.info.approved, false);
    assert.equal(a.messages.length + b.messages.length, 0);
  });
}
test('S3: accept with an unknown rid approves nothing', () => {
  const f = fixture(), host = hostLive(f);
  const a = f.socket('viewer', { id: '1111111111', rid: 'r1', approved: false, lastSeen: 1_000_000 });
  f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: '1111111111', rid: 'nope', name: 'Mac' }));
  assert.equal(a.info.approved, false);
});
test('S3: accept without a rid field falls back to the earliest waiting socket with that id', () => {
  const f = fixture(), host = hostLive(f);
  const first = f.socket('viewer', { id: '1111111111', rid: 'r1', approved: false, lastSeen: 1_000_000 });
  const second = f.socket('viewer', { id: '1111111111', rid: 'r2', approved: false, lastSeen: 1_000_000 });
  f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: '1111111111', name: 'Mac' }));
  assert.equal(first.info.approved, true);
  assert.equal(second.info.approved, false);
});
test('S3: decline with rid closes only that socket', () => {
  const f = fixture(), host = hostLive(f);
  const a = f.socket('viewer', { id: '1111111111', rid: 'r1', approved: false, lastSeen: 1_000_000 });
  const b = f.socket('viewer', { id: '1111111111', rid: 'r2', approved: false, lastSeen: 1_000_000 });
  f.room.webSocketMessage(host, JSON.stringify({ type: 'decline', viewer: '1111111111', rid: 'r2' }));
  assert.equal(a.closes.length, 0);
  assert.equal(b.closes.length, 1);
});

test('S5: a burst of more than 40 marks from one viewer is partly dropped, and it recovers later', () => {
  const f = fixture(), host = hostLive(f);
  const v = f.socket('viewer', { id: '1111111111', approved: true, lastSeen: 1_000_000 });
  const ping = JSON.stringify({ type: 'ping', x: 0.5, y: 0.5, color: 'red' });
  for (let i = 0; i < 200; i++) f.room.webSocketMessage(v, ping);
  const got = host.messages.filter((m) => m.type === 'ping').length;
  assert.ok(got > 0, 'normal marks still pass');
  assert.ok(got < 200, `burst must be limited, host got ${got}`);
  assert.ok(got <= 60, `burst limit should be around 40, host got ${got}`);
  f.advance(5_000);
  const before = host.messages.length;
  f.room.webSocketMessage(v, ping);
  assert.equal(host.messages.length, before + 1, 'after a pause the viewer can send again');
});
test('S5: one noisy viewer does not limit another viewer', () => {
  const f = fixture(), host = hostLive(f);
  const noisy = f.socket('viewer', { id: '1111111111', approved: true, lastSeen: 1_000_000 });
  const calm = f.socket('viewer', { id: '2222222222', approved: true, lastSeen: 1_000_000 });
  const ping = JSON.stringify({ type: 'ping', x: 0.1, y: 0.1 });
  for (let i = 0; i < 200; i++) f.room.webSocketMessage(noisy, ping);
  const before = host.messages.length;
  f.room.webSocketMessage(calm, ping);
  assert.equal(host.messages.length, before + 1);
});
test('S5: game from a viewer is forwarded with only type/action/cell/round/busy plus relay-stamped from/name', () => {
  const f = fixture(), host = hostLive(f);
  const v = f.socket('viewer', { id: '1111111111', name: 'Alice', approved: true, lastSeen: 1_000_000 });
  f.room.webSocketMessage(v, JSON.stringify({ type: 'game', action: 'move', cell: 4, round: 2, busy: true,
    evil: 'x'.repeat(5000), nested: { a: 1 }, from: '9999999999', name: 'Apple Support' }));
  const game = host.messages.at(-1);
  assert.deepEqual(game, { type: 'game', action: 'move', cell: 4, round: 2, busy: true, from: '1111111111', name: 'Alice' });
});
test('S5: game with an unknown action is dropped', () => {
  const f = fixture(), host = hostLive(f);
  const v = f.socket('viewer', { id: '1111111111', name: 'Alice', approved: true, lastSeen: 1_000_000 });
  for (const action of ['hack', '', 7, null, { a: 1 }, 'MOVE']) {
    f.room.webSocketMessage(v, JSON.stringify({ type: 'game', action }));
  }
  f.room.webSocketMessage(v, JSON.stringify({ type: 'game' }));
  assert.equal(host.messages.length, 0);
});
test('S5: every valid game action passes', () => {
  const f = fixture(), host = hostLive(f);
  const v = f.socket('viewer', { id: '1111111111', name: 'Alice', approved: true, lastSeen: 1_000_000 });
  for (const action of ['invite', 'accept', 'decline', 'move', 'again', 'quit']) {
    f.room.webSocketMessage(v, JSON.stringify({ type: 'game', action }));
  }
  assert.equal(host.messages.length, 6);
});
test('S5: game move with a cell outside 0..8 or non-integer is dropped', () => {
  const f = fixture(), host = hostLive(f);
  const v = f.socket('viewer', { id: '1111111111', name: 'Alice', approved: true, lastSeen: 1_000_000 });
  for (const cell of [-1, 9, 1.5, '4', null, 1e999]) {
    f.room.webSocketMessage(v, JSON.stringify({ type: 'game', action: 'move', cell }));
  }
  assert.equal(host.messages.length, 0);
});
test('S5: host game messages keep working for the chosen viewer (regression)', () => {
  const f = fixture(), host = hostLive(f);
  const v = f.socket('viewer', { id: '1111111111', approved: true, lastSeen: 1_000_000 });
  f.room.webSocketMessage(host, JSON.stringify({ type: 'game', action: 'invite', to: '1111111111', name: 'Mac' }));
  assert.equal(v.messages.at(-1).action, 'invite');
  assert.equal(v.messages.at(-1).from, 'host');
});

// ---- Волна 1d: S2 ----
test('S2: viewer=<roomId> is reported to the host with an empty viewer id (old hosts then show a normal prompt)', async () => {
  const f = fixture(), host = hostLive(f);
  const res = await f.room.fetch(new Request('https://relay.example/room/1234567890?role=viewer&viewer=1234567890&name=x'));
  assert.equal(res.status, 101);
  const request = host.messages.find((m) => m.type === 'request');
  assert.ok(request, 'host must get a request');
  assert.equal(request.viewer, '');
  assert.equal(request.name, 'x');
  assert.equal(typeof request.rid, 'string');
});
test('S2: viewer=<roomId> with formatting characters is still recognised as the room id', async () => {
  const f = fixture(), host = hostLive(f);
  await f.room.fetch(new Request('https://relay.example/room/1234567890?role=viewer&viewer=123-456%20789-0&name=x'));
  assert.equal(host.messages.find((m) => m.type === 'request').viewer, '');
});
test('S2: a different viewer id is passed to the host unchanged', async () => {
  const f = fixture(), host = hostLive(f);
  await f.room.fetch(new Request('https://relay.example/room/1234567890?role=viewer&viewer=2222222222&name=Bob'));
  assert.equal(host.messages.find((m) => m.type === 'request').viewer, '2222222222');
});
test('S2: a viewer that claimed the room id cannot be matched by an accept for the room id', async () => {
  const f = fixture(), host = hostLive(f);
  await f.room.fetch(new Request('https://relay.example/room/1234567890?role=viewer&viewer=1234567890&name=x'));
  f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: '1234567890', name: 'Mac' }));
  const viewers = f.all().filter((s) => s.tag === 'viewer');
  assert.equal(viewers.length, 1);
  assert.equal(viewers[0].info.approved, false);
});

// ======================= Протокол mu-share-2 (аутентификация по ключу) =======================
const nodeCrypto = require('node:crypto');
const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
function keypair(n) {
  const seed = Buffer.alloc(32, n);
  const priv = nodeCrypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
  const pub = b64u(nodeCrypto.createPublicKey(priv).export({ format: 'der', type: 'spki' }).subarray(-32));
  return { pub, sign: (message) => b64u(nodeCrypto.sign(null, Buffer.from(message), priv)) };
}
const KEY_A = keypair(1), KEY_B = keypair(2), KEY_C = keypair(3);
const ROOM = '1234567890', VIEWER_ID = '9876543210';
const hostMsg = (room, nonce) => `mu-share/v2\nhost\n${room}\n${nonce}`;
const viewerMsg = (room, id, rid, nonce) => `mu-share/v2\nviewer\n${room}\n${id}\n${rid}\n${nonce}`;
const V1 = { 'x-macutils-client': 'mu-share-1' }, V2 = { 'x-macutils-client': 'mu-share-2' };
const tick = () => new Promise((resolve) => setImmediate(resolve));

// Несколько комнат («Durable Objects») в одном мире: ROOMS.get(id) ведёт к своей Room.
function world(extra = {}) {
  const rooms = new Map();
  const env = { ...extra };
  const fixtureFor = (name) => { if (!rooms.has(name)) rooms.set(name, fixture(env)); return rooms.get(name); };
  env.ROOMS = {
    idFromName: (name) => name,
    get: (name) => ({ fetch: (url, init) => fixtureFor(name).room.fetch(url instanceof Request ? url : new Request(url, init)) }),
  };
  return { env, f: fixtureFor, advance(ms) { for (const f of rooms.values()) f.advance(ms); } };
}
const roomUrl = (id, query) => `https://relay.example/room/${id}?${query}`;
const lastSocket = (f, tag) => f.all().filter((s) => s.tag === tag).at(-1);
const msgOf = (socket, type) => socket.messages.find((m) => m.type === type);

async function connectHost(f, headers = V2, id = ROOM) {
  const res = await f.room.fetch(new Request(roomUrl(id, 'role=host'), { headers }));
  return { res, socket: lastSocket(f, 'host') };
}
async function authHost(f, key = KEY_A, id = ROOM, ip) {
  const headers = ip ? { ...V2, 'x-relay-ip': ip } : V2;
  const { res, socket } = await connectHost(f, headers, id);
  assert.equal(res.status, 101);
  const nonce = msgOf(socket, 'challenge').nonce;
  await f.room.webSocketMessage(socket, JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', pub: key.pub, sig: key.sign(hostMsg(id, nonce)) }));
  return socket;
}
async function connectViewer(f, { id = VIEWER_ID, room = ROOM, headers = V2, name = 'Петя', ip } = {}) {
  const h = ip ? { ...headers, 'x-relay-ip': ip } : headers;
  const res = await f.room.fetch(new Request(roomUrl(room, `role=viewer&viewer=${id}&name=${encodeURIComponent(name)}&h264=1`), { headers: h }));
  return { res, socket: lastSocket(f, 'viewer') };
}
async function authViewer(f, key = KEY_B, opts = {}) {
  const { res, socket } = await connectViewer(f, opts);
  assert.equal(res.status, 101);
  const challenge = msgOf(socket, 'challenge');
  const room = opts.room ?? ROOM, id = opts.id ?? VIEWER_ID;
  await f.room.webSocketMessage(socket, JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', pub: key.pub, sig: key.sign(viewerMsg(room, id, challenge.rid, challenge.nonce)) }));
  return socket;
}

test('v2: хост получает challenge, до auth хостом не считается и зрители видят «нет трансляции»', async () => {
  const w = world(), f = w.f(ROOM);
  const { res, socket } = await connectHost(f);
  assert.equal(res.status, 101);
  const challenge = msgOf(socket, 'challenge');
  assert.equal(challenge.v, 2);
  assert.match(challenge.nonce, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(f.room.activeHosts().length, 0);
  const viewer = await f.room.fetch(new Request(roomUrl(ROOM, `role=viewer&viewer=${VIEWER_ID}&name=x`), { headers: V2 }));
  assert.equal(viewer.status, 404);
  assert.ok(f.alarm, 'будильник для таймаута проверки');
});

test('v2: успешная проверка хоста, claim, authed с отпечатком', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const authed = msgOf(host, 'authed');
  assert.equal(authed.claimed, true);
  assert.match(authed.fp, /^[0-9a-f]{4}(-[0-9a-f]{4}){3}$/);
  assert.equal(f.room.activeHosts().length, 1);
  assert.equal(f.store.get('owner').pub, KEY_A.pub);
  assert.equal(f.store.get('owner').fp, authed.fp);
  // повторное подключение того же ключа — не claim
  const second = await authHost(f);
  assert.equal(msgOf(second, 'authed').claimed, false);
});

test('v2: неверная подпись, чужая комната и мусор → bad-signature, ключ не записан', async () => {
  const w = world(), f = w.f(ROOM);
  for (const make of [
    (nonce) => ({ pub: KEY_A.pub, sig: KEY_B.sign(hostMsg(ROOM, nonce)) }),
    (nonce) => ({ pub: KEY_A.pub, sig: KEY_A.sign(hostMsg('1111111111', nonce)) }),
    () => ({ pub: KEY_A.pub, sig: 'x' }),
    () => ({ pub: 'abc', sig: KEY_A.sign('x') }),
  ]) {
    const { socket } = await connectHost(f);
    const nonce = msgOf(socket, 'challenge').nonce;
    await f.room.webSocketMessage(socket, JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', ...make(nonce) }));
    assert.equal(msgOf(socket, 'error').code, 'bad-signature');
    assert.equal(socket.closes.at(-1)[0], 4401);
    assert.equal(msgOf(socket, 'authed'), undefined);
  }
  assert.equal(f.store.get('owner'), undefined);
  assert.equal(f.room.activeHosts().length, 0);
});

test('v2: подпись привязана к nonce (нельзя переиспользовать)', async () => {
  const w = world(), f = w.f(ROOM);
  const first = await connectHost(f);
  const old = KEY_A.sign(hostMsg(ROOM, msgOf(first.socket, 'challenge').nonce));
  const second = await connectHost(f);
  await f.room.webSocketMessage(second.socket, JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', pub: KEY_A.pub, sig: old }));
  assert.equal(msgOf(second.socket, 'error').code, 'bad-signature');
});

test('v2: другой ключ на занятом ID → id-claimed (4403), владелец остаётся', async () => {
  const w = world(), f = w.f(ROOM);
  await authHost(f, KEY_A);
  const thief = await authHost(f, KEY_C);
  assert.equal(msgOf(thief, 'error').code, 'id-claimed');
  assert.equal(thief.closes.at(-1)[0], 4403);
  assert.equal(f.store.get('owner').pub, KEY_A.pub);
});

test('v2: тот же ключ вытесняет старое подключение (replaced, 4409) без разрыва зрителей', async () => {
  const w = world(), f = w.f(ROOM);
  const old = await authHost(f);
  const viewer = f.socket('viewer', { id: VIEWER_ID, approved: true, approvedBy: KEY_A.pub, lastSeen: 1_000_000 });
  const fresh = await authHost(f);
  assert.equal(msgOf(old, 'error').code, 'replaced');
  assert.equal(old.closes.at(-1)[0], 4409);
  assert.deepEqual(f.room.activeHosts(), [fresh]);
  f.room.webSocketClose(old, 4409);
  assert.equal(viewer.messages.some((m) => m.type === 'ended' || m.type === 'reconnecting'), false);
  assert.equal(viewer.info.ended, undefined);
});

test('v2: владелец вытесняет хоста без ключа и завершает пущенных им зрителей', async () => {
  const w = world(), f = w.f(ROOM);
  const squatter = hostLive(f);
  const viewer = f.socket('viewer', { id: VIEWER_ID, approved: true, lastSeen: 1_000_000 });
  const owner = await authHost(f);
  assert.equal(squatter.closes.at(-1)[0], 4409);
  assert.equal(viewer.messages.at(-1).type, 'ended');
  assert.deepEqual(f.room.activeHosts(), [owner]);
});

test('v2: grace сохраняется, возвращает комнату только прошедший проверку', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const viewer = f.socket('viewer', { id: VIEWER_ID, approved: true, approvedBy: KEY_A.pub, lastSeen: 1_000_000 });
  f.room.webSocketClose(host, 1006);
  assert.equal(viewer.messages.at(-1).type, 'reconnecting');
  const pending = await connectHost(f);
  assert.equal(viewer.messages.some((m) => m.type === 'resumed'), false, 'неавторизованный сокет ожидание не прерывает');
  await f.room.webSocketMessage(pending.socket, JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', pub: KEY_C.pub, sig: 'x' }));
  assert.equal(viewer.messages.some((m) => m.type === 'resumed'), false);
  const owner = await authHost(f);
  assert.equal(viewer.messages.at(-1).type, 'resumed');
  assert.equal(msgOf(owner, 'authed').claimed, false);
});

test('v2: хост без ключа к ID с владельцем → 409 id-claimed до апгрейда, пока не off', async () => {
  const w = world(), f = w.f(ROOM);
  await authHost(f);
  f.room.webSocketClose(lastSocket(f, 'host'), 1000);
  const legacy = await f.room.fetch(new Request(roomUrl(ROOM, 'role=host'), { headers: V1 }));
  assert.equal(legacy.status, 409);
  assert.equal(await legacy.text(), 'id-claimed');
  const off = world({ AUTH_MODE: 'off' });
  const g = off.f(ROOM);
  g.store.set('owner', { v: 2, pub: KEY_A.pub, fp: 'x', claimedAt: 1, lastSeenAt: 1_000_000 });
  assert.equal((await g.room.fetch(new Request(roomUrl(ROOM, 'role=host'), { headers: V1 }))).status, 101);
});

test('v2: 6-значный ID нельзя занять (id-format, 4400)', async () => {
  const w = world(), f = w.f('123456');
  const host = await authHost(f, KEY_A, '123456');
  assert.equal(msgOf(host, 'error').code, 'id-format');
  assert.equal(host.closes.at(-1)[0], 4400);
  assert.equal(f.store.get('owner'), undefined);
});

test('v2: нет auth за 10 с → auth-timeout (4408) для хоста и зрителя, обрыва комнаты нет', async () => {
  const w = world(), f = w.f(ROOM);
  hostLive(f);
  const pendingHost = (await connectHost(f)).socket;
  const { socket: pendingViewer } = await connectViewer(f);
  f.advance(9_000);
  f.room.expireViewers();
  assert.equal(pendingHost.closes.length, 0);
  f.advance(1_500);
  await f.room.alarm();
  for (const socket of [pendingHost, pendingViewer]) {
    assert.equal(msgOf(socket, 'error').code, 'auth-timeout');
    assert.equal(socket.closes.at(-1)[0], 4408);
  }
  f.room.webSocketClose(pendingHost, 4408);
  f.room.webSocketClose(pendingViewer, 4408);
  assert.equal(f.room.hostLostAt ?? null, null);
  assert.equal(f.all().filter((s) => s.tag === 'host' && s.info.auth !== 'pending').length, 1);
  const cancelled = f.all().filter((s) => s.tag === 'host')[0].messages.filter((m) => m.type === 'cancelled');
  assert.equal(cancelled.length, 0, 'неаутентифицированный зритель хосту не виден');
});

test('v2: хост до auth: кадры, команды и heartbeat не действуют', async () => {
  const w = world(), f = w.f(ROOM);
  const { socket } = await connectHost(f);
  const approved = f.socket('viewer', { id: VIEWER_ID, approved: true, lastSeen: 1_000_000 });
  await f.room.webSocketMessage(socket, new ArrayBuffer(8));
  await f.room.webSocketMessage(socket, '{"type":"heartbeat"}');
  await f.room.webSocketMessage(socket, '{"type":"game","to":"9876543210","action":"invite"}');
  assert.equal(approved.messages.length, 0);
  await f.room.webSocketMessage(socket, JSON.stringify({ type: 'release' }));
  assert.equal(f.store.get('owner'), undefined);
});

test('v2: поток зрителя — challenge, auth, request хосту с ключом, fp и idVerified', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const { socket: viewer } = await connectViewer(f);
  const challenge = msgOf(viewer, 'challenge');
  assert.equal(challenge.hostKey, KEY_A.pub);
  assert.equal(challenge.hostFp, msgOf(host, 'authed').fp);
  assert.match(challenge.rid, /^[0-9a-f-]{36}$/);
  assert.equal(host.messages.some((m) => m.type === 'request'), false, 'до auth хост ничего не видит');
  await f.room.webSocketMessage(viewer, JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', pub: KEY_B.pub, sig: KEY_B.sign(viewerMsg(ROOM, VIEWER_ID, challenge.rid, challenge.nonce)) }));
  assert.deepEqual(msgOf(viewer, 'waiting'), { type: 'waiting', v: 2, rid: challenge.rid });
  const request = msgOf(host, 'request');
  assert.equal(request.v, 2);
  assert.equal(request.auth, 'key');
  assert.equal(request.pub, KEY_B.pub);
  assert.equal(request.rid, challenge.rid);
  assert.equal(request.viewer, VIEWER_ID);
  assert.equal(request.idVerified, true, 'ID свободен: привязан к ключу зрителя');
  assert.equal(request.self, false);
  assert.match(request.fp, /^[0-9a-f]{4}(-[0-9a-f]{4}){3}$/);
  assert.equal(w.f(VIEWER_ID).store.get('owner').pub, KEY_B.pub);
});

test('v2: чужой ключ с занятым ID зрителя → idVerified:false', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  await authViewer(f, KEY_B);
  await authViewer(f, KEY_C);
  const requests = host.messages.filter((m) => m.type === 'request');
  assert.equal(requests.length, 2);
  assert.equal(requests[1].idVerified, false);
  assert.equal(requests[1].viewer, VIEWER_ID);
  assert.equal(w.f(VIEWER_ID).store.get('owner').pub, KEY_B.pub);
});

test('v2: self — владелец комнаты подключается к себе (viewer = ID комнаты), чужой ключ получает пустой ID', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f, KEY_A);
  await authViewer(f, KEY_A, { id: ROOM });
  const own = host.messages.filter((m) => m.type === 'request').at(-1);
  assert.equal(own.self, true);
  assert.equal(own.viewer, ROOM);
  assert.equal(own.idVerified, true);
  await authViewer(f, KEY_C, { id: ROOM });
  const spoof = host.messages.filter((m) => m.type === 'request').at(-1);
  assert.equal(spoof.self, false);
  assert.equal(spoof.viewer, '');
  assert.equal(spoof.idVerified, false);
});

test('v2: подпись зрителя привязана к ID, rid и nonce; не 10 цифр → id-format до request', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const { socket } = await connectViewer(f);
  const challenge = msgOf(socket, 'challenge');
  await f.room.webSocketMessage(socket, JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', pub: KEY_B.pub, sig: KEY_B.sign(viewerMsg(ROOM, '1111111111', challenge.rid, challenge.nonce)) }));
  assert.equal(msgOf(socket, 'error').code, 'bad-signature');
  assert.equal(socket.closes.at(-1)[0], 4401);
  for (const bad of ['123', '12345678901', '123-456-789-0', '']) {
    const { res, socket: s } = await connectViewer(f, { id: bad });
    assert.equal(res.status, 101);
    assert.equal(msgOf(s, 'error').code, 'id-format', bad);
    assert.equal(s.closes.at(-1)[0], 4400);
  }
  assert.equal(host.messages.some((m) => m.type === 'request'), false);
});

test('v2: зритель до auth может слать только auth и heartbeat; повторный auth → 4400', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const { socket } = await connectViewer(f);
  await f.room.webSocketMessage(socket, JSON.stringify({ type: 'ping', x: 0.5, y: 0.5 }));
  await f.room.webSocketMessage(socket, JSON.stringify({ type: 'game', action: 'invite' }));
  await f.room.webSocketMessage(socket, '{"type":"heartbeat"}');
  assert.equal(host.messages.some((m) => m.type === 'ping' || m.type === 'game'), false);
  assert.equal(socket.info.auth, 'pending');
  const viewer = await authViewer(f, KEY_B);
  await f.room.webSocketMessage(viewer, JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', pub: KEY_B.pub, sig: 'x' }));
  assert.equal(viewer.closes.at(-1)[0], 4400);
});

test('v2: закрытие зрителя до auth не шлёт cancelled', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const { socket } = await connectViewer(f);
  f.room.webSocketClose(socket, 1001);
  assert.equal(host.messages.some((m) => m.type === 'cancelled'), false);
  const authed = await authViewer(f, KEY_B);
  f.room.webSocketClose(authed, 1001);
  assert.equal(host.messages.filter((m) => m.type === 'cancelled').length, 1);
});

test('v2: хост с ключом отвечает только с rid; hostSig передаётся только в верном формате', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const viewer = await authViewer(f, KEY_B);
  const rid = viewer.info.rid;
  await f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: VIEWER_ID, name: 'Mac' }));
  assert.equal(viewer.info.approved, false, 'без rid команда игнорируется');
  await f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: VIEWER_ID, rid: 42, name: 'Mac' }));
  assert.equal(viewer.info.approved, false);
  await f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: VIEWER_ID, rid, name: 'Mac', hostSig: 'bad' }));
  assert.equal(viewer.info.approved, true);
  assert.deepEqual(viewer.messages.at(-1), { type: 'accepted', name: 'Mac' });
  const second = await authViewer(f, KEY_C, { id: '5550001112' });
  const sig = KEY_A.sign(`mu-share/v2\naccept\n${ROOM}\n${KEY_C.pub}\n${second.info.rid}`);
  await f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: '5550001112', rid: second.info.rid, name: 'Mac', hostSig: sig }));
  assert.deepEqual(second.messages.at(-1), { type: 'accepted', name: 'Mac', hostSig: sig });
});

test('v2: viewers.list получает fp и auth только у зрителей с ключом; game — fp', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const viewer = await authViewer(f, KEY_B);
  f.socket('viewer', { id: '1111111111', name: 'Legacy', approved: true, lastSeen: 1_000_000 });
  await f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: VIEWER_ID, rid: viewer.info.rid, name: 'Mac' }));
  const list = host.messages.filter((m) => m.type === 'viewers').at(-1).list;
  assert.equal(list.find((p) => p.id === VIEWER_ID).auth, 'key');
  assert.match(list.find((p) => p.id === VIEWER_ID).fp, /^[0-9a-f]{4}(-[0-9a-f]{4}){3}$/);
  assert.deepEqual(list.find((p) => p.id === '1111111111'), { id: '1111111111', name: 'Legacy', h264: false });
  await f.room.webSocketMessage(viewer, JSON.stringify({ type: 'game', action: 'invite', from: 'host' }));
  const game = host.messages.at(-1);
  assert.equal(game.from, VIEWER_ID);
  assert.equal(game.fp, viewer.info.fp);
});

test('v2: legacy-зритель — request без v2-полей для старого хоста и с auth:none для хоста с ключом; challenge ему не шлётся', async () => {
  const w = world(), f = w.f(ROOM);
  const oldHost = hostLive(f);
  const { socket: legacyViewer } = await connectViewer(f, { headers: V1, id: '2222222222' });
  assert.deepEqual(legacyViewer.messages.map((m) => m.type), ['waiting']);
  const req = oldHost.messages.find((m) => m.type === 'request');
  assert.deepEqual(Object.keys(req).sort(), ['name', 'rid', 'type', 'viewer']);
  const w2 = world(), g = w2.f(ROOM);
  const host = await authHost(g);
  await connectViewer(g, { headers: V1, id: '2222222222' });
  const request = msgOf(host, 'request');
  assert.equal(request.auth, 'none');
  assert.equal(request.v, 2);
  assert.equal(request.pub, undefined);
});

test('v2-поля (challenge, authed, error) не уходят legacy-сокетам', async () => {
  const w = world(), f = w.f(ROOM);
  const legacyHost = (await connectHost(f, V1)).socket;
  assert.equal(legacyHost.messages.length, 0);
  assert.equal(f.room.activeHosts().length, 1);
  f.advance(20_000);
  await f.room.alarm();
  const { socket: legacyViewer } = await connectViewer(f, { headers: V1 });
  f.advance(20_000);
  await f.room.alarm();
  const types = [...legacyHost.messages, ...legacyViewer.messages].map((m) => m.type);
  assert.equal(types.some((t) => ['challenge', 'authed', 'error'].includes(t)), false, types.join());
});

test('AUTH_MODE=off: mu-share-2 обслуживается как legacy, хосту authed mode:off, зрителю без challenge', async () => {
  const w = world({ AUTH_MODE: 'off' }), f = w.f(ROOM);
  const { res, socket } = await connectHost(f);
  assert.equal(res.status, 101);
  assert.deepEqual(socket.messages, [{ type: 'authed', v: 2, mode: 'off' }]);
  assert.equal(f.room.activeHosts().length, 1);
  const { socket: viewer } = await connectViewer(f);
  assert.deepEqual(viewer.messages.map((m) => m.type), ['waiting']);
  assert.equal(msgOf(socket, 'request').auth, undefined);
});

test('AUTH_MODE=required: mu-share-1 → 426, mu-share-2 работает', async () => {
  const w = world({ AUTH_MODE: 'required' }), f = w.f(ROOM);
  assert.equal((await f.room.fetch(new Request(roomUrl(ROOM, 'role=host'), { headers: V1 }))).status, 426);
  assert.equal((await f.room.fetch(new Request(roomUrl(ROOM, 'role=host')))).status, 426);
  assert.equal((await connectHost(f)).res.status, 101);
});

test('лимит ожидающих: не больше 10 в комнате, не больше 4 с одного IP; одобренные не считаются', async () => {
  const w = world(), f = w.f(ROOM);
  await authHost(f);
  const results = [];
  const ips = ['1.1.1.1', '1.1.1.1', '1.1.1.1', '1.1.1.1', '1.1.1.1', '2.2.2.2', '3.3.3.3', '4.4.4.4', '5.5.5.5', '6.6.6.6', '7.7.7.7', '8.8.8.8'];
  for (const [i, ip] of ips.entries()) {
    results.push((await connectViewer(f, { headers: V1, id: `55500011${String(i).padStart(2, '0')}`, ip })).res.status);
  }
  assert.deepEqual(results, [101, 101, 101, 101, 429, 101, 101, 101, 101, 101, 101, 429]);
  const pending = f.all().filter((s) => s.tag === 'viewer');
  pending[0].info.approved = true;
  assert.equal((await connectViewer(f, { headers: V1, id: '5550001199', ip: '9.9.9.9' })).res.status, 101);
});

test('MAX_VIEWERS считает только одобренных', async () => {
  const w = world(), f = w.f(ROOM);
  await authHost(f);
  for (let i = 0; i < 10; i++) f.socket('viewer', { id: `100000000${i}`, approved: true, lastSeen: 1_000_000 });
  assert.equal((await connectViewer(f, { headers: V1 })).res.status, 429);
  const g = world().f(ROOM);
  await authHost(g);
  for (let i = 0; i < 10; i++) g.socket('viewer', { id: `200000000${i}`, approved: false, ended: true, lastSeen: 1_000_000 });
  assert.equal((await connectViewer(g, { headers: V1 })).res.status, 101);
});

test('запросы хосту: 20 в минуту сразу, остальные ждут очереди; cancelled и accept для ожидающих не действуют', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const viewers = [];
  for (let i = 0; i < 22; i++) {
    // Временно завершены, чтобы не упереться в лимит ожидающих (10); на окно запросов это не влияет.
    for (const s of viewers) s.info.ended = true;
    const { socket } = await connectViewer(f, { headers: V1, id: `50000000${String(i).padStart(2, '0')}`, ip: `9.9.9.${i}` });
    viewers.push(socket);
  }
  for (const v of viewers) delete v.info.ended;
  const requestsOf = () => host.messages.filter((m) => m.type === 'request').map((m) => m.viewer);
  assert.equal(requestsOf().length, 20);
  assert.equal(viewers[20].info.reqSent, false);
  await f.room.webSocketMessage(host, JSON.stringify({ type: 'accept', viewer: '5000000020', rid: viewers[20].info.rid }));
  assert.equal(viewers[20].info.approved, false, 'запрос ещё не показан хосту');
  f.room.webSocketClose(viewers[21]);
  assert.equal(host.messages.filter((m) => m.type === 'cancelled' && m.viewer === '5000000021').length, 0);
  f.advance(61_000);
  for (const v of viewers.slice(0, 21)) v.info.lastSeen = 1_061_000;
  await f.room.alarm();
  assert.equal(requestsOf().includes('5000000020'), true);
  assert.equal(requestsOf().includes('5000000021'), false, 'закрытый зритель из очереди не уходит');
});

test('после decline: тот же ключ (v2) и тот же IP (legacy) ждут 60 с, после третьего подряд — 10 минут', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const declineLast = async (socket) => f.room.webSocketMessage(host, JSON.stringify({ type: 'decline', viewer: socket.info.id, rid: socket.info.rid }));
  const first = await authViewer(f, KEY_B);
  await declineLast(first);
  const blocked = await connectViewer(f);
  const challenge = msgOf(blocked.socket, 'challenge');
  await f.room.webSocketMessage(blocked.socket, JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', pub: KEY_B.pub, sig: KEY_B.sign(viewerMsg(ROOM, VIEWER_ID, challenge.rid, challenge.nonce)) }));
  assert.equal(msgOf(blocked.socket, 'error').code, 'rate-limited');
  assert.equal(blocked.socket.closes.at(-1)[0], 4429);
  const other = await authViewer(f, KEY_C, { id: '5550001112' });
  assert.equal(other.info.auth, 'key', 'другой ключ не затронут');
  f.advance(61_000);
  const again = await authViewer(f, KEY_B);
  assert.equal(again.info.auth, 'key');
  // legacy: по IP
  const legacy = await connectViewer(f, { headers: V1, id: '7770001112', ip: '8.8.8.8' });
  await declineLast(legacy.socket);
  assert.equal((await connectViewer(f, { headers: V1, id: '7770001112', ip: '8.8.8.8' })).res.status, 429);
  f.advance(61_000);
  assert.equal((await connectViewer(f, { headers: V1, id: '7770001112', ip: '8.8.8.8' })).res.status, 101);
});

test('новые привязки: хосты квоту не тратят; ID зрителя — не больше 20 в сутки с одного IP, потом idVerified:false', async () => {
  const w = world();
  const outcomes = [];
  for (let i = 0; i < 6; i++) {
    const id = `100000000${i + 1}`;
    const host = await authHost(w.f(id), keypair(10 + i), id, '7.7.7.7');
    outcomes.push(msgOf(host, 'authed') ? 'ok' : msgOf(host, 'error').code);
  }
  assert.deepEqual(outcomes, ['ok', 'ok', 'ok', 'ok', 'ok', 'ok']);
  // Квота зрителя — через внутренний /claim (так его вызывает комната, где зритель подключается).
  const claim = async (id, n) => (await (await w.f(id).room.fetch(new Request('https://room/claim', {
    method: 'POST', body: JSON.stringify({ pub: keypair(50 + n).pub, ip: '8.8.8.8' }) }))).json());
  const results = [];
  for (let n = 0; n < 21; n++) results.push((await claim(`20000000${String(n).padStart(2, '0')}`, n)).ok);
  assert.deepEqual(results, [...Array(20).fill(true), false]);
  assert.equal((await claim('2000000020', 20)).reason, 'rate-limited');
  w.advance(86_400_001);
  assert.equal((await claim('2000000020', 20)).ok, true, 'новые сутки');
});

test('release: хост с ключом освобождает ID, зрители завершаются, ID свободен для другого ключа', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await authHost(f);
  const viewer = f.socket('viewer', { id: VIEWER_ID, approved: true, lastSeen: 1_000_000 });
  await f.room.webSocketMessage(host, JSON.stringify({ type: 'release' }));
  await tick();
  assert.equal(f.store.get('owner'), undefined);
  assert.equal(host.closes.at(-1)[0], 1000);
  assert.equal(viewer.messages.at(-1).type, 'ended');
  assert.equal(msgOf(await authHost(f, KEY_C), 'authed').claimed, true);
});

test('владелец без активности 180 дней теряет ID; активность продлевает не чаще раза в час', async () => {
  const w = world(), f = w.f(ROOM);
  await authHost(f, KEY_A);
  const claimedAt = f.store.get('owner').lastSeenAt;
  f.advance(1_000);
  await authHost(f, KEY_A);
  assert.equal(f.store.get('owner').lastSeenAt, claimedAt, 'обновление не чаще раза в час');
  f.advance(3_600_000);
  await authHost(f, KEY_A);
  assert.ok(f.store.get('owner').lastSeenAt > claimedAt);
  f.advance(181 * 86_400_000);
  assert.equal(msgOf(await authHost(f, KEY_C), 'authed').claimed, true);
  assert.equal(f.store.get('owner').pub, KEY_C.pub);
});

test('/claim между комнатами: проверка формата, и маршрут недоступен снаружи через Worker', async () => {
  const w = world(), f = w.f(ROOM);
  const bad = await f.room.fetch(new Request('https://room/claim', { method: 'POST', body: JSON.stringify({ pub: 'x' }) }));
  assert.equal(bad.status, 400);
  const ok = await f.room.fetch(new Request('https://room/claim', { method: 'POST', body: JSON.stringify({ pub: KEY_A.pub, ip: '' }) }));
  assert.deepEqual(await ok.json(), { ok: true, claimed: true });
  assert.deepEqual(await (await f.room.fetch(new Request('https://room/claim', { method: 'POST', body: JSON.stringify({ pub: KEY_B.pub }) }))).json(),
    { ok: false, claimed: false, reason: 'id-claimed' });
  const forwarded = [];
  const env = { ROOMS: { idFromName: (n) => n, get: () => ({ fetch: (r) => { forwarded.push(r); return new Response('room'); } }) } };
  for (const path of [`/room/${ROOM}/claim`, '/claim', '/quota', `/room/${ROOM}/quota`, '/room/__limits']) {
    for (const method of ['GET', 'POST']) {
      const res = await f.worker.fetch(new Request(`https://relay.example${path}`, { method, headers: V2, ...(method === 'POST' ? { body: '{"pub":"x"}' } : {}) }), env);
      assert.equal(res.status, 200, `${method} ${path}`);
      assert.equal(await res.text(), 'PAGE', `${method} ${path}`);
    }
  }
  assert.equal(forwarded.length, 0, 'во внутренние маршруты комнат снаружи не попасть');
});

test('Worker: IP клиента кладётся в x-relay-ip (подделка заголовка не проходит), лимит подключений и /version', async () => {
  const w = world({ RL_CONNECT: { limit: async ({ key }) => ({ success: key !== '6.6.6.6' }) }, RELAY_COMMIT: 'abc1234' });
  const f = w.f(ROOM);
  const seen = [];
  w.env.ROOMS = { idFromName: (n) => n, get: () => ({ fetch: (r) => { seen.push(r.headers.get('x-relay-ip')); return new Response('ok'); } }) };
  const upgrade = (ip, extra = {}) => new Request(roomUrl(ROOM, 'role=host'), { headers: { ...V2, Upgrade: 'websocket', 'CF-Connecting-IP': ip, ...extra } });
  assert.equal((await f.worker.fetch(upgrade('1.2.3.4', { 'x-relay-ip': '9.9.9.9' }), w.env)).status, 200);
  assert.equal((await f.worker.fetch(upgrade('6.6.6.6'), w.env)).status, 429);
  assert.deepEqual(seen, ['1.2.3.4']);
  const noClient = await f.worker.fetch(new Request(roomUrl(ROOM, 'role=host'), { headers: { Upgrade: 'websocket' } }), w.env);
  assert.equal(noClient.status, 403);
  const version = await (await f.worker.fetch(new Request('https://relay.example/version'), w.env)).json();
  assert.deepEqual(version, { commit: 'abc1234', protocols: ['mu-share-1', 'mu-share-2'], auth: 'optional' });
  const required = await (await f.worker.fetch(new Request('https://relay.example/version'), { ...w.env, AUTH_MODE: 'required' })).json();
  assert.deepEqual(required.protocols, ['mu-share-2']);
  assert.equal((await f.worker.fetch(new Request(roomUrl(ROOM, 'role=host'), { headers: { ...V1, Upgrade: 'websocket' } }), { ...w.env, AUTH_MODE: 'required' })).status, 426);
  const dev = await (await f.worker.fetch(new Request('https://relay.example/version'), { ROOMS: w.env.ROOMS })).json();
  assert.equal(dev.commit, 'dev');
});

function statusBody(key, { id = ROOM, ids = [VIEWER_ID], ts = 1_000_000, v = 2 } = {}) {
  return { v, id, pub: key.pub, ts, ids, sig: key.sign(`mu-share/v2\nstatus\n${id}\n${ts}\n${ids.join(',')}`) };
}
const postStatus = (f, env, body, headers = V2) =>
  f.worker.fetch(new Request('https://relay.example/status', { method: 'POST', headers, body: JSON.stringify(body) }), env);

test('POST /status: подпись, свежесть, владелец ID, лимиты', async () => {
  const w = world({ RL_STATUS: { limit: async ({ key }) => ({ success: key !== '6.6.6.6' }) } }), f = w.f('control');
  await authHost(w.f(VIEWER_ID), KEY_C, VIEWER_ID);
  await authHost(w.f('1000000001'), KEY_A, '1000000001');
  const ok = await postStatus(f, w.env, statusBody(KEY_A, { id: '1000000001', ids: [VIEWER_ID, '1000000001', '2000000000'] }));
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), { [VIEWER_ID]: true, '1000000001': true, '2000000000': false });
  const cases = [
    [statusBody(KEY_A, { id: '1000000001', ts: 1_000_000 - 121_000 }), 400, 'протухший ts'],
    [{ ...statusBody(KEY_A, { id: '1000000001' }), sig: KEY_B.sign('x') }, 401, 'чужая подпись'],
    [statusBody(KEY_B, { id: '1000000001' }), 403, 'ключ не владелец ID'],
    [statusBody(KEY_A, { id: '1000000001', ids: Array.from({ length: 21 }, (_, i) => `30000000${String(i).padStart(2, '0')}`) }), 400, '> 20 ID'],
    [statusBody(KEY_A, { id: '1000000001', ids: ['123456'] }), 400, '6-значный ID'],
    [statusBody(KEY_A, { id: '123456', ids: [] }), 400, 'свой ID не 10 цифр'],
    [statusBody(KEY_A, { id: '1000000001', v: 1 }), 400, 'версия'],
  ];
  for (const [body, status, why] of cases) assert.equal((await postStatus(f, w.env, body)).status, status, why);
  assert.equal((await postStatus(f, w.env, statusBody(KEY_A, { id: '1000000001' }), {})).status, 403, 'без заголовка клиента');
  const off = await postStatus(f, { ...w.env, AUTH_MODE: 'off' }, statusBody(KEY_A, { id: '1000000001' }));
  assert.equal(off.status, 404);
  const byIp = await f.worker.fetch(new Request('https://relay.example/status', { method: 'POST', headers: { ...V2, 'CF-Connecting-IP': '6.6.6.6' }, body: JSON.stringify(statusBody(KEY_A, { id: '1000000001' })) }), w.env);
  assert.equal(byIp.status, 429);
});

test('POST /status: не больше 6 запросов в минуту на ключ', async () => {
  const w = world(), f = w.f('control');
  await authHost(w.f('1000000002'), KEY_A, '1000000002');
  const statuses = [];
  for (let i = 0; i < 8; i++) statuses.push((await postStatus(f, w.env, statusBody(KEY_A, { id: '1000000002', ids: [] }))).status);
  assert.deepEqual(statuses.slice(0, 6).every((s) => s === 200), true);
  assert.deepEqual(statuses.slice(6), [429, 429]);
});

test('GET /status: только 10-значные ID, не больше 20, лимит по IP; required выключает GET', async () => {
  const w = world({ RL_STATUS: { limit: async ({ key }) => ({ success: key !== '6.6.6.6' }) } }), f = w.f('control');
  const asked = [];
  w.env.ROOMS = { idFromName: (n) => n, get: (n) => ({ fetch: () => { asked.push(n); return new Response('0'); } }) };
  const ids = ['123456', ...Array.from({ length: 25 }, (_, i) => `40000000${String(i).padStart(2, '0')}`)];
  const res = await f.worker.fetch(new Request(`https://relay.example/status?ids=${ids.join(',')}`, { headers: V2 }), w.env);
  assert.equal(res.status, 200);
  assert.equal(asked.length, 20);
  assert.equal(asked.includes('123456'), false);
  assert.equal((await f.worker.fetch(new Request('https://relay.example/status?ids=4000000000', { headers: { ...V2, 'CF-Connecting-IP': '6.6.6.6' } }), w.env)).status, 429);
  assert.equal((await f.worker.fetch(new Request('https://relay.example/status?ids=4000000000', { headers: V1 }), { ...w.env, AUTH_MODE: 'required' })).status, 426);
  assert.equal((await f.worker.fetch(new Request('https://relay.example/status?ids=4000000000'), w.env)).status, 403);
});
