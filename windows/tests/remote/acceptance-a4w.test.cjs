// Приёмка W-3/W-4 по ТЗ § 3.3, § 4, § 6, § 7: подключение на двойниках (AnyDesk — пароль только в stdin, TeamViewer — только в окно
// через UI Automation), фокус/процесс, ошибки; правка XML с .bak; шаблоны. Реальные программы, PowerShell и окна не запускаются.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const { createConnector, MESSAGES } = require("../../remote/connect");
const { createUia, SCRIPT } = require("../../remote/uia");
const { SecretBuffer } = require("../../remote/secret");
const editor = require("../../remote/editor");
const templates = require("../../remote/templates");
const { load, passwordFor } = require("../../remote/source");
const { downloadURL } = require("../../remote/models");
const F = require("./fixtures");

const AD = "C:\\Program Files (x86)\\AnyDesk\\AnyDesk.exe", TV = "C:\\Program Files\\TeamViewer\\TeamViewer.exe";
const PW = "ПАРОЛЬ-КАНАРЕЙКА-секрет-31337";
const settings = { defaultProgram: "anyDesk", timeoutSeconds: 20, programPaths: {} };
const record = (extra = {}) => ({ sourceRow: 2, name: "Лаборатория Север", id: "123456789", program: null, hasPassword: true, ...extra });

// ---------- двойники ----------

function rig({ installed = [AD, TV], secret = PW, uiaResult = { state: "connected" }, uiaThrows = false, exit = null, spawnThrows = false, passwordThrows = false } = {}) {
  const r = { states: [], log: [], spawned: [], opened: [], uiaCalls: [], secrets: [], passwordCalls: 0 };
  const spawn = (file, args, opts) => {
    if (spawnThrows) throw new Error("spawn failed");
    const child = new EventEmitter(), chunks = [];
    child.stdin = { write: (data, cb) => { chunks.push(Buffer.from(data)); cb?.(); }, end() {} };
    child.unref = () => {};
    r.spawned.push({ file, args, opts, chunks });
    if (exit !== null) setImmediate(() => child.emit("exit", exit));
    return child;
  };
  const store = { password: async () => { r.passwordCalls++; if (passwordThrows) throw new Error("gone"); if (secret == null) return null; const s = new SecretBuffer(secret); r.secrets.push(s); return s; } };
  const uia = { enter: async (opts, password, onEvent) => { await opts.afterReady?.(); const s = typeof password === "function" ? await password() : password; r.uiaCalls.push({ opts, bytes: s ? Buffer.from(s.bytes) : null }); onEvent({ state: "waiting" }); if (uiaThrows) throw new Error("uia crashed"); return uiaResult; }, cancel() { r.cancelled = true; } };
  r.connector = createConnector({ exists: (p) => installed.includes(p), spawn, uia, hud: { show: (s) => r.states.push(s) }, openExternal: (u) => r.opened.push(u), log: (l) => r.log.push(l) });
  r.store = store;
  r.run = (rec = record(), opts = {}) => r.connector.connectRecord(rec, { settings, store, noPassword: false, ...opts });
  r.dump = () => JSON.stringify([r.states, r.log, r.spawned.map((s) => [s.file, s.args, s.opts]), r.opened]);
  return r;
}
const wiped = (r) => r.secrets.every((s) => s.isWiped);

// ---------- AnyDesk ----------

test("AnyDesk: пароль только в stdin (байтами), в аргументах и окружении нет; затёрт; 9/10-значные и алиасы", async () => {
  for (const id of ["123456789", "1234567890", "office@ad", "front-desk.2@company"]) {
    const r = rig();
    assert.deepEqual(await r.run(record({ id })), { ok: true });
    assert.equal(r.spawned.length, 1);
    assert.equal(r.spawned[0].file, AD);
    assert.deepEqual(r.spawned[0].args, [id, "--with-password"]);
    assert.equal(Buffer.concat(r.spawned[0].chunks).toString("utf8"), PW + "\n");
    assert.ok(!r.dump().includes(PW) && !r.dump().includes("КАНАРЕЙКА"), "пароль утёк мимо stdin");
    assert.equal(r.spawned[0].opts.env, undefined, "окружение процессу не передаётся");
    assert.ok(wiped(r));
    assert.equal(r.uiaCalls.length, 0, "UI Automation для AnyDesk не нужен");
  }
});

test("AnyDesk: пароли любого вида доходят до stdin без искажений", async () => {
  for (const pw of ["p@$$ w0rd!\"'\\<>&", "пароль 🔐 с эмодзи", "日本語パスワード", "x".repeat(1000), " пробелы "]) {
    const r = rig({ secret: pw });
    await r.run();
    assert.equal(Buffer.concat(r.spawned[0].chunks).toString("utf8"), pw + "\n");
  }
});

test("⌘↩-вариант и запись без пароля: только ID; файл с паролями не читается", async () => {
  const a = rig();
  await a.run(record(), { noPassword: true });
  assert.deepEqual(a.spawned[0].args, ["123456789"]);
  assert.equal(a.spawned[0].chunks.length, 0);
  assert.equal(a.passwordCalls, 0);
  const b = rig();
  await b.run(record({ hasPassword: false }));
  assert.equal(b.passwordCalls, 0);
  const c = rig({ secret: null });
  assert.deepEqual(await c.run(), { ok: true });
  assert.ok(c.states.some((s) => /Пароля в файле нет/.test(s.title)), "в файле пароля нет — сказали, ввести вручную");
});

