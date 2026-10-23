// Приёмка по ТЗ § 7 (.audit/tz-anydesk.md) и сверка 1:1 с Mac: те же выдуманные данные → тот же список и та же диагностика.
// Эталон parity.json делает Mac-тест AcceptanceParityTests (Tests/Fixtures/RemoteParity/parity.json); оба файла должны совпадать.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./fixtures");
const { ConnectionsFileStore } = require("../../remote/filestore");
const { load, passwordFor } = require("../../remote/source");
const { ConnectionSearch } = require("../../remote/search");
const lists = require("../../remote/lists");
const { RemoteSettings } = require("../../remote/settings");
const { RemoteService } = require("../../remote/service");

const FAST = { debounceMs: 30, retryMs: 40, retries: 3, pollMs: 40 };
const mkdir = () => fs.mkdtempSync(path.join(os.tmpdir(), "rc-acc-"));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(store, predicate, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (predicate(store.state)) return store.state; await wait(15); }
  assert.fail(`состояние не достигнуто: ${store.state.status} ${store.state.error?.code ?? ""} ${store.state.snapshot?.records.length ?? ""}`);
}
async function opened(file, timing = FAST) {
  const store = new ConnectionsFileStore(timing);
  store.setSource(file);
  await until(store, (s) => s.status === "ready");
  return store;
}
const GOLDEN = JSON.parse(fs.readFileSync(path.join(__dirname, "parity.json"), "utf8"));
const json = (v) => JSON.parse(JSON.stringify(v));

// ---------- сверка с Mac ----------

function diag(snap) {
  const d = snap.diagnostics;
  return {
    records: snap.records.map((r) => ({ row: r.sourceRow, name: r.name, id: r.id, group: r.group, tags: r.tags, note: r.note, program: r.program, hasPassword: r.hasPassword })),
    loaded: d.loaded, withPassword: d.withPassword, skipped: d.skipped.map((s) => ({ row: s.row, reason: s.reason, value: s.value })),
    duplicates: d.duplicates.map((g) => ({ id: g.id, rows: g.rows, names: g.names })), unrecognizedColumns: d.unrecognizedColumns, lossyIDRows: d.lossyIDRows,
    ambiguousProgramRows: d.ambiguousProgramRows, columns: d.columns.map((c) => ({ title: c.title, field: c.field, column: c.column })),
    clean: require("../../remote/models").isClean(d), duplicateCount: require("../../remote/models").duplicateCount(d),
  };
}
const secret = (kind, snap, data, row) => {
  const r = snap.records.find((x) => x.sourceRow === row);
  if (!r) return null;
  const s = passwordFor(r, data, kind);
  if (!s) return null;
  const text = Buffer.from(s.bytes).toString("utf8");
  s.wipe();
  return text;
};
const ID_FORMS = [
  F.number("123456789"), F.number("1234567890"), F.text("123456789"), F.inline("987654321"), F.text("123 456 789"), F.text(" 123 456 780 "),
  F.number("1.23456789E+08"), F.text("1,23456789E+08"), F.formula("111222333"), F.text("office@ad"), F.text("Front-Desk.2@Company"), F.text("12345"),
  F.text("abc"), F.text("123456789012"), F.number("1.23E+08"), F.text("0123456789"), F.text("a@b@c"), F.text("123456789.0"),
];
const HAND_XML = "﻿<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<connections>\r\n  <!-- выдуманные данные -->\r\n"
  + "  <connection><name>Аптека Захід</name><id>123 456 789</id><password>Pw-x-секрет</password><group>Філії</group></connection>\r\n"
  + "  <connection><name>Bad row</name><id>12</id></connection>\r\n"
  + "  <connection name=\"Атрибуты\" id=\"555 666 777\" app=\"TeamViewer\"/>\r\n"
  + "  <connection><name>Front</name><id>front@ad</id><tags>a, b; A</tags><note><![CDATA[n & <m>]]></note><extra>x</extra></connection>\r\n"
  + "</connections>\r\n";

test("сверка с Mac: сложные файлы xlsx и xml — записи, диагностика, пароли", () => {
  const messy = F.messyRows();
  const mx = F.xlsxRows(messy), mm = F.xmlRows(messy);
  const sx = load(mx, "xlsx"), sm = load(mm, "xml");
  assert.deepEqual(json(diag(sx)), GOLDEN["messy-xlsx"]);
  assert.deepEqual(json(diag(sm)), GOLDEN["messy-xml"]);
  const rows = [2, 3, 14, 22, 24, 18];
  assert.deepEqual(rows.map((r) => secret("xlsx", sx, mx, r)), GOLDEN["messy-passwords"].xlsx);
  assert.deepEqual(rows.map((r) => secret("xml", sm, mm, r)), GOLDEN["messy-passwords"].xml);
});

