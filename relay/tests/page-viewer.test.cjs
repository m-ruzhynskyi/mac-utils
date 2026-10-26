// Зритель на странице relay (клиент для Windows, браузер): декодер WebCodecs подменён моделью со своими часами.
// Жалоба (2026-10-26): трансляция с Mac у зрителя на Windows «жёстко тормозит и рывками». Причина — старое правило
// `decodeQueueSize > 4` → всё до ключевого кадра выбрасывается, а ключевой у Mac раз в 4 с; ведущему зритель ничего не
// говорил. Здесь — модель: ведущий шлёт 60 кадров/с, ключевой раз в 4 с (или по просьбе); декодер тратит на кадр
// `decodeMs` и может «встать» (сборка мусора, перетаскивание окна). Из index.html берутся блок <view-video> и nalUnits.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync(`${__dirname}/../src/index.html`, 'utf8');
const block = html.slice(html.indexOf('// <view-video>'), html.indexOf('// </view-video>'));
const nal = html.slice(html.indexOf('function nalUnits(data) {'), html.indexOf('\n}\n', html.indexOf('function nalUnits(data) {')) + 3);
assert.ok(block.length > 1000 && nal.length > 100, 'метка <view-video> и nalUnits на месте');

const annexB = (...units) => Uint8Array.from(units.flatMap((u) => [0, 0, 0, 1, ...u]));
const KEY = annexB([0x67, 0x64, 0x00, 0x28, 0xaa], [0x68, 0xee, 0x3c, 0x80], [0x65, 0x88, 0x84]);
const DELTA = annexB([0x41, 0x9a, 0x02]);

