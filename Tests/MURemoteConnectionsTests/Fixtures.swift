import Foundation
@testable import MURemoteConnections

/// Фикстуры с выдуманными данными. Бинарников в репозитории нет: .xlsx собирается здесь из XML-строк.
enum Fixtures {
    /// Ячейка листа так, как её пишет Excel.
    enum Cell {
        /// Общая строка (`t="s"`), как Excel пишет текст.
        case text(String)
        /// Строка прямо в ячейке (`t="inlineStr"`), как пишут сторонние программы.
        case inline(String)
        /// Число (`<v>` без типа).
        case number(String)
        /// Результат формулы-строки (`t="str"`).
        case formula(String)
        case empty
    }

    struct Sheet {
        var name: String
        var rows: [[Cell]]
        /// Номер первой строки листа (над таблицей бывают пустые строки).
        var firstRow = 1
    }

    // MARK: XLSX

    static func xlsx(_ sheets: [Sheet], absoluteTargets: Bool = false, compress: Bool = true) -> Data {
        var shared: [String] = []
        var sharedIndex: [String: Int] = [:]
        func sharedRef(_ s: String) -> Int {
            if let i = sharedIndex[s] { return i }
            shared.append(s)
            sharedIndex[s] = shared.count - 1
            return shared.count - 1
        }

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>
            """.utf8), compress: compress)

        var sheetsXML = ""
        var rels = ""
        for (i, sheet) in sheets.enumerated() {
            let n = i + 1
            sheetsXML += #"<sheet name="\#(escape(sheet.name))" sheetId="\#(n)" r:id="rId\#(n)"/>"#
            let target = absoluteTargets ? "/xl/worksheets/sheet\(n).xml" : "worksheets/sheet\(n).xml"
            rels += #"<Relationship Id="rId\#(n)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="\#(target)"/>"#

            var body = ""
            for (r, row) in sheet.rows.enumerated() {
                let rowNumber = sheet.firstRow + r
                body += #"<row r="\#(rowNumber)" spans="1:\#(max(row.count, 1))">"#
                for (c, cell) in row.enumerated() {
                    let ref = "\(column(c))\(rowNumber)"
                    switch cell {
                    case .text(let s): body += #"<c r="\#(ref)" s="1" t="s"><v>\#(sharedRef(s))</v></c>"#
                    case .inline(let s): body += #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(escape(s))</t></is></c>"#
                    case .number(let s): body += #"<c r="\#(ref)"><v>\#(s)</v></c>"#
                    case .formula(let s): body += #"<c r="\#(ref)" t="str"><f>CONCAT("x")</f><v>\#(escape(s))</v></c>"#
                    case .empty: break
                    }
                }
                body += "</row>"
            }
            zip.add("xl/worksheets/sheet\(n).xml", Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><dimension ref="A1"/><sheetData>\(body)</sheetData></worksheet>
                """.utf8), compress: compress)
        }

        zip.add("xl/workbook.xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetsXML)</sheets></workbook>
            """.utf8), compress: compress)
        zip.add("xl/_rels/workbook.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
            """.utf8), compress: compress)
        let items = shared.map { #"<si><t xml:space="preserve">\#(escape($0))</t></si>"# }.joined()
        zip.add("xl/sharedStrings.xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(shared.count)" uniqueCount="\(shared.count)">\(items)</sst>
            """.utf8), compress: compress)
        return zip.finish()
    }

    /// Простой лист: все ячейки — общие строки, кроме тех, что похожи на числа.
    static func xlsx(rows: [[String]], sheet: String = "Подключения") -> Data {
        xlsx([Sheet(name: sheet, rows: rows.map { $0.map(cell) })])
    }

    static func cell(_ s: String) -> Cell {
        if s.isEmpty { return .empty }
        if Double(s) != nil, !s.contains(" ") { return .number(s) }
        return .text(s)
    }

    static func column(_ index: Int) -> String {
        var n = index + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(65 + r)!) + s
            n = (n - 1) / 26
        }
        return s
    }

    // MARK: XML

    static func xml(rows: [[String]]) -> Data {
        let header = rows[0]
        let tags = header.map { h -> String in
            ConnectionHeaders.field(for: h).map(XMLConnectionsEditor.tag) ?? "extra"
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<connections>\n"
        for row in rows.dropFirst() {
            out += "  <connection>"
            for (tag, value) in zip(tags, row) where !value.isEmpty { out += "<\(tag)>\(escape(value))</\(tag)>" }
            out += "</connection>\n"
        }
        out += "</connections>\n"
        return Data(out.utf8)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Выдуманные данные

    static let places = ["Лаборатория Север", "Склад Південь", "Офис Восток", "Аптека Захід", "Школа №7",
                         "Kyiv Front Desk", "Бухгалтерия", "Касса 2", "Сервер печати", "Приёмная"]
    static let groups = ["Клиенты", "Філії", "Office", ""]

    /// Пароль строки — выдуманный и узнаваемый, чтобы тесты могли искать его следы.
    static func password(_ i: Int) -> String { "Pw-\(i)-секрет" }

    /// Строка с ID: 9 цифр, детерминированно по номеру.
    static func id(_ i: Int) -> String { String(100_000_000 + i * 7_919) }

    /// Чистые данные: заголовки + `count` корректных строк.
    static func cleanRows(_ count: Int, header: [String] = ["Название", "ID", "Пароль", "Группа", "Теги", "Заметка", "Программа"]) -> [[String]] {
        var rows = [header]
        for i in 0..<count {
            rows.append(["\(places[i % places.count]) \(i)", id(i), i % 5 == 4 ? "" : password(i),
                         groups[i % groups.count], i % 3 == 0 ? "касса, ночь" : "", i % 4 == 0 ? "звонить заранее" : "",
                         i % 6 == 5 ? "TeamViewer" : (i % 2 == 0 ? "AnyDesk" : "")])
        }
        return rows
    }

    /// 200+ строк с кривыми заголовками и всеми видами ошибок. Номера строк листа = индекс + 1.
    static let messyHeader = ["  Назва ", "ID AnyDesk", "ПАРОЛЬ", "Група", "Теги", "Примітка", "Програма", "Ответственный"]

    static func messyRows() -> [[String]] {
        var rows = [messyHeader]
        for i in 0..<210 {
            rows.append(["Комп’ютер \(i)", id(i), password(i), groups[i % groups.count], "", "", "AnyDesk", "Иванов"])
        }
        // Строки листа: заголовок — 1, данные со 2-й. Портим выборочно (индекс в rows = номер строки - 1).
        rows[3][0] = ""                         // строка 4: нет имени
        rows[5][1] = ""                         // строка 6: нет ID
        rows[7][1] = "12345"                    // строка 8: короткий ID
        rows[9][1] = "1.23E+08"                 // строка 10: экспонента, цифры потеряны
        rows[11][1] = "123 456 780"             // строка 12: пробелы
        rows[13][1] = rows[2][1]                // строка 14: дубликат строки 3
        rows[15][6] = "RustDesk"                // строка 16: неизвестная программа
        rows[17][1] = "office@ad"               // строка 18: алиас
        rows[19][1] = "front@ad"; rows[19][6] = "TeamViewer" // строка 20: алиас у TeamViewer
        rows[21] = Array(repeating: "", count: messyHeader.count) // строка 22: пустая — не диагностика
        rows[23][1] = "1,23456789E+08"          // строка 24: экспонента с запятой, без потерь
        return rows
    }
}
