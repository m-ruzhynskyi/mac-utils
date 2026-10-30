// Метки зрителей у ведущего на Windows: куда на экране (в физических пикселях) попадает точка, которую зритель
// поставил на кадре. main.js грузится целиком с подменённым Electron: мониторы с масштабом Windows (DIP и физические
// пиксели), помощник (track, place, protect), окно меток с его настоящей физической рамкой и DPI. Ожидание: точка
// (доля кадра) попадает в ту же долю транслируемой области — при любом devicePixelRatio страницы меток.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const Module = require("node:module");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");
const { EventEmitter } = require("node:events");

const MAIN = process.env.MAIN_JS || path.join(__dirname, "..", "main.js");
// Перепроверка исключения из захвата в тестах — раз в 300 мс вместо 15 с.
const VERIFY_MS = 300;
process.env.MU_OVERLAY_VERIFY_MS = String(VERIFY_MS);
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
// IPC от страницы ретранслятора: main сверяет адрес кадра-отправителя (guard.fromRelay).
const RELAY_FRAME = { url: "https://mac-utils-relay.mako-62d.workers.dev/" };
const page = (extra = {}) => ({ senderFrame: RELAY_FRAME, ...extra });
const OVERLAY_FRAME = { url: require("node:url").pathToFileURL(path.join(path.dirname(MAIN), "overlay.html")).href };

// Монитор: DIP-границы (как у Electron), масштаб и физическая рамка.
const monitor = (id, phys, scale, dipOrigin, primary = false, dipSize = null) => ({
  id, scaleFactor: scale, primary, phys,
  bounds: { x: dipOrigin[0], y: dipOrigin[1], width: dipSize ? dipSize[0] : Math.round(phys.width / scale), height: dipSize ? dipSize[1] : Math.round(phys.height / scale) },
});
const toPhys = (d, x, y) => [d.phys.x + (x - d.bounds.x) * d.scaleFactor, d.phys.y + (y - d.bounds.y) * d.scaleFactor];
const contains = (r, x, y) => x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;
const overlap = (a, b) => Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x)) *
  Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y));

function electron(world) {
  const ipc = new Map(), handles = new Map(), screenEvents = new EventEmitter(), permissions = {};
  let displayMedia = null;
  const windows = [];
  let nextHwnd = 0x10000;
  class BrowserWindow extends EventEmitter {
    constructor(opts) {
      super();
      this.opts = opts;
      this.bounds = { x: opts.x ?? 0, y: opts.y ?? 0, width: opts.width ?? 800, height: opts.height ?? 600 };
      // Windows: скрытое окно, созданное на мониторе с другим масштабом, живёт с DPI основного (world.createScale) —
      // физически оно больше монитора (журнал ведущей: 3363x1890 вместо 1920x1080).
      const at = world.displays.find((d) => contains(d.bounds, this.bounds.x, this.bounds.y)) || world.displays[0];
      this.scale = world.createScale ?? at.scaleFactor;
      const [px, py] = toPhys(at, this.bounds.x, this.bounds.y);
      this.phys = { x: Math.round(px), y: Math.round(py), width: Math.round(this.bounds.width * this.scale), height: Math.round(this.bounds.height * this.scale) };
      this.hwnd = String(nextHwnd++);
      this.affinity = 0; this.ignoring = false;
      this.sent = []; this.calls = []; this.visible = opts.show !== false; this.destroyed = false;
      const self = this;
      this.webContents = Object.assign(new EventEmitter(), {
        send(channel, data) {
          if (!self.loaded) return;
          self.sent.push([channel, data === undefined ? undefined : JSON.parse(JSON.stringify(data))]);
          if (channel === "region") self.region = data;
          if (channel === "mark" && world.report !== false) self.reportMark(data);
        },
        setWindowOpenHandler(fn) { self.openHandler = fn; },
      });
      windows.push(this);
    }
    // Страница меток: её окно — физическая рамка / DPR (как innerWidth у Chromium), область — доли окна (overlay.html).
    get page() { return { w: Math.round(this.phys.width / this.scale), h: Math.round(this.phys.height / this.scale), dpr: this.scale }; }
    reportMark(mark) {
      const page = this.page, place = require("../overlay-place");
      const area = place.areaIn(this.region || { fx: 0, fy: 0, fw: 1, fh: 1 }, page.w, page.h);
      const first = mark.type === "ping" ? [mark.x, mark.y] : mark.points[0];
      ipc.get("overlay-report")?.({ sender: this.webContents, senderFrame: OVERLAY_FRAME }, { mark: first, point: place.markPoint(first, area), area, region: this.region,
        innerWidth: page.w, innerHeight: page.h, dpr: page.dpr });
    }
    setBounds(b) { this.calls.push("setBounds"); this.bounds = { ...b }; const d = world.displays.find((m) => contains(m.bounds, b.x, b.y)) || world.displays[0];
      const [x, y] = toPhys(d, b.x, b.y); this.scale = d.scaleFactor;
      this.phys = { x: Math.round(x), y: Math.round(y), width: Math.round(b.width * d.scaleFactor), height: Math.round(b.height * d.scaleFactor) }; }
    static getAllWindows() { return windows.filter((w) => !w.destroyed); }
    getMediaSourceId() { return `window:${this.hwnd}:0`; }
    getNativeWindowHandle() { const b = Buffer.alloc(8); b.writeBigUInt64LE(BigInt(this.hwnd)); return b; }
    // Electron считает DIP окна по его DPI, а не по монитору (журнал: overlay=-1098,… вместо -1920,…).
    getBounds() { return { x: Math.round(this.phys.x / this.scale), y: Math.round(this.phys.y / this.scale), width: this.page.w, height: this.page.h }; }
    getContentBounds() { return this.getBounds(); }
    loadFile() { setImmediate(() => { this.loaded = true; this.webContents.emit("did-finish-load"); }); }
    loadURL() { this.loaded = true; return Promise.resolve(); }
    showInactive() { this.visible = true; if (world.protectionLostOnShow) this.affinity = 0; this.calls.push("show"); }
    // world.layeredBlocks: защита, заданная после setIgnoreMouseEvents(true), не встаёт (проверка второго порядка).
    // world.oldWindows: Windows 10 до 2004 — WDA_EXCLUDEFROMCAPTURE встаёт как WDA_MONITOR (0x1, в захвате чёрное).
    setContentProtection(on) { this.calls.push(`protect:${on}`); if (!(world.layeredBlocks && this.ignoring)) this.affinity = on && !world.protectFails ? (world.oldWindows ? 0x1 : 0x11) : 0; }
    setIgnoreMouseEvents(on) { this.ignoring = on; this.calls.push(`ignore:${on}`); }
    show() { this.visible = true; }
    hide() { this.visible = false; }
    close() { if (this.destroyed) return; this.destroyed = true; this.emit("closed"); }
    isDestroyed() { return this.destroyed; }
    isMinimized() { return !!this.minimized; }
    setAlwaysOnTop() {} flashFrame() {} focus() {} restore() {}
  }
  // Помощник: place — SetWindowPos в физических пикселях; переезд на монитор с другим DPI в первый раз даёт размер по
  // новому DPI (WM_DPICHANGED), второй раз встаёт как просили. protect — что стоит на окне (своё SetWindowDisplayAffinity
  // для чужого окна Windows отклоняет: err=5).
  function helper(args, done) {
    const [command, hwnd, ...rest] = args;
    const win = windows.find((w) => w.hwnd === hwnd && !w.destroyed);
    helperCalls.push(args);
    if (!win) return setImmediate(() => done(new Error("no window"), ""));
    // world.helperBroken: помощник старой версии или упал — place/protect не отвечают.
    if (world.helperBroken) return setImmediate(() => done(new Error("exit 2"), ""));
    if (command === "place" && world.placeDenied) {
      // Отказ Windows (UIPI: помощник без повышенных прав): окно не сдвинулось, помощник читает, где оно.
      return setImmediate(() => done(null, `${win.phys.x} ${win.phys.y} ${win.phys.width} ${win.phys.height} ${Math.round(96 * win.scale)}\n`));
    }
    if (command === "place") {
      const [x, y, width, height] = rest.map(Number);
      // world.driftAfterPlace: Chromium каждый раз меняет рамку уже после ответа помощника (и сообщает resize).
      // world.badPlace: на этом по счёту place помощник видит окно на 1 px уже (рамку тут же снова поменял Chromium).
      if (world.badPlace === helperCalls.filter(([c]) => c === "place").length) {
        win.phys = { x, y, width: width - 1, height };
        return setImmediate(() => done(null, `${x} ${y} ${width - 1} ${height} ${Math.round(96 * win.scale)}\n`));
      }
      if (world.driftAfterPlace) setTimeout(() => { win.phys = { ...win.phys, width: win.phys.width + 7 }; win.emit("resize"); }, 5);
      const to = world.displays.find((d) => contains(d.phys, x, y));
      const k = to && to.scaleFactor !== win.scale ? to.scaleFactor / win.scale : 1;
      // world.clampHeight: система ужимает окно до рабочей области (без панели задач): монитор 1080 → 1040.
      win.phys = { x, y, width: Math.round(width * k), height: Math.min(Math.round(height * k), world.clampHeight ?? Infinity) };
      if (to) win.scale = to.scaleFactor;
      return setImmediate(() => done(null, `${win.phys.x} ${win.phys.y} ${win.phys.width} ${win.phys.height} ${Math.round(96 * win.scale)}\n`));
    }
    if (command === "protect") return setImmediate(() => done(null, `affinity=0x${win.affinity.toString(16)} err=5 exstyle=0x80088\n`));
    setImmediate(() => done(new Error("unknown"), ""));
  }
  const helperCalls = [];
  const screen = Object.assign(screenEvents, {
    getAllDisplays: () => world.displays,
    getPrimaryDisplay: () => world.displays.find((d) => d.primary),
    getDisplayMatching: (r) => [...world.displays].sort((a, b) => overlap(b.bounds, r) - overlap(a.bounds, r))[0],
    dipToScreenRect: (_w, r) => {
      const d = [...world.displays].sort((a, b) => overlap(b.bounds, r) - overlap(a.bounds, r))[0];
      // Границы монитора целиком — его физическая рамка (журнал ведущей: capture совпал с монитором).
      if (r.x === d.bounds.x && r.y === d.bounds.y && r.width === d.bounds.width && r.height === d.bounds.height) return { ...d.phys };
      const [x, y] = toPhys(d, r.x, r.y);
      return { x: Math.round(x), y: Math.round(y), width: Math.round(r.width * d.scaleFactor), height: Math.round(r.height * d.scaleFactor) };
    },
    dipToScreenPoint: (pt) => {
      const d = world.displays.find((m) => contains(m.bounds, pt.x, pt.y)) || world.displays[0];
      const [x, y] = toPhys(d, pt.x, pt.y);
      return { x: Math.round(x), y: Math.round(y) };
    },
    screenToDipRect: (_w, r) => {
      const d = [...world.displays].sort((a, b) => overlap(b.phys, r) - overlap(a.phys, r))[0];
      return { x: Math.round(d.bounds.x + (r.x - d.phys.x) / d.scaleFactor), y: Math.round(d.bounds.y + (r.y - d.phys.y) / d.scaleFactor),
               width: Math.round(r.width / d.scaleFactor), height: Math.round(r.height / d.scaleFactor) };
    },
  });
  return {
    windows, ipc, handles, helper, helperCalls, permissions, get displayMedia() { return displayMedia; },
    module: {
      app: { requestSingleInstanceLock: () => true, quit() { world.quits = (world.quits || 0) + 1; }, whenReady: () => Promise.resolve(),
             on: (name, fn) => { (world.appEvents ||= {})[name] = fn; }, isPackaged: false,
             getVersion: () => "1.1.0", getPath: () => world.logs,
             getGPUInfo: async (kind) => (world.gpu ? world.gpu[kind] : {}), getGPUFeatureStatus: () => world.gpu?.status || {},
             commandLine: { hasSwitch: (f) => !!world.gpu?.switches?.[f], getSwitchValue: (f) => world.gpu?.switches?.[f] || "" } },
      BrowserWindow, screen,
      clipboard: { writeText: (text) => (world.clipboardFails ? Promise.reject(new Error("busy")) : Promise.resolve(void (world.clipboardText = text))) },
      desktopCapturer: { getSources: async () => world.sources },
      ipcMain: { on: (name, fn) => ipc.set(name, fn), handle: (name, fn) => handles.set(name, fn) },
      session: { defaultSession: { webRequest: { onBeforeSendHeaders() {} }, setDisplayMediaRequestHandler: (fn) => { displayMedia = fn; },
        setPermissionRequestHandler: (fn) => { permissions.request = fn; }, setPermissionCheckHandler: (fn) => { permissions.check = fn; } } },
      dialog: { showMessageBox: async (...args) => { world.dialogs = (world.dialogs || 0) + 1; return { response: 1 }; } },
      shell: { openExternal: (url) => { (world.opened ||= []).push(url); return Promise.resolve(); } },
    },
  };
}

