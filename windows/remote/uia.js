// Запуск tv-uia.ps1: пароль уходит в stdin PowerShell (в аргументах его нет), результат — строки JSON на stdout.
"use strict";

const path = require("node:path");

// В упакованном приложении `remote/` лежит внутри app.asar, а powershell читает файл с диска: скрипт распакован рядом
// (`build.asarUnpack`), путь переписывается на app.asar.unpacked.
const SCRIPT = path.join(__dirname, "tv-uia.ps1").replace(/([\\/])app\.asar([\\/])/, "$1app.asar.unpacked$2");
// powershell.exe — по полному пути из системной папки, а не по PATH и текущей папке.
const POWERSHELL = path.win32.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
const STATES = new Set(["ready", "waiting", "idSubmitted", "intermediate", "entered", "session", "passwordNeeded", "noPrompt", "noWindow", "elevated", "focusLost", "fieldNotFound", "wrongPassword"]);
// Промежуточные события: скрипт продолжает работу. Остальные состояния — итог.
const EVENTS = new Set(["waiting", "idSubmitted", "intermediate"]);
// Скрипт продлевает ожидание, пока открыто известное промежуточное окно или после ввода ID, но не дольше двух сроков.
const MAX_EXTENSION = 2;

// spawn — child_process.spawn (в тестах двойник). Возвращает { enter(options, secret, onEvent), cancel() }.
// options: { timeoutMs, id?, noPassword?, afterReady? } — afterReady вызывается, когда скрипт запомнил уже открытые окна и готов
// ждать новое: запускать TeamViewer нужно только после этого, иначе пароль уйдёт в окно прежнего подключения. id — ID партнёра
// (запасной ввод в главное окно и опознание окна сеанса); noPassword — пароля нет: окно пароля только обнаруживается.
// secret — SecretBuffer или null (при noPassword).
function createUia(spawn, { script = SCRIPT, powershell = POWERSHELL } = {}) {
  const active = new Set();   // идущие вызовы: у каждого свой процесс и свой признак отмены
  return {
    enter({ timeoutMs, id, noPassword, afterReady }, secret, onEvent = () => {}) {
      return new Promise((resolve) => {
        const run = { child: null, cancelled: false };
        let settled = false, last = "fieldNotFound", payload = null;
        const wipePayload = () => { if (payload) { payload.fill(0); payload = null; } };
        let guard = null;
        const done = (state) => { if (!settled) { settled = true; clearTimeout(guard); active.delete(run); wipePayload(); resolve({ state }); } };
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
            else if (EVENTS.has(state)) onEvent({ state });
            else { last = state; done(state); }
          }
        });
        child.on("exit", () => done(run.cancelled ? "cancelled" : last));
        // Параметры и пароль — только через stdin; пароль байтами из буфера (UTF-8), копия затирается после записи.
        try {
          child.stdin.write(JSON.stringify({ timeoutMs, id: id == null ? undefined : String(id), noPassword: noPassword || !secret ? true : undefined }) + "\n");
          payload = Buffer.concat([secret ? secret.bytes : Buffer.alloc(0), Buffer.from("\n")]);
          child.stdin.write(payload, () => { wipePayload(); try { child.stdin.end(); } catch (_) {} });
        } catch (_) { return done("fieldNotFound"); }
        guard = setTimeout(() => { try { child.kill(); } catch (_) {} done("fieldNotFound"); }, timeoutMs * MAX_EXTENSION + 10_000);
        guard.unref?.();
      });
    },
    cancel() { for (const run of [...active]) { run.cancelled = true; try { run.child.kill(); } catch (_) {} } },
  };
}

module.exports = { createUia, SCRIPT, POWERSHELL, MAX_EXTENSION };
