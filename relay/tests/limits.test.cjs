const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(`${__dirname}/../src/limits.js`, 'utf8')
  .replace(/^import .*;$/gm, '')
  .replace(/^export /gm, '');
assert.doesNotMatch(fs.readFileSync(`${__dirname}/../src/limits.js`, 'utf8'), /^import /m, 'limits.js не должен ничего импортировать');
const names = ['windowHit', 'pendingAllowed', 'declineCooldown', 'noteDecline', 'ipKey',
  'MAX_PENDING', 'MAX_PENDING_PER_IP', 'MAX_UNAUTH', 'MAX_UNAUTH_PER_IP', 'AUTH_TIMEOUT_MS', 'DECLINE_BASE_MS', 'DECLINE_LONG_MS', 'CLAIM_PER_IP_PER_DAY'];
const L = vm.runInNewContext(`${source}\n({ ${names.join(', ')} })`);

test('константы по контракту', () => {
  assert.equal(L.MAX_PENDING, 10);
  assert.equal(L.MAX_PENDING_PER_IP, 4);
  assert.equal(L.MAX_UNAUTH, 5);
  assert.equal(L.MAX_UNAUTH_PER_IP, 1);
  assert.equal(L.AUTH_TIMEOUT_MS, 10_000);
  assert.equal(L.DECLINE_BASE_MS, 60_000);
  assert.equal(L.DECLINE_LONG_MS, 600_000);
  assert.equal(L.CLAIM_PER_IP_PER_DAY, 5);
});

test('windowHit: лимит в окне, сброс после окна, ключи независимы', () => {
  const map = new Map();
  for (let i = 0; i < 5; i++) assert.equal(L.windowHit(map, 'a', 5, 60_000, 1000 + i), true);
  assert.equal(L.windowHit(map, 'a', 5, 60_000, 2000), false);
  assert.equal(L.windowHit(map, 'a', 5, 60_000, 2001), false, 'отказ не продлевает окно');
  assert.equal(L.windowHit(map, 'b', 5, 60_000, 2000), true);
  assert.equal(L.windowHit(map, 'a', 5, 60_000, 1000 + 60_000), true, 'новое окно');
});

test('windowHit: суточный счётчик claim', () => {
  const map = new Map();
  const day = 86_400_000;
  for (let i = 0; i < L.CLAIM_PER_IP_PER_DAY; i++) assert.equal(L.windowHit(map, '1.2.3.4', L.CLAIM_PER_IP_PER_DAY, day, i), true);
  assert.equal(L.windowHit(map, '1.2.3.4', L.CLAIM_PER_IP_PER_DAY, day, 1000), false);
  assert.equal(L.windowHit(map, '1.2.3.4', L.CLAIM_PER_IP_PER_DAY, day, day + 1), true);
});

test('windowHit: нулевой лимит всегда отказывает, часы назад не ломают', () => {
  const map = new Map();
  assert.equal(L.windowHit(map, 'a', 0, 1000, 5), false);
  assert.equal(L.windowHit(map, 'b', 1, 1000, 5000), true);
  assert.equal(L.windowHit(map, 'b', 1, 1000, 100), true, 'now раньше начала окна — новое окно');
});

test('windowHit: устаревшие записи вычищаются', () => {
  const map = new Map();
  for (let i = 0; i < 1100; i++) L.windowHit(map, `k${i}`, 1, 1000, 0);
  L.windowHit(map, 'fresh', 1, 1000, 5000);
  assert.ok(map.size < 10, `размер ${map.size}`);
});

const pending = (ip, extra = {}) => ({ approved: false, ip, ...extra });

test('pendingAllowed: общий лимит и лимит на IP', () => {
  assert.equal(L.pendingAllowed([], '1.1.1.1', 3, 1), true);
  assert.equal(L.pendingAllowed([pending('1.1.1.1')], '1.1.1.1', 3, 1), false);
  assert.equal(L.pendingAllowed([pending('1.1.1.1')], '2.2.2.2', 3, 1), true);
  const three = [pending('a'), pending('b'), pending('c')];
  assert.equal(L.pendingAllowed(three, 'd', 3, 1), false);
});

