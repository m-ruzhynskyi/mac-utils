// Mac Utils Share для Windows: трансляция экрана по коду и просмотр чужих трансляций.
// Интерфейс — страница ретранслятора (та же, что в браузере), приложение добавляет:
// выбор экрана или окна с превью, системный звук (loopback) и автообновление.
const { app, BrowserWindow, desktopCapturer, ipcMain, session, dialog, shell, screen } = require("electron");
const { autoUpdater } = require("electron-updater");
const path = require("path");
const { spawn, execFile } = require("child_process");
const fs = require("fs");
const place = require("./overlay-place");

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
// Окно меток накрывает монитор транслируемой области (`target`), а метки ставятся в саму область (overlay-place.js):
// так они не зависят от того, куда Windows на самом деле поставила окно меток. Готовится в начале трансляции, а не
// по первой метке: иначе первые метки терялись (страница меток ещё грузилась) или ложились на весь основной экран,
// пока помощник не сообщил, где окно.
let overlayReady = false; // страница меток загружена
let target = null; // транслируемая область, DIP; null — ещё не известна (окно: ждём помощника)
let trackedRect = null; // последняя рамка окна от помощника, физические пиксели
let overlayShown = false;
let sourceHidden = false; // транслируемое окно свёрнуто или скрыто: меток не показываем
const pendingMarks = [];

const sharedDisplay = () => place.sharedDisplay(chosen?.source, screen.getAllDisplays(), screen.getPrimaryDisplay());

// Числа для разбора, если метки лягут не туда: мониторы, область, окно меток. Без содержимого экрана и имён окон.
function logPlacement(event) {
  try {
    const file = path.join(app.getPath("logs"), "overlay.log");
    if (fs.existsSync(file) && fs.statSync(file).size > 256 * 1024) fs.rmSync(file);
    const rect = (r) => (r ? `${r.x},${r.y},${r.width}x${r.height}` : "-");
    const displays = screen.getAllDisplays().map((d) => `${d.id}:${rect(d.bounds)}@${d.scaleFactor}`).join(" ");
    const kind = /^window:/.test(chosen?.source?.id || "") ? "window" : "screen";
    const bounds = overlay && !overlay.isDestroyed() ? overlay.getContentBounds() : null;
    fs.appendFileSync(file, `${new Date().toISOString()} ${event} ${kind} displays=[${displays}] source=${chosen?.source?.display_id || "-"} ` +
      `target=${rect(target)} tracked=${rect(trackedRect)} overlay=${rect(bounds)}\n`);
  } catch (_) {}
}

