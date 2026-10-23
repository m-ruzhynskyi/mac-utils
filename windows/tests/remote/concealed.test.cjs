// W2-5: секрет в буфер обмена Windows — мимо журнала буфера (Win+V) и облачной синхронизации. PowerShell — двойник; реальный буфер,
// PowerShell и окна не трогаются. Плюс ленивая передача пароля в tv-uia.ps1 (W2-3) на уровне uia.js.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const { createConcealedWriter, CLIP_SCRIPT, CONCEAL_FORMATS } = require("../../remote/concealed");
const { createUia } = require("../../remote/uia");
const { SecretBuffer } = require("../../remote/secret");

const SECRET = "Доступ-КАНАРЕЙКА-vpn-ключ-777";

function psDouble({ reply = '{"state":"ok"}\n', code = 0, error = null, never = false } = {}) {
  const calls = [];
  const spawn = (file, args, opts) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    const written = [];
    child.kill = () => { child.killed = true; child.emit("close", null); };
    child.stdin = Object.assign(new EventEmitter(), { write: (d, cb) => { written.push(d); cb?.(); return true; }, end() { child.ended = true; } });
    calls.push({ file, args, opts, written, child });
    if (!never) setImmediate(() => {
      if (error) return child.emit("error", error);
      if (reply) child.stdout.emit("data", Buffer.from(reply));
      child.emit("close", code);
    });
    return child;
  };
  return { spawn, calls };
}

test("W2-5: секрет уходит в stdin помощника байтами, в аргументах его нет; копия затирается; -Sta, без окна", async () => {
  const ps = psDouble();
  const secret = new SecretBuffer(SECRET);
  assert.equal(await createConcealedWriter(ps.spawn)(secret), true);
  const [call] = ps.calls;
  assert.match(call.file, /System32\\WindowsPowerShell\\v1\.0\\powershell\.exe$/);
  assert.ok(call.args.includes("-Sta") && call.args.includes("-NoProfile") && call.args.includes("-NonInteractive"));
  assert.equal(call.args.at(-1), CLIP_SCRIPT);
  assert.ok(!JSON.stringify(call.args).includes("КАНАРЕЙКА"));
  assert.equal(call.opts.windowsHide, true);
  assert.equal(call.written.length, 1);
  assert.ok(call.written[0].every((b) => b === 0), "копия байтов в stdin затёрта после записи");
  assert.ok(call.child.ended, "вход закрыт — скрипт читает до конца");
  assert.ok(!secret.isWiped, "SecretBuffer затирает вызывающий");
});

test("W2-5: помощник не ответил «ok», упал, не запустился или завис — false (секрет обычным текстом не кладётся)", async () => {
  assert.equal(await createConcealedWriter(psDouble({ reply: "" }).spawn)(new SecretBuffer("x")), false);
  assert.equal(await createConcealedWriter(psDouble({ code: 1 }).spawn)(new SecretBuffer("x")), false);
  assert.equal(await createConcealedWriter(psDouble({ error: new Error("ENOENT") }).spawn)(new SecretBuffer("x")), false);
  assert.equal(await createConcealedWriter(() => { throw new Error("EPERM"); })(new SecretBuffer("x")), false);
  const hang = psDouble({ never: true });
  const keepAlive = setTimeout(() => {}, 5000);   // сторож помощника unref — цикл событий держит тест
  assert.equal(await createConcealedWriter(hang.spawn, { timeoutMs: 20 })(new SecretBuffer("x")), false);
  clearTimeout(keepAlive);
  assert.ok(hang.calls[0].child.killed);
  assert.equal(await createConcealedWriter(psDouble().spawn)(new SecretBuffer("")), false, "пустое не копируем");
  assert.equal(await createConcealedWriter(psDouble().spawn)(null), false);
});