test("сверка с Mac: все формы ID, рукописный XML, дубликаты, перестановки колонок", () => {
  const idRows = [[F.text("Название"), F.text("ID")], ...ID_FORMS.map((c, i) => [F.text(`Узел ${i}`), c])];
  assert.deepEqual(json(diag(load(F.xlsx([{ name: "Лист1", rows: idRows }]), "xlsx"))), GOLDEN["id-forms"]);
  assert.deepEqual(json(diag(load(Buffer.from(HAND_XML, "utf8"), "xml"))), GOLDEN["hand-xml"]);

  const dup = F.cleanRows(10);
  dup.push(["Копия кассы", dup[3][1], "", "", "", "", ""], ["Тот же ID, другая программа", dup[1][1], "", "", "", "", "TeamViewer"]);
  assert.deepEqual(json(diag(load(F.xlsxRows(dup), "xlsx"))), GOLDEN.dupes);

  const order = [3, 0, 6, 2, 5, 1, 4], base = F.cleanRows(40);
  const permute = (header) => [order.map((i) => header[i]), ...base.slice(1).map((r) => order.map((i) => r[i]))];
  assert.deepEqual(json(diag(load(F.xlsxRows(permute(["Назва", "Адреса", "Пароль", "Група", "Теги", "Примітка", "Програма"])), "xlsx"))), GOLDEN["shuffled-uk-xlsx"]);
  assert.deepEqual(json(diag(load(F.xmlRows(permute(["Name", "Address", "Password", "Group", "Tags", "Note", "App"])), "xml"))), GOLDEN["shuffled-en-xml"]);
  assert.deepEqual(json(diag(load(F.xlsxRows([["Назва", "ID"], ["Один", "111222333"], ["Два", "x@ad"]]), "xlsx"))), GOLDEN["no-password-column"]);
});

test("сверка с Mac: поиск (части названия, ID, группы, раскладка) и списки (избранное, недавние, фильтры)", () => {
  const big = load(F.xlsxRows(F.cleanRows(300)), "xlsx");
  const search = new ConnectionSearch(big.records);
  const got = {};
  for (const q of Object.keys(GOLDEN.searches)) {
    const r = search.search(q);
    got[q] = { rows: r.records.map((x) => x.sourceRow), hint: r.hint ? r.hint.converted : null, effective: r.effectiveQuery };
  }
  assert.deepEqual(got, GOLDEN.searches);

  const small = load(F.xlsxRows(F.cleanRows(30)), "xlsx"), ids = Array.from({ length: 30 }, (_, i) => F.id(i));
  const idx = new ConnectionSearch(small.records);
  for (const [name, query, filter] of [["plain", "", "all"], ["tv", "", "teamViewer"], ["ad", "", "anyDesk"], ["query", "касса", "all"]]) {
    const l = lists.buildListing({ search: idx, query, filter, defaultProgram: "anyDesk", favorites: [ids[1], ids[3], "gone-id"],
      recents: [ids[7], ids[6], ids[5], ids[4], ids[3], ids[2], "x@ad"] });
    assert.deepEqual({ sections: l.sections.map((s) => ({ id: s.id, rows: s.records.map((r) => r.sourceRow) })), counts: { all: l.counts.all, anyDesk: l.counts.anyDesk, teamViewer: l.counts.teamViewer } },
      GOLDEN.lists[name], name);
  }
});

// ---------- приёмка § 7 ----------

