// Модуль «Удалённые подключения»: чтение, ID, диагностика — поведение 1:1 с Mac (MURemoteConnectionsTests).
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const F = require("./fixtures");
const { normalize } = require("../../remote/id");
const { fieldFor } = require("../../remote/headers");
const { load, passwordFor } = require("../../remote/source");
const { parseProgram, programOf, isClean, duplicateCount, ConnectionsError } = require("../../remote/models");
const xlsx = require("../../remote/xlsx");

const norm = (s) => normalize(s)?.value ?? null;
const build = (rows) => load(F.xlsxRows(rows), "xlsx");

test("ID: цифры, пробелы и невидимые знаки", () => {
  assert.equal(norm("123456789"), "123456789");
  assert.equal(norm("1234567890"), "1234567890");
  assert.equal(norm("0123456789"), "0123456789");
  assert.equal(norm("123 456 789"), "123456789");
  assert.equal(norm(" 123 456 789 "), "123456789");
  assert.equal(norm("﻿123​456789\n"), "123456789");
});

test("ID: формы числа из Excel и потеря цифр", () => {
  for (const [raw, want] of [["123456789.0", "123456789"], ["123456789.000", "123456789"], ["1.23456789E+08", "123456789"],
    ["1.23456789e8", "123456789"], ["1,23456789E+08", "123456789"], ["1.234567891E+09", "1234567891"]]) assert.equal(norm(raw), want, raw);
  assert.equal(normalize("1.23456789E+08").lossy, false);
  const lossy = normalize("1.23E+08");
  assert.equal(lossy.value, "123000000");
  assert.equal(lossy.lossy, true);
});

test("ID: невалидные значения", () => {
  for (const bad of ["", "   ", "12345", "12345678901", "123456789.5", "abc", "12a456789", "1.2.3", "1E+40", "-123456789", "+123456789",
    "123-456-789", "@ad", "name@", "a@b@c", "имя@ad", "a b@c d@e"]) assert.equal(norm(bad), null, JSON.stringify(bad));
});

test("ID: алиасы", () => {
  assert.equal(norm("Office@AD"), "office@ad");
  assert.equal(norm("front-desk.2@company"), "front-desk.2@company");
  assert.equal(norm(" office @ ad "), "office@ad");
  assert.equal(normalize("office@ad").isAlias, true);
});

test("заголовки на русском, украинском и английском в любом порядке", () => {
  const variants = [
    ["Name", "ID", "Password", "Group", "Tags", "Note", "App"],
    ["Програма", "Примітка", "Теги", "Група", "Пароль", "Адреса", "Назва"],
    ["ПРОГРАММА", "заметка", "Тэги", "группа", "пароль", "AnyDesk ID", "название"],
    ["Ім’я", "ID AnyDesk", "Pass", "GROUP", "tag", "Notes", "Application"],
  ];
  for (const header of variants) {
    const values = { name: "Лаборатория Север", id: "123 456 789", password: "x", group: "Клиенты", tags: "касса, ночь, Касса", note: "звонить заранее", program: "teamviewer" };
    const row = header.map((h) => { const f = fieldFor(h); assert.ok(f, `не распознан заголовок ${h}`); return values[f]; });
    const snap = build([header, row]);
    assert.deepEqual(snap.records, [{ sourceRow: 2, name: "Лаборатория Север", id: "123456789", group: "Клиенты", tags: ["касса", "ночь"], note: "звонить заранее", program: "teamViewer", hasPassword: true,
      method: null, account: "", hasAccountPassword: false, accessLines: 0 }], header.join());
    assert.ok(isClean(snap.diagnostics));
    assert.equal(snap.diagnostics.columns.length, 7);
  }
});

test("нет обязательных колонок: в ошибке — найденные заголовки", () => {
  assert.throws(() => build([["Название", "Пароль", "Кто"], ["a", "b", "c"]]), (e) => e.code === "missingColumns" && JSON.stringify(e.found) === JSON.stringify(["Название", "Пароль", "Кто"]));
  assert.throws(() => build([]), (e) => e.code === "missingColumns" && e.found.length === 0);
});

test("название таблицы над заголовком пропускается", () => {
  const snap = build([["Мои подключения"], ["Название", "ID"], ["Касса 2", "123456789"]]);
  assert.deepEqual(snap.records.map((r) => r.sourceRow), [3]);
  assert.deepEqual(snap.diagnostics.unrecognizedColumns, []);
});

test("значения «Программа»", () => {
  for (const [raw, program] of [["AnyDesk", "anyDesk"], ["any desk", "anyDesk"], ["AD", "anyDesk"], ["TeamViewer", "teamViewer"], ["Team-Viewer", "teamViewer"], ["ТимВьюер", "teamViewer"]]) assert.equal(parseProgram(raw), program, raw);
  assert.equal(parseProgram("RustDesk"), null);
});

