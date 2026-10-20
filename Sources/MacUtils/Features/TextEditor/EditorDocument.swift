import CryptoKit
import Foundation

/// Язык подсветки вкладки (меню «Синтаксис»).
enum EditorLanguage: String, CaseIterable, Codable {
    case rtf, json, xml, plain

    var title: String {
        switch self {
        case .rtf: return "RTF"
        case .json: return "JSON"
        case .xml: return "XML / HTML"
        case .plain: return "Обычный текст"
        }
    }

    /// Коротко — для строки состояния.
    var short: String {
        switch self {
        case .rtf: return "RTF"
        case .json: return "JSON"
        case .xml: return "XML"
        case .plain: return "Текст"
        }
    }

    /// По расширению, а для остальных — по первым байтам (`{\rtf` → RTF).
    static func detect(url: URL?, head: Data) -> EditorLanguage {
        switch url?.pathExtension.lowercased() ?? "" {
        case "frm", "rtf": return .rtf
        case "json": return .json
        case "xml", "html", "htm", "xhtml", "plist", "svg": return .xml
        default: break
        }
        var bytes = head.prefix(64)[...]
        for bom in [TextEncoding.bomUTF8, TextEncoding.bomUTF16LE, TextEncoding.bomUTF16BE] where bytes.starts(with: bom) {
            bytes = bytes.dropFirst(bom.count)
        }
        let start = String(decoding: bytes.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }.prefix(8), as: UTF8.self)
        if start.hasPrefix("{\\rtf") { return .rtf }
        if start.hasPrefix("<?xml") || start.hasPrefix("<!") || start.hasPrefix("<html") { return .xml }
        return .plain
    }
}

/// Отпечаток файла на диске: размер, время изменения и SHA-256 первых 64 КБ. Меняется — файл изменили снаружи.
struct FileStamp: Codable, Equatable {
    let size: Int
    let modified: Date
    let headHash: String

    init(size: Int, modified: Date, headHash: String) {
        self.size = size
        self.modified = modified
        self.headHash = headHash
    }

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        self.init(size: size, modified: modified, headHash: Self.hash(head))
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Перевод строки документа: один вид или смешанные (нормализуются только по явной команде).
enum LineEndingMode: Equatable {
    case single(LineEnding)
    case mixed

    var title: String {
        switch self {
        case .single(let ending): return ending.title
        case .mixed: return "Смешанные"
        }
    }

    static func of(_ text: NSString, default fallback: LineEnding) -> LineEndingMode {
        let counts = LineEnding.count(in: text)
        if counts.isMixed { return .mixed }
        return .single(counts.dominant ?? fallback)
    }

    static func of(_ text: String, default fallback: LineEnding) -> LineEndingMode { of(text as NSString, default: fallback) }
}

/// Документ редактора без UI: байты с диска, кодировка, перевод строки и правило сохранения.
/// Главное: открыть и сохранить без правок — те же байты (пишутся исходные).
struct EditorDocument {
    var url: URL?
    /// Байты, из которых получен текст (с диска или из «Открыть заново в…»).
    private(set) var original: Data
    /// Текст сразу после чтения `original` в `decodedEncoding`.
    private(set) var decodedText: String
    private(set) var decodedEncoding: TextEncoding
    /// Байты не подошли кодировке («Открыть заново в UTF-8» у cp1252): показаны знаком �.
    private(set) var lossyDecode = false
    /// Кодировка при сохранении («Преобразовать в…» меняет только её).
    var encoding: TextEncoding
    /// Откуда взялась кодировка — показывает меню «Кодировка».
    var reason: TextEncoding.Reason
    var language: EditorLanguage
    var fileStamp: FileStamp?

    /// Новый документ: пустой текст в кодировке по умолчанию.
    init(newWith encoding: TextEncoding = .utf8) {
        url = nil
        original = Data()
        decodedText = ""
        decodedEncoding = encoding
        self.encoding = encoding
        reason = .fallback
        language = .plain
    }

