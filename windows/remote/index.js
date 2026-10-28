// «Удалённые подключения»: окно, палитра (Win+Shift+A по умолчанию), меню в трее. Единственная точка подключения к main.js — init().
// Вся логика — в service.js и соседних модулях (без Electron, с тестами); здесь только окна, трей, клавиша и IPC.
"use strict";

const path = require("node:path");
const { ConnectionsFileStore } = require("./filestore");
const { RemoteSettings, hotkeyProblem } = require("./settings");
const { RemoteService } = require("./service");
const fs = require("node:fs");
const { spawn, execFile } = require("node:child_process");
const { TITLES, downloadURL, programOf } = require("./models");
const { createConnector, defaultPaths } = require("./connect");
const { createUia } = require("./uia");
const { createConcealedWriter } = require("./concealed");
const { buildCard, publicCard, cardSecret, cardSecrets, hasAccount, ACCOUNT_ID, CARD_SECRETS, maskedAccess, parseContacts, isPhone } = require("./access");
const { createHandlerLookup, callPlan } = require("./dialer");
const { SecretBuffer } = require("./secret");
const { createHud } = require("./hud");
const editor = require("./editor");
const templates = require("./templates");
const lists = require("./lists");
const { createSecretClipboard } = require("./clipboard");
const { createLocator, isProgramFile } = require("./locate");

const UI = path.join(__dirname, "ui");
const PRELOAD = path.join(UI, "preload.js");

// "Win+Shift+A" → ускоритель Electron "Super+Shift+A"; "Ctrl+Alt+A" → "Control+Alt+A".
const accelerator = (hotkey) => String(hotkey).replace(/\bctrl\b/i, "Control").replace(/\bwin\b/i, "Super");

// Только файлы списка и сами программы: окно и страницы не могут направить приложение на произвольный путь. Программа — по
// имени файла: «AnyDesk.exe», портативный «AnyDesk (1).exe» из «Загрузок»; «TeamViewer.exe», «TeamViewerQS.exe» (locate.js).
const LIST_FILE = /\.(xlsx|xlsm|xml)$/i;
const PROGRAM_FILE = { anyDesk: { test: (v) => isProgramFile("anyDesk", v) }, teamViewer: { test: (v) => isProgramFile("teamViewer", v) } };

// Палитра — по экрану (DIP, масштаб Windows Electron учитывает): ширина ~800, высота ~62 % рабочей области (не меньше 600),
// всегда целиком в workArea; по центру, чуть выше середины.
function paletteBounds(workArea) {
  const width = Math.min(800, workArea.width - 32);
  const height = Math.min(workArea.height - 32, Math.max(600, Math.round(workArea.height * 0.62)));
  const y = workArea.y + Math.max(16, Math.round((workArea.height - height) * 0.35));
  return { x: Math.round(workArea.x + (workArea.width - width) / 2), y, width, height };
}
function sanitizePatch(patch) {
  const out = { ...patch };
  if (typeof out.file === "string" && out.file !== "" && !LIST_FILE.test(out.file)) delete out.file;
  if (out.programPaths && typeof out.programPaths === "object") {
    const clean = {};
    for (const p of ["anyDesk", "teamViewer"]) {
      const v = out.programPaths[p];
      if (typeof v === "string" && (v === "" || PROGRAM_FILE[p].test(v))) clean[p] = v;
    }
    out.programPaths = clean;
  }
  return out;
}