// options: decodeMs — кадр в декодере; stalls: [[от, до]] мс — декодер стоит; fps — с какой частотой начинает ведущий;
// hostSlow — ведущий понимает `slow` (новый Mac/страница); hostKey — отвечает ключевым кадром на просьбу (через relay);
// hardware — есть аппаратный декодер (иначе configure с prefer-hardware — ошибка после configure).
function run(seconds, options = {}) {
  const { decodeMs = 4, stalls = [], hostSlow = true, hostKey = true, hardware = true } = options;
  let clock = 0;
  const logs = [], sentToRelay = [], configs = [], decodeErrors = [];
  const raf = [];
  const decoders = [];
  class VideoFrame {
    constructor(init) { Object.assign(this, init); }
    close() {}
  }
  class EncodedVideoChunk { constructor(init) { Object.assign(this, init); } }
  class VideoDecoder {
    constructor({ output, error }) { this.output = output; this.error = error; this.state = 'unconfigured'; this.queue = []; this.busyUntil = 0; this.needKey = true; decoders.push(this); }
    static isConfigSupported(config) { return Promise.resolve({ supported: config.hardwareAcceleration !== 'prefer-hardware' || hardware }); }
    get decodeQueueSize() { return this.queue.length; }
    configure(config) {
      configs.push(config);
      this.state = 'configured'; this.needKey = true;
      if (config.hardwareAcceleration === 'prefer-hardware' && !hardware) {
        Promise.resolve().then(() => { if (this.state !== 'closed') { this.state = 'closed'; this.error(new Error('NotSupportedError')); } });
      }
    }
    decode(chunk) {
      if (this.state !== 'configured') throw new Error('InvalidStateError');
      // Как Chromium: после configure/reset первым должен быть ключевой кадр.
      if (this.needKey && chunk.type !== 'key') { decodeErrors.push(clock); throw new Error('DataError: key frame required'); }
      this.needKey = false;
      this.queue.push(chunk);
    }
    reset() { this.queue = []; this.state = 'unconfigured'; this.needKey = true; }
    close() { this.queue = []; this.state = 'closed'; }
    // Шаг часов: декодер стоит во время stalls, иначе отдаёт кадр за decodeMs.
    step() {
      if (this.state !== 'configured' || !this.queue.length) return;
      if (stalls.some(([a, b]) => clock >= a && clock < b)) { this.busyUntil = Math.max(this.busyUntil, clock); return; }
      if (this.busyUntil === 0 || this.busyUntil < clock - decodeMs) this.busyUntil = clock;
      while (this.queue.length && this.busyUntil + decodeMs <= clock) {
        this.busyUntil += decodeMs;
        const chunk = this.queue.shift();
        this.output(new VideoFrame({ timestamp: chunk.timestamp, displayWidth: 1920, displayHeight: 1080 }));
      }
    }
  }
  const canvas = { width: 0, height: 0, style: { display: 'none' }, getContext: () => ({ drawImage() {} }) };
  const screen = { style: { display: '' } };
  const context = vm.createContext({
    performance: { now: () => clock }, console: { info() {} },
    window: { mu: { log: (line) => logs.push(line) } },
    $: (id) => (id === 'video' ? canvas : screen), status() {},
    requestAnimationFrame: (fn) => raf.push(fn),
    viewSocket: { readyState: 1, send: (text) => sentToRelay.push({ at: clock, ...JSON.parse(text) }) },
    VideoDecoder, EncodedVideoChunk, Promise,
  });
  vm.runInContext(`${nal}\n${block}`, context);

  // Ведущий: кадры по своей частоте, ключевой раз в 4 с или по просьбе (relay передаёт её не чаще раза в секунду).
  let fps = options.fps ?? 60, nextFrame = 0, lastKey = -Infinity, wantKey = false, relayKeyAt = -Infinity, slowAt = null;
  let painted = 0, lastPaint = 0, longestGap = 0;
  const gaps = [];
  return (async () => {
    for (; clock <= seconds * 1000; clock += 1) {
      for (const message of sentToRelay.splice(0)) {
        if (message.key && hostKey && clock - relayKeyAt >= 1000) { relayKeyAt = clock; wantKey = true; }
        if (message.slow && hostSlow && fps === 60) { fps = 30; slowAt = clock; }
        (run.history ??= []).push(message);
      }
      if (clock >= nextFrame) {
        nextFrame += 1000 / fps;
        const key = wantKey || clock - lastKey >= 4000;
        if (key) { lastKey = clock; wantKey = false; }
        context.playH264(Uint8Array.from([key ? 1 : 0, ...(key ? KEY : DELTA)]));
        await Promise.resolve();
      }
      for (const d of decoders) d.step();
      // Экран 60 Гц: rAF раз в ~16,7 мс.
      if (clock % 17 === 0) {
        const frames = raf.splice(0);
        for (const fn of frames) fn();
        const after = vm.runInContext('viewStats.painted', context);
        if (after > painted) { painted = after; const gap = clock - lastPaint; if (clock > 1000) { gaps.push(gap); longestGap = Math.max(longestGap, gap); } lastPaint = clock; }
      }
    }
    vm.runInContext('viewStatsFlush(performance.now(), true)', context);
    return { logs, configs, decodeErrors, fps, slowAt, longestGap, gaps,
             stats: logs.filter((l) => l.startsWith('viewer stats')),
             asks: (run.history ?? []).splice(0) };
  })();
}
const field = (line, name) => Number((line.match(new RegExp(`\\b${name}=(\\d+)`)) || [])[1]);

test('короткая заминка декодера (150 мс, сборка мусора): старое правило «очередь > 4» заморозило бы до ключевого, теперь — ни выброса, ни просьб', async () => {
  const r = await run(10, { stalls: [[3000, 3150]] });
  const stats = r.stats.at(-1);
  assert.ok(field(stats, 'maxQueue') > 4, `очередь дошла до ${field(stats, 'maxQueue')} — прежде это был выброс до ключевого (до 4 с)`);
  assert.equal(field(stats, 'dropped'), 0, stats);
  assert.equal(field(stats, 'freezes'), 0, stats);
  assert.equal(field(stats, 'keyAsks'), 0);
  assert.equal(r.fps, 60, 'частоту ведущего не трогаем');
  assert.ok(r.longestGap < 250, `самая долгая пауза картинки ${r.longestGap} мс`);
  assert.deepEqual(r.decodeErrors, []);
});

