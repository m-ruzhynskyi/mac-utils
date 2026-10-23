import Foundation

/// «Создать шаблон»: пустая таблица с нужными колонками и строкой-примером (выдуманной).
/// ID пишется текстом — Excel не превратит его в 1,23E+08.
public enum ConnectionsTemplate {
    /// Заголовки на языке модуля — все три варианта распознаются при чтении.
    public static var headers: [String] {
        [RL("Название"), "ID", RL("Пароль"), RL("Группа"), RL("Теги"), RL("Заметка"), RL("Программа")]
    }

    public static var example: [String] {
        [RL("Пример · Офис"), "123 456 789", "", RL("Офисы"), RL("пример"), RL("Удалите эту строку"), "AnyDesk"]
    }

    static var sheetName: String { RL("Подключения") }

    public static func xml() -> Data {
        let tags = ["name", "id", "password", "group", "tags", "note", "app"]
        var row = "  <connection>"
        // Пустые поля тоже пишем: видно, что их можно заполнить.
        for (tag, value) in zip(tags, example) {
            row += "<\(tag)>\(XMLConnectionsEditor.escape(value))</\(tag)>"
        }
        row += "</connection>"
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- Mac Utils: name, id, password, group, tags (a, b), note, app (AnyDesk | TeamViewer) -->
            <connections>
            \(row)
            </connections>

            """.utf8)
    }

    public static func xlsx() -> Data {
        func esc(_ s: String) -> String { XMLConnectionsEditor.escape(s, attribute: true) }
        func column(_ i: Int) -> String { String(UnicodeScalar(UInt8(65 + i))) }
        func row(_ r: Int, _ cells: [String], style: Int) -> String {
            var out = "<row r=\"\(r)\">"
            for (i, value) in cells.enumerated() where !value.isEmpty {
                out += "<c r=\"\(column(i))\(r)\" t=\"inlineStr\" s=\"\(style)\"><is><t xml:space=\"preserve\">\(esc(value))</t></is></c>"
            }
            return out + "</row>"
        }
        let widths = [28, 16, 18, 16, 18, 28, 14]
        let cols = widths.enumerated().map { "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\($0.element)\" customWidth=\"1\"/>" }.joined()
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data((header + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
            </Types>
            """).utf8))
        zip.add("_rels/.rels", Data((header + """
            <Relationships xmlns="\(pkg)"><Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """).utf8))
        zip.add("xl/workbook.xml", Data((header + """
            <workbook xmlns="\(main)" xmlns:r="\(rel)"><sheets><sheet name="\(esc(sheetName))" sheetId="1" r:id="rId1"/></sheets></workbook>
            """).utf8))
        zip.add("xl/_rels/workbook.xml.rels", Data((header + """
            <Relationships xmlns="\(pkg)">\
            <Relationship Id="rId1" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rId2" Type="\(rel)/styles" Target="styles.xml"/>\
            </Relationships>
            """).utf8))
        // Стиль 1 — жирный заголовок, 2 — текстовый формат (@), чтобы ID оставался текстом и при вводе.
        zip.add("xl/styles.xml", Data((header + """
            <styleSheet xmlns="\(main)">\
            <fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
            <xf numFmtId="49" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyNumberFormat="1"/>\
            <xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>\
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
            </styleSheet>
            """).utf8))
        zip.add("xl/worksheets/sheet1.xml", Data((header + """
            <worksheet xmlns="\(main)" xmlns:r="\(rel)">\
            <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>\
            <cols>\(cols)</cols>\
            <sheetData>\(row(1, headers, style: 1))\(row(2, example, style: 2))</sheetData>\
            </worksheet>
            """).utf8))
        return zip.finish()
    }
}

/// Права файла с паролями.
public enum ConnectionsFilePermissions {
    /// Файл могут читать другие пользователи (группа или все).
    public static func isShared(_ url: URL) -> Bool {
        guard let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber else {
            return false
        }
        return mode.intValue & 0o077 != 0
    }

    /// «Поставить 600» — только по нажатию пользователя.
    public static func restrict(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