test("не установлена: ошибка со ссылкой на загрузку, ничего не запущено, пароль не читался", async () => {
  for (const [program, installed] of [["anyDesk", [TV]], ["teamViewer", [AD]]]) {
    const r = rig({ installed });
    const out = await r.run(record({ program }));
    assert.deepEqual(out, { ok: false, error: "notInstalled" });
    assert.equal(r.spawned.length, 0);
    assert.equal(r.passwordCalls, 0);
    const toast = r.states.at(-1);
    assert.equal(toast.kind, "danger");
    assert.ok(toast.actions.some((a) => a.id === "download"));
    r.connector.hudAction("download", { program });
    assert.deepEqual(r.opened, [downloadURL(program)]);
  }
  assert.equal(downloadURL("anyDesk"), "https://anydesk.com/download");
});

test("пользовательский путь к программе в настройках важнее стандартных", async () => {
  const custom = "D:\\Tools\\AnyDesk.exe";
  const r = rig({ installed: [AD, custom] });
  await r.run(record(), { settings: { ...settings, programPaths: { anyDesk: custom } } });
  assert.equal(r.spawned[0].file, custom);
});

test("запись удалена из файла между списком и подключением: не запускаем, список обновится", async () => {
  const r = rig({ passwordThrows: true });
  assert.deepEqual(await r.run(), { ok: false, error: "gone" });
  assert.equal(r.spawned.length, 0);
});

test("запуск не удался: ошибка «не удалось запустить», пароль затёрт", async () => {
  const r = rig({ spawnThrows: true });
  assert.deepEqual(await r.run(), { ok: false, error: "launch" });
  assert.ok(wiped(r));
  const r2 = rig({ exit: 1 });
  assert.deepEqual(await r2.run(), { ok: false, error: "launch" });
  assert.ok(wiped(r2));
});

// ---------- TeamViewer ----------

test("TeamViewer: запуск только с ID, пароль — только в UI Automation; в аргументах и журнале нет", async () => {
  const r = rig();
  assert.deepEqual(await r.run(record({ program: "teamViewer" })), { ok: true });
  assert.equal(r.spawned.length, 1);
  assert.equal(r.spawned[0].file, TV);
  assert.deepEqual(r.spawned[0].args, ["-i", "123456789"]);
  assert.equal(r.spawned[0].chunks.length, 0, "в stdin TeamViewer пароль не пишем");
  assert.equal(r.uiaCalls.length, 1);
  assert.equal(r.uiaCalls[0].bytes.toString("utf8"), PW);
  assert.equal(r.uiaCalls[0].opts.timeoutMs, 60_000, "rc-win-entry D: база 60 с, как на Mac");
  assert.equal(r.uiaCalls[0].opts.limitMs, 180_000);
  assert.ok(!r.dump().includes("КАНАРЕЙКА"));
  assert.ok(wiped(r));
});

test("TeamViewer: алиас не поддерживается; пароль не читается пока не запущено", async () => {
  const r = rig();
  const out = await r.run(record({ program: "teamViewer", id: "office@ad" }));
  assert.equal(out.ok, false);
  assert.equal(r.spawned.length, 0, "алиас в TeamViewer не запускаем");
  assert.equal(r.uiaCalls.length, 0);
  assert.ok(wiped(r));
});

test("TeamViewer: все исходы окна → правильные сообщения, пароль затёрт, в журнале только коды", async () => {
  const cases = [
    [{ state: "connected" }, true, null, "success"], [{ state: "session" }, true, null, "success"],
    [{ state: "entered" }, false, "submitted", "info"], [{ state: "submitted" }, false, "submitted", "info"], [{ state: "sessionClosed" }, false, "sessionClosed", "warning"],
    [{ state: "noPrompt" }, false, "unconfirmed", "info"], [{ state: "noWindow" }, false, "noWindow", "warning"],
    [{ state: "passwordNeeded" }, true, null, "info"], [{ state: "idMismatch" }, false, "idMismatch", "warning"],
    [{ state: "wrongPassword" }, false, "wrongPassword", "danger"], [{ state: "focusLost" }, false, "focusLost", "warning"],
    [{ state: "elevated" }, false, "elevated", "warning"], [{ state: "fieldNotFound" }, false, "fieldNotFound", "warning"],
    [{ state: "cancelled" }, false, "cancelled", "info"], [{ state: "что-то-новое" }, false, "fieldNotFound", "warning"],
  ];
  for (const [uiaResult, ok, error, kind] of cases) {
    const r = rig({ uiaResult });
    const out = await r.run(record({ program: "teamViewer" }));
    assert.equal(out.ok, ok, JSON.stringify(uiaResult));
    if (error) assert.equal(out.error, error);
    assert.equal(r.states.at(-1).kind, kind, JSON.stringify(uiaResult));
    assert.ok(wiped(r), JSON.stringify(uiaResult));
    assert.ok(r.log.every((l) => /^connect (ok|fail) [A-Za-z0-9=_ ]+$/.test(l)), r.log.join("|"));
  }
  // «Не найдено поле» — введите вручную, пароль не копировался; «неверный пароль» — проверьте пароль в файле.
  assert.match(MESSAGES.fieldNotFound("teamViewer").title, /вручную/);
  assert.match(MESSAGES.fieldNotFound("teamViewer").detail, /не копировался/i);
  assert.match(MESSAGES.wrongPassword().title, /пароль в файле/i);
});

test("TeamViewer: UI Automation упал — пароль всё равно затёрт", async () => {
  const r = rig({ uiaThrows: true });
  await assert.rejects(() => r.run(record({ program: "teamViewer" })), /uia crashed/, "ошибка наверх: пока не превращается в тост (замечание)");
  assert.ok(wiped(r));
});

