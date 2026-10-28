// T1: сквозные (e2e) сценарии аутентификации relay v2 — .audit/auth-design.md, разделы 8 (T1) и 10.
// Все подключения идут через Worker (`worker.fetch`: заголовки клиента, IP из CF-Connecting-IP, AUTH_MODE),
// дальше в Room (отдельная «комната» на каждый ID, как Durable Objects) и между комнатами (/claim, /quota, /live).
// Обвязка — копия из room.test.cjs (он не экспортирует свою фикстуру, а require исполнил бы его тесты второй раз).
//
// Тесты с пометкой `BUG-N` описывают найденные дефекты relay (исправлены, .audit/plan-auth-fix.md); R-A…R-F — сценарии
// security-ревью (.audit/review-auth-b.md).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const nodeCrypto = require('node:crypto');

const source = ['limits.js', 'auth.js', 'csp.js', 'index.js']
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
      delete: async (key) => { for (const k of Array.isArray(key) ? key : [key]) store.delete(k); },
      list: async ({ prefix = '' } = {}) => new Map([...store].filter(([k]) => k.startsWith(prefix))),
    },
    getWebSockets: (tag) => sockets.filter((s) => s.tag === tag),
    getTags: (s) => [s.tag],
    acceptWebSocket: (s, tags) => { s.tag = tags[0]; sockets.push(s); },
  };
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
  let room = new context.Room(state, env);
  function socket(tag, info) {
    const s = { tag, readyState: 1, info, messages: [], closes: [],
      deserializeAttachment() { return this.info; },
      serializeAttachment(value) { this.info = value; },
      send(value) { this.messages.push(JSON.parse(value)); },
      close(...args) { this.closes.push(args); this.readyState = 2; },
    };
    sockets.push(s); return s;
  }
  return { get room() { return room; }, worker: context.worker, store, socket, all: () => sockets, advance(ms) { now += ms; }, get now() { return now; },
    // Выгрузка Durable Object: память (Map в объекте) пропадает, storage и сокеты остаются.
    reload() { room = new context.Room(state, env); } };
}

// ---------- ключи, канонические строки ----------
const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
function keypair(n) {
  const seed = Buffer.alloc(32, n);
  const priv = nodeCrypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
  const pub = b64u(nodeCrypto.createPublicKey(priv).export({ format: 'der', type: 'spki' }).subarray(-32));
  return { pub, sign: (message) => b64u(nodeCrypto.sign(null, Buffer.from(message), priv)) };
}
const OWNER = keypair(1), VIEWER_KEY = keypair(2), ATTACKER = keypair(3), OTHER = keypair(4);
const ROOM = '1234567890', VIEWER = '9876543210';
const hostMsg = (room, nonce) => `mu-share/v2\nhost\n${room}\n${nonce}`;
const viewerMsg = (room, id, rid, nonce) => `mu-share/v2\nviewer\n${room}\n${id}\n${rid}\n${nonce}`;
const V1 = 'mu-share-1', V2 = 'mu-share-2';
const authFrame = (key, sig) => JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', pub: key.pub, sig });
const send = (f, socket, message) => f.room.webSocketMessage(socket, typeof message === 'string' ? message : JSON.stringify(message));

// ---------- мир: Worker + несколько комнат ----------
function world(extra = {}) {
  const rooms = new Map();
  const env = { ...extra };
  const fixtureFor = (name) => { if (!rooms.has(name)) rooms.set(name, fixture(env)); return rooms.get(name); };
  env.ROOMS = {
    idFromName: (name) => name,
    get: (name) => ({ fetch: (url, init) => fixtureFor(name).room.fetch(url instanceof Request ? url : new Request(url, init)) }),
  };
  const control = fixtureFor('__control');
  const w = {
    env, f: fixtureFor, control,
    advance(ms) { for (const f of rooms.values()) f.advance(ms); },
    // Время идёт, а подключённые хосты и зрители продолжают слать heartbeat (иначе через 2 минуты комната «умирает»).
    pass(ms) {
      for (const f of rooms.values()) {
        f.advance(ms);
        for (const s of f.all()) if (s.readyState === 1 && s.info && !s.info.ended && s.info.lastSeen != null) s.info.lastSeen = f.now;
      }
    },
    get now() { return control.now; },
    worker: (request, overrideEnv) => control.worker.fetch(request, overrideEnv || env),
  };
  return w;
}

const lastOf = (f, tag) => f.all().filter((s) => s.tag === tag).at(-1);
const msgOf = (socket, type) => socket.messages.find((m) => m.type === type);
const msgsOf = (socket, type) => socket.messages.filter((m) => m.type === type);
const closeCode = (socket) => socket.closes.at(-1)?.[0];
const types = (socket) => socket.messages.map((m) => m.type);

// Подключение «как из приложения»: через Worker, с заголовком клиента и IP.
async function connect(w, role, id, { token = V2, viewer, name = 'Петя', ip, headers = {}, query = '', env } = {}) {
  const params = role === 'host' ? 'role=host' : `role=viewer&viewer=${viewer ?? VIEWER}&name=${encodeURIComponent(name)}&h264=1`;
  const h = { Upgrade: 'websocket', ...(token ? { 'x-macutils-client': token } : {}), ...(ip ? { 'CF-Connecting-IP': ip } : {}), ...headers };
  const res = await w.worker(new Request(`https://relay.example/room/${id}?${params}${query}`, { headers: h }), env);
  return { res, socket: res.status === 101 ? lastOf(w.f(id), role) : null };
}
async function hostLogin(w, key = OWNER, id = ROOM, opts = {}) {
  const { res, socket } = await connect(w, 'host', id, opts);
  assert.equal(res.status, 101, 'хост подключился');
  const challenge = msgOf(socket, 'challenge');
  await send(w.f(id), socket, authFrame(key, key.sign(hostMsg(id, challenge.nonce))));
  return socket;
}
async function viewerLogin(w, key = VIEWER_KEY, id = ROOM, opts = {}) {
  const viewerId = opts.viewer ?? VIEWER;
  const { res, socket } = await connect(w, 'viewer', id, opts);
  assert.equal(res.status, 101, 'зритель подключился');
  const challenge = msgOf(socket, 'challenge');
  await send(w.f(id), socket, authFrame(key, key.sign(viewerMsg(id, viewerId, challenge.rid, challenge.nonce))));
  return socket;
}
const decline = (w, host, viewerSocket, id = ROOM) => send(w.f(id), host, { type: 'decline', viewer: viewerSocket.info.id, rid: viewerSocket.info.rid });
const accept = (w, host, viewerSocket, id = ROOM) => send(w.f(id), host, { type: 'accept', viewer: viewerSocket.info.id, rid: viewerSocket.info.rid, name: 'Mac' });

// =====================================================================================================
// 1. Спуфинг viewer=
// =====================================================================================================
test('спуфинг viewer=<ID комнаты> (legacy): relay отдаёт хосту пустой ID, автоприёма нет, до accept зритель молчит', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const { socket: spoof } = await connect(w, 'viewer', ROOM, { token: V1, viewer: ROOM, name: 'Я сам' });
  const request = msgOf(host, 'request');
  assert.equal(request.viewer, '', 'хост видит «неизвестный», а не собственный ID');
  assert.equal(request.auth, 'none');
  assert.equal(request.pub, undefined);
  await send(f, spoof, { type: 'ping', x: 0.5, y: 0.5 });
  await send(f, spoof, { type: 'accept', viewer: '' });
  assert.equal(spoof.info.approved, false);
  assert.deepEqual(types(spoof), ['waiting']);
  assert.equal(msgsOf(host, 'ping').length, 0);
});

test('спуфинг чужого 10-значного ID (legacy): хост с ключом видит auth:"none" без pub — доверять по ID нельзя', async () => {
  const w = world();
  const host = await hostLogin(w);
  await connect(w, 'viewer', ROOM, { token: V1, viewer: '5550001112', name: 'Мама' });
  const request = msgOf(host, 'request');
  assert.equal(request.viewer, '5550001112');
  assert.equal(request.auth, 'none');
  assert.equal(request.idVerified, undefined);
  assert.equal(request.fp, undefined);
});

test('спуфинг чужого ID (v2): ключ-самозванец получает idVerified:false, настоящий владелец ID — true', async () => {
  const w = world();
  const host = await hostLogin(w);
  await viewerLogin(w, VIEWER_KEY, ROOM, { viewer: VIEWER });
  await viewerLogin(w, ATTACKER, ROOM, { viewer: VIEWER });
  const [real, fake] = msgsOf(host, 'request');
  assert.equal(real.idVerified, true);
  assert.equal(fake.idVerified, false, 'ID уже привязан к другому ключу');
  assert.notEqual(real.fp, fake.fp, 'отпечатки различаются — хост не спутает людей');
  assert.equal(w.f(VIEWER).store.get('owner').pub, VIEWER_KEY.pub, 'самозванец ID не отобрал');
});

test('спуфинг: подпись под другим ID, чужой комнатой или без viewer= отвергается (bad-signature / id-format)', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const { socket } = await connect(w, 'viewer', ROOM, { viewer: VIEWER });
  const ch = msgOf(socket, 'challenge');
  await send(f, socket, authFrame(VIEWER_KEY, VIEWER_KEY.sign(viewerMsg(ROOM, '1111111111', ch.rid, ch.nonce))));
  assert.equal(msgOf(socket, 'error').code, 'bad-signature');
  assert.equal(closeCode(socket), 4401);
  const { socket: otherRoom } = await connect(w, 'viewer', ROOM, { viewer: VIEWER });
  const ch2 = msgOf(otherRoom, 'challenge');
  await send(f, otherRoom, authFrame(VIEWER_KEY, VIEWER_KEY.sign(viewerMsg('0000000000', VIEWER, ch2.rid, ch2.nonce))));
  assert.equal(msgOf(otherRoom, 'error').code, 'bad-signature');
  for (const bad of ['', '123', '98765432101', ' 9876543210', '98765 43210', '９８７６５４３２１０']) {
    const { res, socket: s } = await connect(w, 'viewer', ROOM, { viewer: encodeURIComponent(bad) });
    assert.equal(res.status, 101);
    assert.equal(msgOf(s, 'error')?.code, 'id-format', JSON.stringify(bad));
    assert.equal(closeCode(s), 4400);
  }
  assert.equal(msgsOf(host, 'request').length, 0, 'ни одна подмена до хоста не дошла');
});

test('спуфинг служебных сообщений: одобренный зритель не может прислать request/viewers/ended/accepted, game несёт ID и fp из relay', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const viewer = await viewerLogin(w, VIEWER_KEY);
  await accept(w, host, viewer);
  const before = host.messages.length;
  for (const type of ['request', 'viewers', 'ended', 'accepted', 'cancelled', 'authed', 'challenge']) {
    await send(f, viewer, { type, viewer: '1111111111', name: 'Apple Support', count: 0, list: [] });
  }
  assert.equal(host.messages.length, before);
  await send(f, viewer, { type: 'game', action: 'invite', from: 'host', name: 'Boss', fp: 'ffff-ffff-ffff-ffff' });
  const game = host.messages.at(-1);
  assert.equal(game.from, VIEWER);
  assert.equal(game.name, 'Петя');
  assert.equal(game.fp, viewer.info.fp);
});

