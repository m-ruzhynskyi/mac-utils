import Foundation

/// Стиль из `{\stylesheet}` (S1): абзацный `\sN` или знаковый `\csN`. Читается отдельно от `RTFReader`: модель документа стили не берёт
/// (форматирование в файле записано прямо в абзацах), а для «применить стиль» нужны номер, имя и то, что стиль задаёт.
package struct DocStyle: Equatable, Identifiable {
    package enum Kind: Equatable { case paragraph, character }

    package let kind: Kind
    /// Номер в `\sN` / `\csN`.
    package let number: Int
    /// Имя как в файле.
    package let name: String
    /// Имя для списка: встроенные стили Word с английским именем показываются по-русски, остальные — как в файле.
    package let displayName: String
    package let basedOn: Int?
    package let hidden: Bool
    /// Собственные коды форматирования стиля (без `\sbasedon`, `\snext` и прочих служебных), по порядку.
    package let words: [String]
    /// Группа стиля в исходнике.
    package let group: NSRange

    package var id: String { (kind == .paragraph ? "s" : "cs") + String(number) }
}

package struct DocStyleSheet {
    package var styles: [DocStyle] = []
    /// Исходник до `{\stylesheet`: заголовок RTF с таблицами шрифтов и цветов — основа для чтения кодов стиля.
    package var head = ""

    package init() {}

    package func style(_ kind: DocStyle.Kind, _ number: Int) -> DocStyle? { styles.first { $0.kind == kind && $0.number == number } }

    package var paragraphStyles: [DocStyle] { styles.filter { $0.kind == .paragraph && !$0.hidden } }
    package var characterStyles: [DocStyle] { styles.filter { $0.kind == .character && !$0.hidden } }

    /// Коды стиля вместе с унаследованными от «основан на»: сначала базовый, затем свои (позднее перекрывает раннее).
    package func resolvedWords(_ style: DocStyle) -> [String] {
        var chain: [DocStyle] = [style]
        var seen: Set<String> = [style.id]
        var current = style
        while let base = current.basedOn, let next = self.style(current.kind, base), seen.insert(next.id).inserted, chain.count < 12 {
            chain.append(next)
            current = next
        }
        return chain.reversed().flatMap(\.words)
    }

    // MARK: - Чтение

    /// Служебные коды стиля: не форматирование.
    private static let meta: Set<String> = [
        "sbasedon", "snext", "slink", "sautoupd", "sqformat", "spriority", "ssemihidden", "sunhideused", "slocked", "shidden",
        "styrsid", "additive", "scompose", "sreply", "keycode", "ctrl", "shift", "alt", "fn", "s", "cs", "ts", "ds", "sbasedon",
    ]

    package static func parse(_ source: NSString) -> DocStyleSheet {
        var sheet = DocStyleSheet()
        let marker = source.range(of: "{\\stylesheet")
        guard marker.location != NSNotFound else { return sheet }
        sheet.head = source.substring(to: marker.location)
        let groups = RTFGroupIndex(source)
        guard let sheetIndex = groups.opens.firstIndex(of: marker.location) else { return sheet }
        for (index, open) in groups.opens.enumerated() where groups.parents[index] == sheetIndex {
            let close = min(groups.closes[index], source.length)
            guard close > open + 1 else { continue }
            if let style = parseEntry(source, open: open, close: close, head: sheet.head, groups: groups, groupIndex: index) { sheet.styles.append(style) }
        }
        return sheet
    }

    private static func parseEntry(_ source: NSString, open: Int, close: Int, head: String, groups: RTFGroupIndex, groupIndex: Int) -> DocStyle? {
        let tokens = RTFLexer.tokens(source, in: NSRange(location: open + 1, length: close - open - 1))
        var kind: DocStyle.Kind?
        var number = 0
        var basedOn: Int?
        var hidden = false
        var words: [String] = []
        var nameStart: Int?
        var depth = 0
        for token in tokens {
            switch token.kind {
            case .open: depth += 1; continue
            case .close: depth -= 1; continue
            default: break
            }
            guard depth == 0 else { continue }
            if nameStart != nil { continue }
            switch token.kind {
            case .word:
                switch token.name {
                case "s" where kind == nil: kind = .paragraph; number = token.number ?? 0
                case "cs" where kind == nil: kind = .character; number = token.number ?? 0
                case "ts", "ds": return nil
                case "sbasedon": basedOn = token.number.flatMap { $0 == 222 ? nil : $0 }
                case "ssemihidden", "shidden": hidden = (token.number ?? 1) != 0
                case let name where meta.contains(name): break
                default:
                    guard kind != nil else { continue }
                    words.append("\\" + token.name + (token.number.map(String.init) ?? ""))
                }
            case .text, .hex, .symbol:
                // Стиль «по умолчанию» (Обычный) записан без `\sN`: это абзацный стиль 0.
                if kind == nil, token.kind != .symbol { kind = .paragraph; number = 0 }
                if kind != nil, token.kind != .symbol || token.name != "*" { nameStart = token.range.location }
            default: break
            }
        }
        guard let kind, let nameStart else { return nil }
        let raw = source.substring(with: NSRange(location: nameStart, length: close - nameStart))
        let name = decodeName(raw.components(separatedBy: ";").first ?? raw, head: head)
        guard !name.isEmpty else { return nil }
        return DocStyle(kind: kind, number: number, name: name, displayName: localized(name), basedOn: basedOn, hidden: hidden,
                        words: words, group: NSRange(location: open, length: close - open + 1))
    }

    /// Имя с `\'hh` и `\uN` — через `RTFReader` по заголовку документа (кодовая страница та же).
    private static func decodeName(_ raw: String, head: String) -> String {
        let model = RTFReader.read((head + "\\pard\\plain " + raw + "\\par}") as NSString)
        let text = model.body.paragraphs.flatMap(\.runs).filter { $0.kind == .text }.map(\.text).joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Встроенные стили Word хранятся в файле под английскими именами — в списке они по-русски.
    package static func localized(_ name: String) -> String {
        guard name.allSatisfy({ $0.isASCII }) else { return name }
        let lower = name.lowercased()
        if let number = Int(lower.replacingOccurrences(of: "heading ", with: "")), lower.hasPrefix("heading ") { return "Заголовок \(number)" }
        return builtin[lower] ?? name
    }

    private static let builtin: [String: String] = [
        "normal": "Обычный", "title": "Название", "subtitle": "Подзаголовок", "body text": "Основной текст",
        "body text 2": "Основной текст 2", "body text 3": "Основной текст 3", "body text indent": "Основной текст с отступом",
        "header": "Верхний колонтитул", "footer": "Нижний колонтитул", "list paragraph": "Абзац списка", "list": "Список",
        "list bullet": "Маркированный список", "list number": "Нумерованный список", "no spacing": "Без интервала",
        "quote": "Цитата", "intense quote": "Выделенная цитата", "caption": "Название объекта", "toc heading": "Заголовок оглавления",
        "default paragraph font": "Основной шрифт абзаца", "strong": "Выделение жирным", "emphasis": "Выделение курсивом",
        "page number": "Номер страницы", "hyperlink": "Гиперссылка", "footnote text": "Текст сноски", "plain text": "Обычный текст",
        "block text": "Цитата в блоке", "table grid": "Сетка таблицы", "normal (web)": "Обычный (веб)", "annotation text": "Текст примечания",
        "balloon text": "Текст выноски", "macro text": "Текст макроса", "salutation": "Приветствие", "closing": "Закрытие",
        "signature": "Подпись", "date": "Дата", "note heading": "Заголовок записки", "envelope address": "Адрес на конверте",
        "envelope return": "Обратный адрес",
    ]

    // MARK: - Что стиль задаёт

    /// Свойства стиля, как их читает `RTFReader` (коды стиля с унаследованными, поверх `\pard\plain`): абзац, знаки, шрифт и цвет.
    package struct Properties {
        package var paragraph: RTFParaProps
        package var character: RTFCharProps
        package var fontName: String?
        package var color: RTFColor?
    }

    package func properties(of style: DocStyle) -> Properties? {
        guard !head.isEmpty else { return nil }
        let words = resolvedWords(style).joined()
        let model = RTFReader.read((head + "\\pard\\plain " + words + " x\\par}") as NSString)
        guard let paragraph = model.body.paragraphs.first, let run = paragraph.runs.first else { return nil }
        return Properties(paragraph: paragraph.props, character: run.props, fontName: model.font(run.props.font)?.name,
                          color: run.props.color > 0 ? model.color(run.props.color) : nil)
    }
}
