import AppKit
import SwiftUI
import MUDesign

// V2 (`.audit/plan-word-ui.md`, «★3»): правка значения знака `$` прямо на странице. Щелчок по `$` (или по строке панели «$»
// в «Документе») — поповер с полем: ↩ — записать и перейти к следующему, Tab / ⇧Tab — пропустить, Esc — закрыть.
// Значение пишется точечной правкой исходника тем же генератором, что набор в «Документе» (`DocTextEditor`), один шаг отмены.

/// Прежние значения для быстрого выбора — только в памяти этого сеанса: значения форм — персональные данные, на диск не пишутся
/// (решение пользователя, V3).
@MainActor
package enum DollarValueHistory {
    package static let limit = 8
    private static var values: [String] = []

    package static var recent: [String] { values }

    package static func remember(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        values.removeAll { $0 == trimmed }
        values.insert(trimmed, at: 0)
        if values.count > limit { values.removeLast(values.count - limit) }
    }

    /// Прежние значения под полем: сначала похожие на набранное (начинаются с него, потом содержат), затем остальные —
    /// по свежести; само набранное не повторяется.
    package static func suggestions(for typed: String) -> [String] {
        let typed = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let others = values.filter { $0.lowercased() != typed }
        guard !typed.isEmpty else { return others }
        func rank(_ value: String) -> Int {
            let lower = value.lowercased()
            return lower.hasPrefix(typed) ? 0 : (lower.contains(typed) ? 1 : 2)
        }
        return others.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    package static func reset() { values = [] }
}

extension DocumentController {
    /// Знак `$` под показанной единицей: подсвеченный (не пропущенный и не служебный); `nil` — тут не знак.
    package func dollarEntry(atUnit unit: Int) -> DollarEntry? {
        guard let tab, unit >= 0, unit < rendering.map.count else { return nil }
        let range = rendering.map.range(at: unit)
        guard range.length == 1 else { return nil }
        let model = tab.dollars
        let index = model.count(before: range.location)
        guard index < model.entries.count else { return nil }
        let entry = model.entries[index]
        guard entry.mark.dollar == range.location, !entry.isHidden, !model.isSkipped(entry) else { return nil }
        return entry
    }

    /// Показанные единицы значения знака: от первой до последней видимой; пустое значение — место сразу за `$`.
    package func valueUnits(of entry: DollarEntry) -> NSRange? {
        let map = rendering.map
        let dollar = map.unit(forSource: entry.mark.dollar)
        guard dollar < map.count, map.range(at: dollar) == NSRange(location: entry.mark.dollar, length: 1) else { return nil }
        let parts = entry.mark.parts.flatMap { map.units(inside: $0) }
        guard let first = parts.first, let last = parts.last else { return NSRange(location: dollar + 1, length: 0) }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    /// Записать значение знака (пустое — знак `$` остаётся без значения). `false` — правка невозможна (подсказка уже показана).
    @discardableResult
    package func writeDollarValue(_ value: String, to entry: DollarEntry) -> Bool {
        guard let tab, let units = valueUnits(of: entry) else { return false }
        // Значение — одна строка: переводы строк стали бы новыми абзацами формы.
        let text = value.components(separatedBy: .newlines).joined(separator: " ")
        if NSMaxRange(units) <= storage.length, storage.mutableString.substring(with: units) == text { return true }
        let result = DocTextEditor.replace(units, with: text, model: model, map: rendering.map, source: tab.text)
        if let refusal = result.refusal {
            show(notice: refusal)
            return false
        }
        guard !result.edits.isEmpty else { return false }
        guard apply(result.edits, actionName: "Значение $") else { return false }
        tab.dollars.scanNow(tab.text)
        return true
    }

    /// Хит-тест щелчка по странице (хук в `DocTextView.mouseDown`): по подсвеченному `$` — поповер правки значения.
    package func clickDollar(_ event: NSEvent, in view: DocTextView) -> Bool {
        guard showsDollarMarks, let layout = view.layoutManager, let container = view.textContainer else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: nil)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(inContainer) else { return false }
        let unit = layout.characterIndexForGlyph(at: glyph)
        guard let entry = dollarEntry(atUnit: unit) else { return false }
        DocValuePopover.shared.show(entry, in: self)
        return true
    }
}

/// Правка одного знака за другим: текущий знак, набранное значение, переходы.
@MainActor
package final class DollarValueEditor: ObservableObject {
    package weak var controller: DocumentController?
    @Published package private(set) var entry: DollarEntry
    @Published package var text: String
    /// Перейти к другому знаку (поповер переставляется к нему).
    package var onMove: ((DollarEntry) -> Void)?
    package var onClose: (() -> Void)?

    package init(entry: DollarEntry, controller: DocumentController) {
        self.entry = entry
        self.controller = controller
        text = controller.visibleValue(of: entry.mark) ?? entry.value
        controller.tab?.dollars.pinEditing(entry.mark.dollar)
    }

    /// Место знака для заголовка: страница («с.2») или «—».
    package var place: String { controller?.page(ofSource: entry.mark.dollar).map { "с.\($0)" } ?? "—" }

    /// ↩: записать и перейти к следующему подсвеченному; последний — закрыть.
    package func apply() {
        guard let controller else { return close() }
        guard controller.writeDollarValue(text, to: entry) else { return }
        DollarValueHistory.remember(text)
        move(by: 1)
    }

    /// Tab / ⇧Tab: к следующему / предыдущему подсвеченному без записи; дальше некуда — закрыть.
    package func skip(_ step: Int) { move(by: step) }

    package func close() {
        controller?.tab?.dollars.pinEditing(nil)
        onClose?()
    }

    private func move(by step: Int) {
        guard let model = controller?.tab?.dollars, let order = entry.order else { return close() }
        // Номер среди знаков страницы не меняется от правки значения: `$` остаётся на месте.
        guard let next = model.split.active.first(where: { $0.order == order + step }), let controller else { return close() }
        entry = next
        text = controller.visibleValue(of: next.mark) ?? next.value
        model.pinEditing(next.mark.dollar)
        onMove?(next)
    }
}

/// Поповер над знаком: показывает `DocValuePopoverView`, переставляется при переходе к следующему знаку.
@MainActor
package final class DocValuePopover: NSObject, NSPopoverDelegate {
    package static let shared = DocValuePopover()
    private let popover = NSPopover()
    package private(set) var editor: DollarValueEditor?

    package func show(_ entry: DollarEntry, in controller: DocumentController) {
        close()
        let editor = DollarValueEditor(entry: entry, controller: controller)
        editor.onMove = { [weak self, weak controller] next in
            guard let self, let controller else { return }
            self.anchor(next, in: controller)
        }
        editor.onClose = { [weak self] in self?.popover.performClose(nil) }
        self.editor = editor
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: DocValuePopoverView(editor: editor))
        anchor(entry, in: controller)
    }

    private func anchor(_ entry: DollarEntry, in controller: DocumentController) {
        let unit = controller.rendering.map.unit(forSource: entry.mark.dollar)
        guard let view = controller.textView(forUnit: unit), let layout = view.layoutManager, let container = view.textContainer else { return }
        controller.reveal(NSRange(location: unit, length: 1))
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: unit, length: 1), actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += view.textContainerOrigin.x
        rect.origin.y += view.textContainerOrigin.y
        if popover.isShown { popover.positioningRect = rect } else { popover.show(relativeTo: rect, of: view, preferredEdge: .maxY) }
    }

    package func close() {
        if popover.isShown { popover.performClose(nil) }
        editor = nil
    }

    package nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            editor?.controller?.tab?.dollars.pinEditing(nil)
            editor = nil
        }
    }
}