// =====================================================================================================
// 2. Захват ID в grace-периоде хоста
// =====================================================================================================
test('grace: после обрыва хоста чужой ключ получает id-claimed, зрители остаются в «переподключении»; владелец возвращает комнату', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const viewer = f.socket('viewer', { id: VIEWER, approved: true, approvedBy: OWNER.pub, lastSeen: w.now });
  f.room.webSocketClose(host, 1006);
  assert.equal(viewer.messages.at(-1).type, 'reconnecting');
  w.advance(10_000);
  const thief = await hostLogin(w, ATTACKER);
  assert.equal(msgOf(thief, 'error').code, 'id-claimed');
  assert.equal(closeCode(thief), 4403);
  assert.equal(msgsOf(viewer, 'resumed').length, 0, 'захватчик зрителей не получил');
  assert.equal(f.room.activeHosts().length, 0);
  const owner = await hostLogin(w, OWNER);
  assert.equal(msgOf(owner, 'authed').claimed, false);
  assert.equal(viewer.messages.at(-1).type, 'resumed');
  assert.deepEqual(f.room.activeHosts(), [owner]);
});

test('grace: старый хост без ключа (mu-share-1) на ID с владельцем получает 409 id-claimed — и в grace, и после', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  f.room.webSocketClose(host, 1006);
  w.advance(5_000);
  const { res } = await connect(w, 'host', ROOM, { token: V1 });
  assert.equal(res.status, 409);
  assert.equal(await res.text(), 'id-claimed');
  f.room.webSocketClose(host, 1000);
  assert.equal((await connect(w, 'host', ROOM, { token: V1 })).res.status, 409, 'владение сохраняется и без активного хоста');
});

test('grace: неавторизованное подключение «хоста» ничего не прерывает и через 10 с закрывается auth-timeout', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const viewer = f.socket('viewer', { id: VIEWER, approved: true, lastSeen: w.now });
  f.room.webSocketClose(host, 1006);
  const { socket: squat } = await connect(w, 'host', ROOM);
  assert.equal(f.room.activeHosts().length, 0);
  assert.equal(msgsOf(viewer, 'resumed').length, 0);
  w.advance(10_500);
  viewer.info.lastSeen = w.now;
  await f.room.alarm();
  assert.equal(msgOf(squat, 'error').code, 'auth-timeout');
  assert.equal(closeCode(squat), 4408);
  assert.equal(viewer.messages.some((m) => m.type === 'ended'), false, '45 с ещё не прошло — зрители ждут владельца');
});

test('grace: владельца нет 45 с — зрители получают ended, а ID остаётся за владельцем', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const viewer = f.socket('viewer', { id: VIEWER, approved: true, lastSeen: w.now });
  f.room.webSocketClose(host, 1006);
  w.advance(46_000);
  viewer.info.lastSeen = w.now;
  await f.room.alarm();
  assert.equal(viewer.messages.at(-1).type, 'ended');
  assert.equal((await hostLogin(w, ATTACKER)).messages.at(-1).code, 'id-claimed');
});

test('grace на ID без владельца (legacy-хост): захват другим клиентом возможен — остаточный риск §5.4, фиксируем текущее поведение', async () => {
  const w = world(), f = w.f(ROOM);
  const legacy = (await connect(w, 'host', ROOM, { token: V1 })).socket;
  f.room.webSocketClose(legacy, 1006);
  const { res } = await connect(w, 'host', ROOM, { token: V1 });
  assert.equal(res.status, 101, 'пока ID не привязан к ключу, защиты нет');
  assert.equal(f.store.get('owner'), undefined);
});

// =====================================================================================================
// 3. id-claimed
// =====================================================================================================
test('id-claimed: чужой ключ на свободном (но привязанном) ID отклонён, владелец и привязка не затронуты', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  f.room.webSocketClose(host, 1000);
  const thief = await hostLogin(w, ATTACKER);
  assert.equal(msgOf(thief, 'error').code, 'id-claimed');
  assert.equal(closeCode(thief), 4403);
  assert.equal(msgOf(thief, 'authed'), undefined);
  assert.equal(f.store.get('owner').pub, OWNER.pub);
  assert.equal(f.room.activeHosts().length, 0);
});

test('id-claimed: чужой ключ при живом владельце не вытесняет его и не получает зрителей', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const viewer = await viewerLogin(w);
  await accept(w, host, viewer);
  const thief = await hostLogin(w, ATTACKER);
  assert.equal(msgOf(thief, 'error').code, 'id-claimed');
  assert.deepEqual(f.room.activeHosts(), [host]);
  assert.equal(host.closes.length, 0);
  assert.equal(viewer.info.approved, true);
  assert.equal(viewer.messages.some((m) => m.type === 'ended'), false);
});

test('id-claimed: 6-значный ID занять нельзя (id-format), владелец не создаётся', async () => {
  const w = world(), f = w.f('123456');
  const host = await hostLogin(w, OWNER, '123456');
  assert.equal(msgOf(host, 'error').code, 'id-format');
  assert.equal(closeCode(host), 4400);
  assert.equal(f.store.get('owner'), undefined);
});

// =====================================================================================================
// 4. replaced — тот же владелец со второго устройства
// =====================================================================================================
test('replaced: второе устройство того же владельца вытесняет первое (4409), зрители не рвутся и grace не стартует', async () => {
  const w = world(), f = w.f(ROOM);
  const first = await hostLogin(w);
  const viewer = await viewerLogin(w);
  await accept(w, first, viewer);
  const second = await hostLogin(w);
  assert.equal(msgOf(second, 'authed').claimed, false);
  assert.equal(msgOf(first, 'error').code, 'replaced');
  assert.equal(closeCode(first), 4409);
  f.room.webSocketClose(first, 4409);
  assert.deepEqual(f.room.activeHosts(), [second]);
  assert.equal(viewer.info.approved, true);
  assert.equal(viewer.info.ended, undefined);
  assert.equal(viewer.messages.some((m) => ['ended', 'reconnecting'].includes(m.type)), false);
  assert.equal(f.room.hostLostAt ?? null, null);
});

test('replaced: второе устройство видит запросы зрителей, первое уже нет', async () => {
  const w = world();
  const first = await hostLogin(w);
  const second = await hostLogin(w);
  await viewerLogin(w);
  assert.equal(msgsOf(second, 'request').length, 1);
  assert.equal(msgsOf(first, 'request').length, 0);
});

test('replaced: хост без ключа, занявший ID до владельца, вытесняется, а пущенные им зрители получают ended', async () => {
  const w = world(), f = w.f(ROOM);
  const squatter = (await connect(w, 'host', ROOM, { token: V1 })).socket;
  const guest = f.socket('viewer', { id: VIEWER, approved: true, lastSeen: w.now });
  const owner = await hostLogin(w);
  assert.equal(closeCode(squatter), 4409);
  assert.equal(guest.messages.at(-1).type, 'ended');
  assert.deepEqual(f.room.activeHosts(), [owner]);
});

// =====================================================================================================
// 5. self — viewer == roomId
// =====================================================================================================
test('self: владелец комнаты смотрит сам себя — self:true, idVerified:true, запрос не ограничивается окном 5/мин', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  for (let i = 0; i < 5; i++) await viewerLogin(w, keypair(20 + i), ROOM, { viewer: `500000000${i}`, ip: `9.9.9.${i}` }).then((s) => { s.info.approved = true; });
  assert.equal(msgsOf(host, 'request').length, 5);
  const own = await viewerLogin(w, OWNER, ROOM, { viewer: ROOM, ip: '7.7.7.7' });
  const request = msgsOf(host, 'request').at(-1);
  assert.equal(request.self, true);
  assert.equal(request.viewer, ROOM);
  assert.equal(request.idVerified, true);
  assert.equal(own.info.reqSent, true, 'self обходит очередь');
  assert.equal(w.f(ROOM).store.get('owner').pub, OWNER.pub, 'собственная комната не перепривязывается');
});

test('self: чужой ключ с viewer=<ID комнаты> получает пустой ID, self:false, idVerified:false; legacy — тоже пустой ID', async () => {
  const w = world();
  const host = await hostLogin(w);
  await viewerLogin(w, ATTACKER, ROOM, { viewer: ROOM, ip: '1.1.1.1' });
  const foreign = msgsOf(host, 'request').at(-1);
  assert.deepEqual([foreign.viewer, foreign.self, foreign.idVerified, foreign.auth], ['', false, false, 'key']);
  assert.equal(w.f(ROOM).store.get('owner').pub, OWNER.pub, 'чужой ключ владельца не затёр');
  await connect(w, 'viewer', ROOM, { token: V1, viewer: ROOM, ip: '2.2.2.2' });
  assert.equal(msgsOf(host, 'request').at(-1).viewer, '');
});

test('self: подпись обязана быть по исходному ID комнаты — «стёртый» ID в подписи не принимается', async () => {
  const w = world(), f = w.f(ROOM);
  await hostLogin(w);
  const { socket } = await connect(w, 'viewer', ROOM, { viewer: ROOM });
  const ch = msgOf(socket, 'challenge');
  await send(f, socket, authFrame(OWNER, OWNER.sign(viewerMsg(ROOM, '', ch.rid, ch.nonce))));
  assert.equal(msgOf(socket, 'error').code, 'bad-signature');
});

// =====================================================================================================
// 6. Replay
// =====================================================================================================
test('replay: подпись зрителя с прошлого подключения (другие nonce и rid) не проходит, а при верном nonce но чужом rid — тоже', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const { socket: first } = await connect(w, 'viewer', ROOM);
  const c1 = msgOf(first, 'challenge');
  const captured = VIEWER_KEY.sign(viewerMsg(ROOM, VIEWER, c1.rid, c1.nonce));
  const { socket: second } = await connect(w, 'viewer', ROOM);
  const c2 = msgOf(second, 'challenge');
  assert.notEqual(c1.nonce, c2.nonce);
  assert.notEqual(c1.rid, c2.rid);
  await send(f, second, authFrame(VIEWER_KEY, captured));
  assert.equal(msgOf(second, 'error').code, 'bad-signature');
  const { socket: third } = await connect(w, 'viewer', ROOM);
  const c3 = msgOf(third, 'challenge');
  await send(f, third, authFrame(VIEWER_KEY, VIEWER_KEY.sign(viewerMsg(ROOM, VIEWER, c1.rid, c3.nonce))));
  assert.equal(msgOf(third, 'error').code, 'bad-signature', 'rid входит в подпись');
  const { socket: fourth } = await connect(w, 'viewer', ROOM);
  const c4 = msgOf(fourth, 'challenge');
  await send(f, fourth, authFrame(VIEWER_KEY, VIEWER_KEY.sign(viewerMsg(ROOM, VIEWER, c4.rid, c1.nonce))));
  assert.equal(msgOf(fourth, 'error').code, 'bad-signature', 'nonce входит в подпись');
  assert.equal(msgsOf(host, 'request').length, 0);
});

