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
const { createLocator, commandExe, isProgramFile, inProgramFiles, signatureOK, SIGNATURE_COMMAND } = require("../../remote/locate");
const { createConnector } = require("../../remote/connect");
const { createHud, hudBounds } = require("../../remote/hud");
const { createUia, guardMs } = require("../../remote/uia");
const { SecretBuffer } = require("../../remote/secret");

const NO_LOCATOR = { candidates: () => [], refresh: async () => false, trusted: () => false, verify: async () => false };

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
// Фейковый реестр и PowerShell: execFile(file, args, opts, cb) → child со stdin. Проверка подписи отвечает по пути из stdin
// (`signed`: путь → Subject сертификата; нет — NotSigned). Пишущих команд не бывает — всё записывается.
function fakeSystem({ reg = {}, processes = "", signed = {} } = {}) {
  const calls = [], checked = [];
  const execFile = (file, args, _opts, cb) => {
    calls.push([path.win32.basename(file), ...args]);
    let stdin = "";
    const child = { stdin: { end: (b) => { stdin += b ? Buffer.from(b).toString("utf8") : ""; } } };
    setImmediate(() => {
      if (/reg\.exe$/i.test(file)) {
        const value = reg[args[1]];
        return value ? cb(null, `\r\n${args[1]}\r\n    (Default)    REG_SZ    ${value}\r\n`) : cb(new Error("not found"));
      }
      if (args.includes(SIGNATURE_COMMAND)) {
        const target = stdin.replace(/\n$/, "");
        checked.push(target);
        return cb(null, signed[target] ? `Valid|${signed[target]}\r\n` : "NotSigned|\r\n");
      }
      cb(null, processes);
    });
    return child;
  };
  return { execFile, calls, checked };
}
const ENV = { USERPROFILE: "C:\\Users\\demo", SystemRoot: "C:\\Windows", ProgramFiles: "C:\\Program Files", "ProgramFiles(x86)": "C:\\Program Files (x86)", LOCALAPPDATA: "C:\\Users\\demo\\AppData\\Local" };
const AD_CERT = "CN=AnyDesk Software GmbH, O=AnyDesk Software GmbH, L=Stuttgart, S=Baden-Württemberg, C=DE";
const TV_CERT = "CN=TeamViewer Germany GmbH, O=TeamViewer Germany GmbH, L=Göppingen, C=DE";
// Двойник AnyDesk: что запущено и что ушло в stdin (пароль).
function fakeSpawn() {
  const spawned = [];
  const spawn = (file, args) => {
    const c = new EventEmitter(); const entry = { file, args, stdin: "" }; spawned.push(entry);
    c.stdin = { on() {}, write: (b, cb) => { entry.stdin += Buffer.from(b).toString("utf8"); cb?.(); }, end() {} }; c.unref = () => {};
    setImmediate(() => c.emit("exit", 0)); return c;
  };
  return { spawn, spawned };
}

test("имена (таблица ревью FIX 1): только сам AnyDesk/TeamViewer; установщики, деинсталляторы, MSI, службы, Host_Setup, crack и QuickSupport — нет", () => {
  const table = [
    ["anyDesk", ["AnyDesk.exe", "AnyDesk (1).exe", "anydesk.EXE", "AnyDesk-portable.exe", "AnyDesk_portable (2).exe"], true],
    ["anyDesk", ["AnyDesk-installer.exe", "AnyDesk_Setup.exe", "AnyDeskSetup.exe", "AnyDesk-uninstall.exe", "AnyDeskMSI.exe", "AnyDesk_crack.exe",
      "AnyDesk Install.exe", "AnyDesk.msi", "AnyDesk.exe.lnk", "calc.exe", "My AnyDesk.exe"], false],
    ["teamViewer", ["TeamViewer.exe", "TeamViewer (1).exe", "TeamViewer_Portable.exe"], true],
    ["teamViewer", ["TeamViewer_Setup.exe", "TeamViewer_Setup_x64.exe", "TeamViewerSetup.exe", "TeamViewer_setup (1).exe", "TeamViewer-Setup.exe",
      "TeamViewer Setup.exe", "TeamViewer_Host_Setup.exe", "TeamViewer_Service.exe", "TeamViewer_Desktop.exe", "TeamViewer_Assignment.exe",
      "TeamViewerQS.exe", "TeamViewerQS (1).exe", "TeamViewer_Host.exe", "TeamViewer.msi"], false],
  ];
  for (const [program, names, ok] of table) for (const name of names) assert.equal(isProgramFile(program, `D:\\x\\${name}`), ok, `${program}: ${name}`);
});

