// Секрет (пароль учётки, «Доступ», пароль или ключ VPN) в буфер обмена: через 30 с буфер очищается, если в нём всё ещё он. Сам
// секрет после записи не хранится — только его SHA-256, чтобы узнать «всё ещё он» и не стереть то, что пользователь скопировал после.
// На Windows секрет пишется помощником writeConcealed (concealed.js): вместе с текстом — форматы, по которым журнал буфера (Win+V)
// и облачная синхронизация его не сохраняют (W2-5). Помощник не справился — секрет НЕ кладётся обычным текстом.
"use strict";

const crypto = require("node:crypto");

const CLEAR_MS = 30_000;
const digest = (bytes) => crypto.createHash("sha256").update(bytes).digest();

// clipboard: { writeText(text), readText() → string, clear() } (Electron clipboard или двойник в тестах); writeConcealed(secret) →
// Promise<boolean> — запись мимо журнала буфера (на Windows обязательна; без неё, не на Windows, — обычный writeText).
function createSecretClipboard({ clipboard, writeConcealed = null, setTimer = setTimeout, clearTimer = clearTimeout, clearMs = CLEAR_MS } = {}) {
  const pending = new Map();   // таймер → хеш

  const stillOurs = (hash) => {
    let now;
    try { now = clipboard.readText(); } catch (_) { return false; }
    if (typeof now !== "string" || !now) return false;
    const bytes = Buffer.from(now, "utf8");
    try { return crypto.timingSafeEqual(digest(bytes), hash); } finally { bytes.fill(0); }
  };
  const clearIfOurs = (hash) => { if (stillOurs(hash)) { try { clipboard.clear(); } catch (_) {} } };

  // secret — SecretBuffer; затирает его вызывающий (после того, как промис выполнится). Promise<true> — записано.
  async function copy(secret) {
    if (!clipboard || !secret || !secret.length) return false;
    const hash = digest(secret.bytes);
    if (typeof writeConcealed === "function") {
      let ok = false;
      try { ok = (await writeConcealed(secret)) === true; } catch (_) { ok = false; }
      if (!ok) return false;
    } else {
      try { clipboard.writeText(secret.bytes.toString("utf8")); } catch (_) { return false; }
    }
    const timer = setTimer(() => { pending.delete(timer); clearIfOurs(hash); }, clearMs);
    timer?.unref?.();
    pending.set(timer, hash);
    return true;
  }

  // Выход из приложения: не оставлять секрет в буфере дольше обещанного.
  function flush() {
    for (const [timer, hash] of pending) { clearTimer(timer); clearIfOurs(hash); }
    pending.clear();
  }

  return { copy, flush, get pending() { return pending.size; } };
}

module.exports = { createSecretClipboard, CLEAR_MS };
