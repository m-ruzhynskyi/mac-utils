// Правка XML (добавить, изменить, удалить), .bak, атомарная запись, инварианты «байты вне записи не меняются»; шаблоны.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./fixtures");
const editor = require("../../remote/editor");
const templates = require("../../remote/templates");
const { load } = require("../../remote/source");
const { passwordFor } = require("../../remote/source");

const SAMPLE = `<?xml version="1.0" encoding="UTF-8"?>
<!-- мой список -->
<connections>
  <connection>
    <name>Лаборатория Север</name>
    <id>123 456 789</id>
    <password>pw-север</password>
    <group>Клиенты</group>
    <extra>не трогать</extra>
  </connection>
  <connection name="Склад" id="223456789" group="Філії"/>
  <connection><name>Касса</name><id>323456789</id><app>TeamViewer</app></connection>
</connections>
`;
function fixture(text = SAMPLE, mode = 0o640) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rc-ed-"));
  const file = path.join(dir, "list.xml");
  fs.writeFileSync(file, text, { mode });
  fs.chmodSync(file, mode);
  return { dir, file };
}
const records = (file) => load(fs.readFileSync(file), "xml").records;
const byName = (file, name) => records(file).find((r) => r.name === name);

test("изменить: байты вне записи те же, неизвестный тег и пароль сохранены, .bak с теми же правами", () => {
  const { dir, file } = fixture();
  const target = byName(file, "Лаборатория Север");
  const before = fs.readFileSync(file, "utf8");
  const result = editor.apply(file, "update", { record: target, fields: { name: "Лаборатория Север 2", id: "123456789", group: "Лаборатории", tags: "ночь", note: "звонить", program: "AnyDesk" } });
  assert.deepEqual(result, { ok: true });
  const after = fs.readFileSync(file, "utf8");
  const start = before.indexOf("  <connection>"), end = before.indexOf("</connection>") + "</connection>".length;
  assert.equal(after.slice(0, start), before.slice(0, start), "начало файла не меняется");
  assert.equal(after.slice(after.length - (before.length - end)), before.slice(end), "хвост файла не меняется");
  assert.ok(after.includes("<extra>не трогать</extra>"), "неизвестный тег сохранён");
  const updated = byName(file, "Лаборатория Север 2");
  assert.deepEqual([updated.group, updated.tags, updated.note, updated.program, updated.hasPassword], ["Лаборатории", ["ночь"], "звонить", "anyDesk", true]);
  const secret = passwordFor(updated, fs.readFileSync(file), "xml");
  assert.equal(secret.bytes.toString(), "pw-север", "пароль не потерян и не показывался форме");
  assert.equal(fs.readFileSync(`${file}.bak`, "utf8"), before, ".bak — прежнее содержимое");
  if (process.platform !== "win32") assert.equal(fs.statSync(`${file}.bak`).mode & 0o777, 0o640, ".bak с теми же правами");
  assert.deepEqual(fs.readdirSync(dir).sort(), ["list.xml", "list.xml.bak"], "временных файлов не осталось");
});

test("добавить: запись в конец перед </connections>, отступы как у соседей, остальное без изменений", () => {
  const { file } = fixture();
  const before = fs.readFileSync(file, "utf8");
  assert.deepEqual(editor.apply(file, "add", { fields: { name: "Новая & «точка»", id: "Office@AD", group: "Офис", program: "" } }), { ok: true });
  const after = fs.readFileSync(file, "utf8");
  const cut = before.lastIndexOf("</connections>");
  assert.equal(after.slice(0, cut), before.slice(0, cut), "прежний текст без изменений");
  assert.ok(after.endsWith("</connections>\n"));
  const added = records(file).find((r) => r.id === "office@ad");
  assert.equal(added.name, "Новая & «точка»");
  assert.equal(added.group, "Офис");
  assert.equal(records(file).length, 4);
});

test("удалить: убирается только эта запись вместе со своей строкой", () => {
  const { file } = fixture();
  const before = fs.readFileSync(file, "utf8");
  assert.deepEqual(editor.apply(file, "remove", { record: byName(file, "Склад") }), { ok: true });
  const after = fs.readFileSync(file, "utf8");
  assert.equal(after, before.replace('  <connection name="Склад" id="223456789" group="Філії"/>\n', ""));
  assert.deepEqual(records(file).map((r) => r.name), ["Лаборатория Север", "Касса"]);
});

