// Видео ведущего на странице relay (клиент для Windows и браузер): кодер WebCodecs подменён моделью, и проверяется, что
// зритель (Mac, страница) получает кадры, по которым может начать показ: ключевой H.264 с SPS и PPS или JPEG.
// Модели — поведение кодера Chromium на Windows, при котором зритель Mac висел в «Жду картинку…»: нет аппаратного
// кодера, не создаётся ни один, кадры захвата напрямую не принимаются, SPS/PPS только в первом ключевом кадре; и экран
// крупнее 1920, который должен уменьшать холст (масштаб кодера Windows не проверить, обрезка сдвигает точки зрителей).
// Из index.html берутся блок <host-video> и функция startCapture целиком; для смены монитора — ещё <monitor-switch>.
// Смена монитора зрителем (SHARE-PROTOCOL §4.1): новая дорожка того же эфира другого размера — новый кодер, сразу
// ключевой кадр с SPS/PPS, эфир не останавливается.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync(`${__dirname}/../src/index.html`, 'utf8');
const block = html.slice(html.indexOf('// <host-video>'), html.indexOf('// </host-video>'));
const startAt = html.indexOf('function startCapture(stream, code) {');
const capture = html.slice(startAt, html.indexOf('\nfunction onHostMessage(', startAt));
const monitors = html.slice(html.indexOf('// <monitor-switch>'), html.indexOf('// </monitor-switch>'));
assert.ok(block.length > 100 && capture.length > 1000 && monitors.length > 100, 'метки <host-video>, <monitor-switch> и startCapture на месте');

const NAL = { sps: [0x67, 0x4d, 0x40, 0x32, 0xaa], pps: [0x68, 0xee, 0x3c, 0x80], idr: [0x65, 0x88, 0x84, 0x00], slice: [0x41, 0x9a, 0x02] };
const annexB = (...units) => Uint8Array.from(units.flatMap((u) => [0, 0, 0, 1, ...u]));

