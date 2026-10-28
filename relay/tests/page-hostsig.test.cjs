// Подпись принятия ведущего на странице (SHARE-PROTOCOL §3): строка как у Mac, проверка P-256 и Ed25519, решение зрителя.
// Код — между метками <host-sig> в index.html.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');

const html = fs.readFileSync(`${__dirname}/../src/index.html`, 'utf8');
const block = html.slice(html.indexOf('// <host-sig>'), html.indexOf('// </host-sig>'));
assert.ok(block.length > 800, 'метки <host-sig> на месте');
const page = vm.createContext({ atob, TextEncoder, Uint8Array, Promise, String, Math });
vm.runInContext(`${block}\nObject.assign(this, { acceptMessage, verifyHostSig, hostSigDecision, b64uBytes });`, page);

const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
const ROOM = '1234567890', VIEWER_PUB = 'B' + 'v'.repeat(86), RID = '11111111-2222-3333-4444-555555555555';

test('строка подписи — как у Mac (ShareIdentity.acceptMessage)', () => {
  assert.equal(page.acceptMessage(ROOM, VIEWER_PUB, RID), `mu-share/v2\naccept\n${ROOM}\n${VIEWER_PUB}\n${RID}`);
});

test('P-256: подпись страницы-ведущего проходит; чужой ключ, чужая строка, мусор — нет', async () => {
  const pair = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pub = b64u(await webcrypto.subtle.exportKey('raw', pair.publicKey));
  const message = page.acceptMessage(ROOM, VIEWER_PUB, RID);
  const sig = b64u(await webcrypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, new TextEncoder().encode(message)));
  assert.equal(await page.verifyHostSig(webcrypto.subtle, pub, sig, message), 'ok');
  assert.equal(await page.verifyHostSig(webcrypto.subtle, pub, sig, page.acceptMessage(ROOM, VIEWER_PUB, 'другой-rid')), 'bad');
  const other = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  assert.equal(await page.verifyHostSig(webcrypto.subtle, b64u(await webcrypto.subtle.exportKey('raw', other.publicKey)), sig, message), 'bad');
  assert.equal(await page.verifyHostSig(webcrypto.subtle, pub, 'AAAA', message), 'bad');
  assert.equal(await page.verifyHostSig(webcrypto.subtle, 'не ключ', sig, message), 'bad');
});

test('Ed25519 (ведущий Mac): проверяется, если браузер умеет; иначе «unsupported», а не отказ', async () => {
  const pair = await webcrypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
  const pub = b64u(await webcrypto.subtle.exportKey('raw', pair.publicKey));
  const message = page.acceptMessage(ROOM, VIEWER_PUB, RID);
  const sig = b64u(await webcrypto.subtle.sign({ name: 'Ed25519' }, pair.privateKey, new TextEncoder().encode(message)));
  assert.equal(await page.verifyHostSig(webcrypto.subtle, pub, sig, message), 'ok');
  assert.equal(await page.verifyHostSig(webcrypto.subtle, pub, sig, message + 'x'), 'bad');
  const noEd = { importKey: async (_f, _k, alg) => { if (alg.name === 'Ed25519') throw new Error('NotSupportedError'); return webcrypto.subtle.importKey(_f, _k, alg, false, ['verify']); }, verify: webcrypto.subtle.verify.bind(webcrypto.subtle) };
  assert.equal(await page.verifyHostSig(noEd, pub, sig, message), 'unsupported');
});

test('решение зрителя: подпись сошлась — запомнить; не сошлась — отказ; нет подписи — отказ только у ведущего, что уже подписывал', () => {
  assert.equal(page.hostSigDecision('ok', false), 'accept-signed');
  assert.equal(page.hostSigDecision('bad', false), 'reject-bad');
  assert.equal(page.hostSigDecision('bad', true), 'reject-bad');
  assert.equal(page.hostSigDecision('none', false), 'accept', 'старый ведущий без подписи — как раньше');
  assert.equal(page.hostSigDecision('none', true), 'reject-downgrade', 'откат защиты');
  assert.equal(page.hostSigDecision('unsupported', true), 'accept', 'проверить нечем — не ломаем');
});
