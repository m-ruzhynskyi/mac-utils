import AppKit
import SwiftUI

/// Панель «Знаки $» справа от текста (макеты a, d1, d2).
struct DollarPanelView: View {
    @ObservedObject var tab: EditorTab
    @ObservedObject var model: DollarPanelModel
    @AppStorage(Pref.editorSkipFirst) private var skipOn = true
    @AppStorage(Pref.editorSkipCount) private var skipCount = 3
    @Environment(\.colorScheme) private var scheme

    init(tab: EditorTab) {
        self.tab = tab
        model = tab.dollars
    }

    var body: some View {
        let parts = model.split
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Text("Знаки $").font(DS.Font.manrope(16, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Pill(.neutral, "\(parts.active.count) из \(model.entries.count)")
                    .accessibilityLabel("Подсвечено \(parts.active.count) из \(model.entries.count)")
            }
            skipCard
            list(parts)
            footer(parts)
        }
        .padding(DS.Space.m)
        .frame(maxHeight: .infinity)
        .background(Color.dsSide)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Знаки $")
    }

    // MARK: - Пропуск первых N

    private var skipCard: some View {
        ListCard(style: .field) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: DS.Space.s) {
                    Text("Пропускать первые").font(DS.Font.bodyStrong).foregroundStyle(.dsText)
                    Spacer(minLength: 0)
                    Toggle("Пропускать первые", isOn: $skipOn).toggleStyle(.graphite)
                }
                HStack(spacing: DS.Space.s) {
                    Text(skipOn ? "Без подсветки и правки" : "Обрабатываются все")
                        .font(DS.Font.rowSub).foregroundStyle(.dsMute)
                    Spacer(minLength: 0)
                    GraphiteStepper(value: Binding(get: { DollarSkip.clamp(skipCount) }, set: { skipCount = DollarSkip.clamp($0) }),
                                    range: 0...DollarSkip.maxCount, label: "Сколько пропускать")
                        .disabled(!skipOn)
                }
            }
            .padding(.vertical, DS.Space.s)
            .padding(.horizontal, 10)
        }
    }

    // MARK: - Список

    @ViewBuilder
    private func list(_ parts: (skipped: ArraySlice<DollarEntry>, active: ArraySlice<DollarEntry>)) -> some View {
        if model.entries.isEmpty {
            VStack {
                Spacer(minLength: 0)
                if model.scanning {
                    EmptyState.loading("Ищу знаки $…")
                } else {
                    EmptyState("Знаков $ нет", systemImage: "dollarsign", message: "В тексте нет ни одного $", compact: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let cleared = model.removedCount != nil
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !parts.skipped.isEmpty {
                            GroupLabel("Пропущено · \(parts.skipped.count)").padding(.horizontal, DS.Space.xs)
                            ForEach(parts.skipped, id: \.mark.dollar) { entry in row(entry, skipped: true) }
                            Spacer().frame(height: DS.Space.s)
                        }
                        if !parts.active.isEmpty {
                            GroupLabel(cleared && parts.active.allSatisfy { $0.value.isEmpty }
                                       ? "Без значений · \(parts.active.count)" : "Подсвечено · \(parts.active.count)")
                                .padding(.horizontal, DS.Space.xs)
                            ForEach(parts.active) { entry in row(entry, skipped: false) }
                        }
                        let service = model.service
                        if !service.isEmpty {
                            Spacer().frame(height: DS.Space.s)
                            GroupLabel("В служебных полях · \(service.count)").padding(.horizontal, DS.Space.xs)
                                .help("Знаки в \\info, {\\*\\…} и таблицах RTF: на странице их не видно, их не трогаем")
                            ForEach(service, id: \.mark.dollar) { entry in row(entry, skipped: true) }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: .infinity)
                .onChange(of: model.selected) { _, selected in
                    guard let selected else { return }
                    let id = parts.skipped.contains { $0.id == selected } ? Self.skippedID(selected) : selected
                    withAnimation(DS.Motion.quick) { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// «стало 5 непарных скобок», «стало 2 непарные скобки», «стала 1 непарная скобка».
    static func unbalancedPhrase(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        if !(11...14).contains(tens), ones == 1 { return "стала \(count) непарная скобка" }
        if !(11...14).contains(tens), (2...4).contains(ones) { return "стало \(count) непарные скобки" }
        return "стало \(count) непарных скобок"
    }

    /// Где знак: номер строки исходника, а в «Документе» — страница («с.2»; не видно на странице — «—»).
    private func place(_ entry: DollarEntry) -> String {
        guard tab.mode == .document, let document = tab.documentController else { return "\(entry.line)" }
        return document.page(ofSource: entry.mark.dollar).map { "с.\($0)" } ?? "—"
    }

    /// Значение в строке: в «Коде» — как в исходнике, в «Документе» — как видно на странице (`\'ca…` → «Катя»).
    private func shown(_ entry: DollarEntry) -> String {
        guard tab.mode == .document, let document = tab.documentController else { return entry.value }
        return document.visibleValue(of: entry.mark) ?? entry.value
    }

    /// Строки групп — с разными id: иначе ленивый список путает строку, перешедшую из группы в группу.
    static func skippedID(_ dollar: Int) -> Int { -dollar - 1 }

    private func row(_ entry: DollarEntry, skipped: Bool) -> some View {
        DollarRow(entry: entry, skipped: skipped, selected: model.selected == entry.mark.dollar, place: place(entry), value: shown(entry)) {
            model.selected = entry.mark.dollar
            tab.dollars.onUpdate?()
            tab.revealDollar(entry)
        } remove: {
            tab.removeValues([entry])
        }
        .id(skipped ? Self.skippedID(entry.mark.dollar) : entry.mark.dollar)
    }

    // MARK: - Убрать значения

    @ViewBuilder
    private func footer(_ parts: (skipped: ArraySlice<DollarEntry>, active: ArraySlice<DollarEntry>)) -> some View {
        if let removed = model.removedCount {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(DS.Tone.success.line)
                        .accessibilityHidden(true)
                    Text("Убрано: \(removed)").font(DS.Font.bodyStrong).foregroundStyle(.dsText)
                    Spacer(minLength: 0)
                    Button("Отменить ⌘Z") { tab.undo.undo() }
                        .buttonStyle(.graphite(.secondary, size: .compact))
                        .disabled(!tab.undo.canUndo)
                }
                Text("Знаки $ остались на местах").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                if let unbalanced = model.unbalancedAfterRemoval {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(DS.Tone.warning.line)
                            .accessibilityHidden(true)
                        Text("Внимание: в файле \(Self.unbalancedPhrase(unbalanced)) — Word может не открыть файл")
                            .font(DS.Font.rowSub).foregroundStyle(.dsText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Отменить") { tab.undo.undo() }
                            .buttonStyle(.graphite(.secondary, size: .compact))
                            .disabled(!tab.undo.canUndo)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(10)
            .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous).strokeBorder(Color.dsAccLine, lineWidth: 1.5))
        } else {
            let count = model.removableCount
            VStack(alignment: .leading, spacing: 6) {
                Button("Убрать значения · \(count)") { tab.removeHighlightedValues() }
                    .buttonStyle(.graphite(.primary, fill: true))
                    .disabled(count == 0)
                    .help("Удалить значения у всех подсвеченных; сами $ остаются. Отмена — ⌘Z")
                Text("У одного — × в строке списка").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Строка списка: номер строки, полоска оттенка, `$значение`; выбранная обведена и показывает × «убрать это значение».
private struct DollarRow: View {
    let entry: DollarEntry
    let skipped: Bool
    let selected: Bool
    let place: String
    let value: String
    let select: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        let hue = skipped ? nil : Color(nsColor: EditorStyle.hue(entry.hue))
        let faint = Color(nsColor: EditorStyle.faint)
        HStack(spacing: DS.Space.s) {
            Text(place)
                .font(DS.Font.mono(11, relativeTo: .caption))
                .foregroundStyle(faint)
                .frame(minWidth: 22, alignment: .trailing)
                .fixedSize()
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(hue ?? faint.opacity(0.5))
                .frame(width: 4, height: 16)
            (Text("$").foregroundStyle(hue ?? faint) + Text(value).foregroundStyle(skipped ? faint : Color.dsText))
                .font(DS.Font.mono(12.5, relativeTo: .body))
                .lineLimit(1)
                .truncationMode(.middle)
            if value.isEmpty {
                Text(entry.mark.isEmpty ? "пусто" : "пробелы").font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
            Spacer(minLength: 0)
            if (selected || hovered) && !entry.mark.isEmpty && !entry.isHidden {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.dsMute)
                }
                .buttonStyle(.plain)
                .help("Убрать значение")
                .accessibilityLabel("Убрать значение \(value)")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(selected ? Color.dsPanel : (hovered ? Color.dsPanel.opacity(0.6) : .clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsAccLine, lineWidth: 1.5) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        // С клавиатуры: Tab — к строке, Пробел/Return — перейти, ⌫ — убрать значение.
        .focusable()
        .onKeyPress(.space) { select(); return .handled }
        .onKeyPress(.return) { select(); return .handled }
        .onKeyPress(.delete) { remove(); return .handled }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(place.hasPrefix("с.") ? "Страница " + place.dropFirst(2) : "Строка " + place), $\(value.isEmpty ? " пусто" : value)\(skipped ? ", пропущено" : "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Убрать значение", remove)
    }
}

/// Степпер Graphite: − число + в капсуле (в дизайн-системе своего нет).
struct GraphiteStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 0) {
            Button { value = max(range.lowerBound, value - 1) } label: {
                Image(systemName: "minus").frame(width: 22, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("Меньше")
            Text("\(value)").font(DS.Font.mono(13, relativeTo: .body)).foregroundStyle(.dsText).frame(minWidth: 18)
                .monospacedDigit()
            Button { value = min(range.upperBound, value + 1) } label: {
                Image(systemName: "plus").frame(width: 22, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(value >= range.upperBound)
            .accessibilityLabel("Больше")
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.dsMute)
        .capsuleFill(Color.dsPanel, border: Color.dsLine)
        .opacity(enabled ? 1 : DS.State.disabledOpacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }
}
