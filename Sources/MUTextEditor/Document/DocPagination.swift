import AppKit

/// Разрыв страниц по правилам Word поверх жадной раскладки TextKit. Страницы проходятся по порядку; где правило велит
/// начать следующую страницу раньше, высота контейнера страницы уменьшается до верха переносимого куска
/// (`DocPageView.breakLimit`) и раскладка дальше идёт заново:
/// - `\widctlpar` — у разорванного абзаца не меньше двух строк на каждой странице (иначе переносится строка или абзац);
/// - `\keep` — абзац целиком на одной странице;
/// - `\keepn` — абзац (строка таблицы — если все её абзацы с `\keepn`) на одной странице со следующим; цепочка таких
///   переносится целиком, если не занимает всю страницу.
/// После жёсткого разрыва («\f») правила не действуют: разрыв уже там, где задан.
@MainActor
package enum DocPagination {
    /// Запас к пределу: предыдущий кусок кончается ровно там, где начинается переносимый, и без запаса он не поместился бы из-за округления.
    private static let slack: CGFloat = 1.5
    /// Кусок раскладки в порядке текста: абзац вне таблицы или строка таблицы.
    private struct Unit {
        package var key: String
        /// Верх первой строки куска на странице (координаты контейнера) и число его строк на ней.
        package var top: CGFloat
        package var lines: [NSRect]
        package var keepNext: Bool
        package var keepTogether: Bool
        package var widowControl: Bool
        /// Абзац вне таблицы: его полный диапазон в тексте.
        package var paragraph: NSRange?
    }

    /// Применить правила ко всем страницам; `true` — раскладка изменилась (нужен ещё проход).
    /// Страницы проходятся по порядку, и всё по странице считается заново по естественной раскладке: предел, поставленный
    /// при другом составе предыдущих страниц, устаревает (раскладка идёт дальше от разрывов) и унёс бы лишнее.
    /// Страницы, где таблицы занимают заметную часть, не трогаются: высоты строк таблиц у нас пока неточные, и правило, верное само по себе,
    /// переносило бы абзац из-за чужой ошибки (f030, f069, f176 по гейту).
    @discardableResult
    package static func apply(_ pagesView: DocPagesView, layoutManager: NSLayoutManager) -> Bool {
        guard let storage = layoutManager.textStorage, storage.length > 0 else { return false }
        // Проход уже сделан для этого текста и этого числа страниц: перераскладка, которую он сам вызвал, ничего не меняет.
        if pagesView.paginationDone == DocPagesView.PaginationKey(stamp: pagesView.paginationStamp, length: storage.length, pages: pagesView.pages.count) {
            return false
        }
        var changed = false
        var index = 0
        while index < pagesView.pages.count {
            let page = pagesView.pages[index]
            let old = page.breakLimit
            page.breakLimit = nil
            // Отступ «перед» у верха страницы, начавшейся сама: не у первой и не у страницы с таблицей.
            if let container = page.container as? DocPageContainer {
                layoutManager.ensureLayout(for: container)
                var drops = index > 0 && !mostlyTable(container, layoutManager: layoutManager)
                if container.dropsTopSpace != drops {
                    container.dropsTopSpace = drops
                    relayout(container, layoutManager: layoutManager)
                    if drops, mostlyTable(container, layoutManager: layoutManager) {
                        // Страница втянула таблицы — отступ не трогаем.
                        drops = false
                        container.dropsTopSpace = false
                        relayout(container, layoutManager: layoutManager)
                    }
                    changed = true
                }
            }
            if index + 1 < pagesView.pages.count {
                let next = pagesView.pages[index + 1]
                next.breakLimit = nil
                layoutManager.ensureLayout(for: next.container)
                var limit: CGFloat?
                if !mostlyTable(page.container, layoutManager: layoutManager) {
                    limit = breakTop(page: page.container, next: next.container, layoutManager: layoutManager, storage: storage)
                }
                if let limit {
                    page.breakLimit = limit
                    layoutManager.ensureLayout(for: page.container)
                }
                if (old == nil) != (limit == nil) || abs((old ?? 0) - (limit ?? 0)) > 0.5 { changed = true }
            }
            index += 1
        }
        if let last = layoutManager.textContainers.last { layoutManager.ensureLayout(for: last) }
        // Страховка от бесконечного прохода: страница то втягивает таблицу, то нет.
        if changed {
            pagesView.paginationRounds += 1
            if pagesView.paginationRounds > 6 { changed = false }
        } else {
            pagesView.paginationRounds = 0
        }
        if !changed {
            pagesView.paginationDone = DocPagesView.PaginationKey(stamp: pagesView.paginationStamp, length: storage.length, pages: pagesView.pages.count)
        }
        return changed
    }

    private static func relayout(_ container: NSTextContainer, layoutManager: NSLayoutManager) {
        let glyphs = layoutManager.glyphRange(for: container)
        if glyphs.length > 0 {
            layoutManager.invalidateLayout(forCharacterRange: layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), actualCharacterRange: nil)
        }
        layoutManager.ensureLayout(for: container)
    }

    /// Доля строк таблиц на странице, выше которой правила не действуют.
    private static let tableShareLimit = 0.25

    /// Таблицы занимают заметную часть страницы.
    private static func mostlyTable(_ container: NSTextContainer, layoutManager: NSLayoutManager) -> Bool {
        guard let storage = layoutManager.textStorage else { return false }
        let glyphs = layoutManager.glyphRange(for: container)
        guard glyphs.length > 0 else { return false }
        var table = 0, all = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
            let character = layoutManager.characterIndexForGlyph(at: lineGlyphs.location)
            guard character < storage.length else { return }
            all += 1
            if let style = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle,
               style.textBlocks.contains(where: { $0 is NSTextTableBlock }) { table += 1 }
        }
        return all > 0 && Double(table) / Double(all) > tableShareLimit
    }

    /// Куда перенести начало следующей страницы (верх куска на этой), если правило Word этого требует.
    private static func breakTop(page: NSTextContainer, next: NSTextContainer, layoutManager: NSLayoutManager,
                                 storage: NSTextStorage) -> CGFloat? {
        let glyphs = layoutManager.glyphRange(for: page), nextGlyphs = layoutManager.glyphRange(for: next)
        guard glyphs.length > 0, nextGlyphs.length > 0 else { return nil }
        let text = storage.string as NSString
        let lastCharacter = layoutManager.characterIndexForGlyph(at: NSMaxRange(glyphs) - 1)
        // Жёсткий разрыв в конце страницы — Word тоже переносит ровно там.
        if text.character(at: lastCharacter) == 0x0C { return nil }
        let units = self.units(glyphs, layoutManager: layoutManager, storage: storage)
        guard let last = units.last, let following = self.units(nextGlyphs, layoutManager: layoutManager, storage: storage, limit: 1).first else {
            return nil
        }
        // С какого куска начнётся следующая страница: по умолчанию — со следующего за последним.
        var moved = units.count
        if last.key == following.key, let paragraph = last.paragraph {
            // Абзац разорван между страницами.
            let remaining = lines(of: paragraph, in: nextGlyphs, layoutManager: layoutManager)
            let ends = NSMaxRange(paragraph) <= NSMaxRange(layoutManager.characterRange(forGlyphRange: nextGlyphs, actualGlyphRange: nil))
            if last.keepTogether {
                moved = units.count - 1
            } else if last.widowControl {
                if last.lines.count < 2 {
                    moved = units.count - 1
                } else if ends, remaining < 2 {
                    // Висячая последняя строка: переносим ещё одну, если здесь останется две; иначе — весь абзац.
                    if last.lines.count - 1 >= 2 { return last.lines[last.lines.count - 1].minY + slack }
                    moved = units.count - 1
                }
            }
            if moved == units.count { return nil }
        }
        // Цепочка «не отрывать от следующего» перед первым переносимым куском.
        while moved > 0, units[moved - 1].keepNext { moved -= 1 }
        // Переносить нечего или вся страница — одна цепочка: Word такой разрыв не делает.
        guard moved > 0, moved < units.count else { return nil }
        let top = units[moved].top
        return top > 0.5 ? top + slack : nil
    }

    /// Куски страницы по порядку текста с их строками.
    private static func units(_ glyphs: NSRange, layoutManager: NSLayoutManager, storage: NSTextStorage, limit: Int = .max) -> [Unit] {
        let text = storage.string as NSString
        var result: [Unit] = []
        var rowKeep: [String: Bool] = [:]
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, lineGlyphs, stop in
            let character = layoutManager.characterIndexForGlyph(at: lineGlyphs.location)
            guard character < storage.length else { return }
            let props = (storage.attribute(.docPara, at: character, effectiveRange: nil) as? DocParaInfo)?.props
            let style = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle
            let key: String
            var paragraph: NSRange?
            if let block = style?.textBlocks.last as? NSTextTableBlock {
                key = "T\(ObjectIdentifier(block.table).hashValue)-\(block.startingRow)"
                rowKeep[key] = (rowKeep[key] ?? true) && (props?.keepNext ?? false)
            } else {
                let range = text.paragraphRange(for: NSRange(location: character, length: 0))
                key = "P\(range.location)"
                paragraph = range
            }
            if let index = result.lastIndex(where: { $0.key == key }), index == result.count - 1 || paragraph == nil {
                result[index].top = min(result[index].top, rect.minY)
                result[index].lines.append(rect)
                if paragraph == nil { result[index].keepNext = rowKeep[key] ?? false }
                return
            }
            if result.count >= limit {
                stop.pointee = true
                return
            }
            result.append(Unit(key: key, top: rect.minY, lines: [rect], keepNext: paragraph == nil ? (rowKeep[key] ?? false) : (props?.keepNext ?? false),
                               keepTogether: props?.keepTogether ?? false, widowControl: props?.widowControl ?? false, paragraph: paragraph))
        }
        return result
    }

    /// Сколько строк абзаца в диапазоне глифов (на следующей странице).
    private static func lines(of paragraph: NSRange, in glyphs: NSRange, layoutManager: NSLayoutManager) -> Int {
        let own = NSIntersectionRange(layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil), glyphs)
        guard own.length > 0 else { return 0 }
        var count = 0
        layoutManager.enumerateLineFragments(forGlyphRange: own) { _, _, _, _, _ in count += 1 }
        return count
    }
}
