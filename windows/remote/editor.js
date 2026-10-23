// Правка списка в .xml: добавить, изменить, удалить запись. Байты вне записи не меняются (правится только нужный фрагмент
// текста), перед записью — `<имя>.bak` с теми же правами, запись во временный файл рядом и атомарная подмена, после записи файл
// перечитывается — не прочитался, возвращается копия. .xlsx не пишется никогда. «Доступ» и «Контакты» правкой не трогаются —
// их байты остаются как есть.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const xml = require("./xmlparse");
const { fieldFor } = require("./headers");
const { normalize } = require("./id");
const { parseProgram, parseMethod, METHOD_TITLES, supportsAliases, ConnectionsError } = require("./models");
const { idKey } = require("./builder");
const { load } = require("./source");

const FIELD_TAG = { name: "name", id: "id", password: "password", group: "group", tags: "tags", note: "note", program: "app",
  account: "account", accountPassword: "accountPassword", access: "access", contacts: "contacts" };
// Поля, которые пишет правка. access и contacts здесь нет: их байты не меняются.
const ORDER = ["name", "id", "password", "group", "tags", "note", "program", "account", "accountPassword"];
// Пароли — как записаны (пробелы по краям бывают частью пароля), остальное — с обрезкой.
const RAW = new Set(["password", "accountPassword"]);
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
      // Закрывающий тег корня — а не последнее «</» в файле (после корня бывает комментарий с «</x>»).
      if (depth === 1) rootClose = text.lastIndexOf("</", endOffset - 1);
      depth--;
    },
  });
  return { items, rootClose, rootOpenEnd };
}

const eolOf = (text) => (text.includes("\r\n") ? "\r\n" : "\n");

function validate(fields, { forAdd = false } = {}) {
  const name = String(fields.name ?? "").trim(), rawID = String(fields.id ?? "").trim();
  if (!name) return { error: "missingName" };
  const programText = String(fields.program ?? "").trim();
  let p = null, method = null;
  if (programText) {
    p = parseProgram(programText);
    if (!p) method = parseMethod(programText);
    if (!p && !method) return { error: "unknownProgram" };
  }
  let id;
  if (method) id = idKey(rawID);   // RDP/VPN/«Другое»: ID не обязателен, адрес — как есть
  else {
    if (!rawID) return { error: "missingID" };
    const n = normalize(rawID);
    if (!n) return { error: "invalidID" };
    if (p && n.isAlias && !supportsAliases(p)) return { error: "aliasNotSupported" };
    id = n.value;
  }
  const program = method ? METHOD_TITLES[method] : p ? (p === "anyDesk" ? "AnyDesk" : "TeamViewer") : "";
  return { value: { name, id, password: String(fields.password ?? ""), group: String(fields.group ?? "").trim(), tags: String(fields.tags ?? "").trim(), note: String(fields.note ?? "").trim(), program,
    account: String(fields.account ?? "").trim(), accountPassword: String(fields.accountPassword ?? "") } };
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
  // Номер строки и ID; если так подходят несколько записей (весь XML в одной строке, одинаковый ID) — выбирает имя.
  const sameRow = items.filter((it) => it.row === record.sourceRow && recordID(text, it) === record.id);
  if (sameRow.length === 1) return sameRow[0];
  if (sameRow.length > 1) { const byName = sameRow.filter((it) => nameOf(text, it) === record.name); return byName.length === 1 ? byName[0] : null; }
  const same = items.filter((it) => recordID(text, it) === record.id && nameOf(text, it) === record.name);
  return same.length === 1 ? same[0] : null;
}
// Значение поля записи (тег или атрибут). Пароль — без обрезки пробелов по краям.
function childText(text, it, field) {
  const trim = (v) => (RAW.has(field) ? v : v.trim());
  const child = it.children.find((c) => c.field === field);
  if (child) {
    const inner = text.slice(child.start, child.end).replace(/^<[^>]*>/, "").replace(/<\/[^>]*>$/, "");
    const cdata = /^\s*<!\[CDATA\[([\s\S]*)\]\]>\s*$/.exec(inner);
    return trim(cdata ? cdata[1] : xml.decode(inner));
  }
  for (const [k, v] of Object.entries(it.attrs || {})) if (fieldFor(k) === field) return trim(String(v));
  return "";
}
const recordID = (text, it) => idKey(childText(text, it, "id"));
const nameOf = (text, it) => childText(text, it, "name");

