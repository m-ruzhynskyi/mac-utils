import AppKit

/// Раскладка редактора: «Невидимые символы» рисуются поверх текста (системный `showsInvisibleCharacters` не различает
/// виды переводов строк). Пробел — ·, табуляция — →, LF — ¶, CR — ¤ (CRLF — ¤¶). Неопределённые байты однобайтовых
/// кодировок (у Windows-1252 это 0x81, 0x8D, 0x8F, 0x90, 0x9D — в тексте они U+0081…) получают ширину и бейдж `‹81›`.
final class EditorLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var showsInvisibles = false {
        didSet {
            guard showsInvisibles != oldValue, let storage = textStorage else { return }
            // Ширина бейджей неопределённых байтов меняется — раскладка заново.
            invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
            for container in textContainers { container.textView?.needsDisplay = true }
        }
    }

    override init() {
        super.init()
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Неопределённые байты

    /// Управляющие символы C1 (U+0080…U+009F): так в тексте выглядят байты, которых нет в однобайтовой кодировке.
    static func isUndefinedByte(_ unit: UInt16) -> Bool { (0x80...0x9F).contains(unit) }

    /// `‹81›` — код байта шестнадцатеричными цифрами.
    static func badge(_ unit: UInt16) -> String { "‹" + String(format: "%02X", unit) + "›" }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard showsInvisibles, let storage = textStorage, charIndex < storage.length,
              Self.isUndefinedByte(storage.mutableString.character(at: charIndex)) else { return action }
        return .whitespace
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = (Self.badge(0x81) as NSString).size(withAttributes: [.font: badgeFont(at: charIndex)]).width + 2
        return NSRect(x: glyphPosition.x, y: 0, width: width, height: proposedRect.height)
    }

    private func badgeFont(at index: Int) -> NSFont {
        let font = (textStorage?.attribute(.font, at: min(index, max(0, (textStorage?.length ?? 1) - 1)), effectiveRange: nil) as? NSFont)
            ?? EditorStyle.font(zoom: 1)
        return NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.8, weight: .regular)
    }

    // MARK: - Рисование

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard showsInvisibles, let storage = textStorage else { return }
        let text = storage.mutableString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard chars.length > 0 else { return }
        var units = [UInt16](repeating: 0, count: chars.length)
        units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: chars) }
        let font = (storage.attribute(.font, at: chars.location, effectiveRange: nil) as? NSFont) ?? EditorStyle.font(zoom: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: EditorStyle.invisible]
        let badgeAttributes: [NSAttributedString.Key: Any] = [.font: badgeFont(at: chars.location), .foregroundColor: EditorStyle.escape]
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        for (offset, unit) in units.enumerated() {
            let mark: String
            var shift: CGFloat = 0
            switch unit {
            case 0x20: mark = "·"
            case 0x09: mark = "→"
            case 0x0D: mark = "¤"
            case 0x0A:
                mark = "¶"
                // CRLF: ¤ и ¶ рядом, а не друг на друге (у обоих символов нулевая ширина).
                let index = chars.location + offset
                if index > 0, (offset > 0 ? units[offset - 1] : text.character(at: index - 1)) == 0x0D { shift = advance }
            case 0x80...0x9F: mark = Self.badge(unit)
            default: continue
            }
            let index = chars.location + offset
            let glyph = glyphIndexForCharacter(at: index)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            guard fragment.height > 0 else { continue }
            let location = self.location(forGlyphAt: glyph)
            let style = mark.count > 1 ? badgeAttributes : attributes
            let size = (mark as NSString).size(withAttributes: style)
            let point = NSPoint(x: origin.x + fragment.minX + location.x + shift + (unit == 0x20 ? (advance - size.width) / 2 : 0),
                                y: origin.y + fragment.minY + (fragment.height - size.height) / 2)
            (mark as NSString).draw(at: point, withAttributes: style)
        }
    }
}

/// Парные скобки: ( ) [ ] { }. Скобка с обратной косой чертой перед ней (`\{` в RTF) — не скобка.
enum BracketMatcher {
    private static let pairs: [UInt16: UInt16] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
    private static let closing: [UInt16: UInt16] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
    /// Дальше этого пару не ищем: на 10 МБ поиск не должен тормозить ввод.
    static let limit = 200_000

    /// Скобка экранирована: перед ней нечётное число `\`.
    static func isEscaped(_ text: NSString, _ index: Int) -> Bool {
        var count = 0, i = index - 1
        while i >= 0, text.character(at: i) == 0x5C { count += 1; i -= 1 }
        return count % 2 == 1
    }

    enum Match: Equatable {
        /// Скобка у курсора и её пара.
        case pair(Int, Int)
        /// Пары нет (несбалансированная скобка).
        case unmatched(Int)
    }

    /// Скобка сразу перед курсором или сразу после него — и её пара.
    static func match(in text: NSString, caret: Int) -> Match? {
        for index in [caret - 1, caret] where index >= 0 && index < text.length {
            let unit = text.character(at: index)
            guard pairs[unit] != nil || closing[unit] != nil, !isEscaped(text, index) else { continue }
            if let partner = partner(of: index, in: text) { return .pair(index, partner) }
            return .unmatched(index)
        }
        return nil
    }

    static func partner(of index: Int, in text: NSString) -> Int? {
        let unit = text.character(at: index)
        if let close = pairs[unit] {
            var depth = 0, i = index
            while i < min(text.length, index + limit) {
                let c = text.character(at: i)
                if (c == unit || c == close), !isEscaped(text, i) { depth += c == unit ? 1 : -1 }
                if depth == 0 { return i }
                i += 1
            }
        } else if let open = closing[unit] {
            var depth = 0, i = index
            while i >= max(0, index - limit) {
                let c = text.character(at: i)
                if (c == unit || c == open), !isEscaped(text, i) { depth += c == unit ? 1 : -1 }
                if depth == 0 { return i }
                i -= 1
            }
        }
        return nil
    }
}
