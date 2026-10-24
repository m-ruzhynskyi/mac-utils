import Foundation

/// Разметка XML-файла подключений по байтам: где начинается и кончается каждая `<connection>`, её поля и атрибуты.
/// Нужна для правки без потерь — `XMLParser` позиций в байтах не даёт.
struct XMLScan {
    struct Child {
        let name: String
        let field: ConnectionField?
        let range: Range<Int>
        /// Между открывающим и закрывающим тегом; nil у `<note/>`.
        let content: Range<Int>?
    }

    struct Attribute {
        let field: ConnectionField?
        let value: Range<Int>
    }

    struct Element {
        var range: Range<Int>
        var startTagEnd: Int
        var closeTagStart: Int?
        /// Строки начала и конца открывающего тега: с одной из них совпадает номер строки записи.
        var lines: Set<Int>
        var attributes: [Attribute]
        var children: [Child] = []
    }

    let bytes: [UInt8]
    private(set) var connections: [Element] = []
    private(set) var rootCloseStart: Int?
    private var newlines: [Int] = []

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        newlines = bytes.indices.filter { bytes[$0] == 0x0A }
        try checkEncoding()
        try scan()
    }

    // MARK: Поиск записи

    func find(_ record: ConnectionRecord) throws -> Element {
        // Как в списке: ID AnyDesk/TeamViewer нормализован, адрес RDP — как есть, без ID — пустая строка.
        func id(_ e: Element) -> String? {
            if let c = e.children.first(where: { $0.field == .id }) { return c.content.map { ConnectionsBuilder.idKey(text($0)) } ?? "" }
            if let a = e.attributes.first(where: { $0.field == .id }) { return ConnectionsBuilder.idKey(text(a.value)) }
            return ""
        }
        func name(_ e: Element) -> String? {
            if let c = e.children.first(where: { $0.field == .name }), let content = c.content {
                return text(content).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return e.attributes.first(where: { $0.field == .name }).map { text($0.value).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let sameID = connections.filter { id($0) == record.id }
        if let e = sameID.first(where: { $0.lines.contains(record.sourceRow) }) { return e }
        if let e = sameID.first(where: { name($0) == record.name }) { return e }
        if sameID.count == 1, !record.id.isEmpty { return sameID[0] }
        throw XMLEditError.entryNotFound
    }

    // MARK: Текст и строки

    /// Значение поля: сущности раскрыты, CDATA развёрнуты.
    func text(_ range: Range<Int>) -> String {
        var raw = String(decoding: bytes[range], as: UTF8.self)
        var out = ""
        while let open = raw.range(of: "<![CDATA[") {
            out += XMLScan.unescape(String(raw[..<open.lowerBound]))
            let rest = raw[open.upperBound...]
            guard let close = rest.range(of: "]]>") else { out += String(rest); raw = ""; break }
            out += String(rest[..<close.lowerBound])
            raw = String(rest[close.upperBound...])
        }
        return out + XMLScan.unescape(raw)
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semi = rest[amp...].firstIndex(of: ";"), rest.distance(from: amp, to: semi) <= 10 else {
                out.append("&"); rest = rest[rest.index(after: amp)...]; continue
            }
            let entity = rest[rest.index(after: amp)..<semi]
            let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
            if let v = named[String(entity)] {
                out += v
            } else if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let n = UInt32(entity.dropFirst(2), radix: 16), let u = Unicode.Scalar(n) {
                out.unicodeScalars.append(u)
            } else if entity.hasPrefix("#"), let n = UInt32(entity.dropFirst()), let u = Unicode.Scalar(n) {
                out.unicodeScalars.append(u)
            } else {
                out += rest[amp...semi]
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }

    /// Номер строки (с 1), как у `XMLParser`.
    func line(at index: Int) -> Int {
        var lo = 0, hi = newlines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if newlines[mid] < index { lo = mid + 1 } else { hi = mid }
        }
        return lo + 1
    }

    func lineStart(of index: Int) -> Int {
        var i = index
        while i > 0, bytes[i - 1] != 0x0A { i -= 1 }
        return i
    }

    /// Индекс перевода строки после `index` (или конец файла).
    func lineEnd(after index: Int) -> Int {
        var i = index
        while i < bytes.count, bytes[i] != 0x0A { i += 1 }
        return i
    }

    func isBlank(_ range: Range<Int>) -> Bool {
        range.allSatisfy { [0x20, 0x09, 0x0D].contains(bytes[$0]) }
    }

    /// Отступ строки, на которой стоит `index`, если перед ним только пробелы.
    func lineIndent(before index: Int) -> String {
        let start = lineStart(of: index)
        return isBlank(start..<index) ? String(decoding: bytes[start..<index], as: UTF8.self) : "  "
    }

    // MARK: Разбор

    private func checkEncoding() throws {
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { throw XMLEditError.unsupported }
        let head = String(decoding: bytes.prefix(200), as: UTF8.self).lowercased()
        if head.hasPrefix("<?xml") || head.hasPrefix("\u{FEFF}<?xml"),
           let end = head.range(of: "?>"), let enc = head[..<end.lowerBound].range(of: "encoding=") {
            let value = head[enc.upperBound...].dropFirst().prefix { $0 != "\"" && $0 != "'" }
            guard ["utf-8", "utf8", "us-ascii", "ascii"].contains(String(value)) else { throw XMLEditError.unsupported }
        }
    }

    private func find(_ needle: String, from: Int) -> Int? {
        let n = Array(needle.utf8)
        guard n.count <= bytes.count else { return nil }
        var i = from
        while i + n.count <= bytes.count {
            if bytes[i] == n[0], Array(bytes[i..<i + n.count]) == n { return i }
            i += 1
        }
        return nil
    }

    private func starts(_ prefix: String, at i: Int) -> Bool {
        let p = Array(prefix.utf8)
        return i + p.count <= bytes.count && Array(bytes[i..<i + p.count]) == p
    }

    private func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    private mutating func scan() throws {
        var i = 0
        var depth = 0
        var current: Element?
        var openChild: (name: String, start: Int, contentStart: Int)?
        let n = bytes.count
        while i < n {
            guard let lt = bytes[i...].firstIndex(of: 0x3C) else { break }
            if starts("<!--", at: lt) {
                guard let e = find("-->", from: lt + 4) else { throw XMLEditError.corrupt }
                i = e + 3
            } else if starts("<![CDATA[", at: lt) {
                guard let e = find("]]>", from: lt + 9) else { throw XMLEditError.corrupt }
                i = e + 3
            } else if starts("<?", at: lt) {
                guard let e = find("?>", from: lt + 2) else { throw XMLEditError.corrupt }
                i = e + 2
            } else if starts("<!", at: lt) {
                // DOCTYPE со своими сущностями правкой не трогаем.
                guard let gt = bytes[lt...].firstIndex(of: 0x3E) else { throw XMLEditError.corrupt }
                if bytes[lt..<gt].contains(0x5B) { throw XMLEditError.unsupported }
                i = gt + 1
            } else if starts("</", at: lt) {
                guard let gt = bytes[lt...].firstIndex(of: 0x3E) else { throw XMLEditError.corrupt }
                let name = String(decoding: bytes[(lt + 2)..<gt], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if depth == 3, let open = openChild, current != nil {
                    current?.children.append(Child(name: open.name, field: ConnectionHeaders.field(for: open.name),
                                                   range: open.start..<(gt + 1), content: open.contentStart..<lt))
                    openChild = nil
                } else if depth == 2, var element = current {
                    element.closeTagStart = lt
                    element.range = element.range.lowerBound..<(gt + 1)
                    connections.append(element)
                    current = nil
                } else if depth == 1 {
                    rootCloseStart = lt
                }
                depth -= 1
                i = gt + 1
            } else {
                var j = lt + 1
                var quote: UInt8?
                while j < n {
                    let b = bytes[j]
                    if let q = quote { if b == q { quote = nil } } else if b == 0x22 || b == 0x27 { quote = b } else if b == 0x3E { break }
                    j += 1
                }
                guard j < n else { throw XMLEditError.corrupt }
                let selfClosing = bytes[j - 1] == 0x2F
                var k = lt + 1
                while k < j, !isSpace(bytes[k]), bytes[k] != 0x2F, bytes[k] != 0x3E { k += 1 }
                let name = String(decoding: bytes[(lt + 1)..<k], as: UTF8.self)
                depth += 1
                if depth == 1, name.lowercased() != "connections" { throw XMLEditError.unsupported }
                if depth == 2, name.lowercased() == "connection" {
                    let element = Element(range: lt..<(j + 1), startTagEnd: j + 1, closeTagStart: nil,
                                          lines: [line(at: lt), line(at: j)],
                                          attributes: try attributes(k..<(selfClosing ? j - 1 : j)))
                    if selfClosing { connections.append(element) } else { current = element }
                } else if depth == 3, current != nil {
                    if selfClosing {
                        current?.children.append(Child(name: name, field: ConnectionHeaders.field(for: name),
                                                       range: lt..<(j + 1), content: nil))
                    } else if openChild == nil {
                        openChild = (name, lt, j + 1)
                    }
                }
                if selfClosing { depth -= 1 }
                i = j + 1
            }
        }
        guard depth == 0, rootCloseStart != nil else { throw XMLEditError.corrupt }
    }

    private func attributes(_ range: Range<Int>) throws -> [Attribute] {
        var out: [Attribute] = []
        var i = range.lowerBound
        while i < range.upperBound {
            while i < range.upperBound, isSpace(bytes[i]) { i += 1 }
            guard i < range.upperBound else { break }
            let nameStart = i
            while i < range.upperBound, bytes[i] != 0x3D, !isSpace(bytes[i]) { i += 1 }
            let name = String(decoding: bytes[nameStart..<i], as: UTF8.self)
            while i < range.upperBound, isSpace(bytes[i]) { i += 1 }
            guard i < range.upperBound, bytes[i] == 0x3D else { throw XMLEditError.corrupt }
            i += 1
            while i < range.upperBound, isSpace(bytes[i]) { i += 1 }
            guard i < range.upperBound, bytes[i] == 0x22 || bytes[i] == 0x27 else { throw XMLEditError.corrupt }
            let q = bytes[i]
            let valueStart = i + 1
            guard let end = bytes[valueStart..<range.upperBound].firstIndex(of: q) else { throw XMLEditError.corrupt }
            out.append(Attribute(field: ConnectionHeaders.field(for: name), value: valueStart..<end))
            i = end + 1
        }
        return out
    }
}
