// Секрет (пароль учётки, «Доступ», пароль или ключ VPN) в буфер обмена: через 30 с буфер очищается, если в нём всё ещё он. Сам
// секрет после записи не хранится — только его SHA-256, чтобы узнать «всё ещё он» и не стереть то, что пользователь скопировал после.
// На Windows секрет пишется помощником writeConcealed (concealed.js): вместе с текстом — форматы, по которым журнал буфера (Win+V)
// и облачная синхронизация его не сохраняют (W2-5). Помощник не справился — секрет НЕ кладётся обычным текстом.
"use strict";

const crypto = require("node:crypto");

const CLEAR_MS = 30_000;
const digest = (bytes) => crypto.createHash("sha256").update(bytes).digest();

// clipboard: { writeText(text) → Promise, readText() → Promise<string>, clear() } — Electron 44 (запись и чтение асинхронные, clear —
// нет; await годится и для синхронного двойника); writeConcealed(secret) →
// Promise<boolean> — запись мимо журнала буфера (на Windows обязательна; без неё, не на Windows, — обычный writeText).
function createSecretClipboard({ clipboard, writeConcealed = null, setTimer = setTimeout, clearTimer = clearTimeout, clearMs = CLEAR_MS } = {}) {
  const pending = new Map();   // таймер → хеш

  const clearing = new Set();  // идущие очистки (чтение буфера асинхронное): выход их дожидается

  const stillOurs = async (hash) => {
    let now;
    try { now = await clipboard.readText(); } catch (_) { return false; }
    if (typeof now !== "string" || !now) return false;
    const bytes = Buffer.from(now, "utf8");
    try { return crypto.timingSafeEqual(digest(bytes), hash); } finally { bytes.fill(0); }
  };
  // Promise без отказа: стёрт ли буфер.
  const clearIfOurs = (hash) => {
    const run = (async () => {
      if (!(await stillOurs(hash))) return false;
      try { await clipboard.clear(); return true; } catch (_) { return false; }
    })();
    clearing.add(run);
    run.finally(() => clearing.delete(run));
    return run;
  };

  // secret — SecretBuffer; затирает его вызывающий (после того, как промис выполнится). Promise<true> — записано.
  async function copy(secret) {
    if (!clipboard || !secret || !secret.length) return false;
    const hash = digest(secret.bytes);
    if (typeof writeConcealed === "function") {
      let ok = false;
      try { ok = (await writeConcealed(secret)) === true; } catch (_) { ok = false; }
      if (!ok) return false;
    } else {
      try { await clipboard.writeText(secret.bytes.toString("utf8")); } catch (_) { return false; }
    }
    const timer = setTimer(() => { pending.delete(timer); clearIfOurs(hash); }, clearMs);
    timer?.unref?.();
    pending.set(timer, hash);
    return true;
  }

  // Выход из приложения: не оставлять секрет в буфере дольше обещанного. Promise — когда все очистки (и уже идущие по таймеру)
  // закончились: выход их дожидается (main.js, will-quit).
  async function flush() {
    for (const [timer, hash] of pending) { clearTimer(timer); clearIfOurs(hash); }
    pending.clear();
    await Promise.all([...clearing]);
  }

  return { copy, flush, get pending() { return pending.size; } };
}

module.exports = { createSecretClipboard, CLEAR_MS };
