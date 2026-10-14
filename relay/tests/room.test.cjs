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
  const sockets = [];
  const state = {
    storage: { getAlarm: async () => alarm, setAlarm: async (value) => { alarm = value; } },
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
test('stale host releases ID and ends viewers; late close cannot end new session', async () => {
  const f = fixture(), host = f.socket('host', { lastSeen: 1_000_000 });
  const viewer = f.socket('viewer', { approved: true });
  f.advance(120_000);
  const status = await f.room.fetch(new Request('https://room/live'));
  assert.equal(await status.text(), '0');
  assert.equal(host.closes.length, 1);
  assert.equal(viewer.messages[0].type, 'ended');
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
