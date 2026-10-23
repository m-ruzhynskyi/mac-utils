// Подтверждение подключения: зелёный «успех» — только когда сеанс подтверждён (пароль введён и окно пароля закрылось, или
// найдено окно сеанса TeamViewer). Таймаут без окна пароля и окна сеанса — нейтральный тост, ID TeamViewer в буфер (только ID).
// Запасной путь TeamViewer: главный экран без ID → ID в поле, «Connect» → окно пароля → пароль. Реальные программы, PowerShell
// и окна не запускаются: PowerShell — двойник, отвечающий строками JSON, как tv-uia.ps1.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { EventEmitter } = require("node:events");
const { createConnector } = require("../../remote/connect");
const { createUia, SCRIPT, MAX_EXTENSION } = require("../../remote/uia");
const { SecretBuffer } = require("../../remote/secret");

const AD = "C:\\Program Files (x86)\\AnyDesk\\AnyDesk.exe", TV = "C:\\Program Files\\TeamViewer\\TeamViewer.exe";
const PW = "ПАРОЛЬ-КАНАРЕЙКА-confirm-4242";
const settings = { defaultProgram: "teamViewer", timeoutSeconds: 20, programPaths: {} };
const record = (extra = {}) => ({ sourceRow: 2, name: "Лаборатория Север", id: "123456789", program: "teamViewer", hasPassword: true, ...extra });
const LOG_LINE = /^connect (ok|fail) [A-Za-z0-9=_ ]+$/;

// Двойник: TeamViewer/AnyDesk — пустой процесс; PowerShell — выдаёт заданные строки после «ready» (как скрипт: сначала
// запоминает окна, потом ждёт). order — порядок событий: TeamViewer должен запуститься только после «ready».
function rig({ lines = [], copyText = "default", uia: withUia = true } = {}) {
  const r = { states: [], log: [], copied: [], order: [], stdin: [], spawned: [] };
  const spawn = (file, args, opts) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.unref = () => {};
    child.kill = () => child.emit("exit", 1);
    const chunks = [];
    child.stdin = Object.assign(new EventEmitter(), { write: (d, cb) => { chunks.push(Buffer.from(d)); cb?.(); return true; }, end() {} });
    r.spawned.push({ file, args, opts, chunks });
    if (/powershell/i.test(file)) {
      r.stdin = chunks;
      r.order.push("powershell");
      setImmediate(() => {
        r.order.push("ready");
        child.stdout.emit("data", Buffer.from('{"state":"ready"}\n'));
        setTimeout(() => {
          for (const state of lines) { r.order.push(state); child.stdout.emit("data", Buffer.from(JSON.stringify({ state }) + "\n")); }
          child.emit("exit", 0);
        }, 5);
      });
    } else r.order.push(file === TV ? "teamviewer" : "anydesk");
    return child;
  };
  const copy = copyText === "default" ? (t) => { r.copied.push(t); return true; } : copyText;
  r.connector = createConnector({ exists: (p) => p === TV || p === AD, spawn, uia: withUia ? createUia(spawn) : null, hud: { show: (s) => r.states.push(s) },
    log: (l) => r.log.push(l), copyText: copy });
  r.secrets = [];
  r.store = { password: async () => { const s = new SecretBuffer(PW); r.secrets.push(s); return s; } };
  r.run = (rec = record(), opts = {}) => r.connector.connectRecord(rec, { settings, store: r.store, noPassword: false, ...opts });
  r.dump = () => JSON.stringify([r.states, r.log, r.copied, r.spawned.map((s) => [s.file, s.args, s.opts])]);
  r.input = () => Buffer.concat(r.stdin).toString("utf8").split("\n");
  return r;
}

test("TeamViewer: к сроку нет ни окна пароля, ни окна сеанса → нейтральный тост, успеха нет, ID (только ID) в буфере", async () => {
  const r = rig({ lines: ["waiting", "waiting", "noPrompt"] });
  const out = await r.run();
  assert.deepEqual(out, { ok: false, error: "unconfirmed" });
  assert.ok(!r.states.some((s) => s.kind === "success"), "зелёного тоста не было ни разу");
  const last = r.states.at(-1);
  assert.equal(last.kind, "info");
  assert.equal(last.title, "Не удалось подключиться — ID скопирован");
  assert.deepEqual(r.copied, ["123456789"], "в буфер — ровно ID");
  assert.ok(!r.dump().includes("КАНАРЕЙКА"), "пароль не в буфере, не в тостах, не в журнале");
  assert.ok(r.secrets.every((s) => s.isWiped));
  assert.ok(r.log.every((l) => LOG_LINE.test(l)) && r.log.some((l) => /code=unconfirmed/.test(l)), r.log.join("|"));
  assert.ok(!r.log.join(" ").includes("123456789"), "в журнале нет ID");
});

