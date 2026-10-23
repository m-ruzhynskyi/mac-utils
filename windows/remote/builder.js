// Сырые строки → записи без секретов + диагностика. 1:1 с Mac (`ConnectionsBuilder.swift`).
"use strict";

const { normalize } = require("./id");
const { parseProgram, parseMethod, supportsAliases, emptyDiagnostics } = require("./models");
const { isEmptyEntry } = require("./rawentry");
const { tagKey } = require("./tags");

// Теги через «,» или «;»; «Рег» и «рег.» — одна метка (первое написание остаётся).
function splitTags(raw) {
  const seen = new Set();
  return String(raw).split(/[,;]/).map((t) => t.trim()).filter((t) => t && !seen.has(tagKey(t)) && seen.add(tagKey(t)));
}

// Ключ ID для сопоставления строк файла: ID AnyDesk/TeamViewer — нормализованный, иначе (адрес RDP, пусто) — как есть.
function idKey(raw) {
  const t = String(raw).trim();
  return t ? normalize(t)?.value ?? t : "";
}

function build(file) {
  const diag = emptyDiagnostics();
  diag.columns = file.columns;
  diag.unrecognizedColumns = file.unrecognizedColumns;
  const records = [];
  for (const e of file.entries) {
    if (isEmptyEntry(e)) continue;
    const name = e.name.trim(), rawID = e.id.trim();
    const skip = (reason, value) => diag.skipped.push({ row: e.row, reason, value });
    if (!name) { skip("missingName", ""); continue; }
    const programText = e.program.trim();
    let program = null, method = null;
    if (programText) {
      program = parseProgram(programText);
      if (!program) method = parseMethod(programText);
      if (!program && !method) { skip("unknownProgram", programText); continue; }
    }
    let idValue;
    if (method) {
      // RDP/VPN/«Другое»: ID не обязателен; для RDP это адрес (IP или имя) — не нормализуется как ID AnyDesk.
      idValue = idKey(rawID);
    } else {
      if (!rawID) { skip("missingID", ""); continue; }
      const id = normalize(rawID);
      if (!id) { skip("invalidID", rawID); continue; }
      if (program && id.isAlias && !supportsAliases(program)) { skip("aliasNotSupported", rawID); continue; }
      if (id.lossy) diag.lossyIDRows.push(e.row);
      idValue = id.value;
    }
    records.push({ sourceRow: e.row, name, id: idValue, group: e.group.trim(), tags: splitTags(e.tags), note: e.note.trim(), program, hasPassword: e.hasPassword,
      method, account: e.account.trim(), hasAccountPassword: e.hasAccountPassword, accessLines: e.accessLines });
  }
  // Без программы и не алиас — возьмётся программа по умолчанию. Если в файле есть обе программы, это стоит показать.
  const named = new Set(records.map((r) => r.program).filter(Boolean));
  if (named.size > 1) diag.ambiguousProgramRows = records.filter((r) => !r.program && !r.method && !r.id.includes("@")).map((r) => r.sourceRow);
  diag.duplicates = duplicates(records);
  diag.loaded = records.length;
  diag.withPassword = records.filter((r) => r.hasPassword).length;
  return { records, diagnostics: diag };
}

// Один ID несколько раз. Не дубликат — только если у всех строк явно указаны разные программы. Записи без ID (RDP/VPN/«Другое»)
// дубликатами не считаются.
function duplicates(records) {
  const byID = new Map();
  for (const r of records) { if (!r.id) continue; if (!byID.has(r.id)) byID.set(r.id, []); byID.get(r.id).push(r); }
  const out = [];
  for (const [id, group] of byID) {
    if (group.length < 2) continue;
    const programs = group.map((r) => r.program).filter(Boolean);
    if (programs.length === group.length && new Set(programs).size === programs.length) continue;
    out.push({ id, rows: group.map((r) => r.sourceRow), names: group.map((r) => r.name) });
  }
  return out;
}

module.exports = { build, splitTags, idKey };