// behaviour: { hardware: bool (есть аппаратный кодер), any: bool (создаётся хоть какой-то), software: bool (есть программный),
//              direct: 'ok' | 'throw' | 'silent', spsOnce: bool (SPS/PPS только в первом ключевом кадре кодера),
//              syncError: bool (ошибка прямо из configure), latency: число кадров, которые кодер держит,
//              outage: [от, до] мс — аппаратный кодер падает и не создаётся (сброс GPU-процесса, смена монитора, сон),
//              outageAll: [от, до] мс — то же для любого кодера, crashEvery: мс — аппаратный падает посреди эфира так часто,
//              probe: { hw, sw } — ответ VideoEncoder.isConfigSupported, stuckQueue: очередь кодера не уходит }
function page(behaviour) {
  let clock = 0;
  const sent = [], intervals = [], configs = [], logs = [];
  const within = (range) => range && clock >= range[0] && clock < range[1];
  let lastCrash = 0;
  let wake = null, stopped = 0;
  class VideoFrame {
    constructor(source, init = {}) {
      this.source = source; this.timestamp = init.timestamp;
      this.displayWidth = init.displayWidth ?? source?.displayWidth ?? source?.width ?? 0;
      this.displayHeight = init.displayHeight ?? source?.displayHeight ?? source?.height ?? 0;
    }
    close() {}
  }
  class VideoEncoder {
    constructor({ output, error }) { this.output = output; this.error = error; this.state = 'unconfigured'; this.encodeQueueSize = 0; this.keys = 0; }
    configure(config) {
      configs.push(config); this.config = `${config.width}x${config.height}`; this.acceleration = config.hardwareAcceleration;
      const hardware = config.hardwareAcceleration === 'prefer-hardware';
      const works = behaviour.any !== false && !within(behaviour.outageAll) &&
        (hardware ? behaviour.hardware !== false && !within(behaviour.outage) : behaviour.software !== false);
      if (works) { this.state = 'configured'; return; }
      const fail = () => { this.state = 'closed'; this.error(new Error('Encoder creation error.')); };
      if (behaviour.syncError) fail(); else Promise.resolve().then(fail);
    }
    encode(frame, { keyFrame }) {
      if (this.state !== 'configured') throw new Error('InvalidStateError');
      const hardware = this.acceleration === 'prefer-hardware';
      const crash = within(behaviour.outageAll) || (hardware && (within(behaviour.outage) ||
        (behaviour.crashEvery && clock - lastCrash >= behaviour.crashEvery && clock >= behaviour.crashEvery)));
      if (crash) {
        if (behaviour.crashEvery && hardware && !within(behaviour.outage)) lastCrash = clock;
        this.state = 'closed'; Promise.resolve().then(() => this.error(new Error('Encoder failure')));
        return;
      }
      if (behaviour.stuckQueue && (behaviour.fed?.length ?? 0) >= 10) { this.encodeQueueSize = 3; }
      const direct = frame.source instanceof VideoFrame;
      (behaviour.fed ??= []).push({ direct, width: frame.source?.width ?? frame.displayWidth, config: this.config });
      if (direct && behaviour.direct === 'throw') throw new Error('EncodingError');
      if (direct && behaviour.direct === 'silent') return;
      const sets = keyFrame && (!behaviour.spsOnce || this.keys === 0);
      if (keyFrame) this.keys++;
      const data = keyFrame ? (sets ? annexB(NAL.sps, NAL.pps, NAL.idr) : annexB(NAL.idr)) : annexB(NAL.slice);
      const chunk = { type: keyFrame ? 'key' : 'delta', byteLength: data.length, copyTo: (to) => to.set(data) };
      (this.held ??= []).push(chunk);
      while (this.held.length > (behaviour.latency ?? 0)) {
        const next = this.held.shift();
        Promise.resolve().then(() => this.state === 'configured' && this.output(next));
      }
    }
    close() { this.state = 'closed'; }
  }
  if (behaviour.probe) {
    VideoEncoder.isConfigSupported = async (config) =>
      ({ supported: config.hardwareAcceleration === 'prefer-hardware' ? behaviour.probe.hw : behaviour.probe.sw });
  }
  const element = () => ({ style: {}, textContent: '', title: '', insertAdjacentHTML() {} });
  const elements = {};
  const context = vm.createContext({
    console: { ...console, info() {} }, Math, Promise, Uint8Array, Infinity, logs, String, devicePixelRatio: 1,
    requestAnimationFrame: () => 0,
    performance: { now: () => clock },
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; }, clearInterval() {},
    document: { createElement: (tag) => tag === 'canvas'
      ? { width: 0, height: 0, getContext: () => ({ drawImage() {} }),
          toBlob(done) { done({ arrayBuffer: async () => Uint8Array.from([0xff, 0xd8, 0xff, 0xd9]).buffer }); } }
      : { srcObject: null, muted: false, play() {}, videoWidth: 1920, videoHeight: 1080 } },
    $: (id) => (elements[id] ??= element()),
    status() {}, hostClosed() {}, stopHost() { stopped++; },
    MediaStream: class { constructor(tracks) { this.tracks = tracks; } },
    VideoFrame, VideoEncoder,
    MediaStreamTrackProcessor: class { constructor() { this.readable = { getReader: () => ({
      read: () => new Promise((resolve) => { wake = resolve; }), cancel: async () => {} }) }; } },
  });
  vm.runInContext(`var forceKey = true, watching = false, capture = null, useHelperAudio = false, window = { mu: { log: (l) => logs.push(l), mark() {} } };
    var hostSocket = { readyState: 1, bufferedAmount: 0, onclose: null, send: (p) => sent.push(p) };
    ${block}\n${monitors}\n${capture}`, Object.assign(context, { sent }));
  const track = { onended: null, stop() { if (this.onended) this.onended(); } };
  const stream = { tracks: [track], getVideoTracks() { return this.tracks; }, getAudioTracks: () => [],
    removeTrack(t) { this.tracks = this.tracks.filter((x) => x !== t); }, addTrack(t) { this.tracks.push(t); } };
  context.startCapture(stream, '1234567890');
  return {
    sent, configs, logs, get stopped() { return stopped; },
    get videoMode() { return vm.runInContext('hostVideoMode', context); },
    // Метка зрителя пришла ведущему; screen — что сказало приложение о метках поверх экрана (marks-state).
    hostMark(mark, screen) {
      if (screen !== undefined) vm.runInContext(`marksOnScreen = ${screen}; marksReason = ${screen ? '""' : '"old-windows"'};`, context);
      context.hostShowMark(mark);
      return { shown: vm.runInContext('hostMarks.length', context), box: elements.hostMarks?.style.display, note: elements.hostMarksNote?.textContent };
    },
    // Зритель переключил монитор: новая дорожка (кадры другого размера), старое чтение остановлено.
    replace(size) {
      const next = { onended: null, stop() {} };
      behaviour.size = size;
      wake?.({ value: undefined, done: true }); wake = null;
      return context.capture.replaceVideo({ getVideoTracks: () => [next], getAudioTracks: () => [] });
    },
    viewerJoined() { context.forceKey = true; },
    // Кадры захвата 1920×1080 по 60 в секунду: каждый — в цикл чтения страницы, затем все обещания кодера.
    // Захват ничего не присылает (неподвижный экран), часы идут.
    async idle(seconds) { clock += seconds * 1000; await new Promise(setImmediate); },
    async run(seconds) {
      for (let i = 0; i < Math.round(seconds * 60); i++) {
        clock += 1000 / 60;
        for (let k = 0; k < 5 && !wake; k++) await new Promise(setImmediate);
        const resolve = wake; wake = null;
        const [width, height] = behaviour.size ?? [1920, 1080];
        resolve?.({ value: new VideoFrame(null, { displayWidth: width, displayHeight: height }), done: false });
        await new Promise(setImmediate);
      }
    },
  };
}

