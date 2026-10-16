// Аутентификация share v2 (Ed25519): base64url, канонические строки, проверка подписи, отпечаток.
// См. .audit/auth-design.md, разделы 2 и 9. Без import: файл склеивается с index.js и limits.js в тестах.
// Строки подписи и кодирование должны совпадать с ShareIdentity.swift байт в байт.

const B64U_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

export function b64uEncode(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0);
    out += B64U_ALPHABET[(n >> 18) & 63] + B64U_ALPHABET[(n >> 12) & 63];
    if (i + 1 < bytes.length) out += B64U_ALPHABET[(n >> 6) & 63];
    if (i + 2 < bytes.length) out += B64U_ALPHABET[n & 63];
  }
  return out;
}

/** Строго: только алфавит base64url, без `=`, пробелов и неканонических хвостовых битов. null — если не подходит. */
export function b64uDecode(text) {
  if (typeof text !== "string" || text.length === 0 || text.length % 4 === 1) return null;
  const values = [];
  for (let i = 0; i < text.length; i++) {
    const v = B64U_ALPHABET.indexOf(text[i]);
    if (v < 0) return null;
    values.push(v);
  }
  const bytes = new Uint8Array(Math.floor((text.length * 6) / 8));
  let acc = 0, bits = 0, at = 0;
  for (const v of values) {
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes[at++] = (acc >> bits) & 255;
      acc &= (1 << bits) - 1;
    }
  }
  if (acc !== 0) return null;
  return bytes;
}

/** base64url строки с ровно n байтами данных (32 для ключа и nonce, 64 для подписи). */
export function b64uHasLength(text, n) {
  const bytes = b64uDecode(text);
  return bytes !== null && bytes.length === n;
}

export function hostMessage(roomId, nonce) {
  return `mu-share/v2\nhost\n${roomId}\n${nonce}`;
}

export function viewerMessage(roomId, viewerId, rid, nonce) {
  return `mu-share/v2\nviewer\n${roomId}\n${viewerId}\n${rid}\n${nonce}`;
}

export function statusMessage(myId, ts, ids) {
  return `mu-share/v2\nstatus\n${myId}\n${ts}\n${ids.join(",")}`;
}

export function acceptMessage(roomId, viewerPub, rid) {
  return `mu-share/v2\naccept\n${roomId}\n${viewerPub}\n${rid}`;
}

/** Проверка подписи Ed25519; любые ошибки (кривой ключ, длина) — false, исключений наружу нет. */
export async function verifyEd25519(pub, sig, message) {
  try {
    const pubBytes = b64uDecode(pub), sigBytes = b64uDecode(sig);
    if (!pubBytes || pubBytes.length !== 32 || !sigBytes || sigBytes.length !== 64) return false;
    const key = await crypto.subtle.importKey("raw", pubBytes, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, sigBytes, new TextEncoder().encode(message));
  } catch (_) {
    return false;
  }
}

/** Отпечаток `a1b2-c3d4-e5f6-0718`: первые 8 байт SHA-256 публичного ключа. null, если это не ключ. */
export async function fingerprintOf(pub) {
  const bytes = b64uDecode(pub);
  if (!bytes || bytes.length !== 32) return null;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  let hex = "";
  for (let i = 0; i < 8; i++) hex += digest[i].toString(16).padStart(2, "0");
  return `${hex.slice(0, 4)}-${hex.slice(4, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}`;
}

/** Случайный nonce: 32 байта, base64url (43 символа). */
export function newNonce() {
  return b64uEncode(crypto.getRandomValues(new Uint8Array(32)));
}
