import AppKit
import MUCore
import MUDesign

/// Поиск и замена в «Документе» (S2): совпадения — показанные единицы страниц (поиск по видимому тексту, не по кодам RTF), подсветка —
/// временными атрибутами (исходник и вид текста не меняются), замена — точечные правки исходника.
extension DocumentController {
    static let findColor = NSColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 0.55)
    static let findCurrentColor = NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 0.7)

    /// Показать совпадения: все — жёлтым, текущее — оранжевым. Пустой список снимает подсветку.
    package func setFindMatches(_ ranges: [NSRange], current: Int?) {
        clearFindHighlight()
        findMatches = ranges
        findCurrent = current
        paintFind()
    }

    func clearFindHighlight() {
        let full = NSRange(location: 0, length: storage.length)
        for range in findMatches { layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(range, full)) }
    }

    /// Перекрасить совпадения (после правки текста и после подсветки `$`, которая снимает фон со всего текста).
    func paintFind() {
        let full = NSRange(location: 0, length: storage.length)
        for (index, range) in findMatches.enumerated() {
            let clipped = NSIntersectionRange(range, full)
            guard clipped.length > 0 else { continue }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: index == findCurrent ? Self.findCurrentColor : Self.findColor, forCharacterRange: clipped)
        }
    }

    /// Перейти к совпадению: выделить и показать на странице (с переходом на нужную). Фокус переходит на страницу совпадения, только если
    /// он уже на странице (⌘G из текста); из поля поиска — остаётся в поле, как в «Коде»: иначе следующий ↩ в поле вставил бы абзац в документ.
    package func revealFind(_ index: Int) {
        guard findMatches.indices.contains(index) else { return }
        let range = findMatches[index]
        guard let view = textView(forUnit: range.location) else { return }
        if let window = view.window, let focused = window.firstResponder as? DocTextView, focused !== view,
           textViews.contains(where: { $0 === focused }) {
            window.makeFirstResponder(view)
        }
        view.setSelectedRange(range)
        reveal(range)
    }

    /// «Заменить все»: каждое совпадение — своя точечная правка исходника, все вместе (тело и колонтитулы) — один шаг отмены. Совпадения,
    /// которые «Документ» не правит (номер списка, граница ячейки, рисунок), пропускаются и считаются. Строки без перевода строки и
    /// непересекающиеся правки применяются одним вызовом; иначе — по одной с конца, в одной группе отмены (колонтитулы — первыми).
    package func replaceAll(_ ranges: [NSRange], with strings: [String],
                            headers: [(match: HeaderFindMatch, string: String)] = []) -> (done: Int, skipped: Int, headerDone: Int, headerSkipped: Int) {
        guard let tab, ranges.count == strings.count, !(ranges.isEmpty && headers.isEmpty) else { return (0, 0, 0, 0) }
        typingBurst = nil
        var edits: [DocEdit] = []
        var applicable: [(NSRange, String)] = []
        var skipped = 0
        for (range, string) in zip(ranges, strings) {
            let result = DocTextEditor.replace(range, with: string, model: model, map: rendering.map, source: tab.text)
            if result.refusal != nil || result.edits.isEmpty || hasProtectedUnit(range) {
                skipped += 1
                continue
            }
            edits.append(contentsOf: result.edits)
            applicable.append((range, string))
        }
        let headerPlan = headerReplaceEdits(headers)
        let headerEdits = headerPlan.edits
        guard !applicable.isEmpty || !headerEdits.isEmpty else { return (0, skipped, 0, headerPlan.skipped) }
        let combined = edits + headerEdits
        let sorted = combined.sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
        let disjoint = zip(sorted, sorted.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location }
        let noNewlines = !strings.contains(where: { $0.contains(where: \.isNewline) }) && !headers.contains(where: { $0.string.contains(where: \.isNewline) })
        if disjoint, noNewlines {
            if apply(sorted, actionName: "Заменить все", select: { _ in NSRange(location: 0, length: 0) }) {
                return (applicable.count, skipped, headerPlan.done, headerPlan.skipped)
            }
        }
        // Запасной путь: колонтитулы одной правкой, затем тело с конца к началу (показанные единицы слева остаются верными).
        tab.undo.beginUndoGrouping()
        var headerDone = headerPlan.done, headerSkipped = headerPlan.skipped
        if !headerEdits.isEmpty, !apply(headerEdits, actionName: "Заменить все") {
            headerSkipped += headerDone
            headerDone = 0
        }
        var done = 0
        for (range, string) in applicable.reversed() {
            if perform(replacing: range, with: string) { done += 1 } else { skipped += 1 }
        }
        tab.undo.endUndoGrouping()
        tab.undo.setActionName("Заменить все")
        return (done, skipped, headerDone, headerSkipped)
    }

    private func hasProtectedUnit(_ range: NSRange) -> Bool {
        (range.location..<min(NSMaxRange(range), rendering.map.count)).contains { [.listText, .object, .cellEnd, .sectionEnd, .sectionBreak].contains(rendering.map.kind(at: $0)) }
    }
}
