// Запуск tv-uia.ps1: пароль уходит в stdin PowerShell (в аргументах его нет), результат — строки JSON на stdout.
"use strict";

const path = require("node:path");

const SCRIPT = path.join(__dirname, "tv-uia.ps1");
const STATES = new Set(["waiting", "entered", "noWindow", "elevated", "focusLost", "fieldNotFound", "wrongPassword"]);

// spawn — child_process.spawn (в тестах двойник). Возвращает { enter(options, secret, onEvent), cancel() }.
function createUia(spawn, { script = SCRIPT, powershell = "powershell.exe" } = {}) {
  let current = null, cancelled = false;
  return {
    enter({ timeoutMs }, secret, onEvent = () => {}) {
      return new Promise((resolve) => {
        let settled = false, last = "fieldNotFound";
        cancelled = false;
        const done = (state) => { if (!settled) { settled = true; current = null; resolve({ state }); } };
        let child;
        try {
          child = spawn(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script], { stdio: ["pipe", "pipe", "ignore"], windowsHide: true });
        } catch (_) { return done("fieldNotFound"); }
        current = child;
        let buffer = "";
        child.stdout.on("data", (chunk) => {
          buffer += chunk.toString("utf8");
          for (let i = buffer.indexOf("\n"); i >= 0; i = buffer.indexOf("\n")) {
            const line = buffer.slice(0, i).trim(); buffer = buffer.slice(i + 1);
            let state; try { state = JSON.parse(line).state; } catch (_) { continue; }
            if (!STATES.has(state)) continue;
            if (state === "waiting") onEvent({ state }); else { last = state; done(state); }
          }
        });
        child.on("error", () => done("fieldNotFound"));
        child.on("exit", () => done(cancelled ? "cancelled" : last));
        // Параметры и пароль — только через stdin; пароль байтами из буфера.
        child.stdin.write(JSON.stringify({ timeoutMs }) + "\n");
        child.stdin.write(Buffer.concat([secret.bytes, Buffer.from("\n")]), () => { try { child.stdin.end(); } catch (_) {} });
        const guard = setTimeout(() => { try { child.kill(); } catch (_) {} done("fieldNotFound"); }, timeoutMs + 10_000);
        guard.unref?.();
      });
    },
    cancel() { const child = current; current = null; cancelled = true; if (child) { try { child.kill(); } catch (_) {} } },
  };
}

module.exports = { createUia, SCRIPT };