// Загрузить main.js с этим «Windows»: Electron, electron-updater, помощник (spawn) и его наличие (fs.existsSync).
async function start(world) {
  const fake = electron(world);
  const trackers = [], spawned = [], updater = new Map();
  const childProcess = { ...require("node:child_process"), spawn: (file, args) => {
    spawned.push(args);
    const child = Object.assign(new EventEmitter(), { stdout: new EventEmitter(), kill() {} });
    trackers.push(child); return child;
  }, execFile: (_file, args, _opts, done) => fake.helper(args, done) };
  const realFs = require("node:fs");
  const fakeFs = { ...realFs, existsSync: (p) => (String(p).endsWith("mu-audio.exe") ? world.helper !== false : realFs.existsSync(p)) };
  const load = Module._load, intervals = [], realInterval = global.setInterval;
  Module._load = function (request, ...rest) {
    if (request === "electron") return fake.module;
    if (request === "electron-updater") return { autoUpdater: { on: (name, fn) => updater.set(name, fn), checkForUpdates: async () => {} } };
    if (request === "child_process") return childProcess;
    if (request === "fs") return fakeFs;
    if (request === "./remote" && world.remote) return world.remote;
    return load.call(this, request, ...rest);
  };
  global.setInterval = (...args) => { const id = realInterval(...args); intervals.push(id); return id; };
  try {
    delete require.cache[require.resolve(MAIN)];
    for (const key of Object.keys(require.cache)) if (key.endsWith("overlay-place.js")) delete require.cache[key];
    require(MAIN);
    await tick();
  } finally { Module._load = load; global.setInterval = realInterval; }
  const host = {
    fake, trackers, spawned, updater,
    stop() { intervals.forEach(clearInterval); },
    // Клик ведущего в главном окне (input-event видит только main).
    click() { this.main.webContents.emit("input-event", {}, { type: "mouseUp" }); },
    // Ведущий нажал «Транслировать» (список источников) и кликнул по плитке (choose).
    async choose(sourceId, ...rest) {
      this.click();
      await fake.handles.get("sources")(page());
      this.click();
      return fake.handles.get("choose")(page(), sourceId, ...rest);
    },
    // getDisplayMedia страницы так, как его проводит Electron 44 (shell/browser/web_contents_permission_helper.cc):
    // сначала обработчик разрешений — "media" с ПУСТЫМ mediaTypes (захват экрана — не микрофон и не камера); отказ там —
    // NotAllowedError «Permission denied». Потом setDisplayMediaRequestHandler; отказ (null) — AbortError.
    getDisplayMedia(request = {}) {
      const origin = request.securityOrigin ?? RELAY_FRAME.url;
      let allowed, streams;
      fake.permissions.request(this.main.webContents, "media", (ok) => { allowed = ok; }, { mediaTypes: [], requestingUrl: origin, securityOrigin: origin, isMainFrame: true });
      if (allowed !== true) return { error: "NotAllowedError" };
      fake.displayMedia({ audioRequested: false, securityOrigin: origin, ...request }, (s) => { streams = s; });
      return streams ? { streams } : { error: "AbortError" };
    },
    // Ведущий выбрал источник и страница начала захват.
    async share(sourceId) {
      await this.choose(sourceId, false, []);
      const got = this.getDisplayMedia();
      assert.ok(got.streams, `захват после выбора: ${got.error}`);
      await tick();
    },
    track(rect) { trackers.at(-1).stdout.emit("data", Buffer.from(`${rect.x} ${rect.y} ${rect.width} ${rect.height}\n`)); },
    mark(x, y) { fake.ipc.get("mark")(page(), { type: "ping", x, y, color: "red" }); },
    get overlay() { return fake.windows.find((w) => w.opts.transparent && !w.destroyed); },
    markLog() {
      const file = path.join(world.logs, "overlay.log");
      return fs.existsSync(file) ? fs.readFileSync(file, "utf8").split("\n").filter((l) => / mark /.test(l)) : [];
    },
    // Куда легла последняя метка: точка на холсте страницы меток (как в overlay.html) → физические пиксели экрана
    // по настоящей рамке окна меток и его DPR.
    landed() {
      const o = this.overlay;
      const mark = o.sent.filter(([c]) => c === "mark").at(-1)?.[1];
      if (!mark) return null;
      const region = o.sent.filter(([c]) => c === "region").at(-1)?.[1] || { fx: 0, fy: 0, fw: 1, fh: 1 };
      const page = o.page, place = require("../overlay-place");
      const [cx, cy] = place.markPoint([mark.x, mark.y], place.areaIn(region, page.w, page.h));
      return [Math.round(o.phys.x + cx * page.dpr), Math.round(o.phys.y + cy * page.dpr)];
    },
    log() { const file = path.join(world.logs, "overlay.log"); return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : ""; },
    marksSent() { return this.overlay.sent.filter(([c]) => c === "mark").length; },
    // Что приложение сказало странице о метках (последнее marks-state главному окну).
    marksState() { const m = this.lastMarksState(); return m && { screen: m.screen, inVideo: m.inVideo, reason: m.reason }; },
    lastMarksState() { return fake.windows.find((x) => !x.opts.transparent).sent.filter(([c]) => c === "marks-state").at(-1)?.[1]; },
    get main() { return fake.windows.find((x) => !x.opts.transparent); },
    places() { return fake.helperCalls.filter(([c]) => c === "place").map((a) => a.slice(2).map(Number)); },
  };
  return host;
}

