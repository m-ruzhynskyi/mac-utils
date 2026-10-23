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
const { createUia, SCRIPT, MAX_EXTENSION, MAX_TOTAL } = require("../../remote/uia");
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
    child.stdin = Object.assign(new EventEmitter(), { write: (d, cb) => { chunks.push(Buffer.from(d)); cb?.(); return true; }, end() { r.ended = (r.ended || 0) + 1; } });
    r.spawned.push({ file, args, opts, chunks });
    if (/powershell/i.test(file)) {
      r.stdin = chunks;
      r.order.push("powershell");
      setImmediate(() => {
        r.order.push("ready");
        child.stdout.emit("data", Buffer.from('{"state":"ready"}\n'));
        // Как скрипт: после «passwordField» ждёт вторую строку stdin (пароль), только потом идёт дальше.
        setTimeout(async () => {
          for (const state of lines) {
            r.order.push(state);
            const had = chunks.length;
            child.stdout.emit("data", Buffer.from(JSON.stringify({ state }) + "\n"));
            if (state === "passwordField") {
              r.inputAtField = Buffer.concat(chunks).toString("utf8");
              for (let i = 0; i < 50 && chunks.length === had; i++) await new Promise((res) => setTimeout(res, 2));
              r.order.push("password");
            }
          }
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
  r.store = { password: async () => { r.order.push("readPassword"); if (r.passwordThrows) throw new Error("gone"); if (r.noSecret) return null; const s = new SecretBuffer(PW); r.secrets.push(s); return s; } };
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
  const r = rig({ lines: ["waiting", "idSubmitted", "waiting", "intermediate", "waiting", "passwordField", "confirming", "connected"] });
  const out = await r.run();
  assert.deepEqual(out, { ok: true });
  assert.deepEqual(r.order.slice(0, 3), ["powershell", "ready", "teamviewer"], "TeamViewer — после того, как скрипт запомнил окна");
  // W2-3: пароль читается из файла только по «passwordField» и дописывается в stdin до продолжения скрипта.
  assert.ok(r.order.indexOf("readPassword") > r.order.indexOf("passwordField"), r.order.join(","));
  assert.ok(r.order.indexOf("readPassword") < r.order.indexOf("password"), r.order.join(","));
  assert.equal(r.inputAtField, JSON.stringify({ timeoutMs: 20_000, id: "123456789" }) + "\n", "до поля пароля в stdin — только параметры");
  const [options, password] = r.input();
  assert.deepEqual(JSON.parse(options), { timeoutMs: 20_000, id: "123456789" }, "ID — в параметрах скрипта (для поля ID и окна сеанса)");
  assert.equal(password, PW, "пароль — второй строкой stdin, не в параметрах");
  assert.ok(!JSON.stringify(r.spawned.map((s) => s.args)).includes("КАНАРЕЙКА"));
  assert.ok(r.states.some((s) => /Ввёл ID в TeamViewer/.test(s.title)), "ход виден: ID введён");
  assert.ok(r.states.some((s) => /TeamViewer подключается/.test(s.title)), "промежуточное окно — ждём дальше");
  const successAt = r.states.findIndex((s) => s.kind === "success");
  assert.equal(successAt, r.states.length - 1, "успех — только итогом, не раньше");
  assert.equal(r.states.at(-1).title, "Подключено");
  assert.ok(r.states.some((s) => /жду сеанс/.test(s.title)), "после ввода пароля ждём окно сеанса");
  assert.deepEqual(r.copied, [], "подключение подтверждено — буфер не трогаем");
  assert.ok(r.log.some((l) => /password=1 confirmed=1 typed=1/.test(l)), r.log.join("|"));
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

// ---- Скрипт: «Connect» — только в ближайшем контейнере поля ID (W2-1), повторно ID не вводится (W2-2) ----
test("W2-1: «Connect» ищется только в ближайшем общем контейнере поля ID, не во всём окне; плитки устройств — никогда", () => {
  const finder = PS.slice(PS.indexOf("function Find-ConnectButton"), PS.indexOf("function Get-ForegroundPid"));
  assert.ok(!/\$scopes \+= \$window/.test(finder) && !/\$window\.FindAll/.test(finder), "всё окно не просматривается");
  assert.match(finder, /Compare\(\$node, \$window\)[^\n]*\{ return \$null \}/, "дошли до окна — кнопки нет");
  assert.match(finder, /\$hits\.Count -gt 1 -or \(Test-HasList \$node\)\) \{ return \$null \}/, "несколько «Connect» или список устройств — не форма поля");
  assert.match(finder, /\$i -lt 3/, "не выше трёх уровней");
  assert.ok(!/\$matches/.test(finder), "$matches — автоматическая переменная -match, её не используем");
  const list = PS.match(/\$listTypes = @\(([^\n]+)\)/)[1];
  for (const t of ["List", "ListItem", "DataGrid", "DataItem", "Tree", "Table"]) assert.match(list, new RegExp(`ControlType\\]::${t}\\b`), t);
  // Кнопки формы нет — ID всё равно ставится, подтверждение — Enter в поле (см. тест про клавиатуру).
  const submit = PS.slice(PS.indexOf("function Submit-PartnerId"), PS.indexOf("function Get-ShownIds"));
  assert.ok(submit.indexOf("Find-ConnectButton") < submit.indexOf("SetValue($partnerId)"));
  assert.match(submit, /if \(\$button\) \{ \$invoke\.Invoke\(\); return 'submitted' \}/);
});

test("W2-2: ID уже в поле (запуск с -i сработал) — не вводим и «Connect» второй раз не жмём; запасной ввод — не раньше 8 с", () => {
  const submit = PS.slice(PS.indexOf("function Submit-PartnerId"), PS.indexOf("function Get-ShownIds"));
  const present = submit.indexOf("return 'present'");
  assert.ok(present > 0 && present < submit.indexOf("SetValue($partnerId)") && present < submit.indexOf("Invoke()"));
  assert.match(submit, /\(\[string\]\$value\.Current\.Value -replace '\\D', ''\) -eq \$digits\) \{ return 'present' \}/);
  assert.match(PS, /if \(\$submit -eq 'present'\) \{ \$submitted = \$true \}/, "после «present» больше не пытаемся");
  assert.match(PS, /\$graceUntil = \$started\.AddMilliseconds\(\[Math\]::Min\(8000, \$timeoutMs \/ 2\)\)/);
});

test("W2-1: окно пароля показывает другой ID — пароль не вводится (idMismatch); номер ищется по группам цифр через пробел", () => {
  const check = PS.indexOf("Get-ShownIds $found.Window");
  assert.ok(check > 0 && check < PS.indexOf("Emit 'passwordField'") && check < PS.indexOf("SetValue($password)"));
  assert.match(PS, /if \(\$shown\.Count -and \$shown -notcontains \$digits\) \{ Emit 'idMismatch'; return \}/);
  const pattern = new RegExp(PS.match(/\[regex\]::Matches\(\$t, '([^']+)'\)/)[1].replace("\\u00A0", "\u00A0"), "g");
  const shown = (t) => (t.match(pattern) || []).map((m) => m.replace(/\D/g, "")).filter((n) => n.length >= 7);
  assert.deepEqual(shown("Партнёр 987 654 321"), ["987654321"]);
  assert.deepEqual(shown("TeamViewer Authentication"), []);
  assert.deepEqual(shown("23.10.2026 · версия 15.58.5"), [], "даты и версии — не ID");
  assert.deepEqual(shown("1 234 567 890 - TeamViewer"), ["1234567890"]);
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
  assert.ok(!/Mouse|Cursor|BoundingRectangle|ClickablePoint/i.test(submit), "без координат");
  // Клавиатура в запасном пути — только Enter, и только когда поле ID в фокусе, а окно TeamViewer впереди.
  const keys = [...submit.matchAll(/SendWait\([^)]*\)/g)].map((m) => m[0]);
  assert.deepEqual(keys, ["SendWait('{ENTER}')"]);
  assert.match(submit, /\(Get-ForegroundPid\) -eq \$tvPid -and \$edit\.Current\.HasKeyboardFocus\) \{ \[System\.Windows\.Forms\.SendKeys\]::SendWait\('\{ENTER\}'\)/);
  assert.ok([...PS.matchAll(/SendWait\([^)]*\)/g)].every((m) => m[0] === "SendWait('{ENTER}')"));
});

test("скрипт: «session» — только новое окно с ID в заголовке, без поля пароля, устоявшееся; таймаут — «noWindow»; продление ограничено", () => {
  const session = PS.slice(PS.indexOf("function Find-SessionWindow"), PS.indexOf("function Find-ConnectButton"));
  assert.match(session, /knownWindows\.Contains/, "окно прежнего сеанса не подтверждает новый");
  assert.match(session, /-replace '\\D', ''/, "цифры ID без пробелов");
  assert.match(session, /IsPassword/, "окно с полем пароля — не сеанс");
  assert.match(session, /\$connectingPattern -or \$window\.Current\.Name -match \$failedPattern/, "окно хода и ошибки — не сеанс");
  for (const title of ["Connecting to 123 456 789", "Подключение к 123 456 789", "Connection to 123 456 789 failed"]) assert.ok(psRegex("connectingPattern").test(title) || psRegex("failedPattern").test(title), title);
  for (const title of ["123 456 789 - TeamViewer", "Лаборатория (123 456 789) - TeamViewer"]) assert.ok(!psRegex("connectingPattern").test(title) && !psRegex("failedPattern").test(title), title);
  assert.ok(PS.indexOf("if (-not $found) { if ($sawWindow)") > 0);
  const loop = PS.slice(PS.indexOf("Emit 'ready'"), PS.indexOf("if (-not $found) { if ($sawWindow)"));
  assert.ok(loop.indexOf("Find-PasswordField") < loop.indexOf("Find-SessionWindow"), "окно пароля важнее");
  assert.match(loop, /TotalMilliseconds -ge \$SettleMs\) \{ Emit 'session'/);
  assert.equal(Number(PS.match(/\$limit = \$started\.AddMilliseconds\(\$timeoutMs \* (\d+)\)/)[1]), MAX_EXTENSION);
  assert.equal(Number(PS.match(/\$hardLimit = \$started\.AddMilliseconds\(\$timeoutMs \* (\d+)\)/)[1]), MAX_TOTAL, "сторож uia.js покрывает и проверку сеанса");
  assert.match(PS, /if \(\$noPassword\) \{ Emit 'passwordNeeded'; return \}/);
  assert.ok(PS.indexOf("Emit 'passwordNeeded'") < PS.indexOf("SetValue($password)"));
  assert.ok(!/Clipboard|SetText/i.test(PS), "скрипт буфер обмена не трогает");
});

test("E1: «окно TeamViewer было» — только по окнам клиента; служба TeamViewer_Service и TeamViewer_Desktop не в счёт → noPrompt и noWindow различаются", () => {
  assert.match(PS, /\$serviceNames = @\('TeamViewer_Service', 'TeamViewer_Desktop'\)/);
  assert.match(PS, /function Get-TeamViewerIds \{[^\n]*\$serviceNames -notcontains \$_\.ProcessName/);
  assert.match(PS, /if \(\(Get-TeamViewerWindows \$ids\)\.Count\) \{ \$sawWindow = \$true \}/);
  assert.match(PS, /if \(-not \$found\) \{ if \(\$sawWindow\) \{ Emit 'noPrompt' \} else \{ Emit 'noWindow' \}; return \}/);
  assert.ok(!/\$sawProcess/.test(PS), "по одному процессу (служба работает всегда) «открыт» не считаем");
});

test("E1: noPrompt → «Не удалось подтвердить», noWindow → «TeamViewer не открылся» с «Повторить»; оба не успех, в «Недавние» не идут", async () => {
  const a = rig({ lines: ["waiting", "noPrompt"] });
  assert.deepEqual(await a.run(), { ok: false, error: "unconfirmed" });
  assert.equal(a.states.at(-1).kind, "info");
  assert.match(a.states.at(-1).title, /Не удалось подключиться — ID скопирован/);
  const b = rig({ lines: ["waiting", "noWindow"] });
  assert.deepEqual(await b.run(), { ok: false, error: "noWindow" });
  assert.equal(b.states.at(-1).kind, "warning");
  assert.equal(b.states.at(-1).title, "TeamViewer не открылся");
  assert.ok(b.states.at(-1).actions.some((x) => x.id === "retry"));
  assert.deepEqual(b.copied, ["123456789"]);
  assert.ok(b.log.some((l) => /code=noWindow/.test(l)) && b.log.every((l) => LOG_LINE.test(l)));
  for (const r of [a, b]) {
    assert.ok(!r.states.some((s) => s.kind === "success"));
    assert.ok(!r.order.includes("readPassword"), "окна пароля не было — пароль из файла не читался");
  }
});

test("W2-4: после ввода пароля «Подключено» — только по окну сеанса; иначе «сеанс не подтверждён» или «закрыл сеанс», не успех", async () => {
  const ok = rig({ lines: ["passwordField", "confirming", "connected"] });
  assert.deepEqual(await ok.run(), { ok: true });
  assert.equal(ok.states.at(-1).kind, "success");
  assert.equal(ok.states.at(-1).title, "Подключено");
  const quiet = rig({ lines: ["passwordField", "confirming", "waiting", "submitted"] });
  assert.deepEqual(await quiet.run(), { ok: false, error: "submitted" });
  assert.equal(quiet.states.at(-1).kind, "info");
  assert.equal(quiet.states.at(-1).title, "Пароль введён · сеанс не подтверждён");
  assert.deepEqual(quiet.copied, [], "пароль ввели — ID в буфер не кладём");
  const closed = rig({ lines: ["passwordField", "confirming", "sessionClosed"] });
  assert.deepEqual(await closed.run(), { ok: false, error: "sessionClosed" });
  assert.equal(closed.states.at(-1).kind, "warning");
  assert.equal(closed.states.at(-1).title, "TeamViewer закрыл сеанс");
  // Прежний итог «entered» (пароль ушёл, сеанс не проверен) — тоже не успех.
  const legacy = rig({ lines: ["passwordField", "entered"] });
  assert.deepEqual(await legacy.run(), { ok: false, error: "submitted" });
  for (const r of [ok, quiet, closed, legacy]) {
    assert.ok(r.secrets.length === 1 && r.secrets.every((s) => s.isWiped));
    assert.ok(!r.dump().includes("КАНАРЕЙКА"));
    assert.ok(r.log.every((l) => LOG_LINE.test(l)), r.log.join("|"));
    assert.equal(r.states.filter((s) => s.kind === "success").length, r === ok ? 1 : 0);
  }
  // Скрипт: после пароля ждёт устоявшееся окно сеанса; закрытие — «sessionClosed»; к сроку — «submitted»; «entered» не выдаёт.
  const confirm = PS.slice(PS.indexOf("Emit 'confirming'"), PS.indexOf("} catch {", PS.indexOf("Emit 'confirming'")));
  assert.ok(confirm.indexOf("Find-SessionWindow") >= 0 && confirm.indexOf("Find-SessionWindow") < confirm.indexOf("Emit 'connected'"));
  assert.match(confirm, /TotalMilliseconds -ge \$SettleMs\) \{ Emit 'connected'/);
  assert.match(confirm, /Test-SessionClosed \$ids\) \{ Emit 'sessionClosed'/);
  assert.match(confirm, /TotalMilliseconds -ge \$CloseMs\) \{ Emit 'sessionClosed'/);
  assert.match(confirm, /Emit 'submitted'\s*$/);
  assert.ok(!/Emit 'entered'/.test(PS));
  assert.ok(!/\?\s*\$confirmUntil\s*:/.test(PS), "без тернарного оператора: в Windows PowerShell 5.1 его нет");
  const closedRe = psRegex("closedPattern");
  for (const t of ["Session ended", "The connection was closed", "Сеанс завершён", "Соединение разорвано", "Verbindung getrennt", "З'єднання закрито"]) assert.ok(closedRe.test(t), t);
  for (const t of ["Connecting to 123 456 789", "123 456 789 - TeamViewer", "Waiting for image"]) assert.ok(!closedRe.test(t), t);
});

test("W2-3: пароль TeamViewer не читается, пока скрипт не нашёл поле; нет окна — не читается вовсе; запись пропала — «Записи больше нет»", async () => {
  const none = rig({ lines: ["waiting", "intermediate", "session"] });
  await none.run();
  assert.ok(!none.order.includes("readPassword"), "сеанс без окна пароля — файл с паролем не читали");
  assert.equal(none.input()[1], "", "вторая строка (пароль) так и не пришла");
  const gone = rig({ lines: ["passwordField", "passwordNeeded"] });
  gone.passwordThrows = true;
  assert.deepEqual(await gone.run(), { ok: false, error: "gone" });
  assert.match(gone.states.at(-1).title, /Записи больше нет/);
  assert.equal(gone.input()[1], "", "пароля нет — пустая строка, скрипт ничего не вводит");
  const empty = rig({ lines: ["passwordField", "passwordNeeded"] });
  empty.noSecret = true;
  assert.deepEqual(await empty.run(), { ok: true });
  assert.match(empty.states.at(-1).title, /Введите пароль в окне TeamViewer/);
  // Скрипт: пароль ждёт второй строкой только после «passwordField»; пусто — ничего не вводит.
  assert.match(PS, /Emit 'passwordField'\s+\$password = \$reader\.ReadLine\(\)\s+if \(-not \$password\) \{ \$password = \$null; Emit 'passwordNeeded'; return \}/);
  assert.equal((PS.match(/\$reader\.ReadLine\(\)/g) || []).length, 2, "параметры и (по запросу) пароль");
});