// rc-win-entry D (решение пользователя): ожидание окна пароля TeamViewer — не меньше 60 с (больше — из настроек), продление до 180 с.
test("TeamViewer: таймаут — не меньше 60 с (больше — из настроек), предел 180 с; кнопка «Отмена» отменяет", async () => {
  for (const [timeoutSeconds, ms] of [[undefined, 60_000], [30, 60_000], [1, 60_000], [60, 60_000], [120, 120_000]]) {
    const r = rig();
    await r.run(record({ program: "teamViewer" }), { settings: { ...settings, timeoutSeconds } });
    assert.equal(r.uiaCalls[0].opts.timeoutMs, ms, `timeout=${timeoutSeconds}`);
    assert.equal(r.uiaCalls[0].opts.limitMs, 180_000, `timeout=${timeoutSeconds}`);
    assert.ok(r.states.some((s) => s.actions?.some((a) => a.id === "cancel")), "в ожидании есть «Отмена»");
  }
  const r = rig();
  r.connector.hudAction("cancel");
});

// ---------- createUia: как говорим с PowerShell ----------

function psRig(script) {
  const state = { calls: [], stdin: [], killed: false };
  const spawn = (file, args, opts) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stdin = { write: (d, cb) => { state.stdin.push(Buffer.from(d)); cb?.(); }, end() {} };
    child.kill = () => { state.killed = true; child.emit("exit", null); };
    state.calls.push({ file, args, opts });
    state.child = child;
    setImmediate(() => script(child, state));
    return child;
  };
  return { uia: createUia(spawn), state };
}
const say = (child, ...states) => states.forEach((s) => child.stdout.emit("data", Buffer.from(JSON.stringify({ state: s }) + "\n")));

test("PowerShell: пароль только в stdin, параметры — первая строка JSON; в аргументах пароля нет; пароль не логируется", async () => {
  // Пароль уходит в stdin только после «passwordField»: до этого во входе скрипта — одни параметры.
  const before = [];
  const { uia, state } = psRig((c, st) => { say(c, "waiting"); before.push(Buffer.concat(st.stdin).toString("utf8")); say(c, "passwordField"); setTimeout(() => say(c, "connected"), 5); });
  const events = [];
  const out = await uia.enter({ timeoutMs: 12_000 }, new SecretBuffer(PW), (e) => events.push(e));
  assert.deepEqual(out, { state: "connected" });
  assert.deepEqual(events, [{ state: "waiting" }], "passwordField — не событие для окна, а запрос пароля");
  assert.equal(before[0], JSON.stringify({ timeoutMs: 12_000 }) + "\n", "до поля пароля в stdin — только параметры");
  const args = state.calls[0].args;
  assert.ok(!args.join(" ").includes("КАНАРЕЙКА") && args.includes("-NoProfile") && args.includes("-NonInteractive"));
  assert.ok(args.includes(SCRIPT) && fs.existsSync(SCRIPT));
  const input = Buffer.concat(state.stdin).toString("utf8").split("\n");
  assert.deepEqual(JSON.parse(input[0]), { timeoutMs: 12_000 });
  assert.equal(input[1], PW);
  assert.equal(state.calls[0].opts.windowsHide, true);
});

test("PowerShell: мусор в выводе игнорируется, неизвестные состояния тоже; нет итогового состояния → fieldNotFound", async () => {
  const a = psRig((c) => { c.stdout.emit("data", Buffer.from("мусор\n{не json}\n{\"state\":\"hack\"}\n")); say(c, "wrongPassword"); });
  assert.deepEqual(await a.uia.enter({ timeoutMs: 5000 }, new SecretBuffer("x")), { state: "wrongPassword" });
  const b = psRig((c) => { c.stdout.emit("data", Buffer.from("{\"state\":\"ente")); c.stdout.emit("data", Buffer.from("red\"}\n")); });
  assert.deepEqual(await b.uia.enter({ timeoutMs: 5000 }, new SecretBuffer("x")), { state: "entered" }, "строка, разорванная на куски");
  const c = psRig((child) => child.emit("exit", 1));
  assert.deepEqual(await c.uia.enter({ timeoutMs: 5000 }, new SecretBuffer("x")), { state: "fieldNotFound" });
  const d = psRig((child) => child.emit("error", new Error("нет powershell")));
  assert.deepEqual(await d.uia.enter({ timeoutMs: 5000 }, new SecretBuffer("x")), { state: "fieldNotFound" });
  assert.deepEqual(await createUia(() => { throw new Error("EPERM"); }).enter({ timeoutMs: 5000 }, new SecretBuffer("x")), { state: "fieldNotFound" });
});

test("PowerShell: отмена убивает процесс и даёт cancelled", async () => {
  const { uia, state } = psRig(() => {});
  const p = uia.enter({ timeoutMs: 60_000 }, new SecretBuffer("x"));
  await new Promise((r) => setImmediate(r));
  uia.cancel();
  assert.deepEqual(await p, { state: "cancelled" });
  assert.ok(state.killed);
});