// Разбор метки (первые 10 за трансляцию): точка зрителя, где её нарисовала страница меток (её screenX/Y, масштаб,
// точка на холсте), в физических пикселях — и в долях захваченной области. Доля `q` должна совпасть с точкой
// зрителя `p`; совпала, а у зрителя метка не там — захватывается не та область, что мы отслеживаем (сравнить
// `thumb` — пропорции захвата по Chromium — с `capture`); не совпала — видно, какая из рамок ушла.
let marksLogged = 0;
function logMark(report) {
  if (marksLogged >= 10 || !overlay || overlay.isDestroyed() || !report) return;
  marksLogged++;
  try {
    const rect = (r) => (r ? `${Math.round(r.x)},${Math.round(r.y)},${Math.round(r.width)}x${Math.round(r.height)}` : "-");
    const pair = (a) => (a ? a.map((v) => (typeof v === "number" ? +v.toFixed(4) : v)).join(";") : "-");
    const content = overlay.getContentBounds();
    const toPhysRect = (r) => (screen.dipToScreenRect ? screen.dipToScreenRect(overlay, r) : r);
    const overlayPhys = toPhysRect(content);
    const display = sharedDisplay();
    const capture = display ? (screen.dipToScreenRect ? screen.dipToScreenRect(null, display.bounds) : display.bounds) : trackedRect;
    const [cx, cy] = report.point || [0, 0];
    // Как точку видит страница меток (её положение на экране) и как её видит приложение (границы окна меток).
    const byPage = screen.dipToScreenPoint ? screen.dipToScreenPoint({ x: report.screenX + cx, y: report.screenY + cy }) : null;
    const byApp = { x: overlayPhys.x + cx * (report.dpr || 1), y: overlayPhys.y + cy * (report.dpr || 1) };
    const thumb = chosen?.source?.thumbnail?.getSize?.();
    const protectedNow = typeof overlay.isContentProtected === "function" ? overlay.isContentProtected() : "-";
    const line = `${new Date().toISOString()} mark ${display ? "screen" : "window"} p=${pair(report.mark)} ` +
      `q=${capture && byPage ? pair(place.share(byPage, capture)) : "-"} qApp=${capture ? pair(place.share(byApp, capture)) : "-"} ` +
      `capture=${rect(capture)} thumb=${thumb ? `${thumb.width}x${thumb.height}` : "-"} target=${rect(target)} ` +
      `overlay=${rect(content)} overlayPhys=${rect(overlayPhys)} page=${report.screenX},${report.screenY},${report.innerWidth}x${report.innerHeight}@${report.dpr} ` +
      `area=${report.area ? `${Math.round(report.area.x)},${Math.round(report.area.y)},${Math.round(report.area.w)}x${Math.round(report.area.h)}` : "-"} ` +
      `point=${pair(report.point)} source=${chosen?.source?.id?.split(":")[0] || "-"}:${chosen?.source?.id?.split(":")[1] || "-"} display_id=${chosen?.source?.display_id || "-"} protected=${protectedNow}`;
    fs.appendFileSync(path.join(app.getPath("logs"), "overlay.log"), line + "\n");
  } catch (_) {}
}

// Окно на мониторе с другим масштабом Windows ставит не туда и не того размера — задаём границы ещё раз.
function placeOverlay(bounds) {
  if (!overlay || overlay.isDestroyed()) return;
  overlay.setBounds(bounds);
  setTimeout(() => { if (overlay && !overlay.isDestroyed()) overlay.setBounds(bounds); }, 50);
}

// Область изменилась (или окно меток сдвинулось): окно меток — на её монитор, странице меток — где область.
function layout() {
  if (!overlay || overlay.isDestroyed() || !target) return;
  const display = screen.getDisplayMatching(target);
  if (!place.same(overlay.getBounds(), display.bounds)) placeOverlay(display.bounds);
  sendRegion();
}

function sendRegion() {
  if (!overlay || overlay.isDestroyed() || !overlayReady || !target) return;
  overlay.webContents.send("region", place.region(target, overlay.getContentBounds()));
  flushMarks();
}

function flushMarks() {
  if (!overlayReady || !target || !pendingMarks.length) return;
  if (sourceHidden) { pendingMarks.length = 0; return; }
  if (!overlayShown) {
    overlay.showInactive(); overlayShown = true;
    // Исключение из захвата ставим после показа: заданное скрытому окну (show: false) Windows может не применить,
    // и тогда метки видны в самом видео (1.1.16).
    overlay.setContentProtection(true);
  }
  for (const mark of pendingMarks.splice(0)) overlay.webContents.send("mark", mark);
}

function setTarget(rect, event) {
  target = rect;
  logPlacement(event);
  layout();
}

