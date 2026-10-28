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

    /// Применить правила ко всем страницам; `true` — какая-то страница стала короче (раскладка изменилась).
    @discardableResult
    package static func apply(_ pagesView: DocPagesView, layoutManager: NSLayoutManager) -> Bool {
        guard let storage = layoutManager.textStorage, storage.length > 0 else { return false }
        var changed = false
        var index = 0
        while index + 1 < pagesView.pages.count {
            let page = pagesView.pages[index], next = pagesView.pages[index + 1]
            layoutManager.ensureLayout(for: next.container)
            if let limit = breakTop(page: page.container, next: next.container, layoutManager: layoutManager, storage: storage),
               limit < (page.breakLimit ?? .greatestFiniteMagnitude) - 0.5 {
                page.breakLimit = limit
                layoutManager.ensureLayout(for: page.container)
                changed = true
            }
            index += 1
        }
        return changed
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
                    if last.lines.count - 1 >= 2 { return last.lines[last.lines.count - 1].minY }
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
        return top > 0.5 ? top : nil
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
