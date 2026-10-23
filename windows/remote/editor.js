// Правка списка в .xml: добавить, изменить, удалить запись. Байты вне записи не меняются (правится только нужный фрагмент
// текста), перед записью — `<имя>.bak` с теми же правами, запись во временный файл рядом и атомарная подмена, после записи файл
// перечитывается — не прочитался, возвращается копия. .xlsx не пишется никогда.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const xml = require("./xmlparse");
const { fieldFor } = require("./headers");
const { normalize } = require("./id");
const { parseProgram, supportsAliases, ConnectionsError } = require("./models");
const { load } = require("./source");

const FIELD_TAG = { name: "name", id: "id", password: "password", group: "group", tags: "tags", note: "note", program: "app" };
const ORDER = ["name", "id", "password", "group", "tags", "note", "program"];
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// Элементы <connection>: {row, start, end, children: [{field|null, name, start, end}], text}
function scan(text) {
  const items = [];
  let depth = 0, current = null, rootClose = -1, rootOpenEnd = -1;
  xml.parse(text, {
    start(name, attrs, line, start, openEnd) {
      depth++;
      if (depth === 1) rootOpenEnd = openEnd;
      if (depth === 2 && name.toLowerCase() === "connection") current = { row: line, start, end: -1, children: [], attrs, selfClosed: false, openEnd };
      else if (depth === 3 && current) current.children.push({ field: fieldFor(name), name, start, end: -1 });
    },
    end(name, endOffset) {
      if (depth === 3 && current) current.children[current.children.length - 1].end = endOffset;
      if (depth === 2 && current) { current.end = endOffset; items.push(current); current = null; }
      if (depth === 1) rootClose = endOffset - ("</connections>".length);
      depth--;
    },
  });
  return { items, rootClose: text.lastIndexOf("</"), rootOpenEnd };
}

const eolOf = (text) => (text.includes("\r\n") ? "\r\n" : "\n");

function validate(fields, { forAdd = false } = {}) {
  const name = String(fields.name ?? "").trim(), rawID = String(fields.id ?? "").trim();
  if (!name) return { error: "missingName" };
  if (!rawID) return { error: "missingID" };
  const id = normalize(rawID);
  if (!id) return { error: "invalidID" };
  const programText = String(fields.program ?? "").trim();
  let program = "";
  if (programText) {
    const p = parseProgram(programText);
    if (!p) return { error: "unknownProgram" };
    if (id.isAlias && !supportsAliases(p)) return { error: "aliasNotSupported" };
    program = p === "anyDesk" ? "AnyDesk" : "TeamViewer";
  }
  return { value: { name, id: id.value, password: String(fields.password ?? ""), group: String(fields.group ?? "").trim(), tags: String(fields.tags ?? "").trim(), note: String(fields.note ?? "").trim(), program } };
}

// Текст записи; extra — неизвестные дочерние элементы, сохраняются как есть.
function serialize(value, indent, eol, extra = []) {
  const lines = [];
  for (const field of ORDER) {
    if (value[field] === "" && field !== "name" && field !== "id") continue;
    lines.push(`${indent}${indent}<${FIELD_TAG[field]}>${esc(value[field])}</${FIELD_TAG[field]}>`);
  }
  for (const e of extra) lines.push(`${indent}${indent}${e}`);
  return `<connection>${eol}${lines.join(eol)}${eol}${indent}</connection>`;
}

function indentOf(text, items) {
  const first = items[0];
  if (!first) return "  ";
  const lineStart = text.lastIndexOf("\n", first.start - 1) + 1;
  const lead = text.slice(lineStart, first.start);
  return /^[ \t]*$/.test(lead) && lead ? lead : "  ";
}

// Находит запись по номеру строки и ID (как в списке). null — файл успели поправить.
function locate(text, record, items) {
  const wanted = items.find((it) => it.row === record.sourceRow && recordID(text, it) === record.id);
  if (wanted) return wanted;
  const same = items.filter((it) => recordID(text, it) === record.id && nameOf(text, it) === record.name);
  return same.length === 1 ? same[0] : null;
}
function childText(text, it, field) {
  const child = it.children.find((c) => c.field === field);
  if (child) { const inner = text.slice(child.start, child.end); return xml.decode(inner.replace(/^<[^>]*>/, "").replace(/<\/[^>]*>$/, "").replace(/^<!\[CDATA\[([\s\S]*)\]\]>$/, "$1")).trim(); }
  for (const [k, v] of Object.entries(it.attrs || {})) if (fieldFor(k) === field) return String(v).trim();
  return "";
}
const recordID = (text, it) => normalize(childText(text, it, "id"))?.value ?? "";
const nameOf = (text, it) => childText(text, it, "name");

