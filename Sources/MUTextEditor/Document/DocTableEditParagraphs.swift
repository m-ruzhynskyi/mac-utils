import Foundation

/// Пустой абзац у таблицы (хвост E-1), как в Word: Delete в пустом абзаце перед таблицей и ⌫ в пустом абзаце после неё
/// удаляют этот абзац. Удаляется его `\par` (или вся его область, если так не меняются соседи); правка принимается,
/// только если текст и свойства остальных абзацев остаются прежними.
extension DocTableEdit {
    package struct ParagraphRemoval {
        package var edits: [DocEdit]
        /// Показанная единица, которая исчезает (конец пустого абзаца).
        package var removedUnit: Int
        /// Курсор после правки (место исходника) и где он в показанном тексте до правки.
        package var caretSource: Int
        package var caretUnit: Int
    }

    package static func emptyParagraphNearTable(_ units: NSRange, model: RTFDocumentModel, map: DocSourceMap, source: NSString) -> ParagraphRemoval? {
        guard units.length == 1, units.location < map.count else { return nil }
        let story = model.body
        let piece = map.range(at: units.location)
        guard let index = story.paragraphs.firstIndex(where: { $0.endRange == piece && $0.endRange.length > 0 }) else { return nil }
        let paragraphs = story.paragraphs
        func empty(_ paragraph: RTFParagraph) -> Bool { paragraph.cell == nil && !paragraph.props.inTable && paragraph.runs.allSatisfy { $0.text.isEmpty } }
        switch map.kind(at: units.location) {
        case .paragraphEnd:
            // Delete в пустом абзаце прямо перед таблицей.
            guard empty(paragraphs[index]), paragraphs[safe: index + 1]?.cell != nil else { return nil }
            let paragraph = paragraphs[index]
            let region = NSRange(location: paragraph.regionStart, length: NSMaxRange(paragraph.endRange) - paragraph.regionStart)
            for candidate in [paragraph.endRange, region] {
                if let edits = unchanged(removing: candidate, after: index, model: model, source: source) {
                    return ParagraphRemoval(edits: edits, removedUnit: units.location, caretSource: candidate.location, caretUnit: units.location + 1)
                }
            }
        case .cellEnd:
            // ⌫ в начале пустого абзаца сразу после таблицы (не последнего в документе).
            guard let cell = paragraphs[index].cell, let table = story.tables[safe: cell.table], cell.row == table.rows.count - 1,
                  cell.cell == table.rows[cell.row].cells.count - 1, let next = paragraphs[safe: index + 1], empty(next),
                  next.end == .paragraph, index + 2 < paragraphs.count, units.location + 1 < map.count,
                  map.range(at: units.location + 1) == next.endRange,
                  let edits = unchanged(removing: next.endRange, after: index + 1, model: model, source: source) else { return nil }
            return ParagraphRemoval(edits: edits, removedUnit: units.location + 1, caretSource: next.endRange.location, caretUnit: units.location + 2)
        default:
            break
        }
        return nil
    }

    /// Удаление куска: скобки сбалансированы, а абзацы после `index` (текст, свойства абзаца и знаков) — те же.
    private static func unchanged(removing range: NSRange, after index: Int, model: RTFDocumentModel, source: NSString) -> [DocEdit]? {
        let text = source.substring(with: range) as NSString
        guard DollarMarks.unbalancedBraces(in: text) == 0 else { return nil }
        let edit = DocEdit(range: range, text: DocTextEditor.delimiterAfterRemoval(range, source: source) ? " " : "")
        let new = NSMutableString(string: source)
        new.replaceCharacters(in: range, with: edit.text)
        let after = RTFReader.read(new).body.paragraphs
        let before = model.body.paragraphs
        guard after.count == before.count - 1 else { return nil }
        for (old, now) in zip(before[(index + 1)...], after[index...]) {
            guard old.props == now.props, old.end == now.end, old.runs.map(\.text) == now.runs.map(\.text),
                  old.runs.map(\.props) == now.runs.map(\.props) else { return nil }
        }
        return [edit]
    }
}
