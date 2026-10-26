// rc-win-entry (от пользователя, 1.2.29): вход в «Удалённые подключения» без файла (трей, клавиша, меню окна, подсказка),
// палитра по экрану, портативный AnyDesk/TeamViewer (папки и реестр — только чтение), HUD сверху по центру в workArea,
// ожидание окна пароля TeamViewer 60 с с продлением до 180 с. Двойники Electron, ФС, реестра и PowerShell: ничего не запускается.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const F = require("./fixtures");
const { init, paletteBounds } = require("../../remote");
const { createLocator, commandExe, isProgramFile } = require("../../remote/locate");
const { createConnector } = require("../../remote/connect");
const { createHud, hudBounds } = require("../../remote/hud");
const { createUia, guardMs } = require("../../remote/uia");
const { SecretBuffer } = require("../../remote/secret");

const NO_LOCATOR = { candidates: () => [], refresh: async () => false };

function fakeElectron({ appMenu = null } = {}) {
  const handles = new Map(), listeners = new Map(), registered = [], windows = [], trays = [], menus = [];
  class BrowserWindow {
    constructor(opts) { this.opts = opts; this.sent = []; this.handlers = {}; this.destroyed = false; windows.push(this);
      this.webContents = { send: (...a) => this.sent.push(a), on() {}, setWindowOpenHandler() {} }; }
    loadFile(file, o) { this.file = path.basename(file); this.hash = o?.hash; }
    on(e, fn) { this.handlers[e] = fn; }
    isDestroyed() { return this.destroyed; } isMinimized() { return false; }
    show() { this.shown = true; } showInactive() { this.shown = true; } hide() { this.shown = false; } focus() {} restore() {} setAlwaysOnTop() {}
    setBounds(b) { this.bounds = b; }
  }
  class Tray { constructor() { this.balloons = []; trays.push(this); } setToolTip() {} on() {} setContextMenu(m) { this.menu = m; } destroy() { this.destroyed = true; }
    displayBalloon(o) { this.balloons.push(o); } }
  let dialogPick = null;
  return {
    handles, listeners, registered, windows, trays, menus, setPick: (p) => { dialogPick = p; },
    electron: {
      app: { getPath: () => os.tmpdir() }, BrowserWindow, Tray,
      Menu: { buildFromTemplate: (t) => t, getApplicationMenu: () => appMenu, setApplicationMenu: (m) => menus.push(m) },
      MenuItem: class { constructor(o) { Object.assign(this, o); } },
      globalShortcut: { register: (acc, fn) => { registered.push([acc, fn]); return true; }, unregister() {}, unregisterAll() {} },
      ipcMain: { handle: (n, fn) => handles.set(n, fn), on: (n, fn) => listeners.set(n, fn) },
      shell: { openPath() {}, openExternal() {} },
      dialog: { showOpenDialog: async () => (dialogPick ? { canceled: false, filePaths: [dialogPick] } : { canceled: true, filePaths: [] }) },
      nativeImage: { createFromPath: () => ({ resize: () => ({}) }), createEmpty: () => ({}) },
      screen: { getPrimaryDisplay: () => ({ workArea: { x: 0, y: 0, width: 1920, height: 1040 } }), getCursorScreenPoint: () => ({ x: 10, y: 10 }),
        getDisplayNearestPoint: () => ({ workArea: { x: 0, y: 0, width: 1920, height: 1040 } }) },
    },
  };
}
const sender = (fake, rc) => { rc.openWindow(); return { sender: fake.windows.filter((w) => w.file === "remote.html" && !w.hash).at(-1).webContents }; };

// ---------- 1–4: вход без файла ----------

