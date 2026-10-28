// Безопасность страницы и зависимостей relay (аудит 28.10): CSP с хэшами инлайн-скриптов (L4), страница-ведущий без ключа
// всегда спрашивает (M3), wrangler и undici (L19).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const vm = require('node:vm');

const src = (name) => fs.readFileSync(`${__dirname}/../src/${name}`, 'utf8');
const html = src('index.html'), landing = src('landing.html');

const source = ['limits.js', 'auth.js', 'csp.js', 'index.js'].map(src).join('\n')
  .replace(/^import .*;$/gm, '')
  .replace('export default', 'const worker =')
  .replace('export class Room', 'class Room')
  .replace(/^export (async function|function|const)/gm, '$1');
const context = vm.createContext({ Response, Request, Headers, URL, crypto: globalThis.crypto, TextEncoder, btoa, page: html, landing,
  WebSocketPair: class {}, Date, console });
vm.runInContext(`${source}\nthis.worker = worker; this.csp = { inlineScripts, scriptHashes, contentSecurityPolicy };`, context);
const { worker, csp } = context;

const sha = (text) => `'sha256-${crypto.createHash('sha256').update(text, 'utf8').digest('base64')}'`;
const bodies = [...html.matchAll(/<script(?![^>]*\bsrc\s*=)[^>]*>([\s\S]*?)<\/script>/gi)].map((m) => m[1]);

async function getPage(host = 'https://relay.example/', headers = { 'x-macutils-client': 'mu-share-1' }) {
  return worker.fetch(new Request(host, { headers }), {});
}

test('L4: страница отдаётся с CSP, в script-src — хэш каждого инлайн-скрипта (и только они)', async () => {
  assert.ok(bodies.length >= 2, 'в странице есть инлайн-скрипты');
  const response = await getPage();
  assert.equal(response.status, 200);
  const policy = response.headers.get('content-security-policy');
  const scriptSrc = policy.split('; ').find((d) => d.startsWith('script-src ')).slice('script-src '.length).split(' ');
  assert.deepEqual(scriptSrc.sort(), [...new Set(bodies.map(sha))].sort(), 'хэш в CSP = хэш скрипта');
  assert.ok(!/unsafe-inline|unsafe-eval|\*/.test(policy.split('; ').find((d) => d.startsWith('script-src '))), 'скрипты только по хэшу');
});

test('L4: остальные директивы и заголовки', async () => {
  for (const [url, headers] of [['https://relay.example/', { 'x-macutils-client': 'mu-share-1' }], ['https://relay.example/', {}], ['https://relay.example/', { 'x-macutils-client': 'mu-share-2' }]]) {
    const response = await getPage(url, headers);
    const policy = response.headers.get('content-security-policy');
    for (const part of ["default-src 'none'", "frame-ancestors 'none'", "object-src 'none'", "base-uri 'none'", "media-src blob:",
      "img-src 'self' data: blob:", "connect-src 'self' wss://relay.example", "font-src data:"]) assert.ok(policy.includes(part), `${part} в ${policy}`);
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
    assert.equal(response.headers.get('cache-control'), 'no-store');
  }
  // Без приложения — страница-заглушка: скриптов нет, значит script-src 'none'.
  const stub = await getPage('https://relay.example/', {});
  assert.equal(await stub.text(), landing);
  assert.match(stub.headers.get('content-security-policy'), /script-src 'none'/);
  // Локальная разработка по http — ws, не wss.
  assert.match((await getPage('http://localhost:8787/')).headers.get('content-security-policy'), /connect-src 'self' ws:\/\/localhost:8787/);
});

