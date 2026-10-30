// Mac Utils Share для Windows: трансляция экрана по коду и просмотр чужих трансляций.
// Интерфейс — страница ретранслятора (та же, что в браузере), приложение добавляет:
// выбор экрана или окна с превью, системный звук (loopback) и автообновление.
const { app, BrowserWindow, desktopCapturer, ipcMain, session, dialog, shell, screen, clipboard } = require("electron");
const { autoUpdater } = require("electron-updater");
const path = require("path");
const { spawn, execFile } = require("child_process");
const fs = require("fs");
const place = require("./overlay-place");
const monitorsList = require("./displays");
const guard = require("./guard");
const marks = require("./marks");
const picker = require("./picker");

const RELAY = guard.RELAY;
let window = null;
let chosen = null; // { source, audio }
let remoteConnections = null; // модуль «Удалённые подключения» (remote/index.js)
let broadcasting = false; // идёт эфир: захват начат и страница не сообщила `stopped`
let pendingUpdate = null; // обновление скачано во время эфира: окно — после его конца
let nextSource = null; // монитор, выбранный зрителем (switchTo): его отдаст следующий getDisplayMedia страницы
let previousSource = null; // экран до этого переключения: страница не получила поток (switchTo(0)) — возвращаемся на него
let pendingNotice = null; // уведомление «‹имя› переключает на монитор N» — ждёт окна меток, как метки
let overlay = null; // прозрачное окно поверх экрана ведущего: метки и рисунки зрителей
let tracker = null; // следит, где транслируемое окно, — метки ложатся точно на него
let audioHelper = null; // звук программ без выбранных (mu-audio.exe capture …)
let audioPending = 0; // байт звука, отправленных странице и ещё не подтверждённых (audio-ack): страница подвисла — не копим
const AUDIO_PENDING_MAX = 96_000; // ≈ 2 с звука 24 кГц моно
// Выбор источника — только по действию ведущего в окне приложения: клик или клавиша, которые Windows прислала окну
// (событие input-event видит только main, страница его не подделает), не раньше показа списка и не дольше USER_ACTION_MS.
// После выбора страница может начать захват (getDisplayMedia) в течение ARM_MS; дальше — только через новый выбор.
const USER_ACTION_MS = 5000, ARM_MS = 30_000;
const USER_INPUT = new Set(["mouseDown", "mouseUp", "rawKeyDown", "keyDown", "keyUp", "char", "gestureTap", "gestureTapDown", "touchStart", "touchEnd", "pointerDown", "pointerUp"]);
let lastInput = 0, inputs = 0; // время последнего клика или клавиши в главном окне и их счётчик
let listed = null; // { ids, inputs } — источники, показанные странице последним `sources`, и счётчик кликов на тот момент
let armedUntil = 0; // до какого времени getDisplayMedia страницы получает выбранный источник
const markRate = marks.createRate();

// Помощник mu-audio.exe (native/mu-audio.cpp): звук отдельных программ и положение окон.
const HELPER = app.isPackaged ? path.join(process.resourcesPath, "mu-audio.exe") : path.join(__dirname, "bin", "mu-audio.exe");
const hasHelper = () => fs.existsSync(HELPER);

// Окно для меток: поверх того, что транслируется (экран или окно), сквозь него кликается.
// В саму трансляцию оно не попадает — иначе зритель видел бы свою метку дважды (свою и в видео).
// Окно меток ставит помощник (place) ровно на ФИЗИЧЕСКИЙ прямоугольник монитора транслируемой области, а странице меток
// область передаётся долями этого монитора (overlay-place.js). Без DIP-арифметики: окно, созданное на мониторе с другим
// масштабом, живёт с DPI основного монитора, и его DIP-границы уводят метки в сторону (журнал 1.1.17: метки левее окна).
// Готовится в начале трансляции, а не по первой метке: иначе первые метки терялись (страница меток ещё грузилась).
let overlayReady = false; // страница меток загружена
let target = null; // транслируемая область, физические пиксели; null — ещё не известна (окно: ждём помощника)
let monitor = null; // физическая рамка монитора этой области: на неё ставится окно меток
let clientRect = null; // клиентская область окна меток, если она не совпадает с рамкой (физические пиксели): доли считаются от неё
let placedOn = null; // монитор, на который окно меток поставлено (ответ помощника получен); null — метки ждут
let placing = null; // монитор, на который окно меток ставится сейчас (ждём помощника)
let placed = null; // где окно меток по словам помощника: { x, y, width, height, dpi }
let affinity = null; // исключение из захвата на окне меток по словам помощника (0x11 — исключено)
let protectOrder = 1; // 1 — защита после setIgnoreMouseEvents, 2 — до него (если первый порядок не встал)
// Метки поверх экрана — только при исключении из захвата, подтверждённом помощником (0x11). Не подтвердилось (старая
// Windows 10 — 0x1, отказ — 0x0, нет помощника) — окно меток не показывается вовсе, метки ведущий видит в окне
// приложения (страница рисует схему): иначе они попадают в видео и зритель видит каждую дважды, со сдвигом.
let marksInVideo = null; // null — ещё не проверено, false — окно меток исключено из захвата, строка — почему нет: метки идут в видео (код для журнала и страницы)
let verifyTimer = null;
const VERIFY_MS = Number(process.env.MU_OVERLAY_VERIFY_MS) || 15_000; // пока окно меток показано, исключение перепроверяется
const overlays = new Set(); // все созданные окна меток: должно жить одно
let protectErr = null, exStyle = null; // что сказал помощник о последней попытке: код ошибки Windows и расширенный стиль окна
let settled = false; // проверка защиты закончилась (исключено или нет): метки больше не ждут
let shielded = false; // защита после показа проверена помощником: до этого метки ждут, чтобы не попасть в видео
let checks = 0; // контрольных сверок рамки окна меток на этом мониторе (не больше MAX_CHECKS — без бесконечных циклов)
let checkTimer = null;
let trackedRect = null; // последняя рамка окна от помощника, физические пиксели
let overlayShown = false;
let sourceHidden = false; // транслируемое окно свёрнуто или скрыто: меток не показываем
const pendingMarks = [];
const EXCLUDE_FROM_CAPTURE = 0x11;
const MONITOR_ONLY = 0x1; // Windows 10 до 2004: вместо исключения окно в захвате чёрное
const CHECK_MS = 500, MAX_CHECKS = 3;