test("проверка ID и программы при добавлении/изменении: файл не трогается", () => {
  const { file } = fixture();
  const before = fs.readFileSync(file, "utf8");
  for (const [fields, error] of [[{ name: "", id: "123456789" }, "missingName"], [{ name: "A", id: "" }, "missingID"], [{ name: "A", id: "12345" }, "invalidID"],
    [{ name: "A", id: "123456789", program: "RustDesk" }, "unknownProgram"], [{ name: "A", id: "x@ad", program: "TeamViewer" }, "aliasNotSupported"]]) {
    assert.deepEqual(editor.apply(file, "add", { fields }), { ok: false, error });
  }
  assert.equal(fs.readFileSync(file, "utf8"), before);
  assert.ok(!fs.existsSync(`${file}.bak`), "при отказе .bak не создаётся");
});

test("файл успели поправить: запись нашлась по ID и имени; исчезла — «gone»", () => {
  const { file } = fixture();
  const target = byName(file, "Касса");
  fs.writeFileSync(file, SAMPLE.replace("<!-- мой список -->", "<!-- мой список -->\n<!-- ещё -->\n<!-- строки -->"));
  assert.deepEqual(editor.apply(file, "update", { record: target, fields: { name: "Касса 2", id: "323456789" } }), { ok: true });
  assert.ok(byName(file, "Касса 2"));
  assert.deepEqual(editor.apply(file, "remove", { record: { ...target, id: "999999999", name: "Нет" } }), { ok: false, error: "gone" });
});

test("CRLF, BOM и дубликаты по ID: переводы строк и BOM сохраняются; запись с тем же ID не угадывается", () => {
  const crlf = "﻿" + SAMPLE.replace(/\n/g, "\r\n");
  const { file } = fixture(crlf);
  assert.deepEqual(editor.apply(file, "add", { fields: { name: "Новая", id: "423456789" } }), { ok: true });
  const raw = fs.readFileSync(file, "utf8");
  assert.ok(raw.startsWith("﻿") && raw.indexOf("﻿", 1) < 0);
  assert.ok(!/[^\r]\n/.test(raw), "все переводы строк остались CRLF");
  const dup = fixture(SAMPLE.replace("323456789", "123456789"));
  const first = records(dup.file)[0];
  assert.deepEqual(editor.apply(dup.file, "remove", { record: { ...first, sourceRow: 99, name: "Нет такого" } }), { ok: false, error: "gone" });
});

test(".xlsx не правится никогда; битый XML не перезаписывается", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rc-ed-"));
  const x = path.join(dir, "list.xlsx");
  fs.writeFileSync(x, F.xlsxRows(F.cleanRows(2)));
  const before = fs.readFileSync(x);
  assert.deepEqual(editor.apply(x, "add", { fields: { name: "A", id: "123456789" } }), { ok: false, error: "xlsxReadOnly" });
  assert.ok(before.equals(fs.readFileSync(x)));
  const { file } = fixture("<connections><connection></connections>");
  assert.deepEqual(editor.apply(file, "add", { fields: { name: "A", id: "123456789" } }), { ok: false, error: "corrupt" });
});

test("шаблон .xlsx и .xml читаются тем же модулем, с колонкой «Программа»; файл подключается", async () => {
  for (const kind of ["xlsx", "xml"]) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rc-tpl-"));
    const target = path.join(dir, `Подключения.${kind}`);
    let applied = null;
    const out = await templates.create({ kind, dialog: { showSaveDialog: async () => ({ canceled: false, filePath: target }) }, parent: null, setSettings: (p) => { applied = p; } });
    assert.equal(out, target);
    assert.deepEqual(applied, { file: target, sheet: "" });
    const snap = load(fs.readFileSync(target), kind);
    assert.equal(snap.records.length, 2);
    assert.deepEqual(snap.records.map((r) => r.program), ["anyDesk", "teamViewer"]);
    assert.ok(snap.diagnostics.columns.some((c) => c.field === "program"));
    assert.equal(snap.diagnostics.columns.length, kind === "xlsx" ? 11 : 6, "в XML пустые поля не пишутся; в .xlsx — и учётка, «Доступ», «Контакты»");
  }
  const cancelled = await templates.create({ kind: "xlsx", dialog: { showSaveDialog: async () => ({ canceled: true }) }, parent: null, setSettings() { assert.fail("не должно вызываться"); } });
  assert.equal(cancelled, "");
});