test('replay: подпись хоста с другого соединения или от другой комнаты не проходит; повторный auth на том же сокете → 4400', async () => {
  const w = world(), f = w.f(ROOM);
  const { socket: a } = await connect(w, 'host', ROOM);
  const sigA = OWNER.sign(hostMsg(ROOM, msgOf(a, 'challenge').nonce));
  const { socket: b } = await connect(w, 'host', ROOM);
  await send(f, b, authFrame(OWNER, sigA));
  assert.equal(msgOf(b, 'error').code, 'bad-signature');
  const g = w.f('2222222222');
  const { socket: c } = await connect(w, 'host', '2222222222');
  await send(g, c, authFrame(OWNER, OWNER.sign(hostMsg(ROOM, msgOf(c, 'challenge').nonce))));
  assert.equal(msgOf(c, 'error').code, 'bad-signature', 'подпись для другой комнаты');
  assert.equal(g.store.get('owner'), undefined);
  const viewer = await viewerLogin(w).catch(() => null);
  assert.equal(viewer, null, 'без хоста зрителя нет (404)');
  const host = await hostLogin(w);
  const authed = await viewerLogin(w);
  await send(f, authed, authFrame(VIEWER_KEY, 'x'));
  assert.equal(closeCode(authed), 4400);
  assert.ok(host);
});

// =====================================================================================================
// 7. auth-timeout
// =====================================================================================================
test('auth-timeout: молчащие хост и зритель закрываются 4408 через 10 с; авторизованные и сама комната не страдают', async () => {
  const w = world(), f = w.f(ROOM);
  const owner = await hostLogin(w);
  const good = await viewerLogin(w, VIEWER_KEY, ROOM, { ip: '1.1.1.1' });
  const { socket: silentViewer } = await connect(w, 'viewer', ROOM, { viewer: '5550001112', ip: '2.2.2.2' });
  const { socket: silentHost } = await connect(w, 'host', ROOM);
  w.advance(9_000);
  f.room.expireViewers();
  assert.equal(silentViewer.closes.length + silentHost.closes.length, 0, 'до 10 с ничего не закрывается');
  w.advance(1_500);
  await f.room.alarm();
  for (const socket of [silentViewer, silentHost]) {
    assert.equal(msgOf(socket, 'error').code, 'auth-timeout');
    assert.equal(closeCode(socket), 4408);
  }
  good.info.lastSeen = w.now;
  owner.info.lastSeen = w.now;
  assert.deepEqual(f.room.activeHosts(), [owner]);
  assert.equal(good.closes.length, 0);
  f.room.webSocketClose(silentHost, 4408);
  f.room.webSocketClose(silentViewer, 4408);
  assert.equal(msgsOf(owner, 'cancelled').length, 0, 'хост про неавторизованных не узнаёт');
  assert.equal(f.room.hostLostAt ?? null, null);
});

test('auth-timeout: будильник ставится при подключении без активного хоста — зависший pending-сокет не живёт вечно', async () => {
  const w = world(), f = w.f(ROOM);
  const { socket } = await connect(w, 'host', ROOM);
  assert.ok(await f.room.state.storage.getAlarm(), 'будильник стоит');
  w.advance(10_500);
  await f.room.alarm();
  assert.equal(closeCode(socket), 4408);
});

// =====================================================================================================
// 8. pending-лимиты
// =====================================================================================================
test('pending (B1): ожидающих ответа — не больше 10 в комнате и 4 с одного IP, для v2 после ключа и для legacy; одобренный освобождает место', async () => {
  const w = world();
  const host = await hostLogin(w);
  const office = [];
  for (let i = 0; i < 4; i++) office.push(await viewerLogin(w, keypair(11 + i), ROOM, { viewer: `555000000${i}`, ip: '1.1.1.1' }));
  assert.ok(office.every((v) => v.info.auth === 'key' && !v.info.ended), '4 зрителя из одного офиса');
  const fifth = await connect(w, 'viewer', ROOM, { viewer: '5550000009', ip: '1.1.1.1' });
  assert.equal(fifth.res.status, 429, '5-й с того же IP');
  assert.equal(await fifth.res.text(), 'rate-limited');
  assert.equal((await connect(w, 'viewer', ROOM, { token: V1, viewer: '5550000008', ip: '1.1.1.1' })).res.status, 429, 'и legacy тоже');
  for (let i = 0; i < 6; i++) {
    const res = (await connect(w, 'viewer', ROOM, { token: V1, viewer: `666000000${i}`, ip: `2.2.2.${i}` })).res;
    assert.equal(res.status, 101, `legacy ${i}`);
  }
  assert.equal((await connect(w, 'viewer', ROOM, { token: V1, viewer: '7770000000', ip: '3.3.3.3' })).res.status, 429, '11-й в комнате');
  assert.equal((await connect(w, 'viewer', ROOM, { viewer: '7770000001', ip: '3.3.3.4' })).res.status, 429, '11-й v2 тоже');
  await accept(w, host, office[0]);
  assert.equal((await connect(w, 'viewer', ROOM, { token: V1, viewer: '7770000000', ip: '3.3.3.3' })).res.status, 101, 'место освободилось');
});

test('pending (B1): 3 legacy-зрителя с одного IP одновременно → 101; два зрителя 1.4.0 из одного офиса (R-B) не получают 429', async () => {
  const w = world();
  const host = await hostLogin(w);
  const results = [];
  for (let i = 0; i < 3; i++) results.push((await connect(w, 'viewer', ROOM, { token: V1, viewer: `800000000${i}`, ip: '10.0.0.1' })).res.status);
  assert.deepEqual(results, [101, 101, 101]);
  assert.equal(msgsOf(host, 'request').length, 3, 'все три запроса дошли до ведущего сразу');
});

test('до проверки ключа (M1, F3): с одного IP — до 3 зрителей, четвёртый вытесняет самого старого с этого IP; в комнате не больше 5', async () => {
  const w = world(), f = w.f(ROOM);
  await hostLogin(w);
  const office = [];
  for (let i = 1; i <= 3; i++) { w.advance(1); office.push(await connect(w, 'viewer', ROOM, { viewer: `555000000${i}`, ip: '1.1.1.1' })); }
  assert.deepEqual(office.map((c) => c.res.status), [101, 101, 101], 'три из одного офиса одновременно (X3)');
  w.advance(1);
  const fourth = await connect(w, 'viewer', ROOM, { viewer: '5550000004', ip: '1.1.1.1' });
  assert.equal(fourth.res.status, 101, 'четвёртый с того же IP не получает отказ');
  assert.equal(closeCode(office[0].socket), 4429, 'вытеснен самый старый с этого IP');
  for (let i = 5; i <= 6; i++) { w.advance(1); assert.equal((await connect(w, 'viewer', ROOM, { viewer: `555000000${i}`, ip: `2.2.2.${i}` })).res.status, 101); }
  assert.equal(f.room.unauthViewers().length, 5);
  w.advance(1);
  const next = await connect(w, 'viewer', ROOM, { viewer: '5550000007', ip: '4.4.4.4' });
  assert.equal(next.res.status, 101, 'комната полна: новый не получает отказ');
  assert.equal(closeCode(office[1].socket), 4429, 'вытеснен самый старый в комнате');
  assert.equal(msgOf(office[1].socket, 'error').code, 'rate-limited');
  assert.equal(f.room.unauthViewers().length, 5);
  const back = await viewerLogin(w, keypair(21), ROOM, { viewer: '5550000001', ip: '1.1.1.9' });
  assert.equal(back.info.auth, 'key', 'честный клиент проходит проверку сразу');
});

test('F2: сокет, приславший auth, вытесняется последним — пять новых подключений во время проверки его не выбивают (X1)', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const honest = await connect(w, 'viewer', ROOM, { viewer: '5550000001', ip: '1.1.1.1' });
  const challenge = msgOf(honest.socket, 'challenge');
  // auth отправлен, проверка (подпись, /claim в чужую комнату) ещё идёт — не ждём её.
  const verifying = send(f, honest.socket, authFrame(VIEWER_KEY, VIEWER_KEY.sign(viewerMsg(ROOM, '5550000001', challenge.rid, challenge.nonce))));
  assert.equal(honest.socket.info.verifying, true);
  const flood = [];
  for (let i = 0; i < 5; i++) { w.advance(1); flood.push((await connect(w, 'viewer', ROOM, { viewer: `666000000${i}`, ip: `6.6.6.${i}` })).socket); }
  assert.equal(honest.socket.closes.length, 0, 'проверяемый сокет не вытеснен');
  assert.equal(closeCode(flood[0]), 4429, 'вытеснен самый старый из не приславших auth');
  await verifying;
  assert.equal(honest.socket.info.auth, 'key');
  assert.equal(honest.socket.info.verifying, undefined);
  assert.ok(msgOf(honest.socket, 'waiting'), 'зритель дошёл до waiting');
  assert.ok(msgsOf(host, 'request').some((m) => m.viewer === '5550000001'));
});

test('F2/F3: если все три сокета этого IP уже проходят проверку, четвёртый с того же IP получает 429, а не выбивает их', async () => {
  const w = world(), f = w.f(ROOM);
  await hostLogin(w);
  const checks = [];
  for (let i = 1; i <= 3; i++) {
    const c = await connect(w, 'viewer', ROOM, { viewer: `555000000${i}`, ip: '1.1.1.1' });
    const ch = msgOf(c.socket, 'challenge');
    const key = keypair(30 + i);
    checks.push(send(f, c.socket, authFrame(key, key.sign(viewerMsg(ROOM, `555000000${i}`, ch.rid, ch.nonce)))));
  }
  assert.equal((await connect(w, 'viewer', ROOM, { viewer: '5550000004', ip: '1.1.1.1' })).res.status, 429);
  await Promise.all(checks);
});

test('до проверки ключа: молчащие сокеты закрываются auth-timeout и освобождают место', async () => {
  const w = world(), f = w.f(ROOM);
  await hostLogin(w);
  for (let i = 1; i <= 3; i++) assert.equal((await connect(w, 'viewer', ROOM, { viewer: `555000000${i}`, ip: '1.1.1.1' })).res.status, 101);
  w.advance(10_500);
  await f.room.alarm();
  assert.equal(f.room.unauthViewers().length, 0);
  assert.ok(f.all().filter((s) => s.tag === 'viewer').every((s) => closeCode(s) === 4408));
});