const sharedDisplay = () => place.sharedDisplay(chosen?.source, screen.getAllDisplays(), screen.getPrimaryDisplay());
const physOf = (display) => screen.dipToScreenRect(null, display.bounds);
const monitors = () => screen.getAllDisplays().map(physOf);

// HWND окна меток для помощника (Buffer: 8 байт на x64).
function hwndOf(win) {
  const handle = win.getNativeWindowHandle();
  return String(handle.length >= 8 ? handle.readBigUInt64LE(0) : handle.readUInt32LE(0));
}

function runHelper(args, done) {
  execFile(HELPER, args.map(String), { windowsHide: true, timeout: 3000 }, (error, stdout) => done(error ? "" : String(stdout || "")));
}

const rect = (r) => (r ? `${Math.round(r.x)},${Math.round(r.y)},${Math.round(r.width)}x${Math.round(r.height)}` : "-");
const hex = (n) => (n == null ? "-" : `0x${n.toString(16)}`);
const parsePlaced = (out) => {
  const [x, y, width, height, dpi] = out.trim().split(/\s+/).map(Number);
  return width && height ? { x, y, width, height, dpi } : null;
};
const fr = (f) => (f ? [f.fx, f.fy, f.fw, f.fh].map((v) => +v.toFixed(4)).join(";") : "-");

// Числа для разбора, если метки лягут не туда: мониторы, область, окно меток. Без содержимого экрана, имён окон и
// ID устройств: мониторы — номерами по порядку (1…), основной и транслируемый — их номера.
function logPlacement(event) {
  try {
    const file = path.join(app.getPath("logs"), "overlay.log");
    if (fs.existsSync(file) && fs.statSync(file).size > 256 * 1024) fs.rmSync(file);
    const all = screen.getAllDisplays(), primary = screen.getPrimaryDisplay(), shared = sharedDisplay();
    const number = (d) => (d ? all.findIndex((x) => x.id === d.id) + 1 || "-" : "-"); // id — только для сравнения
    const displays = all.map((d, i) => `${i + 1}:${rect(d.bounds)}@${d.scaleFactor}`).join(" ");
    const kind = /^window:/.test(chosen?.source?.id || "") ? "window" : "screen";
    fs.appendFileSync(file, `${new Date().toISOString()} ${event} ${kind} displays=[${displays}] primary=${number(primary)} source=${number(shared)} ` +
      `target=${rect(target)} monitor=${rect(monitor)} phys=${placed ? `${rect(placed)}@${placed.dpi}` : "-"} affinity=${hex(affinity)} order=${protectOrder} err=${protectErr ?? "-"} exstyle=${exStyle == null ? "-" : "0x" + exStyle.toString(16)} ` +
      `marks=${marksInVideo === null ? "-" : marksInVideo || "screen"} overlays=${overlays.size} build=${app.getVersion()} os=${require("os").release()}\n`);
  } catch (_) {}
}

// Строка в overlay.log с меткой времени; файл больше 256 КБ — начинается заново.
function appendOverlayLog(line) {
  try {
    const file = path.join(app.getPath("logs"), "overlay.log");
    if (fs.existsSync(file) && fs.statSync(file).size > 256 * 1024) fs.rmSync(file);
    fs.appendFileSync(file, `${new Date().toISOString()} ${line}\n`);
  } catch (_) {}
}
// Журнал кодера трансляции от страницы (режим hw/sw/jpeg, причина, размер, очередь, ошибки): только коды и числа —
// всё, кроме букв, цифр и знаков разметки, заменяется, длина ограничена. Начало эфира — ещё и сведения о видеокарте.
const PAGE_LOG = /[^A-Za-z0-9 =().:;,_+\-[\]]/g;
function logPage(line) {
  if (typeof line !== "string") return;
  appendOverlayLog(`page ${line.replace(PAGE_LOG, "?").slice(0, 400)}`);
  if (line.startsWith("encoder start")) logGpu();
}
// Почему не работает аппаратное кодирование: видеокарты (вендор, модель — название и PCI-код модели, драйвер; без
// LUID и других ID экземпляра), статусы ускорения Chromium (video_encode, gpu_compositing…), флаги запуска, которые
// могут его отключить, строка рендерера ANGLE (там же Direct3D и версия драйвера), гибридная графика (optimus,
// amdSwitchable) и профили аппаратного кодера, если Chromium их сообщает. Сведения «complete» собираются до 5 с;
// не успели — «basic» (там только вендор и PCI-код модели).
const GPU_VENDORS = { 0x10de: "nvidia", 0x1002: "amd", 0x1022: "amd", 0x8086: "intel", 0x1414: "microsoft", 0x5143: "qualcomm", 0x15ad: "vmware", 0x106b: "apple" };
const GPU_FLAGS = ["disable-gpu", "disable-gpu-compositing", "disable-software-rasterizer", "disable-accelerated-video-encode",
  "disable-accelerated-video-decode", "ignore-gpu-blocklist", "use-angle", "use-gl", "disable-features", "enable-features"];
const GPU_AUX = ["glRenderer", "displayType", "optimus", "amdSwitchable", "inProcessGpu", "sandboxed", "passthroughCmdDecoder"];
const clean = (v, max = 80) => String(v ?? "-").replace(PAGE_LOG, "_").replace(/ /g, "_").slice(0, max);
async function logGpu() {
  try {
    const status = Object.entries(app.getGPUFeatureStatus() || {}).map(([k, v]) => `${clean(k)}=${clean(v)}`).join(" ");
    const flags = GPU_FLAGS.filter((f) => app.commandLine?.hasSwitch(f)).map((f) => `${f}=${clean(app.commandLine.getSwitchValue(f) || "1")}`);
    const info = (await Promise.race([app.getGPUInfo("complete").catch(() => null), new Promise((resolve) => setTimeout(resolve, 5000))])) ||
      (await app.getGPUInfo("basic"));
    const devices = (info?.gpuDevice || []).map((d, i) => `${i + 1}:${GPU_VENDORS[d.vendorId] || "other"}(${hex(d.vendorId)})` +
      ` model=${hex(d.deviceId)} name=${clean(d.deviceString)} driver=${clean(d.driverVendor)}:${clean(d.driverVersion)}${d.active ? " active" : ""}`);
    appendOverlayLog(`gpu devices=[${devices.join(" ") || "-"}] status=[${status || "-"}] flags=[${flags.join(" ") || "-"}] ` +
      `electron=${clean(process.versions.electron)} chrome=${clean(process.versions.chrome)}`);
    const aux = info?.auxAttributes || {};
    const fields = Object.keys(aux).filter((k) => GPU_AUX.includes(k) || /encode/i.test(k))
      .map((k) => `${clean(k)}=${clean(typeof aux[k] === "object" ? JSON.stringify(aux[k]) : aux[k], 300)}`);
    appendOverlayLog(`gpu aux ${fields.join(" ") || "-"}`);
  } catch (_) {}
}

