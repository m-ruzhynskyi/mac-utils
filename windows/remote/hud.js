// Тост хода подключения: окно сверху по центру рабочей области (как на Mac), не забирает фокус (иначе ввод пароля уйдёт не туда),
// гаснет само. Высота — по содержимому (страница сообщает её), окно всегда целиком в workArea: кнопки не уходят под панель задач.
"use strict";

const path = require("node:path");

// Ширина, отступы и высота до первого замера страницы (DIP: масштаб Windows 125/150 % Electron учитывает сам).
const WIDTH = 460, TOP = 20, MARGIN = 12, FIRST_HEIGHT = 168;

// Место HUD: сверху по центру workArea; высота — по содержимому, но не больше workArea без отступов.
function hudBounds(workArea, height) {
  const width = Math.min(WIDTH, Math.max(240, workArea.width - 2 * MARGIN));
  const h = Math.max(60, Math.min(Math.round(height) || FIRST_HEIGHT, workArea.height - TOP - MARGIN));
  return { x: Math.round(workArea.x + (workArea.width - width) / 2), y: workArea.y + Math.min(TOP, Math.max(0, workArea.height - h)), width, height: h };
}

// electron: { BrowserWindow, screen, ipcMain }; onAction(id) — нажатая кнопка.
function createHud(electron, onAction) {
  const { BrowserWindow, screen, ipcMain } = electron;
  let win = null, timer = null, last = null, height = FIRST_HEIGHT;
  const alive = () => win && !win.isDestroyed();

  function ensure() {
    if (alive()) return;
    win = new BrowserWindow({ width: WIDTH, height: FIRST_HEIGHT, show: false, frame: false, resizable: false, focusable: false, skipTaskbar: true, alwaysOnTop: true,
      transparent: true, hasShadow: false, webPreferences: { preload: path.join(__dirname, "ui", "hud-preload.js"), contextIsolation: true, sandbox: true, nodeIntegration: false } });
    win.setAlwaysOnTop(true, "screen-saver");
    win.loadFile(path.join(__dirname, "ui", "hud.html"));
    win.webContents.on?.("will-navigate", (event) => event.preventDefault());
    win.webContents.setWindowOpenHandler?.(() => ({ action: "deny" }));
    win.on("closed", () => { win = null; });
  }

  // Монитор с курсором (там и окно программы, и пользователь); не вышло — основной.
  function workArea() {
    try { return screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea; } catch (_) {}
    return screen.getPrimaryDisplay().workArea;
  }
  function place() {
    try { win.setBounds(hudBounds(workArea(), height)); } catch (_) {}
  }

  // Страница сообщила высоту содержимого — окно подгоняется (в пределах workArea).
  ipcMain.on("rc:hudSize", (e, h) => {
    if (!alive() || !e || e.sender !== win.webContents || !Number.isFinite(h)) return;
    height = h;
    place();
  });

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

module.exports = { createHud, hudBounds };