test("скрипт tv-uia.ps1: проверка процесса и фокуса до ввода, пароль не выводится и не пишется на диск, буфер обмена не используется", () => {
  const ps = fs.readFileSync(SCRIPT, "utf8");
  const at = (needle) => { const i = ps.indexOf(needle); assert.ok(i >= 0, needle); return i; };
  // Ввод пароля (не ID партнёра, который тоже ставится через SetValue в запасном пути) — после проверок.
  const enter = "SetValue($password)";
  assert.ok(at("TeamViewer*") < at(enter), "процесс проверяется до ввода");
  assert.ok(at("[MuNative]::GetForegroundWindow()") < at(enter) && at("Emit 'focusLost'") < at(enter), "фокус проверяется до ввода");
  assert.ok(at("[MuNative]::Elevated(") < at(enter), "повышенные права — до ввода");
  assert.ok(at("$found.Edit.TryGetCurrentPattern") < at(enter) && at("IsPassword") < at(enter), "вводим только в поле пароля");
  for (const bad of ["Set-Clipboard", "Clipboard]::SetText", "Out-File", "Set-Content", "Add-Content", "Write-Host", "Write-Output $password", "Start-Transcript", "$args", "param("]) {
    assert.ok(!ps.includes(bad), `в скрипте: ${bad}`);
  }
  assert.ok(!/Emit[^\n]*\$password/.test(ps), "Emit не принимает пароль");
  assert.ok(/\$password = \$null/.test(ps), "пароль в скрипте обнуляется");
  const sendkeys = [...ps.matchAll(/SendWait\([^)]*\)/g)].map((m) => m[0]);
  assert.ok(sendkeys.length >= 1 && sendkeys.every((k) => k === "SendWait('{ENTER}')"), "SendKeys — только Enter, пароль клавиатурой не набирается");
  // Пароль читается из stdin только после проверок и события «passwordField» (W2-3), фокус проверяется ещё раз после чтения.
  assert.ok(at("Emit 'passwordField'") < at("$password = $reader.ReadLine()") && at("$password = $reader.ReadLine()") < at(enter));
  assert.ok(at("Emit 'focusLost'") < at("Emit 'passwordField'"));
  const afterRead = ps.slice(at("$password = $reader.ReadLine()"), at(enter));
  assert.match(afterRead, /Get-ForegroundPid\) -ne \$pid2\) \{ Emit 'focusLost'/);
});

// ---------- Перебор ----------

test("перебор 200 сценариев: пароль только в stdin AnyDesk / вход UIA, затёрт, нигде больше", async () => {
  let seed = 31337;
  const rnd = (n) => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) >> 8) % n;
  const uiaStates = ["entered", "connected", "submitted", "sessionClosed", "session", "passwordNeeded", "idMismatch", "noWindow", "noPrompt", "wrongPassword", "focusLost", "elevated", "fieldNotFound", "cancelled", "unknown"];
  const seen = new Set();
  for (let i = 0; i < 200; i++) {
    const program = rnd(2) ? "anyDesk" : "teamViewer";
    const secret = [PW, null, "Pw-" + i + "-секрет"][rnd(3)];
    const r = rig({ secret, installed: [AD, TV].filter(() => rnd(8) !== 0), uiaResult: { state: uiaStates[rnd(uiaStates.length)] }, spawnThrows: rnd(10) === 0, passwordThrows: rnd(12) === 0, exit: rnd(10) === 0 ? 1 : null });
    const id = ["123456789", "1234567890", "office@ad", "x@y"][rnd(4)];
    const noPassword = rnd(5) === 0;
    let out;
    try { out = await r.run(record({ program, id, hasPassword: rnd(6) !== 0 }), { noPassword }); } catch (e) { out = { ok: false, error: "throw" }; }
    seen.add(out.error || "ok");
    const dump = r.dump();
    assert.ok(!/ПАРОЛЬ-КАНАРЕЙКА|Pw-\d+-секрет/.test(dump), `сценарий ${i}: пароль утёк мимо stdin`);
    assert.ok(wiped(r), `сценарий ${i}: пароль не затёрт`);
    if (noPassword) assert.equal(r.passwordCalls, 0, `сценарий ${i}`);
    for (const s of r.spawned) {
      if (s.file === TV) assert.deepEqual(s.args.slice(0, 1), ["-i"], `сценарий ${i}`), assert.equal(s.chunks.length, 0);
      if (s.chunks.length) assert.equal(s.file, AD, `сценарий ${i}: stdin кроме AnyDesk`), assert.ok(s.args.includes("--with-password"));
    }
    if (program === "anyDesk") assert.equal(r.uiaCalls.length, 0);
    // UI Automation — только для TeamViewer (теперь и без пароля: ID и подтверждение сеанса); запуск мог и не удаться.
    if (r.uiaCalls.length) assert.ok(r.spawned.every((s) => s.file === TV), `сценарий ${i}`);
    assert.ok(r.log.every((l) => /^connect (ok|fail) [A-Za-z0-9=_ ]+$/.test(l)), `сценарий ${i}: ${r.log}`);
  }
  assert.ok(seen.size > 4, [...seen].join());
});

// ---------- Правка XML ----------

const BODY = `<?xml version="1.0" encoding="UTF-8"?>
<!-- Список подключений. <connection> в комментарии — не запись -->
<connections>
\t<connection>
\t\t<name>Лаборатория Север</name>
\t\t<id>123 456 789</id>
\t\t<password><![CDATA[Pw-1-секрет&<>]]></password>
\t\t<group>Лаборатории</group>
\t\t<tags>касса, ночь</tags>
\t\t<extra a="1">чужое поле</extra>
\t</connection>
\t<connection name="Касса &amp; склад" id="223456789" password="Pw-2-секрет" app="TeamViewer"/>
\t<!-- между записями -->
\t<connection><name>Аптека Захід</name><id>323456789</id><note/><password>Pw-3-секрет</password></connection>
\t<connection><name>Дубликат</name><id>323456789</id><password>Pw-4-секрет</password></connection>
\t<connection><name>Алиас</name><id>Office@AD</id></connection>
</connections>
`;
const VARIANTS = {
  "lf+tab": BODY,
  "crlf+bom": "\uFEFF" + BODY.replace(/\n/g, "\r\n"),
  "одна строка": BODY.replace(/\n/g, "").replace(/\t/g, "").replace(/<!--[^>]*? -->/, ""),
};
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "rc-a4w-"));
function put(text, mode = 0o600) {
  const dir = tmp(), file = path.join(dir, "list.xml");
  fs.writeFileSync(file, text, { mode });
  fs.chmodSync(file, mode);
  return { dir, file };
}
const recordsOf = (file) => load(fs.readFileSync(file), "xml").records;
const rowsOf = (file) => {
  const data = fs.readFileSync(file);
  return recordsOf(file).map((r) => {
    const secret = passwordFor(r, data, "xml");
    const out = { name: r.name, id: r.id, group: r.group, tags: r.tags.join("|"), note: r.note, program: r.program, password: secret ? Buffer.from(secret.bytes).toString("utf8") : "" };
    secret?.wipe();
    return out;
  });
};
const affix = (a, b) => {
  const x = Buffer.from(a), y = Buffer.from(b);
  let p = 0; while (p < Math.min(x.length, y.length) && x[p] === y[p]) p++;
  let s = 0; while (s < Math.min(x.length, y.length) - p && x[x.length - 1 - s] === y[y.length - 1 - s]) s++;
  return { p, s };
};
const form = (r, extra = {}) => ({ name: r.name, id: r.id, group: r.group, tags: r.tags.join(", "), note: r.note, program: r.program === "teamViewer" ? "TeamViewer" : r.program === "anyDesk" ? "AnyDesk" : "", ...extra });

