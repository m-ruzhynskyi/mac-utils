import Foundation

/// Кодировки текстового редактора (меню «Кодировка», как в Notepad++).
/// Главное правило: открыть и сохранить без правок — байты те же. Однобайтовые кодировки декодируются таблицей
/// на 256 значений, где у каждого байта свой символ (неопределённые байты — U+0080…U+009F и т. п.), поэтому
/// обратное преобразование однозначно.
package enum TextEncoding: String, CaseIterable, Codable, Sendable {
    case utf8, utf8BOM, utf16LE, utf16BE
    case windows1251, windows1252, windows1250
    case koi8R, koi8U
    case iso8859_1, iso8859_2, iso8859_5
    case macRoman, cp866

    package enum Group: CaseIterable {
        case unicode, cyrillic, western, central

        package var title: String {
            switch self {
            case .unicode: return "Юникод"
            case .cyrillic: return "Кириллица"
            case .western: return "Западная Европа"
            case .central: return "Центральная Европа"
            }
        }
    }

    package var title: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 с BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .windows1251: return "Windows-1251"
        case .windows1252: return "Windows-1252"
        case .windows1250: return "Windows-1250"
        case .koi8R: return "KOI8-R"
        case .koi8U: return "KOI8-U"
        case .iso8859_1: return "ISO-8859-1"
        case .iso8859_2: return "ISO-8859-2"
        case .iso8859_5: return "ISO-8859-5"
        case .macRoman: return "Mac Roman"
        case .cp866: return "CP866"
        }
    }

    package var group: Group {
        switch self {
        case .utf8, .utf8BOM, .utf16LE, .utf16BE: return .unicode
        case .windows1251, .koi8R, .koi8U, .iso8859_5, .cp866: return .cyrillic
        case .windows1252, .iso8859_1, .macRoman: return .western
        case .windows1250, .iso8859_2: return .central
        }
    }

    /// Кодовая страница Windows (`\ansicpgNNNN` в RTF).
    package var codePage: Int {
        switch self {
        case .utf8, .utf8BOM: return 65001
        case .utf16LE: return 1200
        case .utf16BE: return 1201
        case .windows1251: return 1251
        case .windows1252: return 1252
        case .windows1250: return 1250
        case .koi8R: return 20866
        case .koi8U: return 21866
        case .iso8859_1: return 28591
        case .iso8859_2: return 28592
        case .iso8859_5: return 28595
        case .macRoman: return 10000
        case .cp866: return 866
        }
    }

    package init?(codePage: Int) {
        guard let match = Self.allCases.first(where: { $0.codePage == codePage && $0 != .utf8BOM }) else { return nil }
        self = match
    }

    // MARK: - Декодирование и кодирование

    /// Текст из байтов; `nil` — байты не годятся для этой кодировки (неверный UTF-8, нечётная длина UTF-16).
    /// BOM своей кодировки снимается; у UTF-16 без BOM декодируются все байты.
    package func decode(_ data: Data) -> String? {
        switch self {
        case .utf8, .utf8BOM:
            let bytes = self == .utf8BOM && data.starts(with: Self.bomUTF8) ? data.dropFirst(3) : data[...]
            var text = String(decoding: bytes, as: UTF8.self)
            // Неверный UTF-8 заменился бы на U+FFFD — тогда байты обратно не совпадут.
            let same = text.withUTF8 { utf8 in
                bytes.withUnsafeBytes { raw in
                    utf8.count == raw.count && (raw.count == 0 || memcmp(utf8.baseAddress!, raw.baseAddress!, raw.count) == 0)
                }
            }
            return same ? text : nil
        case .utf16LE, .utf16BE:
            let bom = self == .utf16LE ? Self.bomUTF16LE : Self.bomUTF16BE
            let bytes = data.starts(with: bom) ? data.dropFirst(2) : data[...]
            guard bytes.count % 2 == 0 else { return nil }
            let count = bytes.count / 2
            var units = [UInt16](repeating: 0, count: count)
            let little = self == .utf16LE
            bytes.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: UInt8.self)
                units.withUnsafeMutableBufferPointer { target in
                    for i in 0..<count {
                        let a = UInt16(source[2 * i]), b = UInt16(source[2 * i + 1])
                        target[i] = little ? a | b << 8 : a << 8 | b
                    }
                }
            }
            // Одинокие половинки суррогатных пар обратно не закодируются — такие байты не UTF-16.
            guard Self.validSurrogates(units) else { return nil }
            return units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: count) } as String
        default:
            guard let table = SingleByteTable.table(for: self) else { return nil }
            return table.decode(data)
        }
    }

    /// Байты для сохранения; `nil` — в тексте есть символы, которых в этой кодировке нет (`unrepresentable`).
    /// `utf16BOM` — писать ли BOM в UTF-16 (новые и преобразованные файлы — с ним; открытый без BOM — без).
    package func encode(_ text: String, utf16BOM: Bool = true) -> Data? {
        switch self {
        case .utf8: return Data(text.utf8)
        case .utf8BOM: return Self.bomUTF8 + Data(text.utf8)
        case .utf16LE, .utf16BE:
            let units = Self.units(text)
            let head = utf16BOM ? 2 : 0
            var bytes = [UInt8](repeating: 0, count: head + units.count * 2)
            let little = self == .utf16LE
            bytes.withUnsafeMutableBufferPointer { target in
                if utf16BOM {
                    target[0] = little ? 0xFF : 0xFE
                    target[1] = little ? 0xFE : 0xFF
                }
                units.withUnsafeBufferPointer { source in
                    for i in 0..<source.count {
                        let high = UInt8(source[i] >> 8), low = UInt8(source[i] & 0xFF)
                        target[head + 2 * i] = little ? low : high
                        target[head + 1 + 2 * i] = little ? high : low
                    }
                }
            }
            return Data(bytes)
        default:
            return SingleByteTable.table(for: self)?.encode(text)
        }
    }

    /// Первые `limit` символов текста, которых нет в этой кодировке (для предупреждения перед «Преобразовать в…»).
    package func unrepresentable(in text: String, limit: Int = 10) -> [Character] {
        guard let table = SingleByteTable.table(for: self) else { return [] }
        var found: [Character] = []
        for scalar in text.unicodeScalars where table.byte(for: scalar.value) == nil {
            let character = Character(scalar)
            if !found.contains(character) { found.append(character) }
            if found.count >= limit { break }
        }
        return found
    }

    /// UTF-16 текста одним куском (у `NSString` из редактора — без перекодирования).
    package static func units(_ text: String) -> [UInt16] {
        let string = text as NSString
        var units = [UInt16](repeating: 0, count: string.length)
        units.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            string.getCharacters(base, range: NSRange(location: 0, length: buffer.count))
        }
        return units
    }

    /// Каждая половинка суррогатной пары стоит в паре.
    package static func validSurrogates(_ units: [UInt16]) -> Bool {
        units.withUnsafeBufferPointer { buffer in
            var i = 0
            while i < buffer.count {
                let unit = buffer[i]
                if unit & 0xFC00 == 0xD800 {
                    guard i + 1 < buffer.count, buffer[i + 1] & 0xFC00 == 0xDC00 else { return false }
                    i += 2
                } else if unit & 0xFC00 == 0xDC00 {
                    return false
                } else {
                    i += 1
                }
            }
            return true
        }
    }

    /// Есть ли байты ≥ 0x80 (по 8 байт за шаг).
    package static func hasHighBytes(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let count = raw.count
            var i = 0
            while i + 8 <= count {
                if raw.loadUnaligned(fromByteOffset: i, as: UInt64.self) & 0x8080_8080_8080_8080 != 0 { return true }
                i += 8
            }
            while i < count {
                if raw[i] >= 0x80 { return true }
                i += 1
            }
            return false
        }
    }

    package static let bomUTF8 = Data([0xEF, 0xBB, 0xBF])
    package static let bomUTF16LE = Data([0xFF, 0xFE])
    package static let bomUTF16BE = Data([0xFE, 0xFF])

    // MARK: - Автоопределение

    package enum Reason: Equatable {
        case bom, validUTF8, rtfCodePage(Int), fallback, manual
        /// Словарь DSL без BOM и не UTF-8: по языку из заголовка (`#INDEX_LANGUAGE "Russian"`).
        case dslLanguage(String)

        package var title: String {
            switch self {
            case .bom: return "по BOM"
            case .validUTF8: return "текст — правильный UTF-8"
            case .rtfCodePage(let page): return "по \\ansicpg\(page)"
            case .fallback: return "по умолчанию"
            case .manual: return "выбрана вручную"
            case .dslLanguage(let language): return "по языку словаря (\(language))"
            }
        }
    }

    /// Порядок: BOM → правильный UTF-8 с не-ASCII байтами → `\ansicpgNNNN` из заголовка RTF → правильный UTF-8
    /// (чистый ASCII без кодовой страницы) → Windows-1252.
    package static func detect(_ data: Data) -> (encoding: TextEncoding, reason: Reason) {
        if data.starts(with: bomUTF8) { return (.utf8BOM, .bom) }
        if data.starts(with: bomUTF16LE) { return (.utf16LE, .bom) }
        if data.starts(with: bomUTF16BE) { return (.utf16BE, .bom) }
        let ascii = !hasHighBytes(data)
        let validUTF8 = ascii || utf8.decode(data) != nil
        if !ascii, validUTF8 { return (.utf8, .validUTF8) }
        if let page = rtfCodePage(data), let encoding = TextEncoding(codePage: page) {
            // Однобайтовая кодировка читает любые байты; `\ansicpg65001` у файла с неверным UTF-8 не помогает — дальше по умолчанию.
            let readable = encoding.group == .unicode ? encoding.decode(data) != nil : true
            if readable { return (encoding, .rtfCodePage(page)) }
        }
        if ascii { return (.utf8, .validUTF8) }
        return (.windows1252, .fallback)
    }

    /// Языки ABBYY Lingvo на кириллице: словарь DSL без BOM с таким языком — Windows-1251.
    package static let cyrillicDSLLanguages: Set<String> = ["russian", "ukrainian", "belarusian", "bulgarian", "serbian", "macedonian",
                                                             "kazakh", "tatar", "kyrgyz", "bashkir", "chuvash", "mongolian", "tajik"]

    /// Словарь ABBYY Lingvo (`.dsl`): обычно UTF-16 LE с BOM, бывает UTF-8; без BOM и не UTF-8 — однобайтовая кодировка, которую
    /// подсказывает язык заголовка (`#INDEX_LANGUAGE` / `#CONTENTS_LANGUAGE`): кириллица — Windows-1251, иначе как обычно.
    package static func detectDSL(_ data: Data) -> (encoding: TextEncoding, reason: Reason) {
        let detected = detect(data)
        guard detected.reason == .fallback else { return detected }
        if let language = dslLanguages(data).first(where: { cyrillicDSLLanguages.contains($0.lowercased()) }) {
            return (.windows1251, .dslLanguage(language))
        }
        return detected
    }

    /// Языки из заголовка DSL: значения `#INDEX_LANGUAGE "…"` и `#CONTENTS_LANGUAGE "…"` (ASCII в начале файла).
    package static func dslLanguages(_ data: Data) -> [String] {
        let head = String(decoding: data.prefix(4096).map { $0 < 0x80 ? $0 : 0x20 }, as: UTF8.self)
        var languages: [String] = []
        for line in head.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("#INDEX_LANGUAGE") || text.hasPrefix("#CONTENTS_LANGUAGE") else { continue }
            let parts = text.split(separator: "\"")
            if parts.count >= 2 { languages.append(String(parts[1]).trimmingCharacters(in: .whitespaces)) }
        }
        return languages
    }

    /// Номер из `\ansicpgNNNN` в начале файла (RTF пишет его в заголовке).
    package static func rtfCodePage(_ data: Data) -> Int? {
        let head = data.prefix(64 * 1024)
        let marker = Array("\\ansicpg".utf8)
        guard let start = head.firstRange(of: marker)?.upperBound else { return nil }
        var value = 0, digits = 0
        var index = start
        while index < head.endIndex, (0x30...0x39).contains(head[index]), digits < 6 {
            value = value * 10 + Int(head[index] - 0x30)
            digits += 1
            index += 1
        }
        return digits > 0 ? value : nil
    }
}