test('pending: без CF-Connecting-IP лимит на IP не применяется (только общий)', async () => {
  const w = world();
  await hostLogin(w);
  assert.equal((await connect(w, 'viewer', ROOM, { viewer: '5550000001' })).res.status, 101);
  assert.equal((await connect(w, 'viewer', ROOM, { viewer: '5550000002' })).res.status, 101);
});

test('pending: подделанный x-relay-ip из клиента не обходит лимит на IP', async () => {
  const w = world();
  await hostLogin(w);
  const first = await connect(w, 'viewer', ROOM, { viewer: '5550000001', ip: '1.1.1.1', headers: { 'x-relay-ip': '8.8.8.1' } });
  for (let i = 2; i <= 4; i++) {
    w.advance(1);
    assert.equal((await connect(w, 'viewer', ROOM, { viewer: `555000000${i}`, ip: '1.1.1.1', headers: { 'x-relay-ip': `8.8.8.${i}` } })).res.status, 101);
  }
  assert.equal(first.socket.info.ip, '1.1.1.1');
  assert.equal(closeCode(first.socket), 4429, 'четыре «разных» x-relay-ip — один IP: самый старый вытеснен');
});

test('BUG-1: пока в комнате висят 3 неавторизованных сокета «хоста», настоящий хост не может подключиться (429), лимита на IP нет', async () => {
  const w = world(), f = w.f(ROOM);
  for (let i = 0; i < 3; i++) assert.equal((await connect(w, 'host', ROOM, { ip: '6.6.6.6' })).res.status, 101);
  assert.equal(f.room.pendingHosts().length, 1, 'с одного IP — один неавторизованный «хост»');
  const legit = await connect(w, 'host', ROOM, { ip: '1.2.3.4' });
  assert.equal(legit.res.status, 101, 'настоящий хост с другого IP должен подключаться');
});

test('R-A: молчащие «хосты» с разных IP не мешают владельцу ни начать трансляцию, ни вернуться в grace', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w, OWNER, ROOM, { ip: '1.2.3.4' });
  const viewer = f.socket('viewer', { id: VIEWER, approved: true, approvedBy: OWNER.pub, lastSeen: w.now });
  f.room.webSocketClose(host, 1006);
  const squat = [];
  for (const ip of ['6.6.6.6', '6.6.6.6', '7.7.7.7', '8.8.8.8', '9.9.9.1', '9.9.9.2', '9.9.9.3']) { w.advance(1); squat.push((await connect(w, 'host', ROOM, { ip })).socket); }
  assert.equal(closeCode(squat[0]), 4409, 'тот же IP: старый сокет вытеснен новым');
  assert.equal(closeCode(squat[1]), 4429, 'переполнение: вытеснен самый старый');
  assert.equal(f.room.pendingHosts().length, 5);
  w.advance(1);
  const back = await hostLogin(w, OWNER, ROOM, { ip: '1.2.3.4' });
  assert.equal(msgOf(back, 'authed').claimed, false, 'владелец вернулся в grace');
  assert.equal(viewer.messages.at(-1).type, 'resumed');
  assert.deepEqual(f.room.activeHosts(), [back]);
});

test('R-A: молчащие «хосты» на непривязанном ID не мешают новому владельцу начать трансляцию', async () => {
  const w = world(), f = w.f('1112223334');
  for (const ip of ['6.6.6.6', '7.7.7.7', '8.8.8.8']) { w.advance(1); await connect(w, 'host', '1112223334', { ip }); }
  w.advance(1);
  const owner = await hostLogin(w, OTHER, '1112223334', { ip: '1.2.3.4' });
  assert.equal(msgOf(owner, 'authed').claimed, true);
  assert.deepEqual(f.room.activeHosts(), [owner]);
});

// =====================================================================================================
// 9. Очередь request: 20 в минуту (B1)
// =====================================================================================================
test('очередь: хосту уходит 20 запросов в минуту, остальные ждут и уходят после окна; закрывшиеся из очереди не отправляются', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const viewers = [];
  for (let i = 0; i < 22; i++) {
    const s = await viewerLogin(w, keypair(40 + i), ROOM, { viewer: `50000000${String(i).padStart(2, '0')}`, ip: `9.9.9.${i}` });
    viewers.push(s);
    s.info.ended = true; // временно: чтобы не упереться в лимит ожидающих (10); на окно запросов не влияет
  }
  for (const s of viewers) delete s.info.ended;
  const sent = () => msgsOf(host, 'request').map((m) => m.viewer);
  assert.equal(sent().length, 20);
  assert.equal(viewers[20].info.reqSent, false);
  assert.equal(viewers[21].info.reqSent, false);
  assert.deepEqual(types(viewers[20]), ['challenge', 'waiting'], 'ждущий получает waiting');
  await send(f, host, { type: 'accept', viewer: '5000000020', rid: viewers[20].info.rid });
  assert.equal(viewers[20].info.approved, false, 'хост ещё не видел запрос');
  f.room.webSocketClose(viewers[21]);
  assert.equal(msgsOf(host, 'cancelled').filter((m) => m.viewer === '5000000021').length, 0);
  w.advance(61_000);
  for (const s of viewers) s.info.lastSeen = w.now;
  await f.room.alarm();
  assert.equal(sent().includes('5000000020'), true);
  assert.equal(sent().includes('5000000021'), false);
  assert.equal(viewers[20].info.reqSent, true);
});

// =====================================================================================================
// 10. decline: 60 с и 10 минут
// =====================================================================================================
test('decline (v2, по ключу): 60 с после отказа, 60 с после второго, 10 минут после третьего подряд; другой ключ не затронут', async () => {
  const w = world();
  const host = await hostLogin(w);
  const blockedAt = async () => {
    const s = await viewerLogin(w, VIEWER_KEY);
    return s.info?.auth === 'key' ? null : s;
  };
  const first = await viewerLogin(w, VIEWER_KEY);
  await decline(w, host, first);
  assert.equal(msgOf(first, 'declined').type, 'declined');
  const blocked = await blockedAt();
  assert.equal(msgOf(blocked, 'error').code, 'rate-limited');
  assert.equal(closeCode(blocked), 4429);
  assert.equal((await viewerLogin(w, OTHER, ROOM, { viewer: '5550001112' })).info.auth, 'key', 'другой ключ свободен');
  w.pass(59_000);
  assert.equal(msgOf(await blockedAt(), 'error').code, 'rate-limited', 'на 59-й секунде ещё нельзя');
  w.pass(2_000);
  const second = await viewerLogin(w, VIEWER_KEY);
  assert.equal(second.info.auth, 'key');
  await decline(w, host, second);
  w.pass(61_000);
  const third = await viewerLogin(w, VIEWER_KEY);
  assert.equal(third.info.auth, 'key', 'после второго отказа тоже 60 с');
  await decline(w, host, third);
  w.pass(61_000);
  assert.equal(msgOf(await blockedAt(), 'error').code, 'rate-limited', 'после третьего подряд — 10 минут');
  w.pass(8 * 60_000);
  assert.equal(msgOf(await blockedAt(), 'error').code, 'rate-limited', 'ещё 9 минут без секунд');
  w.pass(61_000);
  assert.equal((await viewerLogin(w, VIEWER_KEY)).info.auth, 'key', 'через 10 минут можно');
});

test('decline (legacy, по IP): HTTP 429 на 60 с и на 10 минут после третьего; другой IP не затронут', async () => {
  const w = world();
  const host = await hostLogin(w);
  const tryConnect = (ip = '8.8.8.8') => connect(w, 'viewer', ROOM, { token: V1, viewer: '7770001112', ip });
  for (let round = 1; round <= 3; round++) {
    const { res, socket } = await tryConnect();
    assert.equal(res.status, 101, `попытка ${round}`);
    await send(w.f(ROOM), host, { type: 'decline', viewer: '7770001112', rid: socket.info.rid });
    assert.equal((await tryConnect()).res.status, 429);
    assert.equal((await tryConnect('8.8.8.9')).res.status, 101, 'другой IP');
    w.f(ROOM).all().filter((s) => s.tag === 'viewer' && s.info.ip === '8.8.8.9').forEach((s) => { s.info.ended = true; });
    w.pass(61_000);
  }
  assert.equal((await tryConnect()).res.status, 429, 'после третьего — 10 минут');
  w.pass(8 * 60_000);
  assert.equal((await tryConnect()).res.status, 429);
  w.pass(61_000);
  assert.equal((await tryConnect()).res.status, 101);
});

test('decline: пауза не наследуется, если после неё прошло больше 10 минут — серия начинается заново', async () => {
  const w = world();
  const host = await hostLogin(w);
  const first = await viewerLogin(w, VIEWER_KEY);
  await decline(w, host, first);
  w.pass(11 * 60_000);
  const second = await viewerLogin(w, VIEWER_KEY);
  await decline(w, host, second);
  w.pass(61_000);
  assert.equal((await viewerLogin(w, VIEWER_KEY)).info.auth, 'key', 'второй отказ после перерыва — снова 60 с');
});

// =====================================================================================================
// 11. Legacy mu-share-1 в optional
// =====================================================================================================
test('legacy в optional: сеанс mu-share-1 хоста и зрителя идёт как раньше, ни одного v2-поля им не приходит', async () => {
  const w = world(), f = w.f(ROOM);
  const { res, socket: host } = await connect(w, 'host', ROOM, { token: V1 });
  assert.equal(res.status, 101);
  assert.equal(host.messages.length, 0, 'старому хосту ничего не шлют при подключении');
  const { socket: viewer } = await connect(w, 'viewer', ROOM, { token: V1, viewer: '2222222222', name: 'Аня', ip: '1.1.1.1' });
  assert.deepEqual(viewer.messages, [{ type: 'waiting' }]);
  const request = msgOf(host, 'request');
  assert.deepEqual(Object.keys(request).sort(), ['name', 'rid', 'type', 'viewer']);
  await send(f, host, { type: 'accept', viewer: '2222222222', name: 'Mac' });
  assert.deepEqual(viewer.messages.at(-1), { type: 'accepted', name: 'Mac' });
  await send(f, host, new ArrayBuffer(4));
  await send(f, viewer, { type: 'ping', x: 0.2, y: 0.4, color: 'red' });
  assert.deepEqual(msgsOf(host, 'viewers').at(-1), { type: 'viewers', count: 1, list: [{ id: '2222222222', name: 'Аня', h264: true }] }, 'viewers без fp и auth');
  await send(f, viewer, { type: 'game', action: 'invite' });
  assert.deepEqual(host.messages.at(-1), { type: 'game', action: 'invite', from: '2222222222', name: 'Аня' });
  f.room.webSocketClose(host, 1000);
  assert.equal(viewer.messages.at(-1).type, 'ended');
  const forbidden = ['challenge', 'authed', 'error'];
  for (const m of [...host.messages, ...viewer.messages]) {
    assert.equal(forbidden.includes(m.type), false, m.type);
    for (const field of ['v', 'fp', 'pub', 'auth', 'hostKey', 'idVerified', 'self']) assert.equal(field in m, false, `${m.type}.${field}`);
  }
});

