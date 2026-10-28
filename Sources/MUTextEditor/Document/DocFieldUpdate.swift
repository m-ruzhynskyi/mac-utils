import Foundation

/// «Обновить поля» (E-4, F9 в Word): результат `{\fldrslt …}` полей PAGE, NUMPAGES и SECTIONPAGES переписывается
/// числами нашей раскладки. Меняется только текст результата (коды вокруг него остаются), и только там, где число
/// другое, — остальные байты те же. PAGE в колонтитуле не трогается: на каждой странице он свой, одного верного
/// результата у него нет (Word тоже пишет туда что придётся).
package enum DocFieldUpdate {
    package struct Values {
        /// Номер страницы места исходника основного текста (1…), `nil` — ещё не разложено.
        package var page: (Int) -> Int?
        package var total: Int
        /// Страниц в разделе.
        package var sectionPages: (Int) -> Int?
    }

    package struct Result: Equatable {
        package var edits: [DocEdit] = []
        /// Полей с вычисляемым результатом и сколько из них переписано.
        package var fields = 0
        package var updated = 0
    }

    package static func edits(model: RTFDocumentModel, source: NSString, values: Values) -> Result {
        var result = Result()
        var stories: [(story: RTFStory, header: Bool, section: Int?)] = [(model.body, false, nil)]
        for (index, section) in model.sections.enumerated() {
            for kind in RTFHeaderKind.allCases {
                if let header = section.headers[kind] { stories.append((header.story, true, index)) }
            }
        }
        for entry in stories {
            for paragraph in entry.story.paragraphs {
                for piece in pieces(paragraph) {
                    result.fields += 1
                    let wanted: Int?
                    switch piece.kind {
                    case .page: wanted = entry.header ? nil : piece.runs[0].map.first.flatMap { values.page($0.location) }
                    case .numPages: wanted = values.total
                    case .sectionPages: wanted = values.sectionPages(entry.section ?? paragraph.section)
                    case .other: wanted = nil
                    }
                    guard let wanted, piece.text != "\(wanted)" else { continue }
                    // Число — на место текста первого прогона результата (его коды), текст остальных прогонов вырезается.
                    let first = piece.runs[0]
                    var text = DocTextEditor.encode("\(wanted)", props: first.props, uc: first.uc, model: model)
                    let range = span(first.map)
                    if DocTextEditor.needsDelimiter(before: range.location, source: source) { text = " " + text }
                    result.edits.append(DocEdit(range: range, text: text))
                    for run in piece.runs.dropFirst() {
                        for unit in merged(run.map) {
                            result.edits.append(DocEdit(range: unit, text: DocTextEditor.delimiterAfterRemoval(unit, source: source) ? " " : ""))
                        }
                    }
                    result.updated += 1
                }
            }
        }
        return result
    }

    /// Результаты вычисляемых полей абзаца (`\fldrslt`): вид, весь текст и его прогоны (формат внутри результата
    /// бывает разным). Номер `\chpgn` без поля не в счёт.
    package static func pieces(_ paragraph: RTFParagraph) -> [(kind: RTFFieldKind, text: String, runs: [RTFRun])] {
        var result: [(kind: RTFFieldKind, text: String, runs: [RTFRun])] = []
        var last: Int?
        for run in paragraph.runs {
            guard case .field(let kind) = run.kind, let field = run.field, !run.map.isEmpty else {
                last = nil
                continue
            }
            if last == field, !result.isEmpty {
                result[result.count - 1].text += run.text
                result[result.count - 1].runs.append(run)
            } else {
                result.append((kind, run.text, [run]))
            }
            last = field
        }
        return result
    }

    private static func span(_ map: [NSRange]) -> NSRange {
        guard let first = map.first, let last = map.last else { return NSRange(location: 0, length: 0) }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    /// Куски исходника единиц прогона, соседние — вместе.
    private static func merged(_ map: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in map where range.length > 0 {
            if let previous = result.last, NSMaxRange(previous) >= range.location {
                result[result.count - 1] = NSUnionRange(previous, range)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
