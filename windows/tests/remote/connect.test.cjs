// Подключение: AnyDesk (CLI, пароль через stdin), TeamViewer (запуск с ID + UI Automation), ошибки, пароль нигде. Реальные
// программы не запускаются — двойники процессов и UI Automation.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const F = require("./fixtures");
const { createConnector } = require("../../remote/connect");
const { createUia } = require("../../remote/uia");
const { SecretBuffer } = require("../../remote/secret");

const AD = "C:\\Program Files (x86)\\AnyDesk\\AnyDesk.exe", TV = "C:\\Program Files\\TeamViewer\\TeamViewer.exe";
const PASSWORD = "PWD-CANARY-секрет-77";
const settings = { defaultProgram: "anyDesk", timeoutSeconds: 20, programPaths: {} };
const record = (extra = {}) => ({ sourceRow: 2, name: "Лаборатория Север", id: "123456789", program: null, hasPassword: true, ...extra });

function rig({ installed = [AD, TV], secret = PASSWORD, uiaResult = { state: "connected" }, exit = null, passwordThrows = false } = {}) {
  const log = [], states = [], spawned = [], opened = [];
  const fakeSpawn = (file, args, opts) => {
    const child = new EventEmitter();
    const chunks = [];
    child.stdin = { write: (data, cb) => { chunks.push(Buffer.from(data)); cb?.(); }, end() {} };
    child.unref = () => {};
    spawned.push({ file, args, opts, chunks });
    if (exit !== null) setImmediate(() => child.emit("exit", exit));
    return child;
  };
  let secretRef = null;
  const store = { password: async () => { if (passwordThrows) throw new Error("gone"); if (secret == null) return null; secretRef = new SecretBuffer(secret); return secretRef; } };
  const uiaCalls = [];
  const uia = { enter: async (opts, password, onEvent) => { await opts.afterReady?.(); const s = typeof password === "function" ? await password() : password; uiaCalls.push({ opts, bytes: s ? Buffer.from(s.bytes) : null }); onEvent({ state: "waiting" }); return uiaResult; }, cancel() { uiaCalls.cancelled = true; } };
  const connector = createConnector({ exists: (p) => installed.includes(p), spawn: fakeSpawn, uia, hud: { show: (s) => states.push(s) }, openExternal: (u) => opened.push(u), log: (l) => log.push(l) });
  return { connector, states, spawned, log, opened, store, uiaCalls, get secret() { return secretRef; } };
}
const run = (r, rec = record(), opts = {}) => r.connector.connectRecord(rec, { settings, store: r.store, noPassword: false, ...opts });
const everything = (r) => JSON.stringify([r.states, r.log, r.spawned.map((s) => [s.file, s.args, s.opts])]);

test("AnyDesk: ID и --with-password в аргументах, пароль — только в stdin; пароля нет нигде; затирается", async () => {
  const r = rig();
  const result = await run(r);
  assert.deepEqual(result, { ok: true });
  assert.equal(r.spawned.length, 1);
  assert.equal(r.spawned[0].file, AD);
  assert.deepEqual(r.spawned[0].args, ["123456789", "--with-password"]);
  assert.equal(Buffer.concat(r.spawned[0].chunks).toString(), PASSWORD + "\n");
  assert.ok(!everything(r).includes(PASSWORD), "пароль в аргументах, тостах или журнале");
  assert.ok(r.secret.isWiped, "пароль затёрт");
  assert.ok(r.states.some((s) => /Открываю AnyDesk/.test(s.title)));
  // CLI подключение не подтверждает: тост нейтральный, не «успех».
  assert.equal(r.states.at(-1).kind, "info");
  assert.match(r.states.at(-1).title, /Пароль передан/);
  assert.ok(!r.states.some((s) => s.kind === "success"));
  assert.ok(r.log.every((l) => /^connect (ok|fail) [A-Za-z0-9=_ ]+$/.test(l)), r.log.join("|"));
});

