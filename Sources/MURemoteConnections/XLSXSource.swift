import Foundation

/// Чтение .xlsx: ZIP + XML, без внешних библиотек. Первая непустая строка листа — заголовки.
struct XLSXSource: ConnectionsSource {
    /// Имя листа; nil — первый.
    var sheet: String?

    init(sheet: String? = nil) { self.sheet = sheet }

    static let maxRows = 100_000
    static let maxColumns = 200

    /// Имена листов (для выбора в настройках).
    static func sheetNames(in data: Data) throws -> [String] {
        try workbook(ZipArchive(data: data)).sheets.map(\.name)
    }

    func parse(_ data: Data, mode: ParseMode) throws -> ParsedFile {
        let zip = try ZipArchive(data: data)
        let wb = try Self.workbook(zip)
        let target: Sheet
        if let sheet {
            guard let named = wb.sheets.first(where: { $0.name == sheet }) else { throw ConnectionsError.noSheet(sheet) }
            target = named
        } else {
            target = wb.sheets[0]
        }
        guard let sheetXML = try zip.contents(of: target.path) else { throw ConnectionsError.corrupt("Нет данных листа") }
        let shared = try zip.contents(of: "xl/sharedStrings.xml").map { try SharedStringsParser.parse($0) } ?? []
        let rows = try SheetParser.parse(sheetXML, shared: shared)
        return try Self.entries(from: rows, mode: mode)
    }

    // MARK: Книга

    private struct Sheet { let name: String; let path: String }
    private struct Workbook { let sheets: [Sheet] }

    private static func workbook(_ zip: ZipArchive) throws -> Workbook {
        guard let wbData = try zip.contents(of: "xl/workbook.xml") else { throw ConnectionsError.corrupt("Это не книга Excel") }
        let refs = try WorkbookParser.parse(wbData)
        var targets: [String: String] = [:]
        if let rels = try zip.contents(of: "xl/_rels/workbook.xml.rels") {
            targets = try RelsParser.parse(rels)
        }
        let sheets = refs.compactMap { ref -> Sheet? in
            guard let t = targets[ref.rid] else { return nil }
            let path = t.hasPrefix("/") ? String(t.dropFirst()) : "xl/" + t
            return Sheet(name: ref.name, path: path)
        }
        guard !sheets.isEmpty else { throw ConnectionsError.corrupt("В книге нет листов") }
        return Workbook(sheets: sheets)
    }

    // MARK: Заголовки → строки

    /// Сколько первых непустых строк смотреть в поисках заголовков (над ними бывает название таблицы).
    static let headerSearchRows = 10

    private static func entries(from rows: [(number: Int, cells: [String])], mode: ParseMode) throws -> ParsedFile {
        let candidates = rows.indices.prefix(headerSearchRows)
        guard let first = candidates.first else { throw ConnectionsError.missingColumns(found: []) }
        let headerIdx = candidates.first { i in
            let fields = Set(rows[i].cells.compactMap(ConnectionHeaders.field(for:)))
            return fields.contains(.name) && fields.contains(.id)
        } ?? first
        let header = rows[headerIdx].cells
        var columns: [ConnectionField: Int] = [:]
        var matched: [MatchedColumn] = []
        var unrecognized: [String] = []
        var found: [String] = []
        for (i, raw) in header.enumerated() {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            found.append(title)
            // Вторая колонка того же поля не читается — показываем её как нераспознанную.
            if let f = ConnectionHeaders.field(for: title), columns[f] == nil {
                columns[f] = i
                matched.append(MatchedColumn(title: title, field: f, column: i))
            } else {
                unrecognized.append(title)
            }
        }
        guard columns[.name] != nil, columns[.id] != nil else { throw ConnectionsError.missingColumns(found: found) }
        var out: [RawEntry] = []
        out.reserveCapacity(rows.count)
        for row in rows[(headerIdx + 1)...] {
            var e = RawEntry(row: row.number)
            for (field, col) in columns where col < row.cells.count { e.set(field, row.cells[col], mode: mode) }
            out.append(e)
        }
        return ParsedFile(entries: out, columns: matched, unrecognizedColumns: unrecognized)
    }
}

