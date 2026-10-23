// Фикстуры с выдуманными данными (те же, что в тестах Mac-модуля). Бинарников в репозитории нет: .xlsx собирается из XML-строк.
"use strict";

const { ZipWriter } = require("../../remote/zip");
const { fieldFor } = require("../../remote/headers");

const escape = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// Ячейки: {t:"text"|"inline"|"number"|"formula", v} или null (пусто).
const text = (v) => ({ t: "text", v }), inline = (v) => ({ t: "inline", v }), number = (v) => ({ t: "number", v }), formula = (v) => ({ t: "formula", v });

function column(index) {
  let n = index + 1, s = "";
  while (n > 0) { const r = (n - 1) % 26; s = String.fromCharCode(65 + r) + s; n = Math.floor((n - 1) / 26); }
  return s;
}

function cellOf(s) {
  if (s === "") return null;
  if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s) && !s.includes(" ")) return number(s);
  return text(s);
}

// sheets: [{name, rows: [[cell|null]], firstRow=1}]
function xlsx(sheets, { absoluteTargets = false, compress = true } = {}) {
  const shared = [], sharedIndex = new Map();
  const ref = (s) => { if (!sharedIndex.has(s)) { sharedIndex.set(s, shared.length); shared.push(s); } return sharedIndex.get(s); };
  const zip = new ZipWriter();
  zip.add("[Content_Types].xml", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>`, { compress });
  let sheetsXML = "", rels = "";
  sheets.forEach((sheet, i) => {
    const n = i + 1;
    sheetsXML += `<sheet name="${escape(sheet.name)}" sheetId="${n}" r:id="rId${n}"/>`;
    rels += `<Relationship Id="rId${n}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="${absoluteTargets ? `/xl/worksheets/sheet${n}.xml` : `worksheets/sheet${n}.xml`}"/>`;
    let body = "";
    sheet.rows.forEach((row, r) => {
      const rowNumber = (sheet.firstRow ?? 1) + r;
      body += `<row r="${rowNumber}" spans="1:${Math.max(row.length, 1)}">`;
      row.forEach((cell, c) => {
        if (!cell) return;
        const at = `${column(c)}${rowNumber}`;
        if (cell.t === "text") body += `<c r="${at}" s="1" t="s"><v>${ref(cell.v)}</v></c>`;
        else if (cell.t === "inline") body += `<c r="${at}" t="inlineStr"><is><t xml:space="preserve">${escape(cell.v)}</t></is></c>`;
        else if (cell.t === "number") body += `<c r="${at}"><v>${cell.v}</v></c>`;
        else body += `<c r="${at}" t="str"><f>CONCAT("x")</f><v>${escape(cell.v)}</v></c>`;
      });
      body += "</row>";
    });
    zip.add(`xl/worksheets/sheet${n}.xml`, `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><dimension ref="A1"/><sheetData>${body}</sheetData></worksheet>`, { compress });
  });
  zip.add("xl/workbook.xml", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${sheetsXML}</sheets></workbook>`, { compress });
  zip.add("xl/_rels/workbook.xml.rels", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${rels}</Relationships>`, { compress });
  zip.add("xl/sharedStrings.xml", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="${shared.length}" uniqueCount="${shared.length}">${shared.map((s) => `<si><t xml:space="preserve">${escape(s)}</t></si>`).join("")}</sst>`, { compress });
  return zip.finish();
}

// Простой лист: все ячейки — общие строки, кроме похожих на числа.
function xlsxRows(rows, sheet = "Подключения") {
  return xlsx([{ name: sheet, rows: rows.map((r) => r.map(cellOf)) }]);
}

const XML_TAGS = { name: "name", id: "id", password: "password", group: "group", tags: "tags", note: "note", program: "app" };
function xmlRows(rows) {
  const tags = rows[0].map((h) => XML_TAGS[fieldFor(h)] || "extra");
  let out = '<?xml version="1.0" encoding="UTF-8"?>\n<connections>\n';
  for (const row of rows.slice(1)) {
    out += "  <connection>";
    row.forEach((v, i) => { if (v !== "" && i < tags.length) out += `<${tags[i]}>${escape(v)}</${tags[i]}>`; });
    out += "</connection>\n";
  }
  return Buffer.from(out + "</connections>\n", "utf8");
}

const places = ["Лаборатория Север", "Склад Південь", "Офис Восток", "Аптека Захід", "Школа №7", "Kyiv Front Desk", "Бухгалтерия", "Касса 2", "Сервер печати", "Приёмная"];
const groups = ["Клиенты", "Філії", "Office", ""];
// Пароль строки — выдуманный и узнаваемый, чтобы тесты могли искать его следы.
const password = (i) => `Pw-${i}-секрет`;
const id = (i) => String(100_000_000 + i * 7_919);
const CLEAN_HEADER = ["Название", "ID", "Пароль", "Группа", "Теги", "Заметка", "Программа"];

function cleanRows(count, header = CLEAN_HEADER) {
  const rows = [header];
  for (let i = 0; i < count; i++) {
    rows.push([`${places[i % places.length]} ${i}`, id(i), i % 5 === 4 ? "" : password(i), groups[i % groups.length], i % 3 === 0 ? "касса, ночь" : "",
      i % 4 === 0 ? "звонить заранее" : "", i % 6 === 5 ? "TeamViewer" : (i % 2 === 0 ? "AnyDesk" : "")]);
  }
  return rows;
}

const MESSY_HEADER = ["  Назва ", "ID AnyDesk", "ПАРОЛЬ", "Група", "Теги", "Примітка", "Програма", "Ответственный"];
// 200+ строк с кривыми заголовками и всеми видами ошибок. Номер строки листа = индекс + 1.
function messyRows() {
  const rows = [MESSY_HEADER];
  for (let i = 0; i < 210; i++) rows.push([`Комп’ютер ${i}`, id(i), password(i), groups[i % groups.length], "", "", "AnyDesk", "Иванов"]);
  rows[3][0] = "";
  rows[5][1] = "";
  rows[7][1] = "12345";
  rows[9][1] = "1.23E+08";
  rows[11][1] = "123 456 780";
  rows[13][1] = rows[2][1];
  rows[15][6] = "RustDesk";
  rows[17][1] = "office@ad";
  rows[19][1] = "front@ad"; rows[19][6] = "TeamViewer";
  rows[21] = MESSY_HEADER.map(() => "");
  rows[23][1] = "1,23456789E+08";
  return rows;
}

module.exports = { xlsx, xlsxRows, xmlRows, escape, text, inline, number, formula, cellOf, column, cleanRows, messyRows, id, password, places, groups, CLEAN_HEADER };
