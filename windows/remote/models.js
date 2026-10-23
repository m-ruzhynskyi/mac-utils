// Программа удалённого доступа, запись, диагностика. 1:1 с Mac (`RemoteModels.swift`), пароля в записях нет.
"use strict";

const { key } = require("./headers");
const { tagKey, isBadgeTag, VPN, RDP } = require("./tags");

const PROGRAMS = ["anyDesk", "teamViewer"];
const TITLES = { anyDesk: "AnyDesk", teamViewer: "TeamViewer" };
const NAMES = new Map(Object.entries({
  anydesk: "anyDesk", ad: "anyDesk", энидеск: "anyDesk", анидеск: "anyDesk", енідеск: "anyDesk",
  teamviewer: "teamViewer", tv: "teamViewer", тимвьюер: "teamViewer", тимвьювер: "teamViewer",
  тімвюер: "teamViewer", тімвювер: "teamViewer",
}));

// Значение ячейки «Программа» → программа. Регистр, пробелы и знаки не важны; null — не распознано.
function parseProgram(raw) {
  return NAMES.get(key(raw)) || null;
}

// Записи не через AnyDesk/TeamViewer: удалённый рабочий стол, только VPN, другое (телефон и т. п.). Это не программа, а способ
// (record.method): ID может быть пустым, для RDP в ID — адрес компьютера (IP или имя), он не нормализуется.
const METHODS = ["rdp", "vpn", "other"];
const METHOD_TITLES = { rdp: "RDP", vpn: "VPN", other: "Другое" };
const METHOD_NAMES = new Map(Object.entries({
  rdp: "rdp", рдп: "rdp", remotedesktop: "rdp", mstsc: "rdp", windowsapp: "rdp",
  vpn: "vpn", впн: "vpn",
  другое: "other", другие: "other", інше: "other", other: "other", прочее: "other", иное: "other", телефон: "other", phone: "other",
}));
function parseMethod(raw) {
  return METHOD_NAMES.get(key(raw)) || null;
}

// Нужен VPN: способ «VPN» или метка VPN. Через удалённый рабочий стол: способ «RDP» или метка RDP.
const needsVPN = (record) => record.method === "vpn" || (record.tags || []).some((t) => tagKey(t) === VPN);
const usesRDP = (record) => record.method === "rdp" || (record.tags || []).some((t) => tagKey(t) === RDP);
// Метки для показа: без VPN и RDP — они значками.
const labelsOf = (record) => (record.tags || []).filter((t) => !isBadgeTag(t));
// Ключ избранного и недавних — нормализованный ID (номер строки меняется при правке файла); без ID — название.
const favoriteKey = (record) => (record.id ? record.id : `name:${record.name}`);

const supportsAliases = (program) => program === "anyDesk";
const downloadURL = (program) => (program === "anyDesk" ? "https://anydesk.com/download" : "https://www.teamviewer.com/download/");

// Программа записи: из файла, иначе алиас — AnyDesk, иначе программа по умолчанию. У записей RDP/VPN/«Другое» не используется.
function programOf(record, fallback) {
  return record.program || (isAlias(record) ? "anyDesk" : fallback);
}
const isAlias = (record) => record.id.includes("@");
// Уникален в списке: один и тот же ID может встретиться дважды.
const identity = (record) => `${record.sourceRow}:${record.id}`;

// ID для показа: цифры группами по три с конца («123 456 789»); алиас и адрес RDP (IP, имя) — как есть.
function displayID(record) {
  if (isAlias(record) || !/^\d+$/.test(record.id)) return record.id;
  let out = "";
  for (let i = 0; i < record.id.length; i++) {
    if (i > 0 && (record.id.length - i) % 3 === 0) out += " ";
    out += record.id[i];
  }
  return out;
}

function columnLetter(index) {
  if (index == null) return null;
  let n = index + 1, s = "";
  while (n > 0) { const r = (n - 1) % 26; s = String.fromCharCode(65 + r) + s; n = Math.floor((n - 1) / 26); }
  return s;
}

function emptyDiagnostics() {
  return { loaded: 0, withPassword: 0, columns: [], skipped: [], duplicates: [], unrecognizedColumns: [], lossyIDRows: [], ambiguousProgramRows: [] };
}
const duplicateCount = (d) => d.duplicates.reduce((sum, g) => sum + g.rows.length - 1, 0);
// Чисто: показывается только «Загружено N».
const isClean = (d) => !d.skipped.length && !d.duplicates.length && !d.unrecognizedColumns.length && !d.lossyIDRows.length && !d.ambiguousProgramRows.length;

// Ошибки чтения: code — для журнала (без имён листов, заголовков и причин из файла).
class ConnectionsError extends Error {
  constructor(code, detail = "", extra = {}) {
    super(code + (detail ? `: ${detail}` : ""));
    this.code = code;
    this.detail = detail;
    Object.assign(this, extra);
  }
}
const CODES = ["noFile", "unavailable", "locked", "type", "tooLarge", "noSheet", "missingColumns", "corrupt"];

module.exports = { METHODS, METHOD_TITLES, parseMethod, needsVPN, usesRDP, labelsOf, favoriteKey, PROGRAMS, TITLES, parseProgram, supportsAliases, downloadURL, programOf, isAlias, identity, displayID, columnLetter,
  emptyDiagnostics, duplicateCount, isClean, ConnectionsError, CODES };