function world(displays, sources, extra = {}) {
  return { displays, sources, logs: fs.mkdtempSync(path.join(os.tmpdir(), "overlay-")), ...extra };
}
const expected = (phys, x, y) => [Math.round(phys.x + x * phys.width), Math.round(phys.y + y * phys.height)];
const near = (got, want, what) => {
  assert.ok(got, `${what}: метка не показана`);
  assert.ok(Math.abs(got[0] - want[0]) <= 3 && Math.abs(got[1] - want[1]) <= 3, `${what}: метка в ${got}, а должна быть в ${want}`);
};

// Ноутбук 2560×1600 при 150 % (основной) и монитор 1920×1080 при 100 % слева (отрицательные координаты).
const laptop = () => monitor(1, { x: 0, y: 0, width: 2560, height: 1600 }, 1.5, [0, 0], true);
const external = () => monitor(2, { x: -1920, y: 200, width: 1920, height: 1080 }, 1, [-1920, 133]);
const screenSource = (d, n) => ({ id: `screen:${n}:0`, name: `Screen ${n}`, display_id: String(d.id) });
const windowSource = { id: "window:123456:0", name: "Editor", display_id: "" };

test("один монитор 125 %, весь экран: метка, пришедшая сразу после начала, не теряется и в своей точке", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1.25, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)]));
  try {
    await host.share("screen:1:0");
    host.mark(0.3, 0.25);
    await tick(80);
    near(host.landed(), expected(d.phys, 0.3, 0.25), "125 %");
  } finally { host.stop(); }
});

test("второй монитор слева (100 % при основном 150 %): метки на нём, а не на основном", async () => {
  const a = laptop(), b = external();
  const host = await start(world([a, b], [screenSource(a, 1), screenSource(b, 2)]));
  try {
    await host.share("screen:2:0");
    await tick(80);
    host.mark(0.8, 0.6);
    await tick(80);
    near(host.landed(), expected(b.phys, 0.8, 0.6), "второй монитор");
  } finally { host.stop(); }
});

test("окно: метка до первой строки помощника ждёт её и ложится на окно, а не на весь экран", async () => {
  const a = laptop();
  const host = await start(world([a], [windowSource]));
  try {
    await host.share(windowSource.id);
    host.mark(0.5, 0.5);
    await tick(20);
    const rect = { x: 300, y: 240, width: 1200, height: 900 };
    host.track(rect);
    await tick(80);
    near(host.landed(), expected(rect, 0.5, 0.5), "окно");
  } finally { host.stop(); }
});

test("окно на мониторе с другим масштабом: метка на окне", async () => {
  const a = laptop(), b = external();
  const host = await start(world([a, b], [windowSource]));
  try {
    await host.share(windowSource.id);
    const rect = { x: -1700, y: 400, width: 1000, height: 700 };
    host.track(rect);
    await tick(80);
    host.mark(0.1, 0.9);
    await tick(20);
    near(host.landed(), expected(rect, 0.1, 0.9), "окно на втором мониторе");
  } finally { host.stop(); }
});

test("смена масштаба Windows во время трансляции окна (125 % → 150 %): метка на окне", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 2560, height: 1440 }, 1.25, [0, 0], true);
  const w = world([d], [windowSource]);
  const host = await start(w);
  try {
    await host.share(windowSource.id);
    const rect = { x: 400, y: 300, width: 1600, height: 900 };
    host.track(rect);
    await tick(80);
    w.displays = [monitor(7, d.phys, 1.5, [0, 0], true)];
    host.fake.module.screen.emit("display-metrics-changed");
    await tick(80);
    host.mark(0.75, 0.2);
    await tick(20);
    near(host.landed(), expected(rect, 0.75, 0.2), "после смены масштаба");
  } finally { host.stop(); }
});

const pairOf = (line, key) => new RegExp(` ${key}=([-0-9.]+);([-0-9.]+)`).exec(line).slice(1).map(Number);

// Раскладка ведущей из журнала: A 1920x1080 @1 слева, B 2195x1235 DIP @1,75 основной, C 1920x1080 @1 справа.
const layoutA = () => monitor(11, { x: -1920, y: 435, width: 1920, height: 1080 }, 1, [-1920, 248]);
const layoutB = () => monitor(12, { x: 0, y: 0, width: 3840, height: 2160 }, 1.75, [0, 0], true, [2195, 1235]);
const layoutC = () => monitor(13, { x: 3840, y: 452, width: 1920, height: 1080 }, 1, [2195, 258]);
const P = [0.3972, 0.4159];

for (const createScale of [1, 1.25, 1.75]) {
  test(`раскладка ведущей, экран A: p=(0,3972; 0,4159) — в той же доле окна меток (страница @${createScale})`, async () => {
    const a = layoutA(), b = layoutB(), c = layoutC();
    const host = await start(world([a, b, c], [screenSource(a, 1), screenSource(b, 2), screenSource(c, 3)], { createScale }));
    try {
      await host.share("screen:1:0");
      host.mark(...P);
      await tick(80);
      const o = host.overlay;
      assert.deepEqual(o.phys, a.phys, "окно меток ровно на физической рамке монитора A");
      assert.deepEqual(o.sent.filter(([c]) => c === "region").at(-1)[1], { fx: 0, fy: 0, fw: 1, fh: 1 });
      const got = host.landed();
      near(got, expected(a.phys, ...P), "экран A");
      const share = [(got[0] - o.phys.x) / o.phys.width, (got[1] - o.phys.y) / o.phys.height];
      assert.ok(Math.abs(share[0] - P[0]) < 0.002 && Math.abs(share[1] - P[1]) < 0.002, `доля окна меток ${share}`);
      assert.ok(o.opts.enableLargerThanScreen, "окно больше рабочей области не обрезается");
      const [line] = host.markLog();
      assert.deepEqual(pairOf(line, "p"), P);
      const q = pairOf(line, "q");
      assert.ok(Math.abs(q[0] - P[0]) < 0.002 && Math.abs(q[1] - P[1]) < 0.002, `q=${q}`);
      assert.match(line, / capture=-1920,435,1920x1080 monitor=-1920,435,1920x1080 phys=-1920,435,1920x1080@96 fr=0;0;1;1 /);
      assert.match(line, / affinity=0x11 order=1$/);
      assert.doesNotMatch(line, /protected=/);
      assert.doesNotMatch(line, /\d{3,} \d{3,}/, "в строке только поля «ключ=числа»");
    } finally { host.stop(); }
  });
}

test("раскладка ведущей, окно на B @1,75: метка в доле окна", async () => {
  const a = layoutA(), b = layoutB(), c = layoutC();
  const host = await start(world([a, b, c], [windowSource]));
  try {
    await host.share(windowSource.id);
    const rect = { x: 812, y: 301, width: 2207, height: 1333 };
    host.track(rect);
    await tick(20);
    host.mark(...P);
    await tick(80);
    assert.deepEqual(host.overlay.phys, b.phys);
    near(host.landed(), expected(rect, ...P), "окно на B");
    const f = host.overlay.sent.filter(([c]) => c === "region").at(-1)[1];
    assert.ok(Math.abs(f.fx - 812 / 3840) < 1e-9 && Math.abs(f.fh - 1333 / 2160) < 1e-9, JSON.stringify(f));
  } finally { host.stop(); }
});

test("раскладка ведущей: окно перешло с B на C — окно меток переставлено на C, метка на окне", async () => {
  const a = layoutA(), b = layoutB(), c = layoutC();
  const host = await start(world([a, b, c], [windowSource]));
  try {
    await host.share(windowSource.id);
    host.track({ x: 812, y: 301, width: 2207, height: 1333 });
    host.mark(0.5, 0.5);
    await tick(80);
    const moved = { x: 4100, y: 600, width: 1200, height: 700 };
    host.track(moved);
    await tick(80);
    host.mark(...P);
    await tick(80);
    assert.deepEqual(host.overlay.phys, c.phys, "окно меток на физической рамке C");
    assert.deepEqual(host.places().at(-1), [c.phys.x, c.phys.y, c.phys.width, c.phys.height]);
    near(host.landed(), expected(moved, ...P), "окно на C");
  } finally { host.stop(); }
});