// Разбор метки (первые 10 за трансляцию): точка зрителя `p`, область долями окна меток `fr`, где окно меток по словам
// помощника (`phys`, физические пиксели и DPI) и где страница нарисовала метку, — в долях захваченной области `q`.
// `q` должна совпасть с `p`; совпала, а у зрителя метка не там — захватывается не та область, что мы отслеживаем.
let marksLogged = 0;
function logMark(report) {
  if (marksLogged >= 10 || !overlay || overlay.isDestroyed() || !report) return;
  marksLogged++;
  try {
    const pair = (a) => (a ? a.map((v) => (typeof v === "number" ? +v.toFixed(4) : v)).join(";") : "-");
    const [cx, cy] = report.point || [0, 0];
    // Точка холста → физические пиксели: доля окна меток × его физический размер (DPR страницы не нужен).
    const drawn = placed && report.innerWidth && report.innerHeight
      ? { x: placed.x + (cx / report.innerWidth) * placed.width, y: placed.y + (cy / report.innerHeight) * placed.height } : null;
    const area = report.area;
    const line = `${new Date().toISOString()} mark ${sharedDisplay() ? "screen" : "window"} p=${pair(report.mark)} ` +
      `q=${drawn && target ? pair(place.share(drawn, target)) : "-"} capture=${rect(target)} monitor=${rect(monitor)} ` +
      `phys=${placed ? `${rect(placed)}@${placed.dpi}` : "-"} fr=${fr(report.region)} ` +
      `page=${report.innerWidth}x${report.innerHeight}@${report.dpr} ` +
      `area=${area ? `${Math.round(area.x)},${Math.round(area.y)},${Math.round(area.w)}x${Math.round(area.h)}` : "-"} ` +
      `point=${pair(report.point)} overlay=${rect(overlay.getContentBounds())} affinity=${hex(affinity)} order=${protectOrder}`;
    fs.appendFileSync(path.join(app.getPath("logs"), "overlay.log"), line + "\n");
  } catch (_) {}
}

// По-старому, в DIP Electron (дважды: первый раз Windows считает размер по прежнему монитору).
function placeByDip(mine, want) {
  const bounds = screen.getDisplayMatching(screen.screenToDipRect(null, want)).bounds;
  mine.setBounds(bounds);
  setTimeout(() => { if (!mine.isDestroyed()) mine.setBounds(bounds); }, 50);
}

// Окно меток — на физический прямоугольник монитора. Переезд на монитор с другим DPI Windows сопровождает WM_DPICHANGED,
// и окно получает размер по новому DPI, — поэтому ответ помощника сверяется и при расхождении ставим ещё раз.
// fresh — новый монитор (а не исправление после контрольной сверки): счётчик сверок заново.
function placeOverlay(fresh = true) {
  if (!overlay || overlay.isDestroyed() || !monitor) return;
  const mine = overlay, want = monitor;
  placedOn = null; placing = want;
  if (fresh) { checks = 0; clientRect = null; }
  if (!hasHelper()) {
    placeByDip(mine, want);
    placedOn = want; placing = null; flushMarks();
    return;
  }
  const attempt = (n) => runHelper(["place", hwndOf(mine), want.x, want.y, want.width, want.height], (out) => {
    if (mine !== overlay || mine.isDestroyed() || placing !== want) return; // окно закрыто или ставится уже на другой монитор
    placed = parsePlaced(out);
    if (!place.same(placed, want) && n < 2) return attempt(n + 1);
    placedOn = want; placing = null;
    if (place.same(placed, want)) {
      clientRect = null;
      logPlacement("placed");
      scheduleCheck();
    } else {
      // Помощник окно на монитор не поставил (нет ответа, старый помощник, отказ Windows) — по-старому, в DIP.
      const away = !placed || !place.same(place.monitorOf(placed, monitors()), want);
      if (away) { placeByDip(mine, want); checks = MAX_CHECKS; } // сверять нечего: помощник окно не двигает
      // Система ужала окно (рабочая область без панели задач и т. п.): доли области считаем от фактического
      // прямоугольника окна, иначе метки уедут по вертикали (журнал: 1920x1040 вместо 1920x1080).
      else { clientRect = { x: placed.x, y: placed.y, width: placed.width, height: placed.height }; sendRegion(); }
      logPlacement(away ? "place-dip" : "place-mismatch");
    }
    flushMarks();
  });
  attempt(1);
}

// Самопроверка по ответу страницы: окно меток стоит на мониторе, а клиентская область страницы (innerWidth/Height × DPR)
// меньше — значит у окна осталась рамка или заголовок, и метка ляжет ниже и левее. Тогда доли области считаются от
// фактической клиентской области (заголовок сверху, боковые рамки поровну), в журнал — числа. Допуск: округление DPR.
function checkClient(report) {
  if (!report || !monitor || !place.same(placed, monitor) || !report.innerWidth || !report.innerHeight || !(report.dpr > 0)) return;
  const width = Math.round(report.innerWidth * report.dpr), height = Math.round(report.innerHeight * report.dpr);
  const dw = monitor.width - width, dh = monitor.height - height;
  const tolerance = (size) => Math.max(12, size * 0.01);
  if (Math.abs(dw) <= tolerance(monitor.width) && Math.abs(dh) <= tolerance(monitor.height)) return;
  if (dw < 0 || dh < 0) return; // страница больше окна — не рамка, трогать нечего
  const side = Math.round(dw / 2);
  const next = { x: monitor.x + side, y: monitor.y + Math.max(0, dh - side), width, height };
  if (place.same(clientRect, next)) return;
  clientRect = next;
  appendOverlayLog(`client-mismatch monitor=${rect(monitor)} client=${rect(next)} page=${report.innerWidth}x${report.innerHeight}@${report.dpr}`);
  sendRegion();
}

