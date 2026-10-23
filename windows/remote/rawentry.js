// Строка файла до проверки: все значения как есть, строками. Секреты (пароль, пароль учётки, «Доступ», «Контакты») сохраняются
// только при поиске секрета (mode "passwords"), при обычной загрузке — лишь признаки и число строк «Доступа». «Контакты»
// показываются только в карточке подробностей: читаются из файла по запросу, как «Доступ». 1:1 с Mac (`ConnectionsSource.swift`).
"use strict";

function newEntry(row) {
  return { row, name: "", id: "", password: "", hasPassword: false, group: "", tags: "", note: "", program: "",
    account: "", accountPassword: "", hasAccountPassword: false, access: "", accessLines: 0, contacts: "", hasContacts: false };
}

// Непустые строки многострочного текста (пустые строки между блоками не считаются).
function countLines(text) {
  return text ? text.split(/\r\n|[\n\r\v\f\u0085\u2028\u2029]/).filter((l) => l.trim()).length : 0;
}

function setField(entry, field, value, mode) {
  if (field === "password") {
    entry.hasPassword = value !== "";
    if (mode === "passwords") entry.password = value;
  } else if (field === "accountPassword") {
    entry.hasAccountPassword = value !== "";
    if (mode === "passwords") entry.accountPassword = value;
  } else if (field === "access") {
    // Переносы и пустые строки между блоками сохраняются; по краям — обрезка.
    const text = String(value).trim();
    entry.accessLines = countLines(text);
    if (mode === "passwords") entry.access = text;
  } else if (field === "contacts") {
    // Люди и телефоны: в памяти списка — только признак; текст (с переносами) — только при поиске секрета.
    const text = String(value).trim();
    entry.hasContacts = text !== "";
    if (mode === "passwords") entry.contacts = text;
  } else entry[field] = value;
}

// Секретное поле (только в режиме "passwords").
function secretOf(entry, field) {
  return field === "accountPassword" ? entry.accountPassword : field === "access" ? entry.access : field === "contacts" ? entry.contacts : entry.password;
}

const isBlank = (text) => !String(text).trim();
function isEmptyEntry(e) {
  return !e.hasPassword && !e.hasAccountPassword && !e.accessLines && [e.name, e.id, e.group, e.tags, e.note, e.program, e.account].every(isBlank);
}

module.exports = { newEntry, setField, secretOf, isEmptyEntry, countLines };
