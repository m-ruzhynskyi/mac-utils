import AppKit

/// Переключатель «Код ↔ Документ» вкладки: место (курсор, выделение, прокрутка) переносится через карту исходника.
extension EditorTab {
    /// Документом показывается только RTF (`.rtf`, `.frm` с `{\\rtf`).
    var isRTF: Bool { document.language == .rtf }
    var canShowDocument: Bool { isRTF && DocumentController.canShow(text) }

    /// Почему «Документ» недоступен (подсказка неактивного сегмента).
    var documentUnavailableReason: String? {
        guard isRTF else { return nil }
        return canShowDocument ? nil : "Это не RTF: файл не начинается с {\\rtf"
    }

    func setMode(_ newMode: EditorViewMode) {
        guard newMode != mode else { return }
        if newMode == .document {
            guard canShowDocument else { return NSSound.beep() }
            let selection = textView.selectedRange()
            let top = codeTopSourceLocation
            let controller = documentController ?? DocumentController(tab: self)
            controller.showsInvisibles = showsInvisibles
            documentController = controller
            controller.refresh()
            mode = .document
            DispatchQueue.main.async {
                controller.scrollToSource(top)
                controller.select(source: selection, reveal: false)
            }
        } else {
            guard let controller = documentController else { mode = .code; return }
            let selection = controller.sourceSelection
            let top = controller.topSourceLocation
            mode = .code
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.textView.window?.makeFirstResponder(self.textView)
                self.scrollCode(toSource: top)
                self.textView.setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: self.storage.length)))
            }
        }
        EditorViewModes.remember(newMode, for: document.url)
        onEdit?()
    }

    /// Восстановление из сессии или выбор по умолчанию — без переноса места.
    func restoreMode(_ saved: EditorViewMode?) {
        let wanted = saved ?? EditorViewModes.preferred(for: document.url)
        guard wanted == .document, canShowDocument else { return }
        documentController = DocumentController(tab: self)
        documentController?.showsInvisibles = showsInvisibles
        mode = .document
    }

    /// «Показать в коде»: в «Код» и выделить кусок исходника.
    func showInCode(_ range: NSRange) {
        setMode(.code)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let target = NSIntersectionRange(range, NSRange(location: 0, length: self.storage.length))
            self.reveal(range.location <= self.storage.length ? NSRange(location: range.location, length: target.length) : target)
        }
    }

    /// Клик по строке панели «$»: в «Коде» — выделить в исходнике, в «Документе» — показать на странице со вспышкой.
    func revealDollar(_ entry: DollarEntry) {
        guard mode == .document, let controller = documentController else { return reveal(entry.mark.whole) }
        let map = controller.rendering.map
        let dollar = map.unit(forSource: entry.mark.dollar)
        guard dollar < map.count, NSLocationInRange(entry.mark.dollar, map.range(at: dollar)) else { return NSSound.beep() }
        let parts = entry.mark.parts.flatMap { map.units(inside: $0) }
        let end = parts.last.map(NSMaxRange) ?? dollar + 1
        let range = NSRange(location: dollar, length: max(1, end - dollar))
        controller.textView(forUnit: dollar)?.setSelectedRange(NSRange(location: dollar, length: 0))
        controller.reveal(range, flash: true)
    }

    /// Первый видимый символ кода сверху.
    var codeTopSourceLocation: Int {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return 0 }
        let point = NSPoint(x: 0, y: scrollView.contentView.bounds.minY - textView.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: point, in: container)
        return layout.characterIndexForGlyph(at: glyph)
    }

    func scrollCode(toSource location: Int) {
        guard let layout = textView.layoutManager, storage.length > 0 else { return }
        let glyph = layout.glyphIndexForCharacter(at: min(location, storage.length - 1))
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: max(0, line.minY + textView.textContainerOrigin.y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Последний выбор режима: для файла — в сессии вкладки, для новых — по расширению (.frm и .rtf — «Документ»).
enum EditorViewModes {
    static func preferred(for url: URL?) -> EditorViewMode {
        let ext = url?.pathExtension.lowercased() ?? ""
        let saved = UserDefaults.standard.dictionary(forKey: Pref.editorViewModes) as? [String: String] ?? [:]
        if let raw = saved[ext], let mode = EditorViewMode(rawValue: raw) { return mode }
        return ["frm", "rtf"].contains(ext) ? .document : .code
    }

    static func remember(_ mode: EditorViewMode, for url: URL?) {
        let ext = url?.pathExtension.lowercased() ?? ""
        guard !ext.isEmpty else { return }
        var saved = UserDefaults.standard.dictionary(forKey: Pref.editorViewModes) as? [String: String] ?? [:]
        saved[ext] = mode.rawValue
        UserDefaults.standard.set(saved, forKey: Pref.editorViewModes)
    }
}