test("изменить: правятся только байты своей записи; соседи, их пароли и поля целы; пароль не тронут без нового", () => {
  for (const [label, text] of Object.entries(VARIANTS)) {
    const probe = put(text);
    const n = recordsOf(probe.file).length;
    assert.equal(n, 5, label);
    for (let i = 0; i < n; i++) {
      if (label === "одна строка" && (i === 2 || i === 3)) continue;     // одинаковые строка и ID — запись не отличить (см. ОШИБКУ ниже)
      const { file } = put(text);
      const before = fs.readFileSync(file), rowsBefore = rowsOf(file), rec = recordsOf(file)[i];
      const res = editor.apply(file, "update", { record: rec, fields: form(rec, { name: "Новое имя & <тег>", group: "Новая группа", note: "заметка ]]> &" }) });
      assert.deepEqual(res, { ok: true }, `${label} #${i}`);
      const after = fs.readFileSync(file), rowsAfter = rowsOf(file);
      const text0 = before.toString("utf8"), start = text0.split("<connection").slice(0, i + 2).join("<connection").length - 0;
      assert.equal(rowsAfter.length, rowsBefore.length, `${label} #${i}`);
      rowsAfter.forEach((row, j) => { if (j !== i) assert.deepEqual(row, rowsBefore[j], `${label} #${i}: запись ${j} изменилась`); });
      assert.equal(rowsAfter[i].name, "Новое имя & <тег>");
      assert.equal(rowsAfter[i].group, "Новая группа");
      assert.equal(rowsAfter[i].password, rowsBefore[i].password, `${label} #${i}: пароль без нового значения должен остаться`);
      assert.equal(rowsAfter[i].id, rowsBefore[i].id);
      void after; void start;
    }
  }
});

test("изменить: границы правки внутри записи (общие префикс и суффикс покрывают всё вне неё)", () => {
  const { file } = put(BODY);
  const before = fs.readFileSync(file, "utf8");
  for (let i = 0; i < 5; i++) {
    const f = put(BODY).file;
    const rec = recordsOf(f)[i];
    editor.apply(f, "update", { record: rec, fields: form(rec, { note: "Z" }) });
    const after = fs.readFileSync(f, "utf8");
    const { p, s } = affix(before, after);
    // Запись i начинается после i-й закрывающей и заканчивается своим </connection> или />.
    const starts = [...before.matchAll(/<connection[\s>]/g)].map((m) => m.index).filter((ix) => before.lastIndexOf("<!--", ix) < before.lastIndexOf("-->", ix) || before.lastIndexOf("<!--", ix) < 0);
    const byte = (ix) => Buffer.byteLength(before.slice(0, ix));
    const startIx = byte(starts[i]);
    assert.ok(p >= startIx, `#${i}: правка начинается раньше записи (${p} < ${startIx})`);
    const next = byte(starts[i + 1] ?? before.indexOf("</connections>"));
    assert.ok(Buffer.byteLength(before) - s <= next, `#${i}: правка заходит в следующую запись`);
  }
});

test("пароль: новый заменяет, пустая строка убирает, спецсимволы/CDATA-разделитель/эмодзи сохраняются", () => {
  for (const pw of ["Новый ]]> пароль & \"x\" 🔐", "<>&", "внутри пробелы"]) {
    const { file } = put(BODY);
    const rec = recordsOf(file)[0];
    assert.deepEqual(editor.apply(file, "update", { record: rec, fields: form(rec, { password: pw }) }), { ok: true });
    assert.equal(rowsOf(file)[0].password, pw, JSON.stringify(pw));
  }
  const { file } = put(BODY);
  const rec = recordsOf(file)[0];
  editor.apply(file, "update", { record: rec, fields: form(rec, { password: "" }) });
  assert.equal(rowsOf(file)[0].password, "");
  assert.equal(recordsOf(file)[0].hasPassword, false);
});

