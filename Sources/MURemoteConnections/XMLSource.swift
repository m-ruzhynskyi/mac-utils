import Foundation

/// Чтение .xml: `<connections><connection><name/><id/><password/><group/><tags/><note/><app/></connection></connections>`.
/// Поля можно задать и атрибутами `<connection name="…" id="…"/>`; имена тегов — те же, что у колонок XLSX.
/// Номер «строки» записи — строка файла, на которой открывается `<connection>`.
struct XMLSource: ConnectionsSource {
    func parse(_ data: Data, mode: ParseMode) throws -> ParsedFile {
        let d = Delegate(mode: mode)
        let p = XMLParser(data: data)
        p.shouldResolveExternalEntities = false
        p.delegate = d
        d.parser = p
        guard p.parse() else {
            if let e = d.failure { throw e }
            throw ConnectionsError.corrupt("Некорректный XML (строка \(p.lineNumber))")
        }
        guard d.sawRoot else { throw ConnectionsError.corrupt("Ожидался корневой элемент connections") }
        return ParsedFile(entries: d.entries, columns: d.columns, unrecognizedColumns: d.unrecognized)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let mode: ParseMode
        weak var parser: XMLParser?
        var entries: [RawEntry] = []
        var columns: [MatchedColumn] = []
        var unrecognized: [String] = []
        var sawRoot = false
        var failure: ConnectionsError?
        private var depth = 0
        private var current: RawEntry?
        private var field: ConnectionField?
        private var text = ""

        init(mode: ParseMode) { self.mode = mode }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth == 1 {
                guard element.lowercased() == "connections" else { return fail("Ожидался корневой элемент connections") }
                sawRoot = true
            } else if depth == 2 {
                guard element.lowercased() == "connection" else { return }
                var entry = RawEntry(row: parser.lineNumber)
                for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
                    if let f = recognize(key) { entry.set(f, value.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode) }
                }
                current = entry
            } else if depth == 3, current != nil {
                text = ""
                field = recognize(element)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) { if field != nil { text += s } }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { if field != nil { text += String(decoding: data, as: UTF8.self) } }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if depth == 3, let f = field {
                current?.set(f, text.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode)
                field = nil
                text = ""
            }
            if depth == 2, let e = current { entries.append(e); current = nil }
            depth -= 1
        }

        /// Тег или атрибут → поле; заодно собирает соответствие и нераспознанные имена для диагностики.
        private func recognize(_ name: String) -> ConnectionField? {
            guard let f = ConnectionHeaders.field(for: name) else {
                if !unrecognized.contains(name) { unrecognized.append(name) }
                return nil
            }
            if !columns.contains(where: { $0.field == f }) { columns.append(MatchedColumn(title: name, field: f)) }
            return f
        }

        private func fail(_ reason: String) {
            failure = .corrupt(reason)
            parser?.abortParsing()
        }
    }
}
