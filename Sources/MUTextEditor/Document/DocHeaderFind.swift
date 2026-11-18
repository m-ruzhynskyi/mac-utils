import AppKit

/// Поиск и замена в колонтитулах «Документа»: колонтитулы рисуются отдельно от страниц и в `storage` не входят, поэтому у каждой
/// истории колонтитула (раздел, где она записана, и вид) — свой показанный текст. Совпадения — единицы этого текста.
/// Связанные колонтитулы («Как в предыдущем») — один исходник на несколько разделов: история ищется один раз, по первой странице,
/// где она показана.
package struct HeaderFindTarget {
    /// Раздел, в котором колонтитул записан (не тот, где показан).
    package let section: Int
    package let kind: RTFHeaderKind
    /// Индекс первой страницы, где он показан (на ней открывается правка).
    package let page: Int
    package let string: NSString
    package let map: DocSourceMap
    package var isHeader: Bool { kind.isHeader }
}

package struct HeaderFindMatch: Equatable {
    package let section: Int
    package let kind: RTFHeaderKind
    package let page: Int
    /// Показанные единицы совпадения в тексте колонтитула.
    package let units: NSRange
    package var isHeader: Bool { kind.isHeader }
}

extension DocumentController {
    /// Истории колонтитулов, показанные на страницах: по одной на источник, в порядке первой страницы (верхний — до нижнего).
    package func headerFindTargets() -> [HeaderFindTarget] {
        var seen = Set<String>()
        var targets: [HeaderFindTarget] = []
        let total = pagesView.pages.count
        for (index, page) in pagesView.pages.enumerated() where page.section < model.sections.count {
            let sectionTotal = pagesView.pages.filter { $0.section == page.section }.count
            for header in [true, false] {
                guard let kind = headerKind(for: page, header: header),
                      let section = (0...page.section).reversed().first(where: { model.sections[$0].headers[kind] != nil }),
                      let story = model.sections[section].headers[kind]?.story,
                      seen.insert("\(section)-\(kind.rawValue)").inserted else { continue }
                let rendering = renderer.renderMargins(story, model: model, textWidth: DocPageView.bodyRect(page.props).width) { field in
                    switch field {
                    case .page: return "\(page.number)"
                    case .numPages: return "\(total)"
                    case .sectionPages: return "\(sectionTotal)"
                    case .other: return nil
                    }
                }
                targets.append(HeaderFindTarget(section: section, kind: kind, page: index, string: rendering.string.string as NSString, map: rendering.map))
            }
        }
        return targets
    }

    /// Совпадения в колонтитулах (в порядке страниц). Ошибка выражения — наружу, как у поиска по телу.
    package func headerFindMatches(query: String, options: SearchOptions) throws -> [HeaderFindMatch] {
        guard !query.isEmpty else { return [] }
        var all: [HeaderFindMatch] = []
        for target in headerFindTargets() where target.string.length > 0 {
            var options = options
            options.inSelection = false
            let found = try TextSearch.find(query, in: target.string, options: options, scope: nil)
            all += found.ranges.map { HeaderFindMatch(section: target.section, kind: target.kind, page: target.page, units: $0) }
        }
        return all
    }
}

// MARK: - Общий список, переход, замена

/// Место в порядке страниц: страница, полоса (верхний колонтитул — до тела, нижний — после) и смещение внутри полосы.
package struct DocFindKey: Comparable, Equatable {
    package var page: Int
    package var band: Int
    package var offset: Int

    package static func < (a: DocFindKey, b: DocFindKey) -> Bool { (a.page, a.band, a.offset) < (b.page, b.band, b.offset) }
}

package enum DocFindItem: Equatable {
    /// Индекс в списке совпадений тела.
    case body(Int)
    /// Индекс в списке совпадений колонтитулов.
    case header(Int)
}