// Windows: права POSIX сводятся к атрибуту «только для чтения» (stat даёт 0o666/0o444), а подмена файла и удаление
// read-only файла падают с EPERM — перед ними атрибут снимается, после записи возвращается.
const isWin = () => process.platform === "win32";
const readOnly = (file) => { try { return (fs.statSync(file).mode & 0o200) === 0; } catch (_) { return false; } };
function makeWritable(file) { if (isWin() && readOnly(file)) { try { fs.chmodSync(file, 0o666); } catch (_) {} } }
function sleep(ms) { try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch (_) {} }

// Подмена может на миг упереться в антивирус/индексатор, держащий файл: на Windows несколько коротких повторов.
function replace(tmp, file) {
  for (let attempt = 0; ; attempt++) {
    try { return fs.renameSync(tmp, file); } catch (error) {
      if (!isWin() || attempt >= 4 || !["EPERM", "EBUSY", "EACCES"].includes(error.code)) throw error;
      sleep(40 * (attempt + 1));
    }
  }
}

// Запись текста в файл: .bak с теми же правами → временный файл → подмена → проверка.
function writeSafely(file, original, next, bom) {
  const bak = `${file}.bak`;
  let mode = 0o600;
  try { mode = fs.statSync(file).mode & 0o777; } catch (_) {}
  // Прежняя копия могла остаться только для чтения (права скопированы с файла): убираем, иначе новую не записать.
  makeWritable(bak);
  try { fs.rmSync(bak, { force: true }); } catch (_) {}
  fs.copyFileSync(file, bak);
  try { fs.chmodSync(bak, mode); } catch (_) {}
  const tmp = `${file}.tmp-${process.pid}`;
  try {
    // Временный файл всегда записываемый (на Windows read-only tmp не удалить при ошибке); права файла возвращаются после подмены.
    fs.writeFileSync(tmp, (bom ? "﻿" : "") + next, { encoding: "utf8", mode: isWin() ? 0o666 : mode });
    makeWritable(file);
    replace(tmp, file);
    try { fs.chmodSync(file, mode); } catch (_) {}
    load(fs.readFileSync(file), "xml");        // перечитывается: файл должен быть корректным
  } catch (error) {
    makeWritable(file);
    try { fs.copyFileSync(bak, file); } catch (_) {}
    try { fs.chmodSync(file, mode); } catch (_) {}
    makeWritable(tmp);
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

// Правка записи по полям: меняются только те поля, что изменились; форма записи (теги или атрибуты), CDATA, комментарии внутри записи,
// неизвестные теги и отступы остаются. value — проверенные значения формы.
const attrEsc = (s) => esc(s).replace(/"/g, "&quot;");
function sameValue(field, current, wanted) {
  if (field === "id") return idKey(current) === wanted;
  if (field === "tags") return require("./builder").splitTags(current).join("\u0001") === require("./builder").splitTags(wanted).join("\u0001");
  if (field === "program") return (parseProgram(current) || "") === (parseProgram(wanted) || "") && (parseMethod(current) || "") === (parseMethod(wanted) || "")
    && !current.trim() === !wanted;
  return current === wanted;
}
function patchRecord(text, target, value, eol, indent) {
  const patches = [];   // {start, end, text}: правки не пересекаются
  const openTag = text.slice(target.start, target.openEnd);
  const selfClosed = openTag.endsWith("/>");
  const closeStart = selfClosed ? -1 : text.lastIndexOf("</", target.end - 1);
  const lineStart = text.lastIndexOf("\n", target.start - 1) + 1;
  const lead = text.slice(lineStart, target.start);
  const myIndent = /^[ \t]*$/.test(lead) && lead ? lead : "";
  const childIndent = (() => {
    const first = target.children[0];
    if (first) { const ls = text.lastIndexOf("\n", first.start - 1) + 1; const l = text.slice(ls, first.start); if (/^[ \t]+$/.test(l)) return l; }
    return myIndent + indent;
  })();
  for (const field of ORDER) {
    const wanted = value[field];
    const current = childText(text, target, field);
    if (sameValue(field, current, wanted)) continue;
    const child = target.children.find((c) => c.field === field);
    const optional = field !== "name" && field !== "id";
    if (child) {
      const childOpenEnd = text.indexOf(">", child.start) + 1;
      const childSelf = text[childOpenEnd - 2] === "/";
      if (wanted === "" && optional) {
        // Убрать элемент вместе с его строкой.
        const ls = text.lastIndexOf("\n", child.start - 1) + 1;
        const from = /^[ \t]*$/.test(text.slice(ls, child.start)) ? ls : child.start;
        let to = child.end; if (text.startsWith("\r\n", to)) to += 2; else if (text[to] === "\n") to += 1;
        patches.push({ start: from, end: to, text: "" });
      } else {
        const wasCdata = /<!\[CDATA\[/.test(text.slice(child.start, child.end));
        const inner = wasCdata && !wanted.includes("]]>") ? `<![CDATA[${wanted}]]>` : esc(wanted);
        if (childSelf) patches.push({ start: child.start, end: child.end, text: `${text.slice(child.start, childOpenEnd - 2).trimEnd()}>${inner}</${child.name}>` });
        else patches.push({ start: childOpenEnd, end: text.lastIndexOf("</", child.end - 1), text: inner });
      }
      continue;
    }
    // Атрибутная форма: <connection name="…" id="…"/>.
    const attr = Object.keys(target.attrs || {}).find((k) => fieldFor(k) === field);
    if (attr) {
      const re = new RegExp(`(\\s)${attr.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*=\\s*("[^"]*"|'[^']*')`);
      const m = re.exec(openTag);
      if (m) {
        const at = target.start + m.index;
        if (wanted === "" && optional) patches.push({ start: at, end: at + m[0].length, text: "" });
        else patches.push({ start: at + m[1].length, end: at + m[0].length, text: `${attr}="${attrEsc(wanted)}"` });
        continue;
      }
    }
    if (wanted === "" ) continue;
    // Поля нет — добавить: атрибутом в самозакрытую запись, иначе элементом перед закрывающим тегом.
    if (selfClosed) {
      const at = target.openEnd - 2 - (/\s$/.test(text.slice(target.openEnd - 3, target.openEnd - 2)) ? 1 : 0);
      patches.push({ start: at, end: at, text: ` ${FIELD_TAG[field]}="${attrEsc(wanted)}"` });
    } else {
      const ls = text.lastIndexOf("\n", closeStart - 1) + 1;
      const onOwnLine = /^[ \t]*$/.test(text.slice(ls, closeStart));
      const at = onOwnLine ? ls : closeStart;
      patches.push({ start: at, end: at, text: onOwnLine ? `${childIndent}<${FIELD_TAG[field]}>${esc(wanted)}</${FIELD_TAG[field]}>${eol}` : `<${FIELD_TAG[field]}>${esc(wanted)}</${FIELD_TAG[field]}>` });
    }
  }
  if (!patches.length) return text;
  patches.sort((a, b) => b.start - a.start || b.end - a.end);
  let out = text;
  for (const p of patches) out = out.slice(0, p.start) + p.text + out.slice(p.end);
  return out;
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
      // Пароли, которых нет в форме, не меняются: берутся из файла ("" — убрать, строка — новый).
      const given = { ...fields };
      for (const f of RAW) if (typeof given[f] !== "string") delete given[f];
      const checked = validate({ password: childText(text, target, "password"), accountPassword: childText(text, target, "accountPassword"), ...given });
      if (checked.error) return { ok: false, error: checked.error };
      next = patchRecord(text, target, checked.value, eol, indent);
      if (next === text) return { ok: true };   // ничего не изменилось — файл и .bak не трогаем
    } else return { ok: false, error: "action" };
  }
  try { writeSafely(file, text, next, bom); } catch (_) { return { ok: false, error: "writeFailed" }; }
  return { ok: true };
}

module.exports = { apply, validate, scan };
