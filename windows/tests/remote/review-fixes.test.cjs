// Правки по ревью «Удалённые подключения» (Windows): упаковка, горячая клавиша, UTF-8, ошибки процессов, защита в глубину.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const { createConnector } = require("../../remote/connect");
const { createUia, SCRIPT, POWERSHELL } = require("../../remote/uia");
const { SecretBuffer } = require("../../remote/secret");
const { hotkeyProblem, DEFAULTS } = require("../../remote/settings");

const root = path.join(__dirname, "..", "..");
const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));

// ---- W-R1: упаковка ----
// Файл покрыт build.files: точное имя или шаблон «папка/**».
const covered = (rel, patterns) => patterns.some((p) => p === rel || (p.endsWith("/**") && rel.startsWith(p.slice(0, -2))));
function requiredFiles(entry, seen = new Set()) {
  if (seen.has(entry)) return seen;
  seen.add(entry);
  const code = fs.readFileSync(path.join(root, entry), "utf8");
  for (const m of code.matchAll(/require\(["'](\.{1,2}\/[^"']+)["']\)/g)) {
    let rel = path.posix.normalize(path.posix.join(path.posix.dirname(entry), m[1]));
    for (const candidate of [rel, `${rel}.js`, `${rel}/index.js`]) {
      if (fs.existsSync(path.join(root, candidate)) && fs.statSync(path.join(root, candidate)).isFile()) { requiredFiles(candidate, seen); break; }
    }
  }
  return seen;
}

test("W-R1: установщик включает всё, что main.js подтягивает через require (в том числе remote/)", () => {
  const files = [...requiredFiles("main.js")];
  assert.ok(files.some((f) => f.startsWith("remote/")), "main.js подключает модуль remote/");
  for (const f of files) assert.ok(covered(f, pkg.build.files), `${f} не входит в build.files — в установщике require упадёт`);
});

test("W-R1: окна, preload, стили и скрипт UI Automation модуля тоже упакованы; скрипт распакован из asar", () => {
  for (const f of ["remote/ui/remote.html", "remote/ui/remote.js", "remote/ui/remote.css", "remote/ui/preload.js", "remote/ui/hud.html", "remote/ui/hud.js", "remote/ui/hud-preload.js", "remote/tv-uia.ps1"]) {
    assert.ok(fs.existsSync(path.join(root, f)), f);
    assert.ok(covered(f, pkg.build.files), f);
  }
  assert.ok(pkg.build.asarUnpack.includes("remote/tv-uia.ps1"), "powershell -File не читает файл внутри app.asar");
  assert.ok(!SCRIPT.includes(`${path.sep}app.asar${path.sep}`));
});

test("W-R1: в упакованном приложении путь к скрипту ведёт в app.asar.unpacked", () => {
  const rewritten = "C:\\Program Files\\Mac Utils Share\\resources\\app.asar\\remote\\tv-uia.ps1".replace(/([\\/])app\.asar([\\/])/, "$1app.asar.unpacked$2");
  assert.equal(rewritten, "C:\\Program Files\\Mac Utils Share\\resources\\app.asar.unpacked\\remote\\tv-uia.ps1");
});

// ---- W-R2: клавиша ----
test("W-R2: сочетание по умолчанию — без Ctrl+Alt (AltGr), не Ctrl+Shift+Space (Excel); проверка сочетаний", () => {
  assert.equal(DEFAULTS.hotkey, "Win+Shift+A");
  assert.equal(hotkeyProblem(DEFAULTS.hotkey), "");
  assert.equal(hotkeyProblem("Ctrl+Alt+A"), "altgr");
  assert.equal(hotkeyProblem("Control+Alt+Shift+A"), "altgr");
  assert.equal(hotkeyProblem("Ctrl+Alt+Win+A"), "");
  assert.equal(hotkeyProblem("A"), "noModifier");
  assert.equal(hotkeyProblem("Shift+A"), "noModifier");
  assert.equal(hotkeyProblem("Ctrl+Shift+"), "noKey");
  assert.equal(hotkeyProblem("Ctrl+Shift+Space"), "");
  assert.equal(hotkeyProblem("Ctrl+Alt"), "noKey");
});