const nalTypes = (bytes) => {
  const types = [];
  for (let i = 0; i + 3 < bytes.length; i++) if (bytes[i] === 0 && bytes[i + 1] === 0 && bytes[i + 2] === 1) types.push(bytes[i + 3] & 0x1f);
  return types;
};
// Что получил бы зритель, начавший смотреть с пакета `from`: может ли начать показ и сколько кадров за `seconds`.
function viewer(sent, from = 0) {
  const packets = sent.slice(from).map((p) => Uint8Array.from(p));
  const h264 = packets.filter((p) => p[0] === 3), jpeg = packets.filter((p) => p[0] === 1);
  const startsH264 = h264.some((p) => p[1] === 1 && nalTypes(p.subarray(2)).includes(7) && nalTypes(p.subarray(2)).includes(8));
  return { h264: h264.length, jpeg: jpeg.length, canShow: startsH264 || jpeg.length > 0 };
}

test('аппаратный кодер: H.264 60 кадров/с, кадры захвата напрямую, ключевой с SPS/PPS', async () => {
  const p = page({});
  await p.run(2);
  const v = viewer(p.sent);
  assert.ok(v.canShow);
  assert.ok(v.h264 > 100, `кадров ${v.h264}`);
  assert.equal(v.jpeg, 0);
  assert.ok(p.configs.every((c) => c.hardwareAcceleration === 'prefer-hardware'));
});