test("добавить: вставка без изменения остальных байт, в стиле файла (окончания строк, BOM)", () => {
  for (const [label, text] of Object.entries(VARIANTS)) {
    const { file } = put(text);
    const before = fs.readFileSync(file);
    assert.deepEqual(editor.apply(file, "add", { fields: { name: "Новый & узел", id: "555 666 777", group: "Новая", tags: "x, y", note: "n", program: "AnyDesk", password: "Pw-new-секрет" } }), { ok: true }, label);
    const after = fs.readFileSync(file);
    const rows = rowsOf(file);
    assert.equal(rows.length, 6, label);
    assert.deepEqual(rows[5], { name: "Новый & узел", id: "555666777", group: "Новая", tags: "x|y", note: "n", program: "anyDesk", password: "Pw-new-секрет" }, label);
    assert.deepEqual(rows.slice(0, 5), rowsOf(put(text).file), label);
    if (label !== "одна строка") {
      const { p, s } = affix(before, after);
      assert.ok(p + s >= before.length - 1 - 2, `${label}: добавление должно быть вставкой (общих байт ${p + s} из ${before.length})`);
    }
    assert.equal(after[0] === 0xEF, before[0] === 0xEF, `${label}: BOM сохранён/не появился`);
    if (label === "crlf+bom") assert.ok(!after.toString("utf8").replace(/\r\n/g, "").includes("\n"), "в CRLF-файле появился одиночный LF");
  }
});

test("удалить: уходит только эта запись; удалили всё и добавили в пустой файл — комментарии на месте", () => {
  for (const [label, text] of Object.entries(VARIANTS)) {
    for (let i = 0; i < 5; i++) {
      if (label === "одна строка" && (i === 2 || i === 3)) continue;
      const { file } = put(text);
      const rowsBefore = rowsOf(file);
      assert.deepEqual(editor.apply(file, "remove", { record: recordsOf(file)[i] }), { ok: true }, `${label} #${i}`);
      const expected = rowsBefore.filter((_, j) => j !== i);
      assert.deepEqual(rowsOf(file), expected, `${label} #${i}`);
    }
  }
  const { file } = put(BODY);
  for (let i = 0; i < 5; i++) editor.apply(file, "remove", { record: recordsOf(file)[0] });
  assert.equal(recordsOf(file).length, 0);
  assert.ok(fs.readFileSync(file, "utf8").includes("<!-- Список подключений"));
  assert.deepEqual(editor.apply(file, "add", { fields: { name: "Первая", id: "123456789" } }), { ok: true });
  assert.deepEqual(recordsOf(file).map((r) => r.name), ["Первая"]);
});

test("добавили и удалили ту же запись — файл вернулся байт в байт (LF)", () => {
  const { file } = put(BODY);
  const orig = fs.readFileSync(file);
  editor.apply(file, "add", { fields: { name: "Временный", id: "555666777" } });
  editor.apply(file, "remove", { record: recordsOf(file).at(-1) });
  assert.equal(fs.readFileSync(file).compare(orig), 0);
});

test("дубликат ID: правится только выбранная строка", () => {
  const { file } = put(BODY);
  const rec = recordsOf(file)[3];
  assert.equal(rec.name, "Дубликат");
  editor.apply(file, "update", { record: rec, fields: form(rec, { group: "Правка дубликата" }) });
  const rows = rowsOf(file);
  assert.equal(rows[3].group, "Правка дубликата");
  assert.equal(rows[2].group, "");
  assert.equal(rows[3].password, "Pw-4-секрет");
});

test(".bak: прежнее содержимое побайтно, права те же, при втором сохранении — предыдущая версия; лишних файлов нет", () => {
  for (const mode of [0o600, 0o640, 0o644]) {
    const { dir, file } = put(VARIANTS["crlf+bom"], mode);
    const v0 = fs.readFileSync(file);
    editor.apply(file, "add", { fields: { name: "Один", id: "555666777" } });
    const v1 = fs.readFileSync(file);
    const bak = `${file}.bak`;
    assert.equal(fs.readFileSync(bak).compare(v0), 0, ".bak = версия до правки");
    // На NTFS есть только атрибут «только для чтения» (stat даёт 0o666/0o444): биты 0o640 там не проверяются, а запись остаётся доступной.
    if (process.platform === "win32") {
      assert.ok(fs.statSync(bak).mode & 0o200, ".bak не только для чтения");
      assert.ok(fs.statSync(file).mode & 0o200, "файл не только для чтения");
    } else {
      assert.equal(fs.statSync(bak).mode & 0o777, mode, `права .bak ${mode.toString(8)}`);
      assert.equal(fs.statSync(file).mode & 0o777, mode, `права файла ${mode.toString(8)}`);
    }
    editor.apply(file, "add", { fields: { name: "Два", id: "555666778" } });
    assert.equal(fs.readFileSync(bak).compare(v1), 0, "второй .bak — предыдущая версия");
    assert.deepEqual(fs.readdirSync(dir).sort(), ["list.xml", "list.xml.bak"], `лишние файлы: ${fs.readdirSync(dir)}`);
  }
});

test("(исправлено) файл списка только для чтения (0o400): первая правка проходит, вторая падает — старый .bak нельзя перезаписать", () => {
  const { file } = put(BODY, 0o400);
  assert.deepEqual(editor.apply(file, "add", { fields: { name: "Один", id: "555666777" } }), { ok: true });
  assert.deepEqual(editor.apply(file, "add", { fields: { name: "Два", id: "555666778" } }), { ok: true });
  // Атрибут «только для чтения» сохраняется (на Windows chmod 0o400 — это он и есть).
  assert.equal(fs.statSync(file).mode & 0o200, 0, "файл остался только для чтения");
  fs.chmodSync(file, 0o600); fs.chmodSync(`${file}.bak`, 0o600);
});

test("(исправлено; оба клиента): запись с тем же номером строки и ID (весь XML в одну строку, одинаковый ID у двух записей) — правка уходит в первую", () => {
  const { file } = put(VARIANTS["одна строка"]);
  const second = recordsOf(file)[3];
  assert.equal(second.name, "Дубликат");
  editor.apply(file, "update", { record: second, fields: form(second, { group: "Правка" }) });
  assert.deepEqual(rowsOf(file).filter((r) => r.group === "Правка").map((r) => r.name), ["Дубликат"]);
});

