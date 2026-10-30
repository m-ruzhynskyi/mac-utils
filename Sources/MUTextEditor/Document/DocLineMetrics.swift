import AppKit
import CoreText

/// Высота строк как у Word. TextKit округляет ascent и descent шрифта до целых пунктов и добавляет leading (TNR 12 —
/// 14,51 pt, у Word 13,8), Word берёт метрики без округления, как GDI: ascent и descent из OS/2 (`usWinAscent`,
/// `usWinDescent`) плюс внешний интерлиньяж из `hhea`. Одинарный интервал — наибольшие ascent + интерлиньяж и descent
/// шрифтов строки; `\sl` — «минимум», «точно» (< 0) или множитель (`\slmult1`, N/240 одинарного); лишнее — над текстом.
/// `\sb`/`\sa` — над первой и под последней строкой абзаца (в ячейках тоже).
package enum DocLineMetrics {
    package struct Font {
        /// Над базовой линией (с внешним интерлиньяжем — он у Word сверху) и под ней, pt.
        package var above: CGFloat
        package var below: CGFloat
    }

    @MainActor private static var cache: [String: Font] = [:]

    @MainActor package static func metrics(_ font: NSFont) -> Font {
        let key = "\(font.fontName)@\(font.pointSize)"
        if let cached = cache[key] { return cached }
        let ct = font as CTFont
        let scale = font.pointSize / CGFloat(max(1, CTFontGetUnitsPerEm(ct)))
        var result = Font(above: font.ascender + max(0, font.leading), below: -font.descender)
        if let os2 = CTFontCopyTable(ct, CTFontTableTag(kCTFontTableOS2), []) as Data?, os2.count >= 78,
           let hhea = CTFontCopyTable(ct, CTFontTableTag(kCTFontTableHhea), []) as Data?, hhea.count >= 10 {
            func u16(_ data: Data, _ offset: Int) -> Int { Int(data[data.startIndex + offset]) << 8 | Int(data[data.startIndex + offset + 1]) }
            func s16(_ data: Data, _ offset: Int) -> Int { let value = u16(data, offset); return value >= 0x8000 ? value - 0x10000 : value }
            let winAscent = u16(os2, 74), winDescent = u16(os2, 76)
            let ascent = s16(hhea, 4), descent = -s16(hhea, 6), gap = s16(hhea, 8)
            if winAscent + winDescent > 0 {
                // Внешний интерлиньяж GDI: то, что `hhea` добавляет сверх win-метрик.
                let external = max(0, gap - ((winAscent + winDescent) - (ascent + descent)))
                result = Font(above: CGFloat(winAscent + external) * scale, below: CGFloat(winDescent) * scale)
            }
        }
        cache[key] = result
        return result
    }

    /// Защита от бесконечной перекладки: typesetter снова и снова кладёт уже уложенные строки (абзац в `NSTextBlock`
    /// на краю последнего контейнера), а раскладка контейнера не завершается. После `loopLimit` возвратов без
    /// завершения такие строки — нулевой высоты: блок помещается, раскладка идёт дальше (вид этого места хуже, но
    /// приложение не висит). Сброс — по завершении раскладки контейнера (`completed`).
    private struct Loop {
        package var furthest = -1
        package var previous = -1
        package var returns = 0
    }

    package static let loopLimit = 1_000
    @MainActor private static var loops: [ObjectIdentifier: Loop] = [:]

    @MainActor package static func completed(_ layoutManager: NSLayoutManager) {
        loops[ObjectIdentifier(layoutManager)] = nil
    }

    /// `true` — строку `glyphs` кладут по кругу.
    @MainActor private static func looping(_ layoutManager: NSLayoutManager, glyphs: NSRange) -> Bool {
        let key = ObjectIdentifier(layoutManager)
        var loop = loops[key] ?? Loop()
        defer { loops[key] = loop }
        if glyphs.location <= loop.previous { loop.returns += 1 }
        loop.previous = glyphs.location
        if glyphs.location > loop.furthest {
            loop.furthest = glyphs.location
            return false
        }
        return loop.returns > loopLimit
    }

    /// Высота строки Word по одинарной: `\sl` — «точно» (< 0), множитель (`\slmult1`) или «минимум».
    private static func lineHeight(single: CGFloat, props: RTFParaProps?) -> CGFloat {
        guard let props, props.lineSpacing != 0 else { return single }
        let value = CGFloat(abs(props.lineSpacing)) / 20
        if props.lineSpacing < 0 { return value }
        if props.lineMultiple { return single * CGFloat(props.lineSpacing) / 240 }
        return max(single, value)
    }

    /// Отступ перед абзацем пропадает у первой строки страницы, начавшейся сама (`DocPageContainer.dropsTopSpace`: не первая страница);
    /// жёсткий разрыв («\f») и `\pagebb` отступ сохраняют.
    @MainActor private static func dropsSpaceBefore(_ layoutManager: NSLayoutManager, container: NSTextContainer, rect: NSRect,
                                                    paragraph: NSRange, style: NSParagraphStyle, props: RTFParaProps?) -> Bool {
        guard rect.minY < 0.5, style.paragraphSpacingBefore > 0, style.textBlocks.isEmpty, props?.pageBreakBefore != true,
              paragraph.location > 0, (container as? DocPageContainer)?.dropsTopSpace == true,
              let storage = layoutManager.textStorage else { return false }
        return (storage.string as NSString).character(at: paragraph.location - 1) != 0x0C
    }

    /// Поправить строку, которую разложил TextKit: высота, базовая линия, интервалы абзаца. `false` — оставить как есть
    /// (строка с рисунком или заглушкой: её высоту задаёт вложение).
    @MainActor package static func adjust(_ layoutManager: NSLayoutManager, rect: inout NSRect, used: inout NSRect, baseline: inout CGFloat,
                                  container: NSTextContainer, glyphs: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage, glyphs.length > 0 else { return false }
        if looping(layoutManager, glyphs: glyphs) {
            rect.size.height = 0
            used.size.height = 0
            baseline = 0
            return true
        }
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.length > 0, NSMaxRange(characters) <= storage.length else { return false }
        // Строка разрыва («\f» перед абзацем, служебный абзац перед таблицей) — нулевой высоты.
        var breakOnly = true
        storage.enumerateAttribute(.docBreakLine, in: characters) { value, _, stop in
            if value == nil { breakOnly = false; stop.pointee = true }
        }
        if breakOnly {
            rect.size.height = 0
            used.size.height = 0
            baseline = 0
            return true
        }
        var above: CGFloat = 0, below: CGFloat = 0
        // Пробелы, табуляции и метка абзаца — запасной вариант: высоту строки задают её символы (как у Word).
        var blankAbove: CGFloat = 0, blankBelow: CGFloat = 0
        let whole = storage.string as NSString
        var object = false
        storage.enumerateAttributes(in: characters) { attributes, range, stop in
            if let attachment = attributes[.attachment] as? NSTextAttachment, !(attachment.attachmentCell is DocFloatingCell) {
                object = true
                stop.pointee = true
                return
            }
            guard var font = attributes[.font] as? NSFont else { return }
            // Над- и подстрочный текст: у Word высоту строки задаёт шрифт полного кегля.
            if let char = (attributes[.docChar] as? DocCharInfo)?.props, char.vertical != .normal {
                font = NSFont(descriptor: font.fontDescriptor, size: CGFloat(char.halfPoints) / 2) ?? font
            }
            let metrics = metrics(font)
            if Self.blank(whole, range) {
                blankAbove = max(blankAbove, metrics.above)
                blankBelow = max(blankBelow, metrics.below)
                return
            }
            above = max(above, metrics.above)
            below = max(below, metrics.below)
        }
        if above + below == 0 { above = blankAbove; below = blankBelow }
        guard !object, above + below > 0 else { return false }
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: characters.location, length: 0))
        let style = storage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle ?? .default
        let props = (storage.attribute(.docPara, at: characters.location, effectiveRange: nil) as? DocParaInfo)?.props
        let height = lineHeight(single: above + below, props: props)
        // Первая строка абзаца — и та, что идёт после его «\f».
        let first = characters.location == paragraph.location
            || (characters.location == paragraph.location + 1 && storage.attribute(.docBreakLine, at: paragraph.location, effectiveRange: nil) != nil)
        let last = NSMaxRange(characters) >= NSMaxRange(paragraph)
        // Word не отступает «перед» абзацем в начале страницы, если страница началась сама (не жёстким разрывом, не `\pagebb`)
        // и это не первая страница: иначе каждая такая страница сдвинута вниз на отступ.
        var before = first && !Self.dropsSpaceBefore(layoutManager, container: container, rect: rect, paragraph: paragraph, style: style, props: props)
            ? style.paragraphSpacingBefore : 0
        // Между абзацами Word оставляет большее из «после» предыдущего и «перед» следующего, а не сумму (предыдущая строка уже несёт своё «после»).
        if before > 0, first, paragraph.location > 0, style.textBlocks.isEmpty {
            let previous = storage.attribute(.paragraphStyle, at: paragraph.location - 1, effectiveRange: nil) as? NSParagraphStyle
            if let previous, previous.textBlocks.isEmpty { before = max(0, before - previous.paragraphSpacing) }
        }
        let after = last ? style.paragraphSpacing : 0
        rect.size.height = before + height + after
        used.origin.y = rect.minY + before
        used.size.height = height
        baseline = before + height - below
        // `\slmult`: добавок множителя — под текстом, базовая линия на ascent × min(m, 1) от верха строки (как у Word).
        if let props, props.lineSpacing > 0, props.lineMultiple {
            baseline = before + above * min(1, CGFloat(props.lineSpacing) / 240)
        }
        // Рамка рядом со следующим текстом (`RTFFrame.besideNext`): рисуется на его месте, места не занимает.
        if props?.frame.besideNext == true {
            rect.size.height = 0
            used.size.height = 0
            baseline -= before
        }
        return true
    }

    /// Только пробелы, табуляции, метки абзаца и знаки нулевой ширины.
    private static func blank(_ text: NSString, _ range: NSRange) -> Bool {
        for index in range.location..<NSMaxRange(range) {
            switch text.character(at: index) {
            case 0x20, 0x09, 0x0A, 0x0D, 0x2028, 0x2029, 0x200B, 0xFEFF, 0x0C: continue
            default: return false
            }
        }
        return true
    }
}

/// Делегат раскладки колонтитулов: та же высота строк, что у основного текста.
package final class DocLineMetricsDelegate: NSObject, NSLayoutManagerDelegate {
    @MainActor package static let shared = DocLineMetricsDelegate()

    package func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        MainActor.assumeIsolated {
            DocLineMetrics.adjust(layoutManager, rect: &lineFragmentRect.pointee, used: &lineFragmentUsedRect.pointee,
                                  baseline: &baselineOffset.pointee, container: textContainer, glyphs: glyphRange)
        }
    }

    package func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor container: NSTextContainer?, atEnd: Bool) {
        MainActor.assumeIsolated { DocLineMetrics.completed(layoutManager) }
    }
}