    /// Открыть байты: автоопределение кодировки (BOM → UTF-8 → `\ansicpgNNNN` → Windows-1252).
    init(data: Data, url: URL? = nil) {
        let detected = TextEncoding.detect(data)
        self.url = url
        original = data
        decodedEncoding = detected.encoding
        encoding = detected.encoding
        reason = detected.reason
        // Автоопределение выбирает только кодировку, которая читает эти байты.
        decodedText = detected.encoding.decode(data) ?? ""
        language = EditorLanguage.detect(url: url, head: data.prefix(64))
        fileStamp = url.flatMap(FileStamp.init(url:))
    }

    static func open(_ url: URL) throws -> EditorDocument {
        let data = try Data(contentsOf: url)
        return EditorDocument(data: data, url: url)
    }

    var title: String { url?.lastPathComponent ?? "Без имени" }

    /// Сменили кодировку «Преобразовать в…» — сохранение даст другие байты.
    var isConverted: Bool { encoding != decodedEncoding }

    /// «Открыть заново в…»: те же байты в другой кодировке. Неподходящие байты (неверный UTF-8) показываются знаком �
    /// и отмечаются `lossyDecode`; пока текст не правили, сохраняются исходные байты.
    mutating func reinterpret(as newEncoding: TextEncoding) {
        if let text = newEncoding.decode(original) {
            decodedText = text
            lossyDecode = false
        } else {
            decodedText = newEncoding.lossyDecode(original)
            lossyDecode = true
        }
        decodedEncoding = newEncoding
        encoding = newEncoding
        reason = .manual
    }

    enum SaveError: LocalizedError, Equatable {
        case unrepresentable([Character])

        var errorDescription: String? {
            switch self {
            case .unrepresentable(let characters):
                return "Символов нет в выбранной кодировке: \(characters.map(String.init).joined(separator: " "))"
            }
        }
    }

    /// Байты для записи. Текст тот же, что прочитан, и кодировка не менялась — исходные байты (BOM, смешанные
    /// переводы строк и неопределённые байты не трогаются). `lossy` — заменить непредставимые символы на «?».
    func data(for text: String, lossy: Bool = false) throws -> Data {
        // Сравнение побуквенное (`NSString`): у `String` «é» и «e + ◌́» равны, а байты у них разные.
        if encoding == decodedEncoding, (text as NSString).isEqual(to: decodedText) { return original }
        if let data = encoding.encode(text) { return data }
        guard lossy else { throw SaveError.unrepresentable(encoding.unrepresentable(in: text)) }
        return encoding.lossyEncode(text)
    }

    /// После записи: записанные байты становятся исходными.
    mutating func didSave(_ data: Data, text: String, to url: URL) {
        self.url = url
        original = data
        decodedText = text
        decodedEncoding = encoding
        lossyDecode = false
        fileStamp = FileStamp(url: url)
    }

    /// Файл изменили снаружи (размер, время или начало файла).
    var isChangedOnDisk: Bool {
        guard let url, let stamp = fileStamp, let now = FileStamp(url: url) else { return false }
        return now != stamp
    }
}

extension TextEncoding {
    /// Чтение с заменой неподходящих байтов на U+FFFD (для «Открыть заново в…» с неверным UTF-8 или UTF-16).
    func lossyDecode(_ data: Data) -> String {
        if let text = decode(data) { return text }
        switch self {
        case .utf16LE, .utf16BE:
            let bom = self == .utf16LE ? Self.bomUTF16LE : Self.bomUTF16BE
            let bytes = Array(data.starts(with: bom) ? data.dropFirst(2) : data[...])
            let units = stride(from: 0, to: bytes.count - 1, by: 2).map { i -> UInt16 in
                let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
                return self == .utf16LE ? a | b << 8 : a << 8 | b
            }
            // Лишний байт в конце — тоже замена.
            return String(decoding: units, as: UTF16.self) + (bytes.count % 2 == 1 ? "\u{FFFD}" : "")
        default:
            let bytes = self == .utf8BOM && data.starts(with: Self.bomUTF8) ? data.dropFirst(3) : data[...]
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Запись с заменой непредставимых символов на «?» (только после согласия пользователя).
    func lossyEncode(_ text: String) -> Data {
        if let data = encode(text) { return data }
        guard let table = SingleByteTable.table(for: self) else { return Data(text.utf8) }
        return Data(text.unicodeScalars.map { table.byte(for: $0.value) ?? 0x3F })
    }
}