test("кривой файл на 210 строк: пропуски с номерами и причинами, дубликат, потеря цифр", () => {
  const snap = build(F.messyRows());
  const d = snap.diagnostics;
  assert.deepEqual(d.unrecognizedColumns, ["Ответственный"]);
  assert.deepEqual(d.skipped, [
    { row: 4, reason: "missingName", value: "" }, { row: 6, reason: "missingID", value: "" }, { row: 8, reason: "invalidID", value: "12345" },
    { row: 16, reason: "unknownProgram", value: "RustDesk" }, { row: 20, reason: "aliasNotSupported", value: "front@ad" }]);
  assert.deepEqual(d.lossyIDRows, [10]);
  assert.deepEqual(d.duplicates, [{ id: F.id(1), rows: [3, 14], names: ["Комп’ютер 1", "Комп’ютер 12"] }]);
  assert.equal(duplicateCount(d), 1);
  assert.equal(d.loaded, 210 - 1 - 5);
  assert.equal(snap.records.length, d.loaded);
  assert.equal(isClean(d), false);
  const byRow = new Map(snap.records.map((r) => [r.sourceRow, r]));
  assert.equal(byRow.get(10).id, "123000000");
  assert.equal(byRow.get(12).id, "123456780");
  assert.equal(byRow.get(18).id, "office@ad");
  assert.equal(byRow.get(24).id, "123456789");
  assert.equal(byRow.get(22), undefined);
});

test("дубликаты между программами", () => {
  const snap = build([["Name", "ID", "App"], ["A", "123456789", "AnyDesk"], ["B", "123456789", "TeamViewer"], ["C", "987654321", ""], ["D", "987654321", "AnyDesk"]]);
  assert.deepEqual(snap.diagnostics.duplicates.map((g) => g.id), ["987654321"]);
  assert.equal(snap.records.length, 4);
});

test("неоднозначная программа — только если в файле есть обе", () => {
  const single = build([["Name", "ID", "App"], ["A", "123456789", "AnyDesk"], ["B", "223456789", ""]]);
  assert.deepEqual(single.diagnostics.ambiguousProgramRows, []);
  assert.ok(isClean(single.diagnostics));
  const both = build([["Name", "ID", "App"], ["A", "123456789", "AnyDesk"], ["B", "223456789", "TeamViewer"], ["C", "323456789", ""], ["D", "x@ad", ""]]);
  assert.deepEqual(both.diagnostics.ambiguousProgramRows, [4]);
  assert.equal(programOf(both.records.find((r) => r.name === "C"), "teamViewer"), "teamViewer");
  assert.equal(programOf(both.records.find((r) => r.name === "D"), "teamViewer"), "anyDesk");
});

test("чистый файл без колонки «Программа»", () => {
  const snap = build(F.cleanRows(30, ["Name", "ID", "Password"]).map((r) => r.slice(0, 3)));
  assert.ok(isClean(snap.diagnostics));
  assert.equal(snap.diagnostics.loaded, 30);
  assert.equal(snap.diagnostics.withPassword, 24);
  assert.ok(snap.records.every((r) => r.program === null));
});

test("XLSX: типы ячеек, пропуски колонок и строк, листы, абсолютные пути, stored/deflate", () => {
  const rows = [[F.text("Name"), F.text("ID"), null, F.text("Group")], [F.inline("Касса"), F.number("123456789"), null, F.formula("Клиенты")]];
  for (const opts of [{}, { absoluteTargets: true }, { compress: false }]) {
    const snap = load(F.xlsx([{ name: "Пусто", rows: [[]] }, { name: "Данные", rows, firstRow: 3 }], opts), "xlsx", "Данные");
    assert.deepEqual(snap.records.map((r) => [r.sourceRow, r.name, r.id, r.group]), [[4, "Касса", "123456789", "Клиенты"]], JSON.stringify(opts));
  }
  const data = F.xlsx([{ name: "A", rows: [[]] }, { name: "B", rows: [[]] }]);
  assert.deepEqual(xlsx.sheetNames(data), ["A", "B"]);
  assert.throws(() => load(data, "xlsx", "Нет"), (e) => e.code === "noSheet");
});

test("XLSX: повреждённые, обрезанные и зашифрованные архивы", () => {
  const good = F.xlsxRows(F.cleanRows(3));
  assert.throws(() => load(Buffer.from("это не zip"), "xlsx"), (e) => e.code === "corrupt");
  assert.throws(() => load(good.subarray(0, good.length - 40), "xlsx"), (e) => e.code === "corrupt");
  assert.throws(() => load(Buffer.alloc(0), "xlsx"), (e) => e.code === "corrupt");
  const encrypted = Buffer.from(good);
  for (let pos = encrypted.indexOf(Buffer.from("PK\x01\x02")); pos >= 0; pos = encrypted.indexOf(Buffer.from("PK\x01\x02"), pos + 4)) {
    encrypted.writeUInt16LE(encrypted.readUInt16LE(pos + 8) | 1, pos + 8);   // бит 0 флагов: файл зашифрован
  }
  assert.throws(() => load(encrypted, "xlsx"), (x) => x.code === "corrupt");
});

