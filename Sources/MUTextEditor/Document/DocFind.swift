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

    /// Перейти к совпадению: выделить и показать на странице (с переходом на нужную).
    package func revealFind(_ index: Int) {
        guard findMatches.indices.contains(index) else { return }
        let range = findMatches[index]
        guard let view = textView(forUnit: range.location) else { return }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(range)
        reveal(range)
    }

    /// «Заменить все»: каждое совпадение — своя точечная правка исходника, все вместе — один шаг отмены. Совпадения, которые «Документ» не правит
    /// (номер списка, граница ячейки, рисунок), пропускаются и считаются. Строки без перевода строки и непересекающиеся правки применяются
    /// одним вызовом; иначе — по одной с конца, в одной группе отмены.
    package func replaceAll(_ ranges: [NSRange], with strings: [String]) -> (done: Int, skipped: Int) {
        guard let tab, ranges.count == strings.count, !ranges.isEmpty else { return (0, 0) }
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
        guard !applicable.isEmpty else { return (0, skipped) }
        let sorted = edits.sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
        let disjoint = zip(sorted, sorted.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location }
        if disjoint, !strings.contains(where: { $0.contains(where: \.isNewline) }) {
            if apply(sorted, actionName: "Заменить все", select: { _ in NSRange(location: 0, length: 0) }) { return (applicable.count, skipped) }
        }
        // Запасной путь: с конца к началу показанные единицы слева остаются верными.
        tab.undo.beginUndoGrouping()
        var done = 0
        for (range, string) in applicable.reversed() {
            if perform(replacing: range, with: string) { done += 1 } else { skipped += 1 }
        }
        tab.undo.endUndoGrouping()
        tab.undo.setActionName("Заменить все")
        return (done, skipped)
    }

    private func hasProtectedUnit(_ range: NSRange) -> Bool {
        (range.location..<min(NSMaxRange(range), rendering.map.count)).contains { [.listText, .object, .cellEnd, .sectionEnd, .sectionBreak].contains(rendering.map.kind(at: $0)) }
    }
}
