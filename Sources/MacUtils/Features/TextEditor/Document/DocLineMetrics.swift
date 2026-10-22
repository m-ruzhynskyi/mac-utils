import AppKit
import CoreText

/// Высота строк как у Word. TextKit округляет ascent и descent шрифта до целых пунктов и добавляет leading (TNR 12 —
/// 14,51 pt, у Word 13,8), Word берёт метрики без округления, как GDI: ascent и descent из OS/2 (`usWinAscent`,
/// `usWinDescent`) плюс внешний интерлиньяж из `hhea`. Одинарный интервал — наибольшие ascent + интерлиньяж и descent
/// шрифтов строки; `\sl` — «минимум», «точно» (< 0) или множитель (`\slmult1`, N/240 одинарного); лишнее — над текстом.
/// `\sb`/`\sa` — над первой и под последней строкой абзаца (в ячейках тоже).
enum DocLineMetrics {
    struct Font {
        /// Над базовой линией (с внешним интерлиньяжем — он у Word сверху) и под ней, pt.
        var above: CGFloat
        var below: CGFloat
    }

    @MainActor private static var cache: [String: Font] = [:]

    @MainActor static func metrics(_ font: NSFont) -> Font {
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

    /// Поправить строку, которую разложил TextKit: высота, базовая линия, интервалы абзаца. `false` — оставить как есть
    /// (строка с рисунком или заглушкой: её высоту задаёт вложение).
    @MainActor static func adjust(_ layoutManager: NSLayoutManager, rect: inout NSRect, used: inout NSRect, baseline: inout CGFloat,
                                  container: NSTextContainer, glyphs: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage, glyphs.length > 0 else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.length > 0, NSMaxRange(characters) <= storage.length else { return false }
        // Служебный абзац разрыва перед таблицей — нулевой высоты.
        if storage.attribute(.docBreakLine, at: characters.location, effectiveRange: nil) != nil {
            rect.size.height = 0
            used.size.height = 0
            baseline = 0
            return true
        }
        var above: CGFloat = 0, below: CGFloat = 0
        var object = false
        storage.enumerateAttributes(in: characters) { attributes, _, stop in
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
            above = max(above, metrics.above)
            below = max(below, metrics.below)
        }
        guard !object, above + below > 0 else { return false }
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: characters.location, length: 0))
        let style = storage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle ?? .default
        let props = (storage.attribute(.docPara, at: characters.location, effectiveRange: nil) as? DocParaInfo)?.props
        let single = above + below
        var height = single
        if let props, props.lineSpacing != 0 {
            let value = CGFloat(abs(props.lineSpacing)) / 20
            if props.lineSpacing < 0 {
                height = value
            } else if props.lineMultiple {
                height = single * CGFloat(props.lineSpacing) / 240
            } else {
                height = max(single, value)
            }
        }
        let first = characters.location == paragraph.location
        let last = NSMaxRange(characters) >= NSMaxRange(paragraph)
        let before = first ? style.paragraphSpacingBefore : 0
        let after = last ? style.paragraphSpacing : 0
        rect.size.height = before + height + after
        used.origin.y = rect.minY + before
        used.size.height = height
        baseline = before + height - below
        return true
    }
}

/// Делегат раскладки колонтитулов: та же высота строк, что у основного текста.
final class DocLineMetricsDelegate: NSObject, NSLayoutManagerDelegate {
    @MainActor static let shared = DocLineMetricsDelegate()

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        MainActor.assumeIsolated {
            DocLineMetrics.adjust(layoutManager, rect: &lineFragmentRect.pointee, used: &lineFragmentUsedRect.pointee,
                                  baseline: &baselineOffset.pointee, container: textContainer, glyphs: glyphRange)
        }
    }
}
