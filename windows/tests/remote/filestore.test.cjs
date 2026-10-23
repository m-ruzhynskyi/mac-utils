// Хранилище списка: нет файла, правка, замена, появление, «занят», повреждение, пароль в момент подключения.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./fixtures");
const { ConnectionsFileStore } = require("../../remote/filestore");

const FAST = { debounceMs: 30, retryMs: 40, retries: 3, pollMs: 40 };
const dir = () => fs.mkdtempSync(path.join(os.tmpdir(), "rc-"));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(store, predicate, ms = 3000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (predicate(store.state)) return store.state; await wait(15); }
  assert.fail(`состояние не достигнуто: ${JSON.stringify({ ...store.state, snapshot: store.state.snapshot && "…" })}`);
}
const rows = (n) => F.cleanRows(n);

test("файл не выбран → noFile; не существует → error unavailable", async () => {
  const store = new ConnectionsFileStore(FAST);
  assert.equal(store.state.status, "noFile");
  store.setSource(path.join(dir(), "нет.xlsx"));
  const s = await until(store, (x) => x.status === "error");
  assert.equal(s.error.code, "unavailable");
  assert.equal(s.snapshot, null);
  store.stop();
});

test("неподдерживаемый тип; xlsx и xml читаются", async () => {
  const d = dir();
  const store = new ConnectionsFileStore(FAST);
  fs.writeFileSync(path.join(d, "a.txt"), "x");
  store.setSource(path.join(d, "a.txt"));
  assert.equal((await until(store, (x) => x.status === "error")).error.code, "type");
  fs.writeFileSync(path.join(d, "a.xlsx"), F.xlsxRows(rows(5)));
  store.setSource(path.join(d, "a.xlsx"));
  assert.equal((await until(store, (x) => x.status === "ready")).snapshot.records.length, 5);
  fs.writeFileSync(path.join(d, "a.xml"), F.xmlRows(rows(4)));
  store.setSource(path.join(d, "a.xml"));
  assert.equal((await until(store, (x) => x.status === "ready" && x.snapshot.records.length === 4)).snapshot.records.length, 4);
  store.stop();
});

test("правка на месте, атомарная замена и появление файла подхватываются", async () => {
  const d = dir(), file = path.join(d, "list.xlsx");
  const store = new ConnectionsFileStore(FAST);
  store.setSource(file);                                  // файла ещё нет
  await until(store, (x) => x.status === "error");
  fs.writeFileSync(file, F.xlsxRows(rows(3)));            // появился
  await until(store, (x) => x.status === "ready" && x.snapshot.records.length === 3);
  fs.writeFileSync(file, F.xlsxRows(rows(6)));            // правка на месте
  await until(store, (x) => x.status === "ready" && x.snapshot.records.length === 6);
  for (const n of [7, 8]) {                               // замена через временный файл, как Excel
    fs.writeFileSync(path.join(d, "~$tmp"), F.xlsxRows(rows(n)));
    fs.renameSync(path.join(d, "~$tmp"), file);
    await until(store, (x) => x.status === "ready" && x.snapshot.records.length === n);
  }
  store.stop();
});

test("файл удалён → после повторов «недоступен»; повреждение сбрасывает список", async () => {
  const d = dir(), file = path.join(d, "list.xlsx");
  fs.writeFileSync(file, F.xlsxRows(rows(3)));
  const store = new ConnectionsFileStore(FAST);
  store.setSource(file);
  await until(store, (x) => x.status === "ready");
  fs.writeFileSync(file, "мусор");
  const bad = await until(store, (x) => x.status === "error");
  assert.equal(bad.error.code, "corrupt");
  assert.equal(bad.snapshot, null, "прежний список не сохраняется");
  fs.writeFileSync(file, F.xlsxRows(rows(2)));
  await until(store, (x) => x.status === "ready");
  fs.unlinkSync(file);
  assert.equal((await until(store, (x) => x.status === "error")).error.code, "unavailable");
  store.stop();
});

test("выбор листа и имена листов", async () => {
  const d = dir(), file = path.join(d, "book.xlsx");
  fs.writeFileSync(file, F.xlsx([{ name: "Пусто", rows: [[]] }, { name: "Данные", rows: rows(4).map((r) => r.map(F.cellOf)) }]));
  const store = new ConnectionsFileStore(FAST);
  store.setSource(file, "Данные");
  assert.equal((await until(store, (x) => x.status === "ready")).snapshot.records.length, 4);
  assert.deepEqual(await store.sheetNames(), ["Пусто", "Данные"]);
  store.setSource(file, "Нет такого");
  assert.equal((await until(store, (x) => x.status === "error")).error.code, "noSheet");
  store.stop();
});

test("пароль читается заново в момент подключения (после сдвига строк)", async () => {
  const d = dir(), file = path.join(d, "list.xlsx");
  fs.writeFileSync(file, F.xlsxRows([["Name", "ID", "Password"], ["A", "123456789", "pw-1"], ["B", "223456789", "pw-2"]]));
  const store = new ConnectionsFileStore(FAST);
  store.setSource(file);
  const record = (await until(store, (x) => x.status === "ready")).snapshot.records[1];
  fs.writeFileSync(file, F.xlsxRows([["Name", "ID", "Password"], ["Новая", "923456789", "x"], ["A", "123456789", "pw-1"], ["B", "223456789", "pw-2-новый"]]));
  const secret = await store.password(record);
  assert.equal(secret.bytes.toString(), "pw-2-новый");
  secret.wipe();
  fs.unlinkSync(file);
  await assert.rejects(store.password(record));
  store.stop();
});

test("чтение не создаёт файлов рядом и не меняет файл", async () => {
  const d = dir(), file = path.join(d, "list.xlsx");
  fs.writeFileSync(file, F.xlsxRows(rows(10)));
  const before = fs.readFileSync(file), mtime = fs.statSync(file).mtimeMs;
  const store = new ConnectionsFileStore(FAST);
  store.setSource(file);
  await until(store, (x) => x.status === "ready");
  await store.password((await until(store, (x) => x.status === "ready")).snapshot.records[0]);
  store.stop();
  assert.deepEqual(fs.readdirSync(d), ["list.xlsx"]);
  assert.ok(before.equals(fs.readFileSync(file)));
  assert.equal(fs.statSync(file).mtimeMs, mtime);
});