/// Содержимое поповера (макет «★3»): `$значение` и место, поле, «Применить ↩» и «Пропустить Tab», прежние значения.
package struct DocValuePopoverView: View {
    @ObservedObject package var editor: DollarValueEditor
    @FocusState private var focused: Bool

    package init(editor: DollarValueEditor) { self.editor = editor }

    package var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                (Text("$").foregroundStyle(Color.dsAccText) + Text(editor.text.isEmpty ? "пусто" : editor.text))
                    .font(DS.Font.mono(13, relativeTo: .body).weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Pill(.neutral, editor.place)
            }
            TextField("Значение", text: $editor.text)
                .textFieldStyle(.plain)
                .font(DS.Font.manrope(14, .bold, relativeTo: .body))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Color.dsAccLine, lineWidth: 1.5))
                .focused($focused)
                .onSubmit { editor.apply() }
                .onKeyPress(keys: [.tab]) { press in
                    editor.skip(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onExitCommand { editor.close() }
                .accessibilityLabel("Значение знака $")
            HStack(spacing: DS.Space.s) {
                Button("Применить ↩") { editor.apply() }
                    .buttonStyle(.graphite(.primary, size: .compact, fill: true))
                Button("Пропустить Tab") { editor.skip(1) }
                    .buttonStyle(.graphite(.secondary, size: .compact))
            }
            let previous = DollarValueHistory.suggestions(for: editor.text).prefix(4)
            if !previous.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Предыдущие значения").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                    FlowChips(values: Array(previous)) { editor.text = $0 }
                }
            }
        }
        .padding(DS.Space.m)
        .frame(width: 300)
        .background(Color.dsPanel)
        .onAppear { focused = true }
    }
}

/// Прежние значения чипами в строку (переносятся, если не помещаются).
private struct FlowChips: View {
    let values: [String]
    let pick: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.xs) { chips }
            VStack(alignment: .leading, spacing: DS.Space.xs) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(values, id: \.self) { value in
            Chip(value, selected: false) { pick(value) }
                .lineLimit(1)
                .help("Подставить «\(value)»")
        }
    }
}