test("AnyDesk без пароля: только ID, stdin не используется; ⌘↩-вариант (noPassword) тоже", async () => {
  for (const [rec, opts] of [[record({ hasPassword: false }), {}], [record(), { noPassword: true }]]) {
    const r = rig();
    await run(r, rec, opts);
    assert.deepEqual(r.spawned[0].args, ["123456789"]);
    assert.equal(r.spawned[0].chunks.length, 0);
  }
});

test("алиас AnyDesk передаётся как есть", async () => {
  const r = rig();
  await run(r, record({ id: "office@ad", hasPassword: false }));
  assert.deepEqual(r.spawned[0].args, ["office@ad"]);
});

test("программы нет: ошибка со ссылкой на загрузку, ничего не запускается", async () => {
  const r = rig({ installed: [] });
  assert.deepEqual(await run(r), { ok: false, error: "notInstalled" });
  assert.equal(r.spawned.length, 0);
  assert.equal(r.states.at(-1).kind, "danger");
  assert.ok(r.states.at(-1).actions.some((a) => a.id === "download"));
  assert.equal(r.connector.installed("anyDesk"), false);
});

test("записи больше нет в файле / пароля в файле нет", async () => {
  const gone = rig({ passwordThrows: true });
  assert.deepEqual(await run(gone), { ok: false, error: "gone" });
  assert.equal(gone.spawned.length, 0);
  assert.match(gone.states.at(-1).title, /Записи больше нет/);
  const noPw = rig({ secret: null });
  assert.deepEqual(await run(noPw), { ok: true });
  assert.ok(noPw.states.some((s) => /Пароля в файле нет/.test(s.title)));
});

test("процесс не принял команду → ошибка с «Повторить»", async () => {
  const r = rig({ exit: 1 });
  assert.deepEqual(await run(r), { ok: false, error: "launch" });
  assert.ok(r.states.at(-1).actions.some((a) => a.id === "retry"));
});

test("TeamViewer: запуск с -i ID без пароля в аргументах; пароль вводит UI Automation; затирается", async () => {
  const r = rig();
  const result = await run(r, record({ program: "teamViewer" }));
  assert.deepEqual(result, { ok: true });
  assert.equal(r.spawned[0].file, TV);
  assert.deepEqual(r.spawned[0].args, ["-i", "123456789"]);
  assert.equal(r.uiaCalls[0].bytes.toString(), PASSWORD);
  assert.equal(r.uiaCalls[0].opts.timeoutMs, 60_000);
  assert.equal(r.uiaCalls[0].opts.limitMs, 180_000);
  assert.ok(!everything(r).includes(PASSWORD));
  assert.ok(r.secret.isWiped);
  assert.ok(r.states.some((s) => /Жду окно пароля/.test(s.title)));
  assert.equal(r.states.at(-1).title, "Подключено");
});

test("TeamViewer: исходы UI Automation → тосты по дизайну; пароль затёрт в каждом", async () => {
  const cases = [
    ["connected", true, /^Подключено$/], ["entered", false, /сеанс не подтверждён/], ["submitted", false, /сеанс не подтверждён/], ["sessionClosed", false, /закрыл сеанс/],
    ["session", true, /Подключено без пароля/], ["noPrompt", false, /Не удалось подключиться — ID скопирован|Не удалось подтвердить подключение/],
    ["noWindow", false, /TeamViewer не открылся/], ["passwordNeeded", true, /Введите пароль в окне TeamViewer/], ["idMismatch", false, /от другого компьютера/],
    ["wrongPassword", false, /Проверьте пароль в файле/], ["focusLost", false, /Ввод прерван/],
    ["elevated", false, /запущен от администратора/], ["fieldNotFound", false, /Введите пароль вручную/], ["cancelled", false, /Отменено/],
  ];
  for (const [state, ok, title] of cases) {
    const r = rig({ uiaResult: { state } });
    const result = await run(r, record({ program: "teamViewer" }));
    assert.equal(result.ok, ok, state);
    assert.match(r.states.at(-1).title, title, state);
    assert.ok(r.secret.isWiped, `${state}: пароль не затёрт`);
    assert.ok(!everything(r).includes(PASSWORD), state);
  }
});