test("переезд окна меток на монитор с другим DPI: ответ помощника сверяется, вторая попытка встаёт", async () => {
  const a = layoutA(), b = layoutB(), c = layoutC();
  const host = await start(world([a, b, c], [screenSource(a, 1)], { createScale: 1.75 }));
  try {
    await host.share("screen:1:0");
    host.mark(...P);
    await tick(80);
    const want = [a.phys.x, a.phys.y, a.phys.width, a.phys.height];
    assert.deepEqual(host.places(), [want, want], "первый раз — размер по новому DPI, второй — как просили");
    assert.deepEqual(host.overlay.phys, a.phys);
  } finally { host.stop(); }
});

test("одна метка от страницы — одна метка в окне меток и одна строка журнала (без дублей)", async () => {
  const a = layoutA(), b = layoutB();
  const host = await start(world([a, b], [screenSource(a, 1)]));
  try {
    await host.share("screen:1:0");
    host.mark(...P);
    await tick(80);
    host.mark(0.1, 0.2);
    await tick(80);
    assert.equal(host.marksSent(), 2);
    assert.equal(host.markLog().length, 2);
  } finally { host.stop(); }
});

test("исключение из захвата ставится после показа и setIgnoreMouseEvents; фактическое значение — в журнале", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1.25, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)], { protectionLostOnShow: true }));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(80);
    const calls = host.overlay.calls;
    assert.ok(calls.lastIndexOf("protect:true") > calls.indexOf("show"), `порядок: ${calls}`);
    assert.ok(calls.lastIndexOf("protect:true") > calls.lastIndexOf("ignore:true"), `порядок: ${calls}`);
    assert.equal(host.overlay.affinity, 0x11);
    assert.match(host.markLog()[0], / affinity=0x11 order=1$/);
  } finally { host.stop(); }
});

test("защита не встала после setIgnoreMouseEvents — второй порядок: защита до него", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1.25, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)], { layeredBlocks: true }));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(80);
    const calls = host.overlay.calls;
    assert.equal(host.overlay.affinity, 0x11);
    assert.equal(calls.at(-1), "ignore:true", `клики сквозь окно остаются: ${calls}`);
    assert.match(host.markLog()[0], / affinity=0x11 order=2$/);
  } finally { host.stop(); }
});

test("помощник не ответил на place и protect: метки не застревают, в журнале — что не подтвердилось", async () => {
  const a = layoutA(), b = layoutB();
  const host = await start(world([a, b], [screenSource(a, 1)], { helperBroken: true }));
  try {
    await host.share("screen:1:0");
    host.mark(...P);
    await tick(80);
    // Исключение из захвата не подтвердилось — метки всё равно поверх экрана (ведущая их видит), страница знает, что они в видео.
    assert.equal(host.marksSent(), 1);
    assert.equal(host.overlay.visible, true, "окно меток на экране");
    assert.deepEqual(host.marksState(), { screen: true, inVideo: true, reason: "no-answer" });
    assert.equal(host.places().length, 2, "одна повторная попытка, не больше");
    assert.match(host.log(), / unprotected .* phys=- affinity=- order=3 err=- exstyle=- marks=no-answer overlays=1 /);
    assert.match(host.log(), / place-dip /, "помощник не поставил окно — по-старому, в DIP");
    assert.ok(host.overlay.calls.includes("setBounds"));
  } finally { host.stop(); }
});

test("рамка окна меток ушла после ответа помощника (поздний WM_DPICHANGED): контрольная сверка ставит заново", async () => {
  const a = layoutA(), b = layoutB();
  const host = await start(world([a, b], [screenSource(a, 1)], { createScale: 1.75 }));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(80);
    const o = host.overlay;
    assert.deepEqual(o.phys, a.phys);
    o.phys = { ...o.phys, width: 3360, height: 1890 }; // Chromium применил размер по прежнему DPI уже после сверки
    o.emit("resize");
    await tick(700);
    assert.deepEqual(o.phys, a.phys, "окно меток снова на физической рамке монитора A");
    assert.match(host.log(), / place-check /, "контрольная сверка была и её видно в журнале");
    host.mark(...P);
    await tick(20);
    near(host.landed(), expected(a.phys, ...P), "после контрольной сверки");
  } finally { host.stop(); }
});

test("контрольная сверка не сошлась: окно меток ставится заново (place-drift) и снова сверяется", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1.25, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)], { badPlace: 2 }));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(1300);
    const log = host.log();
    assert.ok(log.indexOf(" place-drift ") > 0 && log.indexOf(" place-check ") > log.indexOf(" place-drift "), log);
    assert.equal(host.places().length, 4, "постановка, неудачная сверка, постановка заново, сверка");
    assert.deepEqual(host.overlay.phys, d.phys);
  } finally { host.stop(); }
});

test("рамка уходит после каждой постановки: контрольных сверок не больше трёх, без бесконечного цикла", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1.25, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)], { driftAfterPlace: true }));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(2200);
    const count = host.places().length;
    assert.equal(count, 1 + 3, "первая постановка и три контрольные");
    assert.equal(host.log().split(" place-check ").length - 1, 3);
    await tick(700);
    assert.equal(host.places().length, count, "после трёх сверок помощника больше не зовут");
  } finally { host.stop(); }
});

test("отказ Windows в place (окно не сдвинулось): окно меток ставится по-старому, в DIP, метки показываются", async () => {
  const a = layoutA(), b = layoutB();
  const host = await start(world([a, b], [screenSource(a, 1)], { createScale: 1.75, placeDenied: true }));
  try {
    await host.share("screen:1:0");
    host.mark(...P);
    await tick(120);
    host.overlay.emit("resize"); // setBounds DIP-пути двигает окно — контрольные сверки не нужны
    await tick(700);
    assert.equal(host.places().length, 2, "две попытки place, потом DIP и без контрольных сверок");
    assert.match(host.log(), / place-dip /);
    assert.ok(host.overlay.calls.includes("setBounds"));
    assert.equal(host.marksSent(), 1);
  } finally { host.stop(); }
});

test("старая Windows 10 (affinity 0x1 — в видео чёрное): защита снята (не чёрный экран), метки поверх экрана и в видео", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1.25, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)], { oldWindows: true }));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(80);
    const calls = host.overlay.calls.filter((c) => c.startsWith("protect:"));
    assert.equal(calls.at(-1), "protect:false", `защита снята: ${calls}`);
    assert.equal(host.overlay.affinity, 0);
    assert.ok(!host.fake.helperCalls.some(([c], i, all) => c === "protect" && all.slice(0, i).some(([p]) => p === "protect")), "второй порядок не нужен");
    assert.match(host.log(), / unprotected .* affinity=0x1 order=1 err=\d+ exstyle=0x[0-9a-f]+ marks=old-windows overlays=1 build=1\.1\.0 os=\S+\n/);
    assert.equal(host.marksSent(), 1, "метка поверх экрана показана");
    assert.equal(host.overlay.visible, true);
    assert.deepEqual(host.marksState(), { screen: true, inVideo: true, reason: "old-windows" });
  } finally { host.stop(); }
});

test("журнал размещения: мониторы номерами по порядку, без ID устройств", async () => {
  const a = layoutA(), b = layoutB(), c = layoutC();
  const host = await start(world([a, b, c], [screenSource(a, 1)]));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(80);
    const line = host.log().split("\n").find((l) => / placed /.test(l));
    assert.match(line, / displays=\[1:-1920,248,1920x1080@1 2:0,0,2195x1235@1\.75 3:2195,258,1920x1080@1\] primary=2 source=1 /);
    assert.doesNotMatch(host.log().replace(/^\S+Z /gm, ""), /\b1[123]:|=1[123]\b/, "ID мониторов (11, 12, 13) в журнал не попадают");   // без меток времени: минута :11 давала ложное срабатывание
  } finally { host.stop(); }
});

test("без помощника исключение из захвата не проверить: метки поверх экрана всё равно показываются, страница знает, что они в видео", async () => {
  const a = laptop(), b = external();
  const host = await start(world([a, b], [screenSource(a, 1), screenSource(b, 2)], { helper: false }));
  try {
    await host.share("screen:2:0");
    host.mark(0.8, 0.6);
    await tick(80);
    assert.equal(host.marksSent(), 1);
    assert.equal(host.overlay.visible, true);
    assert.deepEqual(host.marksState(), { screen: true, inVideo: true, reason: "no-helper" });
  } finally { host.stop(); }
});

test("исключение подтверждено — метки поверх экрана, страница знает (screen: true)", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1.25, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)]));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(80);
    assert.equal(host.marksSent(), 1);
    assert.deepEqual(host.marksState(), { screen: true, inVideo: false, reason: "" });
    assert.match(host.log(), / protect .* affinity=0x11 order=1 err=\d+ exstyle=0x[0-9a-f]+ marks=screen overlays=1 /);
  } finally { host.stop(); }
});

