// Видео ведущего на странице relay (клиент для Windows и браузер): кодер WebCodecs подменён моделью, и проверяется, что
// зритель (Mac, страница) получает кадры, по которым может начать показ: ключевой H.264 с SPS и PPS или JPEG.
// Модели — поведение кодера Chromium на Windows, при котором зритель Mac висел в «Жду картинку…»: нет аппаратного
// кодера, не создаётся ни один, кадры захвата напрямую не принимаются, SPS/PPS только в первом ключевом кадре.
// Из index.html берутся блок <host-video> и функция startCapture целиком.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync(`${__dirname}/../src/index.html`, 'utf8');
const block = html.slice(html.indexOf('// <host-video>'), html.indexOf('// </host-video>'));
const startAt = html.indexOf('function startCapture(stream, code) {');
const capture = html.slice(startAt, html.indexOf('\nfunction onHostMessage(', startAt));
assert.ok(block.length > 100 && capture.length > 1000, 'метки <host-video> и startCapture на месте');

const NAL = { sps: [0x67, 0x4d, 0x40, 0x32, 0xaa], pps: [0x68, 0xee, 0x3c, 0x80], idr: [0x65, 0x88, 0x84, 0x00], slice: [0x41, 0x9a, 0x02] };
const annexB = (...units) => Uint8Array.from(units.flatMap((u) => [0, 0, 0, 1, ...u]));

// behaviour: { hardware: bool (есть аппаратный кодер), any: bool (создаётся хоть какой-то), direct: 'ok' | 'throw' | 'silent',
//              spsOnce: bool (SPS/PPS только в первом ключевом кадре кодера), syncError: bool (ошибка прямо из configure),
//              latency: число кадров, которые кодер держит, пока не придут следующие }
function page(behaviour) {
  let clock = 0;
  const sent = [], intervals = [], configs = [];
  let wake = null;
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
      configs.push(config);
      const works = behaviour.any !== false && (config.hardwareAcceleration !== 'prefer-hardware' || behaviour.hardware !== false);
      if (works) { this.state = 'configured'; return; }
      const fail = () => { this.state = 'closed'; this.error(new Error('Encoder creation error.')); };
      if (behaviour.syncError) fail(); else Promise.resolve().then(fail);
    }
    encode(frame, { keyFrame }) {
      if (this.state !== 'configured') throw new Error('InvalidStateError');
      const direct = frame.source instanceof VideoFrame;
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
  const element = () => ({ style: {}, textContent: '', title: '', insertAdjacentHTML() {} });
  const elements = {};
  const context = vm.createContext({
    console, Math, Promise, Uint8Array, Infinity,
    performance: { now: () => clock },
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; }, clearInterval() {},
    document: { createElement: (tag) => tag === 'canvas'
      ? { width: 0, height: 0, getContext: () => ({ drawImage() {} }),
          toBlob(done) { done({ arrayBuffer: async () => Uint8Array.from([0xff, 0xd8, 0xff, 0xd9]).buffer }); } }
      : { srcObject: null, muted: false, play() {}, videoWidth: 1920, videoHeight: 1080 } },
    $: (id) => (elements[id] ??= element()),
    status() {}, hostClosed() {}, stopHost() {},
    VideoFrame, VideoEncoder,
    MediaStreamTrackProcessor: class { constructor() { this.readable = { getReader: () => ({
      read: () => new Promise((resolve) => { wake = resolve; }), cancel: async () => {} }) }; } },
  });
  vm.runInContext(`var forceKey = true, watching = false, capture = null, useHelperAudio = false, window = {};
    var hostSocket = { readyState: 1, bufferedAmount: 0, onclose: null, send: (p) => sent.push(p) };
    ${block}\n${capture}`, Object.assign(context, { sent }));
  const track = { onended: null };
  context.startCapture({ getVideoTracks: () => [track], getAudioTracks: () => [] }, '1234567890');
  return {
    sent, configs,
    viewerJoined() { context.forceKey = true; },
    // Кадры захвата 1920×1080 по 60 в секунду: каждый — в цикл чтения страницы, затем все обещания кодера.
    // Захват ничего не присылает (неподвижный экран), часы идут.
    async idle(seconds) { clock += seconds * 1000; await new Promise(setImmediate); },
    async run(seconds) {
      for (let i = 0; i < Math.round(seconds * 60); i++) {
        clock += 1000 / 60;
        for (let k = 0; k < 5 && !wake; k++) await new Promise(setImmediate);
        const resolve = wake; wake = null;
        resolve?.({ value: new VideoFrame(null, { displayWidth: 1920, displayHeight: 1080 }), done: false });
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
    assert.ok(p.configs.some((c) => c.hardwareAcceleration === 'no-preference'));
    assert.ok(p.configs.filter((c) => c.hardwareAcceleration === 'no-preference').every((c) => c.framerate === 30));
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

test('SPS/PPS только в первом ключевом кадре: зритель, пришедший позже, всё равно получает их', async () => {
  const p = page({ spsOnce: true });
  await p.run(2);
  const joined = p.sent.length;
  p.viewerJoined();
  await p.run(1);
  const v = viewer(p.sent, joined);
  assert.ok(v.canShow, 'ключевой кадр после входа зрителя несёт SPS и PPS');
});