test('legacy в optional: decline без rid отклоняет самого раннего, accept без rid — тоже (старый хост не знает rid)', async () => {
  const w = world(), f = w.f(ROOM);
  const { socket: host } = await connect(w, 'host', ROOM, { token: V1 });
  const { socket: a } = await connect(w, 'viewer', ROOM, { token: V1, viewer: '2222222222', ip: '1.1.1.1' });
  const { socket: b } = await connect(w, 'viewer', ROOM, { token: V1, viewer: '3333333333', ip: '2.2.2.2' });
  await send(f, host, { type: 'decline', viewer: '2222222222' });
  assert.equal(a.messages.at(-1).type, 'declined');
  await send(f, host, { type: 'accept', viewer: '3333333333', name: 'Mac' });
  assert.equal(b.info.approved, true);
});

test('legacy в optional: v2-зритель на старом хосте — запрос с v2-полями, но хост-legacy продолжает работать без rid', async () => {
  const w = world(), f = w.f(ROOM);
  const { socket: oldHost } = await connect(w, 'host', ROOM, { token: V1 });
  const viewer = await viewerLogin(w, VIEWER_KEY);
  const request = msgOf(oldHost, 'request');
  assert.equal(request.viewer, VIEWER);
  assert.equal(request.auth, 'key');
  await send(f, oldHost, { type: 'accept', viewer: VIEWER, name: 'Mac' });
  assert.equal(viewer.info.approved, true);
  assert.deepEqual(viewer.messages.at(-1), { type: 'accepted', name: 'Mac' }, 'без hostSig: у хоста без ключа подписи нет');
});

test('legacy в optional: mu-share-1 хост на привязанном ID — 409 id-claimed; mu-share-1 зритель к v2-хосту — как и раньше', async () => {
  const w = world(), f = w.f(ROOM);
  const owner = await hostLogin(w);
  assert.equal((await connect(w, 'host', ROOM, { token: V1 })).res.status, 409, 'на живом');
  f.room.webSocketClose(owner, 1000);
  assert.equal((await connect(w, 'host', ROOM, { token: V1 })).res.status, 409, 'и на свободном привязанном');
  const again = await hostLogin(w);
  const { socket } = await connect(w, 'viewer', ROOM, { token: V1, viewer: '2222222222', ip: '1.1.1.1' });
  assert.deepEqual(types(socket), ['waiting']);
  assert.equal(msgOf(again, 'request').auth, 'none');
});

test('клиент без заголовка или с неизвестным токеном: 403; страница без заголовка — лендинг, с заголовком — приложение', async () => {
  const w = world();
  for (const token of [null, 'mu-share-0', 'mu-share-3', '']) {
    const res = await w.worker(new Request(`https://relay.example/room/${ROOM}?role=host`, { headers: { Upgrade: 'websocket', ...(token === null ? {} : { 'x-macutils-client': token }) } }));
    assert.equal(res.status, 403, JSON.stringify(token));
  }
  assert.equal(await (await w.worker(new Request('https://relay.example/'))).text(), 'LANDING');
  assert.equal(await (await w.worker(new Request('https://relay.example/', { headers: { 'x-macutils-client': V1 } }))).text(), 'PAGE');
  assert.equal((await w.worker(new Request(`https://relay.example/room/${ROOM}?role=host`, { headers: { 'x-macutils-client': V2 } }))).status, 426, 'без Upgrade');
});

// =====================================================================================================
// 12. required / off
// =====================================================================================================
test('required: mu-share-1 → 426 для хоста, зрителя и GET /status; mu-share-2 работает; /version отдаёт только v2', async () => {
  const w = world({ AUTH_MODE: 'required' });
  for (const role of ['host', 'viewer']) {
    const res = await connect(w, role, ROOM, { token: V1 });
    assert.equal(res.res.status, 426, role);
    assert.equal(await res.res.text(), 'Update Mac Utils');
  }
  assert.equal((await connect(w, 'host', ROOM, { token: null })).res.status, 403, 'без заголовка клиента — 403, не 426');
  assert.equal((await w.worker(new Request('https://relay.example/status?ids=1234567890', { headers: { 'x-macutils-client': V1 } }))).status, 426);
  assert.equal((await hostLogin(w)).messages.at(-1).type, 'authed');
  const version = await (await w.worker(new Request('https://relay.example/version'))).json();
  assert.deepEqual([version.protocols, version.auth], [[V2], 'required']);
});

test('off: mu-share-2 хост получает только authed mode:off, зритель — только waiting; ключи, владелец и проверки игнорируются', async () => {
  const w = world({ AUTH_MODE: 'off' }), f = w.f(ROOM);
  f.store.set('owner', { v: 2, pub: OWNER.pub, fp: 'x', claimedAt: 1, lastSeenAt: w.now });
  const { res, socket: host } = await connect(w, 'host', ROOM);
  assert.equal(res.status, 101);
  assert.deepEqual(host.messages, [{ type: 'authed', v: 2, mode: 'off' }]);
  assert.equal(f.room.activeHosts().length, 1, 'хост активен без auth');
  const { socket: viewer } = await connect(w, 'viewer', ROOM, { ip: '1.1.1.1' });
  assert.deepEqual(viewer.messages, [{ type: 'waiting' }]);
  const request = msgOf(host, 'request');
  assert.deepEqual(Object.keys(request).sort(), ['name', 'rid', 'type', 'viewer']);
  const second = await connect(w, 'host', ROOM, { token: V1 });
  assert.equal(second.res.status, 409, 'один хост на комнату, как раньше');
  assert.equal(msgOf(viewer, 'challenge'), undefined);
});

test('off: стороннее подключение не получает challenge и auth-timeout; хост без ключа занимает привязанный ID', async () => {
  const w = world({ AUTH_MODE: 'off' }), f = w.f(ROOM);
  f.store.set('owner', { v: 2, pub: OWNER.pub, fp: 'x', claimedAt: 1, lastSeenAt: w.now });
  const { socket } = await connect(w, 'host', ROOM, { token: V1 });
  w.advance(11_000);
  socket.info.lastSeen = w.now;
  await f.room.alarm();
  assert.equal(socket.closes.length, 0);
  assert.equal(f.room.activeHosts().length, 1);
});

// =====================================================================================================
// 13. Внешний /room/<id>/claim и внутренние маршруты
// =====================================================================================================
test('внешний доступ к /claim и /quota невозможен: Worker отдаёт страницу, до комнат запрос не доходит', async () => {
  const w = world();
  const forwarded = [];
  const env = { ROOMS: { idFromName: (n) => n, get: (n) => ({ fetch: (r) => { forwarded.push([n, new URL(r.url).pathname]); return new Response('room'); } }) } };
  const paths = [`/room/${ROOM}/claim`, '/claim', '/quota', `/room/${ROOM}/quota`, '/room/__limits', `/room/${ROOM}/`, `/room/${ROOM}/../claim`, `/room/${ROOM}%2Fclaim`, '/room/', '/room/abc', `/ROOM/${ROOM}/claim`, '//claim'];
  for (const path of paths) {
    for (const method of ['GET', 'POST']) {
      for (const headers of [{ 'x-macutils-client': V2 }, { 'x-macutils-client': V2, Upgrade: 'websocket' }, {}]) {
        const res = await w.worker(new Request(`https://relay.example${path}`, { method, headers, ...(method === 'POST' ? { body: JSON.stringify({ pub: ATTACKER.pub }) } : {}) }), env);
        assert.ok(['PAGE', 'LANDING'].includes(await res.text()), `${method} ${path} ${JSON.stringify(headers)}`);
      }
    }
  }
  assert.deepEqual(forwarded, []);
});

test('внешний POST /claim по пути комнаты не привязывает ключ: владелец ID не появляется', async () => {
  const w = world(), f = w.f(ROOM);
  const res = await w.worker(new Request(`https://relay.example/room/${ROOM}/claim`, { method: 'POST', headers: { 'x-macutils-client': V2 }, body: JSON.stringify({ pub: ATTACKER.pub, ip: '' }) }));
  assert.equal(await res.text(), 'PAGE');
  assert.equal(f.store.get('owner'), undefined);
});

test('внутренний /claim между комнатами: первая привязка, повтор, чужой ключ, мусор; /quota без ключа отказывает', async () => {
  const w = world(), f = w.f(ROOM);
  const post = (path, body) => f.room.fetch(new Request(`https://room${path}`, { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body) }));
  assert.deepEqual(await (await post('/claim', { pub: OWNER.pub, ip: '' })).json(), { ok: true, claimed: true });
  assert.deepEqual(await (await post('/claim', { pub: OWNER.pub })).json(), { ok: true, claimed: false });
  assert.deepEqual(await (await post('/claim', { pub: ATTACKER.pub })).json(), { ok: false, claimed: false, reason: 'id-claimed' });
  for (const bad of ['not json', { pub: 5 }, { pub: 'short' }, {}]) assert.equal((await post('/claim', bad)).status, 400, JSON.stringify(bad));
  assert.deepEqual(await (await post('/quota', { key: '' })).json(), { ok: false });
});

// =====================================================================================================
// 14. POST /status
// =====================================================================================================
function statusBody(key, { id, ids = [VIEWER], ts, v = 2 } = {}) {
  const stamp = ts ?? 1_000_000;
  return { v, id, pub: key.pub, ts: stamp, ids, sig: key.sign(`mu-share/v2\nstatus\n${id}\n${stamp}\n${ids.join(',')}`) };
}
const postStatus = (w, body, { token = V2, ip, env, raw } = {}) => w.worker(new Request('https://relay.example/status', {
  method: 'POST', headers: { ...(token ? { 'x-macutils-client': token } : {}), ...(ip ? { 'CF-Connecting-IP': ip } : {}) }, body: raw ?? JSON.stringify(body),
}), env);

test('POST /status: владелец ID с верной подписью получает карту онлайн-статусов', async () => {
  const w = world();
  await hostLogin(w, OWNER, ROOM);
  await hostLogin(w, VIEWER_KEY, '1000000001');
  await hostLogin(w, ATTACKER, VIEWER);
  const res = await postStatus(w, statusBody(VIEWER_KEY, { id: '1000000001', ids: [ROOM, '1000000001', VIEWER, '2000000000'] }));
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { [ROOM]: true, '1000000001': true, [VIEWER]: true, '2000000000': false });
});

