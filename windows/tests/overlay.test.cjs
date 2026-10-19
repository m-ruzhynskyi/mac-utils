// Метки зрителей у ведущего на Windows: куда на экране (в физических пикселях) попадает точка, которую зритель
// поставил на кадре. main.js грузится целиком с подменённым Electron: мониторы с масштабом Windows (DIP и физические
// пиксели), помощник track, окно меток. Ожидание: точка (доля кадра) попадает в ту же долю транслируемой области.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const Module = require("node:module");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");
const { EventEmitter } = require("node:events");

const MAIN = process.env.MAIN_JS || path.join(__dirname, "..", "main.js");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

// Монитор: DIP-границы (как у Electron), масштаб и физическая рамка.
const monitor = (id, phys, scale, dipOrigin, primary = false) => ({
  id, scaleFactor: scale, primary, phys,
  bounds: { x: dipOrigin[0], y: dipOrigin[1], width: Math.round(phys.width / scale), height: Math.round(phys.height / scale) },
});
const toPhys = (d, x, y) => [d.phys.x + (x - d.bounds.x) * d.scaleFactor, d.phys.y + (y - d.bounds.y) * d.scaleFactor];
const contains = (r, x, y) => x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;
const overlap = (a, b) => Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x)) *
  Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y));

function electron(world) {
  const ipc = new Map(), handles = new Map(), screenEvents = new EventEmitter();
  let displayMedia = null;
  const windows = [];
  class BrowserWindow extends EventEmitter {
    constructor(opts) {
      super();
      this.opts = opts;
      this.bounds = { x: opts.x ?? 0, y: opts.y ?? 0, width: opts.width ?? 800, height: opts.height ?? 600 };
      this.sent = []; this.visible = opts.show !== false; this.destroyed = false;
      const self = this;
      this.webContents = Object.assign(new EventEmitter(), {
        send(channel, data) { if (self.loaded) self.sent.push([channel, JSON.parse(JSON.stringify(data))]); },
        setWindowOpenHandler() {},
      });
      windows.push(this);
    }
    // Windows: окно, переезжающее на монитор с другим масштабом, при первом setBounds получает размер,
    // пересчитанный по масштабу прежнего монитора (поэтому main.js ставит границы дважды).
    setBounds(b) {
      const from = world.displays.find((d) => overlap(d.bounds, this.bounds) > 0) || world.displays[0];
      const to = world.displays.find((d) => contains(d.bounds, b.x, b.y)) || from;
      const k = world.dpiQuirk && from.scaleFactor !== to.scaleFactor ? from.scaleFactor / to.scaleFactor : 1;
      const next = { x: b.x, y: b.y, width: Math.round(b.width * k), height: Math.round(b.height * k) };
      const moved = next.x !== this.bounds.x || next.y !== this.bounds.y, resized = next.width !== this.bounds.width || next.height !== this.bounds.height;
      this.bounds = next;
      if (moved) this.emit("move");
      if (resized) this.emit("resize");
    }
    getBounds() { return { ...this.bounds }; }
    getContentBounds() { return { ...this.bounds }; }
    loadFile() { setImmediate(() => { this.loaded = true; this.webContents.emit("did-finish-load"); }); }
    loadURL() { return Promise.resolve(); }
    showInactive() { this.visible = true; }
    show() { this.visible = true; }
    hide() { this.visible = false; }
    close() { this.destroyed = true; }
    isDestroyed() { return this.destroyed; }
    isMinimized() { return false; }
    setAlwaysOnTop() {} setIgnoreMouseEvents() {} setContentProtection() {} flashFrame() {} focus() {} restore() {}
  }
  const screen = Object.assign(screenEvents, {
    getAllDisplays: () => world.displays,
    getPrimaryDisplay: () => world.displays.find((d) => d.primary),
    getDisplayMatching: (r) => [...world.displays].sort((a, b) => overlap(b.bounds, r) - overlap(a.bounds, r))[0],
    screenToDipRect: (_w, r) => {
      const d = [...world.displays].sort((a, b) => overlap(b.phys, r) - overlap(a.phys, r))[0];
      return { x: Math.round(d.bounds.x + (r.x - d.phys.x) / d.scaleFactor), y: Math.round(d.bounds.y + (r.y - d.phys.y) / d.scaleFactor),
               width: Math.round(r.width / d.scaleFactor), height: Math.round(r.height / d.scaleFactor) };
    },
  });
  return {
    windows, ipc, handles, get displayMedia() { return displayMedia; },
    module: {
      app: { requestSingleInstanceLock: () => true, quit() {}, whenReady: () => Promise.resolve(), on() {}, isPackaged: false,
             getVersion: () => "1.1.0", getPath: () => world.logs },
      BrowserWindow, screen,
      desktopCapturer: { getSources: async () => world.sources },
      ipcMain: { on: (name, fn) => ipc.set(name, fn), handle: (name, fn) => handles.set(name, fn) },
      session: { defaultSession: { webRequest: { onBeforeSendHeaders() {} }, setDisplayMediaRequestHandler: (fn) => { displayMedia = fn; } } },
      dialog: {}, shell: {},
    },
  };
}

