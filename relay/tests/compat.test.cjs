// Совместимость сторон трансляции (Mac ↔ страница relay: браузер и клиент для Windows) по общим фикстурам
// relay/tests/fixtures. Те же файлы читает ShareCompatTests на Mac, поэтому правка формата на одной стороне ломает тест.
// - *.h264: пакеты видео как они идут через relay — [3][1 — ключевой][Annex B], каждый с 4 байтами длины впереди:
//   mac-videotoolbox — H264Encoder Mac (High), page-chromium-hardware / page-chromium-openh264 — страница ведущего в
//   Chromium 130 (Electron 33, как клиент для Windows) с аппаратным кодером и с программным OpenH264 (тот же, что у
//   ведущего Windows без аппаратного H.264). Ключевой кадр, потом два обычных; картинка — демо 320×180.
// - marks.json: метки зрителя в формате Mac и страницы.
// - displays.json: мониторы ведущего, запросы и ответы переключения (SHARE-PROTOCOL §4.1).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const dir = `${__dirname}/fixtures`;
const html = fs.readFileSync(`${__dirname}/../src/index.html`, 'utf8');
const page = vm.createContext({});
vm.runInContext(html.slice(html.indexOf('// <host-video>'), html.indexOf('// </host-video>')), page);
const relaySource = fs.readFileSync(`${__dirname}/../src/index.js`, 'utf8');
const relay = vm.createContext({});
vm.runInContext(relaySource.slice(relaySource.indexOf('const MARK_COLORS'), relaySource.indexOf('// Token bucket')) +
  '\nObject.assign(this, { sanitizeMark, sanitizeDisplays, sanitizeSwitchRequest, sanitizeSwitchResult });', relay);

function packets(name) {
  const data = fs.readFileSync(`${dir}/${name}`);
  const list = [];
  for (let at = 0; at < data.length;) { const length = data.readUInt32BE(at); list.push(new Uint8Array(data.subarray(at + 4, at + 4 + length))); at += 4 + length; }
  return list;
}
// Как страница-зритель настраивает декодер (playH264): строка кодека из первых байтов SPS ключевого кадра.
function pageCodec(packet) {
  const sps = page.nalUnits(packet.subarray(2)).find((u) => (u[0] & 0x1f) === 7);
  if (!sps) return null;
  const hex = (n) => n.toString(16).padStart(2, '0');
  return `avc1.${hex(sps[1])}${hex(sps[2])}${hex(sps[3])}`;
}

for (const [name, profile] of [['mac-videotoolbox.h264', 0x64], ['page-chromium-hardware.h264', null], ['page-chromium-openh264.h264', null]]) {
  test(`${name}: ключевой кадр с SPS и PPS, по нему настраивается страница-зритель`, () => {
    const list = packets(name);
    assert.equal(list.length, 3);
    assert.ok(list.every((p) => p[0] === 3), 'тип пакета — H.264');
    assert.deepEqual(list.map((p) => p[1]), [1, 0, 0], 'первый ключевой, потом обычные');
    const types = page.nalUnits(list[0].subarray(2)).map((u) => u[0] & 0x1f);
    assert.ok(types.includes(7) && types.includes(8) && types.includes(5), `NAL ключевого: ${types}`);
    const codec = pageCodec(list[0]);
    assert.match(codec, /^avc1\.(42|4d|64)[0-9a-f]{4}$/, `строка кодека ${codec}`);
    if (profile) assert.equal(parseInt(codec.slice(5, 7), 16), profile, 'Mac шлёт High');
    // Подстановка SPS/PPS (0b20c3e) ключевой кадр, где они есть, не меняет.
    const cache = {}, key = list[0].subarray(2);
    assert.equal(page.withParameterSets(key, cache), key);
    assert.ok(cache.sps && cache.pps);
  });
}

test('метки: формат Mac и страницы relay принимает одинаково, координаты — доли кадра', () => {
  const marks = JSON.parse(fs.readFileSync(`${dir}/marks.json`, 'utf8'));
  for (const side of ['mac', 'page']) {
    for (const kind of ['ping', 'stroke']) {
      const clean = relay.sanitizeMark(JSON.parse(marks[side][kind]));
      assert.deepEqual(JSON.parse(JSON.stringify(clean)), marks.expected[side][kind], `${side} ${kind}`);
    }
  }
});

const displays = JSON.parse(fs.readFileSync(`${dir}/displays.json`, 'utf8'));
const plain = (value) => JSON.parse(JSON.stringify(value));

test('мониторы ведущего: годные списки relay передаёт без имён и ID, в том же виде', () => {
  for (const sample of displays.valid) {
    assert.deepEqual(plain(relay.sanitizeDisplays(JSON.parse(sample.message))), sample.expected, sample.about);
  }
});

test('мониторы ведущего: негодный список relay отбрасывает целиком', () => {
  for (const sample of displays.invalid) {
    assert.equal(relay.sanitizeDisplays(JSON.parse(sample.message)), null, sample.about);
  }
});

test('мониторы ведущего: нумерация фикстуры — слева направо, затем сверху вниз', () => {
  for (const layout of displays.numbering) {
    const order = [...layout.screens].sort((a, b) => a.at[0] - b.at[0] || a.at[1] - b.at[1]).map((s) => s.key);
    assert.deepEqual(order, layout.expected, layout.about);
  }
});

test('switch-request и switch-result: relay оставляет только проверенные поля', () => {
  for (const sample of displays.requests.valid) assert.deepEqual(plain(relay.sanitizeSwitchRequest(JSON.parse(sample.message))), sample.expected);
  for (const message of displays.requests.invalid) assert.equal(relay.sanitizeSwitchRequest(JSON.parse(message)), null, message);
  for (const sample of displays.results.valid) assert.deepEqual(plain(relay.sanitizeSwitchResult(JSON.parse(sample.message))), sample.expected);
  for (const message of displays.results.invalid) assert.equal(relay.sanitizeSwitchResult(JSON.parse(message)), null, message);
});
