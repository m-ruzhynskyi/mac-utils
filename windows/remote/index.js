// «Удалённые подключения»: окно, палитра (Win+Shift+A по умолчанию), меню в трее. Единственная точка подключения к main.js — init().
// Вся логика — в service.js и соседних модулях (без Electron, с тестами); здесь только окна, трей, клавиша и IPC.
"use strict";

const path = require("node:path");
const { ConnectionsFileStore } = require("./filestore");
const { RemoteSettings, hotkeyProblem } = require("./settings");
const { RemoteService } = require("./service");
const fs = require("node:fs");
const { spawn } = require("node:child_process");
const { TITLES, downloadURL, programOf } = require("./models");
const { createConnector } = require("./connect");
const { createUia } = require("./uia");
const { createConcealedWriter } = require("./concealed");
const { parseAccess, howToConnect, findPhones, isPhone } = require("./access");
const { SecretBuffer } = require("./secret");
const { createHud } = require("./hud");
const editor = require("./editor");
const templates = require("./templates");
const lists = require("./lists");
const { createSecretClipboard } = require("./clipboard");

const UI = path.join(__dirname, "ui");
const PRELOAD = path.join(UI, "preload.js");

// "Win+Shift+A" → ускоритель Electron "Super+Shift+A"; "Ctrl+Alt+A" → "Control+Alt+A".
const accelerator = (hotkey) => String(hotkey).replace(/\bctrl\b/i, "Control").replace(/\bwin\b/i, "Super");

