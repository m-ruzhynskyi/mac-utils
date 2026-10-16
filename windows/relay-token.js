"use strict";
// Какой токен протокола ставить в X-MacUtils-Client. mu-share-2 — только если ключ можно хранить и relay сам объявил его в
// `GET /version` (поле protocols). Иначе mu-share-1: откат relay на версию без v2 не должен выключать клиент
// (старый relay принимает только mu-share-1 и на всё остальное отвечает 403).
const LEGACY = "mu-share-1";
const KEYED = "mu-share-2";

/** Разбор ответа /version: ключи поддерживаются, если protocols содержит mu-share-2. */
function supportsKeys(body) {
  return !!body && typeof body === "object" && Array.isArray(body.protocols) && body.protocols.includes(KEYED);
}

/**
 * Токен для запросов к relay.
 * @returns {Promise<{token: string, certain: boolean}>} certain — ответ relay получен (его можно запомнить);
 *   нет связи или странный ответ — mu-share-1, и повторим при следующей загрузке страницы.
 */
async function detectToken({ base, keysAvailable, fetch: doFetch = globalThis.fetch, timeoutMs = 6000 }) {
  if (!keysAvailable) return { token: LEGACY, certain: true };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await doFetch(new URL("version", base).toString(), { signal: controller.signal, cache: "no-store" });
    if (!response.ok) return { token: LEGACY, certain: response.status === 404 || response.status === 405 };
    let body;
    try { body = await response.json(); } catch (_) { return { token: LEGACY, certain: false }; }
    return { token: supportsKeys(body) ? KEYED : LEGACY, certain: Array.isArray(body?.protocols) };
  } catch (_) {
    return { token: LEGACY, certain: false };
  } finally {
    clearTimeout(timer);
  }
}

module.exports = { detectToken, supportsKeys, LEGACY, KEYED };