test("XML: теги, атрибуты, CDATA, номера строк, внешние сущности не раскрываются", () => {
  const xml = `<?xml version="1.0"?>
<!DOCTYPE connections [<!ENTITY x SYSTEM "file:///etc/passwd">]>
<connections>
  <connection><name>Касса &amp; склад</name><id>123 456 789</id><password><![CDATA[a<b&c]]></password><app>AnyDesk</app><zzz>1</zzz></connection>
  <connection name="Офис" id="223456789" group="Клиенты"/>
  <connection><name>&x;</name><id>323456789</id></connection>
</connections>`;
  const snap = load(Buffer.from(xml), "xml");
  assert.deepEqual(snap.records.map((r) => [r.sourceRow, r.name, r.id, r.program, r.hasPassword]),
    [[4, "Касса & склад", "123456789", "anyDesk", true], [5, "Офис", "223456789", null, false], [6, "", "323456789", null, false]].filter((r) => r[1]));
  assert.deepEqual(snap.diagnostics.unrecognizedColumns, ["zzz"]);
  assert.deepEqual(snap.diagnostics.skipped, [{ row: 6, reason: "missingName", value: "" }]);
  assert.throws(() => load(Buffer.from("<connections><connection></connections>"), "xml"), (e) => e.code === "corrupt");
  assert.throws(() => load(Buffer.from("<other/>"), "xml"), (e) => e.code === "corrupt");
});

test("XML даёт те же записи, что XLSX на кривом файле", () => {
  const rows = F.messyRows();
  const a = load(F.xlsxRows(rows), "xlsx"), b = load(F.xmlRows(rows), "xml");
  assert.deepEqual(b.records.map((r) => [r.name, r.id, r.program]), a.records.map((r) => [r.name, r.id, r.program]));
  assert.deepEqual(b.diagnostics.skipped.map((s) => [s.reason, s.value]), a.diagnostics.skipped.map((s) => [s.reason, s.value]));
});

test("пароль берётся из файла в момент подключения: по строке, по имени, единственный; среди дубликатов не гадаем", () => {
  const rows = [["Name", "ID", "Password"], ["A", "123456789", "pw-a"], ["B", "223456789", "pw-b"], ["C", "323456789", "pw-c1"], ["D", "323456789", "pw-c2"]];
  const data = F.xlsxRows(rows);
  const rec = (name) => load(data, "xlsx").records.find((r) => r.name === name);
  assert.equal(passwordFor(rec("A"), data, "xlsx").bytes.toString(), "pw-a");
  // файл поправили: строки сдвинулись
  const shifted = F.xlsxRows([rows[0], ["Новая", "923456789", "x"], ...rows.slice(1)]);
  assert.equal(passwordFor(rec("B"), shifted, "xlsx").bytes.toString(), "pw-b");
  assert.equal(passwordFor(rec("C"), data, "xlsx").bytes.toString(), "pw-c1", "та же строка");
  const noRow = { ...rec("C"), sourceRow: 99, name: "Другое" };
  assert.equal(passwordFor(noRow, data, "xlsx"), null, "среди дубликатов не угадываем");
  assert.equal(passwordFor({ ...rec("A"), id: "999999999" }, data, "xlsx"), null);
});

test("записи и диагностика не содержат паролей; SecretBuffer не печатается и затирается", () => {
  const rows = F.cleanRows(20);
  const snap = load(F.xlsxRows(rows), "xlsx");
  const dump = JSON.stringify(snap);
  for (let i = 0; i < 20; i++) assert.ok(!dump.includes(F.password(i)), `пароль ${i} в записях`);
  const data = F.xlsxRows(rows);
  const secret = passwordFor(snap.records[0], data, "xlsx");
  assert.equal(String(secret), "[секрет]");
  assert.equal(JSON.stringify({ secret }), '{"secret":"[секрет]"}');
  assert.ok(!require("node:util").inspect(secret).includes("Pw-"));
  secret.wipe();
  assert.ok(secret.isWiped);
});

test("производительность: 5000 строк xlsx и xml ≤ 3 с", () => {
  const rows = F.cleanRows(5000);
  for (const [data, kind] of [[F.xlsxRows(rows), "xlsx"], [F.xmlRows(rows), "xml"]]) {
    const t = Date.now();
    const snap = load(data, kind);
    assert.equal(snap.records.length, 5000);
    assert.ok(Date.now() - t < 3000, `${kind} ${Date.now() - t} мс`);
  }
});
