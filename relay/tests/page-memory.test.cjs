// Память долгой трансляции на странице relay (ведущий Windows и браузер, зритель в браузере): медленная сеть, медленный
// JPEG, остановленный звук. Блок <host-video>, startCapture и playPCM берутся из index.html; браузерные API — модели.
// Время модельное: 10 минут трансляции — за доли секунды. Ожидание: очередь и удерживаемые данные выходят на плато,
// а не растут линейно (жалоба: «если трансляцию долго не выключать, память забивается полностью»).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync(`${__dirname}/../src/index.html`, 'utf8');
const block = html.slice(html.indexOf('// <host-video>'), html.indexOf('// </host-video>'));
const startAt = html.indexOf('function startCapture(stream, code) {');
const capture = html.slice(startAt, html.indexOf('\nfunction onHostMessage(', startAt));
const monitors = html.slice(html.indexOf('// <monitor-switch>'), html.indexOf('// </monitor-switch>'));
const pcmAt = html.indexOf('function playPCM(buffer) {');
const playPCM = html.slice(pcmAt, html.indexOf('\n}\n', pcmAt) + 2);
assert.ok(block.length > 100 && capture.length > 1000 && playPCM.length > 100, 'нужные куски index.html на месте');

const NAL = { sps: [0x67, 0x4d, 0x40, 0x32, 0xaa], pps: [0x68, 0xee, 0x3c, 0x80], idr: [0x65, 0x88, 0x84, 0x00], slice: [0x41, 0x9a, 0x02] };
const annexB = (...units) => Uint8Array.from(units.flatMap((u) => [0, 0, 0, 1, ...u]));
const MB = 1024 * 1024;

// Ведущий. options: { drain: байт/с, которые уходят в сеть; size: [w, h]; jpeg: true — нет кодера H.264;
//                     jpegMs: сколько модельных мс кодируется JPEG; helperAudio: звук от помощника mu-audio }
function host(options) {
  let clock = 0;
  const pendingTimers = [];
  let wake = null, jpegFreeAt = 0;
  const stats = { openFrames: 0, maxOpenFrames: 0, blobsInFlight: 0, maxBlobsInFlight: 0, sentBytes: 0, audioSent: 0, audioOffered: 0 };
  class VideoFrame {
    constructor(source, init = {}) {
      this.source = source; this.timestamp = init.timestamp;
      this.displayWidth = init.displayWidth ?? source?.displayWidth ?? source?.width ?? 0;
      this.displayHeight = init.displayHeight ?? source?.displayHeight ?? source?.height ?? 0;
      stats.openFrames++; stats.maxOpenFrames = Math.max(stats.maxOpenFrames, stats.openFrames);
      this.open = true;
    }
    close() { if (this.open) { this.open = false; stats.openFrames--; } }
  }
  class VideoEncoder {
    constructor({ output }) { this.output = output; this.state = 'unconfigured'; this.encodeQueueSize = 0; }
    configure() { if (options.jpeg) throw new Error('NotSupportedError'); this.state = 'configured'; }
    encode(frame, { keyFrame }) {
      // Видео ~6 Мбит/с при 60 кадрах/с: ключевой крупнее.
      const size = keyFrame ? 60_000 : 12_000;
      const data = keyFrame ? annexB(NAL.sps, NAL.pps, NAL.idr) : annexB(NAL.slice);
      const chunk = { type: keyFrame ? 'key' : 'delta', byteLength: size, copyTo: (to) => to.set(data) };
      Promise.resolve().then(() => this.state === 'configured' && this.output(chunk));
    }
    close() { this.state = 'closed'; }
  }
  const socket = {
    readyState: 1, queued: 0, onclose: null,
    get bufferedAmount() { return this.queued; },
    send(packet) {
      const size = packet.byteLength ?? packet.length;
      this.queued += size; stats.sentBytes += size;
      if ((packet[0] ?? new Uint8Array(packet)[0]) === 2) stats.audioSent++;
    },
  };
  let audioCallback = null;
  const element = () => ({ style: {}, textContent: '', title: '', insertAdjacentHTML() {} });
  const elements = {};
  const context = vm.createContext({
    console: { ...console, info() {} }, Math, Promise, Uint8Array, DataView, ArrayBuffer, Infinity,
    performance: { now: () => clock },
    setInterval: () => 0, clearInterval() {},
    document: { createElement: (tag) => tag === 'canvas'
      ? { width: 0, height: 0, getContext: () => ({ drawImage() {} }),
          // JPEG кодируется `jpegMs` модельных мс, по одному за раз (как асинхронное кодирование холста в Chromium),
          // и держит снимок холста, пока не ответит.
          toBlob(done) {
            stats.blobsInFlight++; stats.maxBlobsInFlight = Math.max(stats.maxBlobsInFlight, stats.blobsInFlight);
            jpegFreeAt = Math.max(jpegFreeAt, clock) + (options.jpegMs ?? 20);
            pendingTimers.push({ at: jpegFreeAt, run: () => {
              stats.blobsInFlight--;
              done({ arrayBuffer: async () => new Uint8Array(150_000).buffer });
            } });
          } }
      : { srcObject: null, muted: false, play() {}, videoWidth: 1920, videoHeight: 1080 } },
    $: (id) => (elements[id] ??= element()),
    status() {}, hostClosed() {}, stopHost() {},
    MediaStream: class { constructor(tracks) { this.tracks = tracks; } },
    VideoFrame, VideoEncoder,
    MediaStreamTrackProcessor: class { constructor() { this.readable = { getReader: () => ({
      read: () => new Promise((resolve) => { wake = resolve; }), cancel: async () => {} }) }; } },
  });
  vm.runInContext(`var forceKey = true, watching = false, capture = null, useHelperAudio = ${!!options.helperAudio};
    var window = { mu: { setMuted() {}, startAudio(cb) { audioCallbackSink(cb); } } };
    var hostSocket = socketSink;
    ${block}\n${monitors}\n${capture}`, Object.assign(context, { socketSink: socket, audioCallbackSink: (cb) => { audioCallback = cb; } }));
  const track = { onended: null, stop() {} };
  const stream = { tracks: [track], getVideoTracks() { return this.tracks; }, getAudioTracks: () => [] };
  context.startCapture(stream, '1234567890');
  return {
    socket, stats,
    // `seconds` модельных секунд: захват 60 кадров/с, звук помощника — 0,1 с каждые 6 кадров, сеть уносит `drain` байт/с.
    async run(seconds) {
      const [width, height] = options.size ?? [1920, 1080];
      for (let i = 0; i < Math.round(seconds * 60); i++) {
        clock += 1000 / 60;
        socket.queued = Math.max(0, socket.queued - (options.drain ?? 1e9) / 60);
        for (const timer of pendingTimers.filter((t) => t.at <= clock)) { pendingTimers.splice(pendingTimers.indexOf(timer), 1); timer.run(); }
        if (audioCallback && i % 6 === 0) { stats.audioOffered++; audioCallback(new Uint8Array(4_800)); }
        for (let k = 0; k < 5 && !wake; k++) await new Promise(setImmediate);
        const resolve = wake; wake = null;
        resolve?.({ value: new VideoFrame(null, { displayWidth: width, displayHeight: height }), done: false });
        await new Promise(setImmediate);
      }
    },
  };
}

