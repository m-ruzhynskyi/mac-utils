// Мониторы ведущего на странице relay (SHARE-PROTOCOL §4.1): правило ведущего, ревизия списка, зритель (запрос, ответ,
// таймаут), клавиши 1…9 и замена дорожки видео без остановки эфира. Код берётся из index.html между метками
// <monitor-switch>, данные — из общей фикстуры fixtures/displays.json (её же читают Mac и Windows).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync(`${__dirname}/../src/index.html`, 'utf8');
const block = html.slice(html.indexOf('// <monitor-switch>'), html.indexOf('// </monitor-switch>'));
assert.ok(block.length > 1000, 'метки <monitor-switch> на месте');
const page = vm.createContext({});
vm.runInContext(`${block}\nObject.assign(this, { switchDecision, displaysRevision, displaysMessage, swapVideoTrack, displayLabel, displaysLayout, monitorViewer, monitorKey, SWITCH_WAIT_MS, allowSwitchFrom, switchResult, shouldReannounce });`, page);
const fixture = JSON.parse(fs.readFileSync(`${__dirname}/fixtures/displays.json`, 'utf8'));
const KATE = fixture.valid[0].expected;
const plain = (value) => JSON.parse(JSON.stringify(value));

const host = (over = {}) => ({ allowed: true, screen: true, rev: 7, list: KATE.list, current: 2, switching: false, lastSwitchAt: -Infinity, ...over });

test('правило ведущего: все пять исходов', () => {
  const now = 100_000;
  assert.equal(page.switchDecision(host({ allowed: false }), { display: 3, rev: 7 }, now), 'off');
  assert.equal(page.switchDecision(host({ screen: false }), { display: 3, rev: 7 }, now), 'off');
  assert.equal(page.switchDecision(host({ list: [] }), { display: 3, rev: 7 }, now), 'off');
  assert.equal(page.switchDecision(host(), { display: 3, rev: 6 }, now), 'stale');
  assert.equal(page.switchDecision(host(), { display: 4, rev: 7 }, now), 'stale');
  assert.equal(page.switchDecision(host(), { display: 2, rev: 7 }, now), 'ok');
  assert.equal(page.switchDecision(host({ switching: true }), { display: 3, rev: 7 }, now), 'busy');
  assert.equal(page.switchDecision(host(), { display: 3, rev: 7 }, now), 'switch');
});

test('правило ведущего: между переключениями не меньше 2 с, уже текущий — ok и раньше', () => {
  const at = 50_000;
  assert.equal(page.switchDecision(host({ lastSwitchAt: at }), { display: 1, rev: 7 }, at + 1999), 'busy');
  assert.equal(page.switchDecision(host({ lastSwitchAt: at }), { display: 2, rev: 7 }, at + 10), 'ok');
  assert.equal(page.switchDecision(host({ lastSwitchAt: at }), { display: 1, rev: 7 }, at + 2000), 'switch');
});

test('ревизия растёт только при изменении списка', () => {
  const memo = { key: '', rev: 0 };
  const first = page.displaysRevision(memo, KATE.list);
  assert.equal(page.displaysRevision(memo, plain(KATE.list)), first, 'тот же список');
  const scaled = plain(KATE.list); scaled[0].scale = 1.25;
  assert.equal(page.displaysRevision(memo, scaled), first + 1, 'сменили масштаб');
  assert.equal(page.displaysRevision(memo, KATE.list.slice(0, 2)), first + 2, 'отключили монитор');
});

test('сообщение displays: как в фикстуре; выключено, окно или чужой current — пустой список без current', () => {
  assert.deepEqual(plain(page.displaysMessage(7, KATE.list, 2, true)), KATE);
  assert.deepEqual(plain(page.displaysMessage(8, KATE.list, 2, false)), { type: 'displays', v: 1, rev: 8, list: [] });
  assert.deepEqual(plain(page.displaysMessage(8, KATE.list, 0, true)), { type: 'displays', v: 1, rev: 8, list: [] });
  const many = fixture.valid[2].expected.list.concat([{ ...KATE.list[0], n: 9 }]);
  assert.equal(page.displaysMessage(1, many, 1, true).list.length, 8);
});

test('зритель: первый список без плашки, клик → запрос с ревизией, ok и новый current — готово, метки заново', () => {
  const v = page.monitorViewer();
  assert.deepEqual(plain(v.apply(KATE)), { switched: false, gone: false, done: false });
  assert.equal(v.current, 2);
  assert.equal(v.request(2, 0), null, 'уже показывается');
  assert.equal(v.request(5, 0), null, 'нет такого');
  assert.deepEqual(plain(v.request(3, 1000)), { type: 'switch-request', display: 3, rev: 7 });
  assert.equal(v.request(1, 1100), null, 'запрос уже в пути');
  assert.equal(v.result({ type: 'switch-result', display: 3, result: 'ok' }), null);
  assert.equal(v.pending, 3, 'ok ждёт displays');
  assert.deepEqual(plain(v.apply({ ...KATE, current: 3 })), { switched: true, gone: false, done: true });
  assert.equal(v.pending, 0);
  assert.deepEqual(plain(v.apply({ ...KATE, current: 3 })), { switched: false, gone: false, done: false }, 'повтор того же списка ничего не меняет');
});

test('зритель: переключил другой — тоже «показывает монитор N»', () => {
  const v = page.monitorViewer();
  v.apply(KATE);
  assert.equal(v.apply({ ...KATE, current: 1 }).switched, true);
});