test("TeamViewer без пароля — UI Automation без пароля (ID и подтверждение сеанса); алиас у TeamViewer не принимается", async () => {
  const r = rig({ uiaResult: { state: "session" } });
  assert.deepEqual(await run(r, record({ program: "teamViewer", hasPassword: false })), { ok: true });
  assert.equal(r.uiaCalls.length, 1);
  assert.equal(r.uiaCalls[0].bytes, null, "пароля нет — в UI Automation ничего не передаётся");
  assert.equal(r.uiaCalls[0].opts.noPassword, true);
  assert.equal(r.uiaCalls[0].opts.id, "123456789");
  assert.deepEqual(await run(rig(), record({ program: "teamViewer", id: "x@ad" })), { ok: false, error: "alias" });
});

test("программа по умолчанию и алиас: запись без программы идёт в программу по умолчанию, алиас — в AnyDesk", async () => {
  const r = rig();
  await run(r, record({ hasPassword: false }), { settings: { ...settings, defaultProgram: "teamViewer" } });
  assert.equal(r.spawned[0].file, TV);
  const r2 = rig();
  await run(r2, record({ id: "office@ad", hasPassword: false }), { settings: { ...settings, defaultProgram: "teamViewer" } });
  assert.equal(r2.spawned[0].file, AD);
});

test("свой путь к программе из настроек", async () => {
  const r = rig({ installed: ["D:\\Tools\\AnyDesk.exe"] });
  await run(r, record({ hasPassword: false }), { settings: { ...settings, programPaths: { anyDesk: "D:\\Tools\\AnyDesk.exe" } } });
  assert.equal(r.spawned[0].file, "D:\\Tools\\AnyDesk.exe");
});

// ---- UI Automation: запуск PowerShell ----
function fakePowerShell(lines, { exitAfter = true } = {}) {
  const calls = [];
  const spawn = (file, args, opts) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    const written = [];
    child.stdin = { write: (d, cb) => { written.push(Buffer.from(d)); cb?.(); }, end() {} };
    child.kill = () => child.emit("exit", 1);
    calls.push({ file, args, opts, written });
    // Как скрипт: после «passwordField» ждёт вторую строку stdin (пароль) и только потом продолжает.
    setImmediate(async () => {
      for (const l of lines) {
        const had = written.length;
        child.stdout.emit("data", Buffer.from(JSON.stringify(l) + "\n"));
        if (l.state === "passwordField") for (let i = 0; i < 50 && written.length === had; i++) await new Promise((r) => setTimeout(r, 2));
      }
      if (exitAfter) child.emit("exit", 0);
    });
    return child;
  };
  return { spawn, calls };
}

test("UI Automation: пароль и параметры — только через stdin, в аргументах PowerShell пароля нет; события доходят", async () => {
  const ps = fakePowerShell([{ state: "waiting" }, { state: "waiting" }, { state: "passwordField" }, { state: "confirming" }, { state: "connected" }]);
  const uia = createUia(ps.spawn);
  const events = [];
  const secret = new SecretBuffer(PASSWORD);
  const result = await uia.enter({ timeoutMs: 20_000 }, secret, (e) => events.push(e.state));
  assert.deepEqual(result, { state: "connected" });
  assert.deepEqual(events, ["waiting", "waiting", "confirming"], "passwordField — запрос пароля, не событие для окна");
  assert.ok(!JSON.stringify(ps.calls[0].args).includes(PASSWORD));
  assert.ok(ps.calls[0].args.includes("-NoProfile") && ps.calls[0].args.includes("-File"));
  const stdin = Buffer.concat(ps.calls[0].written).toString();
  assert.equal(stdin, `{"timeoutMs":20000}\n${PASSWORD}\n`);
});