test("исключение пропало посреди эфира и не встаёт снова: окно меток остаётся, страница знает, что метки в видео", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1.25, [0, 0], true);
  const w = world([d], [screenSource(d, 1)]);
  const host = await start(w);
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(80);
    assert.equal(host.marksSent(), 1);
    // Windows сняла исключение (например, после смены стиля окна), и оно больше не ставится.
    host.overlay.affinity = 0; w.protectFails = true;
    await tick(VERIFY_MS + 120);
    assert.equal(host.overlay.visible, true, "окно меток на экране");
    assert.deepEqual(host.marksState(), { screen: true, inVideo: true, reason: "unprotected" });
    assert.match(host.log(), / protect-lost .*\n.* unprotected .* marks=unprotected /);
    host.mark(0.3, 0.3);
    await tick(80);
    assert.equal(host.marksSent(), 2, "новые метки поверх экрана показываются");
  } finally { host.stop(); }
});

test("исключение пропало, но встаёт заново: метки остаются поверх экрана", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1.25, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)]));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(80);
    host.overlay.affinity = 0;
    await tick(VERIFY_MS + 120);
    assert.equal(host.overlay.affinity, 0x11, "исключение поставлено снова");
    assert.equal(host.overlay.visible, true);
    host.mark(0.3, 0.3);
    await tick(80);
    assert.equal(host.marksSent(), 2);
  } finally { host.stop(); }
});

test("новая трансляция: окна меток прежних закрыты — живёт одно (иначе второе с метками попало бы в видео)", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1.25, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)]));
  try {
    await host.share("screen:1:0");
    const first = host.overlay;
    await host.share("screen:1:0");
    assert.ok(first.destroyed, "прежнее окно меток закрыто");
    assert.equal(host.fake.windows.filter((x) => x.opts.transparent && !x.destroyed).length, 1);
    host.mark(0.5, 0.5);
    await tick(80);
    assert.match(host.log().split("\n").filter((l) => / protect /.test(l)).at(-1), / overlays=1 /);
  } finally { host.stop(); }
});

// ---- Зритель переключает мониторы ведущего (SHARE-PROTOCOL §4.1): displays / switchTo / notice ----
const katya = () => { const a = layoutA(), b = layoutB(), c = layoutC(); return { a, b, c, sources: [screenSource(a, 1), screenSource(b, 2), screenSource(c, 3)] }; };
// Страница после switchTo делает новый getDisplayMedia: обработчик приложения отдаёт выбранный монитор.
async function switchTo(host, n) {
  const ok = await host.fake.handles.get("switchTo")(page(), n);
  if (ok) { assert.ok(host.getDisplayMedia().streams, "захват после switchTo"); await tick(); }
  return ok;
}

test("мониторы для зрителей (Катя): номера слева направо, физические пиксели, без ID устройств; окно — current 0", async () => {
  const k = katya();
  const host = await start(world([k.b, k.c, k.a], [...k.sources, windowSource]));
  try {
    await host.share("screen:2:0");
    const info = await host.fake.handles.get("displays")(page());
    assert.equal(info.current, 2);
    assert.deepEqual(info.list.map((d) => [d.n, d.w, d.h, d.scale, d.primary]), [[1, 1920, 1080, 1, false], [2, 3840, 2160, 1.75, true], [3, 1920, 1080, 1, false]]);
    assert.doesNotMatch(JSON.stringify(info), /"id"|display_id/);
    await host.share(windowSource.id);
    assert.equal((await host.fake.handles.get("displays")(page())).current, 0);
    assert.equal(await host.fake.handles.get("switchTo")(page(), 1), false, "окно на монитор не переключается");
  } finally { host.stop(); }
});

test("Катя: зритель переключает A → B → C — окно меток на новом мониторе в физических пикселях, метка на месте", async () => {
  const k = katya();
  const host = await start(world([k.a, k.b, k.c], k.sources, { createScale: 1.75 }));
  try {
    await host.share("screen:1:0");
    for (const [n, d] of [[2, k.b], [3, k.c], [1, k.a], [3, k.c]]) {
      assert.equal(await switchTo(host, n), true);
      host.mark(...P);
      await tick(80);
      assert.deepEqual(host.overlay.phys, d.phys, `окно меток на мониторе ${n}`);
      near(host.landed(), expected(d.phys, ...P), `монитор ${n}`);
      assert.equal((await host.fake.handles.get("displays")(page())).current, n);
    }
  } finally { host.stop(); }
});

test("выбор монитора без getDisplayMedia (страница не смогла) отменяется switchTo(0): следующий захват — прежний экран", async () => {
  const k = katya();
  const host = await start(world([k.a, k.b, k.c], k.sources));
  try {
    await host.share("screen:2:0");
    assert.equal(await host.fake.handles.get("switchTo")(page(), 3), true);
    assert.equal(await host.fake.handles.get("switchTo")(page(), 0), false);
    host.getDisplayMedia();
    await tick();
    host.mark(0.5, 0.5);
    await tick(80);
    near(host.landed(), expected(k.b.phys, 0.5, 0.5), "прежний монитор B");
  } finally { host.stop(); }
});

test("уведомление о переключении: в окне меток после защиты от захвата, без помощника и на старой Windows — нет", async () => {
  const k = katya();
  for (const [extra, shown] of [[{}, true], [{ helper: false }, false], [{ oldWindows: true }, false]]) {
    const host = await start(world([k.a, k.b, k.c], k.sources, extra));
    try {
      await host.share("screen:2:0");
      await switchTo(host, 3);
      const list = (await host.fake.handles.get("displays")(page())).list;
      host.fake.ipc.get("notice")(page(), { name: "Максим", n: 3, list });
      await tick(80);
      const notices = host.overlay.sent.filter(([c]) => c === "notice");
      assert.equal(notices.length, shown ? 1 : 0, JSON.stringify(extra));
      if (shown) {
        assert.equal(notices[0][1].name, "Максим");
        assert.equal(notices[0][1].n, 3);
        assert.deepEqual(host.overlay.phys, k.c.phys, "уведомление на новом мониторе");
        assert.equal(host.overlay.affinity, 0x11, "окно меток исключено из захвата");
      }
    } finally { host.stop(); }
  }
});

test("мониторы изменились (подключили, масштаб) — странице приходит displays-changed", async () => {
  const k = katya();
  const host = await start(world([k.a, k.b, k.c], k.sources));
  try {
    const page = host.fake.windows[0];
    page.loaded = true;
    host.fake.module.screen.emit("display-added");
    host.fake.module.screen.emit("display-metrics-changed");
    assert.equal(page.sent.filter(([c]) => c === "displays-changed").length, 2);
  } finally { host.stop(); }
});

test("switchTo даёт странице активацию (скрипт «с жестом»): иначе Chromium не пустит её getDisplayMedia", async () => {
  const k = katya();
  const host = await start(world([k.a, k.b, k.c], k.sources));
  try {
    await host.share("screen:2:0");
    const calls = [];
    const sender = { executeJavaScript: async (code, gesture) => { calls.push([code, gesture]); } };
    assert.equal(await host.fake.handles.get("switchTo")(page({ sender }), 3), true);
    assert.deepEqual(calls, [["void 0", true]]);
    assert.equal(await host.fake.handles.get("switchTo")(page({ sender }), 9), false);
    assert.equal(calls.length, 1, "нет такого монитора — без активации");
  } finally { host.stop(); }
});

test("захват после switchTo не удался (getDisplayMedia уже отдал новый экран): switchTo(0) возвращает источник и окно меток", async () => {
  const k = katya();
  const host = await start(world([k.a, k.b, k.c], k.sources));
  try {
    await host.share("screen:2:0");
    assert.equal(await switchTo(host, 3), true);
    assert.deepEqual(host.overlay.phys, k.c.phys, "обработчик уже переставил окно меток на C");
    assert.equal(await host.fake.handles.get("switchTo")(page(), 0), false);
    await tick(80);
    assert.equal((await host.fake.handles.get("displays")(page())).current, 2, "источник — снова B");
    host.mark(0.5, 0.5);
    await tick(80);
    assert.deepEqual(host.overlay.phys, k.b.phys, "окно меток вернулось на B");
    near(host.landed(), expected(k.b.phys, 0.5, 0.5), "метка на B");
    // Повторная отмена ничего не трогает: возвращаться уже не на что.
    assert.equal(await host.fake.handles.get("switchTo")(page(), 0), false);
    assert.equal((await host.fake.handles.get("displays")(page())).current, 2);
  } finally { host.stop(); }
});

