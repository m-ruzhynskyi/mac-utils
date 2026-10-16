const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const nodeCrypto = require('node:crypto');

const source = fs.readFileSync(`${__dirname}/../src/auth.js`, 'utf8').replace(/^export /gm, '');
assert.doesNotMatch(fs.readFileSync(`${__dirname}/../src/auth.js`, 'utf8'), /^import /m, 'auth.js не должен ничего импортировать');
const names = ['b64uEncode', 'b64uDecode', 'b64uHasLength', 'hostMessage', 'viewerMessage', 'statusMessage', 'acceptMessage',
  'verifyEd25519', 'fingerprintOf', 'newNonce'];
const A = vm.runInNewContext(`${source}\n({ ${names.join(', ')} })`, { crypto: globalThis.crypto, TextEncoder, Uint8Array });

// Общие векторы раздела 9 .audit/auth-design.md (те же значения в ShareIdentityTests.swift).
const seed = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1));
const priv = nodeCrypto.createPrivateKey({
  key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
const pubBytes = nodeCrypto.createPublicKey(priv).export({ format: 'der', type: 'spki' }).subarray(-32);
const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
const sign = (message) => b64u(nodeCrypto.sign(null, Buffer.from(message), priv));
const ROOM = '1234567890', VIEWER = '9876543210', RID = '00000000-0000-4000-8000-000000000000';
const NONCE = b64u(Buffer.alloc(32));
const PUB = 'ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ';
const VECTORS = {
  host: ['mu-share/v2\nhost\n1234567890\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'x9MgCzYW402REdrI5TCh0L9nulcDS2OWlJXamB6Dlkdl96FvdoTvI5R-si1e5RCKCc6w-k1TKaAY_stmB4jUDQ'],
  viewer: [`mu-share/v2\nviewer\n1234567890\n9876543210\n${RID}\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`,
    'jkWqO6B7KzZaHhkf-WpoT8K5OF8P7SrLFq_9I-j_8eUaphvOL4NSS7Afl5rsM2aDlN8Fd8cXPjCS0a4qMqDyAA'],
  status: ['mu-share/v2\nstatus\n1234567890\n1760000000000\n9876543210,1234567890',
    'Qj7Zd93qxbtdJzIGhmEUD7ConlCIU3-IlRVCiq4yiH4y5xY7RmnEugENnktUWxzQroMDbGt7eC2ePC_rbYGFDw'],
  accept: [`mu-share/v2\naccept\n1234567890\n${PUB}\n${RID}`,
    'S2NdQNkrRNHogvIyB1I8GycN4wLgz6img5dzbGj5mtnYBRcq9moqek6TzQchQiPSpsU96p2joGBA49nBpc9YCw'],
};

test('вектор: публичный ключ и отпечаток', async () => {
  assert.equal(b64u(pubBytes), PUB);
  assert.equal(A.b64uEncode(pubBytes), PUB);
  assert.equal(await A.fingerprintOf(PUB), '65b6-0673-d6ed-884b');
  assert.equal(await A.fingerprintOf('abc'), null);
  assert.equal(await A.fingerprintOf(''), null);
});

test('вектор: канонические строки', () => {
  assert.equal(A.hostMessage(ROOM, NONCE), VECTORS.host[0]);
  assert.equal(A.viewerMessage(ROOM, VIEWER, RID, NONCE), VECTORS.viewer[0]);
  assert.equal(A.statusMessage(ROOM, 1760000000000, [VIEWER, ROOM]), VECTORS.status[0]);
  assert.equal(A.acceptMessage(ROOM, PUB, RID), VECTORS.accept[0]);
});

test('вектор: подписи совпадают побайтно (Ed25519 детерминирован) и проходят проверку', async () => {
  for (const [name, [message, expected]] of Object.entries(VECTORS)) {
    assert.equal(sign(message), expected, name);
    assert.equal(await A.verifyEd25519(PUB, expected, message), true, name);
  }
});

test('verifyEd25519: другая комната, роль, ключ, испорченная подпись и кривые данные', async () => {
  const [message, sig] = VECTORS.host;
  assert.equal(await A.verifyEd25519(PUB, sig, A.hostMessage('1234567891', NONCE)), false);
  assert.equal(await A.verifyEd25519(PUB, sig, VECTORS.viewer[0]), false);
  const flipped = sig.slice(0, 10) + (sig[10] === 'A' ? 'B' : 'A') + sig.slice(11);
  assert.equal(await A.verifyEd25519(PUB, flipped, message), false);
  const other = b64u(nodeCrypto.createPublicKey(nodeCrypto.generateKeyPairSync('ed25519').privateKey)
    .export({ format: 'der', type: 'spki' }).subarray(-32));
  assert.equal(await A.verifyEd25519(other, sig, message), false);
  for (const bad of ['', 'abc', sig + '=', sig.slice(0, 85), null, undefined, 42]) {
    assert.equal(await A.verifyEd25519(PUB, bad, message), false, String(bad));
    assert.equal(await A.verifyEd25519(bad, sig, message), false, String(bad));
  }
});

test('base64url: круг, строгость, длины', () => {
  const bytes = Uint8Array.from([0xfb, 0xff, 0xfe, 0x00, 0x10]);
  assert.equal(A.b64uEncode(bytes), '-__-ABA');
  assert.deepEqual(Array.from(A.b64uDecode('-__-ABA')), Array.from(bytes));
  for (const n of [0, 1, 2, 3, 31, 32, 33, 64]) {
    const data = nodeCrypto.randomBytes(n);
    assert.equal(A.b64uEncode(data), data.toString('base64url'));
    if (n) assert.deepEqual(Buffer.from(A.b64uDecode(data.toString('base64url'))), data);
  }
  for (const bad of ['ab+/', 'ab==', 'a', 'ab cd', '', 'ab\n', 'AB']) assert.equal(A.b64uDecode(bad), null, JSON.stringify(bad));
  assert.equal(A.b64uHasLength(PUB, 32), true);
  assert.equal(A.b64uHasLength(PUB, 31), false);
  assert.equal(A.b64uHasLength(VECTORS.host[1], 64), true);
  assert.equal(A.b64uHasLength(5, 32), false);
});

test('newNonce: 32 случайных байта, 43 символа base64url', () => {
  const a = A.newNonce(), b = A.newNonce();
  assert.equal(a.length, 43);
  assert.match(a, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(a, b);
  assert.equal(A.b64uHasLength(a, 32), true);
});