// ---- W-R3: UTF-8 ----
test("W-R3: пароль не на латинице уходит в stdin PowerShell байтами UTF-8, скрипт читает UTF-8", () => {
  const password = "Пароль-€-ąę-密码";
  const written = [];
  const spawn = () => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter(); child.kill = () => {};
    child.stdin = Object.assign(new EventEmitter(), { write: (d, cb) => { written.push(Buffer.from(d)); cb?.(); }, end() {} });
    setImmediate(() => { child.stdout.emit("data", Buffer.from('{"state":"entered"}\n')); child.emit("exit", 0); });
    return child;
  };
  return createUia(spawn).enter({ timeoutMs: 5000 }, new SecretBuffer(password)).then((result) => {
    assert.equal(result.state, "entered");
    assert.equal(Buffer.concat(written).toString("utf8"), `{"timeoutMs":5000}\n${password}\n`);
  });
});

// ---- W-R4: ошибки процессов и stdin ----
function failingChild({ stdinError = true, processError = false } = {}) {
  const child = new EventEmitter();
  child.stdout = new EventEmitter(); child.kill = () => {}; child.unref = () => {};
  child.stdin = new EventEmitter();
  child.stdin.write = (_d, cb) => { if (stdinError) setImmediate(() => child.stdin.emit("error", Object.assign(new Error("write EPIPE"), { code: "EPIPE" }))); cb?.(); return true; };
  child.stdin.end = () => {};
  if (processError) setImmediate(() => child.emit("error", Object.assign(new Error("spawn ENOENT"), { code: "ENOENT" })));
  return child;
}
const settings = { defaultProgram: "anyDesk", timeoutSeconds: 20, programPaths: {} };
const record = (extra = {}) => ({ sourceRow: 2, name: "Касса", id: "123456789", program: null, hasPassword: true, ...extra });
const AD = "C:\\Program Files (x86)\\AnyDesk\\AnyDesk.exe", TV = "C:\\Program Files\\TeamViewer\\TeamViewer.exe";

test("W-R4: AnyDesk — ошибка stdin/процесса не роняет главный процесс (нет необработанного 'error'), пользователь видит ошибку", async () => {
  for (const opts of [{ stdinError: true }, { processError: true, stdinError: false }]) {
    const states = [];
    const connector = createConnector({ exists: (p) => p === AD, spawn: () => failingChild(opts), hud: { show: (s) => states.push(s) } });
    const store = { password: async () => new SecretBuffer("pw") };
    let uncaught = null;
    const onUncaught = (e) => { uncaught = e; };
    process.once("uncaughtException", onUncaught);
    const result = await connector.connectRecord(record(), { settings, store, noPassword: false });
    await new Promise((r) => setImmediate(r));
    process.removeListener("uncaughtException", onUncaught);
    assert.equal(uncaught, null, "необработанное исключение");
    assert.equal(result.ok, false);
    assert.equal(states.at(-1).kind, "danger");
  }
});

test("W-R4: UI Automation — нет powershell.exe / запись в закрытый stdin: ответ «поле не найдено», без падения", async () => {
  for (const opts of [{ processError: true, stdinError: false }, { stdinError: true }]) {
    const uia = createUia(() => failingChild(opts));
    let uncaught = null;
    const onUncaught = (e) => { uncaught = e; };
    process.once("uncaughtException", onUncaught);
    const result = await uia.enter({ timeoutMs: 5000 }, new SecretBuffer("pw"));
    await new Promise((r) => setImmediate(r));
    process.removeListener("uncaughtException", onUncaught);
    assert.equal(uncaught, null);
    assert.equal(result.state, "fieldNotFound");
  }
});