test("§7 файл 200+ строк: корректные видны, некорректные в диагностике с номером строки (xlsx и xml)", async () => {
  const d = mkdir();
  fs.writeFileSync(path.join(d, "a.xlsx"), F.xlsxRows(F.messyRows()));
  fs.writeFileSync(path.join(d, "a.xml"), F.xmlRows(F.messyRows()));
  const store = await opened(path.join(d, "a.xlsx"));
  const snap = store.state.snapshot;
  assert.equal(snap.records.length, 204);
  assert.deepEqual(Object.fromEntries(snap.diagnostics.skipped.map((s) => [s.row, s.reason])),
    { 4: "missingName", 6: "missingID", 8: "invalidID", 16: "unknownProgram", 20: "aliasNotSupported" });
  assert.deepEqual(snap.diagnostics.lossyIDRows, [10]);
  assert.deepEqual(snap.diagnostics.unrecognizedColumns, ["Ответственный"]);
  assert.deepEqual(snap.diagnostics.duplicates.map((g) => g.rows), [[3, 14]]);
  const shown = new Set(snap.records.map((r) => r.sourceRow));
  for (const row of [4, 6, 8, 16, 20, 22]) assert.ok(!shown.has(row), `строка ${row} в списке`);
  for (const row of [2, 3, 5, 9, 10, 12, 14, 18, 24, 211]) assert.ok(shown.has(row), `строки ${row} нет`);
  store.setSource(path.join(d, "a.xml"));
  const xml = (await until(store, (s) => s.status === "ready" && s.snapshot !== snap)).snapshot;
  assert.equal(xml.records.length, 204);
  assert.equal(xml.diagnostics.skipped.length, 5);
  assert.ok(xml.diagnostics.skipped.every((s) => s.row > 0));
  store.stop();
});

test("§7 колонки в случайном порядке, заголовки рус/укр/англ → одна и та же картина", () => {
  const canonical = F.cleanRows(60);
  const sets = [["Название", "ID", "Пароль", "Группа", "Теги", "Заметка", "Программа"], ["Назва", "Адреса", "Пароль", "Група", "Теги", "Примітка", "Програма"],
    ["Name", "Address", "Password", "Group", "Tags", "Note", "Program"], ["name", "anydesk", "PASSWORD", "GROUP", "tags", "NOTE", "app"]];
  const bare = (snap) => diag(snap).records.map(({ row, ...rest }) => rest);   // у XML «строка» — строка файла, у XLSX — листа
  const ref = bare(load(F.xlsxRows(canonical), "xlsx"));
  let seed = 12345;
  const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  for (const h of sets) for (let k = 0; k < 4; k++) {
    const order = h.map((_, i) => i).sort(() => rnd() - 0.5);
    const rows = [order.map((i) => h[i]), ...canonical.slice(1).map((r) => order.map((i) => r[i]))];
    for (const [data, kind] of [[F.xlsxRows(rows), "xlsx"], [F.xmlRows(rows), "xml"]]) {
      const snap = load(data, kind);
      assert.deepEqual(bare(snap), ref, rows[0].join("|"));
      assert.equal(snap.diagnostics.skipped.length, 0);
    }
  }
});

test("§7 пустые строки молча; нет колонок — ошибка со списком заголовков; повреждённый файл сбрасывает список", async () => {
  const rows = F.cleanRows(6);
  rows.splice(3, 0, Array(7).fill("")); rows.splice(5, 0, ["  ", "\t", "", "", "", "", ""]); rows.push(Array(7).fill(""));
  const snap = load(F.xlsxRows(rows), "xlsx");
  assert.equal(snap.records.length, 6);
  assert.equal(snap.diagnostics.skipped.length, 0);

  const d = mkdir(), f = path.join(d, "x.xlsx");
  fs.writeFileSync(f, F.xlsxRows([["Фамилия", "Телефон"], ["Иванов", "555"]]));
  const store = new ConnectionsFileStore(FAST);
  store.setSource(f);
  const s = await until(store, (x) => x.status === "error");
  assert.equal(s.error.code, "missingColumns");
  assert.deepEqual(s.error.found, ["Фамилия", "Телефон"]);

  fs.writeFileSync(f, F.xlsxRows(F.cleanRows(30)));
  store.reload();
  await until(store, (x) => x.status === "ready" && x.snapshot.records.length === 30);
  fs.writeFileSync(f, "не архив");
  store.reload();
  const bad = await until(store, (x) => x.status === "error");
  assert.equal(bad.snapshot, null, "старый список не сохраняется");
  store.stop();
});