test('L4: в странице нет того, что CSP заблокирует — атрибутов-обработчиков, javascript:, eval, внешних адресов, воркеров', () => {
  assert.doesNotMatch(html, /\son(click|load|error|change|input|submit|keydown|keyup|mouse\w+|focus|blur)\s*=/i);
  assert.doesNotMatch(html, /javascript:/i);
  assert.doesNotMatch(html, /\beval\s*\(|new Function\s*\(|importScripts|new Worker\(|<iframe|<object|<embed|<link\b/i);
  assert.doesNotMatch(html, /(?:src|href)\s*=\s*["']https?:/i, 'внешних ресурсов нет');
  // Все fetch/WebSocket — свой хост (connect-src 'self').
  for (const m of html.matchAll(/fetch\(\s*([`"'])([^`"']*)\1/g)) assert.ok(m[2].startsWith('/'), `fetch ${m[2]}`);
  assert.doesNotMatch(html, /new WebSocket\(\s*["'`]wss?:\/\/(?!\$\{)/);
  // Схемы мониторов Windows — <img src="data:image/svg+xml,…">: разрешено img-src data:.
  assert.match(csp.contentSecurityPolicy([], new URL('https://h/')), /img-src 'self' data: blob:/);
});

test('L4: хэши считаются из самой страницы — правка скрипта меняет CSP', async () => {
  const one = await csp.scriptHashes('<script>a()</script><script src="x.js"></script><script>b()</script>');
  assert.deepEqual([...one], [sha('a()'), sha('b()')]);
  assert.deepEqual([...await csp.scriptHashes('<script>a( )</script>')], [sha('a( )')]);
});

// ---- M3: страница-ведущий без ключа ----
const requestCode = html.slice(html.indexOf('// Зритель просится'), html.indexOf('function showRequest'));
function pageHost({ keyed, trusted }) {
  const answers = [];
  const ctx = vm.createContext({ myId: '1000000000', hostAuth: keyed ? { keyed: true } : null, answers,
    trustedList: () => trusted, B64U_KEY: /^[A-Za-z0-9_-]{43}$/, answer: (...args) => answers.push(args), showRequest: () => {} });
  vm.runInContext(`${requestCode}\nthis.onRequest = onRequest; this.pending = () => requests;`, ctx);
  return { ctx, answers };
}

test('M3: ведущий-страница без ключа не впускает «доверенного» зрителя по ID — спрашивает, как Mac', () => {
  const { ctx, answers } = pageHost({ keyed: false, trusted: [{ id: '2000000000', pub: null }] });
  ctx.onRequest({ type: 'request', viewer: '2000000000', name: 'Анна', rid: 'r1' });
  assert.deepEqual(answers, [], 'автоответа нет');
  assert.equal(ctx.pending().length, 1, 'запрос ждёт решения человека');
  assert.equal(ctx.pending()[0].kind, 'legacy');
});

test('M3: старый зритель у ведущего с ключом по ID тоже не впускается; проверенный ключ — по-прежнему автоприём', () => {
  const pub = 'A'.repeat(43);
  const old = pageHost({ keyed: true, trusted: [{ id: '2000000000', pub }] });
  old.ctx.onRequest({ type: 'request', viewer: '2000000000', name: 'Анна', rid: 'r1', v: 2, auth: 'none' });
  assert.deepEqual(old.answers, []);
  const keyed = pageHost({ keyed: true, trusted: [{ id: '2000000000', pub }] });
  keyed.ctx.onRequest({ type: 'request', viewer: '2000000000', name: 'Анна', rid: 'r2', v: 2, auth: 'key', pub, idVerified: true });
  assert.equal(keyed.answers.length, 1, 'ключ совпал с запомненным — автоприём');
  assert.equal(keyed.answers[0][1], true);
});

// ---- L19 ----
test('L19: wrangler закреплён версией, undici не ниже исправленной, в lock — те же версии', () => {
  const pkg = JSON.parse(fs.readFileSync(`${__dirname}/../package.json`, 'utf8'));
  const lock = JSON.parse(fs.readFileSync(`${__dirname}/../package-lock.json`, 'utf8'));
  assert.match(pkg.devDependencies.wrangler, /^\d+\.\d+\.\d+$/, 'без ^ — версию меняют осознанно');
  assert.equal(lock.packages['node_modules/wrangler'].version, pkg.devDependencies.wrangler);
  const [major, minor, patch] = lock.packages['node_modules/undici'].version.split('.').map(Number);
  assert.ok(major > 7 || (major === 7 && (minor > 30 || (minor === 30 && patch >= 1))), `undici ${lock.packages['node_modules/undici'].version}`);
  assert.deepEqual(Object.keys(pkg.dependencies || {}), [], 'в воркер зависимости не попадают');
});
