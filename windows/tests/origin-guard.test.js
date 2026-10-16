const test = require("node:test");
const assert = require("node:assert/strict");
const { originOf, isTrustedSender, navigationAction } = require("../origin-guard");

const RELAY = "https://mac-utils-relay.mako-62d.workers.dev/";
const OFFLINE = "file:///C:/app/resources/app/offline.html";

test("отправитель: главный кадр со страницей relay проходит", () => {
  const main = { url: RELAY + "?x=1" };
  assert.equal(isTrustedSender(main, main, RELAY), true);
});

test("отправитель: чужой origin, вложенный кадр, пустые значения — отказ", () => {
  const main = { url: "https://evil.example/" };
  assert.equal(isTrustedSender(main, main, RELAY), false);
  const real = { url: RELAY };
  assert.equal(isTrustedSender({ url: RELAY }, real, RELAY), false); // другой кадр (iframe) с тем же адресом
  assert.equal(isTrustedSender(null, real, RELAY), false);
  assert.equal(isTrustedSender(real, null, RELAY), false);
  const file = { url: "file:///C:/app/offline.html" };
  assert.equal(isTrustedSender(file, file, RELAY), false);
});

test("отправитель: другой объект того же кадра (processId и routingId) проходит", () => {
  const main = { url: RELAY, processId: 7, routingId: 3 };
  assert.equal(isTrustedSender({ url: RELAY, processId: 7, routingId: 3 }, main, RELAY), true);
});

test("отправитель: другой routingId/processId, родитель или нет идентификаторов — отказ", () => {
  const main = { url: RELAY, processId: 7, routingId: 3 };
  assert.equal(isTrustedSender({ url: RELAY, processId: 7, routingId: 4 }, main, RELAY), false);
  assert.equal(isTrustedSender({ url: RELAY, processId: 8, routingId: 3 }, main, RELAY), false);
  assert.equal(isTrustedSender({ url: RELAY, processId: 7, routingId: 3, parent: main }, main, RELAY), false);
  assert.equal(isTrustedSender({ url: RELAY }, { url: RELAY }, RELAY), false);
  // тот же кадр, но чужой origin — по-прежнему отказ
  assert.equal(isTrustedSender({ url: "https://evil.example/", processId: 7, routingId: 3 }, main, RELAY), false);
});

test("отправитель: похожие адреса не проходят", () => {
  for (const url of [
    "http://mac-utils-relay.mako-62d.workers.dev/",
    "https://mac-utils-relay.mako-62d.workers.dev.evil.example/",
    "https://evil.example/https://mac-utils-relay.mako-62d.workers.dev/",
    "https://mac-utils-relay.mako-62d.workers.dev:8443/",
    "https://user@evil.example\\@mac-utils-relay.mako-62d.workers.dev/",
    "about:blank", "data:text/html,x", "",
  ]) {
    const f = { url };
    assert.equal(isTrustedSender(f, f, RELAY), false, url);
  }
});

test("переход: relay и offline.html разрешены", () => {
  assert.equal(navigationAction(RELAY, RELAY, OFFLINE), "allow");
  assert.equal(navigationAction(RELAY + "abc?x#y", RELAY, OFFLINE), "allow");
  assert.equal(navigationAction(OFFLINE, RELAY, OFFLINE), "allow");
});

test("переход: чужой http/https — во внешний браузер", () => {
  assert.equal(navigationAction("https://evil.example/", RELAY, OFFLINE), "external");
  assert.equal(navigationAction("http://mac-utils-relay.mako-62d.workers.dev/", RELAY, OFFLINE), "external");
  assert.equal(navigationAction("https://mac-utils-relay.mako-62d.workers.dev.evil.example/", RELAY, OFFLINE), "external");
});

test("переход: file://, javascript:, data:, другое — запрет", () => {
  for (const url of ["file:///C:/Windows/win.ini", "javascript:alert(1)", "data:text/html,x", "ms-msdt:/x", "about:blank", ""]) {
    assert.equal(navigationAction(url, RELAY, OFFLINE), "deny", url);
  }
});

test("originOf: мусор и непрозрачные origin дают null", () => {
  assert.equal(originOf("not a url"), null);
  assert.equal(originOf("data:text/html,x"), null);
  assert.equal(originOf(RELAY), "https://mac-utils-relay.mako-62d.workers.dev");
});
