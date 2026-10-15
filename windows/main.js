// Mac Utils Share для Windows: трансляция экрана по коду и просмотр чужих трансляций.
// Интерфейс — страница ретранслятора (та же, что в браузере), приложение добавляет:
// выбор экрана или окна с превью, системный звук (loopback) и автообновление.
const { app, BrowserWindow, desktopCapturer, ipcMain, session, dialog, shell, screen } = require("electron");
const { autoUpdater } = require("electron-updater");
const path = require("path");
const { spawn, execFile } = require("child_process");
const fs = require("fs");

const RELAY = "https://mac-utils-relay.mako-62d.workers.dev/";
let window = null;
let chosen = null; // { source, audio }
let overlay = null; // прозрачное окно поверх экрана ведущего: метки и рисунки зрителей
let tracker = null; // следит, где транслируемое окно, — метки ложатся точно на него
let audioHelper = null; // звук программ без выбранных (mu-audio.exe capture …)

// Помощник mu-audio.exe (native/mu-audio.cpp): звук отдельных программ и положение окон.
const HELPER = app.isPackaged ? path.join(process.resourcesPath, "mu-audio.exe") : path.join(__dirname, "bin", "mu-audio.exe");
const hasHelper = () => fs.existsSync(HELPER);

// Окно для меток: поверх того, что транслируется (экран или окно), сквозь него кликается.
// В саму трансляцию оно не попадает — иначе зритель видел бы свою метку дважды (свою и в видео).
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
    overlay.setContentProtection(true);
    overlay.loadFile(path.join(__dirname, "overlay.html"));
  } else {
    overlay.setBounds(display.bounds);
  }
  overlay.showInactive();
  trackWindow();
}

// Транслируется окно — держим метки ровно над ним (id источника: «window:<HWND>:0»).
function trackWindow() {
  const match = /^window:(\d+):/.exec(chosen?.source?.id || "");
  if (!match || tracker || !hasHelper()) return;
  tracker = spawn(HELPER, ["track", match[1]], { windowsHide: true });
  let rest = "";
  tracker.stdout.on("data", (chunk) => {
    const lines = (rest + chunk.toString()).split("\n");
    rest = lines.pop();
    for (const line of lines) {
      if (!overlay || overlay.isDestroyed()) return;
      const [x, y, width, height] = line.trim().split(" ").map(Number);
      if (line.startsWith("hidden") || line.startsWith("gone")) { overlay.hide(); continue; }
      if (!width || !height) continue;
      overlay.setBounds(screen.screenToDipRect(null, { x, y, width, height }));
      overlay.showInactive();
    }
  });
  tracker.on("exit", () => { tracker = null; });
}

function hideOverlay() {
  if (tracker) { tracker.kill(); tracker = null; }
  if (overlay && !overlay.isDestroyed()) overlay.close();
  overlay = null;
}

function stopAudio() {
  if (audioHelper) { audioHelper.kill(); audioHelper = null; }
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
    // Звук без выбранных программ идёт через помощник (mu-audio.exe), а не через общий loopback.
    // Звук отдаём, только если страница его просила, — иначе Chromium отменяет захват.
    const audio = chosen.audio && !(chosen.muted || []).length && request.audioRequested;
    callback(audio ? { video: chosen.source, audio: "loopback" } : { video: chosen.source });
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
  ipcMain.on("stopped", () => { hideOverlay(); stopAudio(); });

  // Программы, у которых сейчас есть звук, — для списка «Не передавать звук программ».
  ipcMain.handle("audioApps", () => new Promise((resolve) => {
    if (!hasHelper()) return resolve(null);
    execFile(HELPER, ["list"], { windowsHide: true, timeout: 5000 }, (error, stdout) => {
      try { resolve(error ? null : JSON.parse(stdout).map((a) => a.name).filter(Boolean)); } catch (_) { resolve(null); }
    });
  }));

  // Звук всех программ, кроме выбранных: PCM 24 кГц моно — странице, она отправляет зрителям.
  ipcMain.on("startAudio", (event) => {
    stopAudio();
    if (!chosen?.audio || !chosen.muted.length || !hasHelper()) return;
    const sender = event.sender;
    audioHelper = spawn(HELPER, ["capture", ...chosen.muted], { windowsHide: true });
    let odd = null;
    audioHelper.stdout.on("data", (chunk) => {
      let data = odd ? Buffer.concat([odd, chunk]) : chunk;
      odd = data.length % 2 ? data.subarray(data.length - 1) : null;
      if (odd) data = data.subarray(0, data.length - 1);
      if (data.length && !sender.isDestroyed()) sender.send("audio", data);
    });
    audioHelper.on("exit", () => { audioHelper = null; });
  });

  ipcMain.handle("sources", async () => {
    const sources = await desktopCapturer.getSources({
      types: ["screen", "window"],
      thumbnailSize: { width: 400, height: 225 },
    });
    return sources.map((s) => ({ id: s.id, name: s.name, thumbnail: s.thumbnail.toDataURL() }));
  });

  ipcMain.handle("choose", async (_event, id, audio, muted) => {
    const sources = await desktopCapturer.getSources({ types: ["screen", "window"] });
    const source = sources.find((s) => s.id === id);
    const list = Array.isArray(muted) && hasHelper() ? muted.filter((m) => typeof m === "string" && /^[^"\\/]{1,120}$/.test(m)) : [];
    chosen = source ? { source, audio: !!audio, muted: list } : null;
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
app.on("will-quit", () => { stopAudio(); hideOverlay(); });

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
