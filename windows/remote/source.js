// Источник списка: .xlsx или .xml, по расширению. Файл только читается.
"use strict";

const path = require("node:path");
const xlsx = require("./xlsx");
const xmlSource = require("./xmlsource");
const { build, idKey } = require("./builder");
const { secretOf } = require("./rawentry");
const { isSecret } = require("./headers");
const { SecretBuffer } = require("./secret");
const { ConnectionsError } = require("./models");

const MAX_FILE_SIZE = 64 << 20;

function kindOf(file) {
  const ext = path.extname(file).toLowerCase();
  if (ext === ".xlsx" || ext === ".xlsm") return "xlsx";
  if (ext === ".xml") return "xml";
  throw new ConnectionsError("type");
}

function parseData(data, kind, mode, sheet = null) {
  return kind === "xlsx" ? xlsx.parse(data, mode, sheet) : xmlSource.parse(data, mode);
}

// Содержимое файла → {records, diagnostics}. Бросает ConnectionsError.
function load(data, kind, sheet = null) {
  return build(parseData(data, kind, "records", sheet));
}

// Пароль записи — прямо из файла, в момент подключения. Сначала строка с тем же номером и ID; если файл успели поправить —
// строка с тем же ID и именем, затем единственная строка с этим ID. null — записи или пароля нет. Угадывать среди нескольких
// строк с одним ID не будем. Строки разбора (string) затереть нельзя — они живут только до конца вызова.
function passwordFor(record, data, kind, sheet = null) {
  return secretFor("password", record, data, kind, sheet);
}

// Секретное поле записи (пароль, пароль учётки, «Доступ») — так же, как пароль. Записи без ID (RDP/VPN/«Другое») ищутся по номеру
// строки и названию. SecretBuffer или null.
function secretFor(field, record, data, kind, sheet = null) {
  if (!isSecret(field)) throw new Error("not a secret field");
  const sameID = parseData(data, kind, "passwords", sheet).entries.filter((e) => idKey(e.id) === record.id);
  const named = (e) => e.name.trim() === record.name;
  let match = sameID.find((e) => e.row === record.sourceRow && (record.id !== "" || named(e)));
  if (!match) match = sameID.find(named);
  if (!match && sameID.length === 1 && record.id !== "") match = sameID[0];
  const value = match ? secretOf(match, field) : "";
  if (!value) return null;
  return new SecretBuffer(value);
}

module.exports = { MAX_FILE_SIZE, kindOf, load, passwordFor, secretFor };
