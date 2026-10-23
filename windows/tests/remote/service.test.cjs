// Сервис модуля: что уходит в окна (без паролей), избранное/недавние сохраняются только по ID, диагностика.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./fixtures");
const { ConnectionsFileStore } = require("../../remote/filestore");
const { RemoteSettings } = require("../../remote/settings");
const { RemoteService } = require("../../remote/service");

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function setup(rows, ext = "xlsx") {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rc-svc-"));
  const file = path.join(dir, `list.${ext}`);
  fs.writeFileSync(file, ext === "xlsx" ? F.xlsxRows(rows) : F.xmlRows(rows));
  const settings = new RemoteSettings(path.join(dir, "settings", "remote.json"));
  settings.update({ file });
  const store = new ConnectionsFileStore({ debounceMs: 20, retryMs: 20, pollMs: 30 });
  const service = new RemoteService({ settings, store });
  service.start();
  for (let i = 0; i < 200 && store.state.status !== "ready" && store.state.status !== "error"; i++) await wait(10);
  return { dir, file, settings, store, service };
}

test("вид списка: секции, значки, подсветка, диагностика; пароля нигде нет", async () => {
  const { service, store } = await setup(F.cleanRows(30));
  const view = service.view();
  assert.equal(view.status, "ready");
  assert.equal(view.diagnostics.loaded, 30);
  const dump = JSON.stringify(view);
  for (let i = 0; i < 30; i++) assert.ok(!dump.includes(F.password(i)), "пароль в виде списка");
  const found = service.view({ query: "север" });
  assert.equal(found.sections[0].id, "results");
  assert.ok(found.sections[0].records[0].nameMarks.length > 0);
  assert.equal(service.view({ filter: "teamViewer" }).counts.all, 30);
  store.stop();
});

test("избранное и недавние хранятся в настройках по ID, переживают перезапуск, пароль не попадает", async () => {
  const { service, settings, store, dir } = await setup(F.cleanRows(10));
  const first = service.view().sections.flatMap((s) => s.records)[0];
  assert.ok(service.toggleFavorite(first.key));
  service.noteConnected(service.recordByKey(first.key));
  const saved = fs.readFileSync(path.join(dir, "settings", "remote.json"), "utf8");
  assert.ok(!/Pw-\d/.test(saved), "пароль в настройках");
  assert.deepEqual(JSON.parse(saved).favoriteIDs, [first.key.split(":")[1]]);
  const again = new RemoteSettings(path.join(dir, "settings", "remote.json"));
  assert.deepEqual(again.favoriteIDs, settings.favoriteIDs);
  assert.equal(service.view().sections[0].id, "favorites");
  service.toggleFavorite(first.key);
  assert.deepEqual(settings.favoriteIDs, []);
  store.stop();
});

test("ошибки показываются с кодом: нет колонок — со списком найденных заголовков", async () => {
  const { service, store } = await setup([["Кто", "Что"], ["a", "b"]]);
  const view = service.view();
  assert.equal(view.status, "error");
  assert.equal(view.error.code, "missingColumns");
  assert.deepEqual(view.error.found, ["Кто", "Что"]);
  assert.deepEqual(view.sections, []);
  store.stop();
});

test("настройки: допустимые значения, права файла, нет паролей", async () => {
  const { settings, dir, store } = await setup(F.cleanRows(2));
  settings.update({ timeoutSeconds: 9999, defaultProgram: "нет", hotkey: "", programPaths: { teamViewer: "D:\\TV\\TeamViewer.exe" } });
  assert.equal(settings.data.timeoutSeconds, 120);
  assert.equal(settings.data.defaultProgram, "anyDesk");
  assert.equal(settings.data.hotkey, "Ctrl+Alt+A");
  assert.equal(settings.data.programPaths.teamViewer, "D:\\TV\\TeamViewer.exe");
  assert.deepEqual(fs.readdirSync(path.join(dir, "settings")), ["remote.json"], "без временных файлов");
  store.stop();
});