test("без файла: значок в трее и Win+Shift+A есть; первый запуск — одна подсказка в трее, второй — без неё; модальных окон нет", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rc-entry-"));
  const fake = fakeElectron();
  const rc = init(fake.electron, { userData: dir, icon: "icon.png", locator: NO_LOCATOR });
  assert.equal(fake.trays.length, 1);
  assert.deepEqual(fake.trays[0].menu.filter((i) => i.label).map((i) => i.label), ["Выбрать файл…", "Создать шаблон .xlsx…", "Создать шаблон .xml…", "Открыть список…"]);
  assert.equal(fake.registered.length, 1);
  assert.deepEqual(fake.trays[0].balloons, [{ title: "Удалённые подключения", content: "Подключения: Win+Shift+A или значок в трее", iconType: "info", noSound: true }]);
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir, "remote-connections.json"), "utf8")).entryHintShown, true, "подсказка запомнена");
  rc.dispose();
  const again = fakeElectron();
  const rc2 = init(again.electron, { userData: dir, icon: "icon.png", locator: NO_LOCATOR });
  assert.deepEqual(again.trays[0].balloons, [], "второй запуск — без подсказки");
  rc2.dispose();
  // С файлом подсказка не нужна.
  const withFile = fs.mkdtempSync(path.join(os.tmpdir(), "rc-entry-"));
  const file = path.join(withFile, "list.xml"); fs.writeFileSync(file, F.xmlRows(F.cleanRows(2)));
  fs.writeFileSync(path.join(withFile, "remote-connections.json"), JSON.stringify({ file }));
  const third = fakeElectron();
  const rc3 = init(third.electron, { userData: withFile, icon: "icon.png", locator: NO_LOCATOR });
  assert.deepEqual(third.trays[0].balloons, []);
  rc3.dispose();
  const ui = fs.readFileSync(path.join(__dirname, "../../remote/index.js"), "utf8");
  assert.ok(!/showMessageBox|showErrorBox/.test(ui), "без системных модальных диалогов");
});

test("меню окна: «Удалённые подключения» есть всегда — меню приложения нет (null) → своё; есть → пункт добавлен один раз", () => {
  const fresh = fakeElectron({ appMenu: null });
  const a = init(fresh.electron, { userData: fs.mkdtempSync(path.join(os.tmpdir(), "rc-entry-")), locator: NO_LOCATOR });
  assert.equal(fresh.menus.length, 1);
  assert.equal(fresh.menus[0][0].label, "Удалённые подключения", "меню поставлено явно, а не потеряно");
  assert.ok(fresh.menus[0][0].submenu.some((i) => i.label === "Выбрать файл…"));
  a.dispose();
  const items = [];
  const existing = { items, append: (i) => items.push(i) };
  const withMenu = fakeElectron({ appMenu: existing });
  const b = init(withMenu.electron, { userData: fs.mkdtempSync(path.join(os.tmpdir(), "rc-entry-")), locator: NO_LOCATOR });
  assert.equal(items.filter((i) => i.label === "Удалённые подключения").length, 1);
  assert.equal(withMenu.menus[0], existing, "меню приложения переустановлено с пунктом");
  b.dispose();
});

