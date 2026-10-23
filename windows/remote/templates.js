// «Создать шаблон»: пустой файл подключений с нужными колонками и двумя примерами (.xlsx или .xml). Существующий файл не
// перезаписывается без подтверждения системного диалога сохранения.
"use strict";

const fs = require("node:fs");
const { writeXlsx } = require("./xlsxwriter");

// Программа: AnyDesk | TeamViewer | RDP | VPN | Другое. Учётка Windows, «Доступ» (многострочный) и «Контакты» — необязательны.
const HEADER = ["Название", "ID", "Пароль", "Группа", "Теги", "Заметка", "Программа", "Учётная запись", "Пароль учётной записи", "Доступ", "Контакты"];
const EXAMPLES = [
  ["Пример: касса 1", "123456789", "", "Магазин", "касса", "Замените примеры своими данными", "AnyDesk", "", "", "", ""],
  ["Пример: сервер", "987654321", "", "Офис", "сервер", "", "TeamViewer", "", "", "", ""],
];
const TAGS = ["name", "id", "password", "group", "tags", "note", "app", "account", "accountPassword", "access", "contacts"];
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function templateBuffer(kind) {
  if (kind === "xlsx") return writeXlsx([HEADER, ...EXAMPLES]);
  const items = EXAMPLES.map((row) => `  <connection>\n${row.map((v, i) => (v === "" ? "" : `    <${TAGS[i]}>${esc(v)}</${TAGS[i]}>\n`)).join("")}  </connection>\n`).join("");
  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>\n<!-- name, id, password, group, tags (a, b), note, app (AnyDesk | TeamViewer | RDP | VPN | Другое),\n     account, accountPassword (учётка Windows), access (VPN/RDP и прочее, многострочный), contacts -->\n<connections>\n${items}</connections>\n`, "utf8");
}

// Спрашивает, куда сохранить; возвращает путь или "" (отмена). setSettings — подключает новый файл.
async function create({ kind, dialog, parent, setSettings }) {
  kind = kind === "xml" ? "xml" : "xlsx";
  const picked = await dialog.showSaveDialog(parent && !parent.isDestroyed?.() ? parent : undefined, {
    title: "Шаблон списка подключений", defaultPath: `Подключения.${kind}`, filters: [{ name: kind === "xlsx" ? "Excel" : "XML", extensions: [kind] }] });
  if (picked.canceled || !picked.filePath) return "";
  fs.writeFileSync(picked.filePath, templateBuffer(kind), { mode: 0o600 });
  setSettings({ file: picked.filePath, sheet: "" });
  return picked.filePath;
}

module.exports = { create, templateBuffer, HEADER, EXAMPLES };