// MARK: - XML-разборщики

private func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}

private func makeParser(_ data: Data, _ delegate: XMLParserDelegate) -> XMLParser {
    let p = XMLParser(data: data)
    p.shouldResolveExternalEntities = false
    p.delegate = delegate
    return p
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    var refs: [(name: String, rid: String)] = []

    static func parse(_ data: Data) throws -> [(name: String, rid: String)] {
        let d = WorkbookParser()
        let p = makeParser(data, d)
        guard p.parse() else { throw ConnectionsError.corrupt("Повреждён workbook.xml") }
        return d.refs
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        guard localName(element) == "sheet", let name = a["name"] else { return }
        let rid = a.first { $0.key == "r:id" || $0.key.hasSuffix(":id") }?.value ?? ""
        refs.append((name, rid))
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    static func parse(_ data: Data) throws -> [String: String] {
        let d = RelsParser()
        guard makeParser(data, d).parse() else { throw ConnectionsError.corrupt("Повреждён workbook.xml.rels") }
        return d.targets
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        if localName(element) == "Relationship", let id = a["Id"], let t = a["Target"] { targets[id] = t }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inItem = false
    private var inText = false
    private var phonetic = 0

    static func parse(_ data: Data) throws -> [String] {
        let d = SharedStringsParser()
        guard makeParser(data, d).parse() else { throw ConnectionsError.corrupt("Повреждён sharedStrings.xml") }
        return d.strings
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch localName(element) {
        case "si": inItem = true; current = ""
        case "rPh": phonetic += 1
        case "t": inText = inItem && phonetic == 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { if inText { current += s } }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(element) {
        case "si": strings.append(current); inItem = false
        case "rPh": phonetic -= 1
        case "t": inText = false
        default: break
        }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    var rows: [(number: Int, cells: [String])] = []
    private var rowNumber = 0
    private var cells: [String] = []
    private var column = 0
    private var type = ""
    private var value = ""
    private var inValue = false
    private var inInline = false
    private var inInlineText = false
    private var phonetic = 0
    private var overflow = false

    init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, shared: [String]) throws -> [(number: Int, cells: [String])] {
        let d = SheetParser(shared: shared)
        let p = makeParser(data, d)
        guard p.parse() || d.overflow else { throw ConnectionsError.corrupt("Повреждены данные листа") }
        return d.rows
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch localName(element) {
        case "row":
            rowNumber = a["r"].flatMap(Int.init) ?? (rowNumber + 1)
            cells = []
            if rows.count >= XLSXSource.maxRows { overflow = true; parser.abortParsing() }
        case "c":
            column = a["r"].map(Self.columnIndex) ?? cells.count
            type = a["t"] ?? ""
            value = ""
        case "v": inValue = true
        case "is": inInline = true
        case "rPh": phonetic += 1
        case "t": inInlineText = inInline && phonetic == 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) {
        if inValue || inInlineText { value += s }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(element) {
        case "v": inValue = false
        case "is": inInline = false
        case "rPh": phonetic -= 1
        case "t": inInlineText = false
        case "c": store()
        case "row":
            if cells.contains(where: { !$0.isEmpty }) { rows.append((rowNumber, cells)) }
        default: break
        }
    }

    private func store() {
        guard column < XLSXSource.maxColumns else { return }
        let text: String
        switch type {
        case "s": text = Int(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 && $0 < shared.count ? shared[$0] : nil } ?? ""
        case "b": text = value == "1" ? "TRUE" : "FALSE"
        case "e": text = ""
        default: text = value
        }
        while cells.count <= column { cells.append("") }
        cells[column] = text
    }

    /// «AB12» → 27 (с нуля).
    static func columnIndex(_ ref: String) -> Int {
        var n = 0
        for ch in ref.unicodeScalars {
            guard ch.value >= 65 && ch.value <= 90 || ch.value >= 97 && ch.value <= 122 else { break }
            n = n * 26 + Int(ch.value & 0x1F)
        }
        return max(n - 1, 0)
    }
}