test('pendingAllowed: одобренные, завершённые и закрытые не считаются', () => {
  const list = [{ approved: true, ip: 'x' }, pending('x', { ended: true }), { id: '1', ip: 'x' },
    { readyState: 3, deserializeAttachment: () => pending('x') }, null];
  assert.equal(L.pendingAllowed(list, 'x', 3, 1), true);
});

test('pendingAllowed: принимает сокеты с deserializeAttachment', () => {
  const sock = { readyState: 1, deserializeAttachment: () => pending('9.9.9.9') };
  assert.equal(L.pendingAllowed([sock], '9.9.9.9', 3, 1), false);
  assert.equal(L.pendingAllowed([sock], '8.8.8.8', 3, 1), true);
});

test('pendingAllowed: без IP лимит на IP не применяется', () => {
  assert.equal(L.pendingAllowed([pending(undefined)], '', 3, 1), true);
  assert.equal(L.pendingAllowed([pending(undefined)], undefined, 3, 1), true);
});

test('decline: 60 с, после третьего подряд 10 минут', () => {
  const map = new Map();
  assert.equal(L.declineCooldown(map, 'k', 0), 0);
  L.noteDecline(map, 'k', 0);
  assert.equal(L.declineCooldown(map, 'k', 10_000), 50_000);
  assert.equal(L.declineCooldown(map, 'k', 60_000), 0);
  L.noteDecline(map, 'k', 61_000);
  assert.equal(L.declineCooldown(map, 'k', 61_000), 60_000);
  L.noteDecline(map, 'k', 130_000);
  assert.equal(L.declineCooldown(map, 'k', 130_000), 600_000);
  assert.equal(L.declineCooldown(map, 'other', 130_000), 0);
});

test('decline: серия сбрасывается после долгой тишины', () => {
  const map = new Map();
  L.noteDecline(map, 'k', 0); L.noteDecline(map, 'k', 60_000); L.noteDecline(map, 'k', 120_000);
  const until = 120_000 + 600_000;
  L.noteDecline(map, 'k', until + 600_001);
  assert.equal(L.declineCooldown(map, 'k', until + 600_001), 60_000);
});

test('pendingAllowed: filter отбирает, какие ожидающие считать', () => {
  const list = [{ approved: false, ip: 'a', auth: 'pending' }, { approved: false, ip: 'a', auth: 'none' }];
  assert.equal(L.pendingAllowed(list, 'a', 10, 1), false);
  assert.equal(L.pendingAllowed(list, 'a', 10, 2, (info) => info.auth !== 'pending'), true);
});

test('ipKey: IPv4 целиком, IPv6 по /64, IPv4-mapped как IPv4, идемпотентность', () => {
  const cases = [
    ['1.2.3.4', '1.2.3.4'], [' 1.2.3.4 ', '1.2.3.4'], ['', ''], [undefined, ''],
    ['2001:db8:1:2:3:4:5:6', '2001:db8:1:2::/64'], ['2001:DB8:1:2::9', '2001:db8:1:2::/64'],
    ['2001:0db8:0001:0002:ffff::1', '2001:db8:1:2::/64'], ['2001:db8::1', '2001:db8:0:0::/64'],
    ['::1', '0:0:0:0::/64'], ['::ffff:1.2.3.4', '1.2.3.4'], ['fe80::1%eth0', 'fe80:0:0:0::/64'],
    ['[2001:db8:1:2::1]', '2001:db8:1:2::/64'], ['2001:db8:1:2:3:4:1.2.3.4', '2001:db8:1:2::/64'],
  ];
  for (const [ip, key] of cases) {
    assert.equal(L.ipKey(ip), key, String(ip));
    assert.equal(L.ipKey(L.ipKey(ip)), key, `повторно: ${ip}`);
  }
  assert.equal(L.ipKey('2001:db8:1:2::1'), L.ipKey('2001:db8:1:2:ffff:ffff:ffff:ffff'), 'один /64');
  assert.notEqual(L.ipKey('2001:db8:1:2::1'), L.ipKey('2001:db8:1:3::1'), 'разные /64');
  assert.equal(L.ipKey('not:::an:ip'), 'not:::an:ip', 'мусор не ломается');
});