test("(исправлено; проверить на Mac тем же тестом): пробелы по краям пароля теряются при чтении файла", () => {
  const { file } = put(BODY);
  const rec = recordsOf(file)[0];
  editor.apply(file, "update", { record: rec, fields: form(rec, { password: " внутри пробелы " }) });
  assert.equal(rowsOf(file)[0].password, " внутри пробелы ");
});

test("ошибка записи: исходный файл цел, мусора нет; .xlsx не пишется никогда; файла нет → unavailable", () => {
  const { dir, file } = put(BODY);
  const orig = fs.readFileSync(file);
  if (process.platform === "win32") {
    // chmod каталога на NTFS ничего не запрещает: сбой записи создаём занятым именем временного файла (на его месте каталог).
    fs.mkdirSync(`${file}.tmp-${process.pid}`);
    const res = editor.apply(file, "add", { fields: { name: "x", id: "123456789" } });
    assert.equal(res.ok, false);
    fs.rmdirSync(`${file}.tmp-${process.pid}`);
    assert.equal(fs.readFileSync(file).compare(orig), 0);
    assert.deepEqual(fs.readdirSync(dir).sort(), ["list.xml", "list.xml.bak"], "остаётся только .bak = исходный файл");
  } else {
    fs.chmodSync(dir, 0o555);
    try {
      const res = editor.apply(file, "add", { fields: { name: "x", id: "123456789" } });
      if (process.getuid?.() !== 0) assert.equal(res.ok, false);
    } finally { fs.chmodSync(dir, 0o755); }
    assert.equal(fs.readFileSync(file).compare(orig), 0);
    assert.deepEqual(fs.readdirSync(dir).filter((n) => n !== "list.xml"), process.getuid?.() === 0 ? ["list.xml.bak"] : [], "ни .tmp, ни .bak без записи");
  }
  const x = path.join(tmp(), "never.xlsx");
  const data = F.xlsxRows(F.cleanRows(5));
  fs.writeFileSync(x, data);
  assert.deepEqual(editor.apply(x, "add", { fields: { name: "x", id: "123456789" } }), { ok: false, error: "xlsxReadOnly" });
  assert.equal(fs.readFileSync(x).compare(data), 0);
  assert.equal(editor.apply(path.join(tmp(), "нет.xml"), "add", { fields: { name: "x", id: "123456789" } }).ok, false);
});

test("проверка полей: имя, ID, программа, алиас у TeamViewer — файл не меняется", () => {
  const { file } = put(BODY);
  const orig = fs.readFileSync(file);
  for (const fields of [{ name: "", id: "123456789" }, { name: "x", id: "12345" }, { name: "x", id: "" }, { name: "x", id: "123456789", program: "RustDesk" },
    { name: "x", id: "office@ad", program: "TeamViewer" }, { name: "  ", id: "  " }]) {
    assert.equal(editor.apply(file, "add", { fields }).ok, false, JSON.stringify(fields));
  }
  assert.equal(fs.readFileSync(file).compare(orig), 0);
  assert.equal(fs.existsSync(`${file}.bak`), false, ".bak не создаётся, если править нечего");
});

test("устаревшая запись (файл правили руками): находится по ID и имени или отказ «gone», но не чужая запись", () => {
  const { file } = put(BODY);
  const stale = recordsOf(file)[3];
  fs.writeFileSync(file, "<!-- добавили -->\n<!-- ещё -->\n" + BODY.replace(/^<\?xml[^\n]*\n/, ""));
  const res = editor.apply(file, "update", { record: stale, fields: form(stale, { group: "Ушла" }) });
  if (res.ok) assert.deepEqual(rowsOf(file).filter((r) => r.group === "Ушла").map((r) => r.name), ["Дубликат"]);
  else assert.equal(res.error, "gone");
  fs.writeFileSync(file, BODY.replace(/\t<connection><name>Дубликат<\/name>.*\n/, ""));
  assert.equal(editor.apply(file, "update", { record: stale, fields: form(stale, { group: "x" }) }).error, "gone");
  assert.equal(editor.apply(file, "remove", { record: stale }).error, "gone");
});

test("случайные цепочки правок (150 шагов × 3 вида файла) сходятся с моделью, файл всегда читается", () => {
  for (const [label, text] of Object.entries(VARIANTS)) {
    let seed = 777;
    const rnd = (n) => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) >> 8) % n;
    const dupRecord = /<connection><name>Дубликат<\/name><id>323456789<\/id><password>Pw-4-секрет<\/password><\/connection>/;
    const { file } = put(text.replace(dupRecord, ""));      // без пары с одним ID: в «одной строке» её не различить
    let model = rowsOf(file), nextID = 500_000_000;
    for (let step = 0; step < 150; step++) {
      const recs = recordsOf(file);
      assert.equal(recs.length, model.length, `${label} шаг ${step}`);
      const op = rnd(3);
      if (op === 0) {
        nextID += 13;
        const name = ["Узел", "Філія & Ко", "Склад <1>", "Касса\"2\""][rnd(4)] + ` ${step}`, pw = rnd(2) ? `Pw-${step}-]]>-&` : "";
        assert.deepEqual(editor.apply(file, "add", { fields: { name, id: String(nextID), group: `Г${step % 3}`, tags: `t${step % 4}`, password: pw } }), { ok: true }, `${label} шаг ${step}`);
        model.push({ name, id: String(nextID), group: `Г${step % 3}`, tags: `t${step % 4}`, note: "", program: null, password: pw });
      } else if (op === 1 && recs.length) {
        const i = rnd(recs.length), r = recs[i], note = `правка ${step} ]]> &`, group = `Г${rnd(5)}`;
        assert.deepEqual(editor.apply(file, "update", { record: r, fields: form(r, { note, group }) }), { ok: true }, `${label} шаг ${step}`);
        model[i] = { ...model[i], note, group };
      } else if (op === 2 && recs.length) {
        const i = rnd(recs.length);
        assert.deepEqual(editor.apply(file, "remove", { record: recs[i] }), { ok: true }, `${label} шаг ${step}`);
        model.splice(i, 1);
      } else continue;
      const got = rowsOf(file);
      assert.deepEqual(got.map((r) => [r.name, r.id, r.password, r.group, r.note.replace(/\r\n/g, "\n")]), model.map((r) => [r.name, r.id, r.password, r.group, r.note]), `${label} шаг ${step}`);
    }
  }
});

