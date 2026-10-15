const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(`${__dirname}/../src/index.js`, 'utf8')
  .replace(/^import .*;$/gm, '')
  .replace('export default', 'const worker =')
  .replace('export class Room', 'class Room');
function fixture() {
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
  }
  class FakePair { constructor() { const mk = () => ({ readyState: 1, info: null, messages: [], closes: [],
      deserializeAttachment() { return this.info; }, serializeAttachment(v) { this.info = v; },
      send(v) { this.messages.push(JSON.parse(v)); }, close(...a) { this.closes.push(a); this.readyState = 2; } });
    this[0] = mk(); this[1] = mk(); } }
  const context = vm.createContext({ Date: { now: () => now }, Response: FakeResponse, URL, WebSocketPair: FakePair, crypto: globalThis.crypto });
  vm.runInContext(`${source}\nthis.Room = Room;`, context);
  const room = new context.Room(state);
  function socket(tag, info) {
    const s = { tag, readyState: 1, info, messages: [], closes: [],
      deserializeAttachment() { return this.info; },
      serializeAttachment(value) { this.info = value; },
      send(value) { this.messages.push(JSON.parse(value)); },
      close(...args) { this.closes.push(args); this.readyState = 2; },
    };
    sockets.push(s); return s;
  }
  return { room, socket, all: () => sockets, advance(ms) { now += ms; }, get alarm() { return alarm; } };
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
  f.room.hostCommand('{"type":"accept","viewer":"1111111111"}');
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
