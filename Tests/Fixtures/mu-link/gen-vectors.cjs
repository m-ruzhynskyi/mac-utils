// Генератор общих векторов MU Link: node Tests/Fixtures/mu-link/gen-vectors.cjs > Tests/Fixtures/mu-link/vectors.json. Ключи — только для тестов.
const crypto = require("crypto");
const b64u = (b) => Buffer.from(b).toString("base64url");
const seed = (label) => crypto.createHash("sha256").update(label).digest();
const PKCS8 = Buffer.from("302e020100300506032b657004220420", "hex");
function keyPair(s) {
  const priv = crypto.createPrivateKey({ key: Buffer.concat([PKCS8, s]), format: "der", type: "pkcs8" });
  const pub = crypto.createPublicKey(priv).export({ format: "jwk" }).x;
  return { priv, pub };
}
const mac = keyPair(seed("mu-link test mac")), pc = keyPair(seed("mu-link test pc"));
const clientNonce = b64u(seed("mu-link test client nonce")), serverNonce = b64u(seed("mu-link test server nonce"));
const code = "042917";
const fields = `${mac.pub}\n${pc.pub}\n${clientNonce}\n${serverNonce}`;
const msg = (kind) => `mu-link/1\n${kind}\n${fields}`;
const sign = (k, m) => b64u(crypto.sign(null, Buffer.from(m), k.priv));
const hmac = (m) => b64u(crypto.createHmac("sha256", Buffer.from(code)).update(m).digest());
const out = {
  comment: "MU Link v1: общие тестовые векторы Mac и Windows. Ключи только для тестов. Описание — docs/mu-link-protocol.md.",
  macSeed: b64u(seed("mu-link test mac")), macPub: mac.pub,
  pcSeed: b64u(seed("mu-link test pc")), pcPub: pc.pub,
  clientNonce, serverNonce, code,
  serverMessage: msg("server"), clientMessage: msg("client"),
  serverSig: sign(pc, msg("server")), clientSig: sign(mac, msg("client")),
  pairMacMessage: msg("pair-mac"), pairPcMessage: msg("pair-pc"),
  pairMacProof: hmac(msg("pair-mac")), pairPcProof: hmac(msg("pair-pc")),
  frames: {
    helloMac: { v: 1, type: "hello", id: "h1", role: "mac", app: "Mac Utils", version: "1.0.0", name: "MacBook Air", caps: [], pub: mac.pub, nonce: clientNonce },
    helloPc: { v: 1, type: "hello", id: "h2", role: "pc", app: "Mac Utils Share", version: "1.3.0", name: "DESKTOP-KYIV", caps: [], pub: pc.pub, nonce: serverNonce, paired: false, sig: sign(pc, msg("server")) },
    pair: { v: 1, type: "pair", id: "p1", proof: hmac(msg("pair-mac")), sig: sign(mac, msg("client")) },
    paired: { v: 1, type: "paired", id: "p2", proof: hmac(msg("pair-pc")) },
    auth: { v: 1, type: "auth", id: "a1", sig: sign(mac, msg("client")) },
    ready: { v: 1, type: "ready", id: "r1" },
    ping: { v: 1, type: "ping", id: "k7", t: 1763900000000 },
    pong: { v: 1, type: "pong", id: "k7", t: 1763900000000 },
    status: { v: 1, type: "status", id: "s1", name: "DESKTOP-KYIV", os: "Windows 10.0.26100", uptime: 11520, app: "Mac Utils Share", version: "1.3.0",
      power: { source: "unknown", percent: null, minutesLeft: null } },
    error: { v: 1, type: "error", id: "e1", code: "bad-code", message: "Неверный код", attemptsLeft: 3 },
    future: { v: 2, type: "clipboard", id: "f1", items: [{ kind: "text", text: "привет" }], extra: { nested: true } },
  },
};
process.stdout.write(JSON.stringify(out, null, 2) + "\n");
