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
