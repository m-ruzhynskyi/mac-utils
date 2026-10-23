// «Удалённые подключения»: окно, палитра Ctrl+Alt+A, меню в трее. Единственная точка подключения к main.js — init().
// Вся логика — в service.js и соседних модулях (без Electron, с тестами); здесь только окна, трей, клавиша и IPC.
"use strict";

const path = require("node:path");
const { ConnectionsFileStore } = require("./filestore");
const { RemoteSettings } = require("./settings");
const { RemoteService } = require("./service");
const fs = require("node:fs");
const { spawn } = require("node:child_process");
const { TITLES, downloadURL, programOf } = require("./models");
const { createConnector } = require("./connect");
const { createUia } = require("./uia");
const { createHud } = require("./hud");
const editor = require("./editor");
const templates = require("./templates");

const UI = path.join(__dirname, "ui");
const PRELOAD = path.join(UI, "preload.js");

// "Ctrl+Alt+A" → ускоритель Electron "Control+Alt+A".
const accelerator = (hotkey) => String(hotkey).replace(/\bctrl\b/i, "Control").replace(/\bwin\b/i, "Super");

// electron: { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, shell, dialog, nativeImage, screen };
// options: { icon, userData, connector?, editor?, templates?, hud?, log? }. Возвращает управляющий объект (тесты и main.js).
function init(electron, options = {}) {
  const { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, shell, dialog, nativeImage, screen } = electron;
  const userData = options.userData || app.getPath("userData");
  const settings = new RemoteSettings(path.join(userData, "remote-connections.json"));
  const store = new ConnectionsFileStore(options.timing);
  const log = options.log || (() => {});
  let lastRequest = null;
  // Тост хода подключения; «успех» можно отключить в настройках (уведомление после подключения).
  const realHud = options.hud || createHud({ BrowserWindow, screen, ipcMain }, (id) => hudAction(id));
  const hud = { show(state) { if (state.kind === "success" && !settings.data.notify) return; realHud.show(state); } };
  const connector = options.connector || createConnector({ exists: fs.existsSync, customPaths: () => settings.data.programPaths, spawn,
    uia: createUia(spawn), hud, openExternal: (url) => shell.openExternal(url), log });
  const service = new RemoteService({ settings, store, connector });
  let windowRef = null, paletteRef = null, tray = null, hotkeyOk = true, registered = "";

  const alive = (w) => w && !w.isDestroyed();
  const secure = { preload: PRELOAD, contextIsolation: true, sandbox: true, nodeIntegration: false };

  function openWindow() {
    if (alive(windowRef)) { if (windowRef.isMinimized()) windowRef.restore(); windowRef.show(); windowRef.focus(); return windowRef; }
    windowRef = new BrowserWindow({ width: 760, height: 760, minWidth: 520, minHeight: 480, title: "Mac Utils · Удалённые подключения",
      autoHideMenuBar: true, backgroundColor: "#111111", icon: options.icon, webPreferences: secure });
    windowRef.loadFile(path.join(UI, "remote.html"));
    windowRef.on("closed", () => { windowRef = null; });
    return windowRef;
  }

  function openPalette() {
    if (!alive(paletteRef)) {
      paletteRef = new BrowserWindow({ width: 700, height: 460, frame: false, resizable: false, show: false, alwaysOnTop: true, skipTaskbar: true,
        transparent: true, hasShadow: false, webPreferences: secure });
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

  function registerHotkey() {
    if (registered) { try { globalShortcut.unregister(registered); } catch (_) {} registered = ""; }
    const want = accelerator(settings.data.hotkey);
    try { hotkeyOk = !!globalShortcut.register(want, openPalette); } catch (_) { hotkeyOk = false; }
    if (hotkeyOk) registered = want; else log(`горячая клавиша не зарегистрирована`);
    return hotkeyOk;
  }

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
    settings.update({ file: picked.filePaths[0], sheet: "" });
    service.start();
    return picked.filePaths[0];
  }

  function setSettings(patch) {
    const before = settings.data.file + "|" + settings.data.sheet;
    const data = settings.update(patch || {});
    if (before !== data.file + "|" + data.sheet) service.start();
    let ok = true;
    if (patch && Object.hasOwn(patch, "hotkey")) ok = registerHotkey();
    notifyViews();
    return { ...data, hotkeyOk: ok };
  }

  ipcMain.handle("rc:view", (_e, q) => service.view({ query: String(q?.query ?? ""), filter: ["anyDesk", "teamViewer"].includes(q?.filter) ? q.filter : "all" }));
  ipcMain.handle("rc:toggleFavorite", (_e, key) => service.toggleFavorite(String(key)));
  ipcMain.handle("rc:connect", (_e, q) => connect(String(q?.key), !!q?.noPassword));
  ipcMain.handle("rc:openFile", () => openFile());
  ipcMain.handle("rc:reload", () => store.reload());
  ipcMain.handle("rc:chooseFile", chooseFile);
  ipcMain.handle("rc:getSettings", () => ({ ...settings.data }));
  ipcMain.handle("rc:setSettings", (_e, patch) => setSettings(patch));
  ipcMain.handle("rc:sheets", () => store.sheetNames().catch(() => []));
  ipcMain.handle("rc:createTemplate", async (_e, kind) => (options.templates || templates).create({ kind, dialog, parent: windowRef, settings, service, setSettings }));
  ipcMain.handle("rc:edit", async (_e, q) => {
    if (q?.action === "download") { shell.openExternal(require("./models").downloadURL(q.payload === "teamViewer" ? "teamViewer" : "anyDesk")); return true; }
    return editRecord(q);
  });

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
  ipcMain.on("rc:closePalette", () => { if (alive(paletteRef)) paletteRef.hide(); });

  service.onChange(notifyViews);
  service.start();
  registerHotkey();
  buildTray();

  return {
    service, settings, store, openWindow, openPalette, registerHotkey, trayTemplate, connect, hudAction, titles: TITLES,
    get hotkeyOk() { return hotkeyOk; },
    dispose() { try { globalShortcut.unregisterAll?.(); } catch (_) {} store.stop(); tray?.destroy?.(); },
  };
}

module.exports = { init, accelerator };