// Контрольная сверка: Chromium может поменять рамку окна меток уже после ответа помощника (WM_DPICHANGED обработан
// позже, move/resize окна). Через CHECK_MS после постановки или последнего move/resize помощник ставит окно ещё раз и
// сверяет; ушло — ставим заново. Не больше MAX_CHECKS сверок на монитор: без бесконечных циклов.
function scheduleCheck() {
  if (!hasHelper() || checks >= MAX_CHECKS || !overlay || overlay.isDestroyed()) return;
  const mine = overlay;
  clearTimeout(checkTimer);
  checkTimer = setTimeout(() => {
    if (mine !== overlay || mine.isDestroyed() || !overlayShown || placing || !placedOn) return;
    const want = placedOn;
    checks++;
    runHelper(["place", hwndOf(mine), want.x, want.y, want.width, want.height], (out) => {
      if (mine !== overlay || mine.isDestroyed() || placing || placedOn !== want) return;
      // place сама ставит окно на место: сошлось — сверка в журнал (place-check), нет — ставим заново (place-drift).
      const got = parsePlaced(out);
      if (place.same(got, want)) return logPlacement("place-check");
      placed = got;
      logPlacement("place-drift");
      placeOverlay(false);
    });
  }, CHECK_MS);
}

// Исключение из захвата ставит само приложение: SetWindowDisplayAffinity принимает только окна своего процесса.
// Помощник читает, что встало (GetWindowDisplayAffinity читает окно любого процесса). Не 0x11 — второй порядок:
// защита до setIgnoreMouseEvents (тот переписывает расширенный стиль окна), затем снова сквозные клики. И после него
// не 0x11 — метки всё равно показываем (`marksIntoVideo`): ведущая должна их видеть; зрители узнают, что метки идут в видео.
function protectOverlay() {
  const mine = overlay;
  mine.setIgnoreMouseEvents(true);
  mine.setContentProtection(true);
  if (!hasHelper()) return marksIntoVideo("no-helper");
  const check = (order) => runHelper(["protect", hwndOf(mine)], (out) => {
    if (mine !== overlay || mine.isDestroyed()) return;
    const match = /affinity=0x([0-9a-f]+)/i.exec(out);
    affinity = match ? parseInt(match[1], 16) : null;
    protectOrder = order;
    const err = /err=(\d+)/.exec(out), style = /exstyle=0x([0-9a-f]+)/i.exec(out);
    protectErr = err ? Number(err[1]) : null; exStyle = style ? parseInt(style[1], 16) : null;
    if (affinity !== EXCLUDE_FROM_CAPTURE && affinity !== MONITOR_ONLY && order === 1) {
      mine.setIgnoreMouseEvents(false);
      mine.setContentProtection(true);
      mine.setIgnoreMouseEvents(true);
      return check(2);
    }
    if (affinity !== EXCLUDE_FROM_CAPTURE && affinity !== MONITOR_ONLY && order === 2) {
      // Третий порядок: защита на скрытом окне, затем показ (журнал: на показанном окне affinity оставался 0x0 дважды).
      mine.hide();
      mine.setContentProtection(false);
      mine.setContentProtection(true);
      mine.showInactive();
      mine.setIgnoreMouseEvents(true);
      return check(3);
    }
    if (affinity !== EXCLUDE_FROM_CAPTURE) return marksIntoVideo(affinity === MONITOR_ONLY ? "old-windows" : affinity === null ? "no-answer" : "unprotected");
    shielded = true; settled = true;
    setMarksState(false);
    logPlacement("protect");
    scheduleVerify();
    flushMarks();
  });
  check(1);
}

// Исключение не встало: окно меток остаётся на экране — ведущий должен видеть, куда нажимают зрители, — и метки попадают
// в видео. Страница сообщает зрителям (`marks: "video"` в displays), и они свою копию метки не рисуют.
function marksIntoVideo(reason) {
  shielded = false; settled = true;
  clearTimeout(verifyTimer); verifyTimer = null;
  // WDA_MONITOR (старая Windows 10) делает окно в захвате чёрным — снимаем: лучше метка в видео, чем чёрный экран.
  if (affinity === MONITOR_ONLY && overlay && !overlay.isDestroyed()) overlay.setContentProtection(false);
  setMarksState(reason);
  logPlacement("unprotected");
  flushMarks();
}

// Где ведущий видит метки: странице — чтобы знала, идут ли метки в видео (`inVideo`). `covered` — главное окно приложения
// пересекается с транслируемой областью: тогда схема меток на странице сама попала бы в видео, и страница пишет только
// строку «… поставил метку».
let mainCovered = null;
function setMarksState(blocked) {
  if (marksInVideo === blocked) return;
  marksInVideo = blocked;
  sendMarksState();
}
function sendMarksState() {
  if (!window || window.isDestroyed()) return;
  mainCovered = mainWindowCovered();
  window.webContents.send("marks-state", { screen: true, inVideo: !!marksInVideo, reason: marksInVideo || "", covered: mainCovered });
}
// Главное окно (не свёрнутое) пересекается с транслируемой областью — в физических пикселях, как `target`.
// Области ещё нет — считаем, что пересекается (схему не показываем, пока не ясно).
function mainWindowCovered() {
  if (!window || window.isDestroyed() || window.isMinimized()) return false;
  if (!target) return true;
  const r = screen.dipToScreenRect(window, window.getBounds());
  return r.x < target.x + target.width && target.x < r.x + r.width && r.y < target.y + target.height && target.y < r.y + r.height;
}
function coveredChanged() { if (marksInVideo && mainWindowCovered() !== mainCovered) sendMarksState(); }

// Пока окно меток показано, исключение перепроверяется (смена монитора, DPI, перестановка окна Windows его не трогают
// по документации, но проверка дешёвая): ушло — заново оба порядка, не встало — метки только на странице.
function scheduleVerify() {
  clearTimeout(verifyTimer);
  if (!hasHelper() || !overlay || overlay.isDestroyed()) return;
  const mine = overlay;
  verifyTimer = setTimeout(() => {
    if (mine !== overlay || mine.isDestroyed() || !overlayShown || !shielded) return;
    runHelper(["protect", hwndOf(mine)], (out) => {
      if (mine !== overlay || mine.isDestroyed() || !overlayShown || !shielded) return;
      const match = /affinity=0x([0-9a-f]+)/i.exec(out);
      const now = match ? parseInt(match[1], 16) : null;
      if (now === EXCLUDE_FROM_CAPTURE) return scheduleVerify();
      affinity = now;
      logPlacement("protect-lost");
      shielded = false; settled = false;
      protectOverlay();
    });
  }, VERIFY_MS);
  verifyTimer.unref?.(); // проверка не держит приложение (и тесты) живыми
}

