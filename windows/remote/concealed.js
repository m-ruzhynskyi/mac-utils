// Секрет в буфер обмена Windows мимо журнала буфера (Win+V) и облачной синхронизации — через clip-conceal.ps1 (W2-5).
// Секрет уходит в stdin PowerShell байтами (в аргументах его нет), копия байтов затирается сразу после записи. Ничего не пишет в
// журнал. Итог — Promise<boolean>: true — буфер принял текст вместе с форматами-исключениями; false — не записано ничего (тогда
// вызывающий НЕ кладёт секрет обычным writeText: в журнал буфера и облако он попасть не должен).
"use strict";

const path = require("node:path");
const { POWERSHELL } = require("./uia");

// Как tv-uia.ps1: в упакованном приложении скрипт распакован из app.asar рядом (`build.asarUnpack`).
const CLIP_SCRIPT = path.join(__dirname, "clip-conceal.ps1").replace(/([\\/])app\.asar([\\/])/, "$1app.asar.unpacked$2");
// Форматы, которые кладутся вместе с текстом (для тестов и проверки скрипта).
const CONCEAL_FORMATS = ["ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"];
const TIMEOUT_MS = 10_000;

// spawn — child_process.spawn (в тестах двойник). Возвращает write(secret: SecretBuffer) → Promise<boolean>; secret затирает вызывающий.
function createConcealedWriter(spawn, { script = CLIP_SCRIPT, powershell = POWERSHELL, timeoutMs = TIMEOUT_MS } = {}) {
  return function write(secret) {
    return new Promise((resolve) => {
      if (!secret || !secret.length || typeof spawn !== "function") return resolve(false);
      let settled = false, ok = false, payload = null, guard = null, child = null;
      const wipe = () => { if (payload) { payload.fill(0); payload = null; } };
      const done = (value) => { if (settled) return; settled = true; clearTimeout(guard); wipe(); resolve(value); };
      try {
        // -Sta: буфер обмена Windows Forms требует однопоточный апартамент.
        child = spawn(powershell, ["-NoProfile", "-NonInteractive", "-Sta", "-ExecutionPolicy", "Bypass", "-File", script], { stdio: ["pipe", "pipe", "ignore"], windowsHide: true });
      } catch (_) { return done(false); }
      child.on?.("error", () => done(false));
      child.stdin?.on?.("error", () => done(false));
      child.stdout?.on?.("error", () => {});
      let buffer = "";
      child.stdout?.on?.("data", (chunk) => {
        buffer += chunk.toString("utf8");
        if (/\{"state":"ok"\}/.test(buffer)) ok = true;
        if (buffer.length > 4096) buffer = buffer.slice(-64);
      });
      // «close» — после того как вывод дочитан; «exit» может прийти раньше последних данных — даём выводу дойти.
      child.on?.("close", (code) => done(ok && (code === 0 || code == null)));
      child.on?.("exit", (code) => { const t = setTimeout(() => done(ok && (code === 0 || code == null)), 200); t.unref?.(); });
      try {
        payload = Buffer.from(secret.bytes);
        child.stdin.write(payload, () => { wipe(); try { child.stdin.end(); } catch (_) {} });
      } catch (_) { try { child.kill?.(); } catch (_) {} return done(false); }
      guard = setTimeout(() => { try { child.kill?.(); } catch (_) {} done(false); }, timeoutMs);
      guard.unref?.();
    });
  };
}

module.exports = { createConcealedWriter, CLIP_SCRIPT, CONCEAL_FORMATS };