test("удачное переключение не откатывается поздней отменой следующего (новый switchTo забывает прежний экран)", async () => {
  const k = katya();
  const host = await start(world([k.a, k.b, k.c], k.sources));
  try {
    await host.share("screen:2:0");
    await switchTo(host, 3);
    // Следующий запрос: страница не дошла до getDisplayMedia (обработчик не вызывался) и отменила выбор.
    assert.equal(await host.fake.handles.get("switchTo")(page(), 1), true);
    assert.equal(await host.fake.handles.get("switchTo")(page(), 0), false);
    assert.equal((await host.fake.handles.get("displays")(page())).current, 3, "остаётся C — последний удачный");
  } finally { host.stop(); }
});

test("журнал кодера страницы — в overlay.log только коды и числа; начало эфира — видеокарта, статусы и флаги (без LUID)", async () => {
  const w = world([monitor(1, { x: 0, y: 0, width: 1920, height: 1080 }, 1, [0, 0], true)], []);
  w.gpu = {
    status: { video_encode: "disabled_software", gpu_compositing: "enabled" },
    switches: { "disable-features": "MediaFoundationH264Encoding" },
    basic: { gpuDevice: [{ vendorId: 0x10de, deviceId: 0x2504, active: true }] },
    complete: { gpuDevice: [{ vendorId: 0x10de, deviceId: 0x2504, deviceString: "NVIDIA GeForce RTX 3060", driverVendor: "NVIDIA",
      driverVersion: "31.0.15.3623", luid: { high: 0, low: 12345 }, active: true }, { vendorId: 0x8086, deviceId: 0x4680, active: false }],
      auxAttributes: { glRenderer: "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11-31.0.15.3623)", optimus: false,
        videoEncodeAcceleratorSupportedProfile: [{ profile: "h264 main", maxResolutionWidth: 4096, maxResolutionHeight: 2304 }], machineModelName: "x" } },
  };
  const host = await start(w);
  try {
    const main = host.fake.windows.find((x) => !x.opts.transparent);
    const send = host.fake.ipc.get("page-log");
    send(page({ sender: main.webContents }), "encoder start reason=start mode=hw src=3840x2160 <img src=x> Катя");
    send({ sender: {} }, "encoder start чужое окно");
    await tick(20);
    const log = host.log();
    assert.match(log, / page encoder start reason=start mode=hw src=3840x2160 \?img src=x\? \?{4}\n/);
    assert.ok(!log.includes("чужое"), "строки не из главного окна не пишутся");
    assert.match(log, / gpu devices=\[1:nvidia\(0x10de\) model=0x2504 name=NVIDIA_GeForce_RTX_3060 driver=NVIDIA:31.0.15.3623 active 2:intel\(0x8086\) model=0x4680 /);
    assert.match(log, /status=\[video_encode=disabled_software gpu_compositing=enabled\] flags=\[disable-features=MediaFoundationH264Encoding\]/);
    assert.match(log, / gpu aux glRenderer=ANGLE_\(NVIDIA,_NVIDIA_GeForce_RTX_3060_Direct3D11.* optimus=false videoEncodeAcceleratorSupportedProfile=.*4096/);
    assert.ok(!/12345|luid|machineModel/.test(log), "без LUID и модели компьютера");
  } finally { host.stop(); }
});

test("схема меток на странице только когда главное окно не над транслируемой областью (covered)", async () => {
  const a = laptop(), b = external();
  const host = await start(world([a, b], [screenSource(a, 1), screenSource(b, 2)], { oldWindows: true }));
  try {
    const main = host.main;
    // Главное окно — на мониторе, который транслируется.
    main.setBounds({ x: a.bounds.x + 40, y: a.bounds.y + 40, width: 800, height: 600 });
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(80);
    assert.deepEqual(host.lastMarksState(), { screen: true, inVideo: true, reason: "old-windows", covered: true });
    // Перенесли на другой монитор — схему можно.
    main.setBounds({ x: b.bounds.x + 40, y: b.bounds.y + 40, width: 800, height: 600 });
    main.emit("move");
    assert.equal(host.lastMarksState().covered, false);
    // Свернули — тоже можно.
    main.setBounds({ x: a.bounds.x + 40, y: a.bounds.y + 40, width: 800, height: 600 });
    main.emit("move");
    assert.equal(host.lastMarksState().covered, true);
    main.minimized = true; main.emit("minimize");
    assert.equal(host.lastMarksState().covered, false);
  } finally { host.stop(); }
});

test("у окна меток осталась рамка: клиентская область меньше монитора — доли считаются от неё, в журнале числа", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)]));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.5);
    await tick(80);
    const normal = host.overlay.sent.filter(([c]) => c === "region").at(-1)[1];
    assert.deepEqual(normal, { fx: 0, fy: 0, fw: 1, fh: 1 });
    host.fake.ipc.get("overlay-report")({ sender: host.overlay.webContents, senderFrame: OVERLAY_FRAME }, { mark: [0.5, 0.5], point: [960, 500], area: {}, region: normal,
      innerWidth: 1904, innerHeight: 1041, dpr: 1 });
    const fixed = host.overlay.sent.filter(([c]) => c === "region").at(-1)[1];
    assert.ok(Math.abs(fixed.fw - 1920 / 1904) < 1e-9 && Math.abs(fixed.fh - 1080 / 1041) < 1e-9);
    assert.ok(fixed.fy < 0, "область начинается выше клиентской: заголовок сверху");
    assert.match(host.log(), / client-mismatch monitor=0,0,1920x1080 client=8,31,1904x1041 page=1904x1041@1\n/);
  } finally { host.stop(); }
});

test("система ужала окно меток до рабочей области: доли считаются от фактического окна, метка на месте", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)], { clampHeight: 1040 }));
  try {
    await host.share("screen:1:0");
    host.mark(0.5, 0.25);
    await tick(80);
    const region = host.overlay.sent.filter(([c]) => c === "region").at(-1)[1];
    assert.ok(Math.abs(region.fh - 1080 / 1040) < 1e-9, `доля высоты ${region.fh}`);
    near(host.landed(), [960, 270], "метка при окне 1920x1040");
    assert.match(host.log(), / place-mismatch .* phys=0,0,1920x1040@/);
  } finally { host.stop(); }
});

test("звонки (Discord и др.) исключаются из звука ведущего сами, пока галочку не сняли", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)]));
  try {
    await host.choose("screen:1:0", true, ["Game.exe", "discord.exe"]);
    host.fake.ipc.get("startAudio")(page({ sender: { isDestroyed: () => false, send() {} } }));
    const args = host.spawned.at(-1);
    assert.equal(args[0], "capture");
    const names = args.slice(1).map((n) => n.toLowerCase());
    for (const need of ["game.exe", "discord.exe", "zoom.exe", "teams.exe", "telegram.exe"]) assert.ok(names.includes(need), need);
    assert.equal(names.filter((n) => n === "discord.exe").length, 1, "без повторов");
    host.fake.ipc.get("setMuteCalls")(page({ sender: { isDestroyed: () => false, send() {} } }), false);
    assert.deepEqual(host.spawned.at(-1), ["capture", "Game.exe", "discord.exe"], "галочку сняли — только отмеченное вручную");
    await host.choose("screen:1:0", true, [], false);
    host.fake.ipc.get("startAudio")(page({ sender: { isDestroyed: () => false, send() {} } }));
    assert.deepEqual(host.spawned.at(-1), ["capture"], "выбор без звонков при начале эфира");
  } finally { host.stop(); }
});

test("окно обновления не всплывает во время эфира: ждёт его конца", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1, [0, 0], true);
  const w = world([d], [screenSource(d, 1)]);
  const host = await start(w);
  try {
    const downloaded = host.updater.get("update-downloaded");
    await host.share("screen:1:0");
    downloaded({ version: "9.9.9" });
    await tick(30);
    assert.equal(w.dialogs || 0, 0, "во время эфира окна нет");
    host.fake.ipc.get("stopped")(page());
    await tick(1700);
    assert.equal(w.dialogs, 1, "после конца эфира — одно окно");
    downloaded({ version: "9.9.10" });
    await tick(30);
    assert.equal(w.dialogs, 2, "без эфира — сразу");
  } finally { host.stop(); }
});

test("страница с эфиром ушла (перезагрузка, падение) без stopped: эфир считается оконченным, окно обновления не теряется", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1, [0, 0], true);
  const w = world([d], [screenSource(d, 1)]);
  const host = await start(w);
  try {
    const downloaded = host.updater.get("update-downloaded");
    await host.share("screen:1:0");
    downloaded({ version: "9.9.9" });
    host.main.webContents.emit("did-start-navigation", {}, "https://x/", true, true); // внутри страницы — не конец
    await tick(30);
    assert.equal(w.dialogs || 0, 0);
    host.main.webContents.emit("render-process-gone", {});
    await tick(1700);
    assert.equal(w.dialogs, 1, "после падения страницы окно приходит");
    // Новый эфир в окне ожидания 1,5 с: окно ждёт его конца.
    downloaded({ version: "9.9.10" });
    await tick(30);
    assert.equal(w.dialogs, 2);
    await host.share("screen:1:0");
    downloaded({ version: "9.9.11" });
    host.main.webContents.emit("did-fail-load", {});
    await host.share("screen:1:0");
    await tick(1700);
    assert.equal(w.dialogs, 2, "эфир начат раньше срока — окно не поверх него");
    host.fake.ipc.get("stopped")(page());
    await tick(1700);
    assert.equal(w.dialogs, 3);
  } finally { host.stop(); }
});

