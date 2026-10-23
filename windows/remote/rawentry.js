// Строка файла до проверки: все значения как есть, строками. Пароль сохраняется только при поиске пароля
// (mode "passwords"), при обычной загрузке — лишь признак. 1:1 с Mac (`ConnectionsSource.swift`).
"use strict";

function newEntry(row) {
  return { row, name: "", id: "", password: "", hasPassword: false, group: "", tags: "", note: "", program: "" };
}

function setField(entry, field, value, mode) {
  if (field === "password") {
    entry.hasPassword = value !== "";
    if (mode === "passwords") entry.password = value;
  } else entry[field] = value;
}

const isBlank = (text) => !String(text).trim();
function isEmptyEntry(e) {
  return !e.hasPassword && [e.name, e.id, e.group, e.tags, e.note, e.program].every(isBlank);
}

module.exports = { newEntry, setField, isEmptyEntry };