test("TeamViewer: не подтверждено и буфер недоступен → «Не удалось подтвердить подключение», без галочки", async () => {
  for (const copyText of [null, () => { throw new Error("busy"); }, () => false]) {
    const r = rig({ lines: ["noPrompt"], copyText });
    assert.deepEqual(await r.run(), { ok: false, error: "unconfirmed" });
    assert.equal(r.states.at(-1).kind, "info");
    assert.equal(r.states.at(-1).title, "Не удалось подтвердить подключение");
    assert.ok(!r.states.some((s) => s.kind === "success"));
    assert.ok(r.log.some((l) => /copied=0/.test(l)));
  }
});

test("TeamViewer открылся на главном экране без ID: скрипт ввёл ID и нажал «Connect», затем ввёл пароль", async () => {
  const r = rig({ lines: ["waiting", "idSubmitted", "waiting", "intermediate", "waiting", "entered"] });
  const out = await r.run();
  assert.deepEqual(out, { ok: true });
  assert.deepEqual(r.order.slice(0, 3), ["powershell", "ready", "teamviewer"], "TeamViewer — после того, как скрипт запомнил окна");
  const [options, password] = r.input();
  assert.deepEqual(JSON.parse(options), { timeoutMs: 20_000, id: "123456789" }, "ID — в параметрах скрипта (для поля ID и окна сеанса)");
  assert.equal(password, PW, "пароль — второй строкой stdin, не в параметрах");
  assert.ok(!JSON.stringify(r.spawned.map((s) => s.args)).includes("КАНАРЕЙКА"));
  assert.ok(r.states.some((s) => /Ввёл ID в TeamViewer/.test(s.title)), "ход виден: ID введён");
  assert.ok(r.states.some((s) => /TeamViewer подключается/.test(s.title)), "промежуточное окно — ждём дальше");
  const successAt = r.states.findIndex((s) => s.kind === "success");
  assert.equal(successAt, r.states.length - 1, "успех — только итогом, не раньше");
  assert.match(r.states.at(-1).title, /Пароль введён/);
  assert.deepEqual(r.copied, [], "подключение подтверждено — буфер не трогаем");
  assert.ok(r.log.some((l) => /password=1 typed=1/.test(l)), r.log.join("|"));
  assert.ok(r.secrets.every((s) => s.isWiped));
});

test("TeamViewer: окно сеанса подтверждено без окна пароля → «Подключено без пароля»; запись без пароля — тоже через UI Automation", async () => {
  const a = rig({ lines: ["waiting", "session"] });
  assert.deepEqual(await a.run(), { ok: true });
  assert.equal(a.states.at(-1).kind, "success");
  assert.match(a.states.at(-1).title, /Подключено без пароля/);
  const b = rig({ lines: ["waiting", "idSubmitted", "session"] });
  assert.deepEqual(await b.run(record({ hasPassword: false })), { ok: true });
  const [options, password] = b.input();
  assert.deepEqual(JSON.parse(options), { timeoutMs: 20_000, id: "123456789", noPassword: true });
  assert.equal(password, "", "пароля нет — пустая строка");
  const c = rig({ lines: ["noPrompt"] });
  assert.deepEqual(await c.run(record({ hasPassword: false })), { ok: false, error: "unconfirmed" });
  assert.ok(!c.states.some((s) => s.kind === "success"));
  assert.deepEqual(c.copied, ["123456789"]);
  const d = rig({ lines: ["passwordNeeded"] });
  await d.run(record({ hasPassword: false }));
  assert.equal(d.states.at(-1).kind, "info");
  assert.match(d.states.at(-1).title, /Введите пароль в окне TeamViewer/);
});

test("AnyDesk (CLI): подключение не подтверждается → нейтральный тост, без «успеха»; без UI Automation TeamViewer — тоже", async () => {
  const a = rig();
  assert.deepEqual(await a.run(record({ program: "anyDesk" })), { ok: true });
  assert.ok(!a.states.some((s) => s.kind === "success"));
  assert.match(a.states.at(-1).title, /Пароль передан/);
  const b = rig();
  await b.run(record({ program: "anyDesk", hasPassword: false }));
  assert.ok(!b.states.some((s) => s.kind === "success"));
  assert.match(b.states.at(-1).title, /Открыт AnyDesk/);
  const c = rig({ uia: false });
  assert.deepEqual(await c.run(record({ hasPassword: false })), { ok: true });
  assert.ok(!c.states.some((s) => s.kind === "success"));
  assert.deepEqual(c.copied, ["123456789"]);
});

// ---- Скрипт: поиск поля ID, кнопки «Connect» и окна сеанса — по подписям и ролям, отмена не нажимается ----
const PS = fs.readFileSync(SCRIPT, "utf8");
const psRegex = (name) => {
  const m = PS.match(new RegExp(`\\$${name} = '([^']*)'`));
  assert.ok(m, name);
  return new RegExp(m[1].replace(/^\(\?i\)/, ""), "i");
};