// Запись текста в файл: .bak с теми же правами → временный файл → подмена → проверка.
function writeSafely(file, original, next, bom) {
  const bak = `${file}.bak`;
  let mode = 0o600;
  try { mode = fs.statSync(file).mode & 0o777; } catch (_) {}
  fs.copyFileSync(file, bak);
  try { fs.chmodSync(bak, mode); } catch (_) {}
  const tmp = `${file}.tmp-${process.pid}`;
  try {
    fs.writeFileSync(tmp, (bom ? "﻿" : "") + next, { encoding: "utf8", mode });
    fs.renameSync(tmp, file);
    load(fs.readFileSync(file), "xml");        // перечитывается: файл должен быть корректным
  } catch (error) {
    try { fs.copyFileSync(bak, file); } catch (_) {}
    try { fs.rmSync(tmp, { force: true }); } catch (_) {}
    throw new ConnectionsError("corrupt", "Не удалось сохранить файл");
  }
}

function read(file) {
  if (path.extname(file).toLowerCase() !== ".xml") throw new ConnectionsError("type", "xlsx-readonly");
  const raw = fs.readFileSync(file, "utf8");
  const bom = raw.charCodeAt(0) === 0xFEFF;
  return { text: bom ? raw.slice(1) : raw, bom };
}

// action: add | update | remove. record — запись списка (для update/remove); fields — поля формы.
// Возвращает {ok:true} или {ok:false, error}.
function apply(file, action, { record = null, fields = {} } = {}) {
  let doc;
  try { doc = read(file); } catch (e) { return { ok: false, error: e.code === "type" ? "xlsxReadOnly" : "unavailable" }; }
  const { text, bom } = doc;
  let scanned;
  try { scanned = scan(text); } catch (_) { return { ok: false, error: "corrupt" }; }
  const eol = eolOf(text), indent = indentOf(text, scanned.items);
  let next;
  if (action === "add") {
    const checked = validate(fields, { forAdd: true });
    if (checked.error) return { ok: false, error: checked.error };
    const at = scanned.rootClose;
    if (at < 0) return { ok: false, error: "corrupt" };
    // Перед закрывающим тегом корня: после последней записи, с тем же отступом.
    const before = text.slice(0, at).replace(/[ \t]*$/, "");
    const lead = before.endsWith("\n") ? "" : eol;
    next = `${before}${lead}${indent}${serialize(checked.value, indent, eol)}${eol}${text.slice(at)}`;
  } else {
    const target = record && locate(text, record, scanned.items);
    if (!target) return { ok: false, error: "gone" };
    if (action === "remove") {
      const lineStart = text.lastIndexOf("\n", target.start - 1) + 1;
      const from = /^[ \t]*$/.test(text.slice(lineStart, target.start)) ? lineStart : target.start;
      let to = target.end;
      if (text.startsWith("\r\n", to)) to += 2; else if (text[to] === "\n") to += 1;
      next = text.slice(0, from) + text.slice(to);
    } else if (action === "update") {
      const checked = validate({ password: childText(text, target, "password"), ...fields });
      if (checked.error) return { ok: false, error: checked.error };
      const extra = target.children.filter((c) => !c.field).map((c) => text.slice(c.start, c.end));
      const lineStart = text.lastIndexOf("\n", target.start - 1) + 1;
      const lead = text.slice(lineStart, target.start);
      const myIndent = /^[ \t]*$/.test(lead) && lead ? lead : indent;
      next = text.slice(0, target.start) + serialize(checked.value, myIndent, eol, extra) + text.slice(target.end);
    } else return { ok: false, error: "action" };
  }
  try { writeSafely(file, text, next, bom); } catch (_) { return { ok: false, error: "writeFailed" }; }
  return { ok: true };
}

module.exports = { apply, validate, scan };
