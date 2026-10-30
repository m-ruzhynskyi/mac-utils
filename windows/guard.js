// Что можно странице ретранслятора в главном окне (чистые функции; main.js и tests/guard.test.cjs).
// Страница приходит из сети: если её подменят (взлом воркера или аккаунта Cloudflare, XSS, чужой корневой сертификат),
// она не должна уйти на чужой адрес вместе с мостом window.mu, открыть через систему file:, search-ms: и т. п.,
// включить камеру или микрофон, читать буфер обмена (там бывают пароли «Удалённых подключений») или звать IPC из чужого кадра.
const path = require("path");
const { fileURLToPath } = require("url");

const RELAY = "https://mac-utils-relay.mako-62d.workers.dev/";
const RELAY_ORIGIN = new URL(RELAY).origin;
// Внешние ссылки — только https и только сюда (страница ретранслятора ссылок наружу сейчас не даёт).
const EXTERNAL_HOSTS = new Set(["github.com", "mac-utils-relay.mako-62d.workers.dev"]);

function parse(url) {
  try { return new URL(String(url)); } catch (_) { return null; }
}

// Адрес страницы ретранслятора (тот же origin: схема, хост, порт).
function isRelay(url) {
  const u = parse(url);
  return !!u && u.origin === RELAY_ORIGIN;
}

// Своя локальная страница приложения: file: внутри папки приложения (offline.html, overlay.html).
function isLocal(url, dir) {
  const u = parse(url);
  if (!u || u.protocol !== "file:" || u.host) return false;
  let file;
  try { file = path.resolve(fileURLToPath(u)); } catch (_) { return false; }
  const base = path.resolve(dir) + path.sep;
  return process.platform === "win32" ? file.toLowerCase().startsWith(base.toLowerCase()) : file.startsWith(base);
}

// Куда главному окну можно перейти по действию страницы (ссылка, location, форма, редирект сервера).
const navigationAllowed = (url) => isRelay(url);

// Что можно открыть в системе (shell.openExternal): https, хост из списка, без логина и порта в адресе.
function externalAllowed(url) {
  const u = parse(url);
  return !!u && u.protocol === "https:" && EXTERNAL_HOSTS.has(u.hostname) && !u.username && !u.password && !u.port;
}

// Запрос захвата экрана: getDisplayMedia (и getUserMedia с chromeMediaSource "desktop") Electron передаёт обработчику
// разрешений как "media" с ПУСТЫМ mediaTypes — туда попадают только микрофон ("audio") и камера ("video")
// (shell/browser/web_contents_permission_helper.cc, RequestMediaAccessPermission). Отказ на нём — NotAllowedError
// «Permission denied» странице, до setDisplayMediaRequestHandler запрос не доходит.
const isCaptureRequest = (permission, details) => permission === "media" && Array.isArray(details?.mediaTypes) && details.mediaTypes.length === 0;

// Разрешения браузера: всё запрещено, кроме захвата экрана и звука (не камеры) для страницы ретранслятора.
// clipboard-sanitized-write — только запись: страница копирует свой ID по клику (navigator.clipboard.writeText);
// чтение буфера (clipboard-read и его старый вариант) запрещено.
// mediaTypes — у запроса (массив), mediaType — у проверки (строка).
// Захват экрана (isCaptureRequest) — только когда captureArmed: ведущий только что выбрал источник в окне приложения
// (или зритель переключил монитор в эфире). getUserMedia с "desktop" сам выбирает источник по ID страницы, поэтому
// без выбора ведущего он не проходит, как и getDisplayMedia.
function permissionAllowed(permission, url, details = {}, captureArmed = false) {
  if (!isRelay(url)) return false;
  if (permission === "display-capture" || permission === "clipboard-sanitized-write") return true;
  if (permission !== "media") return false;
  if (isCaptureRequest(permission, details)) return captureArmed === true;
  if (Array.isArray(details.mediaTypes)) return details.mediaTypes.every((t) => t === "audio");
  return details.mediaType === "audio";
}

// Кадр, приславший IPC (event.senderFrame): его адрес. Кадр ушёл или уничтожен — null.
function senderURL(event) {
  try { return event?.senderFrame?.url || null; } catch (_) { return null; }
}
const fromRelay = (event) => isRelay(senderURL(event));
const fromLocal = (event, dir) => isLocal(senderURL(event), dir);

module.exports = { RELAY, RELAY_ORIGIN, EXTERNAL_HOSTS, isRelay, isLocal, navigationAllowed, externalAllowed, permissionAllowed, isCaptureRequest, senderURL, fromRelay, fromLocal };