// Показ окна меток: показать, поставить на монитор (помощник), исключить из захвата. Метки ждут обоих ответов помощника.
function showOverlay() {
  overlay.showInactive(); overlayShown = true;
  placeOverlay();
  protectOverlay();
}

// Область изменилась: странице меток — где она долями окна; монитор другой — окно меток на него.
function layout() {
  if (!overlay || overlay.isDestroyed() || !target) return;
  if (overlayShown && !place.same(placedOn, monitor) && !place.same(placing, monitor)) placeOverlay();
  sendRegion();
}

function sendRegion() {
  if (!overlay || overlay.isDestroyed() || !overlayReady || !target) return;
  overlay.webContents.send("region", place.fractions(target, clientRect || monitor));
  flushMarks();
}

function flushMarks() {
  if (!overlayReady || !target || (!pendingMarks.length && !pendingNotice)) return;
  if (sourceHidden) { pendingMarks.length = 0; pendingNotice = null; return; }
  if (!overlayShown) showOverlay();
  if (!placedOn || !settled) return;
  for (const mark of pendingMarks.splice(0)) overlay.webContents.send("mark", mark);
  // Уведомление — только если исключение из захвата подтверждено помощником: иначе зрители увидели бы его в картинке
  // (без помощника и на старой Windows 10 о переключении говорит строка «В эфире» на странице).
  if (pendingNotice && affinity === EXCLUDE_FROM_CAPTURE) overlay.webContents.send("notice", pendingNotice);
  pendingNotice = null;
}

// rect — физические пиксели; монитор — тот, где большая часть области (у экрана — он сам).
function setTarget(rect, event) {
  target = rect;
  monitor = place.monitorOf(rect, monitors());
  logPlacement(event);
  layout();
  coveredChanged();
}

// Окно меток — в начале трансляции; область экрана известна сразу, область окна — после первой строки помощника.
function prepareOverlay() {
  // Окно от прошлой трансляции (отказ после выбора источника, перезагрузка страницы) — с его областью и помощником.
  hideOverlay();
  overlayReady = false; overlayShown = false; sourceHidden = false; target = null; monitor = null; trackedRect = null; marksLogged = 0;
  placedOn = null; placing = null; placed = null; clientRect = null; affinity = null; protectErr = null; exStyle = null; protectOrder = 1; shielded = false; settled = false; marksInVideo = null;
  // Окна меток прежних трансляций, если какое-то не закрылось, — закрыть: второе окно с метками было бы в видео.
  for (const old of overlays) if (!old.isDestroyed()) old.close();
  overlays.clear();
  const display = sharedDisplay() || screen.getPrimaryDisplay();
  overlay = new BrowserWindow({
    ...display.bounds,
    show: false, transparent: true, frame: false, resizable: false, movable: false, focusable: false,
    skipTaskbar: true, hasShadow: false, alwaysOnTop: true,
    // Больше рабочей области: иначе окно на весь монитор обрезается по панели задач (1235 → 1196).
    enableLargerThanScreen: true,
    webPreferences: { contextIsolation: true, preload: path.join(__dirname, "overlay-preload.js") },
  });
  const created = overlay;
  overlays.add(created);
  created.on("closed", () => overlays.delete(created));
  overlay.setAlwaysOnTop(true, "screen-saver");
  overlay.setIgnoreMouseEvents(true);
  overlay.on("move", scheduleCheck);
  overlay.on("resize", scheduleCheck);
  overlay.webContents.once("did-finish-load", () => { overlayReady = true; sendRegion(); });
  overlay.loadFile(path.join(__dirname, "overlay.html"));
  if (sharedDisplay()) setTarget(physOf(sharedDisplay()), "screen");
  else trackWindow();
}

// Транслируется окно — держим метки ровно над ним (id источника: «window:<HWND>:0»).
function trackWindow() {
  const match = /^window:(\d+):/.exec(chosen?.source?.id || "");
  if (!match || tracker) return;
  if (!hasHelper()) {
    // Без помощника рамку окна не узнать: метки на весь монитор — лучше, чем ничего, но в журнале видно почему.
    setTarget(physOf(screen.getPrimaryDisplay()), "no-helper");
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
      setTarget(trackedRect, "window");
      flushMarks();
    }
  });
  mine.on("exit", () => { if (tracker === mine) tracker = null; });
}

function hideOverlay() {
  if (tracker) { tracker.kill(); tracker = null; }
  clearTimeout(checkTimer); checkTimer = null;
  clearTimeout(verifyTimer); verifyTimer = null;
  if (overlay && !overlay.isDestroyed()) overlay.close();
  overlay = null; overlayReady = false; overlayShown = false; target = null; monitor = null; trackedRect = null;
  placedOn = null; placing = null; placed = null;
  pendingMarks.length = 0; pendingNotice = null;
}

// Программы созвонов (имена процессов Windows), как `callApps` на Mac. Дочерние процессы (Discord.exe, Teams) совпадают по имени.
const CALL_APPS = ["Discord.exe", "DiscordPTB.exe", "DiscordCanary.exe", "Telegram.exe", "Viber.exe", "WhatsApp.exe", "WhatsApp.Root.exe",
  "Zoom.exe", "CptHost.exe", "Teams.exe", "ms-teams.exe", "Skype.exe", "Slack.exe", "Webex.exe", "CiscoCollabHost.exe"];
function mutedProcesses(state) {
  const names = state.calls ? [...state.muted, ...CALL_APPS] : state.muted;
  return [...new Set(names.map((n) => n.toLowerCase()))].map((lower) => names.find((n) => n.toLowerCase() === lower));
}

