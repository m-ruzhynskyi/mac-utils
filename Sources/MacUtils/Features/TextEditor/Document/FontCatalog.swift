import AppKit
import CoreText
import MUAudio

/// Чем показать шрифт Word на Mac. В файле всегда остаётся исходное имя — замена только для экрана.
enum FontSubstitution {
    /// Шрифты Office, которых нет в macOS, → ближайшие по виду (план, § 4.6).
    static let table: [String: String] = [
        "Calibri": "Helvetica Neue", "Calibri Light": "Helvetica Neue", "Aptos": "Helvetica Neue", "Segoe UI": "Helvetica Neue",
        "Candara": "Helvetica Neue", "Corbel": "Helvetica Neue",
        "Cambria": "Georgia", "Constantia": "Georgia", "Century": "Georgia",
        "Consolas": "Menlo", "Lucida Console": "Menlo",
        "Palatino Linotype": "Palatino", "Book Antiqua": "Palatino",
        "Lucida Sans": "Lucida Grande", "Lucida Sans Unicode": "Lucida Grande",
        "Gill Sans MT": "Gill Sans",
        "Franklin Gothic": "Avenir Next Condensed", "Franklin Gothic Medium": "Avenir Next Condensed",
        "Monotype Corsiva": "Apple Chancery",
        "Rockwell": "American Typewriter",
        "Cambria Math": "STIX Two Math",
    ]

    /// Имя без приставок старых кириллических шрифтов Windows («Times New Roman Cyr» → «Times New Roman»).
    static func baseName(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespaces)
        for suffix in [" CYR", " Cyr", " cyr", " CE", " Baltic", " Greek", " Tur"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    /// Семейство для показа: само (если есть), из таблицы замен, по семейству `\fonttbl` или по `\panose`.
    static func display(for name: String, family: RTFFont.Family = .nil_, panose: String? = nil,
                        available: (String) -> Bool = FontCatalog.isInstalled) -> String {
        let base = baseName(name)
        if !base.isEmpty, available(base) { return base }
        if let replacement = table[base], available(replacement) { return replacement }
        let byFamily: String
        switch family {
        case .roman: byFamily = "Times New Roman"
        case .swiss: byFamily = "Arial"
        case .modern: byFamily = "Courier New"
        case .script: byFamily = "Apple Chancery"
        case .decor, .tech, .nil_, .bidi: byFamily = byPanose(panose) ?? "Times New Roman"
        }
        return available(byFamily) ? byFamily : "Helvetica"
    }

    /// По классу PANOSE: моноширинный → Courier New, рубленый → Arial, с засечками → Times New Roman.
    static func byPanose(_ panose: String?) -> String? {
        guard let panose, panose.count >= 8 else { return nil }
        let bytes = stride(from: 0, to: panose.count - 1, by: 2).compactMap { offset -> UInt8? in
            let start = panose.index(panose.startIndex, offsetBy: offset)
            return UInt8(panose[start..<panose.index(start, offsetBy: 2)], radix: 16)
        }
        guard bytes.count >= 4, bytes[0] == 2 else { return nil }
        if bytes[3] == 9 { return "Courier New" }
        if (11...13).contains(bytes[1]) { return "Arial" }
        return "Times New Roman"
    }
}

/// Каталог шрифтов для списка в режиме «Документ» (`d09`): шрифты документа, стандартный набор Word и все шрифты
/// Mac. Проверка наличия — только чтение; загрузка системного шрифта — только по нажатию «Загрузить».
enum FontCatalog {
    /// Стандартный набор Word (то, что пользователь ждёт увидеть в списке).
    static let word: [String] = [
        "Arial", "Arial Black", "Arial Narrow", "Aptos", "Bahnschrift", "Book Antiqua", "Bookman Old Style", "Calibri",
        "Calibri Light", "Cambria", "Cambria Math", "Candara", "Century", "Century Gothic", "Comic Sans MS", "Consolas",
        "Constantia", "Corbel", "Courier New", "Franklin Gothic Medium", "Garamond", "Georgia", "Gill Sans MT", "Impact",
        "Lucida Console", "Lucida Sans", "Lucida Sans Unicode", "Microsoft Sans Serif", "Monotype Corsiva", "MS Gothic",
        "Palatino Linotype", "Rockwell", "Segoe Print", "Segoe Script", "Segoe UI", "Sylfaen", "Symbol", "Tahoma",
        "Times New Roman", "Trebuchet MS", "Verdana", "Webdings", "Wingdings",
    ]

    /// Шрифты Word, которые macOS загружает сама (Font Book) — с кнопкой «Загрузить».
    static let downloadable: Set<String> = ["Garamond", "Century Gothic", "Book Antiqua", "Bookman Old Style"]

    private static var installedCache: Set<String>?

    static var installedFamilies: Set<String> {
        if let installedCache { return installedCache }
        let families = Set(NSFontManager.shared.availableFontFamilies)
        installedCache = families
        return families
    }

    static func isInstalled(_ family: String) -> Bool { installedFamilies.contains(family) }

    /// Список установленных обновился (после загрузки шрифта).
    static func refresh() { installedCache = nil }

    enum Availability: Equatable {
        case installed
        /// Есть в системе для загрузки — показ заменой, пока не загружен.
        case downloadable(substitute: String)
        /// Нет на Mac (ставится только с Office) — показ заменой.
        case missing(substitute: String)
    }

    static func availability(_ name: String, family: RTFFont.Family = .nil_, panose: String? = nil) -> Availability {
        let base = FontSubstitution.baseName(name)
        if isInstalled(base) { return .installed }
        let substitute = FontSubstitution.display(for: name, family: family, panose: panose)
        return downloadable.contains(base) ? .downloadable(substitute: substitute) : .missing(substitute: substitute)
    }

    /// Загрузка системного шрифта по нажатию: прогресс 0…1, в конце `done(успех)`. Молча не вызывается.
    static func download(_ family: String, progress: @escaping @MainActor (Double) -> Void, done: @escaping @MainActor (Bool) -> Void) {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, nil) { state, info in
            let values = info as NSDictionary
            switch state {
            case .didFinish:
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        refresh()
                        done(isInstalled(family))
                    }
                }
                return false
            case .didFailWithError:
                DispatchQueue.main.async { MainActor.assumeIsolated { done(false) } }
                return false
            case .downloading:
                let percent = (values[kCTFontDescriptorMatchingPercentage] as? NSNumber)?.doubleValue ?? 0
                DispatchQueue.main.async { MainActor.assumeIsolated { progress(percent / 100) } }
                return true
            default:
                return true
            }
        }
    }
}