// Окно меток — в начале трансляции; область экрана известна сразу, область окна — после первой строки помощника.
function prepareOverlay() {
  // Окно от прошлой трансляции (отказ после выбора источника, перезагрузка страницы) — с его областью и помощником.
  hideOverlay();
  overlayReady = false; overlayShown = false; sourceHidden = false; target = null; trackedRect = null; marksLogged = 0;
  const display = sharedDisplay() || screen.getPrimaryDisplay();
  overlay = new BrowserWindow({
    ...display.bounds,
    show: false, transparent: true, frame: false, resizable: false, movable: false, focusable: false,
    skipTaskbar: true, hasShadow: false, alwaysOnTop: true,
    webPreferences: { contextIsolation: true, preload: path.join(__dirname, "overlay-preload.js") },
  });
  overlay.setAlwaysOnTop(true, "screen-saver");
  overlay.setIgnoreMouseEvents(true);
  overlay.setContentProtection(true);
  overlay.on("move", sendRegion);
  overlay.on("resize", sendRegion);
  overlay.webContents.once("did-finish-load", () => { overlayReady = true; sendRegion(); });
  overlay.loadFile(path.join(__dirname, "overlay.html"));
  if (sharedDisplay()) setTarget(sharedDisplay().bounds, "screen");
  else trackWindow();
}

// Транслируется окно — держим метки ровно над ним (id источника: «window:<HWND>:0»).
function trackWindow() {
  const match = /^window:(\d+):/.exec(chosen?.source?.id || "");
  if (!match || tracker) return;
  if (!hasHelper()) {
    // Без помощника рамку окна не узнать: метки на весь монитор — лучше, чем ничего, но в журнале видно почему.
    setTarget(screen.getPrimaryDisplay().bounds, "no-helper");
    return;
  }
  const mine = tracker = spawn(HELPER, ["track", match[1]], { windowsHide: true });
  let rest = "";
  mine.stdout.on("data", (chunk) => {
    if (mine !== tracker) return; // строки остановленного помощника
    const lines = (rest + chunk.toString()).split("\n");
    rest = lines.pop();
    for (const line of lines) {
      if (!overlay || overlay.isDestroyed()) return;
      if (line.startsWith("hidden") || line.startsWith("gone")) { overlay.hide(); overlayShown = false; sourceHidden = true; continue; }
      const [x, y, width, height] = line.trim().split(" ").map(Number);
      if (!width || !height) continue;
      trackedRect = { x, y, width, height };
      sourceHidden = false;
      setTarget(screen.screenToDipRect(null, trackedRect), "window");
      flushMarks();
    }
  });
  mine.on("exit", () => { if (tracker === mine) tracker = null; });
}

function hideOverlay() {
  if (tracker) { tracker.kill(); tracker = null; }
  if (overlay && !overlay.isDestroyed()) overlay.close();
  overlay = null; overlayReady = false; overlayShown = false; target = null; trackedRect = null;
  pendingMarks.length = 0;
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
    // backgroundThrottling: false — свёрнутое окно не замедляет захват и кодирование кадров трансляции (до 60/с) до ~1 раза в секунду.
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
    prepareOverlay();
  });

  // Мониторы подключили, отключили или поменяли масштаб — метки снова на нужном экране.
  // У окна физическая рамка та же, а DIP после смены масштаба — другие: пересчитываем из последней рамки помощника.
  for (const event of ["display-added", "display-removed", "display-metrics-changed"]) {
    screen.on(event, () => {
      if (!overlay || overlay.isDestroyed()) return;
      if (sharedDisplay()) setTarget(sharedDisplay().bounds, event);
      else if (trackedRect) setTarget(screen.screenToDipRect(null, trackedRect), event);
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
  // Метка ждёт, пока окно меток загрузится и станет известна область (не больше 50, иначе старые отбрасываются).
  ipcMain.on("mark", (_event, mark) => {
    if (!chosen) return;
    if (!overlay || overlay.isDestroyed()) prepareOverlay();
    pendingMarks.push(mark);
    if (pendingMarks.length > 50) pendingMarks.splice(0, pendingMarks.length - 50);
    flushMarks();
  });
  ipcMain.on("stopped", () => { hideOverlay(); stopAudio(); });
  ipcMain.on("overlay-report", (event, report) => { if (overlay && !overlay.isDestroyed() && event.sender === overlay.webContents) logMark(report); });

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
