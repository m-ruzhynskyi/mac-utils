// Электронная обвязка модуля (index.js) на двойнике Electron: клавиша, трей, окна, IPC, без реальных окон.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./fixtures");
const { init, accelerator } = require("../../remote");

function fakeElectron({ registerOk = true } = {}) {
  const handles = new Map(), listeners = new Map(), registered = [], windows = [], opened = [];
  class BrowserWindow {
    constructor(opts) { this.opts = opts; this.sent = []; this.shown = false; this.destroyed = false; this.handlers = {}; windows.push(this);
      this.webContents = { send: (...a) => this.sent.push(a) }; }
    loadFile(file, o) { this.file = path.basename(file); this.hash = o?.hash; }
    on(e, fn) { this.handlers[e] = fn; }
    isDestroyed() { return this.destroyed; }
    isMinimized() { return false; }
    show() { this.shown = true; } showInactive() { this.shown = true; } hide() { this.shown = false; } focus() {} restore() {} setAlwaysOnTop() {}
    setBounds(b) { this.bounds = b; }
  }
  const trays = [];
  class Tray { constructor(img) { this.img = img; this.handlers = {}; trays.push(this); } setToolTip() {} on(e, fn) { this.handlers[e] = fn; } setContextMenu(m) { this.menu = m; } destroy() {} }
  return {
    handles, listeners, registered, windows, trays, opened,
    electron: {
      app: { getPath: () => os.tmpdir() },
      BrowserWindow, Tray,
      Menu: { buildFromTemplate: (t) => t },
      globalShortcut: { register: (acc, fn) => { registered.push([acc, fn]); return registerOk; }, unregister: () => {}, unregisterAll() {} },
      ipcMain: { handle: (n, fn) => handles.set(n, fn), on: (n, fn) => listeners.set(n, fn) },
      shell: { openPath: (p) => opened.push(["path", p]), openExternal: (u) => opened.push(["url", u]) },
      dialog: { showOpenDialog: async () => ({ canceled: true, filePaths: [] }) },
      nativeImage: { createFromPath: () => ({ resize: () => ({}) }), createEmpty: () => ({}) },
      screen: { getPrimaryDisplay: () => ({ workArea: { x: 0, y: 0, width: 1920, height: 1040 } }), getCursorScreenPoint: () => ({ x: 10, y: 10 }), getDisplayNearestPoint: () => ({ workArea: { x: 0, y: 0, width: 1920, height: 1040 } }) },
    },
  };
}
const setup = async (opts) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rc-glue-"));
  const file = path.join(dir, "list.xlsx");
  fs.writeFileSync(file, F.xlsxRows(F.cleanRows(12)));
  fs.writeFileSync(path.join(dir, "remote-connections.json"), JSON.stringify({ file }));
  const fake = fakeElectron(opts);
  const rc = init(fake.electron, { userData: dir, timing: { debounceMs: 20, retryMs: 20, pollMs: 30 }, icon: "icon.png" });
  for (let i = 0; i < 200 && rc.store.state.status !== "ready"; i++) await new Promise((r) => setTimeout(r, 10));
  return { fake, rc, dir, file };
};

test("клавиша Ctrl+Alt+A регистрируется как Control+Alt+A; не вышло — сообщается", async () => {
  assert.equal(accelerator("Ctrl+Alt+A"), "Control+Alt+A");
  const { fake, rc } = await setup();
  assert.equal(fake.registered[0][0], "Control+Alt+A");
  assert.equal(rc.hotkeyOk, true);
  rc.dispose();
  const bad = await setup({ registerOk: false });
  assert.equal(bad.rc.hotkeyOk, false);
  bad.rc.dispose();
});

test("палитра: по клавише — окно без рамки по центру экрана с курсором, получает rc:show; Esc скрывает", async () => {
  const { fake, rc } = await setup();
  fake.registered[0][1]();
  const palette = fake.windows.at(-1);
  assert.equal(palette.opts.frame, false);
  assert.equal(palette.opts.alwaysOnTop, true);
  assert.equal(palette.hash, "palette");
  assert.deepEqual(palette.bounds, { x: 610, y: 208, width: 700, height: 460 });
  assert.ok(palette.shown);
  assert.ok(palette.sent.some(([c]) => c === "rc:show"));
  fake.listeners.get("rc:closePalette")();
  assert.equal(palette.shown, false);
  rc.dispose();
});

