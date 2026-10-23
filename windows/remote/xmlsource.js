// Чтение .xml: <connections><connection><name/><id/><password/><group/><tags/><note/><app/></connection></connections>.
// Поля можно задать и атрибутами <connection name="…" id="…"/>. Номер «строки» записи — строка файла, на которой открывается
// <connection>. 1:1 с Mac (`XMLSource.swift`).
"use strict";

const xml = require("./xmlparse");
const { fieldFor } = require("./headers");
const { ConnectionsError } = require("./models");
const { newEntry, setField } = require("./rawentry");

function parse(data, mode) {
  const entries = [], columns = [], unrecognized = [];
  let depth = 0, sawRoot = false, current = null, field = null, text = "";
  const recognize = (name) => {
    const f = fieldFor(name);
    if (!f) { if (!unrecognized.includes(name)) unrecognized.push(name); return null; }
    if (!columns.some((c) => c.field === f)) columns.push({ title: name, field: f, column: null });
    return f;
  };
  xml.parse(data, {
    start(name, attrs, line) {
      depth++;
      if (depth === 1) {
        if (name.toLowerCase() !== "connections") throw new ConnectionsError("corrupt", "Ожидался корневой элемент connections");
        sawRoot = true;
      } else if (depth === 2) {
        if (name.toLowerCase() !== "connection") return;
        const entry = newEntry(line);
        for (const key of Object.keys(attrs).sort()) {
          const f = recognize(key);
          if (f) setField(entry, f, f === "password" || f === "accountPassword" ? attrs[key] : attrs[key].trim(), mode);
        }
        current = entry;
      } else if (depth === 3 && current) { text = ""; field = recognize(name); }
    },
    text(t) { if (field) text += t; },
    cdata(t) { if (field) text += t; },
    end() {
      // Пароль и пароль учётки — как записаны: пробелы по краям бывают частью пароля.
      if (depth === 3 && field) { setField(current, field, field === "password" || field === "accountPassword" ? text : text.trim(), mode); field = null; text = ""; }
      if (depth === 2 && current) { entries.push(current); current = null; }
      depth--;
    },
  });
  if (!sawRoot) throw new ConnectionsError("corrupt", "Ожидался корневой элемент connections");
  return { entries, columns, unrecognizedColumns: unrecognized };
}

module.exports = { parse };