function cleanNames(list) {
  return Array.isArray(list) ? list.filter((m) => typeof m === "string" && /^[^"\\/]{1,120}$/.test(m)).slice(0, 50) : [];
}

function stopAudio() {
  if (audioHelper) { audioHelper.kill(); audioHelper = null; }
}

if (!app.requestSingleInstanceLock()) app.quit();

// Любое окно приложения: без <webview> и без новых окон (главное окно ставит свой обработчик — внешние ссылки).
app.on("web-contents-created", (_e, contents) => {
  contents.on("will-attach-webview", (event) => event.preventDefault());
  contents.setWindowOpenHandler(() => ({ action: "deny" }));
});

function createWindow() {
  window = new BrowserWindow({
    width: 1200,
    height: 760,
    backgroundColor: "#111111",
    title: "Mac Utils Share",
    icon: path.join(__dirname, "assets", "icon.png"),
    autoHideMenuBar: true,
    // backgroundThrottling: false — свёрнутое окно не замедляет захват и кодирование кадров трансляции (до 60/с) до ~1 раза в секунду.
    webPreferences: { preload: path.join(__dirname, "preload.js"), contextIsolation: true, sandbox: true, nodeIntegration: false, backgroundThrottling: false },
  });
  // Закрыли главное окно — выходим совсем (окно меток не должно держать приложение без окна).
  window.on("closed", () => { window = null; app.quit(); });
  // Страница с эфиром ушла (перезагрузка, offline.html, падение): эфира больше нет.
  // Выбор источника новой странице не достаётся.
  window.webContents.on("did-start-navigation", (_e, _url, inPlace, isMainFrame) => {
    if (!isMainFrame || inPlace) return;
    if (broadcasting) { hideOverlay(); stopAudio(); endBroadcast(); }
    forgetChoice();
  });
  window.webContents.on("render-process-gone", () => { hideOverlay(); stopAudio(); forgetChoice(); endBroadcast(); });
  window.webContents.on("did-fail-load", () => endBroadcast());
  // Главное окно двигают, сворачивают — схема меток на странице только когда оно не над транслируемой областью.
  for (const event of ["move", "resize", "minimize", "restore"]) window.on(event, coveredChanged);
  // Клик или клавиша ведущего в окне — для выбора источника (USER_ACTION_MS).
  window.webContents.on("input-event", (_e, input) => { if (USER_INPUT.has(input?.type)) { lastInput = Date.now(); inputs++; } });
  // Страница уходит только на адреса ретранслятора (offline.html → «Повторить» — тоже туда); остальное не открывается.
  const stay = (event, url) => { if (!guard.navigationAllowed(event?.url ?? url)) event.preventDefault(); };
  window.webContents.on("will-navigate", stay);
  window.webContents.on("will-frame-navigate", stay);
  window.webContents.on("will-redirect", stay);
  window.loadURL(RELAY).catch(() => window.loadFile(path.join(__dirname, "offline.html")));
  window.webContents.on("did-fail-load", () => window.loadFile(path.join(__dirname, "offline.html")));
  // Новые окна не открываются; внешние ссылки — в браузере, только https и хосты из guard.EXTERNAL_HOSTS.
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (guard.externalAllowed(url)) shell.openExternal(url);
    return { action: "deny" };
  });
}

// Окна самого приложения (главное, «Удалённые подключения», палитра, HUD, окно меток): Electron 35+ на Windows больше не прячет их
// из desktopCapturer.getSources. В список выбора и в choose они не попадают — главное окно в эфире дало бы картинку в картинке.
const sourceHwnd = (id) => (/^window:(\d+):/.exec(String(id || "")) || [])[1] || null;
function withoutOwnWindows(sources) {
  const own = new Set();
  for (const win of BrowserWindow.getAllWindows?.() || []) {
    try { const hwnd = sourceHwnd(win.getMediaSourceId()); if (hwnd) own.add(hwnd); } catch (_) {}
  }
  return sources.filter((s) => !own.has(sourceHwnd(s.id)));
}

// IPC главного окна — только из кадра страницы ретранслятора (event.senderFrame.url); остальным — отказ (denied).
const relayOnly = (fn, denied) => (event, ...args) => (guard.fromRelay(event) ? fn(event, ...args) : denied);

// Захват «взведён»: ведущий выбрал источник кликом не больше ARM_MS назад или зритель в эфире переключил монитор (switchTo).
const captureArmed = () => !!chosen && (!!nextSource || Date.now() <= armedUntil);