// ---- W-R5: копии пароля затираются ----
test("W-R5: копия пароля с переводом строки затирается после записи (AnyDesk и UI Automation)", async () => {
  const captured = [];
  const spawn = (file, args) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter(); child.kill = () => {}; child.unref = () => {};
    child.stdin = Object.assign(new EventEmitter(), { write: (d, cb) => { captured.push(d); cb?.(); return true; }, end() {} });
    setImmediate(() => { child.stdout.emit("data", Buffer.from('{"state":"entered"}\n')); child.emit("exit", 0); });
    return child;
  };
  const connector = createConnector({ exists: (p) => p === AD, spawn, hud: { show() {} } });
  await connector.connectRecord(record(), { settings, store: { password: async () => new SecretBuffer("СЕКРЕТ") }, noPassword: false });
  assert.ok(captured.length >= 1 && captured.every((b) => !Buffer.isBuffer(b) || b.every((x) => x === 0) || !b.includes("СЕКРЕТ")), "копия AnyDesk затёрта");
  captured.length = 0;
  await createUia(spawn).enter({ timeoutMs: 5000 }, new SecretBuffer("СЕКРЕТ"));
  const payloads = captured.filter((b) => Buffer.isBuffer(b) && b.length > 0 && !b.toString().startsWith("{"));
  assert.ok(payloads.length === 1 && payloads[0].every((x) => x === 0), "копия UIA затёрта");
});

test("W-R5: буфер файла с паролями всех записей затирается после поиска пароля", async () => {
  const fsx = require("node:fs"), os = require("node:os");
  const F = require("./fixtures");
  const { ConnectionsFileStore } = require("../../remote/filestore");
  const dir = fsx.mkdtempSync(path.join(os.tmpdir(), "rc-w5-"));
  const file = path.join(dir, "list.xlsx");
  fsx.writeFileSync(file, F.xlsxRows([["Name", "ID", "Password"], ["A", "123456789", "pw-a"]]));
  const store = new ConnectionsFileStore({ debounceMs: 20, retryMs: 20, pollMs: 30 });
  const seen = [];
  const realRead = fsx.promises.readFile;
  fsx.promises.readFile = async (...a) => { const data = await realRead.apply(fsx.promises, a); seen.push(data); return data; };
  try {
    store.setSource(file);
    for (let i = 0; i < 200 && store.state.status !== "ready"; i++) await new Promise((r) => setTimeout(r, 10));
    const secret = await store.password(store.state.snapshot.records[0]);
    assert.equal(secret.bytes.toString(), "pw-a");
    assert.ok(seen.at(-1).every((b) => b === 0), "буфер файла затёрт");
    secret.wipe();
  } finally { fsx.promises.readFile = realRead; store.stop(); }
});

// ---- W-R9/W-R13: TeamViewer запускается после «готов»; параллельные вызовы UI Automation независимы ----
test("W-R9: TeamViewer запускается, только когда скрипт запомнил открытые окна пароля (afterReady)", async () => {
  const order = [];
  const spawn = (file, args) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter(); child.kill = () => {}; child.unref = () => {};
    child.stdin = Object.assign(new EventEmitter(), { write: (_d, cb) => { cb?.(); return true; }, end() {} });
    if (/powershell/i.test(file)) {
      order.push("powershell");
      setImmediate(() => { order.push("ready"); child.stdout.emit("data", Buffer.from('{"state":"ready"}\n')); setTimeout(() => { child.stdout.emit("data", Buffer.from('{"state":"entered"}\n')); child.emit("exit", 0); }, 20); });
    } else order.push("teamviewer");
    return child;
  };
  const connector = createConnector({ exists: (p) => p === TV, spawn, uia: createUia(spawn), hud: { show() {} } });
  const result = await connector.connectRecord(record({ program: "teamViewer" }), { settings, store: { password: async () => new SecretBuffer("pw") }, noPassword: false });
  assert.equal(result.ok, true);
  assert.deepEqual(order, ["powershell", "ready", "teamviewer"]);
});

