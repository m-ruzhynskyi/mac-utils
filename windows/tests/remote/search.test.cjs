// Поиск, раскладки, избранное, недавние, секции — порт SearchAndListTests Mac-модуля.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const F = require("./fixtures");
const { ConnectionSearch, highlights, highlightsInID } = require("../../remote/search");
const lists = require("../../remote/lists");
const { displayID } = require("../../remote/models");
const { load } = require("../../remote/source");

const rec = (sourceRow, name, id, extra = {}) => ({ sourceRow, name, id, group: "", tags: [], note: "", program: null, hasPassword: false, ...extra });
const records = [
  rec(2, "Лаборатория Север", "123456789", { group: "Лаборатории", tags: ["ночь"], program: "anyDesk", hasPassword: true }),
  rec(3, "Север · резервный сервер", "678901234", { group: "Лаборатории" }),
  rec(4, "Лаборатория Восток", "1234567890", { group: "Лаборатории", program: "teamViewer" }),
  rec(5, "Бухгалтерия", "567890123", { group: "Офисы", note: "звонить заранее", program: "teamViewer" }),
  rec(6, "Касса 4 · Запад", "kassa4@ad", { group: "Офисы" }),
  rec(7, "Склад Харків", "345678901", { program: "anyDesk" }),
  rec(8, "Ёлка", "987654321"),
];
const names = (q) => new ConnectionSearch(records).search(q).records.map((r) => r.name);