test('зритель: busy, failed, off — плашки; stale — молча; таймаут 8 с', () => {
  for (const result of ['busy', 'failed', 'off']) {
    const v = page.monitorViewer(); v.apply(KATE); v.request(3, 0);
    assert.equal(v.result({ display: 3, result }), result);
    assert.equal(v.pending, 0);
  }
  const v = page.monitorViewer(); v.apply(KATE); v.request(3, 0);
  assert.equal(v.result({ display: 1, result: 'busy' }), null, 'ответ не на этот запрос');
  assert.equal(v.result({ display: 3, result: 'stale' }), null);
  assert.equal(v.pending, 0);
  v.request(1, 10_000);
  assert.equal(v.expired(10_000 + page.SWITCH_WAIT_MS - 1), false);
  assert.equal(v.expired(10_000 + page.SWITCH_WAIT_MS), true);
  assert.equal(v.pending, 0);
});

test('зритель: пустой список прячет раздел; незнакомая версия и мусор игнорируются; старый ведущий — раздела нет', () => {
  const v = page.monitorViewer();
  assert.equal(v.list.length, 0, 'без displays раздела нет');
  v.apply(KATE); v.request(3, 0);
  assert.deepEqual(plain(v.apply({ type: 'displays', v: 1, rev: 8, list: [] })), { switched: false, gone: true, done: true });
  assert.equal(v.list.length, 0);
  assert.equal(v.request(3, 0), null);
  assert.equal(v.apply({ ...KATE, v: 2 }), null);
  assert.equal(v.apply({ type: 'displays', v: 1, rev: '7', list: [] }), null);
  assert.equal(v.list.length, 0);
});

test('клавиши 1…9: только без модификаторов и не в поле ввода', () => {
  const key = (k, over = {}) => page.monitorKey({ key: k, target: { tagName: 'CANVAS' }, ...over });
  assert.equal(key('3'), 3);
  assert.equal(key('9'), 9);
  assert.equal(key('0'), 0);
  assert.equal(key('a'), 0);
  assert.equal(key('3', { target: { tagName: 'INPUT' } }), 0);
  assert.equal(key('3', { target: { tagName: 'DIV', isContentEditable: true } }), 0);
  assert.equal(key('3', { ctrlKey: true }), 0);
  assert.equal(key('3', { metaKey: true }), 0);
  assert.equal(key('3', { repeat: true }), 0);
});

test('замена дорожки: onended старой снят до остановки, чтение остановлено, звук первого захвата остаётся', () => {
  const log = [];
  const track = (name, kind) => ({ name, kind, onended: () => log.push(`ended ${name}`), stop() { log.push(`stop ${name}`); if (this.onended) this.onended(); } });
  const oldVideo = track('old', 'video'), loopback = track('loopback', 'audio');
  const stream = { tracks: [oldVideo, loopback],
    getVideoTracks() { return this.tracks.filter((t) => t.kind === 'video'); },
    getAudioTracks() { return this.tracks.filter((t) => t.kind === 'audio'); },
    removeTrack(t) { this.tracks = this.tracks.filter((x) => x !== t); }, addTrack(t) { this.tracks.push(t); } };
  const newVideo = track('new', 'video'), extraAudio = track('extra', 'audio');
  const next = { getVideoTracks: () => [newVideo], getAudioTracks: () => [extraAudio] };
  const got = page.swapVideoTrack(stream, next, () => log.push('reader stopped'));
  assert.equal(got, newVideo);
  assert.deepEqual(log, ['stop extra', 'ended extra', 'reader stopped', 'stop old'], 'старая дорожка не вызвала onended (эфир не остановился)');
  assert.deepEqual(stream.tracks.map((t) => t.name), ['loopback', 'new']);
  assert.equal(page.swapVideoTrack(stream, { getVideoTracks: () => [], getAudioTracks: () => [] }, () => log.push('x')), null);
  assert.equal(log.includes('x'), false, 'без новой дорожки ничего не трогаем');
});

test('схема: пропорции раскладки Кати, основной 4K при 175 % не крупнее соседей вдвое', () => {
  const layout = page.displaysLayout(KATE.list, 40);
  const [a, b, c] = layout.tiles;
  assert.ok(a.x < b.x && b.x < c.x, 'слева направо');
  assert.ok(Math.abs(b.h - 40 + 3) < 0.01, 'основной во всю высоту');
  assert.ok(a.h < b.h && a.w < b.w && b.w < a.w * 1.3, `ширины ${a.w} ${b.w}`);
  assert.ok(layout.width > 0 && layout.height > 0);
  assert.equal(page.displayLabel(KATE.list[1], 2), 'Монитор 2, основной, 3840 на 2160, 175 %, показывается сейчас');
  assert.equal(page.displayLabel(KATE.list[0], 2), 'Монитор 1, 1920 на 1080, 100 %');
});

test('разрешение ведущего по умолчанию выключено: только явное «да» из хранилища', () => {
  assert.equal(page.allowSwitchFrom(undefined), false);
  assert.equal(page.allowSwitchFrom(null), false);
  assert.equal(page.allowSwitchFrom(false), false);
  assert.equal(page.allowSwitchFrom('true'), false);
  assert.equal(page.allowSwitchFrom(true), true);
  assert.doesNotMatch(html, /id="allowSwitch" checked/, 'галочка в выборе не отмечена заранее');
});

test('итог переключения: выключили настройку во время переключения — off, не ok', () => {
  assert.equal(page.switchResult(true, true), 'ok');
  assert.equal(page.switchResult(true, false), 'off');
  assert.equal(page.switchResult(false, true), 'failed');
});

test('свежий список на off/stale — не чаще раза в секунду', () => {
  assert.equal(page.shouldReannounce(-Infinity, 0), true);
  assert.equal(page.shouldReannounce(10_000, 10_999), false);
  assert.equal(page.shouldReannounce(10_000, 11_000), true);
});