test("UI Automation: мусор в выводе игнорируется, процесс упал без ответа → «поле не найдено», отмена → cancelled", async () => {
  const noisy = createUia(fakePowerShell([{ hello: 1 }]).spawn);
  assert.deepEqual(await noisy.enter({ timeoutMs: 5000 }, new SecretBuffer("x")), { state: "fieldNotFound" });
  const hanging = fakePowerShell([], { exitAfter: false });
  const uia = createUia(hanging.spawn);
  const pending = uia.enter({ timeoutMs: 5000 }, new SecretBuffer("x"));
  uia.cancel();
  assert.deepEqual(await pending, { state: "cancelled" });
});

test("скрипт UI Automation: пароль читается из stdin, не печатается и не пишется; проверяет процесс, права и фокус", () => {
  const ps = fs.readFileSync(path.join(__dirname, "..", "..", "remote", "tv-uia.ps1"), "utf8");
  assert.match(ps, /OpenStandardInput\(\)/);                 // вход читается байтами
  assert.match(ps, /UTF8Encoding/);                           // и в UTF-8: пароль не на латинице не искажается
  assert.ok(!/\[Console\]::In\b/.test(ps), "кодировка консоли не используется");
  assert.match(ps, /OpenProcess/);                            // «запущен от администратора» определяется и без доступа к процессу
  assert.match(ps, /baseline/);                               // окна пароля, открытые до запуска, игнорируются
  assert.ok(!/param\s*\(/i.test(ps), "пароль не может прийти параметром");
  assert.ok(!/\$args|\$MyInvocation/.test(ps));
  assert.ok(!/(Write-Host|Write-Output|Out-File|Set-Content|Add-Content|Tee-Object|Export-)[^\n]*\$password/i.test(ps));
  assert.ok(!/\$password[^\n]*(\|\s*(Out-|Set-|Add-))/i.test(ps));
  assert.match(ps, /TeamViewer\*/);                     // только процесс TeamViewer
  assert.match(ps, /Elevated/);                          // «запущен от администратора»
  assert.match(ps, /GetForegroundWindow/);               // фокус
  assert.match(ps, /ValuePattern/);                      // ввод через UI Automation, не буфер обмена
  assert.ok(!/Clipboard|SetText|Get-Clipboard/i.test(ps));
});

test("пароль нигде: исходники модуля не трогают буфер, реестр, хранилище учётных данных, localStorage, console", () => {
  const dir = path.join(__dirname, "..", "..", "remote");
  const files = [];
  (function walk(d) { for (const f of fs.readdirSync(d, { withFileTypes: true })) f.isDirectory() ? walk(path.join(d, f.name)) : files.push(path.join(d, f.name)); })(dir);
  const bad = /clipboard|localStorage|sessionStorage|keytar|safeStorage|CredWrite|cmdkey|reg\s+add|HKEY_|console\.(log|info|warn|error)|child_process.*password/i;
  // Буфер обмена — только clipboard.js (секрет на 30 с, затем очистка), index.js (подключение его и копия ID/адреса) и помощник для
  // секретов мимо журнала Win+V и облака (concealed.js + clip-conceal.ps1, W2-5).
  const clipboardOK = new Set(["clipboard.js", "index.js", "concealed.js", "clip-conceal.ps1"]);
  for (const file of files.filter((f) => /\.(js|ps1|html)$/.test(f))) {
    const code = fs.readFileSync(file, "utf8").split("\n").filter((l) => !l.trim().startsWith("//") && !l.trim().startsWith("#")).join("\n");
    const rule = clipboardOK.has(path.basename(file)) ? new RegExp(bad.source.replace("clipboard|", ""), "i") : bad;
    assert.ok(!rule.test(code), `${path.basename(file)}: ${(rule.exec(code) || [])[0]}`);
  }
});