test("страница не подтверждает звук (подвисла): приложение пропускает его, а не копит; подтвердила — звук снова идёт", async () => {
  const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1, [0, 0], true);
  const host = await start(world([d], [screenSource(d, 1)]));
  try {
    await host.choose("screen:1:0", true, []);
    const sent = [];
    host.fake.ipc.get("startAudio")(page({ sender: { isDestroyed: () => false, send: (...a) => sent.push(a) } }));
    const helper = host.trackers.at(-1);
    const chunk = Buffer.alloc(9600);
    for (let i = 0; i < 40; i++) helper.stdout.emit("data", chunk);
    assert.ok(sent.length <= 11, `отправлено ${sent.length} кусков, предел ≈ 2 с`);
    const stuck = sent.length;
    host.fake.ipc.get("audio-ack")(page(), 9600 * stuck);
    helper.stdout.emit("data", chunk);
    assert.equal(sent.length, stuck + 1, "после подтверждения звук идёт");
  } finally { host.stop(); }
});

// ---- Безопасность главного окна (аудит H1, L17): страница ретранслятора могла бы быть подменена ----
const oneScreen = () => { const d = monitor(7, { x: 0, y: 0, width: 1920, height: 1080 }, 1, [0, 0], true); return world([d], [screenSource(d, 1), { id: "window:4242:0", name: "Отчёт" }]); };
const EVIL = (extra = {}) => ({ senderFrame: { url: "https://evil.example/" }, ...extra });
const capture = (host, request = {}) => host.getDisplayMedia(request).streams ?? null;

test("навигация: главное окно не уходит с ретранслятора (ссылка, редирект, кадр); новые окна не открываются", async () => {
  const host = await start(oneScreen());
  try {
    const contents = host.main.webContents;
    const navigate = (event, url) => { let prevented = false; contents.emit(event, { url, preventDefault() { prevented = true; } }, url); return prevented; };
    for (const event of ["will-navigate", "will-frame-navigate", "will-redirect"]) {
      assert.equal(navigate(event, "https://mac-utils-relay.mako-62d.workers.dev/?id=1"), false, `${event}: ретранслятор`);
      for (const url of ["https://evil.example/", "file:///C:/Windows/System32/calc.exe", "http://mac-utils-relay.mako-62d.workers.dev/", "javascript:alert(1)"]) {
        assert.equal(navigate(event, url), true, `${event}: ${url}`);
      }
    }
  } finally { host.stop(); }
});

test("openExternal со схемами file:, search-ms:, javascript: — отказ; новые окна — всегда deny", async () => {
  const w = oneScreen();
  const host = await start(w);
  try {
    const open = (url) => host.main.openHandler({ url });
    for (const url of ["file://\\\\host\\share\\x.exe", "file:///C:/Windows/System32/calc.exe", "search-ms:query=x&crumb=location:\\\\host\\share",
      "javascript:alert(1)", "ms-settings:privacy", "http://github.com/", "https://evil.example/"]) {
      assert.deepEqual(open(url), { action: "deny" }, url);
    }
    assert.deepEqual(w.opened || [], [], "ничего не открыто в системе");
    assert.deepEqual(open("https://github.com/m-ruzhynskyi/mac-utils/releases"), { action: "deny" }, "окно не открывается и для разрешённой ссылки");
    assert.deepEqual(w.opened, ["https://github.com/m-ruzhynskyi/mac-utils/releases"], "разрешённая https-ссылка — в браузере");
  } finally { host.stop(); }
});

test("обработчик разрешений: экран и звук — ретранслятору; камера, чтение буфера, уведомления — нет; чужим — ничего", async () => {
  const host = await start(oneScreen());
  try {
    const { request, check } = host.fake.permissions;
    const ask = (permission, details) => new Promise((resolve) => request(host.main.webContents, permission, resolve, details));
    const relay = RELAY_FRAME.url;
    assert.equal(await ask("display-capture", { requestingUrl: relay }), true);
    assert.equal(await ask("media", { requestingUrl: relay, mediaTypes: ["audio"] }), true);
    assert.equal(await ask("media", { requestingUrl: relay, mediaTypes: ["video"] }), false, "камера");
    assert.equal(await ask("media", { requestingUrl: relay, mediaTypes: ["audio", "video"] }), false);
    for (const permission of ["clipboard-read", "deprecated-sync-clipboard-read", "notifications", "geolocation", "openExternal", "fullscreen"]) {
      assert.equal(await ask(permission, { requestingUrl: relay }), false, permission);
    }
    assert.equal(await ask("display-capture", { requestingUrl: "https://evil.example/" }), false);
    assert.equal(await ask("media", { requestingUrl: OVERLAY_FRAME.url, mediaTypes: ["audio"] }), false, "свои локальные окна — тоже без разрешений");
    assert.equal(check(host.main.webContents, "media", "https://mac-utils-relay.mako-62d.workers.dev", { mediaType: "audio" }), true);
    assert.equal(check(host.main.webContents, "media", "https://mac-utils-relay.mako-62d.workers.dev", { mediaType: "video" }), false);
    assert.equal(check(host.main.webContents, "clipboard-read", "https://mac-utils-relay.mako-62d.workers.dev", {}), false);
    assert.equal(check(null, "display-capture", "https://evil.example", {}), false);
  } finally { host.stop(); }
});

test("IPC: чужой кадр, кадр без адреса и окно меток не управляют трансляцией", async () => {
  const host = await start(oneScreen());
  try {
    host.click();
    for (const event of [EVIL(), {}, { senderFrame: null }, { sender: host.main.webContents, senderFrame: OVERLAY_FRAME }]) {
      assert.deepEqual(await host.fake.handles.get("sources")(event), [], "sources");
      host.click();
      assert.equal(await host.fake.handles.get("choose")(event, "screen:1:0", true, []), false, "choose");
      assert.deepEqual(await host.fake.handles.get("displays")(event), { list: [], current: 0 }, "displays");
      assert.equal(await host.fake.handles.get("switchTo")(event, 1), false, "switchTo");
      assert.equal(await host.fake.handles.get("audioApps")(event), null, "audioApps");
      const sync = { ...event, returnValue: undefined };
      host.fake.ipc.get("version")(sync);
      assert.equal(sync.returnValue, event.senderFrame === OVERLAY_FRAME ? "1.1.0" : "", "version: ответ есть всегда, версия — только своим");
    }
    assert.equal(capture(host), null, "захват без выбора — отказ");
    // Эфир по выбору ведущего; чужой кадр не ставит метки и не останавливает его.
    await host.share("screen:1:0");
    host.fake.ipc.get("mark")(EVIL(), { type: "ping", x: 0.5, y: 0.5, color: "red" });
    host.fake.ipc.get("stopped")(EVIL());
    await tick(80);
    assert.ok(!host.overlay || host.marksSent() === 0, "метка чужого кадра не показана");
    assert.equal(host.fake.ipc.get("version")(page()), undefined);
    assert.ok(capture(host), "чужой stopped не забыл выбор");
  } finally { host.stop(); }
});

test("выбор источника: только по клику ведущего после показа списка и только из списка; снимков у страницы нет", async () => {
  const w = oneScreen();
  const host = await start(w);
  try {
    // Без клика: ни списка, ни выбора, ни захвата.
    assert.deepEqual(await host.fake.handles.get("sources")(page()), []);
    assert.equal(await host.fake.handles.get("choose")(page(), "screen:1:0", false, []), false);
    assert.equal(capture(host), null);
    // Клик → список: без снимков.
    host.click();
    const list = await host.fake.handles.get("sources")(page());
    assert.deepEqual(list.map((s) => s.id), ["screen:1:0", "window:4242:0"]);
    assert.ok(list.every((s) => /^data:image\/svg\+xml,/.test(s.thumbnail)), "схема вместо снимка");
    // Клик был ДО показа списка — выбор после него без нового клика не проходит.
    assert.equal(await host.fake.handles.get("choose")(page(), "screen:1:0", false, []), false, "клик до списка не считается");
    assert.equal(capture(host), null);
    host.click();
    await host.fake.handles.get("sources")(page());
    host.click();
    assert.equal(await host.fake.handles.get("choose")(page(), "screen:9:0", false, []), false, "не из списка");
    host.click();
    await host.fake.handles.get("sources")(page());
    host.click();
    assert.equal(await host.fake.handles.get("choose")(page(), "screen:1:0", false, []), true, "клик по плитке — выбор");
    assert.equal(capture(host, { securityOrigin: "https://evil.example" }), null, "захват для чужого origin — отказ");
    assert.equal(capture(host).video.id, "screen:1:0");
    // Эфир кончился — выбор забыт: страница не начнёт захват снова без нового клика, switchTo не даёт активацию.
    host.fake.ipc.get("stopped")(page());
    assert.equal(capture(host), null, "после эфира — без нового выбора нельзя");
    assert.equal(await host.fake.handles.get("switchTo")(page({ sender: { executeJavaScript: async () => assert.fail("активация без эфира") } }), 1), false);
    assert.match(host.log(), /choose denied reason=no-input/);
    assert.match(host.log(), /choose denied reason=not-listed/);
  } finally { host.stop(); }
});