test("W2-5: скрипт кладёт текст вместе с форматами-исключениями журнала и облака; секрет не выводится и не пишется на диск", () => {
  const raw = fs.readFileSync(CLIP_SCRIPT);
  assert.deepEqual([...raw.subarray(0, 3)], [0xef, 0xbb, 0xbf], "UTF-8 с BOM — для Windows PowerShell 5.1");
  const ps = raw.toString("utf8");
  for (const f of CONCEAL_FORMATS) assert.match(ps, new RegExp(`SetData\\('${f}'`), f);
  assert.deepEqual(CONCEAL_FORMATS, ["ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"]);
  assert.match(ps, /\[BitConverter\]::GetBytes\(\[int\]0\)/, "DWORD 0");
  assert.match(ps, /SetData\(\[System\.Windows\.Forms\.DataFormats\]::UnicodeText, \$text\)/);
  assert.match(ps, /\[System\.Windows\.Forms\.Clipboard\]::SetDataObject\(\$data, \$true/, "один объект: текст и форматы вместе");
  assert.match(ps, /OpenStandardInput\(\)/);
  assert.match(ps, /UTF8Encoding/);
  for (const bad of ["Set-Clipboard", "SetText(", "Out-File", "Set-Content", "Add-Content", "Write-Host", "Start-Transcript", "$args", "param("]) assert.ok(!ps.includes(bad), bad);
  assert.ok(!/WriteLine\([^)]*\$text/.test(ps));
  assert.match(ps, /\$text = \$null/);
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "package.json"), "utf8"));
  assert.ok(pkg.build.asarUnpack.includes("remote/clip-conceal.ps1"), "скрипт распакован из app.asar, как tv-uia.ps1");
});

// ---- W2-3 на уровне uia.js ----
function uiaDouble(lines) {
  const r = { written: [], raw: [], ended: 0, read: 0 };
  const spawn = () => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.kill = () => child.emit("exit", 1);
    child.stdin = Object.assign(new EventEmitter(), { write: (d, cb) => { r.raw.push(d); r.written.push(Buffer.from(d)); cb?.(); return true; }, end() { r.ended++; } });
    setImmediate(async () => {
      for (const state of lines) {
        r.writtenAt ??= {};
        r.writtenAt[state] = Buffer.concat(r.written).toString("utf8");
        child.stdout.emit("data", Buffer.from(JSON.stringify({ state }) + "\n"));
        await new Promise((res) => setTimeout(res, 3));
      }
      child.emit("exit", 0);
    });
    return child;
  };
  return { r, uia: createUia(spawn) };
}

test("W2-3: uia.js читает пароль только по «passwordField», один раз; до этого stdin открыт и в нём только параметры", async () => {
  const { r, uia } = uiaDouble(["ready", "waiting", "intermediate", "passwordField", "confirming", "connected"]);
  const secrets = [];
  const result = await uia.enter({ timeoutMs: 9000, id: "123456789" }, async () => { r.read++; const s = new SecretBuffer(SECRET); secrets.push(s); return s; });
  assert.deepEqual(result, { state: "connected" });
  assert.equal(r.read, 1);
  const params = JSON.stringify({ timeoutMs: 9000, id: "123456789" }) + "\n";
  assert.equal(r.writtenAt.passwordField, params, "до поля пароля — только параметры");
  assert.equal(r.writtenAt.confirming, params + SECRET + "\n", "пароль — второй строкой, сразу после запроса");
  assert.ok(Buffer.isBuffer(r.raw[1]) && r.raw[1].every((b) => b === 0), "копия пароля затёрта");
  assert.ok(secrets.every((s) => s.isWiped), "SecretBuffer затёрт сразу после записи");
  assert.equal(r.ended, 1);
});

test("W2-3: без «passwordField» пароль не читается вовсе; без пароля вход закрыт сразу; ошибка чтения — пустая строка и secretError", async () => {
  const a = uiaDouble(["ready", "waiting", "noPrompt"]);
  let reads = 0;
  assert.deepEqual(await a.uia.enter({ timeoutMs: 5000 }, async () => { reads++; return new SecretBuffer("x"); }), { state: "noPrompt" });
  assert.equal(reads, 0);
  assert.equal(a.r.ended, 0, "вход ждёт пароль — не закрыт (скрипт его так и не попросил)");
  const b = uiaDouble(["ready", "passwordField", "session"]);
  assert.deepEqual(await b.uia.enter({ timeoutMs: 5000, noPassword: true }, null), { state: "session" });
  assert.equal(b.r.ended, 1);
  assert.equal(Buffer.concat(b.r.written).toString("utf8"), JSON.stringify({ timeoutMs: 5000, noPassword: true }) + "\n", "запрос пароля при noPassword игнорируется");
  const c = uiaDouble(["ready", "passwordField", "passwordNeeded"]);
  const out = await c.uia.enter({ timeoutMs: 5000 }, async () => { throw new Error("entry gone"); });
  assert.equal(out.state, "passwordNeeded");
  assert.ok(out.secretError);
  assert.equal(Buffer.concat(c.r.written).toString("utf8").split("\n")[1], "");
});