// electron: { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, shell, dialog, nativeImage, screen };
// options: { icon, userData, connector?, editor?, templates?, hud?, log?, copyText?, clipboard?, writeConcealed?, dialer? } — copyText(text) кладёт в
// буфер обмена ID TeamViewer или адрес RDP (передаётся из main.js; пароль через него не идёт); clipboard — буфер для секретов
// («Скопировать пароль учётки», «Доступ»: очищается через 30 с), по умолчанию — electron.clipboard; writeConcealed(secret) →
// Promise<boolean> кладёт секрет в буфер мимо журнала Win+V и облака; dialer — { isUniTalk() → Promise<boolean>, open(url) } (в тестах
// двойник: UniTalk не запускается). Возвращает управляющий объект (тесты и main.js).
function init(electron, options = {}) {
  const { app, BrowserWindow, Tray, Menu, MenuItem, globalShortcut, ipcMain, shell, dialog, nativeImage, screen } = electron;
  const userData = options.userData || app.getPath("userData");
  const settings = new RemoteSettings(path.join(userData, "remote-connections.json"));
  const store = new ConnectionsFileStore(options.timing);
  const log = options.log || (() => {});
  let lastRequest = null;
  // Тост хода подключения; «успех» можно отключить в настройках (уведомление после подключения).
  const realHud = options.hud || createHud({ BrowserWindow, screen, ipcMain }, (id) => hudAction(id));
  const hud = { show(state) { if (state.kind === "success" && !settings.data.notify) return; realHud.show(state); } };
  // Программы вне Program Files: портативный exe в «Загрузках» и на Рабочем столе, обработчик ссылок и App Paths из реестра,
  // запущенный процесс (только чтение). Реестр и процессы — только на Windows.
  const locator = options.locator || createLocator({ fs, env: process.env, execFile: process.platform === "win32" ? execFile : null });
  const connector = options.connector || createConnector({ exists: fs.existsSync, customPaths: () => settings.data.programPaths, spawn,
    uia: createUia(spawn), hud, openExternal: (url) => shell.openExternal(url), log, copyText: options.copyText, locate: (p) => locator.candidates(p), trust: locator });
  // Находки и подписи: реестр, процессы, подписи файлов вне Program Files — свой путь и %LOCALAPPDATA% тоже. Поменялось — окно
  // перерисует плашку «не найден».
  const refreshPrograms = () => {
    const local = defaultPaths(process.env);
    const extra = Object.fromEntries(["anyDesk", "teamViewer"].map((p) => [p, [settings.data.programPaths?.[p], ...local[p]].filter(Boolean)]));
    return Promise.resolve(locator.refresh(extra)).then((changed) => { if (changed) notifyViews(); }).catch(() => {});
  };
  // Секреты (пароль учётки, «Доступ», пароль или ключ VPN) — в буфер только мимо журнала буфера Windows и облачной синхронизации
  // (W2-5). Не Windows — журнала Win+V нет, помощника тоже (null): там секрет пишется обычным текстом (сборка для разработки).
  const writeConcealed = options.writeConcealed || (process.platform === "win32" ? createConcealedWriter(spawn) : null);
  const service = new RemoteService({ settings, store, connector });
  // Звонок: обработчик `tel:` — по реестру (только чтение); UniTalk — openExternal, иначе номер копируется.
  const dialer = options.dialer || { isUniTalk: createHandlerLookup(process.platform === "win32" ? execFile : null).isUniTalk,
    open: (url) => shell.openExternal(url) };
  const secretClipboard = createSecretClipboard({ clipboard: options.clipboard || electron.clipboard, writeConcealed });
  // Запись в буфер в Electron 44 асинхронная: Promise<boolean>, ошибка записи — false.
  const copyPlain = async (text) => {
    if (typeof options.copyText === "function") { try { return (await options.copyText(String(text))) !== false; } catch (_) { return false; } }
    try { await electron.clipboard.writeText(String(text)); return true; } catch (_) { return false; }
  };
  // Подробности, которые надо открыть в окне (из трея или меню): окно забирает ключ, когда готово.
  let pendingDetails = null;
  let windowRef = null, paletteRef = null, tray = null, hotkeyOk = true, registered = "";

  const alive = (w) => w && !w.isDestroyed();
  const secure = { preload: PRELOAD, contextIsolation: true, sandbox: true, nodeIntegration: false };
  // Окна модуля показывают только свою страницу: переход куда-либо (в том числе перетаскивание файла в окно) и новые окна запрещены.
  const lock = (win) => {
    win.webContents.on?.("will-navigate", (event) => event.preventDefault());
    win.webContents.setWindowOpenHandler?.(() => ({ action: "deny" }));
  };
  // Вызов принят только от окон модуля (список, палитра).
  const trusted = (event) => !!event && !!event.sender && ((alive(windowRef) && event.sender === windowRef.webContents) || (alive(paletteRef) && event.sender === paletteRef.webContents));

  function openWindow() {
    if (alive(windowRef)) { if (windowRef.isMinimized()) windowRef.restore(); windowRef.show(); windowRef.focus(); return windowRef; }
    windowRef = new BrowserWindow({ width: 760, height: 760, minWidth: 520, minHeight: 480, title: "Mac Utils · Удалённые подключения",
      autoHideMenuBar: true, backgroundColor: "#111111", icon: options.icon, webPreferences: secure });
    lock(windowRef);
    windowRef.loadFile(path.join(UI, "remote.html"));
    windowRef.on("closed", () => { windowRef = null; });
    return windowRef;
  }

  function openPalette() {
    if (!alive(paletteRef)) {
      paletteRef = new BrowserWindow({ width: 800, height: 600, frame: false, resizable: false, show: false, alwaysOnTop: true, skipTaskbar: true,
        transparent: true, hasShadow: false, webPreferences: secure });
      lock(paletteRef);
      paletteRef.loadFile(path.join(UI, "remote.html"), { hash: "palette" });
      paletteRef.on("blur", () => { if (alive(paletteRef)) paletteRef.hide(); });
      paletteRef.on("closed", () => { paletteRef = null; });
    }
    // По центру экрана с курсором, размер — по его рабочей области.
    try { paletteRef.setBounds(paletteBounds(screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea)); } catch (_) {}
    paletteRef.show(); paletteRef.focus();
    paletteRef.webContents.send("rc:show");
  }

  // Клавиша и значок в трее — всегда, и без файла (rc-win-entry: иначе вход в модуль не найти). Без файла клавиша открывает окно
  // списка с пустым состоянием «Выберите файл подключений», с файлом — палитру.
  const hotkeyAction = () => (settings.data.file ? openPalette() : openWindow());
  function applyEnabled() {
    if (registered) { try { globalShortcut.unregister(registered); } catch (_) {} registered = ""; }
    hotkeyOk = true;
    const problem = hotkeyProblem(settings.data.hotkey);
    if (problem === "noModifier" || problem === "noKey") hotkeyOk = false;
    else {
      const want = accelerator(settings.data.hotkey);
      try { hotkeyOk = !!globalShortcut.register(want, hotkeyAction); } catch (_) { hotkeyOk = false; }
      if (hotkeyOk) registered = want;
    }
    if (!hotkeyOk) log("горячая клавиша не зарегистрирована");
    buildTray();
    return hotkeyOk;
  }
  const registerHotkey = applyEnabled;

  function buildTray() {
    if (!tray) {
      const image = options.icon ? nativeImage.createFromPath(options.icon).resize({ width: 16, height: 16 }) : nativeImage.createEmpty();
      tray = new Tray(image);
      tray.setToolTip("Mac Utils · Удалённые подключения");
      tray.on("click", openWindow);
    }
    tray.setContextMenu(Menu.buildFromTemplate(trayTemplate()));
  }

  // Вход без файла (меню трея и окна): выбрать файл или создать шаблон — после этого открывается список; или открыть список.
  function entryItems() {
    return [
      { label: "Выбрать файл…", click: async () => { if (await chooseFile()) openWindow(); } },
      { label: "Создать шаблон .xlsx…", click: async () => { if (await createTemplate("xlsx")) openWindow(); } },
      { label: "Создать шаблон .xml…", click: async () => { if (await createTemplate("xml")) openWindow(); } },
      { type: "separator" },
      { label: "Открыть список…", click: openWindow },
    ];
  }
  // Пункт «Удалённые подключения» в меню окон: всегда, с файлом и без. Меню приложения может ещё не быть (null) — тогда своё.
  const entryMenu = () => [
    { label: "Открыть список…", click: openWindow },
    { label: `Поиск (${settings.data.hotkey})`, click: hotkeyAction },
    { type: "separator" },
    ...entryItems().slice(0, 3),
  ];
  function ensureWindowMenu() {
    try {
      const item = { label: "Удалённые подключения", submenu: entryMenu() };
      const menu = Menu.getApplicationMenu?.();
      if (menu && MenuItem && typeof menu.append === "function") {
        if (!(menu.items || []).some((i) => i.label === item.label)) menu.append(new MenuItem(item));
        Menu.setApplicationMenu(menu);
      } else {
        Menu.setApplicationMenu(Menu.buildFromTemplate([item]));
      }
    } catch (_) {}
  }

  // Меню в трее: избранное, недавние (названия — из файла, показываются только в меню), «Открыть список», внизу — только «Обновить».
  // «Открыть в Excel», папка, «Добавить» и строка «Загружено N · пропущено …» с диагностикой — в окне списка и его настройках.
  // Без файла — вход: выбрать файл, создать шаблон, открыть список.
  function trayTemplate() {
    if (!settings.data.file) return entryItems();
    const view = service.view();
    const items = [{ label: "Открыть список…", click: openWindow }, { label: `Поиск (${settings.data.hotkey})`, click: openPalette }, { type: "separator" }];
    const flat = view.sections.filter((s) => s.kind === "favorites" || s.kind === "recents");
    for (const s of flat) {
      items.push({ label: s.kind === "favorites" ? "Избранное" : "Недавние", enabled: false });
      for (const r of s.records) items.push({ label: r.id ? `${r.name} · ${r.id}` : r.name, click: () => connect(r.key, false, true) });
    }
    if (flat.length) items.push({ type: "separator" });
    items.push({ label: "↻ Обновить", click: reload });
    return items;
  }

  // Перечитать файл и заново поискать программы (портативный AnyDesk могли скачать только что).
  function reload() {
    store.reload();
    refreshPrograms();
  }

  const notifyViews = () => {
    for (const w of [windowRef, paletteRef]) if (alive(w)) w.webContents.send("rc:changed");
    if (tray) { try { tray.setContextMenu(Menu.buildFromTemplate(trayTemplate())); } catch (_) {} }
  };

  // fromTray — из меню в трее: запись VPN/«Другое» (или RDP без адреса) открывается подробностями в окне списка.
  async function connect(key, noPassword, fromTray = false) {
    lastRequest = { key, noPassword };
    const record = service.recordByKey(key);
    if (!record) { hud.show(connector.MESSAGES.gone()); store.reload(); return { ok: false, error: "gone" }; }
    const result = await connector.connectRecord(record, { noPassword, settings: settings.data, store, service });
    if (result && result.ok) service.noteConnected(record);
    if (result && result.error === "details" && fromTray) showDetails(key);
    return result;
  }

  function showDetails(key) {
    pendingDetails = key;
    const win = openWindow();
    try { win.webContents.send("rc:details"); } catch (_) {}
  }

  // Карточка записи с паролями — только здесь, в основном процессе: «Доступ» и пароль учётки читаются из файла сейчас и сразу
  // затираются. null — записи нет.
  async function fullCard(key) {
    const record = service.recordByKey(key);
    if (!record) return null;
    const read = async (field) => {
      let secret = null;
      try { secret = await service.secret(key, field); } catch (_) { secret = null; }
      if (!secret) return null;
      try { return secret.bytes.toString("utf8"); } finally { secret.wipe(); }
    };
    const access = record.accessLines > 0 ? await read("access") : null;
    const accountPassword = record.hasAccountPassword ? await read("accountPassword") : null;
    return { record, card: buildCard(record, access, accountPassword) };
  }

  // Адрес RDP из «Доступа» (запись не RDP, но в «Доступе» есть блок RDP): файл читается заново, окну адрес не доверяем.
  async function accessRDPAddress(key) {
    return (await fullCard(key))?.card.rdp?.address || null;
  }

  // RDP — «Подключение к удалённому рабочему столу» (mstsc); не тот адрес — подробности. fromAccess — адрес из строк «Доступа».
  async function openRDP(key, fromAccess = false) {
    const record = service.recordByKey(key);
    if (!record) return { ok: false, error: "gone" };
    let target = record;
    if (fromAccess) {
      const address = await accessRDPAddress(key);
      if (!address) return { ok: false, error: "details" };
      target = { ...record, method: "rdp", id: address };
    }
    const result = connector.openRDP ? await connector.openRDP(target) : { ok: false, error: "details" };
    if (result && result.ok) service.noteConnected(record);
    return result;
  }

  // Секрет по полю: пароль программы, пароль учётки, «Доступ» — из файла; секрет карточки (vpn.key, vpn.password, rdp.password,
  // account.<хэш>.<n>) — из «Доступа» и колонок, файл читается заново. { secret: SecretBuffer | null, changed } — changed: учётки
  // с таким id в перечитанном файле нет (файл изменился после открытия карточки), ничего не отдаём.
  async function secretOf(key, field) {
    if (CARD_SECRETS.test(field)) {
      const card = (await fullCard(key))?.card || { accounts: [] };
      if (ACCOUNT_ID.test(field) && !hasAccount(card, field)) return { secret: null, changed: true };
      const value = cardSecret(card, field);
      return { secret: value ? new SecretBuffer(value) : null, changed: false };
    }
    return { secret: await service.secret(key, field), changed: false };
  }
  const CHANGED = { kind: "warning", title: "Файл изменился — откройте карточку заново", actions: [{ id: "close", label: "Закрыть" }] };

  const COPY_TITLES = { password: "Пароль скопирован", accountPassword: "Пароль учётки скопирован", access: "«Доступ» скопирован" };
  const copyable = (field) => Object.hasOwn(COPY_TITLES, field) || CARD_SECRETS.test(field);
  // Секрет — из файла сейчас, в буфер на 30 с (мимо журнала Win+V). quiet — без тоста (подпись показывает карточка). В журнал —
  // только код поля.
  async function copySecret(key, field, quiet = false) {
    if (!copyable(field)) return { ok: false, error: "field" };
    const code = ACCOUNT_ID.test(field) ? "account" : field;
    let secret = null, changed = false;
    try { ({ secret, changed } = await secretOf(key, field)); } catch (_) { secret = null; }
    try {
      if (changed) {
        hud.show(CHANGED);
        log(`copy fail field=${code} changed`);
        return { ok: false, error: "changed" };
      }
      if (!secret) {
        hud.show({ kind: "warning", title: "Не удалось прочитать файл", detail: "Проверьте, что файл на месте, и повторите.", actions: [{ id: "close", label: "Закрыть" }] });
        log(`copy fail field=${code}`);
        return { ok: false, error: "unavailable" };
      }
      const ok = await secretClipboard.copy(secret);
      if (!ok) hud.show({ kind: "warning", title: "Не удалось скопировать", detail: "Буфер обмена недоступен — секрет не скопирован.", actions: [{ id: "close", label: "Закрыть" }] });
      else if (!quiet) hud.show({ kind: "success", title: COPY_TITLES[field] || "Пароль скопирован", detail: "Буфер очистится через 30 с. В журнал буфера Windows не попадает.", autoHideMs: 2500 });
      log(`copy ${ok ? "ok" : "fail"} field=${code}`);
      return { ok };
    } finally { secret?.wipe(); }
  }

  // 👁 в карточке: значение уходит только в окно подробностей, на 10 с (скрывает окно). В журнал — ничего.
  async function revealSecret(key, field) {
    if (field !== "password" && !CARD_SECRETS.test(field)) return { ok: false };
    let secret = null, changed = false;
    try { ({ secret, changed } = await secretOf(key, field)); } catch (_) { secret = null; }
    if (changed) { hud.show(CHANGED); return { ok: false, error: "changed" }; }
    if (!secret) return { ok: false };
    try { return { ok: true, value: secret.bytes.toString("utf8") }; } finally { secret.wipe(); }
  }

  // «Показать» в «Доступе · как в файле»: текст уходит только в окно подробностей (на 10 с), под маской — метки паролей до конца
  // строки, все секреты карточки и пароль ID по значению, пары и одиночные слова без меток (maskedAccess).
  async function revealAccess(key) {
    let secret = null;
    try { secret = await service.secret(key, "access"); } catch (_) { secret = null; }
    if (!secret) return { ok: false };
    try {
      const full = await fullCard(key);
      const secrets = full ? cardSecrets(full.card) : [];
      if (full && !full.record.method && full.record.hasPassword) {
        let program = null;
        try { program = await service.secret(key, "password"); } catch (_) { program = null; }
        if (program) { try { secrets.push(program.bytes.toString("utf8")); } finally { program.wipe(); } }
      }
      return { ok: true, text: maskedAccess(secret.bytes.toString("utf8").split(/\r\n|\n|\r/).join("\n"), secrets) };
    } finally { secret.wipe(); }
  }

  // Адрес RDP: ID записи RDP или (fromAccess) адрес из «Доступа» — файл читается заново.
  async function copyAddress(key, fromAccess = false) {
    const record = service.recordByKey(key);
    if (!record) return { ok: false };
    const address = fromAccess ? await accessRDPAddress(key) : record.id;
    if (!address) return { ok: false };
    const ok = await copyPlain(address);
    hud.show(ok ? { kind: "success", title: "Адрес скопирован", detail: record.name, autoHideMs: 2000 } : { kind: "warning", title: "Не удалось скопировать", detail: "Буфер обмена недоступен.", actions: [{ id: "close", label: "Закрыть" }] });
    log(`copy ${ok ? "ok" : "fail"} field=address`);
    return { ok };
  }

  // Не секрет из карточки (сервер, логин) — обычной копией; окно присылает только то, что само показывает.
  async function copyText(text) {
    const value = String(text ?? "");
    if (!value || value.length > 256 || /[\r\n]/.test(value)) return { ok: false };
    const ok = await copyPlain(value);
    hud.show(ok ? { kind: "success", title: "Скопировано", autoHideMs: 1500 } : { kind: "warning", title: "Не удалось скопировать", detail: "Буфер обмена недоступен.", actions: [{ id: "close", label: "Закрыть" }] });
    log(`copy ${ok ? "ok" : "fail"} field=text`);
    return { ok };
  }

  // Телефон из «Контактов» (карточка подробностей): только строка вида телефона. В журнал — только код.
  async function copyPhone(text) {
    if (!isPhone(text)) return { ok: false, error: "phone" };
    const ok = await copyPlain(String(text).trim());
    hud.show(ok ? { kind: "success", title: "Телефон скопирован", autoHideMs: 2000 } : { kind: "warning", title: "Не удалось скопировать", detail: "Буфер обмена недоступен.", actions: [{ id: "close", label: "Закрыть" }] });
    log(`copy ${ok ? "ok" : "fail"} field=phone`);
    return { ok };
  }

  // Звонок: обработчик tel:/callto: — UniTalk → openExternal('tel:+380…'); нет — номер копируется («UniTalk не найден — номер
  // скопирован»). Только строка вида телефона. В журнал — только код.
  async function call(text) {
    if (!isPhone(text)) return { ok: false, error: "phone" };
    let uniTalk = false;
    try { uniTalk = await dialer.isUniTalk(); } catch (_) { uniTalk = false; }
    const plan = callPlan(text, uniTalk);
    if (plan.call) {
      let opened = true;
      try { await dialer.open(plan.call); } catch (_) { opened = false; }
      if (opened) { log("call ok"); return { ok: true, call: true }; }
      // UniTalk не открылся — номер всё равно не теряется: копируется.
      plan.copy = String(text).trim(); plan.reason = "openFailed";
    }
    const ok = await copyPlain(plan.copy);
    const title = { noUniTalk: "UniTalk не найден — номер скопирован", openFailed: "UniTalk не открылся — номер скопирован" }[plan.reason] || "Номер скопирован";
    hud.show(ok ? { kind: "success", title, autoHideMs: 2500 }
                : { kind: "warning", title: "Не удалось скопировать", detail: "Буфер обмена недоступен.", actions: [{ id: "close", label: "Закрыть" }] });
    log(`call copy reason=${plan.reason}`);
    return { ok, call: false, reason: plan.reason };
  }

  // Карточка подробностей (макеты Details и Accounts): шаги «Как подключиться», учётные записи — без паролей и ключей (только
  // признаки и id для 👁/⧉); «Контакты» — люди и телефоны. Читается из файла при открытии карточки; живёт в окне, пока она
  // открыта. В журнал — ничего.
  async function cardInfo(key) {
    const full = await fullCard(key);
    if (!full) return { ok: false };
    let contacts = [];
    if (full.record.hasContacts) {
      let secret = null;
      try { secret = await service.secret(key, "contacts"); } catch (_) { secret = null; }
      if (secret) { try { contacts = parseContacts(secret.bytes.toString("utf8")); } finally { secret.wipe(); } }
    }
    return { ok: true, card: publicCard(full.record, full.card), contacts };
  }

  function showFolder() {
    if (settings.data.file) shell.showItemInFolder(settings.data.file);
  }

  // Меню строки (правая кнопка): действия над записью. Окну уходят только «подробности» и «изменить» (их показывает окно).
  function rowMenuTemplate(key, sender) {
    const record = service.recordByKey(key);
    if (!record) return [];
    const p = service.present(record);
    const tell = (action) => () => { try { sender?.send?.("rc:menu", { action, key }); } catch (_) {} };
    const items = [];
    if (!p.method) items.push({ label: "Подключиться", click: () => connect(key, false) }, { label: "Открыть без пароля", click: () => connect(key, true) });
    else if (p.rdpHost) items.push({ label: "Открыть удалённый рабочий стол", click: () => openRDP(key) });
    items.push({ label: p.favorite ? "Убрать из избранного" : "В избранное", click: () => service.toggleFavorite(key) });
    items.push({ label: "Подробности", click: tell("details") });
    if (p.hasAccountPassword) items.push({ label: "Скопировать пароль учётки", click: () => copySecret(key, "accountPassword") });
    if (p.method === "rdp" && record.id) items.push({ label: "Скопировать адрес", click: () => copyAddress(key) });
    if (/\.(xml|xlsx|xlsm)$/i.test(settings.data.file)) items.push({ type: "separator" }, { label: "Изменить…", click: tell("edit") });
    return items;
  }
  function popupRowMenu(event, key) {
    const template = rowMenuTemplate(key, event.sender);
    if (!template.length) return false;
    try {
      const menu = Menu.buildFromTemplate(template);
      menu.popup?.({ window: BrowserWindow.fromWebContents?.(event.sender) || undefined });
    } catch (_) { return false; }
    return true;
  }

  // Кнопки тоста: повторить, открыть файл, скачать программу, отмена, закрыть.
  function hudAction(id) {
    const record = lastRequest && service.recordByKey(lastRequest.key);
    if (id === "retry" && lastRequest) connect(lastRequest.key, lastRequest.noPassword);
    else if (id === "openFile") openFile();
    else if (id === "download" && record) shell.openExternal(downloadURL(programOf(record, settings.data.defaultProgram)));
    else if (id === "download") shell.openExternal(downloadURL(settings.data.defaultProgram));
    else connector.hudAction(id);
  }

  function openFile() {
    if (settings.data.file) shell.openPath(settings.data.file);
  }

  async function chooseFile() {
    // Electron 43+: без defaultPath диалог открывается в «Загрузках» и не помнит прошлую папку — открываем папку текущего файла.
    const picked = await dialog.showOpenDialog(alive(windowRef) ? windowRef : undefined, { title: "Файл подключений", properties: ["openFile"],
      ...(settings.data.file ? { defaultPath: path.dirname(settings.data.file) } : {}),
      filters: [{ name: "Список подключений", extensions: ["xlsx", "xml"] }] });
    if (picked.canceled || !picked.filePaths[0]) return "";
    if (!LIST_FILE.test(picked.filePaths[0])) return "";
    settings.update({ file: picked.filePaths[0], sheet: "" });
    service.start();
    applyEnabled();
    notifyViews();
    return picked.filePaths[0];
  }

  // «Указать AnyDesk.exe…» в плашке «не установлен»: выбранный exe с именем программы и действительной подписью её издателя
  // (или из Program Files) сохраняется в programPaths. Подпись не та — честное предупреждение, путь не сохраняется: пароль такому
  // файлу не уходит. { ok } или { ok: false, error: "name" | "signature" | "cancel" }.
  async function pickProgram(program) {
    if (!Object.hasOwn(PROGRAM_FILE, program)) return { ok: false, error: "program" };
    const picked = await dialog.showOpenDialog(alive(windowRef) ? windowRef : undefined, { title: `Где ${TITLES[program]}?`, properties: ["openFile"],
      defaultPath: process.env.USERPROFILE ? path.win32.join(process.env.USERPROFILE, "Downloads") : undefined,
      filters: [{ name: TITLES[program], extensions: ["exe"] }] });
    const file = !picked.canceled && picked.filePaths[0];
    if (!file) return { ok: false, error: "cancel" };
    const title = TITLES[program];
    if (!PROGRAM_FILE[program].test(file)) {
      hud.show({ kind: "warning", title: `Это не ${title}`, detail: `Выберите сам ${title}.exe — не установщик, не службу и не QuickSupport.`, actions: [{ id: "close", label: "Закрыть" }] });
      return { ok: false, error: "name" };
    }
    let signed = false;
    try { signed = await locator.verify(program, file); } catch (_) { signed = false; }
    if (!signed) {
      hud.show({ kind: "warning", title: `Подпись ${title} не подтверждена`, detail: `У файла нет действительной подписи издателя ${title} — пароль ему не передаётся, путь не сохранён. Скачайте ${title} с официального сайта.`,
        actions: [{ id: "close", label: "Закрыть" }] });
      log(`program pick fail program=${program} code=signature`);
      return { ok: false, error: "signature" };
    }
    settings.update({ programPaths: { ...settings.data.programPaths, [program]: file } });
    notifyViews();
    return { ok: true };
  }

  function setSettings(rawPatch) {
    const patch = sanitizePatch(rawPatch && typeof rawPatch === "object" ? rawPatch : {});
    // Сочетание без модификатора («A», «Shift+A») нельзя: оно отняло бы ввод. Ctrl+Alt допустимо, но с предупреждением про AltGr.
    let problem = "";
    if (Object.hasOwn(patch, "hotkey")) {
      problem = hotkeyProblem(patch.hotkey);
      if (problem === "noModifier" || problem === "noKey") delete patch.hotkey;
    }
    const before = settings.data.file + "|" + settings.data.sheet;
    const data = settings.update(patch);
    if (before !== data.file + "|" + data.sheet) service.start();
    const ok = applyEnabled();
    notifyViews();
    return { ...data, hotkeyOk: problem === "noModifier" || problem === "noKey" ? false : ok, hotkeyProblem: problem || hotkeyProblem(data.hotkey) };
  }

  // Вызовы принимаются только от окон модуля.
  const guarded = (fn, denied = null) => (event, ...args) => (trusted(event) ? fn(event, ...args) : denied);
  ipcMain.handle("rc:view", guarded((_e, q) => service.view({ query: String(q?.query ?? ""), filter: lists.FILTERS.includes(q?.filter) ? q.filter : "all",
    tags: Array.isArray(q?.tags) ? q.tags.map(String) : [] })));
  ipcMain.handle("rc:details", guarded((_e, key) => service.details(String(key))));
  ipcMain.handle("rc:pendingDetails", guarded(() => { const key = pendingDetails; pendingDetails = null; return key; }));
  ipcMain.handle("rc:revealAccess", guarded((_e, key) => revealAccess(String(key)), { ok: false }));
  ipcMain.handle("rc:copySecret", guarded((_e, q) => copySecret(String(q?.key), String(q?.field), !!q?.quiet), { ok: false }));
  ipcMain.handle("rc:revealSecret", guarded((_e, q) => revealSecret(String(q?.key), String(q?.field)), { ok: false }));
  ipcMain.handle("rc:copyText", guarded((_e, text) => copyText(text), { ok: false }));
  ipcMain.handle("rc:call", guarded((_e, text) => call(String(text ?? "")), { ok: false }));
  ipcMain.handle("rc:copyAddress", guarded((_e, q) => copyAddress(String(q?.key), !!q?.fromAccess), { ok: false }));
  ipcMain.handle("rc:copyPhone", guarded((_e, text) => copyPhone(String(text ?? "")), { ok: false }));
  ipcMain.handle("rc:cardInfo", guarded((_e, key) => cardInfo(String(key)), { ok: false }));
  ipcMain.handle("rc:openRDP", guarded((_e, q) => openRDP(String(q?.key), !!q?.fromAccess), { ok: false, error: "denied" }));
  ipcMain.handle("rc:showFolder", guarded(() => showFolder()));
  ipcMain.handle("rc:rowMenu", guarded((event, key) => popupRowMenu(event, String(key)), false));
  ipcMain.handle("rc:toggleFavorite", guarded((_e, key) => service.toggleFavorite(String(key)), false));
  ipcMain.handle("rc:connect", guarded((_e, q) => connect(String(q?.key), !!q?.noPassword), { ok: false, error: "denied" }));
  ipcMain.handle("rc:openFile", guarded(() => openFile()));
  ipcMain.handle("rc:reload", guarded(() => reload()));
  ipcMain.handle("rc:pickProgram", guarded((_e, program) => pickProgram(String(program)), { ok: false, error: "denied" }));
  ipcMain.handle("rc:chooseFile", guarded(chooseFile, ""));
  ipcMain.handle("rc:getSettings", guarded(() => ({ ...settings.data }), null));
  ipcMain.handle("rc:setSettings", guarded((_e, patch) => setSettings(patch), null));
  ipcMain.handle("rc:sheets", guarded(() => store.sheetNames().catch(() => []), []));
  const createTemplate = async (kind) => {
    const file = await (options.templates || templates).create({ kind, dialog, parent: alive(windowRef) ? windowRef : undefined, settings, service, setSettings });
    return file || "";
  };
  ipcMain.handle("rc:createTemplate", guarded(async (_e, kind) => createTemplate(kind), ""));
  ipcMain.handle("rc:edit", guarded(async (_e, q) => {
    if (q?.action === "download") { shell.openExternal(require("./models").downloadURL(q.payload === "teamViewer" ? "teamViewer" : "anyDesk")); return true; }
    return editRecord(q);
  }, { ok: false, error: "denied" }));

  // Правка списка (только .xml; .xlsx не пишется): добавить, изменить, удалить; затем файл перечитывается.
  async function editRecord(q) {
    const file = settings.data.file;
    if (!file || !["add", "update", "remove"].includes(q?.action)) return { ok: false, error: "action" };
    const p = q.payload || {};
    const record = q.action === "add" ? null : service.recordByKey(String(p.key));
    if (q.action !== "add" && !record) return { ok: false, error: "gone" };
    const fields = p.fields && typeof p.fields === "object" ? p.fields : {};
    const result = (options.editor || editor).apply(file, q.action, { record, fields });
    if (result.ok) store.reload();
    return result;
  }
  ipcMain.on("rc:closePalette", (e) => { if (trusted(e) && alive(paletteRef)) paletteRef.hide(); });

  service.onChange(notifyViews);
  service.start();
  applyEnabled();
  refreshPrograms();
  ensureWindowMenu();
  // Первый запуск без файла — один раз подсказка в трее (без модальных окон): где вход в подключения.
  if (!settings.data.file && !settings.data.entryHintShown && typeof tray?.displayBalloon === "function") {
    try {
      tray.displayBalloon?.({ title: "Удалённые подключения", content: `Подключения: ${settings.data.hotkey} или значок в трее`, iconType: "info", noSound: true });
      settings.update({ entryHintShown: true });
    } catch (_) {}
  }

  return {
    service, settings, store, entryMenu, entryItems, openWindow, openPalette, pickProgram, locator, registerHotkey, trayTemplate, rowMenuTemplate, connect, openRDP, copySecret, revealSecret, copyAddress, copyText, copyPhone, call, cardInfo, revealAccess, hudAction, writeConcealed, titles: TITLES,
    get hotkeyOk() { return hotkeyOk; },
    // Promise: секреты в буфере стёрты (выход его дожидается, main.js).
    dispose() { try { globalShortcut.unregisterAll?.(); } catch (_) {} const cleared = secretClipboard.flush(); store.stop(); tray?.destroy?.(); return cleared; },
  };
}

module.exports = { init, accelerator, paletteBounds };
