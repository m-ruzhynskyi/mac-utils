// Удалённый рабочий стол Windows: `mstsc.exe /v:<адрес>`. Адрес — из ID записи RDP (IP, имя, [IPv6], порт); всё, что могло бы
// стать другим параметром или командой, не пропускается. Логин и пароль в командную строку не идут никогда.
"use strict";

const path = require("node:path");

const HOST = /^[A-Za-z0-9.\-_:[\]]+$/;

// Адрес годится: имя, IPv4, [IPv6], порт — только [A-Za-z0-9.-_:[]], не длиннее 255.
function isValidHost(host) {
  const h = String(host ?? "").trim();
  return h.length > 0 && h.length <= 255 && HOST.test(h);
}

// Адрес для открытия: у записи RDP с годным адресом — адрес, иначе "" (тогда — подробности).
const rdpHost = (record) => (record.method === "rdp" && isValidHost(record.id) ? record.id.trim() : "");

// Полный путь к mstsc.exe (не поиск по PATH: рядом могла лежать чужая программа с тем же именем).
function mstscPath(env = process.env) {
  return path.win32.join(env.SystemRoot || env.windir || "C:\\Windows", "System32", "mstsc.exe");
}

// Аргументы mstsc; null — адрес не годится.
function mstscArgs(host) {
  return isValidHost(host) ? [`/v:${String(host).trim()}`] : null;
}

module.exports = { isValidHost, rdpHost, mstscPath, mstscArgs };
