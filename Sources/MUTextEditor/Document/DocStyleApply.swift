import AppKit
import MUCore

/// Стили в «Документе» (S1): список из `\stylesheet`, текущий стиль под курсором, «применить». Менять стили нельзя.
/// «Применить» — точечные правки исходника: `\sN` и то, что задаёт стиль (абзац — `ParaChange`, знаки — коды шрифта, размера, начертаний
/// и цвета), как Word записывает их в абзац; знаковый стиль — группа `{\csN …}` вокруг выделения. Всё вместе — один шаг отмены.
package enum DocStyleCommand {
    /// Что известно о месте курсора (без доступа к документу — для тестов).
    package struct Context: Equatable {
        package var isDocument = true
        package var inHeader = false
        /// Курсор или выделение в абзаце основного текста, который можно править.
        package var paragraphEditable = true
        /// В выделении есть текст (знаковый стиль к пустому месту не применяется).
        package var hasText = false

        package init(isDocument: Bool = true, inHeader: Bool = false, paragraphEditable: Bool = true, hasText: Bool = false) {
            self.isDocument = isDocument
            self.inHeader = inHeader
            self.paragraphEditable = paragraphEditable
            self.hasText = hasText
        }
    }

    package enum Availability: Equatable {
        case hidden
        case disabled(String)
        case enabled

        package var isEnabled: Bool { self == .enabled }
        package var isVisible: Bool { self != .hidden }
    }

    package static func availability(_ style: DocStyle, in context: Context) -> Availability {
        guard context.isDocument else { return .hidden }
        if context.inHeader { return .disabled("Стиль в колонтитуле пока выбирается в режиме «Код»") }
        switch style.kind {
        case .paragraph: return context.paragraphEditable ? .enabled : .disabled("Этот абзац нельзя править в «Документе»")
        case .character: return context.hasText ? .enabled : .disabled("Выделите текст, чтобы применить стиль знаков")
        }
    }
}

extension DocumentController {
    /// Стили документа (читаются при первом обращении и после правки исходника).
    package var styleSheet: DocStyleSheet {
        guard let tab else { return DocStyleSheet() }
        if let cached = styleCache, cached.revision == tab.sourceRevision { return cached.sheet }
        let sheet = DocStyleSheet.parse(tab.text)
        styleCache = (tab.sourceRevision, sheet)
        return sheet
    }

    /// Абзацный стиль под курсором (по `\sN` абзаца); `nil` — стиля нет в таблице.
    package var currentParagraphStyle: DocStyle? {
        guard let index = rendering.paragraph(atUnit: min(selectedUnits.location, max(0, rendering.length - 1))),
              let number = model.body.paragraphs[safe: index]?.props.style else { return nil }
        return styleSheet.style(.paragraph, number)
    }

    /// Знаковый стиль под курсором: ближайшая объемлющая группа с `\csN` в начале.
    package var currentCharacterStyle: DocStyle? {
        guard let tab else { return nil }
        let source = tab.text
        let location = rendering.map.sourceLocation(beforeUnit: min(selectedUnits.location, rendering.map.count))
        let groups = RTFGroupIndex(source)
        var group = groups.innermost(containing: location)
        while let index = group {
            for token in RTFLexer.tokens(source, in: NSRange(location: groups.opens[index] + 1, length: min(60, max(0, source.length - groups.opens[index] - 1)))) {
                guard token.kind == .word || (token.kind == .symbol && token.name == "*") else { break }
                if token.name == "cs", let number = token.number { return styleSheet.style(.character, number) }
            }
            group = groups.parents[index] >= 0 ? groups.parents[index] : nil
        }
        return nil
    }

    package var styleContext: DocStyleCommand.Context {
        guard let tab, tab.mode == .document else { return DocStyleCommand.Context(isDocument: false) }
        var context = DocStyleCommand.Context()
        context.inHeader = openHeaderSession != nil
        let units = selectedUnits
        context.paragraphEditable = !paragraphs(in: units).isEmpty
        if units.length > 0 {
            let text = storage.string as NSString
            context.hasText = (units.location..<min(NSMaxRange(units), text.length)).contains { rendering.map.kind(at: $0) == .text }
        }
        return context
    }

    /// Применить стиль: абзацный — ко всем абзацам выделения, знаковый — к выделенному тексту. `false` — недоступен или отказал.
    @discardableResult
    package func applyStyle(_ style: DocStyle) -> Bool {
        guard let tab else { return false }
        let context = styleContext
        if case .disabled(let reason) = DocStyleCommand.availability(style, in: context) {
            show(notice: reason)
            Feedback.beep()
            return false
        }
        guard DocStyleCommand.availability(style, in: context).isEnabled else { return false }
        typingBurst = nil
        let sheet = styleSheet
        guard let properties = sheet.properties(of: style) else {
            show(notice: "Стиль не читается: нет таблицы шрифтов в начале файла")
            return false
        }
        tab.undo.beginUndoGrouping()
        defer {
            tab.undo.endUndoGrouping()
            tab.undo.setActionName("Стиль «\(style.displayName)»")
        }
        switch style.kind {
        case .paragraph: return applyParagraphStyle(style, properties: properties, sheet: sheet)
        case .character: return applyCharacterStyle(style, properties: properties, sheet: sheet)
        }
    }