test("§7 правка на месте, атомарная замена (как Excel), удаление и возврат → список обновляется", async () => {
  const d = mkdir(), f = path.join(d, "edit.xlsx");
  fs.writeFileSync(f, F.xlsxRows(F.cleanRows(200)));
  const store = await opened(f);
  assert.equal(store.state.snapshot.records.length, 200);
  const rows = F.cleanRows(200);
  rows[1][0] = "Переименованный узел";
  rows.push(["Новый узел", "555666777", "Pw-new-секрет", "Клиенты", "", "", ""]);
  fs.writeFileSync(f, F.xlsxRows(rows));
  await until(store, (s) => s.status === "ready" && s.snapshot.records.length === 201);
  assert.equal(store.state.snapshot.records[0].name, "Переименованный узел");

  for (const n of [51, 52, 53]) {
    const tmp = path.join(d, `~$tmp-${n}.xlsx`);
    fs.writeFileSync(tmp, F.xlsxRows(F.cleanRows(n)));
    fs.renameSync(tmp, f);
    await until(store, (s) => s.status === "ready" && s.snapshot?.records.length === n);
  }
  const data = F.xlsxRows(F.cleanRows(20));
  fs.unlinkSync(f);
  await until(store, (s) => s.status === "error" && s.error.code === "unavailable");
  assert.equal(store.state.snapshot, null);
  fs.writeFileSync(f, data);
  await until(store, (s) => s.status === "ready" && s.snapshot.records.length === 20, 8000);
  store.stop();
});

test("§7 файл занят: повтор, без ошибки; недописанный файл (Excel сохраняет) дочитывается", async () => {
  const d = mkdir(), f = path.join(d, "busy.xlsx");
  const full = F.xlsxRows(F.cleanRows(40));
  fs.writeFileSync(f, full.subarray(0, full.length >> 1));
  const store = new ConnectionsFileStore(FAST);
  store.setSource(f);
  await until(store, (s) => s.status === "error");
  fs.writeFileSync(f, full);
  store.reload();
  await until(store, (s) => s.status === "ready" && s.snapshot.records.length === 40);

  store.stop();   // первый store следит за тем же файлом и читал бы его во время подмены readFile (гонка счётчика)
  // «Занят»: чтение падает с EBUSY два раза, потом проходит; ошибки пользователю не показывается.
  const fsp = fs.promises, orig = fsp.readFile;
  let calls = 0;
  fsp.readFile = async (...a) => { if (String(a[0]) === f && calls++ < 2) throw Object.assign(new Error("busy"), { code: "EBUSY" }); return orig.apply(fsp, a); };
  try {
    const seen = new Set();
    const s2 = new ConnectionsFileStore(FAST);
    s2.on("change", (st) => seen.add(st.status));
    s2.setSource(f);
    await until(s2, (s) => s.status === "ready");
    assert.equal(calls, 3);
    assert.ok(!seen.has("error"));
    s2.stop();
  } finally { fsp.readFile = orig; }
  store.stop();
});

test("§7 поиск: часть названия, ID (целиком, часть, с пробелами), группа/теги/заметка, раскладка, первая строка = Enter", () => {
  const snap = load(F.xlsxRows(F.cleanRows(300)), "xlsx");
  const search = new ConnectionSearch(snap.records), target = snap.records[137];
  const rows = (q) => search.search(q).records;
  assert.ok(rows("лаборат").length && rows("лаборат").every((r) => r.name.toLowerCase().includes("лаборат")));
  assert.equal(rows(target.name.toLowerCase())[0].sourceRow, target.sourceRow);
  const { displayID } = require("../../remote/models");
  for (const q of [target.id, target.id.slice(0, 6), displayID(target), target.id.slice(3, 8)]) assert.ok(rows(q).some((r) => r.sourceRow === target.sourceRow), q);
  assert.equal(rows(target.id)[0].sourceRow, target.sourceRow);
  assert.equal(rows("нетакогослова").length, 0);
  for (const q of ["ФІЛІЇ", "OFFICE", "КАССА", "Ночь", "ЗВОНИТЬ", "приемная", "КЛИЕНТЫ"]) assert.ok(rows(q).length, q);
  const typed = search.search("ctdth");
  assert.equal(typed.hint.converted, "север");
  assert.ok(typed.records.every((r) => r.name.toLowerCase().includes("север")));
  assert.equal(search.search("Лнш").hint.converted, "kyi");
});

test("§7 избранное/недавние: 5 штук, исчезнувшие ID не показываются", () => {
  const snap = load(F.xlsxRows(F.cleanRows(30)), "xlsx");
  const prefs = { favoriteIDs: [], recentIDs: [] };
  for (let i = 0; i < 8; i++) lists.noteConnected(snap.records[i], prefs);
  assert.equal(prefs.recentIDs.length, 5);
  assert.equal(prefs.recentIDs[0], snap.records[7].id);
  lists.toggleFavorite(snap.records[1], prefs); lists.toggleFavorite(snap.records[3], prefs);
  const rows = F.cleanRows(30).filter((_, i) => i !== 4 && i !== 9);
  const after = load(F.xlsxRows(rows), "xlsx");
  const l = lists.buildListing({ search: new ConnectionSearch(after.records), query: "", filter: "all", defaultProgram: "anyDesk", favorites: prefs.favoriteIDs, recents: prefs.recentIDs });
  assert.equal(l.sections[0].kind, "favorites");
  const shown = l.sections.filter((s) => s.kind === "favorites" || s.kind === "recents").flatMap((s) => s.records.map((r) => r.id));
  assert.ok(!shown.includes(snap.records[3].id));
  assert.ok(shown.includes(snap.records[1].id));
});

