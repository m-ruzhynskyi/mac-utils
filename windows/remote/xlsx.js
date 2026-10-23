// Чтение .xlsx: ZIP + XML, без внешних библиотек. Заголовки ищутся в первых 10 непустых строках (над таблицей бывает
// название). 1:1 с Mac (`XLSXSource.swift`).
"use strict";

const { ZipArchive } = require("./zip");
const xml = require("./xmlparse");
const { fieldFor } = require("./headers");
const { ConnectionsError } = require("./models");
const { newEntry, setField } = require("./rawentry");

const MAX_ROWS = 100_000;
const MAX_COLUMNS = 200;
const HEADER_SEARCH_ROWS = 10;
const corrupt = (text) => new ConnectionsError("corrupt", text);

function workbook(zip) {
  const wb = zip.contents("xl/workbook.xml");
  if (!wb) throw corrupt("Это не книга Excel");
  const refs = [];
  xml.parse(wb, { start(name, a) { if (name === "sheet" && a.name != null) refs.push({ name: a.name, rid: a["r:id"] ?? Object.entries(a).find(([k]) => k.endsWith(":id"))?.[1] ?? "" }); } });
  const targets = new Map();
  const rels = zip.contents("xl/_rels/workbook.xml.rels");
  if (rels) xml.parse(rels, { start(name, a) { if (name === "Relationship" && a.Id != null && a.Target != null) targets.set(a.Id, a.Target); } });
  const sheets = refs.filter((r) => targets.has(r.rid)).map((r) => {
    const t = targets.get(r.rid);
    return { name: r.name, path: t.startsWith("/") ? t.slice(1) : "xl/" + t };
  });
  if (!sheets.length) throw corrupt("В книге нет листов");
  return sheets;
}

// Имена листов (для выбора в настройках).
function sheetNames(data) { return workbook(new ZipArchive(data)).map((s) => s.name); }

function sharedStrings(data) {
  const out = [];
  let current = "", inItem = false, inText = false, phonetic = 0;
  xml.parse(data, {
    start(name) { if (name === "si") { inItem = true; current = ""; } else if (name === "rPh") phonetic++; else if (name === "t") inText = inItem && phonetic === 0; },
    text(t) { if (inText) current += t; },
    cdata(t) { if (inText) current += t; },
    end(name) { if (name === "si") { out.push(current); inItem = false; } else if (name === "rPh") phonetic--; else if (name === "t") inText = false; },
  });
  return out;
}

// «AB12» → 27 (с нуля).
function columnIndex(ref) {
  let n = 0;
  for (const ch of ref) {
    const c = ch.charCodeAt(0);
    if (!((c >= 65 && c <= 90) || (c >= 97 && c <= 122))) break;
    n = n * 26 + (c & 0x1F);
  }
  return Math.max(n - 1, 0);
}

function sheetRows(data, shared) {
  const rows = [];
  let rowNumber = 0, cells = [], column = 0, type = "", value = "";
  let inValue = false, inInline = false, inInlineText = false, phonetic = 0;
  const store = () => {
    if (column >= MAX_COLUMNS) return;
    let text;
    if (type === "s") { const i = parseInt(value.trim(), 10); text = Number.isInteger(i) && i >= 0 && i < shared.length ? shared[i] : ""; }
    else if (type === "b") text = value === "1" ? "TRUE" : "FALSE";
    else if (type === "e") text = "";
    else text = value;
    while (cells.length <= column) cells.push("");
    cells[column] = text;
  };
  xml.parse(data, {
    start(name, a) {
      if (name === "row") {
        rowNumber = a.r != null && /^\d+$/.test(a.r) ? parseInt(a.r, 10) : rowNumber + 1;
        cells = [];
        if (rows.length >= MAX_ROWS) throw new ConnectionsError("tooLarge");
      } else if (name === "c") { column = a.r != null ? columnIndex(a.r) : cells.length; type = a.t ?? ""; value = ""; }
      else if (name === "v") inValue = true;
      else if (name === "is") inInline = true;
      else if (name === "rPh") phonetic++;
      else if (name === "t") inInlineText = inInline && phonetic === 0;
    },
    text(t) { if (inValue || inInlineText) value += t; },
    cdata(t) { if (inValue || inInlineText) value += t; },
    end(name) {
      if (name === "v") inValue = false;
      else if (name === "is") inInline = false;
      else if (name === "rPh") phonetic--;
      else if (name === "t") inInlineText = false;
      else if (name === "c") store();
      else if (name === "row") { if (cells.some((c) => c !== "")) rows.push({ number: rowNumber, cells }); }
    },
  });
  return rows;
}

function entriesFrom(rows, mode) {
  if (!rows.length) throw new ConnectionsError("missingColumns", "", { found: [] });
  const candidates = rows.slice(0, HEADER_SEARCH_ROWS);
  let headerIdx = candidates.findIndex((r) => {
    const fields = new Set(r.cells.map(fieldFor).filter(Boolean));
    return fields.has("name") && fields.has("id");
  });
  if (headerIdx < 0) headerIdx = 0;
  const columns = new Map(), matched = [], unrecognized = [], found = [];
  rows[headerIdx].cells.forEach((raw, i) => {
    const title = raw.trim();
    if (!title) return;
    found.push(title);
    const f = fieldFor(title);
    // Вторая колонка того же поля не читается — показываем её как нераспознанную.
    if (f && !columns.has(f)) { columns.set(f, i); matched.push({ title, field: f, column: i }); }
    else unrecognized.push(title);
  });
  if (!columns.has("name") || !columns.has("id")) throw new ConnectionsError("missingColumns", "", { found });
  const entries = [];
  for (const row of rows.slice(headerIdx + 1)) {
    const e = newEntry(row.number);
    for (const [field, col] of columns) if (col < row.cells.length) setField(e, field, row.cells[col], mode);
    entries.push(e);
  }
  return { entries, columns: matched, unrecognizedColumns: unrecognized };
}

// sheet — имя листа (null — первый). mode: "records" | "passwords".
function parse(data, mode, sheet = null) {
  const zip = new ZipArchive(data);
  const sheets = workbook(zip);
  let target = sheets[0];
  if (sheet) {
    target = sheets.find((s) => s.name === sheet);
    if (!target) throw new ConnectionsError("noSheet", sheet);
  }
  const sheetXML = zip.contents(target.path);
  if (!sheetXML) throw corrupt("Нет данных листа");
  const sst = zip.contents("xl/sharedStrings.xml");
  return entriesFrom(sheetRows(sheetXML, sst ? sharedStrings(sst) : []), mode);
}

module.exports = { parse, sheetNames, columnIndex };