test("скрипт: поле ID находится в новом и старом интерфейсе по подписи/подсказке, поле пароля и посторонние — нет", () => {
  const field = psRegex("idFieldPattern");
  for (const label of ["ID, IP address, or hostname", "Enter end user's ID, IP, or hostname", "Partner ID", "PartnerID", "ID партнера", "ID партнёра", "Partner-ID"]) assert.ok(field.test(label), label);
  for (const label of ["Password", "Пароль", "Search and Connect", "Chat", "TeamViewer ID", "Your ID"]) assert.ok(!field.test(label), label);
});

test("скрипт: нажимается только «Connect»; Cancel/Deny/Close и «Search and Connect» — никогда", () => {
  const connect = psRegex("connectPattern"), deny = psRegex("denyPattern");
  for (const name of ["Connect", "CONNECT", "Подключиться", "Connect to partner", "Verbinden"]) assert.ok(connect.test(name) && !deny.test(name), name);
  for (const name of ["Search and Connect ⌘K", "Search and Connect", "Cancel", "Deny", "Close", "Отмена", "Закрыть", "Abbrechen", "Disconnect"]) assert.ok(!connect.test(name), name);
  for (const name of ["Cancel", "Deny", "Close", "Отмена", "Отклонить", "Закрыть", "Abbrechen", "Скасувати"]) assert.ok(deny.test(name), name);
  // Отказ проверяется раньше совпадения; нажатие — InvokePattern, не координаты и не клавиатура.
  const finder = PS.slice(PS.indexOf("function Find-ConnectButton"), PS.indexOf("function Submit-PartnerId"));
  assert.ok(finder.indexOf("$denyPattern") >= 0 && finder.indexOf("$denyPattern") < finder.indexOf("$connectPattern"));
  const submit = PS.slice(PS.indexOf("function Submit-PartnerId"), PS.indexOf("\ntry {"));
  assert.ok(submit.indexOf("SetValue($partnerId)") < submit.indexOf("$invoke.Invoke()"), "ID ставится до нажатия «Connect»");
  assert.match(submit, /IsPassword -or/, "поле пароля под ID не используется");
  assert.ok(!/SendWait|SendKeys|Mouse|Cursor|BoundingRectangle|ClickablePoint/i.test(submit), "без клавиатуры и координат");
  assert.deepEqual([...PS.matchAll(/SendWait\([^)]*\)/g)].map((m) => m[0]), ["SendWait('{ENTER}')"]);
});

test("скрипт: «session» — только новое окно с ID в заголовке, без поля пароля, устоявшееся; таймаут — «noWindow»; продление ограничено", () => {
  const session = PS.slice(PS.indexOf("function Find-SessionWindow"), PS.indexOf("function Find-ConnectButton"));
  assert.match(session, /knownWindows\.Contains/, "окно прежнего сеанса не подтверждает новый");
  assert.match(session, /-replace '\\D', ''/, "цифры ID без пробелов");
  assert.match(session, /IsPassword/, "окно с полем пароля — не сеанс");
  assert.match(session, /\$connectingPattern -or \$window\.Current\.Name -match \$failedPattern/, "окно хода и ошибки — не сеанс");
  for (const title of ["Connecting to 123 456 789", "Подключение к 123 456 789", "Connection to 123 456 789 failed"]) assert.ok(psRegex("connectingPattern").test(title) || psRegex("failedPattern").test(title), title);
  for (const title of ["123 456 789 - TeamViewer", "Лаборатория (123 456 789) - TeamViewer"]) assert.ok(!psRegex("connectingPattern").test(title) && !psRegex("failedPattern").test(title), title);
  const loop = PS.slice(PS.indexOf("Emit 'ready'"), PS.indexOf("if (-not $found) { if ($sawProcess)"));
  assert.ok(loop.indexOf("Find-PasswordField") < loop.indexOf("Find-SessionWindow"), "окно пароля важнее");
  assert.match(loop, /TotalMilliseconds -ge \$SettleMs\) \{ Emit 'session'/);
  assert.match(PS, /\$limit = \$started\.AddMilliseconds\(\$timeoutMs \* (\d+)\)/);
  assert.equal(Number(PS.match(/\$timeoutMs \* (\d+)\)/)[1]), MAX_EXTENSION, "сторож uia.js покрывает продление");
  assert.match(PS, /if \(\$noPassword\) \{ Emit 'passwordNeeded'; return \}/);
  assert.ok(PS.indexOf("Emit 'passwordNeeded'") < PS.indexOf("SetValue($password)"));
  assert.ok(!/Clipboard|SetText/i.test(PS), "скрипт буфер обмена не трогает");
});
