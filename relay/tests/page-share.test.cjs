// Начало трансляции на странице ведущего (WINNA-30): выбор источника в приложении для Windows (window.mu) и getDisplayMedia.
// Из index.html берётся блок pickSource … share; DOM, приложение и getDisplayMedia подменены моделью.
// Пользователь Windows видел «Трансляция не началась (NotAllowedError: Permission denied)» — теперь причина по-русски,
// без имён исключений, а отказ приложения принять выбор не доходит до getDisplayMedia.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync(`${__dirname}/../src/index.html`, 'utf8');
const from = html.indexOf('// В приложении для Windows (window.mu) — свой выбор экрана');
const to = html.indexOf('// Почему relay не пустил ведущего');
assert.ok(from > 0 && to > from, 'блок выбора источника и share на месте');
const block = html.slice(from, to);
const tick = () => new Promise((resolve) => setTimeout(resolve));

function element() {
  return {
    style: {}, innerHTML: '', textContent: '', checked: false, children: [],
    appendChild(child) { this.children.push(child); },
    querySelector() { return (this.nameNode ||= { textContent: '' }); },
    insertAdjacentHTML() {},
  };
}

// mu: модель приложения для Windows (null — обычный браузер); capture(constraints) — что отвечает getDisplayMedia.
function loadPage({ mu = null, capture }) {
  const nodes = new Map();
  const calls = { status: [], captures: [], opened: 0, started: 0, logs: [] };
  const $ = (id) => { if (!nodes.has(id)) nodes.set(id, element()); return nodes.get(id); };
  $('withAudio').checked = true;
  const window = { mu: mu && { ...mu, log: (line) => calls.logs.push(line) } };
  const context = vm.createContext({
    window, $, setTimeout,
    document: { createElement: () => element(), querySelectorAll: () => [] },
    navigator: { mediaDevices: { getDisplayMedia: async (constraints) => { calls.captures.push(constraints); return capture(constraints); } } },
    store: { get: (_k, fallback) => fallback, set() {} },
    status: (text) => calls.status.push(text),
    stopHost() {}, showMuteApps() {}, canSwitchMonitors: () => false, allowSwitch: () => false,
    openHost: async () => { calls.opened++; return true; },
    startCapture() { calls.started++; }, announceDisplays() {},
    pageKeySupported: () => true, hostCheckReason: async () => 'ok', retryPageKey: async () => false, explainHostFailure() {},
  });
  vm.runInContext(`let helperAvailable = false, useHelperAudio = false, keyRetried = false, pageKey = {}, myId = '1111111111';\n${block}\n` +
    'this.share = share; this.captureFailureText = captureFailureText; this.CAPTURE_NOT_CHOSEN = CAPTURE_NOT_CHOSEN;', context);
  return {
    context, calls,
    // Ведущий нажал «Транслировать» и кликнул по первой плитке (или «Отмена»).
    async start({ cancel = false } = {}) {
      const done = context.share();
      if (mu) {
        for (let i = 0; i < 50 && !$('sources').children.length; i++) await tick();
        if (cancel) $('pickerCancel').onclick(); else await $('sources').children[0].onclick();
      }
      await done;
      return calls.status.at(-1);
    },
  };
}

const fail = (name, message = 'Permission denied') => () => { const e = new Error(message); e.name = name; throw e; };
const app = (choose = async () => true) => ({ sources: async () => [{ id: 'screen:1:0', name: 'Экран 1', thumbnail: 'data:image/svg+xml,' }], choose });
const stream = { getTracks: () => [] };
const LATIN_ERROR = /NotAllowedError|AbortError|NotReadableError|NotFoundError|NotSupportedError|TypeError|Permission denied/;