for (const syncError of [false, true]) {
  test(`нет аппаратного кодера (ошибка ${syncError ? 'прямо из configure' : 'после configure'}): программный H.264, 30 кадров/с`, async () => {
    const p = page({ hardware: false, syncError });
    await p.run(1);
    const before = p.sent.length;
    await p.run(4);
    const v = viewer(p.sent);
    assert.ok(v.canShow, 'зритель может начать показ');
    assert.equal(v.jpeg, 0);
    const rate = (p.sent.length - before) / 4;
    assert.ok(rate >= 25 && rate <= 31, `кадров в секунду ${rate}`);
    // Явно программный: `no-preference` на Windows снова берёт аппаратный Media Foundation.
    const software = p.configs.filter((c) => c.hardwareAcceleration === 'prefer-software');
    assert.ok(software.length > 0);
    assert.ok(p.configs.every((c) => c.hardwareAcceleration !== 'no-preference'));
    assert.ok(software.every((c) => c.framerate === 30 && c.width === 1280 && c.height === 720), 'программный — 1280×720, 30 кадров/с');
  });
}

test('не создаётся ни один кодер: кадры JPEG, не чаще 8 в секунду', async () => {
  const p = page({ any: false });
  await p.run(1);
  const before = p.sent.length;
  await p.run(4);
  const v = viewer(p.sent);
  assert.ok(v.canShow);
  assert.equal(v.h264, 0);
  const rate = (p.sent.length - before) / 4;
  assert.ok(rate >= 6 && rate <= 8.5, `JPEG в секунду ${rate}`);
});

for (const direct of ['throw', 'silent']) {
  test(`кодер не принимает кадры захвата напрямую (${direct === 'throw' ? 'исключение' : 'тишина'}): через холст`, async () => {
    const p = page({ direct });
    await p.run(4);
    const v = viewer(p.sent);
    assert.ok(v.canShow);
    assert.ok(v.h264 > 100, `кадров ${v.h264}`);
    assert.ok(p.configs.every((c) => c.hardwareAcceleration === 'prefer-hardware'), 'режим кодера не понижается из-за прямых кадров');
  });
}

test('кодер с задержкой в кадр на неподвижном экране — не поломка: режим не понижается', async () => {
  const p = page({ latency: 1 });
  // Экран почти всё время стоит: кадр, 3 с тишины, и так несколько раз.
  for (let i = 0; i < 4; i++) { await p.run(1 / 60); await p.idle(3); }
  await p.run(1);
  assert.ok(p.configs.every((c) => c.hardwareAcceleration === 'prefer-hardware'), 'остался аппаратный кодер');
  assert.ok(viewer(p.sent).h264 > 30);
});

test('экран крупнее 1920 (2560×1440): кадры уменьшает холст, а не кодер; поток 1920×1080', async () => {
  const behaviour = { size: [2560, 1440] };
  const p = page(behaviour);
  await p.run(1);
  assert.ok(viewer(p.sent).canShow);
  assert.ok(behaviour.fed.length > 30);
  assert.ok(behaviour.fed.every((f) => !f.direct), 'ни одного кадра захвата напрямую в кодер');
  assert.ok(p.configs.every((c) => c.width === 1920 && c.height === 1080));
});

test('SPS/PPS только в первом ключевом кадре: зритель, пришедший позже, всё равно получает их', async () => {
  const p = page({ spsOnce: true });
  await p.run(2);
  const joined = p.sent.length;
  p.viewerJoined();
  await p.run(1);
  const v = viewer(p.sent, joined);
  assert.ok(v.canShow, 'ключевой кадр после входа зрителя несёт SPS и PPS');
});

test('смена монитора (1920×1080 → 1280×720): тот же эфир, новый кодер, первым — ключевой кадр с SPS/PPS', async () => {
  const p = page({});
  await p.run(1);
  const before = p.sent.length, configs = p.configs.length;
  assert.equal(p.replace([1280, 720]), true);
  await p.run(1);
  assert.equal(p.stopped, 0, 'старая дорожка не остановила эфир');
  const fresh = p.configs.slice(configs);
  assert.ok(fresh.length >= 1 && fresh.every((c) => c.width === 1280 && c.height === 720), 'кодер под новый размер');
  const first = Uint8Array.from(p.sent[before]);
  assert.equal(first[0], 3);
  assert.equal(first[1], 1, 'первый пакет после смены — ключевой');
  assert.ok(viewer(p.sent, before).canShow, 'зритель настраивает декодер по нему');
  assert.ok(viewer(p.sent, before).h264 > 50, 'кадры идут дальше');
});

