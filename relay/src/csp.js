// Заголовки безопасности страницы трансляции (CSP с хэшами инлайн-скриптов, nosniff, Referrer-Policy).
// Без import и без обращения к окружению: файл склеивается с index.js в тестах. Хэши считаются из самой страницы при первом
// запросе, поэтому правка скрипта не ломает страницу молча: CSP всегда соответствует тому, что отдаётся.

/** Тела инлайн-скриптов (без src) в порядке появления. */
export function inlineScripts(html) {
  const bodies = [];
  const re = /<script(?![^>]*\bsrc\s*=)[^>]*>([\s\S]*?)<\/script>/gi;
  for (let m = re.exec(html); m; m = re.exec(html)) bodies.push(m[1]);
  return bodies;
}

/** 'sha256-…' для каждого инлайн-скрипта (base64 от SHA-256 UTF-8 текста между тегами — так считает браузер). */
export async function scriptHashes(html) {
  const out = [];
  for (const body of inlineScripts(html)) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body)));
    let binary = "";
    for (const byte of digest) binary += String.fromCharCode(byte);
    const hash = `'sha256-${btoa(binary)}'`;
    if (!out.includes(hash)) out.push(hash);
  }
  return out;
}

/**
 * CSP страницы. connect-src — сам хост (fetch /status, /room/…/host-check) и его WebSocket; картинки — свои, data: (схемы
 * мониторов, значки) и blob: (кадры JPEG); видео — blob:; шрифты встроены (data:); стили инлайн (атрибуты style у страницы).
 */
export function contentSecurityPolicy(hashes, url) {
  const socket = `${url.protocol === "https:" ? "wss" : "ws"}://${url.host}`;
  return [
    "default-src 'none'",
    `script-src ${hashes.length ? hashes.join(" ") : "'none'"}`,
    "style-src 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "media-src blob:",
    "font-src data:",
    `connect-src 'self' ${socket}`,
    "frame-ancestors 'none'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
  ].join("; ");
}

const hashCache = new Map();

/** Заголовки ответа со страницей `html` для запроса на `url`. */
export async function pageHeaders(html, url) {
  if (!hashCache.has(html)) hashCache.set(html, scriptHashes(html));
  const hashes = await hashCache.get(html);
  return {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "content-security-policy": contentSecurityPolicy(hashes, url),
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
  };
}
