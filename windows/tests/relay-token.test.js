"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { detectToken, supportsKeys, LEGACY, KEYED } = require("../relay-token");

const BASE = "https://relay.example.com/";
const reply = (status, body, { json = true } = {}) => async (url) => ({
  ok: status >= 200 && status < 300, status, url,
  json: async () => { if (!json) throw new SyntaxError("not json"); return body; },
});

test("mu-share-2 только если relay объявил его в protocols", async () => {
  const keyed = await detectToken({ base: BASE, keysAvailable: true, fetch: reply(200, { commit: "x", protocols: ["mu-share-1", "mu-share-2"], auth: "optional" }) });
  assert.deepEqual(keyed, { token: KEYED, certain: true });
  const legacy = await detectToken({ base: BASE, keysAvailable: true, fetch: reply(200, { protocols: ["mu-share-1"] }) });
  assert.deepEqual(legacy, { token: LEGACY, certain: true });
  const requiredMode = await detectToken({ base: BASE, keysAvailable: true, fetch: reply(200, { protocols: ["mu-share-2"], auth: "required" }) });
  assert.equal(requiredMode.token, KEYED);
});

test("safeStorage недоступен: relay не опрашивается, токен mu-share-1", async () => {
  let called = false;
  const result = await detectToken({ base: BASE, keysAvailable: false, fetch: async () => { called = true; throw new Error("no"); } });
  assert.deepEqual(result, { token: LEGACY, certain: true });
  assert.equal(called, false);
});

test("запрос идёт на /version без заголовка клиента", async () => {
  let seen;
  await detectToken({ base: "https://relay.example.com/", keysAvailable: true, fetch: async (url, init) => { seen = { url, init }; return reply(200, { protocols: [] })(url); } });
  assert.equal(seen.url, "https://relay.example.com/version");
  assert.equal(seen.init.headers, undefined);
});

test("старый relay, странные ответы и нет связи: mu-share-1, неуверенный ответ не запоминается надолго", async () => {
  assert.deepEqual(await detectToken({ base: BASE, keysAvailable: true, fetch: reply(404, null) }), { token: LEGACY, certain: true });
  assert.deepEqual(await detectToken({ base: BASE, keysAvailable: true, fetch: reply(200, null, { json: false }) }), { token: LEGACY, certain: false },
    "старый relay отдаёт страницу вместо JSON (или страница входа в Wi-Fi)");
  assert.deepEqual(await detectToken({ base: BASE, keysAvailable: true, fetch: reply(200, { commit: "x" }) }), { token: LEGACY, certain: false });
  assert.deepEqual(await detectToken({ base: BASE, keysAvailable: true, fetch: reply(500, null) }), { token: LEGACY, certain: false });
  assert.deepEqual(await detectToken({ base: BASE, keysAvailable: true, fetch: async () => { throw new Error("offline"); } }), { token: LEGACY, certain: false });
});

test("зависший relay: таймаут и mu-share-1", async () => {
  const hang = (url, init) => new Promise((_, reject) => init.signal.addEventListener("abort", () => reject(new Error("aborted"))));
  const started = Date.now();
  assert.deepEqual(await detectToken({ base: BASE, keysAvailable: true, fetch: hang, timeoutMs: 30 }), { token: LEGACY, certain: false });
  assert.ok(Date.now() - started < 2000);
});

test("supportsKeys", () => {
  assert.equal(supportsKeys({ protocols: ["mu-share-2"] }), true);
  for (const bad of [null, undefined, {}, { protocols: "mu-share-2" }, { protocols: ["mu-share-1"] }, "x", []]) assert.equal(supportsKeys(bad), false);
});
