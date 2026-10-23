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
const { createHud } = require("./hud");
const editor = require("./editor");
const templates = require("./templates");

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
// options: { icon, userData, connector?, editor?, templates?, hud?, log?, copyText?, writeConcealed? } — writeConcealed(secret) → Promise<boolean> кладёт секрет в буфер мимо журнала Win+V и облака; copyText(text) кладёт в буфер обмена ID
// TeamViewer, когда подключение не подтвердилось (передаётся из main.js; пароль через него не идёт). Возвращает управляющий объект (тесты и main.js).
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
  // Секреты (пароль учётки, «Доступ») — в буфер только мимо журнала буфера Windows и облачной синхронизации (W2-5). Не Windows —
  // такого помощника нет (null): секрет тогда в буфер не кладётся.
  const writeConcealed = options.writeConcealed || (process.platform === "win32" ? createConcealedWriter(spawn) : null);
  const service = new RemoteService({ settings, store, connector });
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

  // Меню в трее: избранное, недавние (названия — из файла, показываются только в меню), «Открыть список», «Excel», «Перечитать».
  function trayTemplate() {
    const view = service.view();
    const items = [{ label: "Открыть список…", click: openWindow }, { label: `Поиск (${settings.data.hotkey})`, click: openPalette }, { type: "separator" }];
    const flat = view.sections.filter((s) => s.kind === "favorites" || s.kind === "recents");
    for (const s of flat) {
      items.push({ label: s.kind === "favorites" ? "Избранное" : "Недавние", enabled: false });
      for (const r of s.records) items.push({ label: `${r.name} · ${r.id}${r.dim ? "" : ""}`, click: () => connect(r.key, false) });
    }
    if (flat.length) items.push({ type: "separator" });
    items.push({ label: "Открыть файл в Excel", click: () => openFile() }, { label: "Перечитать файл", click: () => store.reload() });
    if (view.status === "ready" && view.diagnostics && !view.diagnostics.clean) {
      const d = view.diagnostics;
      items.push({ type: "separator" }, { label: `Загружено ${d.loaded} · пропущено ${d.skippedCount} · дубликатов ${d.duplicateCount}`, click: openWindow });
    } else if (view.status === "ready" && view.diagnostics) items.push({ type: "separator" }, { label: `Загружено ${view.diagnostics.loaded}`, enabled: false });
    return items;
  }

  const notifyViews = () => {
    for (const w of [windowRef, paletteRef]) if (alive(w)) w.webContents.send("rc:changed");
    if (tray) { try { tray.setContextMenu(Menu.buildFromTemplate(trayTemplate())); } catch (_) {} }
  };

  async function connect(key, noPassword) {
    lastRequest = { key, noPassword };
    const record = service.recordByKey(key);
    if (!record) { hud.show(connector.MESSAGES.gone()); store.reload(); return { ok: false, error: "gone" }; }
    const result = await connector.connectRecord(record, { noPassword, settings: settings.data, store, service });
    if (result && result.ok) service.noteConnected(record);
    return result;
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
  ipcMain.handle("rc:view", guarded((_e, q) => service.view({ query: String(q?.query ?? ""), filter: ["anyDesk", "teamViewer"].includes(q?.filter) ? q.filter : "all" })));
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
    service, settings, store, entryMenu, openWindow, openPalette, registerHotkey, trayTemplate, connect, hudAction, writeConcealed, titles: TITLES,
    get hotkeyOk() { return hotkeyOk; },
    dispose() { try { globalShortcut.unregisterAll?.(); } catch (_) {} store.stop(); tray?.destroy?.(); },
  };
}

module.exports = { init, accelerator };
