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
// Какой монитор транслируется: по display_id источника, иначе по номеру в названии («Screen 2»), иначе основной.
function sharedDisplay() {
  const displays = screen.getAllDisplays();
  const source = chosen?.source;
  const byId = displays.find((d) => String(d.id) === String(source?.display_id || ""));
  if (byId) return byId;
  const index = /^screen:/.test(source?.id || "") ? Number((/(\d+)\s*$/.exec(source.name || "") || [])[1]) : NaN;
  if (index >= 1 && index <= displays.length) {
    // Порядок «Screen 1, 2…» у Windows — слева направо, как у мониторов по координатам.
    return [...displays].sort((a, b) => a.bounds.x - b.bounds.x || a.bounds.y - b.bounds.y)[index - 1];
  }
  return screen.getPrimaryDisplay();
}

// Окно на мониторе с другим масштабом Windows ставит не туда и не того размера — задаём границы ещё раз.
function placeOverlay(bounds) {
  if (!overlay || overlay.isDestroyed()) return;
  overlay.setBounds(bounds);
  setTimeout(() => { if (overlay && !overlay.isDestroyed()) overlay.setBounds(bounds); }, 50);
}

function showOverlay() {
  const display = sharedDisplay();
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
  }
  overlay.showInactive();
  if (!/^window:/.test(chosen?.source?.id || "")) placeOverlay(display.bounds);
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
      overlay.showInactive();
      placeOverlay(screen.screenToDipRect(null, { x, y, width, height }));
    }
  });
  tracker.on("exit", () => { tracker = null; });
}

function hideOverlay() {
  if (tracker) { tracker.kill(); tracker = null; }
  if (overlay && !overlay.isDestroyed()) overlay.close();
  overlay = null;
}

function cleanNames(list) {
  return Array.isArray(list) ? list.filter((m) => typeof m === "string" && /^[^"\\/]{1,120}$/.test(m)).slice(0, 50) : [];
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
    icon: path.join(__dirname, "assets", "icon.png"),
    autoHideMenuBar: true,
    // backgroundThrottling: false — свёрнутое окно не замедляет таймер кадров трансляции (33 мс) до ~1 раза в секунду.
    webPreferences: { preload: path.join(__dirname, "preload.js"), contextIsolation: true, backgroundThrottling: false },
  });
  // Закрыли главное окно — выходим совсем (окно меток не должно держать приложение без окна).
  window.on("closed", () => { window = null; app.quit(); });
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
    // С помощником звук всегда идёт через него — так список «не передавать» можно менять прямо в эфире.
    const audio = chosen.audio && !hasHelper() && request.audioRequested;
    callback(audio ? { video: chosen.source, audio: "loopback" } : { video: chosen.source });
  });

  // Мониторы подключили, отключили или поменяли масштаб — метки снова на нужном экране.
  for (const event of ["display-added", "display-removed", "display-metrics-changed"]) {
    screen.on(event, () => {
      if (overlay && !overlay.isDestroyed() && !/^window:/.test(chosen?.source?.id || "")) placeOverlay(sharedDisplay().bounds);
    });
  }

  ipcMain.on("version", (event) => { event.returnValue = app.getVersion(); });
  ipcMain.on("hostname", (event) => { event.returnValue = require("os").hostname(); });
  // Кто-то просится смотреть — привлекаем внимание (мигание на панели задач).
  ipcMain.on("attention", () => {
    if (!window || window.isDestroyed()) return;
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
  ipcMain.on("startAudio", (event) => startAudio(event.sender));

  // Поменяли список в эфире — перезапускаем захват звука с новым списком.
  ipcMain.on("setMuted", (event, muted) => {
    if (!chosen) return;
    chosen.muted = cleanNames(muted);
    if (audioHelper) startAudio(event.sender);
  });

  function startAudio(sender) {
    stopAudio();
    if (!chosen?.audio || !hasHelper()) return;
    const helper = spawn(HELPER, ["capture", ...chosen.muted], { windowsHide: true });
    audioHelper = helper;
    let odd = null;
    audioHelper.stdout.on("data", (chunk) => {
      let data = odd ? Buffer.concat([odd, chunk]) : chunk;
      odd = data.length % 2 ? data.subarray(data.length - 1) : null;
      if (odd) data = data.subarray(0, data.length - 1);
      if (data.length && !sender.isDestroyed()) sender.send("audio", data);
    });
    helper.on("exit", () => { if (audioHelper === helper) audioHelper = null; });
  }

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
    chosen = source ? { source, audio: !!audio, muted: cleanNames(muted) } : null;
    return !!source;
  });

  createWindow();
  checkForUpdates();
  setInterval(checkForUpdates, 6 * 60 * 60 * 1000);
});

app.on("second-instance", () => {
  if (!window || window.isDestroyed()) return app.isReady() && createWindow();
  if (window.isMinimized()) window.restore();
  window.show();
  window.focus();
});

app.on("window-all-closed", () => app.quit());
app.on("will-quit", () => { stopAudio(); hideOverlay(); });

// Автообновление: новые версии публикуются в релизе «windows-latest» репозитория.
function checkForUpdates() {
  if (!app.isPackaged) return;
  autoUpdater.checkForUpdates().catch(() => {});
}

autoUpdater.on("update-downloaded", async (info) => {
  const parent = window && !window.isDestroyed() ? window : undefined;
  const { response } = await dialog.showMessageBox(parent, {
    type: "info",
    buttons: ["Перезапустить сейчас", "Позже"],
    defaultId: 0,
    message: `Доступна новая версия Mac Utils Share ${info.version}`,
    detail: "Она установится при перезапуске.",
  });
  if (response === 0) autoUpdater.quitAndInstall();
});
