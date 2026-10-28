// Что можно странице ретранслятора (аудит безопасности H1, L17): навигация, внешние ссылки, разрешения браузера,
// отправитель IPC, метки зрителей и список источников без снимков. Чистые функции guard.js, marks.js, picker.js;
// как main.js их подключает — в overlay.test.cjs (раздел «Безопасность главного окна»).
const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const guard = require("../guard");
const marks = require("../marks");
const picker = require("../picker");

const RELAY = "https://mac-utils-relay.mako-62d.workers.dev/";
const APP = path.join(__dirname, "..");

test("навигация главного окна — только на адреса ретранслятора", () => {
  for (const url of [RELAY, `${RELAY}?id=123`, `${RELAY}watch#x`, "https://mac-utils-relay.mako-62d.workers.dev"]) {
    assert.equal(guard.navigationAllowed(url), true, url);
  }
  for (const url of ["http://mac-utils-relay.mako-62d.workers.dev/", "https://mac-utils-relay.mako-62d.workers.dev.evil.com/",
    "https://evil.com/?u=https://mac-utils-relay.mako-62d.workers.dev/", "https://mac-utils-relay.mako-62d.workers.dev:8443/",
    "https://workers.dev/", "file:///C:/Windows/System32/calc.exe", "file://host/share/x.exe", "javascript:alert(1)", "data:text/html,<b>x</b>",
    "about:blank", "search-ms:query=x", "", null, undefined, "не адрес"]) {
    assert.equal(guard.navigationAllowed(url), false, String(url));
  }
});

test("openExternal: file:, search-ms:, javascript: и прочие схемы — отказ; https — только хосты из списка", () => {
  for (const url of ["file://\\\\host\\share\\x.exe", "file:///C:/Windows/System32/calc.exe", "file://host/share/x.exe", "search-ms:query=x&crumb=location:\\\\host\\share",
    "javascript:alert(1)", "ms-settings:privacy", "ms-msdt:/id PCWDiagnostic", "vbscript:msgbox", "data:text/html,x", "http://github.com/",
    "https://evil.com/", "https://github.com.evil.com/", "https://github.com@evil.com/", "https://user:pw@github.com/", "https://github.com:8443/",
    "\\\\host\\share\\x.exe", "C:\\Windows\\System32\\calc.exe", "", null]) {
    assert.equal(guard.externalAllowed(url), false, String(url));
  }
  for (const url of ["https://github.com/m-ruzhynskyi/mac-utils/releases", "https://mac-utils-relay.mako-62d.workers.dev/"]) {
    assert.equal(guard.externalAllowed(url), true, url);
  }
});

test("разрешения: только захват экрана и звук (не камера) для ретранслятора; чтение буфера — никому", () => {
  const allow = (permission, url, details) => guard.permissionAllowed(permission, url, details);
  assert.equal(allow("display-capture", RELAY), true);
  assert.equal(allow("media", RELAY, { mediaTypes: ["audio"] }), true, "запрос звука");
  assert.equal(allow("media", RELAY, { mediaType: "audio" }), true, "проверка звука");
  assert.equal(allow("media", RELAY, { mediaTypes: ["video"] }), false, "камера");
  assert.equal(allow("media", RELAY, { mediaTypes: ["audio", "video"] }), false, "звук вместе с камерой");
  assert.equal(allow("media", RELAY, { mediaTypes: [] }), false);
  assert.equal(allow("media", RELAY, { mediaType: "video" }), false);
  assert.equal(allow("media", RELAY, { mediaType: "unknown" }), false);
  assert.equal(allow("media", RELAY), false, "без типа — нет");
  assert.equal(allow("clipboard-sanitized-write", RELAY), true, "копирование своего ID по клику");
  for (const permission of ["clipboard-read", "deprecated-sync-clipboard-read", "notifications", "geolocation", "fullscreen", "pointerLock", "keyboardLock",
    "openExternal", "midiSysex", "hid", "usb", "serial", "window-management", "local-fonts", "idle-detection", "storage-access", "fileSystem", "unknown"]) {
    assert.equal(allow(permission, RELAY, { mediaTypes: ["audio"] }), false, permission);
  }
  const local = pathToFileURL(path.join(APP, "overlay.html")).href;
  for (const url of ["https://evil.com/", "http://mac-utils-relay.mako-62d.workers.dev/", local, "", null]) {
    assert.equal(allow("display-capture", url), false, `display-capture ${url}`);
    assert.equal(allow("media", url, { mediaTypes: ["audio"] }), false, `media ${url}`);
  }
});

test("отправитель IPC: страница ретранслятора или своя локальная страница — по адресу кадра", () => {
  const frame = (url) => ({ senderFrame: { url } });
  const local = pathToFileURL(path.join(APP, "overlay.html")).href;
  assert.equal(guard.fromRelay(frame(RELAY)), true);
  assert.equal(guard.fromRelay(frame(`${RELAY}?x=1`)), true);
  for (const event of [frame("https://evil.com/"), frame(local), frame("about:blank"), { senderFrame: null }, {}, null, undefined,
    { get senderFrame() { throw new Error("frame destroyed"); } }]) {
    assert.equal(guard.fromRelay(event), false);
  }
  assert.equal(guard.fromLocal(frame(local), APP), true);
  assert.equal(guard.fromLocal(frame(pathToFileURL(path.join(APP, "remote", "ui", "remote.html")).href), APP), true);
  assert.equal(guard.fromLocal(frame(pathToFileURL(path.join(APP, "..", "evil.html")).href), APP), false, "файл вне папки приложения");
  assert.equal(guard.fromLocal(frame(pathToFileURL(`${APP}-evil${path.sep}x.html`).href), APP), false, "папка с тем же началом имени");
  assert.equal(guard.fromLocal(frame(RELAY), APP), false);
  assert.equal(guard.fromLocal({}, APP), false);
});

