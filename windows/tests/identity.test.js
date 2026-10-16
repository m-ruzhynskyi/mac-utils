"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const path = require("node:path");
const {
  Identity, IdentityUnavailable, chooseId, fingerprint, b64u, b64uDecode,
  hostMessage, viewerMessage, statusMessage, acceptMessage, PKCS8_ED25519_PREFIX, KEY_FILE, ID_FILE,
} = require("../identity");

// Общие векторы раздела 9 .audit/auth-design.md (те же значения в relay/tests/auth.test.cjs и ShareIdentityTests.swift).
// Ed25519 в Node детерминирован, поэтому pub, fp и sig сравниваются побайтно.
const SEED = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1));
const ROOM = "1234567890", VIEWER = "9876543210", RID = "00000000-0000-4000-8000-000000000000";
const NONCE = b64u(Buffer.alloc(32));
const PUB = "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ";
const FP = "65b6-0673-d6ed-884b";
const VECTORS = {
  host: ["mu-share/v2\nhost\n1234567890\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "x9MgCzYW402REdrI5TCh0L9nulcDS2OWlJXamB6Dlkdl96FvdoTvI5R-si1e5RCKCc6w-k1TKaAY_stmB4jUDQ"],
  viewer: [`mu-share/v2\nviewer\n1234567890\n9876543210\n${RID}\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`,
    "jkWqO6B7KzZaHhkf-WpoT8K5OF8P7SrLFq_9I-j_8eUaphvOL4NSS7Afl5rsM2aDlN8Fd8cXPjCS0a4qMqDyAA"],
  status: ["mu-share/v2\nstatus\n1234567890\n1760000000000\n9876543210,1234567890",
    "Qj7Zd93qxbtdJzIGhmEUD7ConlCIU3-IlRVCiq4yiH4y5xY7RmnEugENnktUWxzQroMDbGt7eC2ePC_rbYGFDw"],
  accept: [`mu-share/v2\naccept\n1234567890\n${PUB}\n${RID}`,
    "S2NdQNkrRNHogvIyB1I8GycN4wLgz6img5dzbGj5mtnYBRcq9moqek6TzQchQiPSpsU96p2joGBA49nBpc9YCw"],
};

// Двойники: «шифрование» safeStorage и файловая система в памяти.
function fakeSafeStorage(available = true) {
  return {
    isEncryptionAvailable: () => available,
    encryptString: (text) => Buffer.from(`enc:${text}`),
    decryptString: (buffer) => {
      const text = buffer.toString();
      if (!text.startsWith("enc:")) throw new Error("cannot decrypt");
      return text.slice(4);
    },
  };
}

function fakeFs() {
  const files = new Map();
  return {
    files,
    existsSync: (file) => files.has(file),
    readFileSync: (file, encoding) => {
      if (!files.has(file)) throw new Error("ENOENT");
      const data = files.get(file);
      return encoding ? Buffer.from(data).toString(encoding) : Buffer.from(data);
    },
    writeFileSync: (file, data) => { files.set(file, Buffer.from(data)); },
    mkdirSync: () => {},
    rmSync: (file) => { files.delete(file); },
  };
}

const DIR = path.join("C:", "data");
const keyPath = path.join(DIR, KEY_FILE), idPath = path.join(DIR, ID_FILE);

function identityWithSeed({ id = ROOM, available = true } = {}) {
  const fs = fakeFs();
  const storage = fakeSafeStorage(available);
  fs.writeFileSync(keyPath, storage.encryptString(Buffer.concat([PKCS8_ED25519_PREFIX, SEED]).toString("base64")));
  if (id) fs.writeFileSync(idPath, JSON.stringify({ id }));
  return { identity: new Identity({ safeStorage: storage, dir: DIR, fs }), fs, storage };
}

test("вектор: публичный ключ и отпечаток", () => {
  const { identity } = identityWithSeed();
  assert.deepEqual(identity.identity(), { pub: PUB, fp: FP });
  assert.equal(identity.identity().pub.length, 43);
  assert.equal(fingerprint(b64uDecode(PUB)), FP);
});

test("вектор: канонические строки", () => {
  assert.equal(hostMessage(ROOM, NONCE), VECTORS.host[0]);
  assert.equal(viewerMessage(ROOM, VIEWER, RID, NONCE), VECTORS.viewer[0]);
  assert.equal(statusMessage(ROOM, 1760000000000, [VIEWER, ROOM]), VECTORS.status[0]);
  assert.equal(acceptMessage(ROOM, PUB, RID), VECTORS.accept[0]);
});

test("вектор: подписи совпадают побайтно (host, viewer, status) и проходят проверку по pub", () => {
  // Свой ID в обоих ролях: хост ROOM, зритель VIEWER — подставляем нужный ID через хранилище.
  const host = identityWithSeed({ id: ROOM }).identity;
  assert.equal(host.signHost(ROOM, NONCE), VECTORS.host[1]);
  assert.equal(host.signStatus(ROOM, 1760000000000, `${VIEWER},${ROOM}`), VECTORS.status[1]);
  const viewer = identityWithSeed({ id: VIEWER }).identity;
  assert.equal(viewer.signViewer(ROOM, VIEWER, RID, NONCE), VECTORS.viewer[1]);

  const publicKey = crypto.createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), b64uDecode(PUB)]), format: "der", type: "spki" });
  for (const [name, [message, sig]] of Object.entries(VECTORS)) {
    assert.equal(crypto.verify(null, Buffer.from(message), publicKey, b64uDecode(sig)), true, name);
  }
});

