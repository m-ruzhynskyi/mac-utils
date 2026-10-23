import AppKit
import MUCore

/// Новые записи `\fonttbl` и `\colortbl` для команды форматирования. Пишутся в конец таблицы, перед её `}`:
/// номера существующих шрифтов и цветов не меняются. Шрифт, которого нет на Mac, пишется под исходным именем — замена
/// только на экране.
struct FormatTables {
    let source: NSString
    let model: RTFDocumentModel
    private(set) var addedFonts: [RTFFont] = []
    private(set) var addedColors: [RTFColor] = []

    init(source: NSString, model: RTFDocumentModel) {
        self.source = source
        self.model = model
    }

    // MARK: - Шрифты

    /// Номер шрифта `name` с той же кодировкой `\'hh`, что у шрифта `like` (иначе байты кириллицы прочитались бы
    /// другой кодовой страницей). Нет такого в таблице — новая запись. `nil` — в файле нет `\fonttbl`.
    mutating func fontNumber(name: String, like font: RTFFont?) -> Int? {
        let encoding = Self.encoding(of: font, model: model)
        let wanted = name.trimmingCharacters(in: .whitespaces)
        let existing = model.fonts.values.filter {
            $0.name == wanted && Self.encoding(of: $0, model: model) == encoding
        }.map(\.number).min()
        if let existing { return existing }
        if let added = addedFonts.first(where: { $0.name == wanted && Self.encoding(of: $0, model: model) == encoding }) {
            return added.number
        }
        guard model.fontTable != nil else { return nil }
        let number = max(model.fonts.keys.max() ?? -1, addedFonts.map(\.number).max() ?? -1) + 1
        var entry = RTFFont(number: number, name: wanted, family: Self.family(for: wanted))
        entry.charset = font?.charset ?? Self.charset(for: encoding)
        entry.codePage = font?.codePage
        addedFonts.append(entry)
        return number
    }

    /// Кодировка `\'hh` у шрифта (как читает `RTFReader`).
    static func encoding(of font: RTFFont?, model: RTFDocumentModel) -> TextEncoding {
        guard let font else { return model.codePage }
        return RTFReader.encoding(charset: font.charset, codePage: font.codePage, document: model.codePage)
    }

    static func charset(for encoding: TextEncoding) -> Int {
        switch encoding {
        case .windows1251, .koi8R, .koi8U, .iso8859_5, .cp866: return 204
        case .windows1250, .iso8859_2: return 238
        default: return 0
        }
    }