test("выбор действует ARM_MS: позже страница захват сама не начнёт; клавиша Enter тоже считается действием ведущего", async () => {
  const host = await start(oneScreen());
  const realNow = Date.now;
  try {
    const key = () => host.main.webContents.emit("input-event", {}, { type: "keyDown" });
    const move = () => host.main.webContents.emit("input-event", {}, { type: "mouseMove" });
    move();
    assert.deepEqual(await host.fake.handles.get("sources")(page()), [], "движение мыши — не действие");
    key();
    await host.fake.handles.get("sources")(page());
    key();
    assert.equal(await host.fake.handles.get("choose")(page(), "screen:1:0", false, []), true);
    const base = realNow();
    Date.now = () => base + 31_000;
    assert.equal(capture(host), null, "через 31 с без эфира выбор не действует");
    Date.now = () => base + 6_000;
    assert.equal(await host.fake.handles.get("choose")(page(), "screen:1:0", false, []), false, "клик старше 5 с не считается");
  } finally { Date.now = realNow; host.stop(); }
});

test("WINNA-30: getDisplayMedia после выбора ведущего проходит обработчик разрешений Electron 44 (\"media\", mediaTypes [])", async () => {
  const k = katya();
  const host = await start(world([k.a, k.b, k.c], k.sources));
  const realNow = Date.now;
  try {
    // Без выбора — отказ уже на разрешениях (у страницы это NotAllowedError), в журнале — почему.
    assert.deepEqual(host.getDisplayMedia(), { error: "NotAllowedError" });
    assert.match(host.log(), /capture denied reason=not-armed stage=permission/);
    // Ведущий выбрал экран — тот же запрос проходит и получает выбранный экран (раньше: NotAllowedError, эфир не начинался).
    assert.equal(await host.choose("screen:2:0", false, []), true);
    assert.equal(host.getDisplayMedia().streams?.video?.id, "screen:2:0");
    // Чужой origin и после выбора — нет.
    assert.deepEqual(host.getDisplayMedia({ securityOrigin: "https://evil.example/" }), { error: "NotAllowedError" });
    // Через ARM_MS без нового выбора — нет; а переключение монитора зрителем в эфире — да (nextSource).
    const base = realNow();
    Date.now = () => base + 31_000;
    assert.deepEqual(host.getDisplayMedia(), { error: "NotAllowedError" }, "выбор протух");
    assert.equal(await host.fake.handles.get("switchTo")(page({ sender: { executeJavaScript: async () => {} } }), 3), true);
    assert.equal(host.getDisplayMedia().streams?.video?.id, "screen:3:0", "switchTo в эфире");
    assert.deepEqual(host.getDisplayMedia(), { error: "NotAllowedError" }, "переключение — на один захват");
    // Камера и после выбора — нет.
    Date.now = realNow;
    await host.choose("screen:1:0", false, []);
    const ask = (details) => new Promise((resolve) => host.fake.permissions.request(host.main.webContents, "media", resolve, { requestingUrl: RELAY_FRAME.url, ...details }));
    assert.equal(await ask({ mediaTypes: ["video"] }), false);
    // Эфир кончился — захват снова только через новый выбор.
    host.fake.ipc.get("stopped")(page());
    assert.deepEqual(host.getDisplayMedia(), { error: "NotAllowedError" });
  } finally { Date.now = realNow; host.stop(); }
});

test("страница ушла (перезагрузка) — выбор забыт", async () => {
  const host = await start(oneScreen());
  try {
    await host.choose("screen:1:0", false, []);
    host.main.webContents.emit("did-start-navigation", {}, "https://mac-utils-relay.mako-62d.workers.dev/", false, true);
    assert.equal(capture(host), null);
  } finally { host.stop(); }
});

test("метки (L17): негодные не показываются, у штриха не больше 2000 точек, не больше 30 меток в секунду", async () => {
  const host = await start(oneScreen());
  try {
    await host.share("screen:1:0");
    const send = (mark) => host.fake.ipc.get("mark")(page(), mark);
    send({ type: "html", x: 0.5, y: 0.5 });
    send({ type: "ping", x: "0.5", y: 0.5 });
    send({ type: "stroke", points: Array.from({ length: 10_000 }, (_, i) => [i / 10_000, 0.5]), color: "green", extra: "<b>" });
    await tick(80);
    const sent = host.overlay.sent.filter(([c]) => c === "mark").map(([, m]) => m);
    assert.equal(sent.length, 1, "дошёл только штрих");
    assert.equal(sent[0].points.length, 2000);
    assert.deepEqual(Object.keys(sent[0]), ["type", "points", "color"]);
    for (let i = 0; i < 60; i++) send({ type: "ping", x: 0.5, y: 0.5, color: "red" });
    await tick(80);
    assert.equal(host.overlay.sent.filter(([c]) => c === "mark").length, 30, "за секунду — не больше 30 (одна уже была)");
  } finally { host.stop(); }
});

test("буфер обмена (пароли «Удалённых подключений») главному окну недоступен: нет в preload, песочница, чтение запрещено", async () => {
  const preload = fs.readFileSync(path.join(path.dirname(MAIN), "preload.js"), "utf8");
  assert.ok(!/clipboard/i.test(preload), "в мосте window.mu нет буфера обмена");
  const host = await start(oneScreen());
  try {
    const prefs = host.main.opts.webPreferences;
    assert.equal(prefs.contextIsolation, true);
    assert.equal(prefs.sandbox, true, "в песочнице preload не получит electron.clipboard");
    assert.equal(prefs.nodeIntegration, false);
    const ask = (permission) => new Promise((resolve) => host.fake.permissions.request(host.main.webContents, permission, resolve, { requestingUrl: RELAY_FRAME.url }));
    assert.equal(await ask("clipboard-read"), false);
    assert.equal(await ask("deprecated-sync-clipboard-read"), false);
  } finally { host.stop(); }
});

test("выход: секреты «Удалённых подключений» стираются из буфера до конца процесса — выход ждёт асинхронную очистку (Electron 44)", async () => {
  let options = null, finish = null, disposes = 0;
  const w = oneScreen();
  w.remote = { init: (_electron, opts) => { options = opts; return { dispose: () => { disposes++; return new Promise((resolve) => { finish = resolve; }); } }; } };
  const host = await start(w);
  try {
    let prevented = 0;
    w.appEvents["will-quit"]({ preventDefault: () => { prevented++; } });
    assert.equal(prevented, 1, "выход отложен");
    assert.equal(disposes, 1);
    await tick(20);
    assert.equal(w.quits || 0, 0, "пока буфер не стёрт — не выходим");
    finish();
    await tick(20);
    assert.equal(w.quits, 1, "стёрт — app.quit() ещё раз");
    w.appEvents["will-quit"]({ preventDefault: () => { prevented++; } });
    assert.equal(prevented, 1, "второй will-quit не задерживается");
    assert.equal(disposes, 1);
    // copyText (ID TeamViewer): запись в буфер асинхронная, ошибка — false, без необработанного отказа.
    assert.equal(await options.copyText("123 456 789"), true);
    assert.equal(w.clipboardText, "123 456 789");
    w.clipboardFails = true;
    assert.equal(await options.copyText("1"), false);
  } finally { host.stop(); }
});

test("окна самого приложения (Electron 35+ их не прячет) — не в списке выбора и не выбираются", async () => {
  const w = oneScreen();
  const host = await start(w);
  try {
    const own = `window:${host.main.hwnd}:0`;
    w.sources.push({ id: own, name: "Mac Utils Share" });
    host.click();
    const list = await host.fake.handles.get("sources")(page());
    assert.deepEqual(list.map((s) => s.id), ["screen:1:0", "window:4242:0"], "главного окна в списке нет");
    host.click();
    assert.equal(await host.fake.handles.get("choose")(page(), own, false, []), false, "и выбрать его нельзя");
    assert.match(host.log(), /choose denied reason=not-listed/);
  } finally { host.stop(); }
});