extension DocumentController {
    /// Индекс страницы, на которой стоит показанная единица тела.
    package func pageIndex(ofUnit unit: Int) -> Int {
        guard storage.length > 0 else { return 0 }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(max(unit, 0), storage.length - 1))
        guard let container = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return 0 }
        return pagesView.pages.firstIndex { $0.container === container } ?? 0
    }

    package func findKey(body range: NSRange) -> DocFindKey { DocFindKey(page: pageIndex(ofUnit: range.location), band: 1, offset: range.location) }

    package func findKey(header match: HeaderFindMatch, offset: Int? = nil) -> DocFindKey {
        DocFindKey(page: match.page, band: match.isHeader ? 0 : 2, offset: offset ?? match.units.location)
    }

    /// Совпадения тела и колонтитулов одним списком в порядке страниц.
    package func orderedFindItems(body: [NSRange], headers: [HeaderFindMatch]) -> [(item: DocFindItem, key: DocFindKey)] {
        var all: [(item: DocFindItem, key: DocFindKey)] = []
        all.reserveCapacity(body.count + headers.count)
        for (index, range) in body.enumerated() { all.append((.body(index), findKey(body: range))) }
        for (index, match) in headers.enumerated() { all.append((.header(index), findKey(header: match))) }
        return all.enumerated().sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }.map(\.element)
    }

    /// Правка колонтитула, в которой сейчас курсор (если открыта).
    package var openHeaderSession: DocHeaderSession? { DocFormatter.existing(for: self)?.headerSession }

    /// Закрыть правку колонтитула (поиск переходит в тело).
    package func closeHeaderEditing() { DocFormatter.existing(for: self)?.endHeaderEditing() }

    /// Перейти к совпадению в колонтитуле: открыть его правку на странице (как двойной щелчок по полю) и выделить найденное.
    /// Фокус остаётся там, где был (поле поиска): иначе следующий ↩ ушёл бы в колонтитул.
    package func revealHeaderMatch(_ match: HeaderFindMatch) {
        guard pagesView.pages.indices.contains(match.page) else { return }
        let page = pagesView.pages[match.page]
        let formatter = DocFormatter.of(self)
        let responder = page.window?.firstResponder
        scrollView.contentView.scrollToVisible(page.convert(page.bounds, to: pagesView))
        if let session = formatter.headerSession, session.section == match.section, session.kind == match.kind {
            // та же история уже открыта
        } else {
            formatter.beginHeaderEditing(page: page, header: match.isHeader)
        }
        guard let session = formatter.headerSession, session.section == match.section, session.kind == match.kind else { return }
        let length = session.storage.length
        let location = min(match.units.location, length)
        session.textView.setSelectedRange(NSRange(location: location, length: min(match.units.length, length - location)))
        if let responder, !(responder is DocTextView), !(responder is DocHeaderTextView) { page.window?.makeFirstResponder(responder) }
    }

    /// Правки исходника для замен в колонтитулах (источник тот же, что у тела): совпадения, которые нельзя править, пропускаются.
    func headerReplaceEdits(_ replacements: [(match: HeaderFindMatch, string: String)]) -> (edits: [DocEdit], done: Int, skipped: Int) {
        guard let tab else { return ([], 0, replacements.count) }
        let targets = Dictionary(headerFindTargets().map { ("\($0.section)-\($0.kind.rawValue)", $0) }, uniquingKeysWith: { first, _ in first })
        var edits: [DocEdit] = []
        var done = 0, skipped = 0
        for (match, string) in replacements {
            guard let target = targets["\(match.section)-\(match.kind.rawValue)"],
                  let story = model.story(.header(section: match.section, kind: match.kind)) else { skipped += 1; continue }
            let result = DocTextEditor.replace(match.units, with: string, model: model, story: story, map: target.map, source: tab.text)
            if result.refusal != nil || result.edits.isEmpty { skipped += 1; continue }
            edits += result.edits
            done += 1
        }
        return (edits, done, skipped)
    }
}