// Обнаруженные ошибки (см. .audit/rc-acceptance.md): исправлено (редактор правит отдельные поля, корень ищется по закрывающему тегу и т. д.), тесты оставлены как защита.
test("(исправлено) запись, добавленная в файл с комментарием после корня (в нём есть </), попадает внутрь комментария и пропадает", () => {
  const { file } = put('<connections>\n  <connection><name>a</name><id>123456789</id></connection>\n</connections>\n<!-- конец </x> -->\n');
  const res = editor.apply(file, "add", { fields: { name: "Новый", id: "555666777" } });
  assert.equal(res.ok, true);
  assert.deepEqual(recordsOf(file).map((r) => r.name), ["a", "Новый"], "добавленная запись должна читаться из файла");
});

test("(исправлено) правка записи пересобирает её целиком — атрибутная форма, комментарий и CDATA внутри записи теряются", () => {
  const { file } = put(BODY);
  const before = fs.readFileSync(file, "utf8");
  const rec = recordsOf(file)[1];                                // запись в виде атрибутов
  editor.apply(file, "update", { record: rec, fields: form(rec, { note: "n" }) });
  const after = fs.readFileSync(file, "utf8");
  assert.ok(after.includes('password="Pw-2-секрет"'), "форма записи должна остаться атрибутной");
  const rec0 = recordsOf(file)[0];
  editor.apply(file, "update", { record: rec0, fields: form(rec0, { note: "n" }) });
  assert.ok(fs.readFileSync(file, "utf8").includes("<![CDATA[Pw-1-секрет&<>]]>"), "CDATA пароля должна остаться как была");
  void before;
});

test("(исправлено) «сохранить без изменений» переписывает файл (Mac оставляет байты в байт)", () => {
  const { file } = put(VARIANTS["одна строка"]);
  const before = fs.readFileSync(file);
  for (const rec of recordsOf(file)) editor.apply(file, "update", { record: rec, fields: form(rec) });
  assert.equal(fs.readFileSync(file).compare(before), 0);
});

// ---------- Шаблоны ----------

test("«Создать шаблон»: .xlsx и .xml читаются без ошибок и без предупреждений, пароля нет, права 600, настройки подхватывают файл", async () => {
  for (const kind of ["xlsx", "xml"]) {
    const dir = tmp(), picked = path.join(dir, `Подключения.${kind}`);
    let applied = null;
    const out = await templates.create({ kind, dialog: { showSaveDialog: async () => ({ canceled: false, filePath: picked }) }, parent: null, setSettings: (p) => { applied = p; } });
    assert.equal(out, picked);
    assert.deepEqual(applied, { file: picked, sheet: "" });
    if (process.platform !== "win32") assert.equal(fs.statSync(picked).mode & 0o777, 0o600);
    const snap = load(fs.readFileSync(picked), kind);
    assert.ok(snap.diagnostics.skipped.length === 0 && !snap.diagnostics.unrecognizedColumns.length && !snap.diagnostics.duplicates.length, JSON.stringify(snap.diagnostics));
    assert.equal(snap.records.length, 2);
    assert.deepEqual(snap.records.map((r) => r.id), ["123456789", "987654321"]);
    assert.ok(snap.records.every((r) => !r.hasPassword), "в примере пароля нет");
    const fields = new Set(snap.diagnostics.columns.map((c) => c.field));
    for (const f of kind === "xlsx" ? ["name", "id", "password", "group", "tags", "note", "program"] : ["name", "id", "group", "tags", "note", "program"]) assert.ok(fields.has(f), `${kind}: колонки ${[...fields]}`);
  }
  const cancelled = await templates.create({ kind: "xlsx", dialog: { showSaveDialog: async () => ({ canceled: true }) }, parent: null, setSettings: () => assert.fail("не должно вызываться") });
  assert.equal(cancelled, "");
});

test("шаблон .xml можно править редактором; шаблон .xlsx — валидный пакет с нужными частями", async () => {
  const { file } = put(templates.templateBuffer("xml").toString("utf8"));
  assert.deepEqual(editor.apply(file, "add", { fields: { name: "Моё", id: "222333444", password: "Pw-мой" } }), { ok: true });
  for (const r of recordsOf(file).filter((x) => x.name.startsWith("Пример"))) editor.apply(file, "remove", { record: recordsOf(file).find((x) => x.id === r.id) });
  assert.deepEqual(recordsOf(file).map((r) => r.name), ["Моё"]);
  const { ZipArchive } = require("../../remote/zip");
  const zip = new ZipArchive(templates.templateBuffer("xlsx"));
  for (const part of ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"]) {
    const body = zip.contents(part);
    assert.ok(body && body.length, `нет части ${part}`);
    assert.ok(/^<\?xml|^<[A-Za-z]/.test(Buffer.from(body).toString("utf8").trim()), part);
  }
});