test("подпись: Valid и издатель программы (CN или O); NotSigned, HashMismatch, чужой издатель, подпись TeamViewer у «AnyDesk.exe» — нет", () => {
  assert.equal(signatureOK("anyDesk", `Valid|${AD_CERT}`), true);
  assert.equal(signatureOK("anyDesk", "Valid|CN=philandro Software GmbH, O=philandro Software GmbH, C=DE"), true);
  assert.equal(signatureOK("teamViewer", `Valid|${TV_CERT}`), true);
  assert.equal(signatureOK("teamViewer", "Valid|CN=TeamViewer GmbH, O=TeamViewer GmbH, C=DE"), true);
  for (const [program, out] of [["anyDesk", "NotSigned|"], ["anyDesk", `HashMismatch|${AD_CERT}`], ["anyDesk", "Valid|CN=Evil Ltd, O=Evil Ltd"],
    ["anyDesk", `Valid|${TV_CERT}`], ["anyDesk", "Valid|CN=AnyDesk Software GmbH Fake, O=Other"], ["anyDesk", "Error|"], ["anyDesk", ""],
    ["teamViewer", "Valid|CN=Not TeamViewer GmbH, O=x"]]) {
    assert.equal(signatureOK(program, out), false, `${program}: ${out}`);
  }
  assert.ok(!/\$args|\{0\}|-Path\s+['"]/.test(SIGNATURE_COMMAND), "команда — константа, путь не подставляется");
  assert.match(SIGNATURE_COMMAND, /OpenStandardInput\(\), \(New-Object System\.Text\.UTF8Encoding\(\$false\)\)/, "путь — из stdin в UTF-8");
  assert.match(SIGNATURE_COMMAND, /Get-AuthenticodeSignature -LiteralPath \$p/);
  assert.equal(inProgramFiles("C:\\Program Files\\AnyDesk\\AnyDesk.exe", ENV), true);
  assert.equal(inProgramFiles("C:\\Program Files (x86)\\TeamViewer\\TeamViewer.exe", ENV), true);
  for (const f of ["C:\\Users\\demo\\Downloads\\AnyDesk.exe", "C:\\Users\\demo\\AppData\\Local\\Programs\\AnyDesk\\AnyDesk.exe", "C:\\Program Files Evil\\AnyDesk.exe",
    "C:\\Program Files\\..\\Users\\demo\\AnyDesk.exe", "AnyDesk.exe"]) assert.equal(inProgramFiles(f, ENV), false, f);
});

test("«Загрузки»: подписанный портативный AnyDesk — «установлен» и получает пароль (CLI <ID> --with-password); путь — в stdin PowerShell; итог по пути+mtime", async () => {
  const files = fakeFs({ "C:\\Users\\demo\\Downloads": { "AnyDesk.exe": 100, "AnyDesk (1).exe": 200, "AnyDesk-installer.exe": 300, "TeamViewerQS.exe": 50 } });
  const sys = fakeSystem({ signed: { "C:\\Users\\demo\\Downloads\\AnyDesk (1).exe": AD_CERT } });
  const locator = createLocator({ fs: files, env: ENV, execFile: sys.execFile });
  assert.deepEqual(locator.candidates("anyDesk"), ["C:\\Users\\demo\\Downloads\\AnyDesk (1).exe", "C:\\Users\\demo\\Downloads\\AnyDesk.exe"], "новые первыми, установщик — нет");
  assert.deepEqual(locator.candidates("teamViewer"), [], "QuickSupport — нет");
  const { spawn, spawned } = fakeSpawn();
  const connector = createConnector({ exists: files.existsSync, env: ENV, locate: (p) => locator.candidates(p), trust: locator, spawn });
  assert.equal(connector.installed("anyDesk"), false, "до проверки подписи — не «установлен»");
  assert.equal(await locator.refresh(), true);
  assert.equal(connector.installed("anyDesk"), true);
  assert.ok(sys.checked.includes("C:\\Users\\demo\\Downloads\\AnyDesk (1).exe"), "путь ушёл в stdin");
  assert.ok(sys.calls.filter((c) => c[0] === "powershell.exe" && c.includes(SIGNATURE_COMMAND)).every((c) => !c.join(" ").includes("Downloads")), "путь не в строке команды");
  const r = await connector.connectRecord({ name: "Демо", id: "123456789", hasPassword: true, program: "anyDesk" },
    { settings: { defaultProgram: "anyDesk", programPaths: {} }, store: { password: async () => new SecretBuffer("Demo-Pw-1") } });
  assert.deepEqual(r, { ok: true });
  assert.deepEqual([spawned[0].file, spawned[0].args, spawned[0].stdin], ["C:\\Users\\demo\\Downloads\\AnyDesk (1).exe", ["123456789", "--with-password"], "Demo-Pw-1\n"]);
  const before = sys.checked.length;
  await locator.verify("anyDesk", "C:\\Users\\demo\\Downloads\\AnyDesk (1).exe");
  assert.equal(sys.checked.length, before, "тот же файл (путь и mtime) — без повторной проверки");
});

test("неподписанный двойник AnyDesk.exe в «Загрузках» не запускается и пароль не получает: «без подписи — пароль не передан»", async () => {
  const files = fakeFs({ "C:\\Users\\demo\\Downloads": { "AnyDesk.exe": 100 }, "C:\\Users\\demo\\Desktop": { "AnyDesk (2).exe": 50 } });
  const sys = fakeSystem({ signed: { "C:\\Users\\demo\\Desktop\\AnyDesk (2).exe": "CN=Evil Ltd, O=Evil Ltd" } });
  const locator = createLocator({ fs: files, env: ENV, execFile: sys.execFile });
  await locator.refresh();
  const { spawn, spawned } = fakeSpawn();
  const states = [], log = [];
  let reads = 0;
  const connector = createConnector({ exists: files.existsSync, env: ENV, locate: (p) => locator.candidates(p), trust: locator, spawn,
    hud: { show: (s) => states.push(s) }, log: (l) => log.push(l) });
  assert.equal(connector.installed("anyDesk"), false, "плашка «не найден» остаётся, записи приглушены");
  const r = await connector.connectRecord({ name: "Демо", id: "123456789", hasPassword: true, program: "anyDesk" },
    { settings: { defaultProgram: "anyDesk", programPaths: {} }, store: { password: async () => { reads++; return new SecretBuffer("Demo-Pw-1"); } } });
  assert.deepEqual(r, { ok: false, error: "unsigned" });
  assert.equal(spawned.length, 0, "ничего не запущено");
  assert.equal(reads, 0, "пароль даже не читался");
  assert.equal(states.at(-1).title, "AnyDesk без подписи — пароль не передан");
  assert.deepEqual(log, ["connect fail code=unsigned program=anyDesk"]);
  // Свой путь из настроек вне Program Files — тоже только с подписью.
  const custom = await connector.connectRecord({ name: "Демо", id: "123456789", hasPassword: true, program: "anyDesk" },
    { settings: { defaultProgram: "anyDesk", programPaths: { anyDesk: "C:\\Users\\demo\\Downloads\\AnyDesk.exe" } }, store: { password: async () => { reads++; return null; } } });
  assert.equal(custom.error, "unsigned");
  assert.equal(spawned.length, 0);
});

test("порядок: свой путь → Program Files/%LOCALAPPDATA% → реестр/App Paths → «Загрузки»/Рабочий стол → процесс", async () => {
  const pf = "C:\\Program Files\\AnyDesk\\AnyDesk.exe", local = "C:\\Users\\demo\\AppData\\Local\\Programs\\AnyDesk\\AnyDesk.exe";
  const regExe = "D:\\Apps\\AnyDesk\\AnyDesk.exe", dl = "C:\\Users\\demo\\Downloads\\AnyDesk.exe", own = "E:\\Mine\\AnyDesk.exe";
  const all = { [own]: 1, [pf]: 1, [local]: 1, [regExe]: 1, [dl]: 1 };
  const signed = Object.fromEntries([own, local, regExe, dl].map((f) => [f, AD_CERT]));
  const make = (present) => {
    const tree = {};
    for (const f of Object.keys(all).filter((f) => present.includes(f))) { const dir = path.win32.dirname(f); (tree[dir] ||= {})[path.win32.basename(f)] = 1; }
    const files = fakeFs(tree);
    const sys = fakeSystem({ reg: { "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\AnyDesk.exe": `"${regExe}"` }, signed });
    const locator = createLocator({ fs: files, env: ENV, execFile: sys.execFile });
    return { locator, connector: createConnector({ exists: files.existsSync, env: ENV, locate: (p) => locator.candidates(p), trust: locator, spawn: fakeSpawn().spawn }) };
  };
  for (const [present, custom, expected] of [
    [[own, pf, local, regExe, dl], own, own], [[pf, local, regExe, dl], "", pf], [[local, regExe, dl], "", local], [[regExe, dl], "", regExe], [[dl], "", dl]]) {
    const { locator, connector } = make(present);
    await locator.refresh({ anyDesk: [custom, local].filter(Boolean) });
    assert.equal(connector.find("anyDesk", custom), expected, `${present.length}: ${expected}`);
  }
});

test("реестр (только reg query): обработчик anydesk: и App Paths; teamviewer10:/tvcontrol1:; процесс — только если остальное пусто", async () => {
  assert.equal(commandExe('"C:\\Tools\\AnyDesk.exe" "%1"'), "C:\\Tools\\AnyDesk.exe");
  assert.equal(commandExe("C:\\Tools\\AnyDesk.exe --url %1"), "C:\\Tools\\AnyDesk.exe");
  assert.equal(commandExe("rundll32 url.dll"), null);
  const sys = fakeSystem({ reg: {
    "HKCU\\Software\\Classes\\anydesk\\shell\\open\\command": '"C:\\Users\\demo\\Tools\\AnyDesk.exe" "%1"',
    "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\TeamViewer.exe": "%ProgramFiles%\\TV15\\TeamViewer.exe",
  } });
  const locator = createLocator({ fs: fakeFs({ "C:\\Users\\demo\\Tools": { "AnyDesk.exe": 1 }, "C:\\Program Files\\TV15": { "TeamViewer.exe": 1 } }), env: ENV, execFile: sys.execFile });
  await locator.refresh();
  assert.deepEqual(locator.candidates("anyDesk"), ["C:\\Users\\demo\\Tools\\AnyDesk.exe"]);
  assert.deepEqual(locator.candidates("teamViewer"), ["C:\\Program Files\\TV15\\TeamViewer.exe"]);
  assert.equal(locator.trusted("teamViewer", "C:\\Program Files\\TV15\\TeamViewer.exe"), true, "Program Files — без проверки подписи");
  assert.equal(locator.trusted("anyDesk", "C:\\Users\\demo\\Tools\\AnyDesk.exe"), false, "HKCU указывает в профиль — подпись не подтверждена");
  for (const call of sys.calls.filter((c) => c[0] === "reg.exe")) assert.equal(call[1], "query", "в реестр не пишем");
  assert.ok(sys.calls.some((c) => c[0] === "reg.exe" && c[2] === "HKCU\\Software\\Classes\\tvcontrol1\\shell\\open\\command"));
  // Обработчик указывает не на программу (или на службу TeamViewer) — не берём. Ничего не найдено — путь запущенного процесса.
  const proc = fakeSystem({ reg: { "HKCR\\anydesk\\shell\\open\\command": '"C:\\evil\\calc.exe" "%1"' },
    processes: "C:\\Users\\demo\\Desktop\\Old\\AnyDesk.exe\r\nC:\\Program Files\\TeamViewer\\TeamViewer_Service.exe\r\n" });
  const byProcess = createLocator({ fs: fakeFs({}), env: ENV, execFile: proc.execFile });
  await byProcess.refresh();
  assert.deepEqual(byProcess.candidates("anyDesk"), ["C:\\Users\\demo\\Desktop\\Old\\AnyDesk.exe"]);
  assert.deepEqual(byProcess.candidates("teamViewer"), [], "служба TeamViewer_Service — не программа");
  assert.ok(proc.calls.some((c) => c[0] === "powershell.exe" && c.join(" ").includes("Get-Process -Name 'AnyDesk*'")));
  assert.ok(!proc.calls.some((c) => /Set-|New-Item|Remove-|reg add|reg delete/i.test(c.join(" "))), "только чтение");
});

test("«Указать AnyDesk.exe…»: файл с подписью AnyDesk — сохраняется; без подписи — честное предупреждение, путь не сохранён; не тот файл — тоже", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rc-entry-"));
  const fake = fakeElectron();
  const good = "C:\\Users\\demo\\Downloads\\AnyDesk (1).exe", bad = "C:\\Users\\demo\\Downloads\\AnyDesk.exe";
  const verified = [];
  const locator = { ...NO_LOCATOR, verify: async (program, file) => { verified.push([program, file]); return file === good; } };
  const huds = [];
  const rc = init(fake.electron, { userData: dir, locator, hud: { show: (s) => huds.push(s) } });
  fake.setPick(good);
  assert.deepEqual(await fake.handles.get("rc:pickProgram")(sender(fake, rc), "anyDesk"), { ok: true });
  assert.equal(rc.settings.data.programPaths.anyDesk, good);
  fake.setPick(bad);
  assert.deepEqual(await fake.handles.get("rc:pickProgram")(sender(fake, rc), "anyDesk"), { ok: false, error: "signature" });
  assert.equal(rc.settings.data.programPaths.anyDesk, good, "путь без подписи не сохранён");
  assert.equal(huds.at(-1).title, "Подпись AnyDesk не подтверждена");
  assert.match(huds.at(-1).detail, /пароль ему не передаётся, путь не сохранён/);
  fake.setPick("C:\\Users\\demo\\Downloads\\AnyDesk-installer.exe");
  assert.deepEqual(await fake.handles.get("rc:pickProgram")(sender(fake, rc), "anyDesk"), { ok: false, error: "name" });
  assert.equal(huds.at(-1).title, "Это не AnyDesk");
  assert.deepEqual(verified, [["anyDesk", good], ["anyDesk", bad]], "установщик даже не проверялся");
  assert.deepEqual(await fake.handles.get("rc:pickProgram")({ sender: { id: 99 } }, "anyDesk"), { ok: false, error: "denied" }, "только от окон модуля");
  assert.deepEqual(await fake.handles.get("rc:pickProgram")(sender(fake, rc), "../../evil"), { ok: false, error: "program" });
  const r = await fake.handles.get("rc:setSettings")(sender(fake, rc), { programPaths: { anyDesk: "D:\\Soft\\AnyDesk-portable.exe", teamViewer: "D:\\x\\TeamViewerQS.exe" } });
  assert.equal(r.programPaths.anyDesk, "D:\\Soft\\AnyDesk-portable.exe");
  assert.equal(r.programPaths.teamViewer, "", "QuickSupport в настройки не принимается");
  rc.dispose();
  const js = fs.readFileSync(path.join(__dirname, "../../remote/ui/remote.js"), "utf8");
  assert.match(js, /pick\.onclick = async \(\) => \{ if \(\(await window\.rc\.pickProgram\(p\)\)\?\.ok\) refresh\(\); \}/);
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