test("метки (L17): форма проверяется, лишние поля отбрасываются, точек не больше 2000", () => {
  assert.deepEqual(marks.clean({ type: "ping", x: 0.25, y: 0.75, color: "blue", html: "<img onerror=x>" }), { type: "ping", x: 0.25, y: 0.75, color: "blue" });
  assert.deepEqual(marks.clean({ type: "ping", x: -3, y: 9, color: "purple" }), { type: "ping", x: 0, y: 1, color: "red" }, "координаты в 0..1, неизвестный цвет — красный");
  for (const bad of [null, undefined, 1, "ping", [], { type: "ping", x: NaN, y: 0 }, { type: "ping", x: "0.5", y: 0.5 }, { type: "ping", x: Infinity, y: 0 },
    { type: "stroke", points: [[0, 0]] }, { type: "stroke", points: "0,0;1,1" }, { type: "stroke" }, { type: "text", x: 0, y: 0 }, { type: "stroke", points: [[0, 0, 0], [1]] }]) {
    assert.equal(marks.clean(bad), null, JSON.stringify(bad) ?? String(bad));
  }
  const many = Array.from({ length: 5000 }, (_, i) => [i / 5000, 0.5]);
  const stroke = marks.clean({ type: "stroke", points: [["x", 1], ...many], color: "green" });
  assert.equal(stroke.points.length, 1999, "первые 2000 точек, из них одна негодная отброшена");
  assert.ok(stroke.points.every((p) => p.length === 2 && p.every((v) => typeof v === "number" && v >= 0 && v <= 1)));
  assert.deepEqual(Object.keys(stroke), ["type", "points", "color"]);
});

test("метки (L17): не больше 30 в секунду — лишние отбрасываются, через секунду снова идут", () => {
  let now = 1000;
  const rate = marks.createRate(marks.MAX_PER_SECOND, () => now);
  const passed = Array.from({ length: 50 }, () => rate()).filter(Boolean).length;
  assert.equal(passed, 30);
  now += 999;
  assert.equal(rate(), false);
  now += 1;
  assert.equal(rate(), true);
});

test("список источников без снимков: у экрана — схема мониторов с номером, у окна — значок; название остаётся", () => {
  const displays = [
    { id: 11, bounds: { x: 0, y: 0, width: 1920, height: 1080 }, scaleFactor: 1 },
    { id: 22, bounds: { x: -1280, y: 0, width: 1280, height: 1024 }, scaleFactor: 1 },
  ];
  const sources = [
    { id: "screen:1:0", name: "Screen 1", display_id: "22", thumbnail: { toDataURL: () => "data:image/png;base64,SECRET" } },
    { id: "screen:2:0", name: "Screen 2", display_id: "11" },
    { id: "window:4242:0", name: "Отчёт.xlsx — Excel" },
  ];
  const list = picker.entries(sources, displays, displays[0]);
  assert.deepEqual(list.map((s) => [s.id, s.name]), sources.map((s) => [s.id, s.name]));
  for (const s of list) {
    assert.match(s.thumbnail, /^data:image\/svg\+xml,/);
    assert.ok(!s.thumbnail.includes("png") && !s.thumbnail.includes("SECRET"), "снимков нет");
    assert.ok(!/["<>]/.test(s.thumbnail), "без кавычек и угловых скобок: страница вставляет адрес в <img src=\"…\">");
    assert.deepEqual(Object.keys(s), ["id", "name", "thumbnail"]);
  }
  const first = decodeURIComponent(list[0].thumbnail), second = decodeURIComponent(list[1].thumbnail);
  // Монитор слева (id 22) — номер 1 и подсвечен у первого источника; у второго подсвечен монитор 2.
  assert.match(first, /fill='#C8F05A'\/><text[^>]*>1<\/text>/);
  assert.match(second, /fill='#C8F05A'\/><text[^>]*>2<\/text>/);
  assert.equal(list[2].thumbnail, picker.WINDOW_PICTURE);
});

test("сборка: модули main.js — в build.files (иначе установленное приложение не запустится); fuses Electron включены (аудит H2)", () => {
  const fs = require("node:fs");
  const pkg = JSON.parse(fs.readFileSync(path.join(APP, "package.json"), "utf8"));
  const main = fs.readFileSync(path.join(APP, "main.js"), "utf8");
  const local = [...main.matchAll(/require\("\.\/([\w.-]+)"\)/g)].map((m) => m[1]).filter((m) => m !== "remote");
  assert.ok(local.includes("guard") && local.includes("marks") && local.includes("picker"));
  for (const name of local) assert.ok(pkg.build.files.includes(`${name}.js`), `${name}.js в build.files`);
  for (const name of ["overlay-place.js", "displays.js"]) assert.ok(pkg.build.files.includes(name), name);
  assert.deepEqual(pkg.build.electronFuses, {
    runAsNode: false, enableNodeOptionsEnvironmentVariable: false, enableNodeCliInspectArguments: false,
    enableEmbeddedAsarIntegrityValidation: true, onlyLoadAppFromAsar: true,
  });
  assert.match(pkg.devDependencies.electron, /^\d+\.\d+\.\d+$/, "Electron — точная версия");
  assert.ok(Number(pkg.devDependencies.electron.split(".")[0]) >= 44, "поддерживаемая ветка Electron");
});
