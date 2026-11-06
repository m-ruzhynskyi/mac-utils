// Ключ страницы relay (P-256) в строгом режиме: relay принимает только клиентов с ключом, поэтому страница обязана его иметь.
// Из index.html берётся блок «Свой ключ страницы»; хранилище IndexedDB подменено моделью.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const nodeCrypto = require('node:crypto');

const html = fs.readFileSync(`${__dirname}/../src/index.html`, 'utf8');
const from = html.indexOf('const PAGE_KEY_DB');
const to = html.indexOf('async function sendPageAuth');
assert.ok(from > 0 && to > from, 'блок ключа страницы на месте');
const block = html.slice(from, to);

// Минимальная модель IndexedDB: один объектный склад; shared — «диск», переживающий перезагрузку страницы.
function fakeIndexedDB(shared, { failOpen = false } = {}) {
  return {
    open() {
      const request = {};
      setTimeout(() => {
        if (failOpen) return request.onerror && request.onerror();
        const db = {
          transaction() {
            const tx = {};
            tx.objectStore = () => ({
              get: (name) => { const r = {}; setTimeout(() => { r.result = shared.get(name); r.onsuccess(); }); return r; },
              put: (value, name) => { shared.set(name, value); setTimeout(() => tx.oncomplete && tx.oncomplete()); return {}; },
            });
            return tx;
          },
          createObjectStore() {}, close() {},
        };
        request.result = db;
        request.onsuccess();
      });
      if (failOpen) request.error = new Error('SecurityError');
      return request;
    },
  };
}

async function loadPage({ indexedDB, shared = new Map() }) {
  const calls = { status: [], ids: [] };
  const window = { isSecureContext: true, crypto: nodeCrypto.webcrypto, indexedDB, mu: undefined };
  const context = vm.createContext({
    window, indexedDB, CryptoKey: globalThis.CryptoKey, TextEncoder, Uint8Array, atob, btoa, setTimeout, clearTimeout,
    appSigns: () => false, status: (text) => calls.status.push(text), generateId: () => '9999999999',
    display: (id) => id, idFromApp: false, $: () => ({ set textContent(v) { calls.ids.push(v); } }),
  });
  vm.runInContext(`let myId = '1111111111'; function b64u(bytes){let t='';for(const b of new Uint8Array(bytes))t+=String.fromCharCode(b);return btoa(t).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');}\n${block}\nlet pageKey = null;\n${html.slice(html.indexOf('async function useSessionKey'), html.indexOf('let pageKeyReady = loadPageKey();'))}\nthis.ready = loadPageKey();`, context);
  await context.ready;
  return { get pageKey() { return vm.runInContext('pageKey', context); }, get myId() { return vm.runInContext('myId', context); }, calls };
}

const verifies = (pub, text, sig) => {
  const raw = Buffer.from(pub, 'base64url');
  const key = nodeCrypto.createPublicKey({ key: { kty: 'EC', crv: 'P-256', x: raw.subarray(1, 33).toString('base64url'), y: raw.subarray(33).toString('base64url') }, format: 'jwk' });
  return nodeCrypto.verify('sha256', Buffer.from(text), { key, dsaEncoding: 'ieee-p1363' }, Buffer.from(sig, 'base64url'));
};

test('хранилище пустое — страница создаёт новый ключ и сохраняет его; после перезагрузки ключ тот же', async () => {
  const disk = new Map();
  const first = await loadPage({ indexedDB: fakeIndexedDB(disk), shared: disk });
  assert.ok(first.pageKey, 'ключ создан');
  assert.equal(first.pageKey.session, undefined, 'не сессионный');
  assert.equal(first.pageKey.pub.length, 87);
  assert.ok(disk.has('p256'), 'сохранён');
  assert.ok(verifies(first.pageKey.pub, 'hello', await first.pageKey.sign('hello')));
  const second = await loadPage({ indexedDB: fakeIndexedDB(disk), shared: disk });
  assert.equal(second.pageKey.pub, first.pageKey.pub);
  assert.equal(first.myId, '1111111111', 'ID не менялся');
});

test('хранилище недоступно (приватное окно) — ключ на время страницы, ID на сессию, пользователь предупреждён', async () => {
  const page = await loadPage({ indexedDB: fakeIndexedDB(new Map(), { failOpen: true }) });
  assert.ok(page.pageKey, 'ключа нет — значит, страница ушла бы без ключа, а relay такого клиента не пускает');
  assert.equal(page.pageKey.session, true);
  assert.equal(page.pageKey.pub.length, 87);
  assert.ok(verifies(page.pageKey.pub, 'hello', await page.pageKey.sign('hello')));
  assert.equal(page.myId, '9999999999', 'старый ID был бы чужим для нового ключа');
  assert.equal(page.calls.status.length, 1);
});