test('медленная сеть, звук от помощника: очередь сокета не растёт без предела (10 мин, сеть 20 КБ/с)', async () => {
  const h = host({ drain: 20_000, helperAudio: true });
  await h.run(600);
  console.log(`  ведущий, медленная сеть: в очереди сокета ${(h.socket.bufferedAmount / MB).toFixed(1)} МБ, звук ушёл ${h.stats.audioSent} из ${h.stats.audioOffered}`);
  assert.ok(h.socket.bufferedAmount < 2 * MB, `очередь ${h.socket.bufferedAmount} байт`);
  assert.ok(h.stats.audioSent > 0, 'звук идёт, пока сеть успевает');
});

test('хорошая сеть: звук помощника не отбрасывается', async () => {
  const h = host({ drain: 2_000_000, helperAudio: true });
  await h.run(30);
  assert.equal(h.stats.audioSent, h.stats.audioOffered);
});

test('JPEG (нет кодера H.264), медленное кодирование: снимков холста в работе — не больше одного', async () => {
  const h = host({ jpeg: true, jpegMs: 400, size: [3840, 2160] });
  await h.run(60);
  console.log(`  ведущий, JPEG: одновременно кодировалось до ${h.stats.maxBlobsInFlight} снимков холста`);
  assert.ok(h.stats.maxBlobsInFlight <= 1, `одновременно ${h.stats.maxBlobsInFlight}`);
});

test('экран 3840×2160: кадры VideoFrame закрываются, открытых не больше трёх', async () => {
  const h = host({ size: [3840, 2160] });
  await h.run(60);
  assert.ok(h.stats.maxOpenFrames <= 3, `открытых до ${h.stats.maxOpenFrames}`);
});

// Зритель в браузере: страницу открыли по ссылке без действия пользователя — AudioContext остановлен, время стоит.
function viewerAudio(state) {
  const live = new Set();
  let resumed = 0;
  class AudioContext {
    constructor() { this.state = state; this.currentTime = 0; this.destination = {}; }
    resume() { resumed++; return Promise.resolve(); }
    createBuffer(channels, length, rate) { const data = new Float32Array(length); return { duration: length / rate, getChannelData: () => data }; }
    createBufferSource() {
      const node = { connect() {}, start() { live.add(node); }, onended: null };
      return node;
    }
  }
  const context = vm.createContext({ Int16Array, Float32Array, AudioContext });
  vm.runInContext(`var audio = null, playAt = 0;\n${playPCM}`, context);
  return { context, live, get resumed() { return resumed; } };
}

test('зритель в браузере, звук остановлен (нет жеста пользователя): куски не копятся', () => {
  const v = viewerAudio('suspended');
  for (let i = 0; i < 6_000; i++) v.context.playPCM(new Int16Array(2_400).buffer);   // 10 минут
  console.log(`  зритель, остановленный звук: запланировано ${v.live.size} кусков`);
  assert.ok(v.live.size <= 15, `запланировано ${v.live.size}`);
  assert.ok(v.resumed > 0, 'страница пытается запустить звук');
});

test('зритель в браузере, звук играет: куски планируются', () => {
  const v = viewerAudio('running');
  for (let i = 0; i < 10; i++) v.context.playPCM(new Int16Array(2_400).buffer);
  assert.equal(v.live.size, 10);
});