test('слабый ПК (кадр декодируется 22 мс, успевает ~45 из 60): просьба «не успеваю» → ведущий на 30 кадрах/с, картинка ровная', async () => {
  const r = await run(70, { decodeMs: 22 });
  assert.ok(r.slowAt !== null && r.slowAt < 5000, `slow ушёл через ${r.slowAt} мс (второй выброс подряд)`);
  assert.equal(r.fps, 30);
  const late = r.gaps.slice(-1000);
  assert.ok(Math.max(...late) < 80, `после перехода на 30 рывков нет: максимум паузы ${Math.max(...late)} мс`);
  const total = r.stats.reduce((sum, l) => sum + field(l, 'freezeMs'), 0);
  assert.ok(total < 1000, `заморозок суммарно ${total} мс за 70 с (раньше — до 4 с на каждую)`);
  assert.deepEqual(r.decodeErrors, [], 'после сброса декодеру первым идёт ключевой кадр');
  // Раз в минуту — строка статистики, только числа.
  assert.ok(r.stats.length >= 2, r.logs.join('\n'));
  assert.match(r.stats[0], /^viewer stats decoder=hw size=1920x1080 sec=\d+ in=\d+ decoded=\d+ painted=\d+ dropped=\d+ maxQueue=\d+ maxLagMs=\d+ freezes=\d+ freezeMs=\d+ keyAsks=\d+ slowAsks=\d+ errors=\d+$/);
});

test('декодер встал на 1 с (перетаскивание окна): очередь сброшена, ключевой попрошен сразу — заморозка ≈ заминка, не до 4 с', async () => {
  const r = await run(10, { stalls: [[2100, 3100]] });
  const stats = r.stats.at(-1);
  assert.equal(field(stats, 'freezes'), 1, stats);
  assert.ok(field(stats, 'freezeMs') < 700, `заморозка после заминки ${field(stats, 'freezeMs')} мс`);
  assert.ok(r.longestGap < 1300, `пауза картинки ${r.longestGap} мс (раньше до ключевого через 4 с — ~1,9 с и больше)`);
  assert.ok(r.asks.some((m) => m.key === true && m.at >= 2500 && m.at < 3200), 'ключевой попрошен во время заминки');
  assert.ok(field(stats, 'keyAsks') <= 3, 'не чаще раза в секунду');
  assert.equal(r.fps, 60, 'разовая заминка частоту ведущего не снижает');
  assert.deepEqual(r.decodeErrors, []);
});

test('старый ведущий (slow не знает, на ключевой отвечает): ключевой по просьбе — без заморозок до 4 с', async () => {
  const r = await run(30, { decodeMs: 22, hostSlow: false });
  assert.equal(r.fps, 60, 'старый ведущий частоту не меняет');
  const worst = Math.max(...r.gaps);
  assert.ok(worst < 1500, `самая долгая пауза ${worst} мс — не до планового ключевого`);
  assert.deepEqual(r.decodeErrors, []);
});

test('нет аппаратного декодера: prefer-hardware падает → декодер браузера по умолчанию, ключевой попрошен, картинка идёт', async () => {
  const r = await run(6, { hardware: false });
  assert.equal(r.configs[0].hardwareAcceleration, 'prefer-hardware');
  assert.equal(r.configs.at(-1).hardwareAcceleration, 'no-preference');
  assert.ok(r.asks.some((m) => m.key === true && m.at < 200), 'ключевой попрошен сразу после отказа');
  const stats = r.stats.at(-1);
  assert.match(stats, /decoder=auto/);
  assert.ok(field(stats, 'painted') > 250, stats);
  assert.equal(field(stats, 'errors'), 1);
});