test("подпись принятия (accept) на векторе проверяется тем же ключом", () => {
  const { identity } = identityWithSeed();
  const sig = identity.sign(acceptMessage(ROOM, PUB, RID));
  assert.equal(sig, VECTORS.accept[1]);
});

test("страница может подписать только свои строки: чужой roomId, viewerId, status и мусор отвергаются", () => {
  const { identity } = identityWithSeed({ id: ROOM });
  assert.throws(() => identity.signHost("1111111111", NONCE), /bad-arguments/, "чужая комната");
  assert.throws(() => identity.signHost("123456", NONCE), /bad-arguments/, "6-значный ID хостом не подписывается");
  assert.throws(() => identity.signHost(ROOM, "короткий"), /bad-arguments/);
  assert.throws(() => identity.signHost(ROOM, NONCE.slice(0, 42)), /bad-arguments/);
  assert.throws(() => identity.signHost(ROOM, `${NONCE}=`), /bad-arguments/);
  assert.throws(() => identity.signViewer(ROOM, VIEWER, RID, NONCE), /bad-arguments/, "зритель подписывает только свой ID");
  assert.throws(() => identity.signViewer("12", ROOM, RID, NONCE), /bad-arguments/, "некорректная комната");
  assert.throws(() => identity.signViewer(ROOM, ROOM, "не-uuid", NONCE), /bad-arguments/);
  assert.throws(() => identity.signStatus(VIEWER, 1, ""), /bad-arguments/, "чужой myId");
  assert.throws(() => identity.signStatus(ROOM, 1.5, ""), /bad-arguments/);
  assert.throws(() => identity.signStatus(ROOM, "1", ""), /bad-arguments/);
  assert.throws(() => identity.signStatus(ROOM, 1, "123"), /bad-arguments/);
  assert.throws(() => identity.signStatus(ROOM, 1, Array.from({ length: 21 }, () => VIEWER).join(",")), /bad-arguments/, "не больше 20 ID");
  assert.throws(() => identity.signStatus(ROOM, 1, 5), /bad-arguments/);
  // Допустимые крайние случаи.
  assert.equal(typeof identity.signViewer("123456", ROOM, RID, NONCE), "string", "смотреть можно и 6-значный ID");
  assert.equal(typeof identity.signStatus(ROOM, 1, ""), "string", "пустой список ID");
  assert.equal(typeof identity.signStatus(ROOM, 1, Array.from({ length: 20 }, () => VIEWER).join(",")), "string");
});