test('Windows, приложение 1.2.34 не даёт экран (обработчик разрешений): понятный текст вместо «NotAllowedError: Permission denied»', async () => {
  const page = loadPage({ mu: app(), capture: fail('NotAllowedError') });
  const text = await page.start();
  assert.doesNotMatch(text, LATIN_ERROR);
  assert.match(text, /приложение не дало доступ к экрану/);
  assert.match(text, /Обновите Mac Utils Share/);
  assert.equal(page.calls.opened, 0, 'к relay без потока не подключаемся');
  assert.deepEqual(page.calls.logs, ['capture failed name=NotAllowedError'], 'код ошибки — в журнал приложения');
});

test('Windows: приложение не приняло выбор (choose → false) — getDisplayMedia не зовётся, текст про выбор экрана', async () => {
  const page = loadPage({ mu: app(async () => false), capture: async () => stream });
  const text = await page.start();
  assert.equal(text, page.context.CAPTURE_NOT_CHOSEN);
  assert.equal(page.calls.captures.length, 0);
});

test('Windows: choose упал (IPC) — тоже «не принят», без захвата', async () => {
  const page = loadPage({ mu: app(async () => { throw new Error('ipc'); }), capture: async () => stream });
  assert.equal(await page.start(), page.context.CAPTURE_NOT_CHOSEN);
  assert.equal(page.calls.captures.length, 0);
});

test('Windows: выбор принят — захват, подключение и эфир (звук системы просим, как раньше)', async () => {
  const page = loadPage({ mu: app(), capture: async () => stream });
  await page.start();
  assert.equal(page.calls.captures.length, 1);
  assert.equal(page.calls.captures[0].audio, true);
  assert.equal(page.calls.opened, 1);
  assert.equal(page.calls.started, 1);
  assert.equal(page.calls.status.length, 0, 'без сообщений об ошибке');
});

test('Windows: отказ обработчика getDisplayMedia (AbortError) — текст про выбор экрана; попытки с другими параметрами остаются', async () => {
  const page = loadPage({ mu: app(), capture: fail('AbortError', 'Invalid capture constraints') });
  assert.equal(await page.start(), page.context.CAPTURE_NOT_CHOSEN);
  assert.equal(page.calls.captures.length, 3, 'в приложении захват пробуется и без звука');
  assert.equal(page.calls.captures[2].audio, false);
});

test('Windows: «Отмена» в выборе — «Трансляция отменена», без захвата', async () => {
  const page = loadPage({ mu: app(), capture: async () => stream });
  assert.equal(await page.start({ cancel: true }), 'Трансляция отменена');
  assert.equal(page.calls.captures.length, 0);
});

test('браузер (Mac и др.): отмена выбора экрана — одна попытка, понятный текст', async () => {
  const page = loadPage({ capture: fail('NotAllowedError') });
  const text = await page.start();
  assert.equal(page.calls.captures.length, 1, 'пользователь отменил — не переспрашиваем');
  assert.doesNotMatch(text, LATIN_ERROR);
  assert.match(text, /экран не выбран/);
});

test('браузер: удачный захват — как раньше', async () => {
  const page = loadPage({ capture: async () => stream });
  await page.start();
  assert.equal(page.calls.started, 1);
  assert.equal(page.calls.status.length, 0);
});

test('тексты ошибок захвата — по-русски, без имён исключений, в приложении и в браузере', () => {
  const page = loadPage({ capture: async () => stream });
  for (const name of ['NotAllowedError', 'AbortError', 'NotReadableError', 'NotFoundError', 'NotSupportedError', 'TypeError', 'OverconstrainedError', 'SecurityError', undefined]) {
    for (const inApp of [true, false]) {
      const text = page.context.captureFailureText(name ? { name, message: 'x' } : null, inApp);
      assert.match(text, /^Трансляция не началась/, `${name} ${inApp}`);
      assert.doesNotMatch(text, LATIN_ERROR, `${name} ${inApp}`);
      if (inApp) assert.doesNotMatch(text, /Chrome, Edge/, 'в приложении не советуем браузер');
    }
  }
});
