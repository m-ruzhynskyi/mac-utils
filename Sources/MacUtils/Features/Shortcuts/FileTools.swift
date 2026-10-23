import Foundation
import MUCore

/// Действия над файлом без окна редактора («Команды», ссылки `macutils://…`): знаки `$`, кодировка, переводы строк.
/// Чтение — как в редакторе (`EditorDocument`: BOM → UTF-8 → `\ansicpg` → Windows-1252), запись — как «Сохранить»
/// (`EditorWindowController.writeFile`: права, метки и дата создания остаются).
enum FileTools {
    enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case unrepresentable(String)
        case brokenBraces(Int)
        case verification

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Не удалось прочитать «\(name)» как текст"
            case .unrepresentable(let characters): return "Символов нет в выбранной кодировке: \(characters)"
            case .brokenBraces(let count):
                return "После удаления в файле стало бы непарных скобок { }: \(count). Файл не изменён — уберите значения в редакторе"
            case .verification: return "Проверка записи не сошлась: файл не изменён"
            }
        }
    }

    /// Знак `$` файла для «Найти значения $ в файле».
    struct DollarValue: Equatable {
        let line: Int
        let value: String
        /// Пропущен по «Пропускать первые N» — «Убрать значения» его не тронет.
        let skipped: Bool
    }

    /// Что даст «Убрать значения $» для этих байтов: новые байты и сколько значений убрано.
    struct Removal: Equatable {
        let data: Data
        let removed: Int
    }

    static func open(_ url: URL) throws -> EditorDocument {
        let document = try EditorDocument.open(url)
        // Байты есть, а текста нет — кодировку не подобрать (двоичный файл).
        guard !(document.decodedText.isEmpty && !document.original.isEmpty) else { throw Failure.unreadable(url.lastPathComponent) }
        return document
    }

    // MARK: - Знаки $

    /// Знаки текста страницы (без служебных групп RTF), как в панели «Знаки $»: правило «по исходнику».
    static func dollarEntries(_ document: EditorDocument) -> [DollarEntry] {
        DollarPanelModel.scan(document.decodedText as NSString, rule: .source, encoding: document.decodedEncoding).filter { !$0.isHidden }
    }

    static func findDollarValues(in url: URL, skipFirst: Int?) throws -> [DollarValue] {
        let entries = dollarEntries(try open(url))
        let skip = min(max(skipFirst ?? 0, 0), entries.count)
        return entries.enumerated().map { index, entry in DollarValue(line: entry.line, value: entry.value, skipped: index < skip) }
    }

    /// «Убрать значения $» без окна: те же знаки, что в панели (первые N пропущены), `$` остаются.
    /// Байты вне убранных значений берутся из исходного файла как есть; результат перечитывается и сверяется с текстом.
    /// Был баланс `{ }`, а после удаления его не стало бы — ничего не меняется (в редакторе это видно и отменяется ⌘Z,
    /// здесь — нет).
    static func removal(of document: EditorDocument, skipFirst: Int?) throws -> Removal {
        let text = document.decodedText as NSString
        let entries = dollarEntries(document)
        let skip = min(max(skipFirst ?? 0, 0), entries.count)
        let marks = entries.dropFirst(skip).map(\.mark)
        let removed = marks.filter { !$0.isEmpty }.count
        guard removed > 0 else { return Removal(data: document.original, removed: 0) }
        let expected = DollarMarks.removingValues(of: marks, in: document.decodedText)
        if DollarMarks.unbalancedBraces(in: text) == 0 {
            let after = DollarMarks.unbalancedBraces(in: expected as NSString)
            if after > 0 { throw Failure.brokenBraces(after) }
        }
        // Куски значений по возрастанию → байтовые диапазоны исходника.
        let ranges = DollarMarks.valueRanges(marks).sorted { $0.location < $1.location }
        let encoding = document.decodedEncoding
        var bytes = Data()
        var unit = 0, byte = bomLength(of: document)
        bytes.append(document.original.prefix(byte))
        for range in ranges where range.length > 0 {
            let keep = try byteCount(text.substring(with: NSRange(location: unit, length: range.location - unit)), encoding)
            bytes.append(document.original.subdata(in: byte..<byte + keep))
            byte += keep + (try byteCount(text.substring(with: range), encoding))
            unit = NSMaxRange(range)
        }
        bytes.append(document.original.suffix(from: byte))
        guard let check = encoding.decode(bytes), (check as NSString).isEqual(to: expected) else { throw Failure.verification }
        return Removal(data: bytes, removed: removed)
    }

    /// Убрать значения в файле и записать. Возвращает, сколько значений убрано (0 — файл не трогается).
    @discardableResult
    static func removeDollarValues(in url: URL, skipFirst: Int?) throws -> Int {
        let result = try removal(of: try open(url), skipFirst: skipFirst)
        if result.removed > 0 { try EditorWindowController.writeFile(result.data, to: url) }
        return result.removed
    }

    private static func bomLength(of document: EditorDocument) -> Int {
        let data = document.original
        switch document.decodedEncoding {
        case .utf8BOM: return data.starts(with: TextEncoding.bomUTF8) ? 3 : 0
        case .utf16LE: return data.starts(with: TextEncoding.bomUTF16LE) ? 2 : 0
        case .utf16BE: return data.starts(with: TextEncoding.bomUTF16BE) ? 2 : 0
        default: return 0
        }
    }

    /// Сколько байтов занимает кусок текста в этой кодировке (без BOM).
    private static func byteCount(_ text: String, _ encoding: TextEncoding) throws -> Int {
        let plain: TextEncoding = encoding == .utf8BOM ? .utf8 : encoding
        guard let data = plain.encode(text, utf16BOM: false) else { throw Failure.verification }
        return data.count
    }

    // MARK: - Кодировка и переводы строк

    /// «Преобразовать в…»: тот же текст в другой кодировке. Возвращает false, если менять нечего.
    /// `from` — в какой кодировке файл сейчас, если автоопределение ошибается («Открыть заново в…»): у текста в
    /// Windows-1251 без `\ansicpg` оно видит Windows-1252.
    @discardableResult
    static func convertEncoding(of url: URL, to target: TextEncoding, from source: TextEncoding? = nil) throws -> Bool {
        var document = try open(url)
        if let source, source != document.decodedEncoding {
            document.reinterpret(as: source)
            guard !document.lossyDecode else { throw Failure.unreadable(url.lastPathComponent) }
        }
        guard target != document.decodedEncoding else { return false }
        document.encoding = target
        let data: Data
        do { data = try document.data(for: document.decodedText) } catch EditorDocument.SaveError.unrepresentable(let characters) {
            throw Failure.unrepresentable(characters.map(String.init).joined(separator: " "))
        }
        try EditorWindowController.writeFile(data, to: url)
        return true
    }

    /// Переводы строк файла — все одного вида. Возвращает false, если менять нечего.
    @discardableResult
    static func convertLineEndings(of url: URL, to ending: LineEnding) throws -> Bool {
        let document = try open(url)
        let converted = LineEnding.convert(document.decodedText, to: ending)
        guard !(converted as NSString).isEqual(to: document.decodedText) else { return false }
        try EditorWindowController.writeFile(try document.data(for: converted), to: url)
        return true
    }
}