// Выбор закончился (эфир кончился, страница ушла): источник забыт — новый захват только через новый выбор.
function forgetChoice() {
  chosen = null; listed = null; armedUntil = 0;
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

  // Разрешения браузера: всё запрещено, кроме захвата экрана и звука для страницы ретранслятора (guard.permissionAllowed).
  // Камера, чтение буфера обмена, уведомления, геолокация и прочее — нет никому, и своим локальным окнам тоже.
  // getDisplayMedia Electron 44 сначала спрашивает здесь как "media" с пустым mediaTypes и при отказе отвечает странице
  // NotAllowedError «Permission denied», до setDisplayMediaRequestHandler дело не доходит (WINNA-30). Такой запрос
  // проходит, только пока захват «взведён» выбором ведущего (captureArmed) — тот же замок, что ниже.
  session.defaultSession.setPermissionRequestHandler((contents, permission, callback, details) => {
    const armed = captureArmed();
    const allowed = guard.permissionAllowed(permission, details?.requestingUrl || contents?.getURL?.() || "", details, armed);
    if (!allowed && guard.isCaptureRequest(permission, details)) appendOverlayLog(`capture denied reason=${armed ? "origin" : "not-armed"} stage=permission`);
    callback(allowed);
  });
  session.defaultSession.setPermissionCheckHandler((contents, permission, origin, details) =>
    guard.permissionAllowed(permission, details?.requestingUrl || origin || "", details));

  // getDisplayMedia на странице получает то, что ведущий выбрал кликом (choose) не больше ARM_MS назад,
  // или монитор, на который в эфире переключил зритель (switchTo). Иначе — отказ.
  session.defaultSession.setDisplayMediaRequestHandler((request, callback) => {
    if (!captureArmed() || !guard.isRelay(request?.securityOrigin || request?.frame?.url || "")) {
      appendOverlayLog(`capture denied reason=${captureArmed() ? "origin" : "not-armed"} stage=display`);
      return callback(null);
    }
    broadcasting = true;
    // Зритель переключил монитор: тот же эфир, другой экран; окно меток (prepareOverlay) — на него.
    if (nextSource) { previousSource = chosen.source; chosen.source = nextSource; nextSource = null; }
    // Звук без выбранных программ идёт через помощник (mu-audio.exe), а не через общий loopback.
    // Звук отдаём, только если страница его просила, — иначе Chromium отменяет захват.
    // С помощником звук всегда идёт через него — так список «не передавать» можно менять прямо в эфире.
    const audio = chosen.audio && !hasHelper() && request.audioRequested;
    callback(audio ? { video: chosen.source, audio: "loopback" } : { video: chosen.source });
    prepareOverlay();
  });

  // Мониторы подключили, отключили или поменяли масштаб — метки снова на нужном экране.
  // Всё в физических пикселях: у окна рамка от помощника та же, у экрана — заново его физическая рамка.
  for (const event of ["display-added", "display-removed", "display-metrics-changed"]) {
    screen.on(event, () => {
      // Странице — список мониторов для зрителей заново.
      if (window && !window.isDestroyed()) window.webContents.send("displays-changed");
      if (!overlay || overlay.isDestroyed()) return;
      // Масштаб монитора сменился — Windows меняет и размер окна меток (WM_DPICHANGED): ставим его заново.
      placedOn = null; placing = null;
      if (sharedDisplay()) setTarget(physOf(sharedDisplay()), event);
      else if (trackedRect) setTarget(trackedRect, event);
    });
  }

  // sendSync: ответ нужен всегда (иначе страница зависнет), версия — только своим страницам.
  ipcMain.on("version", (event) => { event.returnValue = guard.fromRelay(event) || guard.fromLocal(event, __dirname) ? app.getVersion() : ""; });
  // Кто-то просится смотреть — привлекаем внимание (мигание на панели задач).
  ipcMain.on("attention", relayOnly(() => {
    if (!window || window.isDestroyed()) return;
    if (window.isMinimized()) window.restore();
    window.flashFrame(true);
    window.show();
  }));
  // Метка ждёт, пока окно меток загрузится и станет известна область (не больше 50, иначе старые отбрасываются).
  // Метка пересобирается из проверенных полей (marks.clean: форма, цвет, до 2000 точек), не больше 30 меток в секунду.
  ipcMain.on("mark", relayOnly((_event, raw) => {
    if (!chosen) return;
    const mark = marks.clean(raw);
    if (!mark || !markRate()) return;
    if (!overlay || overlay.isDestroyed()) prepareOverlay();
    pendingMarks.push(mark);
    if (pendingMarks.length > 50) pendingMarks.splice(0, pendingMarks.length - 50);
    flushMarks();
  }));
  ipcMain.on("page-log", relayOnly((event, line) => { if (window && event.sender === window.webContents) logPage(line); }));
  ipcMain.on("stopped", relayOnly(() => {
    nextSource = null; previousSource = null; hideOverlay(); stopAudio();
    forgetChoice();
    endBroadcast();
  }));
  ipcMain.on("overlay-report", (event, report) => {
    if (!overlay || overlay.isDestroyed() || event.sender !== overlay.webContents || !guard.fromLocal(event, __dirname)) return;
    checkClient(report);
    logMark(report);
  });

  // Программы, у которых сейчас есть звук, — для списка «Не передавать звук программ».
  ipcMain.handle("audioApps", relayOnly(() => new Promise((resolve) => {
    if (!hasHelper()) return resolve(null);
    execFile(HELPER, ["list"], { windowsHide: true, timeout: 5000 }, (error, stdout) => {
      try { resolve(error ? null : JSON.parse(stdout).map((a) => a.name).filter(Boolean)); } catch (_) { resolve(null); }
    });
  }), null));

  // Звук всех программ, кроме выбранных: PCM 24 кГц моно — странице, она отправляет зрителям.
  ipcMain.on("startAudio", relayOnly((event) => startAudio(event.sender)));

  // Поменяли список в эфире — перезапускаем захват звука с новым списком.
  // Звонки (Discord и др.) исключаются из звука сами (на Mac это настройка, по умолчанию выключена), пока пользователь не снимет галочку на странице ведущего: иначе собеседники
  // из того же созвона слышат себя с задержкой. Имена — процессы Windows (без учёта регистра).
  ipcMain.on("setMuteCalls", relayOnly((event, on) => {
    if (!chosen) return;
    chosen.calls = on === true;
    if (audioHelper) startAudio(event.sender);
  }));

  ipcMain.on("setMuted", relayOnly((event, muted) => {
    if (!chosen) return;
    chosen.muted = cleanNames(muted);
    if (audioHelper) startAudio(event.sender);
  }));

  ipcMain.on("audio-ack", relayOnly((_event, bytes) => { audioPending = Math.max(0, audioPending - (Number.isFinite(bytes) ? bytes : 0)); }));

  function startAudio(sender) {
    stopAudio();
    audioPending = 0;
    if (!chosen?.audio || !hasHelper()) return;
    const helper = spawn(HELPER, ["capture", ...mutedProcesses(chosen)], { windowsHide: true });
    audioHelper = helper;
    let odd = null;
    audioHelper.stdout.on("data", (chunk) => {
      let data = odd ? Buffer.concat([odd, chunk]) : chunk;
      odd = data.length % 2 ? data.subarray(data.length - 1) : null;
      if (odd) data = data.subarray(0, data.length - 1);
      // Страница не забирает звук (интерфейс завис) — пропускаем, иначе он копится в памяти и приходит пачкой.
      if (data.length && !sender.isDestroyed() && audioPending <= AUDIO_PENDING_MAX) { audioPending += data.length; sender.send("audio", data); }
    });
    helper.on("exit", () => { if (audioHelper === helper) audioHelper = null; });
  }

  // Список для выбора — после клика ведущего («Транслировать»), без снимков экрана и окон: у экрана схема мониторов,
  // у окна значок (picker.js). Снимки не нужны и не запрашиваются (thumbnailSize 0).
  ipcMain.handle("sources", relayOnly(async () => {
    if (Date.now() - lastInput > USER_ACTION_MS) { appendOverlayLog("sources denied reason=no-input"); return []; }
    const sources = withoutOwnWindows(await desktopCapturer.getSources({ types: ["screen", "window"], thumbnailSize: { width: 0, height: 0 } }));
    listed = { ids: new Set(sources.map((s) => s.id)), inputs };
    return picker.entries(sources, screen.getAllDisplays(), screen.getPrimaryDisplay());
  }, []));

  // Выбор — только из показанного списка и только по клику (клавише) ведущего после его показа: страница не может
  // молча выбрать экран. Ведущий и так кликает по плитке в окне приложения — лишнего подтверждения нет.
  ipcMain.handle("choose", relayOnly(async (_event, id, audio, muted, muteCalls) => {
    const now = Date.now();
    const reason = !listed || !listed.ids.has(id) ? "not-listed" : inputs === listed.inputs || now - lastInput > USER_ACTION_MS ? "no-input" : null;
    if (reason) { appendOverlayLog(`choose denied reason=${reason}`); forgetChoice(); return false; }
    const sources = withoutOwnWindows(await desktopCapturer.getSources({ types: ["screen", "window"], thumbnailSize: { width: 0, height: 0 } }));
    const source = sources.find((s) => s.id === id);
    chosen = source ? { source, audio: !!audio, muted: cleanNames(muted), calls: muteCalls !== false } : null;
    listed = null; armedUntil = source ? now + ARM_MS : 0;
    nextSource = null; previousSource = null;
    return !!source;
  }, false));

  // Мониторы для зрителей (SHARE-PROTOCOL §4.1): номер, основной, физические пиксели, масштаб, место в DIP — без имён
  // и ID устройств. current — номер транслируемого монитора, 0 — транслируется окно (переключать нельзя).
  ipcMain.handle("displays", relayOnly(() => {
    const all = screen.getAllDisplays();
    const list = monitorsList.list(all, screen.getPrimaryDisplay(), physOf);
    const current = /^screen:/.test(chosen?.source?.id || "") ? monitorsList.numberOf(sharedDisplay(), all) : 0;
    return { list, current };
  }, { list: [], current: 0 }));

  // Зритель выбрал монитор n: источник запоминается, страница берёт его новым getDisplayMedia. 0 — переключение не
  // состоялось: выбор забывается, а если обработчик getDisplayMedia уже отдал новый экран (и переставил окно меток), а
  // поток страница так и не получила, — источник и окно меток возвращаются на прежний экран.
  // Только в эфире (broadcasting): после эфира переключение не начнёт захват заново.
  ipcMain.handle("switchTo", relayOnly(async (event, n) => {
    nextSource = null;
    if (n === 0) {
      if (previousSource && chosen) {
        chosen.source = previousSource;
        previousSource = null;
        prepareOverlay();
      }
      return false;
    }
    previousSource = null;
    if (!broadcasting || !Number.isInteger(n) || n < 1 || !/^screen:/.test(chosen?.source?.id || "")) return false;
    const sources = await desktopCapturer.getSources({ types: ["screen"] });
    const source = monitorsList.sourceFor(n, sources, screen.getAllDisplays());
    if (!source || !chosen) return false;
    nextSource = source;
    // Chromium пускает getDisplayMedia только по действию пользователя, а переключение приходит от зрителя по сети:
    // пустой скрипт «с жестом» даёт странице активацию на несколько секунд — её новый getDisplayMedia проходит.
    // Это единственное место, где странице выдаётся активация без действия пользователя; из других обработчиков — нет.
    try { await event?.sender?.executeJavaScript("void 0", true); } catch (_) {}
    return true;
  }, false));

  // Уведомление ведущему о переключении — в окне меток нового монитора (оно исключено из захвата), 4 с.
  ipcMain.on("notice", relayOnly((_event, data) => {
    const notice = monitorsList.notice(data);
    if (!notice || !chosen) return;
    if (!overlay || overlay.isDestroyed()) prepareOverlay();
    pendingNotice = notice;
    flushMarks();
  }));

  createWindow();
  // «Удалённые подключения» — отдельный модуль (remote/): окно, палитра Ctrl+Alt+A, меню в трее. Его сбой не мешает трансляции.
  // copyText — только для ID TeamViewer, когда подключение не подтвердилось; пароли через буфер не идут. Запись в буфер в Electron 44
  // асинхронная: Promise<boolean>, ошибка — false.
  const copyText = (text) => Promise.resolve().then(() => clipboard.writeText(String(text))).then(() => true, () => false);
  try { remoteConnections = require("./remote").init(require("electron"), { icon: path.join(__dirname, "assets", "icon.png"), copyText }); } catch (_) {}
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
// Выход: секреты «Удалённых подключений» стираются из буфера до конца процесса. Чтение буфера в Electron 44 асинхронное — выход
// откладывается (preventDefault), пока очистка не закончится (не дольше QUIT_WAIT_MS), затем app.quit() ещё раз.
const QUIT_WAIT_MS = 3000;
let disposed = false;
app.on("will-quit", (event) => {
  stopAudio(); hideOverlay();
  if (disposed || !remoteConnections) return;
  disposed = true;
  event.preventDefault();
  let cleared;
  try { cleared = Promise.resolve(remoteConnections.dispose()); } catch (_) { cleared = Promise.resolve(); }
  Promise.race([cleared.catch(() => {}), new Promise((resolve) => setTimeout(resolve, QUIT_WAIT_MS))]).then(() => app.quit());
});

// Автообновление: новые версии публикуются в релизе «windows-latest» репозитория.
function checkForUpdates() {
  if (!app.isPackaged) return;
  autoUpdater.checkForUpdates().catch(() => {});
}

// Эфир кончился (страница сказала `stopped`) или страница пропала (перезагрузка, ошибка загрузки, падение отрисовки) —
// иначе `broadcasting` остался бы включённым и окно обновления не появилось бы до следующего эфира.
function endBroadcast() {
  broadcasting = false;
  if (!pendingUpdate) return;
  // Новый эфир, начатый за эти 1,5 с, окно не получает: оно придёт после его конца.
  setTimeout(() => {
    if (broadcasting || !pendingUpdate) return;
    const info = pendingUpdate; pendingUpdate = null;
    offerUpdate(info);
  }, 1500);
}

// Окно «Перезапустить» посреди эфира попало бы в трансляцию, а «Перезапустить сейчас» оборвало бы её: во время эфира
// не показываем, обновление ставится при выходе (autoInstallOnAppQuit), а окно — после конца эфира.
async function offerUpdate(info) {
  const parent = window && !window.isDestroyed() ? window : undefined;
  const { response } = await dialog.showMessageBox(parent, {
    type: "info",
    buttons: ["Перезапустить сейчас", "Позже"],
    defaultId: 0,
    message: `Доступна новая версия Mac Utils Share ${info.version}`,
    detail: "Она установится при перезапуске.",
  });
  if (response === 0) autoUpdater.quitAndInstall();
}
autoUpdater.on("update-downloaded", (info) => {
  if (broadcasting) { pendingUpdate = info; return; }
  offerUpdate(info);
});