test("пустое окно без файла — «Выберите файл подключений» и кнопки «Выбрать файл…» / «Создать шаблон …»", () => {
  const js = fs.readFileSync(path.join(__dirname, "../../remote/ui/remote.js"), "utf8");
  assert.match(js, /noFile: \["Выберите файл подключений"/);
  assert.match(js, /el\("button", "btn pri", "Выбрать файл…"\)/);
  assert.match(js, /`Создать шаблон \.\$\{kind\}…`/);
});

// ---------- A: палитра ----------

test("палитра по экрану: ширина ~800, высота ~62 % (не меньше 600), всегда в workArea — и при масштабе 125/150 %", () => {
  const inside = (b, w) => b.x >= w.x && b.y >= w.y && b.x + b.width <= w.x + w.width && b.y + b.height <= w.y + w.height;
  const cases = [
    [{ x: 0, y: 0, width: 1920, height: 1040 }, { width: 800, height: 645 }],     // 1080p 100 %
    [{ x: 0, y: 0, width: 1536, height: 824 }, { width: 800, height: 600 }],      // 1080p 125 %: 62 % = 511 → не меньше 600
    [{ x: 0, y: 0, width: 1280, height: 688 }, { width: 800, height: 600 }],      // 1080p 150 %, панель задач снизу
    [{ x: 0, y: 0, width: 1024, height: 600 }, { width: 800, height: 568 }],      // тесный экран: целиком в workArea
    [{ x: -1920, y: 40, width: 1920, height: 1000 }, { width: 800, height: 620 }],// второй монитор слева
  ];
  for (const [w, size] of cases) {
    const b = paletteBounds(w);
    assert.equal(b.width, size.width, JSON.stringify(w));
    assert.equal(b.height, size.height, JSON.stringify(w));
    assert.ok(inside(b, w), JSON.stringify([w, b]));
    assert.ok(Math.abs(b.x + b.width / 2 - (w.x + w.width / 2)) <= 1, "по центру");
  }
});

test("палитра: список забирает место, плашка «не найден» — одна строка, подсказки — одна строка без переноса, «Обновить» в ней", () => {
  const css = fs.readFileSync(path.join(__dirname, "../../remote/ui/remote.css"), "utf8");
  const html = fs.readFileSync(path.join(__dirname, "../../remote/ui/remote.html"), "utf8");
  assert.match(css, /\.scroller \{ flex:1; overflow:auto;/);
  assert.match(css, /body\.palette \.hints \{ flex-wrap:nowrap; white-space:nowrap; overflow:hidden;/);
  assert.match(css, /\.banner\.slim \.tx \{ flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;/);
  assert.match(css, /@media \(max-width: 740px\) \{ body\.palette \.hints \.opt \{ display:none; \} \}/);
  assert.match(html, /<span class="key">Ctrl I<\/span> подробнее/, "«подробнее», а не обрезанное «подроб…»");
});

// ---------- B: где программа ----------

// Фейковая ФС Windows: { "C:\\dir": { "name.exe": mtime } }.
function fakeFs(tree) {
  const files = new Map();
  for (const [dir, entries] of Object.entries(tree)) for (const [name, mtime] of Object.entries(entries)) files.set(path.win32.join(dir, name), mtime);
  return {
    readdirSync: (dir) => { const names = Object.keys(tree[dir] || {}); if (!tree[dir]) throw Object.assign(new Error("ENOENT"), { code: "ENOENT" }); return names; },
    statSync: (file) => { if (!files.has(file)) throw new Error("ENOENT"); return { isFile: () => true, mtimeMs: files.get(file) }; },
    existsSync: (file) => files.has(file),
  };
}
// Фейковый реестр и PowerShell: execFile(file, args, opts, cb). Пишущих команд не бывает — всё записывается.
function fakeSystem({ reg = {}, processes = "" } = {}) {
  const calls = [];
  const execFile = (file, args, _opts, cb) => {
    calls.push([path.win32.basename(file), ...args]);
    if (/reg\.exe$/i.test(file)) {
      const value = reg[args[1]];
      return setImmediate(() => (value ? cb(null, `\r\n${args[1]}\r\n    (Default)    REG_SZ    ${value}\r\n`) : cb(new Error("not found"))));
    }
    setImmediate(() => cb(null, processes));
  };
  return { execFile, calls };
}
const ENV = { USERPROFILE: "C:\\Users\\demo", SystemRoot: "C:\\Windows", ProgramFiles: "C:\\Program Files", "ProgramFiles(x86)": "C:\\Program Files (x86)", LOCALAPPDATA: "C:\\Users\\demo\\AppData\\Local" };

test("портативный AnyDesk в «Загрузках» («AnyDesk (1).exe» — новее, выбирается первым) и на Рабочем столе; установщик TeamViewer — нет", () => {
  const files = fakeFs({
    "C:\\Users\\demo\\Downloads": { "AnyDesk.exe": 100, "AnyDesk (1).exe": 200, "TeamViewer_Setup.exe": 300, "report.xlsx": 1 },
    "C:\\Users\\demo\\Desktop": { "TeamViewerQS.exe": 50 },
  });
  const locator = createLocator({ fs: files, env: ENV, execFile: null });
  assert.deepEqual(locator.candidates("anyDesk"), ["C:\\Users\\demo\\Downloads\\AnyDesk (1).exe", "C:\\Users\\demo\\Downloads\\AnyDesk.exe"]);
  assert.deepEqual(locator.candidates("teamViewer"), ["C:\\Users\\demo\\Desktop\\TeamViewerQS.exe"]);
  for (const [program, name, ok] of [["anyDesk", "AnyDesk (1).exe", true], ["anyDesk", "anydesk.EXE", true], ["anyDesk", "calc.exe", false], ["anyDesk", "AnyDesk.exe.lnk", false],
    ["teamViewer", "TeamViewer.exe", true], ["teamViewer", "TeamViewer_Setup.exe", false], ["teamViewer", "TeamViewerSetup.exe", false], ["teamViewer", "TeamViewerQS.exe", true]]) {
    assert.equal(isProgramFile(program, `D:\\x\\${name}`), ok, name);
  }
  // Подключение: портативный exe → CLI `AnyDesk.exe <ID> --with-password` (документация AnyDesk: путь к exe, установка не нужна).
  const spawned = [];
  const connector = createConnector({ exists: files.existsSync, env: ENV, locate: (p) => locator.candidates(p),
    spawn: (file, args) => { const c = new EventEmitter(); c.stdin = { on() {}, write: (_b, cb) => cb?.(), end() {} }; c.unref = () => {}; spawned.push([file, args]); setImmediate(() => c.emit("exit", 0)); return c; } });
  assert.equal(connector.installed("anyDesk"), true, "плашки «не найден» нет, записи не приглушены");
  assert.equal(connector.find("anyDesk", ""), "C:\\Users\\demo\\Downloads\\AnyDesk (1).exe");
  return connector.connectRecord({ name: "Демо", id: "123456789", hasPassword: true, program: "anyDesk" },
    { settings: { defaultProgram: "anyDesk", programPaths: {} }, store: { password: async () => new SecretBuffer("Demo-Pw-1") } }).then((r) => {
    assert.deepEqual(r, { ok: true });
    assert.deepEqual(spawned[0], ["C:\\Users\\demo\\Downloads\\AnyDesk (1).exe", ["123456789", "--with-password"]]);
  });
});

test("реестр (только reg query): обработчик anydesk: и App Paths; teamviewer10:/tvcontrol1:; процесс — только если остальное пусто", async () => {
  assert.equal(commandExe('"C:\\Tools\\AnyDesk.exe" "%1"'), "C:\\Tools\\AnyDesk.exe");
  assert.equal(commandExe("C:\\Tools\\AnyDesk.exe --url %1"), "C:\\Tools\\AnyDesk.exe");
  assert.equal(commandExe("rundll32 url.dll"), null);
  const sys = fakeSystem({ reg: {
    "HKCU\\Software\\Classes\\anydesk\\shell\\open\\command": '"C:\\Users\\demo\\Tools\\AnyDesk.exe" "%1"',
    "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\TeamViewer.exe": "%ProgramFiles%\\TV15\\TeamViewer.exe",
  } });
  const locator = createLocator({ fs: fakeFs({}), env: ENV, execFile: sys.execFile });
  assert.equal(await locator.refresh(), true);
  assert.deepEqual(locator.candidates("anyDesk"), ["C:\\Users\\demo\\Tools\\AnyDesk.exe"]);
  assert.deepEqual(locator.candidates("teamViewer"), ["C:\\Program Files\\TV15\\TeamViewer.exe"]);
  for (const call of sys.calls.filter((c) => c[0] === "reg.exe")) assert.equal(call[1], "query", "в реестр не пишем");
  assert.ok(sys.calls.some((c) => c[0] === "reg.exe" && c[2] === "HKCU\\Software\\Classes\\tvcontrol1\\shell\\open\\command"));
  // Обработчик указывает не на программу — не берём. Ничего не найдено — путь запущенного процесса (PowerShell Get-Process).
  const proc = fakeSystem({ reg: { "HKCR\\anydesk\\shell\\open\\command": '"C:\\evil\\calc.exe" "%1"' }, processes: "C:\\Users\\demo\\Desktop\\Old\\AnyDesk.exe\r\n" });
  const byProcess = createLocator({ fs: fakeFs({}), env: ENV, execFile: proc.execFile });
  await byProcess.refresh();
  assert.deepEqual(byProcess.candidates("anyDesk"), ["C:\\Users\\demo\\Desktop\\Old\\AnyDesk.exe"]);
  assert.ok(proc.calls.some((c) => c[0] === "powershell.exe" && c.join(" ").includes("Get-Process -Name 'AnyDesk*'")));
  assert.ok(!proc.calls.some((c) => /Set-|New-|Remove-|reg add|reg delete/i.test(c.join(" "))), "только чтение");
  assert.equal(await byProcess.refresh(), false, "без изменений — без лишнего обновления окна");
});

test("«Указать AnyDesk.exe…» в плашке: выбранный exe сохраняется в programPaths, чужой файл — нет; путь «AnyDesk (1).exe» принимается и из настроек", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rc-entry-"));
  const fake = fakeElectron();
  const rc = init(fake.electron, { userData: dir, locator: NO_LOCATOR });
  fake.setPick("C:\\Users\\demo\\Downloads\\AnyDesk (1).exe");
  assert.equal(await fake.handles.get("rc:pickProgram")(sender(fake, rc), "anyDesk"), true);
  assert.equal(rc.settings.data.programPaths.anyDesk, "C:\\Users\\demo\\Downloads\\AnyDesk (1).exe");
  fake.setPick("C:\\Windows\\System32\\calc.exe");
  assert.equal(await fake.handles.get("rc:pickProgram")(sender(fake, rc), "anyDesk"), false);
  assert.equal(rc.settings.data.programPaths.anyDesk, "C:\\Users\\demo\\Downloads\\AnyDesk (1).exe");
  assert.equal(await fake.handles.get("rc:pickProgram")({ sender: { id: 99 } }, "anyDesk"), false, "только от окон модуля");
  assert.equal(await fake.handles.get("rc:pickProgram")(sender(fake, rc), "../../evil"), false);
  const r = await fake.handles.get("rc:setSettings")(sender(fake, rc), { programPaths: { anyDesk: "D:\\Soft\\AnyDesk-portable.exe", teamViewer: "D:\\x\\notepad.exe" } });
  assert.equal(r.programPaths.anyDesk, "D:\\Soft\\AnyDesk-portable.exe");
  assert.equal(r.programPaths.teamViewer, "");
  rc.dispose();
  const js = fs.readFileSync(path.join(__dirname, "../../remote/ui/remote.js"), "utf8");
  assert.match(js, /el\("button", "btn c", `Указать \$\{v\.titles\[p\]\}\.exe…`\); pick\.onclick = async \(\) => \{ if \(await window\.rc\.pickProgram\(p\)\) refresh\(\); \}/);
});

// ---------- C: HUD ----------

test("HUD: сверху по центру workArea монитора с курсором, высота по содержимому и всегда в workArea (150 %, панель задач снизу)", () => {
  const inside = (b, w) => b.x >= w.x && b.y >= w.y && b.x + b.width <= w.x + w.width && b.y + b.height <= w.y + w.height;
  const w150 = { x: 0, y: 0, width: 1280, height: 688 };          // 1920×1080 при 150 %, панель задач 48 px внизу
  for (const h of [120, 168, 260, 900]) {
    const b = hudBounds(w150, h);
    assert.ok(inside(b, w150), JSON.stringify([h, b]));
    assert.equal(b.width, 460);
    assert.equal(b.x, 410, "по центру");
    assert.equal(b.y, 20, "сверху");
    assert.equal(b.height, Math.min(h, 688 - 20 - 12));
  }
  // Окно HUD: место — по монитору с курсором; страница сообщила высоту — окно подогнано; чужое сообщение не принимается.
  const wins = [], ipc = new Map();
  class BW { constructor(o) { this.opts = o; wins.push(this); this.webContents = { send() {}, on() {}, setWindowOpenHandler() {} }; } setAlwaysOnTop() {} loadFile() {} on() {} isDestroyed() { return false; }
    setBounds(b) { this.bounds = b; } showInactive() {} hide() {} }
  const second = { x: 1920, y: 0, width: 1280, height: 688 };
  const hud = createHud({ BrowserWindow: BW, ipcMain: { on: (n, fn) => ipc.set(n, fn) },
    screen: { getCursorScreenPoint: () => ({ x: 2000, y: 10 }), getDisplayNearestPoint: () => ({ workArea: second }), getPrimaryDisplay: () => ({ workArea: w150 }) } }, () => {});
  hud.show({ kind: "info", title: "Жду окно пароля… 14 с", progress: 0.2, actions: [{ id: "cancel", label: "Отмена" }] });
  assert.deepEqual(wins[0].bounds, { x: 1920 + 410, y: 20, width: 460, height: 168 });
  ipc.get("rc:hudSize")({ sender: wins[0].webContents }, 214);
  assert.equal(wins[0].bounds.height, 214);
  ipc.get("rc:hudSize")({ sender: {} }, 999);
  assert.equal(wins[0].bounds.height, 214);
  hud.hide();
  const page = fs.readFileSync(path.join(__dirname, "../../remote/ui/hud.js"), "utf8");
  assert.match(page, /new ResizeObserver\(report\)\.observe/);
});

// ---------- D: ожидание окна пароля TeamViewer ----------

test("TeamViewer: окно пароля на 35-й секунде после «Connecting…» — пароль введён (60 с, продление до 180 с; сторож не мешает)", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const child = new EventEmitter();
  const input = [];
  child.stdin = { on() {}, write: (b, cb) => { input.push(Buffer.from(b).toString("utf8")); cb?.(); }, end() {} };
  child.stdout = new EventEmitter();
  child.kill = () => { child.killed = true; };
  const uia = createUia(() => child);
  const states = [], log = [];
  const connector = createConnector({ exists: (p) => /TeamViewer\.exe$/.test(p), env: ENV, uia, hud: { show: (s) => states.push(s) }, log: (l) => log.push(l),
    clock: { now: () => Date.now() }, spawn: () => { const c = new EventEmitter(); c.unref = () => {}; return c; } });
  const emit = (state) => child.stdout.emit("data", Buffer.from(JSON.stringify({ state }) + "\n"));
  const running = connector.connectRecord({ name: "Демо", id: "123456789", hasPassword: true, program: "teamViewer" },
    { settings: { defaultProgram: "teamViewer", timeoutSeconds: 20, programPaths: {} }, store: { password: async () => new SecretBuffer("Demo-Tv-1") } });
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(JSON.parse(input[0]), { timeoutMs: 60_000, limitMs: 180_000, id: "123456789" });
  emit("ready"); emit("waiting"); emit("intermediate");
  t.mock.timers.tick(35_000);
  assert.ok(!child.killed, "на 35-й секунде сторож ещё не сработал");
  emit("passwordField");
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
  assert.equal(input[1], "Demo-Tv-1\n", "пароль ушёл в скрипт второй строкой");
  emit("confirming"); emit("connected");
  const result = await running;
  assert.deepEqual(result, { ok: true });
  assert.equal(states.at(-1).title, "Подключено");
  assert.ok(states.some((s) => /TeamViewer подключается/.test(s.title)));
  assert.ok(log.some((l) => /^connect ok program=teamViewer password=1 confirmed=1 typed=0 waited=\d+ saw=passwordWindow$/.test(l)), log.join("|"));
  assert.ok(guardMs(60_000, 180_000) >= 180_000 + 60_000);
});

test("TeamViewer: ни окна пароля, ни сеанса к пределу — «не подтверждено», без ложного успеха; в журнале — сколько ждали и что видели", async () => {
  const log = [], states = [];
  const connector = createConnector({ exists: (p) => /TeamViewer\.exe$/.test(p), env: ENV, hud: { show: (s) => states.push(s) }, log: (l) => log.push(l), copyText: () => true,
    spawn: () => { const c = new EventEmitter(); c.unref = () => {}; return c; },
    uia: { enter: async (opts, _pw, onEvent) => { await opts.afterReady?.(); onEvent({ state: "intermediate" }); return { state: "noPrompt" }; } } });
  const r = await connector.connectRecord({ name: "Демо", id: "123456789", hasPassword: true, program: "teamViewer" },
    { settings: { defaultProgram: "teamViewer", programPaths: {} }, store: { password: async () => new SecretBuffer("x") } });
  assert.deepEqual(r, { ok: false, error: "unconfirmed" });
  assert.ok(!states.some((s) => s.kind === "success"));
  assert.match(states.at(-1).detail, /не показал ни окно пароля, ни открытый сеанс/);
  assert.ok(log.some((l) => /^connect fail code=unconfirmed program=teamViewer typed=0 copied=1 waited=\d+ saw=progress$/.test(l)), log.join("|"));
  assert.ok(!log.join("\n").includes("123456789"));
});
