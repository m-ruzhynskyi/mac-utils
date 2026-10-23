// Тост хода подключения: небольшое окно у панели задач, не забирает фокус (иначе ввод пароля уйдёт не туда), гаснет само.
"use strict";

const path = require("node:path");

// electron: { BrowserWindow, screen, ipcMain }; onAction(id) — нажатая кнопка.
function createHud(electron, onAction) {
  const { BrowserWindow, screen, ipcMain } = electron;
  let win = null, timer = null, last = null;
  const alive = () => win && !win.isDestroyed();

  function ensure() {
    if (alive()) return;
    win = new BrowserWindow({ width: 440, height: 160, show: false, frame: false, resizable: false, focusable: false, skipTaskbar: true, alwaysOnTop: true,
      transparent: true, hasShadow: false, webPreferences: { preload: path.join(__dirname, "ui", "hud-preload.js"), contextIsolation: true, sandbox: true, nodeIntegration: false } });
    win.setAlwaysOnTop(true, "screen-saver");
    win.loadFile(path.join(__dirname, "ui", "hud.html"));
    win.webContents.on?.("will-navigate", (event) => event.preventDefault());
    win.webContents.setWindowOpenHandler?.(() => ({ action: "deny" }));
    win.on("closed", () => { win = null; });
  }

  function place() {
    try {
      const b = screen.getPrimaryDisplay().workArea;
      win.setBounds({ x: b.x + b.width - 456, y: b.y + b.height - 176, width: 440, height: 160 });
    } catch (_) {}
  }

  ipcMain.on("rc:hudAction", (e, id) => { if (alive() && e && e.sender === win.webContents && typeof id === "string") { onAction(id, last); if (id === "close" || id === "cancel") hide(); } });

  function hide() { clearTimeout(timer); if (alive()) win.hide(); }

  // state: { kind: info|success|warning|danger, title, detail?, spinner?, progress?, actions?, autoHideMs? }
  function show(state) {
    last = state;
    ensure(); place();
    win.webContents.send("rc:hud", state);
    win.showInactive();
    clearTimeout(timer);
    // Успех гаснет за 2,5 с; ошибки висят до «Закрыть» или 12 с.
    const ms = state.autoHideMs ?? (state.kind === "danger" || state.kind === "warning" ? 12_000 : 0);
    if (ms) { timer = setTimeout(hide, ms); timer.unref?.(); }
  }

  return { show, hide };
}

module.exports = { createHud };