test('POST /status: подпись обязана покрывать id, ts и список ids — любая подмена → 401', async () => {
  const w = world();
  await hostLogin(w, OWNER, ROOM);
  const good = statusBody(OWNER, { id: ROOM, ids: [VIEWER] });
  assert.equal((await postStatus(w, good)).status, 200);
  const cases = {
    'ids подменены': { ...good, ids: ['1111111111'] },
    'ids добавлены': { ...good, ids: [VIEWER, '1111111111'] },
    'порядок ids': { ...statusBody(OWNER, { id: ROOM, ids: [VIEWER, '1111111111'] }), ids: ['1111111111', VIEWER] },
    'ts сдвинут': { ...good, ts: good.ts + 1 },
    'подпись чужим ключом': { ...good, sig: ATTACKER.sign(`mu-share/v2\nstatus\n${ROOM}\n${good.ts}\n${VIEWER}`) },
    'подпись без домена': { ...good, sig: OWNER.sign(`status\n${ROOM}\n${good.ts}\n${VIEWER}`) },
    'подпись от host-контекста': { ...good, sig: OWNER.sign(hostMsg(ROOM, 'x')) },
    'мусор в sig': { ...good, sig: 'AAAA' },
  };
  for (const [why, body] of Object.entries(cases)) {
    const w2 = world();
    await hostLogin(w2, OWNER, ROOM);
    const res = await postStatus(w2, body);
    assert.ok([400, 401].includes(res.status), `${why}: ${res.status}`);
    assert.notEqual(res.status, 200, why);
  }
});

test('POST /status: свежесть ts — ±120 с принимается, дальше 400; запрос без ts-числа и с чужим v отвергается', async () => {
  const w = world();
  await hostLogin(w, OWNER, ROOM);
  const at = (delta) => postStatus(w, statusBody(OWNER, { id: ROOM, ts: w.now + delta }));
  assert.equal((await at(-120_000)).status, 200);
  w.advance(1);
  assert.equal((await at(120_000)).status, 200);
  assert.equal((await at(-121_001)).status, 400, 'протух');
  assert.equal((await at(121_001)).status, 400, 'из будущего');
  const bodies = [
    { ...statusBody(OWNER, { id: ROOM }), ts: '1000000' },
    { ...statusBody(OWNER, { id: ROOM }), ts: 1e30 },
    { ...statusBody(OWNER, { id: ROOM }), ts: null },
    statusBody(OWNER, { id: ROOM, v: 1 }),
    statusBody(OWNER, { id: ROOM, v: 3 }),
  ];
  for (const body of bodies) assert.equal((await postStatus(w, body)).status, 400, JSON.stringify(body).slice(0, 80));
});

test('POST /status: чужой публичный ключ (не владелец ID) → 403; свободный ID не привязывается (только чтение)', async () => {
  const w = world();
  await hostLogin(w, OWNER, ROOM);
  const stolen = await postStatus(w, statusBody(ATTACKER, { id: ROOM, ids: [] }));
  assert.equal(stolen.status, 403);
  assert.equal((await stolen.json()).error, 'id-claimed');
  assert.equal(w.f(ROOM).store.get('owner').pub, OWNER.pub);
  // /status не привязывает свободный ID: занять чужой ID можно только подключением (там квота и остальные проверки).
  const fresh = await postStatus(w, statusBody(ATTACKER, { id: '3000000000', ids: [] }));
  assert.equal(fresh.status, 403);
  assert.equal((await fresh.json()).error, 'not-owner');
  assert.equal(w.f('3000000000').store.get('owner'), undefined);
  assert.equal(w.f('__limits').store.size, 0, 'квота привязок не тронута');
});

test('POST /status: форматы тела — 6-значные и лишние ID, > 20, не-JSON, пустое тело, > 4096 байт, не-массив ids', async () => {
  const w = world();
  await hostLogin(w, OWNER, ROOM);
  const ok = (extra) => ({ ...statusBody(OWNER, { id: ROOM, ids: [VIEWER] }), ...extra });
  const twentyOne = Array.from({ length: 21 }, (_, i) => `30000000${String(i).padStart(2, '0')}`);
  const cases = [
    ['6-значный в ids', statusBody(OWNER, { id: ROOM, ids: ['123456'] }), 400],
    ['21 ID', statusBody(OWNER, { id: ROOM, ids: twentyOne }), 400],
    ['свой ID 6 цифр', statusBody(OWNER, { id: '123456', ids: [] }), 400],
    ['ids не массив', ok({ ids: VIEWER }), 400],
    ['ids с числом', ok({ ids: [1234567890] }), 400],
    ['pub короткий', ok({ pub: 'abc' }), 400],
  ];
  for (const [why, body, status] of cases) assert.equal((await postStatus(w, body)).status, status, why);
  assert.equal((await postStatus(w, null, { raw: 'not json' })).status, 400);
  assert.equal((await postStatus(w, null, { raw: '' })).status, 400);
  assert.equal((await postStatus(w, null, { raw: 'null' })).status, 400);
  assert.equal((await postStatus(w, null, { raw: ' '.repeat(5000) })).status, 413);
});

test('POST /status: без заголовка клиента 403, в режиме off 404, в required v2 работает; GET /status остаётся для 10-значных ID', async () => {
  const w = world();
  await hostLogin(w, OWNER, ROOM);
  const body = statusBody(OWNER, { id: ROOM });
  assert.equal((await postStatus(w, body, { token: null })).status, 403);
  assert.equal((await postStatus(w, body, { env: { ...w.env, AUTH_MODE: 'off' } })).status, 404);
  assert.equal((await postStatus(w, body, { env: { ...w.env, AUTH_MODE: 'required' } })).status, 200);
  const get = await w.worker(new Request(`https://relay.example/status?ids=${ROOM},123456`, { headers: { 'x-macutils-client': V2 } }));
  assert.deepEqual(await get.json(), { [ROOM]: true });
});

test('POST /status: лимит по ключу — 6 в минуту, потом 429; после минуты снова можно; по IP — RL_STATUS', async () => {
  const w = world({ RL_STATUS: { limit: async ({ key }) => ({ success: key !== '6.6.6.6' }) } });
  await hostLogin(w, OWNER, ROOM);
  const codes = [];
  for (let i = 0; i < 8; i++) codes.push((await postStatus(w, statusBody(OWNER, { id: ROOM, ids: [], ts: w.now }))).status);
  assert.deepEqual(codes, [200, 200, 200, 200, 200, 200, 429, 429]);
  w.advance(61_000);
  assert.equal((await postStatus(w, statusBody(OWNER, { id: ROOM, ids: [], ts: w.now }))).status, 200);
  assert.equal((await postStatus(w, statusBody(VIEWER_KEY, { id: '1000000009', ids: [], ts: w.now }), { ip: '6.6.6.6' })).status, 429, 'RL_STATUS по IP');
});

test('POST /status: тот же подписанный запрос в окне свежести идемпотентен (повтор даёт тот же ответ)', async () => {
  const w = world();
  await hostLogin(w, OWNER, ROOM);
  const body = statusBody(OWNER, { id: ROOM, ids: [ROOM] });
  const a = await (await postStatus(w, body)).json();
  const b = await (await postStatus(w, body)).json();
  assert.deepEqual(a, b);
});

test('BUG-2 / R-E: поддельные POST /status с публичным ключом жертвы не расходуют её лимит 6/мин — окно считается после подписи', async () => {
  const w = world();
  await hostLogin(w, OWNER, ROOM);
  const forged = { ...statusBody(OWNER, { id: ROOM, ids: [] }), sig: ATTACKER.sign('x') };
  for (let i = 0; i < 6; i++) assert.equal((await postStatus(w, forged)).status, 401);
  const legit = await postStatus(w, statusBody(OWNER, { id: ROOM, ids: [] }));
  assert.equal(legit.status, 200, 'подделки с неверной подписью не должны съедать лимит владельца');
});

// =====================================================================================================
// 15. Сквозные сценарии
// =====================================================================================================
test('e2e: полный сеанс v2 — хост, зритель, accept с hostSig, кадры, метки, stop; зритель видит hostKey и подпись хоста', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const { socket: viewer } = await connect(w, 'viewer', ROOM, { ip: '1.1.1.1' });
  const ch = msgOf(viewer, 'challenge');
  assert.equal(ch.hostKey, OWNER.pub);
  assert.equal(ch.hostFp, msgOf(host, 'authed').fp);
  await send(f, viewer, authFrame(VIEWER_KEY, VIEWER_KEY.sign(viewerMsg(ROOM, VIEWER, ch.rid, ch.nonce))));
  const request = msgOf(host, 'request');
  assert.equal(request.pub, VIEWER_KEY.pub);
  const hostSig = OWNER.sign(`mu-share/v2\naccept\n${ROOM}\n${request.pub}\n${request.rid}`);
  await send(f, host, { type: 'accept', viewer: request.viewer, rid: request.rid, name: 'Mac', hostSig });
  assert.deepEqual(viewer.messages.at(-1), { type: 'accepted', name: 'Mac', hostSig });
  await send(f, host, new ArrayBuffer(16));
  await send(f, viewer, { type: 'ping', x: 0.3, y: 0.3 });
  assert.equal(host.messages.at(-1).type, 'ping');
  assert.equal(msgsOf(host, 'viewers').at(-1).list[0].fp, viewer.info.fp);
  f.room.webSocketClose(host, 1000);
  assert.equal(viewer.messages.at(-1).type, 'ended');
});

test('e2e: «Сменить ID» — release освобождает ID, прежние зрители завершаются, новый ключ занимает его', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const viewer = await viewerLogin(w);
  await accept(w, host, viewer);
  await send(f, host, { type: 'release' });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.store.get('owner'), undefined);
  assert.equal(viewer.messages.at(-1).type, 'ended');
  const next = await hostLogin(w, ATTACKER);
  assert.equal(msgOf(next, 'authed').claimed, true);
});

// =====================================================================================================
// 16. Исправления по security-ревью (.audit/review-auth-b.md): R-C, R-D, R-F, M3, M4, порядок cooldown, N5
// =====================================================================================================
test('R-F (M2): grace на непривязанном ID — чужой ключ занимает комнату, но пущенные legacy-хостом зрители завершаются, а не resumed', async () => {
  const w = world(), f = w.f(ROOM);
  const legacyHost = (await connect(w, 'host', ROOM, { token: V1, ip: '1.1.1.1' })).socket;
  const v = (await connect(w, 'viewer', ROOM, { token: V1, viewer: VIEWER, ip: '2.2.2.2' })).socket;
  await send(f, legacyHost, { type: 'accept', viewer: VIEWER });
  assert.equal(v.info.approved, true);
  assert.equal(v.info.approvedBy, 'none', 'пустил хост без ключа');
  f.room.webSocketClose(legacyHost, 1006);
  assert.equal(v.messages.at(-1).type, 'reconnecting');
  w.advance(5_000);
  const thief = await hostLogin(w, ATTACKER, ROOM, { ip: '6.6.6.6' });
  assert.equal(msgOf(thief, 'authed').claimed, true, 'непривязанный ID занят (остаточный риск §5.4)');
  assert.equal(v.messages.at(-1).type, 'ended', 'зритель не смотрит чужой экран');
  assert.equal(msgsOf(v, 'resumed').length, 0);
  v.messages.length = 0;
  await f.room.webSocketMessage(thief, new Uint8Array([1, 2, 3]));
  assert.equal(v.messages.length, 0, 'кадры захватчика зрителю не идут');
});

