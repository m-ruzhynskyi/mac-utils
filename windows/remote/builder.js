// Сырые строки → записи без паролей + диагностика. 1:1 с Mac (`ConnectionsBuilder.swift`).
"use strict";

const { normalize } = require("./id");
const { parseProgram, supportsAliases, emptyDiagnostics } = require("./models");
const { isEmptyEntry } = require("./rawentry");

function splitTags(raw) {
  const seen = new Set();
  return raw.split(/[,;]/).map((t) => t.trim()).filter((t) => t && !seen.has(t.toLowerCase()) && seen.add(t.toLowerCase()));
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
    if (!rawID) { skip("missingID", ""); continue; }
    const id = normalize(rawID);
    if (!id) { skip("invalidID", rawID); continue; }
    const programText = e.program.trim();
    let program = null;
    if (programText) {
      program = parseProgram(programText);
      if (!program) { skip("unknownProgram", programText); continue; }
    }
    if (program && id.isAlias && !supportsAliases(program)) { skip("aliasNotSupported", rawID); continue; }
    if (id.lossy) diag.lossyIDRows.push(e.row);
    records.push({ sourceRow: e.row, name, id: id.value, group: e.group.trim(), tags: splitTags(e.tags), note: e.note.trim(), program, hasPassword: e.hasPassword });
  }
  // Без программы и не алиас — возьмётся программа по умолчанию. Если в файле есть обе программы, это стоит показать.
  const named = new Set(records.map((r) => r.program).filter(Boolean));
  if (named.size > 1) diag.ambiguousProgramRows = records.filter((r) => !r.program && !r.id.includes("@")).map((r) => r.sourceRow);
  diag.duplicates = duplicates(records);
  diag.loaded = records.length;
  diag.withPassword = records.filter((r) => r.hasPassword).length;
  return { records, diagnostics: diag };
}

// Один ID несколько раз. Не дубликат — только если у всех строк явно указаны разные программы.
function duplicates(records) {
  const byID = new Map();
  for (const r of records) { if (!byID.has(r.id)) byID.set(r.id, []); byID.get(r.id).push(r); }
  const out = [];
  for (const [id, group] of byID) {
    if (group.length < 2) continue;
    const programs = group.map((r) => r.program).filter(Boolean);
    if (programs.length === group.length && new Set(programs).size === programs.length) continue;
    out.push({ id, rows: group.map((r) => r.sourceRow), names: group.map((r) => r.name) });
  }
  return out;
}

module.exports = { build, splitTags };
