import AppKit

/// Вставка форматированного текста (RTF или HTML из буфера, например из Word): текст вставляется генератором ввода
/// D-3, затем на вставленный кусок — только известные нам свойства (шрифт, размер, Ж/К/Ч/S, цвет) теми же точечными
/// правками, что у кнопок панели. Всё — одним шагом отмены. Остальное (стили, таблицы, рисунки) отбрасывается
/// с подсказкой «Вставлено без части форматирования».
extension DocFormatter {
    /// `false` — в буфере нет форматированного текста (вставка идёт обычным текстом).
    func pasteFormatted(in view: NSTextView, pasteboard: NSPasteboard = .general) -> Bool {
        guard headerSession == nil, let type = pasteboard.availableType(from: [.rtf, .rtfd, .html]), let data = pasteboard.data(forType: type) else {
            return false
        }
        let documentType: NSAttributedString.DocumentType = type == .html ? .html : type == .rtfd ? .rtfd : .rtf
        guard let pasted = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil) else { return false }
        paste(pasted)
        return true
    }

    /// Самое большое число отдельных правок формата на одну вставку: дальше — без части форматирования.
    static let pasteFormatLimit = 60

    /// Вставить `pasted` на место выделения.
    func paste(_ pasted: NSAttributedString) {
        guard let controller, let tab = controller.tab else { return }
        let clean = Self.cleaned(pasted)
        let text = clean.string
        guard !text.isEmpty else { return }
        let selection = controller.selectedUnits
        tab.undo.beginUndoGrouping()
        defer {
            tab.undo.endUndoGrouping()
            tab.undo.setActionName("Вставка")
        }
        guard controller.perform(replacing: selection, with: text) else { return }
        let inserted = NSRange(location: selection.location, length: (text as NSString).length)
        guard NSMaxRange(inserted) <= controller.storage.length,
              (controller.storage.string as NSString).substring(with: inserted) == text else {
            return controller.show(notice: "Вставлено без форматирования")
        }
        var complete = clean.length == pasted.length
        var count = 0
        for change in Self.changes(clean) {
            guard count < Self.pasteFormatLimit else { complete = false; break }
            let units = NSRange(location: inserted.location + change.range.location, length: change.range.length)
            guard needs(change.change, units: units) else { continue }
            count += 1
            let span = controller.rendering.map.sourceRange(ofUnits: units)
            switch FormatEdits.character(change.change, span: span, source: tab.text, model: controller.model) {
            case .success(let plan):
                guard let edits = FormatCheck.merged(plan.edits), !edits.isEmpty else { continue }
                controller.apply(edits.map { DocEdit(range: $0.range, text: $0.string) }, actionName: "Вставка") { _ in
                    NSRange(location: NSMaxRange(inserted), length: 0)
                }
            case .failure:
                complete = false
            }
        }
        updateState()
        if !complete { controller.show(notice: "Вставлено без части форматирования") }
    }

    /// Нужна ли правка: вставленный кусок уже такой (шрифт и размер места вставки) — нет.
    private func needs(_ change: CharChange, units: NSRange) -> Bool {
        guard let controller else { return false }
        let storage = controller.storage
        var needed = false
        storage.enumerateAttribute(.docChar, in: NSIntersectionRange(units, NSRange(location: 0, length: storage.length))) { value, _, stop in
            guard let info = value as? DocCharInfo else { return }
            let props = info.props
            let differs: Bool
            switch change {
            case .bold(let on): differs = props.bold != on
            case .italic(let on): differs = props.italic != on
            case .underline(let on): differs = (props.underline != .none) != on
            case .strike(let on): differs = props.strike != on
            case .size(let halfPoints): differs = props.halfPoints != halfPoints
            case .font(let name): differs = info.fontName != name && FontSubstitution.baseName(info.fontName) != name
            case .color(let color): differs = (controller.model.color(props.color) ?? RTFColor(red: 0, green: 0, blue: 0)) != (color ?? RTFColor(red: 0, green: 0, blue: 0))
            case .highlight, .clear: differs = false
            }
            if differs {
                needed = true
                stop.pointee = true
            }
        }
        return needed
    }

    /// Без рисунков и с переводами строк `\n` (абзацы).
    static func cleaned(_ pasted: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        pasted.enumerateAttributes(in: NSRange(location: 0, length: pasted.length)) { attributes, range, _ in
            var piece = (pasted.string as NSString).substring(with: range)
            piece = piece.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n").replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !piece.isEmpty else { return }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }

    struct PasteChange {
        var range: NSRange
        var change: CharChange
    }

    /// Куски вставленного текста с одним значением каждого свойства — по свойствам, подряд идущие склеены.
    static func changes(_ pasted: NSAttributedString) -> [PasteChange] {
        var result: [PasteChange] = []
        func collect(_ value: (([NSAttributedString.Key: Any]) -> CharChange?)) {
            var current: PasteChange?
            pasted.enumerateAttributes(in: NSRange(location: 0, length: pasted.length)) { attributes, range, _ in
                // Переводы строк — концы абзацев, их не оформляем.
                let text = (pasted.string as NSString).substring(with: range)
                guard let change = value(attributes), !text.allSatisfy({ $0 == "\n" }) else {
                    if let piece = current { result.append(piece) }
                    current = nil
                    return
                }
                if var piece = current, piece.change == change, NSMaxRange(piece.range) == range.location {
                    piece.range.length += range.length
                    current = piece
                } else {
                    if let piece = current { result.append(piece) }
                    current = PasteChange(range: range, change: change)
                }
            }
            if let piece = current { result.append(piece) }
        }
        let manager = NSFontManager.shared
        collect { ($0[.font] as? NSFont).flatMap { $0.familyName }.flatMap { $0.hasPrefix(".") ? nil : CharChange.font($0) } }
        collect { ($0[.font] as? NSFont).map { CharChange.size(Int(($0.pointSize * 2).rounded())) } }
        collect { ($0[.font] as? NSFont).map { CharChange.bold(manager.traits(of: $0).contains(.boldFontMask)) } }
        collect { ($0[.font] as? NSFont).map { CharChange.italic(manager.traits(of: $0).contains(.italicFontMask)) } }
        collect { .underline((($0[.underlineStyle] as? Int) ?? 0) != 0) }
        collect { .strike((($0[.strikethroughStyle] as? Int) ?? 0) != 0) }
        collect { attributes in
            guard let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) else { return .color(nil) }
            let rgb = RTFColor(red: Int((color.redComponent * 255).rounded()), green: Int((color.greenComponent * 255).rounded()),
                               blue: Int((color.blueComponent * 255).rounded()))
            return .color(rgb == RTFColor(red: 0, green: 0, blue: 0) ? nil : rgb)
        }
        return result
    }
}
