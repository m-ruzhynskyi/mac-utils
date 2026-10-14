// Mac Utils Share для Windows: трансляция экрана по коду и просмотр чужих трансляций.
// Интерфейс — страница ретранслятора (та же, что в браузере), приложение добавляет:
// выбор экрана или окна с превью, системный звук (loopback) и автообновление.
const { app, BrowserWindow, desktopCapturer, ipcMain, session, dialog, shell, screen } = require("electron");
const { autoUpdater } = require("electron-updater");
const path = require("path");

const RELAY = "https://mac-utils-relay.mako-62d.workers.dev/";
let window = null;
let chosen = null; // { source, audio }
let overlay = null; // прозрачное окно поверх экрана ведущего: метки и рисунки зрителей

// Окно для меток: на весь экран, который транслируется (для окна — основной экран), сквозь него кликается.
function showOverlay() {
  const displays = screen.getAllDisplays();
  const display = displays.find((d) => String(d.id) === String(chosen?.source?.display_id)) || screen.getPrimaryDisplay();
  if (!overlay || overlay.isDestroyed()) {
    overlay = new BrowserWindow({
      ...display.bounds,
      transparent: true, frame: false, resizable: false, movable: false, focusable: false,
      skipTaskbar: true, hasShadow: false, alwaysOnTop: true,
      webPreferences: { contextIsolation: true, preload: path.join(__dirname, "overlay-preload.js") },
    });
    overlay.setAlwaysOnTop(true, "screen-saver");
    overlay.setIgnoreMouseEvents(true);
    overlay.loadFile(path.join(__dirname, "overlay.html"));
  } else {
    overlay.setBounds(display.bounds);
  }
  overlay.showInactive();
}

function hideOverlay() {
  if (overlay && !overlay.isDestroyed()) overlay.close();
  overlay = null;
}

if (!app.requestSingleInstanceLock()) app.quit();

function createWindow() {
  window = new BrowserWindow({
    width: 1200,
    height: 760,
    backgroundColor: "#111111",
    title: "Mac Utils Share",
    autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, "preload.js"), contextIsolation: true },
  });
  window.loadURL(RELAY).catch(() => window.loadFile(path.join(__dirname, "offline.html")));
  window.webContents.on("did-fail-load", () => window.loadFile(path.join(__dirname, "offline.html")));
  // Внешние ссылки — в браузере.
  window.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });
}

app.whenReady().then(() => {
  // Ретранслятор пускает только приложения Mac Utils — добавляем их метку ко всем запросам к нему
  // (и к странице, и к WebSocket). В обычном браузере трансляции недоступны.
  session.defaultSession.webRequest.onBeforeSendHeaders(
    { urls: ["https://mac-utils-relay.mako-62d.workers.dev/*", "wss://mac-utils-relay.mako-62d.workers.dev/*"] },
    (details, callback) => {
      details.requestHeaders["X-MacUtils-Client"] = "mu-share-1";
      callback({ requestHeaders: details.requestHeaders });
    }
  );

  // getDisplayMedia на странице получает то, что пользователь выбрал в нашем окне выбора.
  session.defaultSession.setDisplayMediaRequestHandler((request, callback) => {
    if (!chosen) return callback({});
    callback({ video: chosen.source, audio: chosen.audio ? "loopback" : undefined });
  });

  ipcMain.on("version", (event) => { event.returnValue = app.getVersion(); });
  ipcMain.on("hostname", (event) => { event.returnValue = require("os").hostname(); });
  // Кто-то просится смотреть — привлекаем внимание (мигание на панели задач).
  ipcMain.on("attention", () => {
    if (!window) return;
    if (window.isMinimized()) window.restore();
    window.flashFrame(true);
    window.show();
  });
  ipcMain.on("mark", (_event, mark) => {
    if (!overlay || overlay.isDestroyed()) showOverlay();
    overlay.webContents.send("mark", mark);
  });
  ipcMain.on("stopped", () => hideOverlay());

  ipcMain.handle("sources", async () => {
    const sources = await desktopCapturer.getSources({
      types: ["screen", "window"],
      thumbnailSize: { width: 400, height: 225 },
    });
    return sources.map((s) => ({ id: s.id, name: s.name, thumbnail: s.thumbnail.toDataURL() }));
  });

  ipcMain.handle("choose", async (_event, id, audio) => {
    const sources = await desktopCapturer.getSources({ types: ["screen", "window"] });
    const source = sources.find((s) => s.id === id);
    chosen = source ? { source, audio: !!audio } : null;
    return !!source;
  });

  createWindow();
  checkForUpdates();
  setInterval(checkForUpdates, 6 * 60 * 60 * 1000);
});

app.on("second-instance", () => {
  if (window) {
    if (window.isMinimized()) window.restore();
    window.focus();
  }
});

app.on("window-all-closed", () => app.quit());

// Автообновление: новые версии публикуются в релизе «windows-latest» репозитория.
function checkForUpdates() {
  if (!app.isPackaged) return;
  autoUpdater.checkForUpdates().catch(() => {});
}

autoUpdater.on("update-downloaded", async (info) => {
  const { response } = await dialog.showMessageBox(window, {
    type: "info",
    buttons: ["Перезапустить сейчас", "Позже"],
    defaultId: 0,
    message: `Доступна новая версия Mac Utils Share ${info.version}`,
    detail: "Она установится при перезапуске.",
  });
  if (response === 0) autoUpdater.quitAndInstall();
});
