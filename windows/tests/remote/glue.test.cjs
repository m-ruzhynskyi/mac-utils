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
      this.navigationBlocked = false;
      this.webContents = { send: (...a) => this.sent.push(a), on: (event, fn) => { if (event === "will-navigate") { const e = { prevented: false, preventDefault() { this.prevented = true; } }; fn(e); this.navigationBlocked = e.prevented; } }, setWindowOpenHandler: (fn) => { this.openDenied = fn().action === "deny"; } }; }
    loadFile(file, o) { this.file = path.basename(file); this.hash = o?.hash; }
    on(e, fn) { this.handlers[e] = fn; }
    isDestroyed() { return this.destroyed; }
    isMinimized() { return false; }
    show() { this.shown = true; } showInactive() { this.shown = true; } hide() { this.shown = false; } focus() {} restore() {} setAlwaysOnTop() {}
    setBounds(b) { this.bounds = b; }
  }
  const trays = [];
  class Tray { constructor(img) { this.img = img; this.handlers = {}; trays.push(this); } setToolTip() {} on(e, fn) { this.handlers[e] = fn; } setContextMenu(m) { this.menu = m; } destroy() { this.destroyed = true; } }
  return {
    handles, listeners, registered, windows, trays, opened,
    electron: {
      app: { getPath: () => os.tmpdir() },
      BrowserWindow, Tray,
      Menu: { buildFromTemplate: (t) => t, getApplicationMenu: () => null, setApplicationMenu() {} }, MenuItem: class {},
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
  // Доверенный отправитель — окно списка (вызовы IPC принимаются только от окон модуля).
  fake.trust = () => { rc.openWindow(); return { sender: fake.windows.filter((w) => w.file === "remote.html" && !w.hash).at(-1).webContents }; };
  for (let i = 0; i < 200 && rc.store.state.status !== "ready"; i++) await new Promise((r) => setTimeout(r, 10));
  return { fake, rc, dir, file };
};

test("клавиша по умолчанию Win+Shift+A (не Ctrl+Alt: это AltGr) → Super+Shift+A; не вышло — сообщается", async () => {
  assert.equal(accelerator("Ctrl+Alt+A"), "Control+Alt+A");
  assert.equal(accelerator("Win+Shift+A"), "Super+Shift+A");
  const { fake, rc } = await setup();
  assert.equal(fake.registered[0][0], "Super+Shift+A");
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
  fake.listeners.get("rc:closePalette")({ sender: palette.webContents });
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

test("трей: открыть список, поиск, избранное и недавние; внизу только «Обновить» (Excel и сводка — в окне списка)", async () => {
  const { fake, rc } = await setup();
  const key = rc.service.view().sections.flatMap((s) => s.records)[0].key;
  await fake.handles.get("rc:toggleFavorite")(fake.trust(), key);
  const labels = () => fake.trays[0].menu.map((i) => i.label || "—");
  const l = labels();
  assert.ok(l.includes("Открыть список…") && l.includes("Поиск (Win+Shift+A)") && l.includes("Избранное"));
  assert.equal(l.at(-1), "↻ Обновить", "внизу — только «Обновить»");
  assert.ok(!l.some((x) => /Excel|Загружено|пропущено|папк/i.test(x)), l.join("|"));
  let reloaded = 0; const real = rc.store.reload.bind(rc.store); rc.store.reload = () => { reloaded++; return real(); };
  fake.trays[0].menu.at(-1).click();
  assert.equal(reloaded, 1);
  rc.dispose();
});

test("IPC: вид, настройки, смена файла перечитывает список, смена клавиши перерегистрирует; пароль наружу не уходит", async () => {
  const { fake, rc, dir } = await setup();
  const view = await fake.handles.get("rc:view")(fake.trust(), { query: "", filter: "all" });
  assert.equal(view.status, "ready");
  assert.ok(!JSON.stringify(view).includes("Pw-"));
  const file2 = path.join(dir, "second.xml");
  fs.writeFileSync(file2, F.xmlRows(F.cleanRows(3)));
  const result = await fake.handles.get("rc:setSettings")(fake.trust(), { file: file2, hotkey: "Ctrl+Alt+B" });
  assert.equal(result.hotkeyOk, true);
  assert.equal(fake.registered.at(-1)[0], "Control+Alt+B");
  assert.equal(result.hotkeyProblem, "altgr", "Ctrl+Alt — предупреждение про AltGr");
  for (let i = 0; i < 200 && !(rc.store.state.snapshot?.records.length === 3); i++) await new Promise((r) => setTimeout(r, 10));
  assert.equal(rc.store.state.snapshot.records.length, 3);
  assert.equal((await fake.handles.get("rc:getSettings")(fake.trust())).hotkey, "Ctrl+Alt+B");
  const saved = fs.readFileSync(path.join(dir, "remote-connections.json"), "utf8");
  assert.ok(!/Pw-/.test(saved));
  rc.dispose();
});

test("подключение без поставщика — не падает; несуществующая запись — «записи больше нет»", async () => {
  const { fake, rc } = await setup();
  assert.deepEqual(await fake.handles.get("rc:connect")(fake.trust(), { key: "999:1", noPassword: false }), { ok: false, error: "gone" });
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

test("правка через IPC: .xlsx — только чтение; .xml — запись, .bak, список обновляется; кнопка «Скачать» открывает страницу программы", async () => {
  const { fake, rc, dir } = await setup();
  assert.equal((await fake.handles.get("rc:view")(fake.trust(), {})).canEdit, false);
  const readOnly = await fake.handles.get("rc:edit")(fake.trust(), { action: "add", payload: { fields: { name: "A", id: "123456789" } } });
  assert.deepEqual(readOnly, { ok: false, error: "xlsxReadOnly" });
  const xmlFile = path.join(dir, "list.xml");
  fs.writeFileSync(xmlFile, F.xmlRows(F.cleanRows(3)));
  await fake.handles.get("rc:setSettings")(fake.trust(), { file: xmlFile });
  for (let i = 0; i < 200 && rc.store.state.snapshot?.records.length !== 3; i++) await new Promise((r) => setTimeout(r, 10));
  assert.equal((await fake.handles.get("rc:view")(fake.trust(), {})).canEdit, true);
  assert.deepEqual(await fake.handles.get("rc:edit")(fake.trust(), { action: "add", payload: { fields: { name: "Новая", id: "523456789" } } }), { ok: true });
  for (let i = 0; i < 200 && rc.store.state.snapshot?.records.length !== 4; i++) await new Promise((r) => setTimeout(r, 10));
  assert.equal(rc.store.state.snapshot.records.length, 4);
  assert.ok(fs.existsSync(`${xmlFile}.bak`));
  assert.deepEqual(await fake.handles.get("rc:edit")(fake.trust(), { action: "remove", payload: { key: "999:1" } }), { ok: false, error: "gone" });
  assert.equal(await fake.handles.get("rc:edit")(fake.trust(), { action: "download", payload: "teamViewer" }), true);
  assert.deepEqual(fake.opened.at(-1), ["url", "https://www.teamviewer.com/download/"]);
  rc.dispose();
});

test("клавиша и значок в трее — только когда выбран файл; без файла сочетание ни у кого не отнимается", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rc-glue-"));
  const fake = fakeElectron();
  const rc = init(fake.electron, { userData: dir, icon: "icon.png" });
  assert.equal(fake.registered.length, 0, "без файла клавиша не регистрируется");
  assert.equal(fake.trays.length, 0, "и значка в трее нет");
  const sender = () => { rc.openWindow(); return { sender: fake.windows.filter((w) => w.file === "remote.html" && !w.hash).at(-1).webContents }; };
  const file = path.join(dir, "list.xml");
  fs.writeFileSync(file, F.xmlRows(F.cleanRows(2)));
  await fake.handles.get("rc:setSettings")(sender(), { file });
  assert.equal(fake.registered.length, 1);
  assert.equal(fake.trays.length, 1);
  await fake.handles.get("rc:setSettings")(sender(), { file: "" });
  assert.equal(fake.trays[0].destroyed, true, "файл снят — значок убран");
  rc.dispose();
});

test("сочетание без Ctrl/Alt/Win не принимается; Ctrl+Alt — с предупреждением; свои настройки вне .xlsx/.xml и чужие программы не принимаются", async () => {
  const { fake, rc } = await setup();
  const bad = await fake.handles.get("rc:setSettings")(fake.trust(), { hotkey: "A" });
  assert.equal(bad.hotkeyOk, false);
  assert.equal(bad.hotkey, "Win+Shift+A", "прежнее сочетание сохранено");
  assert.equal((await fake.handles.get("rc:setSettings")(fake.trust(), { hotkey: "Shift+A" })).hotkeyOk, false);
  const r = await fake.handles.get("rc:setSettings")(fake.trust(), { file: "C:\\Windows\\win.ini", programPaths: { anyDesk: "C:\\evil\\calc.exe", teamViewer: "D:\\TV\\TeamViewer.exe" } });
  assert.notEqual(r.file, "C:\\Windows\\win.ini");
  assert.equal(r.programPaths.anyDesk, "");
  assert.equal(r.programPaths.teamViewer, "D:\\TV\\TeamViewer.exe");
  rc.dispose();
});

test("вызовы IPC — только от окон модуля: чужой отправитель отклоняется; окна не переходят по ссылкам", async () => {
  const { fake, rc } = await setup();
  const stranger = { sender: { id: 99 } };
  for (const [name, arg] of [["rc:view", {}], ["rc:connect", { key: "2:123456789" }], ["rc:setSettings", { file: "x.xml" }], ["rc:openFile"], ["rc:chooseFile"], ["rc:edit", { action: "remove", payload: { key: "x" } }]]) {
    const result = await fake.handles.get(name)(stranger, arg);
    assert.ok(result == null || result === "" || result === false || result.ok === false || (Array.isArray(result) && !result.length), `${name}: ${JSON.stringify(result)}`);
  }
  assert.deepEqual(fake.opened, [], "ничего не открыто");
  rc.openWindow();
  const w = fake.windows.find((x) => x.file === "remote.html");
  assert.equal(typeof w.navigationBlocked, "boolean");
  assert.equal(w.navigationBlocked, true);
  rc.dispose();
});

test("вход без файла: пункт меню окна Share — выбрать файл, шаблон .xlsx/.xml; после создания шаблона открывается список", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rc-glue-"));
  const fake = fakeElectron();
  let appended = null;
  fake.electron.Menu.getApplicationMenu = () => ({ append: (item) => { appended = item; } });
  fake.electron.MenuItem = class { constructor(o) { Object.assign(this, o); } };
  const made = [];
  const templates = { create: async ({ kind, setSettings }) => { made.push(kind); const file = path.join(dir, `t.${kind}`); fs.writeFileSync(file, kind === "xml" ? F.xmlRows(F.cleanRows(2)) : F.xlsxRows(F.cleanRows(2))); setSettings({ file, sheet: "" }); return file; } };
  const rc = init(fake.electron, { userData: dir, icon: "icon.png", templates });
  assert.equal(appended?.label, "Удалённые подключения");
  assert.deepEqual(appended.submenu.filter((i) => i.label).map((i) => i.label), ["Открыть список…", "Выбрать файл…", "Создать шаблон .xlsx…", "Создать шаблон .xml…"]);
  assert.equal(fake.windows.length, 0);
  await appended.submenu.find((i) => i.label === "Создать шаблон .xml…").click();
  assert.deepEqual(made, ["xml"]);
  assert.ok(fake.windows.some((w) => w.file === "remote.html"), "после шаблона открыт список");
  assert.equal(fake.registered.length, 1, "файл выбран — клавиша включилась");
  rc.dispose();
  const ui = fs.readFileSync(path.join(__dirname, "../../remote/ui/remote.js"), "utf8");
  assert.match(ui, /rc\.createTemplate\(kind\)[\s\S]{0,40}refresh/, "пустой экран создаёт шаблон сразу, а не отправляет в настройки");
});
