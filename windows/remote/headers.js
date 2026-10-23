// Названия колонок XLSX и тегов XML на русском, украинском и английском. Регистр, пробелы и знаки не важны.
// 1:1 с Mac (`ConnectionHeaders.swift`).
"use strict";

const FIELDS = ["name", "id", "password", "group", "tags", "note", "program"];

const ALIASES = {
  name: ["name", "название", "назва", "имя", "імя", "computer", "компьютер", "компютер"],
  id: ["id", "ид", "ід", "anydesk", "anydeskid", "idanydesk", "teamviewer", "teamviewerid", "idteamviewer",
    "anydeskteamviewer", "idanydeskteamviewer", "адрес", "адреса", "address",
    "идентификатор", "ідентифікатор", "номер"],
  password: ["password", "pass", "pwd", "пароль"],
  group: ["group", "группа", "група"],
  tags: ["tags", "tag", "теги", "тэги", "тег"],
  note: ["note", "notes", "заметка", "заметки", "примітка", "примітки", "комментарий", "коментар"],
  program: ["program", "app", "application", "программа", "програма", "приложение", "додаток"],
};

const LOOKUP = new Map();
for (const [field, names] of Object.entries(ALIASES)) for (const n of names) LOOKUP.set(n, field);

// Ключ сравнения: только буквы и цифры в нижнем регистре, «ё» = «е».
function key(text) {
  return String(text).toLowerCase().replace(/[^\p{L}\p{N}]/gu, "").replace(/ё/g, "е");
}

// Поле, которому соответствует заголовок, или null.
function fieldFor(header) {
  return LOOKUP.get(key(header)) || null;
}

module.exports = { FIELDS, key, fieldFor };