test('M2: зрители, пущенные ключом владельца, переживают grace и смену окна того же владельца; пущенные другим ключом — нет', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const mine = await viewerLogin(w, VIEWER_KEY, ROOM, { ip: '2.2.2.2' });
  await accept(w, host, mine);
  assert.equal(mine.info.approvedBy, OWNER.pub);
  const stale = f.socket('viewer', { id: '5550000077', approved: true, approvedBy: ATTACKER.pub, lastSeen: w.now });
  f.room.webSocketClose(host, 1006);
  const back = await hostLogin(w, OWNER, ROOM, { ip: '1.1.1.1' });
  assert.equal(mine.messages.at(-1).type, 'resumed');
  assert.equal(stale.messages.at(-1).type, 'ended');
  await hostLogin(w, OWNER, ROOM, { ip: '1.1.1.2' });
  assert.equal(closeCode(back), 4409);
  assert.equal(mine.info.ended, undefined, 'смена окна того же владельца не рвёт зрителя');
});

test('R-C: v2-ключ прерывает живую legacy-трансляцию непривязанного ID (отступление 1, §5.4) — её зрители получают ended', async () => {
  const w = world(), f = w.f(ROOM);
  const legacyHost = (await connect(w, 'host', ROOM, { token: V1, ip: '1.1.1.1' })).socket;
  const v = (await connect(w, 'viewer', ROOM, { token: V1, viewer: VIEWER, ip: '2.2.2.2' })).socket;
  await send(f, legacyHost, { type: 'accept', viewer: VIEWER });
  const thief = await hostLogin(w, ATTACKER, ROOM, { ip: '6.6.6.6' });
  assert.equal(closeCode(legacyHost), 4409);
  assert.equal(v.messages.at(-1).type, 'ended');
  assert.deepEqual(f.room.activeHosts(), [thief]);
});

test('R-D (M3, F1): квота привязок зрителя 20 в сутки на IP переживает выгрузку __limits; 21-й — idVerified:false, но waiting; через сутки снова можно', async () => {
  const w = world();
  let host = await hostLogin(w);
  // Отвечаем сразу (decline: одобренных может быть только 10), иначе с одного IP упрёмся в лимит ожидающих (4).
  // Квоту привязок это не трогает: ID зрителя закрепляется при auth, до ответа ведущего.
  const claim = async (i, ip = '9.9.9.9') => {
    w.pass(6_000); w.f(ROOM).room.roomDeclines = { streak: 0, until: 0 }; // антиспам запросов (L2) этот тест не проверяет
    const s = await viewerLogin(w, keypair(100 + i), ROOM, { viewer: `41000000${String(i).padStart(2, '0')}`, ip });
    await decline(w, host, s);
    return s;
  };
  for (let i = 0; i < 10; i++) assert.equal((await claim(i)).info.idVerified, true, `привязка ${i + 1}`);
  w.f('__limits').reload();
  for (let i = 10; i < 20; i++) assert.equal((await claim(i)).info.idVerified, true, `привязка ${i + 1} после выгрузки`);
  const over = await viewerLogin(w, keypair(120), ROOM, { viewer: '4100000020', ip: '9.9.9.9' });
  assert.equal(over.info.idVerified, false, '21-я в сутки — отказ');
  assert.ok(msgOf(over, 'waiting'), 'но зритель в waiting');
  assert.equal(over.info.auth, 'key');
  assert.equal(over.info.ended, undefined, 'отказ в привязке не обрывает подключение');
  // 21-й запрос за минуту ждёт в очереди (REQUESTS_PER_MIN = 20) и уходит ведущему по будильнику с idVerified:false.
  w.pass(61_000);
  await w.f(ROOM).room.alarm();
  assert.ok(msgsOf(host, 'request').some((m) => m.viewer === '4100000020' && m.idVerified === false));
  assert.equal(w.f('4100000020').store.get('owner'), undefined);
  w.pass(86_400_000);
  host = await hostLogin(w);
  assert.equal((await viewerLogin(w, keypair(121), ROOM, { viewer: '4100000021', ip: '9.9.9.9' })).info.idVerified, true, 'новые сутки');
});

test('F1: 6 хостов с одного IP впервые начинают трансляцию — все authed (привязка хоста квоту не тратит)', async () => {
  const w = world();
  const outcomes = [];
  for (let i = 0; i < 6; i++) {
    const id = `30000000${String(i).padStart(2, '0')}`;
    const host = await hostLogin(w, keypair(140 + i), id, { ip: '7.7.7.7' });
    outcomes.push(msgOf(host, 'authed')?.claimed);
  }
  assert.deepEqual(outcomes, [true, true, true, true, true, true]);
  assert.equal(w.f('__limits').store.size, 0, 'счётчик привязок хостами не трогается');
});

test('M3: сбой счётчика квоты — привязка зрителя отклоняется (fail-closed), хоста квоту не спрашивает', async () => {
  const w = world();
  const rooms = w.env.ROOMS;
  w.env.ROOMS = { idFromName: rooms.idFromName, get: (name) => name === '__limits' ? { fetch: async () => { throw new Error('down'); } } : rooms.get(name) };
  const host = await hostLogin(w, OWNER, ROOM, { ip: '1.1.1.1' });
  assert.equal(msgOf(host, 'authed').claimed, true, 'хост закрепляет ID и при недоступном счётчике');
  const v = await viewerLogin(w, VIEWER_KEY, ROOM, { ip: '2.2.2.2' });
  assert.equal(v.info.idVerified, false, 'зритель — нет');
  assert.equal(w.f(VIEWER).store.get('owner'), undefined);
});

test('M3: просроченные счётчики квоты стираются из storage', async () => {
  const w = world();
  await hostLogin(w);
  await viewerLogin(w, VIEWER_KEY, ROOM, { ip: '9.9.9.9' });
  const limits = w.f('__limits');
  assert.ok(limits.store.has('q:9.9.9.9'));
  w.pass(86_400_000 + 3_600_000);
  await hostLogin(w);
  await viewerLogin(w, keypair(70), ROOM, { viewer: '4200000000', ip: '8.8.8.8' });
  assert.equal(limits.store.has('q:9.9.9.9'), false);
  assert.ok(limits.store.has('q:8.8.8.8'));
});

test('M4: адреса IPv6 из одного /64 — один ключ для pending, квоты и x-relay-ip', async () => {
  const w = world(), f = w.f(ROOM);
  await hostLogin(w);
  const first = await connect(w, 'viewer', ROOM, { viewer: '5550000001', ip: '2001:db8:1:2::1' });
  assert.equal(first.res.status, 101);
  assert.equal(first.socket.info.ip, '2001:db8:1:2::/64', 'в комнату уходит нормализованный ключ');
  for (let i = 2; i <= 4; i++) { w.advance(1); await connect(w, 'viewer', ROOM, { viewer: `555000000${i}`, ip: `2001:db8:1:2:ffff:${i}:2:3` }); }
  assert.equal(closeCode(first.socket), 4429, 'четвёртый адрес того же /64 вытеснил самый старый');
  assert.equal((await connect(w, 'viewer', ROOM, { viewer: '5550000009', ip: '2001:db8:1:3::1' })).res.status, 101, 'другой /64');
  // Квота привязок: ротация адресов внутри /64 не даёт новых привязок.
  const g = world();
  const gHost = await hostLogin(g, OWNER, ROOM);
  for (let i = 0; i < 21; i++) {
    g.pass(6_000); g.f(ROOM).room.roomDeclines = { streak: 0, until: 0 }; // антиспам запросов (L2) этот тест не проверяет
    const s = await viewerLogin(g, keypair(160 + i), ROOM, { viewer: `43000000${String(i).padStart(2, '0')}`, ip: `2001:db8:aa:bb:${i.toString(16)}::${i + 1}` });
    assert.equal(s.info.idVerified, i < 20, `привязка ${i + 1}`);
    if (i < 20) await decline(g, gHost, s);
  }
});

test('cooldown до привязки: отклонённый ключ не закрепляет новый ID и не тратит квоту', async () => {
  const w = world();
  const host = await hostLogin(w);
  const first = await viewerLogin(w, VIEWER_KEY, ROOM, { ip: '2.2.2.2' });
  await decline(w, host, first);
  const quotaBefore = w.f('__limits').store.get('q:2.2.2.3');
  const again = await viewerLogin(w, VIEWER_KEY, ROOM, { viewer: '4400000000', ip: '2.2.2.3' });
  assert.equal(msgOf(again, 'error').code, 'rate-limited');
  assert.equal(w.f('4400000000').store.get('owner'), undefined, 'новый ID не привязан');
  assert.equal(w.f('__limits').store.get('q:2.2.2.3'), quotaBefore, 'квота не тронута');
});

test('N5: в required POST /status с mu-share-1 → 426', async () => {
  const w = world({ AUTH_MODE: 'required' });
  await hostLogin(w);
  assert.equal((await postStatus(w, statusBody(OWNER, { id: ROOM, ids: [] }), { token: V1 })).status, 426);
  assert.equal((await postStatus(w, statusBody(OWNER, { id: ROOM, ids: [] }))).status, 200);
});

// ---- GET /room/<ID>/host-check: причина отказа ведущему без WebSocket (страница relay) ----
const hostCheck = (w, id, { token = V1, ip, env, method = 'GET' } = {}) => w.worker(new Request(`https://relay.example/room/${id}/host-check`, {
  method, headers: { ...(token ? { 'x-macutils-client': token } : {}), ...(ip ? { 'CF-Connecting-IP': ip } : {}) },
}), env);

test('host-check: свободный ID — ok', async () => {
  const w = world();
  const res = await hostCheck(w, ROOM);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true });
});

test('host-check: ID привязан к ключу — id-claimed для клиента без ключа, ok для mu-share-2', async () => {
  const w = world();
  const host = await hostLogin(w);
  w.f(ROOM).room.webSocketClose(host, 1000);
  assert.deepEqual(await (await hostCheck(w, ROOM)).json(), { error: 'id-claimed' });
  assert.deepEqual(await (await hostCheck(w, ROOM, { token: V2 })).json(), { ok: true });
});

test('host-check: идёт трансляция без ключа — busy; AUTH_MODE=off не знает владельцев', async () => {
  const w = world();
  const { res } = await connect(w, 'host', ROOM, { token: V1 });
  assert.equal(res.status, 101);
  assert.deepEqual(await (await hostCheck(w, ROOM)).json(), { error: 'busy' });
  const owned = world();
  const host = await hostLogin(owned);
  owned.f(ROOM).room.webSocketClose(host, 1000);
  owned.env.AUTH_MODE = 'off';
  assert.deepEqual(await (await hostCheck(owned, ROOM)).json(), { ok: true });
});