// Окно, в котором пакеты [from, to) ушли: сколько H.264 и JPEG.
const kinds = (sent, from, to = sent.length) => {
  const part = sent.slice(from, to).map((p) => Uint8Array.from(p)[0]);
  return { h264: part.filter((t) => t === 3).length, jpeg: part.filter((t) => t === 1).length };
};

test('аппаратный кодер падает посреди эфира (сброс GPU, 3 с): программный H.264, не JPEG; через 30 с снова аппаратный', async () => {
  const p = page({ outage: [2000, 5000] });
  await p.run(2);
  const before = p.sent.length;
  await p.run(4);
  const during = kinds(p.sent, before);
  assert.equal(during.jpeg, 0, 'ни одного кадра JPEG');
  assert.ok(during.h264 > 60, `видео идёт во время сбоя: ${during.h264}`);
  assert.ok(p.configs.some((c) => c.hardwareAcceleration === 'prefer-software'), 'перешли на программный');
  await p.run(30);
  assert.equal(p.configs.at(-1).hardwareAcceleration, 'prefer-hardware', 'вернулись на аппаратный');
  const back = p.sent.length;
  await p.run(2);
  assert.ok(kinds(p.sent, back).h264 > 100, 'снова 60 кадров/с');
  assert.ok(p.logs.some((l) => /^encoder mode reason=(fail|crash) mode=sw /.test(l)));
  assert.ok(p.logs.some((l) => /^encoder mode reason=retry mode=hw /.test(l)));
});

test('аппаратный кодер падает каждые 10 с: третий сбой за минуту — программный, а не вечные перезапуски', async () => {
  const p = page({ crashEvery: 10_000 });
  await p.run(35);
  assert.ok(p.logs.some((l) => /^encoder mode reason=crash mode=sw /.test(l)), p.logs.filter((l) => l.includes('mode')).join('\n'));
  assert.equal(kinds(p.sent, 0).jpeg, 0);
});

test('ни один кодер временно не создаётся (6 с): JPEG только как мост, затем снова H.264 без перезапуска эфира', async () => {
  const p = page({ outageAll: [2000, 8000] });
  await p.run(2);
  const before = p.sent.length;
  await p.run(6);
  assert.ok(kinds(p.sent, before).jpeg > 0, 'мост JPEG, пока кодеры не создаются');
  await p.run(10);
  const after = p.sent.length;
  await p.run(3);
  const v = kinds(p.sent, after);
  assert.equal(v.jpeg, 0, 'после сбоя JPEG больше нет');
  assert.ok(v.h264 > 60, `видео вернулось: ${v.h264}`);
  await p.run(30);
  assert.equal(p.configs.at(-1).hardwareAcceleration, 'prefer-hardware', 'и аппаратный вернулся');
});

test('смена монитора во время моста JPEG: после возврата H.264 кадры снова из захвата, а не 8 в секунду', async () => {
  const p = page({ outageAll: [2000, 8000] });
  await p.run(4);
  assert.ok(p.logs.some((l) => /^encoder mode reason=fail mode=jpeg /.test(l)), 'идёт мост JPEG');
  assert.equal(p.replace([1280, 720]), true);
  await p.run(16);
  const after = p.sent.length;
  await p.run(3);
  const v = kinds(p.sent, after);
  assert.equal(v.jpeg, 0);
  assert.ok(v.h264 > 60, `видео вернулось с полной частотой: ${v.h264}`);
});

