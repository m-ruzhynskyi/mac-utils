// Запуск tv-uia.ps1: пароль уходит в stdin PowerShell (в аргументах его нет), результат — строки JSON на stdout.
"use strict";

const path = require("node:path");

// В упакованном приложении `remote/` лежит внутри app.asar, а powershell читает файл с диска: скрипт распакован рядом
// (`build.asarUnpack`), путь переписывается на app.asar.unpacked.
const SCRIPT = path.join(__dirname, "tv-uia.ps1").replace(/([\\/])app\.asar([\\/])/, "$1app.asar.unpacked$2");
// powershell.exe — по полному пути из системной папки, а не по PATH и текущей папке.
const POWERSHELL = path.win32.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
const STATES = new Set(["ready", "waiting", "idSubmitted", "intermediate", "passwordField", "confirming", "entered", "connected", "session", "submitted",
  "sessionClosed", "passwordNeeded", "noPrompt", "noWindow", "idMismatch", "elevated", "focusLost", "fieldNotFound", "wrongPassword"]);
// Промежуточные события: скрипт продолжает работу. Остальные состояния — итог.
const EVENTS = new Set(["waiting", "idSubmitted", "intermediate", "confirming"]);
// Скрипт продлевает ожидание окна пароля не дольше двух сроков, а проверка сеанса после ввода пароля кончается не позже трёх.
const MAX_EXTENSION = 2;
const MAX_TOTAL = 3;

// spawn — child_process.spawn (в тестах двойник). Возвращает { enter(options, password, onEvent), cancel() }.
// options: { timeoutMs, id?, noPassword?, afterReady? } — afterReady вызывается, когда скрипт запомнил уже открытые окна и готов
// ждать новое: запускать TeamViewer нужно только после этого, иначе пароль уйдёт в окно прежнего подключения. id — ID партнёра
// (запасной ввод в главное окно, сверка с окном пароля и опознание окна сеанса); noPassword — пароля нет: окно пароля только
// обнаруживается. password — async () => SecretBuffer | null: вызывается ЛИШЬ по событию скрипта «passwordField» (поле найдено и
// проверено), так пароль не лежит ни в модуле, ни в PowerShell, пока идёт ожидание. Ошибка чтения — в итоге { secretError }.
function createUia(spawn, { script = SCRIPT, powershell = POWERSHELL } = {}) {
  const active = new Set();   // идущие вызовы: у каждого свой процесс и свой признак отмены
  return {
    enter({ timeoutMs, id, noPassword, afterReady }, password, onEvent = () => {}) {
      const getSecret = typeof password === "function" ? password : async () => password || null;
      const withoutPassword = !!noPassword || password == null;
      return new Promise((resolve) => {
        const run = { child: null, cancelled: false };
        let settled = false, last = "fieldNotFound", payload = null, asked = false, secretError = null;
        const wipePayload = () => { if (payload) { payload.fill(0); payload = null; } };
        let guard = null;
        const done = (state) => {
          if (settled) return;
          settled = true; clearTimeout(guard); active.delete(run); wipePayload();
          resolve(secretError ? { state, secretError } : { state });
        };
        const endInput = () => { try { run.child.stdin.end(); } catch (_) {} };
        // Поле пароля найдено: читаем пароль из файла сейчас, пишем байтами (UTF-8) второй строкой и закрываем вход. Нет пароля
        // или ошибка чтения — пустая строка: скрипт ничего не вводит. Копия байтов и SecretBuffer затираются сразу после записи.
        async function sendPassword() {
          if (asked) return;
          asked = true;
          let secret = null;
          try { secret = await getSecret(); } catch (error) { secretError = error || new Error("secret"); }
          if (settled) { secret?.wipe?.(); return; }
          try {
            payload = Buffer.concat([secret ? secret.bytes : Buffer.alloc(0), Buffer.from("\n")]);
            run.child.stdin.write(payload, () => { wipePayload(); endInput(); });
          } catch (_) { wipePayload(); endInput(); }
          finally { secret?.wipe?.(); }
        }
        let child;
        try {
          child = spawn(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script], { stdio: ["pipe", "pipe", "ignore"], windowsHide: true });
        } catch (_) { return done("fieldNotFound"); }
        run.child = child; active.add(run);
        // Запуск мог не удаться асинхронно (нет powershell.exe, отказ доступа): без обработчиков запись в stdin даёт необработанную
        // ошибку в главном процессе.
        child.on("error", () => done("fieldNotFound"));
        child.stdin?.on?.("error", () => done("fieldNotFound"));
        child.stdout?.on?.("error", () => {});
        let buffer = "";
        child.stdout.on("data", (chunk) => {
          buffer += chunk.toString("utf8");
          for (let i = buffer.indexOf("\n"); i >= 0; i = buffer.indexOf("\n")) {
            const line = buffer.slice(0, i).trim(); buffer = buffer.slice(i + 1);
            let state; try { state = JSON.parse(line).state; } catch (_) { continue; }
            if (!STATES.has(state)) continue;
            if (state === "ready") { try { Promise.resolve(afterReady?.()).catch(() => {}); } catch (_) {} }
            else if (state === "passwordField") { if (!withoutPassword) sendPassword(); }
            else if (EVENTS.has(state)) onEvent({ state });
            else { last = state; done(state); }
          }
        });
        child.on("exit", () => done(run.cancelled ? "cancelled" : last));
        // Параметры — первой строкой stdin. Без пароля вход закрывается сразу; с паролем — остаётся открытым до «passwordField».
        try {
          child.stdin.write(JSON.stringify({ timeoutMs, id: id == null ? undefined : String(id), noPassword: withoutPassword ? true : undefined }) + "\n");
          if (withoutPassword) endInput();
        } catch (_) { return done("fieldNotFound"); }
        guard = setTimeout(() => { try { child.kill(); } catch (_) {} done("fieldNotFound"); }, timeoutMs * MAX_TOTAL + 10_000);
        guard.unref?.();
      });
    },
    cancel() { for (const run of [...active]) { run.cancelled = true; try { run.child.kill(); } catch (_) {} } },
  };
}

module.exports = { createUia, SCRIPT, POWERSHELL, MAX_EXTENSION, MAX_TOTAL };