test("окно: безопасные настройки; повторный вызов не создаёт второе", async () => {
  const { fake, rc } = await setup();
  rc.openWindow(); rc.openWindow();
  const wins = fake.windows.filter((w) => w.file === "remote.html" && !w.hash);
  assert.equal(wins.length, 1);
  const prefs = wins[0].opts.webPreferences;
  assert.equal(prefs.contextIsolation, true); assert.equal(prefs.sandbox, true); assert.equal(prefs.nodeIntegration, false);
  rc.dispose();
});

test("трей: открыть список, поиск, избранное и недавние, Excel, перечитать, сводка диагностики", async () => {
  const { fake, rc } = await setup();
  const key = rc.service.view().sections.flatMap((s) => s.records)[0].key;
  await fake.handles.get("rc:toggleFavorite")({}, key);
  const labels = () => fake.trays[0].menu.map((i) => i.label || "—");
  const l = labels();
  assert.ok(l.includes("Открыть список…") && l.includes("Поиск (Ctrl+Alt+A)") && l.includes("Избранное") && l.includes("Открыть файл в Excel") && l.includes("Перечитать файл"));
  assert.ok(l.some((x) => /^Загружено 12/.test(x)));
  rc.dispose();
});

test("IPC: вид, настройки, смена файла перечитывает список, смена клавиши перерегистрирует; пароль наружу не уходит", async () => {
  const { fake, rc, dir } = await setup();
  const view = await fake.handles.get("rc:view")({}, { query: "", filter: "all" });
  assert.equal(view.status, "ready");
  assert.ok(!JSON.stringify(view).includes("Pw-"));
  const file2 = path.join(dir, "second.xml");
  fs.writeFileSync(file2, F.xmlRows(F.cleanRows(3)));
  const result = await fake.handles.get("rc:setSettings")({}, { file: file2, hotkey: "Ctrl+Alt+B" });
  assert.equal(result.hotkeyOk, true);
  assert.equal(fake.registered.at(-1)[0], "Control+Alt+B");
  for (let i = 0; i < 200 && !(rc.store.state.snapshot?.records.length === 3); i++) await new Promise((r) => setTimeout(r, 10));
  assert.equal(rc.store.state.snapshot.records.length, 3);
  assert.equal((await fake.handles.get("rc:getSettings")()).hotkey, "Ctrl+Alt+B");
  const saved = fs.readFileSync(path.join(dir, "remote-connections.json"), "utf8");
  assert.ok(!/Pw-/.test(saved));
  rc.dispose();
});

test("подключение без поставщика — не падает; несуществующая запись — «записи больше нет»", async () => {
  const { fake, rc } = await setup();
  assert.deepEqual(await fake.handles.get("rc:connect")({}, { key: "999:1", noPassword: false }), { ok: false, error: "gone" });
  rc.dispose();
});

test("интерфейс: строгая CSP, нет встроенных скриптов, данные файла только через textContent", () => {
  const ui = path.join(__dirname, "..", "..", "remote", "ui");
  const html = fs.readFileSync(path.join(ui, "remote.html"), "utf8"), js = fs.readFileSync(path.join(ui, "remote.js"), "utf8");
  assert.match(html, /Content-Security-Policy[^>]*default-src 'none'/);
  assert.ok(!/<script(?![^>]*\bsrc=)/.test(html), "встроенный скрипт");
  assert.ok(!/\son\w+=/.test(html), "обработчики в разметке");
  assert.equal((js.match(/innerHTML/g) || []).length, 1, "innerHTML — только для констант значков");
  assert.ok(!/eval\(|new Function|document\.write/.test(js));
  assert.doesNotThrow(() => new (require("node:vm").Script)(js));
});