test("пустой запрос — все в порядке файла", () => assert.deepEqual(names("  "), records.map((r) => r.name)));
test("ранжирование: начало названия первым", () => {
  assert.deepEqual(names("север"), ["Север · резервный сервер", "Лаборатория Север"]);
  assert.deepEqual(names("СЕВ"), ["Север · резервный сервер", "Лаборатория Север"]);
});
test("поля и слова", () => {
  assert.deepEqual(names("ночь"), ["Лаборатория Север"]);
  assert.deepEqual(names("заранее"), ["Бухгалтерия"]);
  assert.deepEqual(names("офисы"), ["Бухгалтерия", "Касса 4 · Запад"]);
  assert.deepEqual(names("лаб вос"), ["Лаборатория Восток"]);
  assert.deepEqual(names("елка"), ["Ёлка"]);
  assert.deepEqual(names("ХАРКІВ"), ["Склад Харків"]);
  assert.deepEqual(names("харк"), ["Склад Харків"]);
});
test("ID с пробелами и без", () => {
  assert.deepEqual(names("123 456"), ["Лаборатория Север", "Лаборатория Восток"]);
  assert.deepEqual(names("234567890"), ["Лаборатория Восток"]);
  assert.deepEqual(names("kassa4"), ["Касса 4 · Запад"]);
});
test("неверная раскладка EN → RU/UK и RU → EN", () => {
  const s = new ConnectionSearch(records);
  const r = s.search("ctdth");
  assert.deepEqual(r.hint, { typed: "ctdth", converted: "север" });
  assert.equal(r.records.length, 2);
  assert.equal(r.effectiveQuery, "север");
  assert.equal(s.search("[fhrsd").hint.converted, "харків");
  assert.deepEqual(s.search("[fhrsd").records.map((x) => x.name), ["Склад Харків"]);
  assert.deepEqual(s.search("лфыыф4").records.map((x) => x.name), ["Касса 4 · Запад"]);
  const none = s.search("zzzz");
  assert.deepEqual(none.records, []);
  assert.equal(none.hint, null);
  assert.equal(s.search("kassa").hint, null);
});
test("подсветка в названии и в ID", () => {
  const text = "Лаборатория Север";
  assert.deepEqual(highlights(text, "север").map((r) => text.slice(r.start, r.end)), ["Север"]);
  assert.deepEqual(highlights("Ёлка", "елка").map((r) => "Ёлка".slice(r.start, r.end)), ["Ёлка"]);
  const id = "123 456 789";
  assert.deepEqual(highlightsInID(id, "3456").map((r) => id.slice(r.start, r.end)), ["3 456"]);
  assert.equal(highlightsInID(id, "x").length, 0);
});
test("ID для показа группами", () => {
  assert.equal(displayID(records[0]), "123 456 789");
  assert.equal(displayID(records[2]), "1 234 567 890");
  assert.equal(displayID(records[4]), "kassa4@ad");
});
test("избранное и недавние: по ID, не больше пяти", () => {
  const prefs = { favoriteIDs: [], recentIDs: [] };
  lists.toggleFavorite(records[3], prefs); lists.toggleFavorite(records[0], prefs);
  assert.ok(lists.isFavorite(records[0], prefs));
  lists.toggleFavorite(records[3], prefs);
  assert.deepEqual(prefs.favoriteIDs, ["123456789"]);
  for (const r of records) lists.noteConnected(r, prefs);
  lists.noteConnected(records[4], prefs);
  assert.deepEqual(prefs.recentIDs, ["kassa4@ad", "987654321", "345678901", "567890123", "1234567890"]);
  assert.ok(!prefs.recentIDs.join("").includes("секрет"));
});
const listing = (over) => lists.buildListing({ search: new ConnectionSearch(records), query: "", filter: "all", defaultProgram: "anyDesk", favorites: [], recents: [], ...over });
test("секции без запроса: избранное, недавние, группы в порядке файла, без группы", () => {
  const l = listing({ favorites: ["123456789", "000000000"], recents: ["567890123", "999999999", "kassa4@ad"] });
  assert.deepEqual(l.sections.map((s) => s.id), ["favorites", "recents", "group:Лаборатории", "group:Офисы", "ungrouped"]);
  assert.deepEqual(l.sections[0].records.map((r) => r.sourceRow), [2]);
  assert.deepEqual(l.sections[1].records.map((r) => r.sourceRow), [5, 6]);
  assert.deepEqual(l.sections.at(-1).records.map((r) => r.sourceRow), [7, 8]);
  assert.equal(l.counts.all, 7);
  assert.equal(l.counts.anyDesk, 5);
  assert.equal(l.counts.teamViewer, 2);
  assert.equal(l.rows.length, 7 + 1 + 2);
  assert.equal(new Set(l.rows.map((r) => r.id)).size, l.rows.length);
});
test("фильтр по программе и программа по умолчанию", () => {
  const tv = listing({ filter: "teamViewer", defaultProgram: "teamViewer" });
  assert.deepEqual(tv.rows.map((r) => r.record.sourceRow).sort((a, b) => a - b), [3, 4, 5, 8]);
  assert.equal(tv.counts.anyDesk, 3);
});
test("поиск — один список «Найдено» с подсказкой раскладки; пусто", () => {
  const l = listing({ query: "ctdth", favorites: ["123456789"] });
  assert.deepEqual(l.sections.map((s) => s.id), ["results"]);
  assert.equal(l.hint.converted, "север");
  assert.equal(l.counts.all, 2);
  assert.ok(listing({ query: "нет такого" }).isEmpty);
});
test("буквы колонок для диагностики", () => {
  const snap = load(F.xlsxRows([["", "Name", "ID"], ["", "A", "123456789"]]), "xlsx");
  assert.deepEqual(snap.diagnostics.columns.map((c) => require("../../remote/models").columnLetter(c.column)), ["B", "C"]);
});
test("скорость поиска: 5000 записей, запрос < 100 мс", () => {
  const snap = load(F.xlsxRows(F.cleanRows(5000)), "xlsx");
  const search = new ConnectionSearch(snap.records);
  const t = process.hrtime.bigint();
  for (const q of ["л", "ла", "лаб", "лабо", "1234", "ctdth", "касса ночь"]) lists.buildListing({ search, query: q, filter: "all", defaultProgram: "anyDesk", favorites: [], recents: [] });
  const perQuery = Number(process.hrtime.bigint() - t) / 1e6 / 7;
  assert.ok(perQuery < 100, `${perQuery} мс на запрос`);
});
