// Поиск по названию, ID, группе, тегам, заметке и логину учётки («Доступ», пароли и контакты — никогда): без регистра и диакритики, по частям слов, ID — с пробелами и без. Ничего нет —
// запрос пробуется в другой раскладке («ctdth» → «север»). 1:1 с Mac (`ConnectionSearch.swift`).
"use strict";

const { alternatives } = require("./layouts");
const { displayTag } = require("./tags");

const MARKS = /\p{M}/gu;
// Регистр, диакритика («ё» = «е», «й» = «и»), ширина знаков; апострофы к одному виду.
function fold(s) {
  return String(s).normalize("NFKD").replace(MARKS, "").toLowerCase().replace(/[’ʼ]/g, "'");
}

class ConnectionSearch {
  constructor(records) {
    this.entries = records.map((record) => ({ record, name: fold(record.name), id: record.id, rest: fold([record.group, ...record.tags, ...record.tags.map(displayTag), record.note, record.account || ""].join("\u001F")) }));
  }

  get records() { return this.entries.map((e) => e.record); }

  // {records, hint: {typed, converted}|null, effectiveQuery}
  search(query) {
    const trimmed = String(query).trim();
    if (!trimmed) return { records: this.records, hint: null, effectiveQuery: "" };
    const found = this.matches(trimmed);
    if (found.length) return { records: found, hint: null, effectiveQuery: trimmed };
    for (const alt of alternatives(trimmed)) {
      const converted = this.matches(alt);
      if (converted.length) return { records: converted, hint: { typed: trimmed, converted: alt }, effectiveQuery: alt };
    }
    return { records: [], hint: null, effectiveQuery: trimmed };
  }

  matches(query) {
    const folded = fold(query);
    const tokens = folded.split(/\s+/).filter(Boolean);
    // ID набирают с пробелами («123 456») — сравниваем и без них.
    const compact = folded.replace(/\s/g, "");
    const scored = [];
    this.entries.forEach((e, index) => {
      const idHit = compact !== "" && e.id.includes(compact);
      const allTokens = tokens.every((t) => e.name.includes(t) || e.id.includes(t) || e.rest.includes(t));
      if (!idHit && !allTokens) return;
      scored.push({ score: score(e, folded, tokens[0] ?? folded, compact), index });
    });
    scored.sort((a, b) => a.score - b.score || a.index - b.index);
    return scored.map((s) => this.entries[s.index].record);
  }
}

// Чем меньше, тем выше: начало названия, начало слова в названии, часть названия, начало ID, остальное.
function score(e, folded, first, compact) {
  if (e.name.startsWith(folded)) return 0;
  if (e.name.split(/[^\p{L}\p{N}]+/u).some((w) => w && w.startsWith(first))) return 1;
  if (e.name.includes(first)) return 2;
  if (compact && e.id.startsWith(compact)) return 3;
  return 4;
}

// Складка текста с отображением в позиции исходной строки (складка может менять длину).
function foldWithMap(text) {
  let folded = "";
  const map = [];
  let at = 0;
  for (const ch of text) {
    const f = fold(ch);
    for (let k = 0; k < f.length; k++) map.push(at);
    folded += f;
    at += ch.length;
  }
  map.push(at);
  return { folded, map };
}

// Где в тексте встречаются слова запроса (без регистра и диакритики): [{start, end}] — для подсветки.
function highlights(text, query) {
  const { folded, map } = foldWithMap(text);
  const ranges = [];
  for (const token of fold(query).split(/\s+/).filter(Boolean)) {
    for (let from = 0; ;) {
      const i = folded.indexOf(token, from);
      if (i < 0) break;
      ranges.push({ start: map[i], end: map[i + token.length] });
      from = i + token.length;
    }
  }
  return merge(ranges);
}

// Подсветка в ID, показанном группами («123 456 789»): запрос сравнивается по цифрам, без пробелов.
function highlightsInID(display, query) {
  const compact = fold(query).replace(/\s/g, "");
  if (!compact) return [];
  const positions = [];
  [...display].forEach((ch, i) => { if (!/\s/.test(ch)) positions.push(i); });
  const plain = positions.map((i) => display[i]).join("").toLowerCase();
  const hit = plain.indexOf(compact);
  if (hit < 0) return highlights(display, query);
  return [{ start: positions[hit], end: positions[hit + compact.length - 1] + 1 }];
}

function merge(ranges) {
  const out = [];
  for (const r of [...ranges].sort((a, b) => a.start - b.start)) {
    const last = out[out.length - 1];
    if (last && r.start <= last.end) last.end = Math.max(last.end, r.end); else out.push({ ...r });
  }
  return out;
}

module.exports = { ConnectionSearch, fold, highlights, highlightsInID };
