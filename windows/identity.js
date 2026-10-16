"use strict";
// Ключ устройства Mac Utils Share (протокол mu-share-2, .audit/auth-design.md §2.3) и ID.
// Приватный ключ живёт только в главном процессе, зашифрованный через safeStorage (DPAPI): странице, которую отдаёт relay,
// он недоступен. Страница получает узкий API: подписать ровно одну из канонических строк протокола, произвольные байты — нет.
// Канонические строки и кодирование — точно как relay/src/auth.js и ShareIdentity.swift.
const crypto = require("crypto");

const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const KEY_FILE = "identity.bin";
const ID_FILE = "identity.json";

const b64u = (bytes) => Buffer.from(bytes).toString("base64url");

/** Строгий base64url: алфавит, без «=», канонический вид. null — не подходит. */
function b64uDecode(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]+$/.test(text) || text.length % 4 === 1) return null;
  const bytes = Buffer.from(text, "base64url");
  return b64u(bytes) === text ? bytes : null;
}

const isId10 = (value) => typeof value === "string" && /^\d{10}$/.test(value);
const isRoomId = (value) => typeof value === "string" && /^(\d{6}|\d{10})$/.test(value);
const isNonce = (value) => b64uDecode(value)?.length === 32;
const isRid = (value) => typeof value === "string" && /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value);

const hostMessage = (roomId, nonce) => `mu-share/v2\nhost\n${roomId}\n${nonce}`;
const viewerMessage = (roomId, viewerId, rid, nonce) => `mu-share/v2\nviewer\n${roomId}\n${viewerId}\n${rid}\n${nonce}`;
const statusMessage = (myId, ts, ids) => `mu-share/v2\nstatus\n${myId}\n${ts}\n${ids.join(",")}`;
const acceptMessage = (roomId, viewerPub, rid) => `mu-share/v2\naccept\n${roomId}\n${viewerPub}\n${rid}`;

/** Отпечаток `a1b2-c3d4-e5f6-0718`: первые 8 байт SHA-256 публичного ключа. */
function fingerprint(pubRaw) {
  const hex = crypto.createHash("sha256").update(pubRaw).digest().subarray(0, 8).toString("hex");
  return hex.match(/.{4}/g).join("-");
}

function randomId() {
  return String(crypto.randomInt(1, 10)) + Array.from({ length: 9 }, () => crypto.randomInt(0, 10)).join("");
}

/** ID: сохранённый; иначе прежний из localStorage страницы (чтобы у тех, кто уже пользуется, ID не поменялся); иначе новый. */
function chooseId({ stored, legacy, random = randomId }) {
  if (isId10(stored)) return stored;
  if (isId10(legacy)) return legacy;
  return random();
}

class IdentityUnavailable extends Error {
  constructor() { super("identity-unavailable"); }
}

class Identity {
  /**
   * @param safeStorage electron.safeStorage (или двойник в тестах)
   * @param dir папка данных приложения
   * @param fs модуль fs (или двойник)
   */
  constructor({ safeStorage, dir, fs = require("fs"), path = require("path"), random = randomId }) {
    this.safeStorage = safeStorage;
    this.fs = fs;
    this.keyPath = path.join(dir, KEY_FILE);
    this.idPath = path.join(dir, ID_FILE);
    this.random = random;
    this.dir = dir;
    this.privateKey = null;
    this.id = null;
  }

  /** Ключ можно хранить безопасно. Нет — приложение работает как mu-share-1 и ключ не создаёт. */
  get available() {
    try { return !!this.safeStorage && this.safeStorage.isEncryptionAvailable() === true; } catch (_) { return false; }
  }

  requireAvailable() {
    if (!this.available) throw new IdentityUnavailable();
  }

  // ---- ID ----

  myId(legacy) {
    this.requireAvailable();
    if (this.id) return this.id;
    let stored = null;
    try { stored = JSON.parse(this.fs.readFileSync(this.idPath, "utf8")).id; } catch (_) {}
    const id = chooseId({ stored, legacy, random: this.random });
    if (id !== stored) this.saveId(id);
    this.id = id;
    return id;
  }

  saveId(id) {
    this.fs.mkdirSync(this.dir, { recursive: true });
    this.fs.writeFileSync(this.idPath, JSON.stringify({ id }));
  }

  // ---- Ключ ----

  key() {
    this.requireAvailable();
    if (this.privateKey) return this.privateKey;
    if (this.fs.existsSync(this.keyPath)) {
      try {
        const der = Buffer.from(this.safeStorage.decryptString(this.fs.readFileSync(this.keyPath)), "base64");
        this.privateKey = crypto.createPrivateKey({ key: der, format: "der", type: "pkcs8" });
        return this.privateKey;
      } catch (_) {
        // Файл не расшифровывается (другая учётная запись, повреждён): прежний ключ потерян, создаём новый.
        // ID остаётся: если он был привязан к старому ключу, relay скажет id-claimed и приложение предложит новый ID.
      }
    }
    const { privateKey } = crypto.generateKeyPairSync("ed25519");
    this.fs.mkdirSync(this.dir, { recursive: true });
    this.fs.writeFileSync(this.keyPath, this.safeStorage.encryptString(privateKey.export({ format: "der", type: "pkcs8" }).toString("base64")));
    this.privateKey = privateKey;
    return privateKey;
  }

  publicRaw() {
    return crypto.createPublicKey(this.key()).export({ format: "der", type: "spki" }).subarray(-32);
  }

  /** `{ pub, fp }` — публичный ключ base64url (43 символа) и отпечаток. */
  identity() {
    const raw = this.publicRaw();
    return { pub: b64u(raw), fp: fingerprint(raw) };
  }

  sign(message) {
    return b64u(crypto.sign(null, Buffer.from(message, "utf8"), this.key()));
  }

  // Подписать можно только строки протокола, и только от своего имени.

  signHost(roomId, nonce) {
    if (!isId10(roomId) || roomId !== this.myId() || !isNonce(nonce)) throw new Error("bad-arguments");
    return this.sign(hostMessage(roomId, nonce));
  }

  signViewer(roomId, viewerId, rid, nonce) {
    if (!isRoomId(roomId) || viewerId !== this.myId() || !isRid(rid) || !isNonce(nonce)) throw new Error("bad-arguments");
    return this.sign(viewerMessage(roomId, viewerId, rid, nonce));
  }

  signStatus(myId, ts, idsCsv) {
    const ids = typeof idsCsv === "string" && idsCsv !== "" ? idsCsv.split(",") : [];
    if (myId !== this.myId() || !Number.isSafeInteger(ts) || typeof idsCsv !== "string" || ids.length > 20 || !ids.every(isId10)) {
      throw new Error("bad-arguments");
    }
    return this.sign(statusMessage(myId, ts, ids));
  }

  /** «Получить новый ID»: новый ключ и новый ID, старые стираются. Возвращает новый ID. */
  reset() {
    this.requireAvailable();
    for (const file of [this.keyPath, this.idPath]) {
      try { this.fs.rmSync(file, { force: true }); } catch (_) {}
    }
    this.privateKey = null;
    this.id = null;
    this.key();
    return this.myId();
  }
}

module.exports = {
  Identity, IdentityUnavailable, chooseId, randomId, fingerprint, b64u, b64uDecode,
  hostMessage, viewerMessage, statusMessage, acceptMessage,
  isId10, isRoomId, isNonce, isRid, PKCS8_ED25519_PREFIX, KEY_FILE, ID_FILE,
};