/// Однобайтовая кодировка: байт ↔ символ. Строится из таблицы CoreFoundation; байт, которого в кодировке нет,
/// становится символом U+00XX (как делает Windows для 0x81 в 1252) — так у каждого байта свой символ.
package struct SingleByteTable {
    package let decodeTable: [UInt16]
    /// Символ BMP → байт; −1 — символа в кодировке нет. Все символы таблицы — из BMP (U+F700… тоже).
    private let encodeTable: [Int16]

    private init(cfEncoding: CFStringEncoding) {
        var decode = [UInt16](repeating: 0, count: 256)
        var used = Set<UInt16>()
        var pending: [Int] = []
        for byte in 0..<256 {
            var value = UInt8(byte)
            let string = CFStringCreateWithBytes(nil, &value, 1, cfEncoding, false) as String?
            let units = string.map { Array($0.utf16) } ?? []
            if units.count == 1, units[0] != 0xFFFD, !used.contains(units[0]) {
                decode[byte] = units[0]
                used.insert(units[0])
            } else {
                pending.append(byte)
            }
        }
        for byte in pending {
            // Свободный U+00XX; если и он занят — из личной области (U+F700 + байт), чтобы не потерять байт.
            let unit = used.contains(UInt16(byte)) ? 0xF700 + UInt16(byte) : UInt16(byte)
            decode[byte] = unit
            used.insert(unit)
        }
        decodeTable = decode
        var encode = [Int16](repeating: -1, count: 0x10000)
        for (byte, unit) in decode.enumerated() { encode[Int(unit)] = Int16(byte) }
        encodeTable = encode
    }

    /// Текст сразу в `NSString` (UTF-16): редактор и скан `$` читают его без перекодирования.
    package func decode(_ data: Data) -> String {
        let count = data.count
        guard count > 0 else { return "" }
        let units = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            decodeTable.withUnsafeBufferPointer { table in
                for i in 0..<count { units[i] = table[Int(bytes[i])] }
            }
        }
        return NSString(charactersNoCopy: units, length: count, freeWhenDone: true) as String
    }

    package func byte(for scalar: UInt32) -> UInt8? {
        guard scalar < 0x10000 else { return nil }
        let byte = encodeTable[Int(scalar)]
        return byte < 0 ? nil : UInt8(byte)
    }

    package func encode(_ text: String) -> Data? {
        let units = TextEncoding.units(text)
        var bytes = [UInt8](repeating: 0, count: units.count)
        let ok = encodeTable.withUnsafeBufferPointer { table in
            units.withUnsafeBufferPointer { source in
                bytes.withUnsafeMutableBufferPointer { target in
                    for i in 0..<source.count {
                        // Половинки суррогатных пар в таблице не встречаются — символы вне BMP непредставимы.
                        let byte = table[Int(source[i])]
                        if byte < 0 { return false }
                        target[i] = UInt8(byte)
                    }
                    return true
                }
            }
        }
        return ok ? Data(bytes) : nil
    }

    /// Таблицы строятся один раз при первом обращении (`static let` ленив и потокобезопасен).
    private static let tables: [TextEncoding: SingleByteTable] = {
        var tables: [TextEncoding: SingleByteTable] = [:]
        for encoding in TextEncoding.allCases {
            if let cf = cfEncoding(encoding) { tables[encoding] = SingleByteTable(cfEncoding: cf) }
        }
        return tables
    }()

    package static func table(for encoding: TextEncoding) -> SingleByteTable? { tables[encoding] }

    private static func cfEncoding(_ encoding: TextEncoding) -> CFStringEncoding? {
        switch encoding {
        case .windows1251: return CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
        case .windows1252: return CFStringEncoding(CFStringBuiltInEncodings.windowsLatin1.rawValue)
        case .windows1250: return CFStringEncoding(CFStringEncodings.windowsLatin2.rawValue)
        case .koi8R: return CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)
        case .koi8U: return CFStringEncoding(CFStringEncodings.KOI8_U.rawValue)
        case .iso8859_1: return CFStringEncoding(CFStringBuiltInEncodings.isoLatin1.rawValue)
        case .iso8859_2: return CFStringEncoding(CFStringEncodings.isoLatin2.rawValue)
        case .iso8859_5: return CFStringEncoding(CFStringEncodings.isoLatinCyrillic.rawValue)
        case .macRoman: return CFStringEncoding(CFStringBuiltInEncodings.macRoman.rawValue)
        case .cp866: return CFStringEncoding(CFStringEncodings.dosRussian.rawValue)
        case .utf8, .utf8BOM, .utf16LE, .utf16BE: return nil
        }
    }
}