// Загрузить main.js с этим «Windows»: Electron, electron-updater, помощник (spawn) и его наличие (fs.existsSync).
async function start(world) {
  const fake = electron(world);
  const trackers = [];
  const childProcess = { ...require("node:child_process"), spawn: () => {
    const child = Object.assign(new EventEmitter(), { stdout: new EventEmitter(), kill() {} });
    trackers.push(child); return child;
  } };
  const realFs = require("node:fs");
  const fakeFs = { ...realFs, existsSync: (p) => (String(p).endsWith("mu-audio.exe") ? world.helper !== false : realFs.existsSync(p)) };
  const load = Module._load, intervals = [], realInterval = global.setInterval;
  Module._load = function (request, ...rest) {
    if (request === "electron") return fake.module;
    if (request === "electron-updater") return { autoUpdater: { on() {}, checkForUpdates: async () => {} } };
    if (request === "child_process") return childProcess;
    if (request === "fs") return fakeFs;
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
    fake, trackers,
    stop() { intervals.forEach(clearInterval); },
    // Ведущий выбрал источник и страница начала захват.
    async share(sourceId) {
      await fake.handles.get("choose")({}, sourceId, false, []);
      fake.displayMedia({ audioRequested: false }, () => {});
      await tick();
    },
    track(rect) { trackers.at(-1).stdout.emit("data", Buffer.from(`${rect.x} ${rect.y} ${rect.width} ${rect.height}\n`)); },
    mark(x, y) { fake.ipc.get("mark")({}, { type: "ping", x, y, color: "red" }); },
    get overlay() { return fake.windows.find((w) => w.opts.transparent && !w.destroyed); },
    // Куда легла последняя метка: точка на холсте окна меток (как в overlay.html) → физические пиксели экрана.
    landed() {
      const o = this.overlay;
      const mark = o.sent.filter(([c]) => c === "mark").at(-1)?.[1];
      if (!mark) return null;
      const region = o.sent.filter(([c]) => c === "region").at(-1)?.[1];
      const content = o.getContentBounds();
      const area = region || { x: 0, y: 0, w: content.width, h: content.height };   // прежний overlay.html: на всё окно
      const dip = [content.x + area.x + mark.x * area.w, content.y + area.y + mark.y * area.h];
      const d = world.displays.find((m) => contains(m.bounds, dip[0], dip[1])) || world.displays[0];
      return toPhys(d, dip[0], dip[1]).map(Math.round);
    },
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
  const host = await start(world([a, b], [screenSource(a, 1), screenSource(b, 2)], { dpiQuirk: true }));
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
  const host = await start(world([a, b], [windowSource], { dpiQuirk: true }));
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