    // MARK: - Абзацный стиль

    private func applyParagraphStyle(_ style: DocStyle, properties: DocStyleSheet.Properties, sheet: DocStyleSheet) -> Bool {
        guard let tab else { return false }
        let indexes = paragraphs(in: selectedUnits)
        guard !indexes.isEmpty else { return false }
        // 1. `\sN`: заменить свой код абзаца или вписать после `\pard`.
        var edits: [DocEdit] = []
        let source = tab.text
        for index in indexes {
            guard let paragraph = model.body.paragraphs[safe: index] else { continue }
            if let edit = styleCodeEdit(paragraph, number: style.number, source: source) { edits.append(edit) }
        }
        if !edits.isEmpty, !apply(edits, actionName: "Стиль") { return false }
        // 2. Свойства абзаца, которые задаёт стиль.
        let props = properties.paragraph
        var change = ParaChange()
        change.alignment = props.alignment
        change.left = props.left
        change.right = props.right
        change.firstLine = props.firstLine
        change.spaceBefore = props.spaceBefore
        change.spaceAfter = props.spaceAfter
        change.lineSpacing = (props.lineSpacing, props.lineMultiple)
        guard applyPlan(FormatEdits.paragraph(change, paragraphs: indexes, source: tab.text, model: model)) else { return false }
        // 3. Знаки: шрифт, размер, начертания, цвет — на текст абзацев, если у какого-то прогона они другие.
        guard let first = model.body.paragraphs[safe: indexes[0]], let last = model.body.paragraphs[safe: indexes[indexes.count - 1]] else { return true }
        let span = NSRange(location: first.regionStart, length: max(0, NSMaxRange(last.endRange) - first.regionStart))
        let char = properties.character
        var changes: [(CharChange, (RTFCharProps) -> Bool)] = [
            (.bold(char.bold), { $0.bold != char.bold }),
            (.italic(char.italic), { $0.italic != char.italic }),
            (.underline(char.underline != .none), { ($0.underline != .none) != (char.underline != .none) }),
            (.size(char.halfPoints), { $0.halfPoints != char.halfPoints }),
        ]
        if let font = properties.fontName { changes.append((.font(font), { [model] in model.font($0.font)?.name != font })) }
        if let color = properties.color { changes.append((.color(color), { [model] in model.color($0.color) != color })) }
        for (colorless, differs) in changes {
            guard paragraphsText(indexes).contains(where: differs) else { continue }
            guard applyPlan(FormatEdits.character(colorless, span: span, source: tab.text, model: model)) else { return false }
        }
        return true
    }

    /// Свойства знаков всех видимых прогонов абзацев.
    private func paragraphsText(_ indexes: [Int]) -> [RTFCharProps] {
        indexes.compactMap { model.body.paragraphs[safe: $0] }.flatMap(\.runs).filter { FormatEdits.isTarget($0.kind) }.map(\.props)
    }

    /// Правка кода `\sN` абзаца: замена существующего или вставка после `\pard`; `nil` — уже такой.
    private func styleCodeEdit(_ paragraph: RTFParagraph, number: Int, source: NSString) -> DocEdit? {
        if let pard = paragraph.pard {
            let end = min(paragraph.contentStart, source.length)
            let start = NSMaxRange(pard)
            if end > start {
                for token in RTFLexer.tokens(source, in: NSRange(location: start, length: end - start)) where token.kind == .word && token.name == "s" {
                    if token.number == number { return nil }
                    return DocEdit(range: token.wordRange, text: "\\s\(number)" + (token.hasDelimiter ? "" : " "))
                }
            }
            return DocEdit(range: NSRange(location: NSMaxRange(pard), length: 0), text: "\\s\(number) ")
        }
        guard paragraph.props.style != number else { return nil }
        return DocEdit(range: NSRange(location: paragraph.regionStart, length: 0), text: "\\s\(number) ")
    }

    // MARK: - Знаковый стиль

    private func applyCharacterStyle(_ style: DocStyle, properties: DocStyleSheet.Properties, sheet: DocStyleSheet) -> Bool {
        guard let tab else { return false }
        let units = selectedUnits
        guard units.length > 0 else { return false }
        let start = rendering.map.sourceLocation(beforeUnit: units.location)
        let end = rendering.map.sourceLocation(beforeUnit: min(NSMaxRange(units), rendering.map.count))
        let words = sheet.resolvedWords(style).joined()
        let change = CharChange.characterStyle(number: style.number, words: words, props: properties.character)
        return applyPlan(FormatEdits.character(change, span: NSRange(location: start, length: max(0, end - start)), source: tab.text, model: model))
    }

    private func applyPlan(_ result: Result<FormatPlan, FormatFailure>) -> Bool {
        switch result {
        case .failure(let failure):
            show(notice: "Нельзя без потерь: \(failure.reason.lowercasedFirst). Изменить это можно в режиме «Код»")
            Feedback.beep()
            return false
        case .success(let plan):
            guard !plan.edits.isEmpty else { return true }
            guard let edits = FormatCheck.merged(plan.edits) else { return false }
            return apply(edits.map { DocEdit(range: $0.range, text: $0.string) }, actionName: "Стиль")
        }
    }
}