// MARK: - Переводы строк

package enum LineEnding: String, CaseIterable, Codable, Sendable {
    case crlf, lf, cr

    package var title: String {
        switch self {
        case .crlf: return "CRLF"
        case .lf: return "LF"
        case .cr: return "CR"
        }
    }

    package var detail: String {
        switch self {
        case .crlf: return "Windows"
        case .lf: return "macOS и Linux"
        case .cr: return "Старый Mac OS"
        }
    }

    package var string: String {
        switch self {
        case .crlf: return "\r\n"
        case .lf: return "\n"
        case .cr: return "\r"
        }
    }

    /// Сколько переводов строк каждого вида.
    package struct Counts: Equatable {
        package var crlf = 0, lf = 0, cr = 0
        package var isMixed: Bool { [crlf, lf, cr].filter { $0 > 0 }.count > 1 }

        /// Вид, которого больше; при равенстве — CRLF, LF, CR. Переводов нет — `nil`.
        package var dominant: LineEnding? {
            let best = max(crlf, lf, cr)
            guard best > 0 else { return nil }
            return crlf == best ? .crlf : (lf == best ? .lf : .cr)
        }
    }

    /// UTF-16 текста кусками по 64 К (без копирования всего текста и без побуквенных вызовов).
    package static func forEachChunk(_ text: NSString, _ body: (UnsafeBufferPointer<UInt16>) -> Void) {
        let length = text.length
        if let pointer = CFStringGetCharactersPtr(text as CFString) {
            body(UnsafeBufferPointer(start: pointer, count: length))
            return
        }
        let size = 65_536
        var buffer = [UInt16](repeating: 0, count: size)
        var location = 0
        while location < length {
            let count = min(size, length - location)
            buffer.withUnsafeMutableBufferPointer { chunk in
                text.getCharacters(chunk.baseAddress!, range: NSRange(location: location, length: count))
                body(UnsafeBufferPointer(rebasing: chunk[..<count]))
            }
            location += count
        }
    }

    package static func count(in text: NSString) -> Counts {
        var counts = Counts()
        var previousCR = false
        forEachChunk(text) { units in
            for unit in units {
                if unit == 0x0A {
                    if previousCR { counts.crlf += 1; counts.cr -= 1 } else { counts.lf += 1 }
                } else if unit == 0x0D {
                    counts.cr += 1
                }
                previousCR = unit == 0x0D
            }
        }
        return counts
    }

    /// Все переводы строк — одного вида (по UTF-16, без перебора символов `String`).
    package static func convert(_ text: NSString, to ending: LineEnding) -> String {
        var result: [UInt16] = []
        result.reserveCapacity(text.length + text.length / 16)
        let replacement = Array(ending.string.utf16)
        var previousCR = false
        forEachChunk(text) { units in
            for unit in units {
                if unit == 0x0A {
                    if !previousCR { result.append(contentsOf: replacement) }
                } else if unit == 0x0D {
                    result.append(contentsOf: replacement)
                } else {
                    result.append(unit)
                }
                previousCR = unit == 0x0D
            }
        }
        guard !result.isEmpty else { return "" }
        return result.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) } as String
    }

    package static func count(in text: String) -> Counts {
        var counts = Counts()
        var previousCR = false
        for unit in text.utf16 {
            if unit == 0x0A {
                if previousCR { counts.crlf += 1; counts.cr -= 1 } else { counts.lf += 1 }
            } else if unit == 0x0D {
                counts.cr += 1
            }
            previousCR = unit == 0x0D
        }
        return counts
    }

    /// Вид, которого больше; при равенстве — CRLF, LF, CR. Переводов нет — `nil` (новый файл берёт LF).
    package static func detect(_ text: String) -> LineEnding? {
        let counts = count(in: text)
        let best = max(counts.crlf, counts.lf, counts.cr)
        guard best > 0 else { return nil }
        return counts.crlf == best ? .crlf : (counts.lf == best ? .lf : .cr)
    }

    /// Все переводы строк — одного вида.
    package static func convert(_ text: String, to ending: LineEnding) -> String {
        var result = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if !previousCR { result.append(contentsOf: ending.string.unicodeScalars) }
            } else if scalar == "\r" {
                result.append(contentsOf: ending.string.unicodeScalars)
            } else {
                result.append(scalar)
            }
            previousCR = scalar == "\r"
        }
        return String(result)
    }
}