test("W-R13: отмена одного вызова не задевает другой; у каждого свой процесс и признак", async () => {
  const children = [];
  const spawn = () => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter(); child.stdin = Object.assign(new EventEmitter(), { write: (_d, cb) => { cb?.(); return true; }, end() {} });
    child.kill = () => child.emit("exit", 1);
    children.push(child);
    return child;
  };
  const uia = createUia(spawn);
  const a = uia.enter({ timeoutMs: 5000 }, new SecretBuffer("a")), b = uia.enter({ timeoutMs: 5000 }, new SecretBuffer("b"));
  uia.cancel();
  assert.deepEqual([(await a).state, (await b).state], ["cancelled", "cancelled"]);
  const c = uia.enter({ timeoutMs: 5000 }, new SecretBuffer("c"));
  children.at(-1).stdout.emit("data", Buffer.from('{"state":"entered"}\n'));
  assert.equal((await c).state, "entered", "отмена прошлого вызова не влияет на новый");
});

// ---- W-R10, W-R11 ----
test("W-R10: powershell.exe — полный путь из системной папки, не по PATH", () => {
  assert.match(POWERSHELL, /^[A-Za-z]:\\.*\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe$/);
});

test("W-R11: ID, начинающийся с «-», не передаётся программе (принял бы за параметр)", async () => {
  const spawned = [];
  const connector = createConnector({ exists: (p) => p === AD, spawn: (...a) => { spawned.push(a); return failingChild({ stdinError: false }); }, hud: { show() {} } });
  const result = await connector.connectRecord(record({ id: "-evil@ad", hasPassword: false }), { settings, store: {}, noPassword: false });
  assert.deepEqual(result, { ok: false, error: "badID" });
  assert.equal(spawned.length, 0);
});

// ---- Windows: запись XML при read-only файле (имитация семантики NTFS на любой ОС) ----
test("Windows (имитация NTFS): rename/удаление read-only файла → EPERM; правка всё равно проходит, атрибут и .bak сохраняются", () => {
  const os = require("node:os");
  const editor = require("../../remote/editor");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mu-ntfs-"));
  const file = path.join(dir, "list.xml");
  fs.writeFileSync(file, '<?xml version="1.0"?>\n<connections>\n  <c><name>A</name><id>123456789</id></c>\n</connections>\n');
  fs.chmodSync(file, 0o444);
  const ro = (f) => { try { return (fs.statSync(f).mode & 0o200) === 0; } catch (_) { return false; } };
  const real = { rename: fs.renameSync, rm: fs.rmSync, copy: fs.copyFileSync, write: fs.writeFileSync };
  const eperm = () => Object.assign(new Error("EPERM"), { code: "EPERM" });
  let renameFails = 0;
  const platform = Object.getOwnPropertyDescriptor(process, "platform");
  Object.defineProperty(process, "platform", { value: "win32" });
  fs.renameSync = (a, b) => { if (ro(b)) throw eperm(); if (renameFails++ < 1) throw eperm(); return real.rename(a, b); };   // первый раз — «антивирус держит файл»
  fs.rmSync = (f, o) => { if (ro(f)) throw eperm(); return real.rm(f, o); };
  try {
    for (const id of ["555666777", "555666778"]) {
      assert.deepEqual(editor.apply(file, "add", { fields: { name: `N${id}`, id } }), { ok: true }, "правка read-only файла");
      assert.ok(ro(file), "атрибут только для чтения возвращён");
    }
    assert.ok(fs.readFileSync(file, "utf8").includes("555666778"));
    assert.ok(fs.readFileSync(`${file}.bak`, "utf8").includes("555666777") && !fs.readFileSync(`${file}.bak`, "utf8").includes("555666778"), ".bak — предыдущая версия");
    assert.deepEqual(fs.readdirSync(dir).sort(), ["list.xml", "list.xml.bak"], "лишних файлов нет");
  } finally {
    fs.renameSync = real.rename; fs.rmSync = real.rm; fs.copyFileSync = real.copy; fs.writeFileSync = real.write;
    Object.defineProperty(process, "platform", platform);
    for (const f of [file, `${file}.bak`]) { try { fs.chmodSync(f, 0o666); } catch (_) {} }
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
