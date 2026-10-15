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
  };
  const context = vm.createContext({ Date: { now: () => now }, Response, URL });
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
  return { room, socket, advance(ms) { now += ms; }, get alarm() { return alarm; } };
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