test('host-check: без заголовка клиента 403, не GET 405, старый клиент при required 426, лимит подключений 429', async () => {
  const w = world();
  assert.equal((await hostCheck(w, ROOM, { token: null })).status, 403);
  assert.equal((await hostCheck(w, ROOM, { method: 'POST' })).status, 405);
  assert.equal((await hostCheck(w, ROOM, { env: { ...w.env, AUTH_MODE: 'required' } })).status, 426);
  const limitedEnv = { ...w.env, RL_CONNECT: { limit: async ({ key }) => ({ success: key !== '6.6.6.6' }) } };
  assert.equal((await hostCheck(w, ROOM, { ip: '6.6.6.6', env: limitedEnv })).status, 429);
  assert.equal((await hostCheck(w, ROOM, { ip: '7.7.7.7', env: limitedEnv })).status, 200);
});

// =====================================================================================================
// Ключ страницы relay (P-256, alg "es256"): браузер и клиент для Windows без своего ключа (заголовок mu-share-1 + auth=v2)
// =====================================================================================================
// Ключ как у WebCrypto: несжатая точка 65 байт (04‖x‖y), подпись r‖s 64 байта (ieee-p1363), SHA-256.
function p256() {
  const { privateKey, publicKey } = nodeCrypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const jwk = publicKey.export({ format: 'jwk' });
  const raw = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]);
  return { pub: b64u(raw), alg: 'es256',
    sign: (message) => b64u(nodeCrypto.sign('sha256', Buffer.from(message), { key: privateKey, dsaEncoding: 'ieee-p1363' })) };
}
const esFrame = (key, sig) => JSON.stringify({ type: 'auth', v: 2, alg: 'es256', pub: key.pub, sig });
const PAGE = { token: V1, query: '&auth=v2' };
async function pageViewer(w, key, id = ROOM, opts = {}) {
  const viewerId = opts.viewer ?? VIEWER;
  const { res, socket } = await connect(w, 'viewer', id, { ...PAGE, ...opts });
  assert.equal(res.status, 101);
  const ch = msgOf(socket, 'challenge');
  assert.ok(ch, 'mu-share-1 + auth=v2 — relay спрашивает ключ');
  await send(w.f(id), socket, esFrame(key, key.sign(viewerMsg(id, viewerId, ch.rid, ch.nonce))));
  return socket;
}

test('es256: зритель со страницы (mu-share-1 + auth=v2) проходит проверку, хост видит ключ и idVerified, второй раз — тот же ключ', async () => {
  const w = world();
  const host = await hostLogin(w);
  const page = p256();
  const first = await pageViewer(w, page);
  assert.equal(msgOf(first, 'waiting')?.v, 2);
  const r1 = msgOf(host, 'request');
  assert.equal(r1.auth, 'key');
  assert.equal(r1.pub, page.pub);
  assert.equal(r1.pub.length, 87);
  assert.equal(r1.idVerified, true, 'ID зрителя закреплён за ключом страницы');
  assert.match(r1.fp, /^[0-9a-f]{4}(-[0-9a-f]{4}){3}$/);
  assert.equal(w.f(VIEWER).store.get('owner').pub, page.pub);
  await accept(w, host, first);
  assert.ok(msgOf(first, 'accepted'));
  // Переподключение того же устройства: ключ тот же, ID по-прежнему его — хост с «Всегда» пустит без вопроса.
  await pageViewer(w, page);
  const r2 = msgsOf(host, 'request').at(-1);
  assert.equal(r2.pub, page.pub);
  assert.equal(r2.idVerified, true);
  assert.equal(r2.fp, r1.fp);
  assert.notEqual(r2.rid, r1.rid);
});

test('es256: другое устройство с тем же ID — idVerified:false; подделки ключа и подписи отвергаются', async () => {
  const w = world(), f = w.f(ROOM);
  const host = await hostLogin(w);
  const page = p256(), other = p256();
  await pageViewer(w, page);
  await pageViewer(w, other);
  assert.equal(msgsOf(host, 'request').at(-1).idVerified, false, 'ID уже за первым ключом');

  const attempt = async (frame) => {
    const { socket } = await connect(w, 'viewer', ROOM, PAGE);
    const ch = msgOf(socket, 'challenge');
    await send(f, socket, frame(ch));
    return socket;
  };
  const message = (ch) => viewerMsg(ROOM, VIEWER, ch.rid, ch.nonce);
  // Подпись чужим ключом, не та строка, точка не на кривой, DER вместо r‖s, ключ не того размера для алгоритма.
  const offCurve = (() => { const raw = Buffer.from(page.pub, 'base64url'); raw[64] ^= 1; return b64u(raw); })();
  const der = (ch) => b64u(nodeCrypto.sign('sha256', Buffer.from(message(ch)), nodeCrypto.createPrivateKey(
    nodeCrypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey.export({ format: 'pem', type: 'pkcs8' }))));
  const bad = [
    (ch) => esFrame(page, other.sign(message(ch))),
    (ch) => esFrame(page, page.sign(message(ch) + 'x')),
    (ch) => JSON.stringify({ type: 'auth', v: 2, alg: 'es256', pub: offCurve, sig: page.sign(message(ch)) }),
    (ch) => JSON.stringify({ type: 'auth', v: 2, alg: 'es256', pub: page.pub, sig: der(ch) }),
    (ch) => JSON.stringify({ type: 'auth', v: 2, alg: 'ed25519', pub: page.pub, sig: page.sign(message(ch)) }),
    (ch) => JSON.stringify({ type: 'auth', v: 2, alg: 'es256', pub: VIEWER_KEY.pub, sig: VIEWER_KEY.sign(message(ch)) }),
    (ch) => JSON.stringify({ type: 'auth', v: 2, alg: 'rsa', pub: page.pub, sig: page.sign(message(ch)) }),
  ];
  const before = msgsOf(host, 'request').length;
  for (const frame of bad) {
    const socket = await attempt(frame);
    assert.equal(msgOf(socket, 'error')?.code, 'bad-signature');
    assert.equal(closeCode(socket), 4401);
  }
  assert.equal(msgsOf(host, 'request').length, before, 'ни одна подделка до хоста не дошла');
});

test('es256: без auth=v2 зритель mu-share-1 идёт по-старому (без challenge), Ed25519-зрители не изменились', async () => {
  const w = world();
  const host = await hostLogin(w);
  const { socket } = await connect(w, 'viewer', ROOM, { token: V1 });
  assert.equal(msgOf(socket, 'challenge'), undefined);
  assert.equal(msgOf(host, 'request').auth, 'none');
  for (const query of ['&auth=1', '&auth=V2', '&auth=']) {
    const { socket: s } = await connect(w, 'viewer', ROOM, { token: V1, query });
    assert.equal(msgOf(s, 'challenge'), undefined, query);
  }
  await viewerLogin(w, VIEWER_KEY, ROOM, { viewer: '5550001112' });
  assert.equal(msgsOf(host, 'request').at(-1).auth, 'key');
  assert.equal(msgsOf(host, 'request').at(-1).idVerified, true);
});

test('es256: ведущий со страницы занимает ID ключом; потом mu-share-1 без ключа — id-claimed, с ключом — снова можно', async () => {
  const w = world();
  const page = p256();
  const { res, socket: host } = await connect(w, 'host', ROOM, PAGE);
  assert.equal(res.status, 101);
  const ch = msgOf(host, 'challenge');
  await send(w.f(ROOM), host, esFrame(page, page.sign(hostMsg(ROOM, ch.nonce))));
  const authed = msgOf(host, 'authed');
  assert.equal(authed.claimed, true);
  assert.equal(w.f(ROOM).store.get('owner').pub, page.pub);
  // Mac-зритель видит ключ ведущего P-256 в challenge (закрепляет и сравнивает его).
  const { socket: macViewer } = await connect(w, 'viewer', ROOM, { viewer: '5550001112' });
  assert.equal(msgOf(macViewer, 'challenge').hostKey, page.pub);
  assert.equal(msgOf(macViewer, 'challenge').hostFp, authed.fp);
  await send(w.f(ROOM), host, { type: 'stop' });
  host.readyState = 3;
  for (const s of w.f(ROOM).all()) if (s.tag === 'host') s.info = { ...s.info, ended: true };

  // Без ключа (старая страница, ключ потерян) этот ID больше не занять — так же, как у Mac.
  const plain = await connect(w, 'host', ROOM, { token: V1 });
  assert.equal(plain.res.status, 409);
  assert.equal(await plain.res.text(), 'id-claimed', 'не «занято окном», а ID за ключом');
  const check = await w.worker(new Request(`https://relay.example/room/${ROOM}/host-check`, { headers: { 'x-macutils-client': V1 } }));
  assert.equal((await check.json()).error, 'id-claimed');
  const keyedCheck = await w.worker(new Request(`https://relay.example/room/${ROOM}/host-check?auth=v2`, { headers: { 'x-macutils-client': V1 } }));
  assert.equal((await keyedCheck.json()).ok, true, 'с ключом страница может занять свой ID');
  const again = await connect(w, 'host', ROOM, PAGE);
  const ch2 = msgOf(again.socket, 'challenge');
  await send(w.f(ROOM), again.socket, esFrame(page, page.sign(hostMsg(ROOM, ch2.nonce))));
  assert.equal(msgOf(again.socket, 'authed').claimed, false);
});

test('es256: AUTH_MODE=off — auth=v2 игнорируется; required — mu-share-1 пускается только с auth=v2', async () => {
  const off = world({ AUTH_MODE: 'off' });
  await connect(off, 'host', ROOM, { token: V1 });
  const { socket } = await connect(off, 'viewer', ROOM, PAGE);
  assert.equal(msgOf(socket, 'challenge'), undefined);
  assert.deepEqual(types(socket), ['waiting']);

  const required = world({ AUTH_MODE: 'required' });
  await hostLogin(required);
  assert.equal((await connect(required, 'viewer', ROOM, { token: V1 })).res.status, 426);
  const page = p256();
  const viewer = await pageViewer(required, page);
  assert.equal(msgOf(viewer, 'waiting')?.v, 2);
});

test('es256: /claim и отпечаток принимают ключ P-256, мусор — нет', async () => {
  const w = world();
  const page = p256();
  const claim = (pub) => w.f('5550001112').room.fetch(new Request('https://room/claim', { method: 'POST', body: JSON.stringify({ pub, ip: '203.0.113.9' }) }));
  assert.equal((await (await claim(page.pub)).json()).ok, true);
  for (const bad of [page.pub.slice(1), 'C' + page.pub.slice(1), page.pub + 'A', '']) {
    assert.equal((await claim(bad)).status, 400, bad);
  }
});