test("safeStorage недоступен: ключ не создаётся, всё бросает identity-unavailable", () => {
  const fs = fakeFs();
  const identity = new Identity({ safeStorage: fakeSafeStorage(false), dir: DIR, fs });
  assert.equal(identity.available, false);
  for (const call of [() => identity.identity(), () => identity.myId(null), () => identity.signHost(ROOM, NONCE), () => identity.reset()]) {
    assert.throws(call, IdentityUnavailable);
  }
  assert.equal(fs.files.size, 0, "ни ключа, ни ID на диск не писалось");
  assert.equal(new Identity({ safeStorage: undefined, dir: DIR, fs }).available, false);
  const broken = { isEncryptionAvailable() { throw new Error("boom"); } };
  assert.equal(new Identity({ safeStorage: broken, dir: DIR, fs }).available, false);
});

test("первый запуск: ключ создаётся, шифруется и переживает перезапуск", () => {
  const fs = fakeFs();
  const storage = fakeSafeStorage();
  const first = new Identity({ safeStorage: storage, dir: DIR, fs });
  const created = first.identity();
  assert.match(created.pub, /^[A-Za-z0-9_-]{43}$/);
  assert.match(created.fp, /^[0-9a-f]{4}(-[0-9a-f]{4}){3}$/);
  const stored = fs.files.get(keyPath);
  assert.ok(stored.toString().startsWith("enc:"), "на диске только зашифрованное");
  // Внутри «шифра» — PKCS8 DER Ed25519 (16 байт заголовка и 32 байта seed), а не публичный ключ и не строка протокола.
  const der = Buffer.from(storage.decryptString(stored), "base64");
  assert.equal(der.length, 48);
  assert.deepEqual(der.subarray(0, 16), PKCS8_ED25519_PREFIX);
  const second = new Identity({ safeStorage: storage, dir: DIR, fs });
  assert.deepEqual(second.identity(), created);
});

test("файл ключа нельзя расшифровать: создаётся новый ключ, ID остаётся", () => {
  const { identity, fs } = identityWithSeed({ id: ROOM });
  fs.writeFileSync(keyPath, Buffer.from("мусор"));
  const fresh = identity.identity();
  assert.notEqual(fresh.pub, PUB);
  assert.equal(identity.myId(null), ROOM);
  assert.ok(fs.files.get(keyPath).toString().startsWith("enc:"), "новый ключ записан");
});

test("ID: сохранённый важнее прежнего из localStorage, прежний важнее нового, мусор отвергается", () => {
  assert.equal(chooseId({ stored: "1111111111", legacy: "2222222222" }), "1111111111");
  assert.equal(chooseId({ stored: null, legacy: "2222222222" }), "2222222222", "ID существующего пользователя не меняется");
  assert.equal(chooseId({ stored: null, legacy: "12345" , random: () => "3333333333" }), "3333333333");
  assert.equal(chooseId({ stored: "abc", legacy: "١٢٣٤٥٦٧٨٩٠", random: () => "4444444444" }), "4444444444");
  assert.match(chooseId({ stored: null, legacy: null }), /^[1-9]\d{9}$/);
});

test("myId переносит прежний ID один раз и дальше возвращает сохранённый", () => {
  const fs = fakeFs();
  const identity = new Identity({ safeStorage: fakeSafeStorage(), dir: DIR, fs });
  assert.equal(identity.myId("5550001112"), "5550001112");
  assert.deepEqual(JSON.parse(fs.files.get(idPath).toString()), { id: "5550001112" });
  const again = new Identity({ safeStorage: fakeSafeStorage(), dir: DIR, fs });
  assert.equal(again.myId("9990001112"), "5550001112");
});

test("reset: новый ключ и новый ID, старые стёрты", () => {
  const { identity } = identityWithSeed({ id: ROOM });
  assert.equal(identity.identity().pub, PUB);
  const next = identity.reset();
  assert.match(next, /^[1-9]\d{9}$/);
  assert.notEqual(identity.identity().pub, PUB);
  assert.equal(identity.myId(null), next);
  assert.notEqual(identity.myId(null), ROOM, "ID сменился");
});

test("base64url: строгий разбор и круг", () => {
  assert.deepEqual([...b64uDecode("-__-ABA")], [0xfb, 0xff, 0xfe, 0x00, 0x10]);
  assert.equal(b64u(b64uDecode(PUB)), PUB);
  for (const bad of ["ab+/", "ab==", "a", "ab cd", "", "AB", 5, null]) assert.equal(b64uDecode(bad), null, String(bad));
});