test("§7 пароль нигде: записи, поиск, вид окна, настройки, рядом с файлом; читается из файла в момент подключения и затирается", async () => {
  const d = mkdir(), f = path.join(d, "pw.xlsx");
  fs.writeFileSync(f, F.xlsxRows(F.messyRows()));
  const settings = new RemoteSettings(path.join(d, "settings", "remote.json"));
  settings.update({ file: f });
  const store = new ConnectionsFileStore(FAST);
  const service = new RemoteService({ settings, store });
  service.start();
  await until(store, (s) => s.status === "ready");
  const record = store.state.snapshot.records[0];
  service.noteConnected(record); service.toggleFavorite(`${record.sourceRow}:${record.id}`);
  const dump = JSON.stringify([store.state, service.view(), service.view({ query: "комп" }), settings.data]);
  assert.ok(!dump.includes("секрет") && !dump.includes("Pw-"), "пароль в памяти/виде/настройках");
  assert.ok(store.state.snapshot.records.some((r) => r.hasPassword));
  for (const file of fs.readdirSync(path.join(d, "settings"))) assert.ok(!fs.readFileSync(path.join(d, "settings", file), "utf8").includes("секрет"));
  assert.deepEqual(fs.readdirSync(d).sort(), ["pw.xlsx", "settings"]);

  const rows = F.messyRows(); rows[1][2] = "Новый-пароль-77";
  fs.writeFileSync(f, F.xlsxRows(rows));
  const s = await store.password(record);
  assert.equal(Buffer.from(s.bytes).toString("utf8"), "Новый-пароль-77", "пароль берётся из файла сейчас");
  assert.ok(!String(s).includes("Пароль") && !JSON.stringify(s).includes("Нов") && !require("node:util").inspect(s).includes("Нов"));
  s.wipe();
  assert.ok(s.isWiped);
  const clean = await store.password(store.state.snapshot.records.find((r) => !r.hasPassword) ?? { sourceRow: 999, id: "000000000", name: "x" });
  assert.equal(clean, null);
  store.stop();
});

const CLIPBOARD_OK = new Set(["clipboard.js", "index.js"]);
test("§7 модуль не пишет пароли в журнал/кэш: в исходниках нет console/clipboard/safeStorage/localStorage", () => {
  const dir = path.join(__dirname, "..", "..", "remote");
  const files = fs.readdirSync(dir, { recursive: true }).filter((n) => n.endsWith(".js"));
  assert.ok(files.length > 10);
  for (const n of files) {
    const text = fs.readFileSync(path.join(dir, n), "utf8");
    // Буфер обмена — только в clipboard.js (секрет на 30 с, затем очистка) и в index.js (подключение его и копия ID/адреса).
    const banned = CLIPBOARD_OK.has(path.basename(n)) ? ["console.", "safeStorage", "localStorage", "sessionStorage", "document.cookie", "keytar"]
      : ["console.", "clipboard", "safeStorage", "localStorage", "sessionStorage", "document.cookie", "keytar"];
    for (const bad of banned) assert.ok(!text.includes(bad), `${n}: ${bad}`);
  }
});

test("§7 скорость: 2000 строк xlsx/xml читаются < 1 с, поиск < 0,1 с", () => {
  for (const [kind, make] of [["xlsx", F.xlsxRows], ["xml", F.xmlRows]]) {
    const data = make(F.cleanRows(2000));
    const t0 = process.hrtime.bigint();
    const snap = load(data, kind);
    const sec = Number(process.hrtime.bigint() - t0) / 1e9;
    assert.equal(snap.records.length, 2000);
    assert.ok(sec < 1, `${kind}: чтение ${sec} с`);
    const search = new ConnectionSearch(snap.records);
    const t1 = process.hrtime.bigint();
    for (const q of ["лабор", "касса 12", "100", "ctdth", "zzzz"]) search.search(q);
    const each = Number(process.hrtime.bigint() - t1) / 1e9 / 5;
    assert.ok(each < 0.1, `${kind}: поиск ${each} с`);
  }
});