    /// Семейство для `\fonttbl` (`\froman`, `\fswiss`, `\fmodern`…): стандартные шрифты Word — по таблице, остальные —
    /// по признакам шрифта Mac.
    static func family(for name: String) -> RTFFont.Family {
        if let known = wordFamilies[FontSubstitution.baseName(name)] { return known }
        guard let font = NSFont(name: name, size: 12) ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: 12) else {
            return .nil_
        }
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.monoSpace) { return .modern }
        switch traits.rawValue & NSFontDescriptor.SymbolicTraits.classMask.rawValue {
        case NSFontDescriptor.SymbolicTraits.classOldStyleSerifs.rawValue, NSFontDescriptor.SymbolicTraits.classTransitionalSerifs.rawValue,
             NSFontDescriptor.SymbolicTraits.classModernSerifs.rawValue, NSFontDescriptor.SymbolicTraits.classClarendonSerifs.rawValue,
             NSFontDescriptor.SymbolicTraits.classSlabSerifs.rawValue, NSFontDescriptor.SymbolicTraits.classFreeformSerifs.rawValue:
            return .roman
        case NSFontDescriptor.SymbolicTraits.classScripts.rawValue: return .script
        case NSFontDescriptor.SymbolicTraits.classOrnamentals.rawValue, NSFontDescriptor.SymbolicTraits.classSymbolic.rawValue: return .decor
        default: return .swiss
        }
    }

    static let wordFamilies: [String: RTFFont.Family] = {
        var table: [String: RTFFont.Family] = [:]
        for name in ["Times New Roman", "Georgia", "Cambria", "Cambria Math", "Garamond", "Book Antiqua", "Bookman Old Style", "Century",
                     "Constantia", "Palatino Linotype", "Sylfaen", "Rockwell"] { table[name] = .roman }
        for name in ["Arial", "Arial Black", "Arial Narrow", "Aptos", "Bahnschrift", "Calibri", "Calibri Light", "Candara", "Corbel",
                     "Century Gothic", "Franklin Gothic Medium", "Gill Sans MT", "Impact", "Lucida Sans", "Lucida Sans Unicode",
                     "Microsoft Sans Serif", "Segoe UI", "Tahoma", "Trebuchet MS", "Verdana"] { table[name] = .swiss }
        for name in ["Courier New", "Consolas", "Lucida Console", "MS Gothic"] { table[name] = .modern }
        for name in ["Comic Sans MS", "Monotype Corsiva", "Segoe Print", "Segoe Script"] { table[name] = .script }
        for name in ["Symbol", "Webdings"] { table[name] = .tech }
        table["Wingdings"] = .nil_
        return table
    }()

    // MARK: - Цвета

    /// Номер цвета в `\colortbl`: есть такой же — его, иначе новый в конце. `nil` — дописать нельзя.
    mutating func colorIndex(_ color: RTFColor) -> Int? {
        if let index = model.colors.indices.dropFirst().first(where: { model.colors[$0] == color }) { return index }
        let base = max(model.colors.count, 1)
        if let added = addedColors.firstIndex(of: color) { return base + added }
        guard model.colorTable != nil ? colorTableEndsWithSeparator : model.fontTable != nil else { return nil }
        addedColors.append(color)
        return base + addedColors.count - 1
    }

    /// Последняя запись `\colortbl` закрыта `;` — иначе новая запись склеилась бы с ней.
    private var colorTableEndsWithSeparator: Bool {
        guard let table = model.colorTable, table.length >= 2 else { return false }
        var index = NSMaxRange(table) - 2
        while index > table.location, [0x20, 0x0D, 0x0A, 0x09].contains(source.character(at: index)) { index -= 1 }
        let unit = source.character(at: index)
        // `{\colortbl}` без записей — тоже можно: первым пишется «авто».
        return unit == 0x3B || (model.colors.isEmpty && unit != 0x7B)
    }

    // MARK: - Правки

    /// Вставки в таблицы шрифтов и цветов.
    func edits() -> [FormatEdit] {
        var edits: [FormatEdit] = []
        if !addedFonts.isEmpty, let table = model.fontTable {
            let text = addedFonts.map(Self.entry).joined()
            edits.append(FormatEdit(range: NSRange(location: NSMaxRange(table) - 1, length: 0), string: text, order: 1))
        }
        if !addedColors.isEmpty {
            let entries = addedColors.map { "\\red\($0.red)\\green\($0.green)\\blue\($0.blue);" }.joined()
            if let table = model.colorTable {
                let prefix = model.colors.isEmpty ? ";" : ""
                edits.append(FormatEdit(range: NSRange(location: NSMaxRange(table) - 1, length: 0), string: prefix + entries, order: 1))
            } else if let fonts = model.fontTable {
                edits.append(FormatEdit(range: NSRange(location: NSMaxRange(fonts), length: 0), string: "{\\colortbl;" + entries + "}", order: 1))
            }
        }
        return edits
    }

    /// Запись `\fonttbl`, как пишет Word: `{\f43\fswiss\fcharset204\fprq2 Calibri;}`.
    static func entry(_ font: RTFFont) -> String {
        var text = "{\\f\(font.number)\\\(font.family.rawValue)\\fcharset\(font.charset)"
        if let codePage = font.codePage { text += "\\cpg\(codePage)" }
        text += "\\fprq\(font.family == .modern ? 1 : 2) " + escape(font.name) + ";}"
        return text
    }

    /// Имя шрифта для RTF: служебные `\ { }` экранируются, не-ASCII — `\uN?`.
    static func escape(_ name: String) -> String {
        var out = ""
        for unit in name.utf16 {
            switch unit {
            case 0x5C, 0x7B, 0x7D: out += "\\" + String(utf16CodeUnits: [unit], count: 1)
            case 0x3B: continue
            case 0x20..<0x80: out += String(utf16CodeUnits: [unit], count: 1)
            default: out += "\\u\(Int(Int16(bitPattern: unit)))?"
            }
        }
        return out
    }
}