test('H.264 нет вообще (isConfigSupported — нет для обоих): JPEG без повторных попыток кодера', async () => {
  const p = page({ any: false, probe: { hw: false, sw: false } });
  await p.run(1);
  const configs = p.configs.length;
  await p.run(70);
  assert.equal(p.configs.length, configs, 'кодер больше не создаётся');
  assert.ok(viewer(p.sent).jpeg > 400);
  assert.ok(p.logs.some((l) => l.startsWith('encoder probe hw1920x1080=no(unsupported) hw1280x720=no(unsupported) hw3840x2160=no(unsupported) sw1280x720=no(unsupported)')));
  assert.ok(p.logs.some((l) => /^encoder mode reason=nocodec mode=jpeg /.test(l)));
});

test('isConfigSupported: аппаратного нет — сразу программный, без JPEG', async () => {
  const p = page({ hardware: false, probe: { hw: false, sw: true } });
  await p.run(2);
  assert.equal(viewer(p.sent).jpeg, 0);
  assert.ok(p.configs.some((c) => c.hardwareAcceleration === 'prefer-software'));
  assert.ok(p.logs.some((l) => /^encoder probe hw1920x1080=no\(unsupported\) .* sw1280x720=yes/.test(l)));
  assert.ok(p.logs.some((l) => /^encoder mode reason=unsupported mode=sw /.test(l)));
});

test('кодер не успевает (очередь > 2): кадры пропускаются; встал больше чем на 3 с — пересоздаётся, а не молчит вечно', async () => {
  const behaviour = { stuckQueue: true };
  const p = page(behaviour);
  await p.run(1);
  const fed = behaviour.fed.length;
  assert.ok(fed <= 12, `подано до полной очереди ${fed}`);
  await p.run(2);
  assert.equal(behaviour.fed.length, fed, 'пока очередь полна, кадры в кодер не подаются');
  await p.run(61);
  assert.ok(p.logs.some((l) => /^encoder error crash code=stalled /.test(l)), 'вставший кодер замечен');
  const stats = p.logs.filter((l) => l.startsWith('encoder stats'));
  assert.ok(stats.length >= 1 && /queueSkips=[1-9]\d*/.test(stats.at(-1)), stats.at(-1));
});

test('журнал кодера: смена режима, ошибки с кодом, раз в минуту stats — только числа и коды', async () => {
  const p = page({ outage: [2000, 5000] });
  await p.run(125);
  const stats = p.logs.filter((l) => l.startsWith('encoder stats'));
  assert.ok(stats.length >= 2, `stats ${stats.length}`);
  assert.ok(p.logs.some((l) => /^encoder error (crash|fail) code=Error:Encoder_failure /.test(l)));
  for (const line of p.logs) assert.match(line, /^encoder [a-z]+( [a-zA-Z0-9]+(=[A-Za-z0-9().:_,-]*)?)*$/, line);
  assert.ok(stats.every((l) => /queued=\d+ encodeQueue=\d+ .* outFps=\d+$/.test(l)));
});

test('режим видео ведущего: hw → при сбое sw → снова hw (строка «В эфире» и поле video у зрителей)', async () => {
  const p = page({ outage: [2000, 5000] });
  await p.run(1);
  assert.equal(p.videoMode, 'hw');
  await p.run(4);
  assert.equal(p.videoMode, 'sw');
  await p.run(32);
  assert.equal(p.videoMode, 'hw');
});

test('метки у ведущего: приложение не может показать их поверх экрана — схема на странице; может — нет', async () => {
  const p = page({});
  await p.run(1);
  const hidden = p.hostMark({ type: 'ping', x: 0.5, y: 0.5, color: 'red' }, false);
  assert.equal(hidden.shown, 1);
  assert.equal(hidden.box, 'block');
  assert.match(hidden.note, /не умеет скрывать окно меток/);
  const q = page({});
  await q.run(1);
  const onScreen = q.hostMark({ type: 'ping', x: 0.5, y: 0.5, color: 'red' }, true);
  assert.equal(onScreen.shown, 0, 'метки поверх экрана — на странице не дублируются');
});
