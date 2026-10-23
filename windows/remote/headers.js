// Названия колонок XLSX и тегов XML на русском, украинском и английском. Регистр, пробелы и знаки не важны.
// 1:1 с Mac (`ConnectionHeaders.swift`).
"use strict";

const FIELDS = ["name", "id", "password", "group", "tags", "note", "program", "account", "accountPassword", "access", "contacts"];
// Значение не держится в памяти списка: читается из файла по запросу и затирается (пароль, пароль учётки, «Доступ»).
const SECRET_FIELDS = new Set(["password", "accountPassword", "access"]);
const isSecret = (field) => SECRET_FIELDS.has(field);

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
  // Учётка Windows. «Пароль» сам по себе — пароль AnyDesk/TeamViewer; пароль учётки — только с уточнением.
  account: ["account", "login", "user", "username", "учетнаязапись", "учетка", "логин", "логін", "користувач", "обліковийзапис", "windowsuser"],
  accountPassword: ["accountpassword", "windowspassword", "парольучетнойзаписи", "парольучетки", "парольwindows", "парольобліковогозапису"],
  // «Доступ»: всё прочее с вкладки (VPN, RDP, IP, логины и пароли) — как секрет: не в поиске, не в журнале.
  access: ["доступ", "access", "подробности", "деталі", "details", "vpnrdp", "подключение", "підключення"],
  // «Контакты»: колонка известна (не «лишняя»), но не читается, не показывается и не ищется.
  contacts: ["контакты", "контакт", "контакти", "contacts", "contact", "контактнаособа", "контактноелицо"],
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

module.exports = { FIELDS, key, fieldFor, isSecret };