// Только файлы списка и сами программы: окно и страницы не могут направить приложение на произвольный путь.
const LIST_FILE = /\.(xlsx|xlsm|xml)$/i;
const PROGRAM_FILE = { anyDesk: /(^|[\\/])AnyDesk\.exe$/i, teamViewer: /(^|[\\/])TeamViewer\.exe$/i };
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
// options: { icon, userData, connector?, editor?, templates?, hud?, log?, copyText?, clipboard?, writeConcealed? } — copyText(text) кладёт в
// буфер обмена ID TeamViewer или адрес RDP (передаётся из main.js; пароль через него не идёт); clipboard — буфер для секретов
// («Скопировать пароль учётки», «Доступ»: очищается через 30 с), по умолчанию — electron.clipboard; writeConcealed(secret) →
// Promise<boolean> кладёт секрет в буфер мимо журнала Win+V и облака. Возвращает управляющий объект (тесты и main.js).
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
  const connector = options.connector || createConnector({ exists: fs.existsSync, customPaths: () => settings.data.programPaths, spawn,
    uia: createUia(spawn), hud, openExternal: (url) => shell.openExternal(url), log, copyText: options.copyText });
  // Секреты (пароль учётки, «Доступ», пароль или ключ VPN) — в буфер только мимо журнала буфера Windows и облачной синхронизации
  // (W2-5). Не Windows — журнала Win+V нет, помощника тоже (null): там секрет пишется обычным текстом (сборка для разработки).
  const writeConcealed = options.writeConcealed || (process.platform === "win32" ? createConcealedWriter(spawn) : null);
  const service = new RemoteService({ settings, store, connector });
  const secretClipboard = createSecretClipboard({ clipboard: options.clipboard || electron.clipboard, writeConcealed });
  const copyPlain = (text) => {
    if (typeof options.copyText === "function") { try { return options.copyText(String(text)) !== false; } catch (_) { return false; } }
    try { electron.clipboard.writeText(String(text)); return true; } catch (_) { return false; }
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
      paletteRef = new BrowserWindow({ width: 700, height: 460, frame: false, resizable: false, show: false, alwaysOnTop: true, skipTaskbar: true,
        transparent: true, hasShadow: false, webPreferences: secure });
      lock(paletteRef);
      paletteRef.loadFile(path.join(UI, "remote.html"), { hash: "palette" });
      paletteRef.on("blur", () => { if (alive(paletteRef)) paletteRef.hide(); });
      paletteRef.on("closed", () => { paletteRef = null; });
    }
    // По центру экрана с курсором.
    try {
      const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()), b = display.workArea;
      paletteRef.setBounds({ x: Math.round(b.x + (b.width - 700) / 2), y: Math.round(b.y + b.height * 0.2), width: 700, height: 460 });
    } catch (_) {}
    paletteRef.show(); paletteRef.focus();
    paletteRef.webContents.send("rc:show");
  }

  // Клавиша и значок в трее живут, только пока выбран файл: без него функции не видно, и сочетание ни у кого не отнимается.
  function applyEnabled() {
    if (registered) { try { globalShortcut.unregister(registered); } catch (_) {} registered = ""; }
    const on = !!settings.data.file;
    hotkeyOk = true;
    if (on) {
      const problem = hotkeyProblem(settings.data.hotkey);
      if (problem === "noModifier" || problem === "noKey") hotkeyOk = false;
      else {
        const want = accelerator(settings.data.hotkey);
        try { hotkeyOk = !!globalShortcut.register(want, openPalette); } catch (_) { hotkeyOk = false; }
        if (hotkeyOk) registered = want;
      }
      if (!hotkeyOk) log("горячая клавиша не зарегистрирована");
      buildTray();
    } else if (tray) { try { tray.destroy?.(); } catch (_) {} tray = null; }
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

  // Меню в трее: избранное, недавние (названия — из файла, показываются только в меню), «Открыть список», внизу — только «Обновить».
  // «Открыть в Excel», папка, «Добавить» и строка «Загружено N · пропущено …» с диагностикой — в окне списка и его настройках.
  function trayTemplate() {
    const view = service.view();
    const items = [{ label: "Открыть список…", click: openWindow }, { label: `Поиск (${settings.data.hotkey})`, click: openPalette }, { type: "separator" }];
    const flat = view.sections.filter((s) => s.kind === "favorites" || s.kind === "recents");
    for (const s of flat) {
      items.push({ label: s.kind === "favorites" ? "Избранное" : "Недавние", enabled: false });
      for (const r of s.records) items.push({ label: r.id ? `${r.name} · ${r.id}` : r.name, click: () => connect(r.key, false, true) });
    }
    if (flat.length) items.push({ type: "separator" });
    items.push({ label: "↻ Обновить", click: () => store.reload() });
    return items;
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

  // Адрес RDP из «Доступа» (запись не RDP, но в «Доступе» есть строка RDP): файл читается заново, окну адрес не доверяем.
  async function accessRDPAddress(key) {
    let secret = null;
    try { secret = await service.secret(key, "access"); } catch (_) { secret = null; }
    if (!secret) return null;
    try { return parseAccess(secret.bytes.toString("utf8")).rdp?.address || null; } finally { secret.wipe(); }
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

  // Пароль или ключ VPN из строк «Доступа» — файл читается заново, окну он не передаётся. SecretBuffer или null.
  async function vpnSecret(key) {
    let access = null;
    try { access = await service.secret(key, "access"); } catch (_) { access = null; }
    if (!access) return null;
    try { const value = parseAccess(access.bytes.toString("utf8")).vpn?.secret; return value ? new SecretBuffer(value) : null; }
    finally { access.wipe(); }
  }

  const COPY_TITLES = { accountPassword: "Пароль учётки скопирован", access: "«Доступ» скопирован", vpnSecret: "Пароль VPN скопирован" };
  // Пароль учётки, «Доступ» или пароль/ключ VPN — из файла сейчас, в буфер на 30 с (мимо журнала Win+V). В журнал — только код поля.
  async function copySecret(key, field) {
    if (!Object.hasOwn(COPY_TITLES, field)) return { ok: false, error: "field" };
    let secret = null;
    try { secret = field === "vpnSecret" ? await vpnSecret(key) : await service.secret(key, field); } catch (_) { secret = null; }
    try {
      if (!secret) {
        hud.show({ kind: "warning", title: "Не удалось прочитать файл", detail: "Проверьте, что файл на месте, и повторите.", actions: [{ id: "close", label: "Закрыть" }] });
        log(`copy fail field=${field}`);
        return { ok: false, error: "unavailable" };
      }
      const ok = await secretClipboard.copy(secret);
      hud.show(ok ? { kind: "success", title: COPY_TITLES[field], detail: "Буфер очистится через 30 с. В журнал буфера Windows не попадает.", autoHideMs: 2500 }
                  : { kind: "warning", title: "Не удалось скопировать", detail: "Буфер обмена недоступен — секрет не скопирован.", actions: [{ id: "close", label: "Закрыть" }] });
      log(`copy ${ok ? "ok" : "fail"} field=${field}`);
      return { ok };
    } finally { secret?.wipe(); }
  }

  // «Показать» в «Доступе»: текст уходит только в окно подробностей и живёт там, пока они открыты.
  async function revealAccess(key) {
    let secret = null;
    try { secret = await service.secret(key, "access"); } catch (_) { secret = null; }
    if (!secret) return { ok: false };
    try { return { ok: true, text: secret.bytes.toString("utf8") }; } finally { secret.wipe(); }
  }

  // Адрес RDP: ID записи RDP или (fromAccess) адрес из строк «Доступа» — файл читается заново.
  async function copyAddress(key, fromAccess = false) {
    const record = service.recordByKey(key);
    if (!record) return { ok: false };
    const address = fromAccess ? await accessRDPAddress(key) : record.id;
    if (!address) return { ok: false };
    const ok = copyPlain(address);
    hud.show(ok ? { kind: "success", title: "Адрес скопирован", detail: record.name, autoHideMs: 2000 } : { kind: "warning", title: "Не удалось скопировать", detail: "Буфер обмена недоступен.", actions: [{ id: "close", label: "Закрыть" }] });
    log(`copy ${ok ? "ok" : "fail"} field=address`);
    return { ok };
  }

  // Телефон из «Контактов» (карточка подробностей): только строка вида телефона. В журнал — только код.
  function copyPhone(text) {
    if (!isPhone(text)) return { ok: false, error: "phone" };
    const ok = copyPlain(String(text).trim());
    hud.show(ok ? { kind: "success", title: "Телефон скопирован", autoHideMs: 2000 } : { kind: "warning", title: "Не удалось скопировать", detail: "Буфер обмена недоступен.", actions: [{ id: "close", label: "Закрыть" }] });
    log(`copy ${ok ? "ok" : "fail"} field=phone`);
    return { ok };
  }

  // Карточка подробностей: «Как подключиться» (из строк «Доступа»; пароль или ключ VPN — только признак) и «Контакты» (текст и
  // телефоны). Читается из файла при открытии карточки, как «Доступ»; живёт в окне, пока карточка открыта. В журнал — ничего.
  async function cardInfo(key) {
    const record = service.recordByKey(key);
    if (!record) return { ok: false };
    const p = service.present(record, "details");
    let info = null, contacts = null;
    if (record.accessLines > 0) {
      let access = null;
      try { access = await service.secret(key, "access"); } catch (_) { access = null; }
      if (access) { try { info = parseAccess(access.bytes.toString("utf8")); } finally { access.wipe(); } }
    }
    if (record.hasContacts) {
      let secret = null;
      try { secret = await service.secret(key, "contacts"); } catch (_) { secret = null; }
      if (secret) { try { const text = secret.bytes.toString("utf8"); contacts = { text, phones: findPhones(text) }; } finally { secret.wipe(); } }
    }
    const howto = howToConnect(record, info, { needsVPN: p.needsVPN, usesRDP: p.usesRDP });
    if (info?.vpn) info.vpn.secret = null;
    return { ok: true, howto, contacts };
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
    const picked = await dialog.showOpenDialog(alive(windowRef) ? windowRef : undefined, { title: "Файл подключений", properties: ["openFile"],
      filters: [{ name: "Список подключений", extensions: ["xlsx", "xml"] }] });
    if (picked.canceled || !picked.filePaths[0]) return "";
    if (!LIST_FILE.test(picked.filePaths[0])) return "";
    settings.update({ file: picked.filePaths[0], sheet: "" });
    service.start();
    applyEnabled();
    notifyViews();
    return picked.filePaths[0];
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
  ipcMain.handle("rc:copySecret", guarded((_e, q) => copySecret(String(q?.key), String(q?.field)), { ok: false }));
  ipcMain.handle("rc:copyAddress", guarded((_e, q) => copyAddress(String(q?.key), !!q?.fromAccess), { ok: false }));
  ipcMain.handle("rc:copyPhone", guarded((_e, text) => copyPhone(String(text ?? "")), { ok: false }));
  ipcMain.handle("rc:cardInfo", guarded((_e, key) => cardInfo(String(key)), { ok: false }));
  ipcMain.handle("rc:openRDP", guarded((_e, q) => openRDP(String(q?.key), !!q?.fromAccess), { ok: false, error: "denied" }));
  ipcMain.handle("rc:showFolder", guarded(() => showFolder()));
  ipcMain.handle("rc:rowMenu", guarded((event, key) => popupRowMenu(event, String(key)), false));
  ipcMain.handle("rc:toggleFavorite", guarded((_e, key) => service.toggleFavorite(String(key)), false));
  ipcMain.handle("rc:connect", guarded((_e, q) => connect(String(q?.key), !!q?.noPassword), { ok: false, error: "denied" }));
  ipcMain.handle("rc:openFile", guarded(() => openFile()));
  ipcMain.handle("rc:reload", guarded(() => store.reload()));
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
  // Вход без файла (трея и горячей клавиши ещё нет): пункт «Удалённые подключения» в меню окна Share (меню скрыто, видно по Alt).
  // Из него сразу выбирают файл или создают шаблон; после выбора открывается список.
  const entryMenu = () => [
    { label: "Открыть список…", click: openWindow },
    { type: "separator" },
    { label: "Выбрать файл…", click: async () => { if (await chooseFile()) openWindow(); } },
    { label: "Создать шаблон .xlsx…", click: async () => { if (await createTemplate("xlsx")) openWindow(); } },
    { label: "Создать шаблон .xml…", click: async () => { if (await createTemplate("xml")) openWindow(); } },
  ];
  try {
    const menu = Menu.getApplicationMenu?.();
    if (menu && MenuItem) { menu.append(new MenuItem({ label: "Удалённые подключения", submenu: entryMenu() })); Menu.setApplicationMenu(menu); }
  } catch (_) {}

  return {
    service, settings, store, entryMenu, openWindow, openPalette, registerHotkey, trayTemplate, rowMenuTemplate, connect, openRDP, copySecret, copyAddress, copyPhone, cardInfo, revealAccess, hudAction, writeConcealed, titles: TITLES,
    get hotkeyOk() { return hotkeyOk; },
    dispose() { try { globalShortcut.unregisterAll?.(); } catch (_) {} secretClipboard.flush(); store.stop(); tray?.destroy?.(); },
  };
}

module.exports = { init, accelerator };
