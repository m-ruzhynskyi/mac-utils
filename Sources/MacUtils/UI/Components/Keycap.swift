import SwiftUI
import MUCore

/// Кейкап сочетания: JetBrains Mono, фон `field`, обводка 1 pt и нижняя грань 3 pt, радиус 7.
/// VoiceOver читает словами («Control Option M»). `onPanel` — фон `panel` (для строк поповера на `field`).
struct Keycap: View {
    private let fixedKeys: [String]?
    private let resolveKeys: (() -> [String])?
    var compact = false
    var onPanel = false
    @ObservedObject private var changes = DefaultsChanges.shared

    init(_ keys: [String], compact: Bool = false, onPanel: Bool = false) {
        fixedKeys = keys
        resolveKeys = nil
        self.compact = compact
        self.onPanel = onPanel
    }

    init(_ hotKey: LayoutHotKey, compact: Bool = false, onPanel: Bool = false) {
        self.init(hotKey.keys, compact: compact, onPanel: onPanel)
    }

    /// Клавиши, которые спрашиваются при каждой отрисовке (сочетание из реестра: после переназначения показывается новое).
    init(resolving keys: @escaping () -> [String], compact: Bool = false, onPanel: Bool = false) {
        fixedKeys = nil
        resolveKeys = keys
        self.compact = compact
        self.onPanel = onPanel
    }

    private var keys: [String] { fixedKeys ?? resolveKeys?() ?? [] }

    /// Символы клавиш-модификаторов: в JetBrains Mono они мелкие — рисуем их системным моноширинным шрифтом.
    static let modifierSymbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘", "↩", "⌫", "⎋", "⇥", "←", "→", "↑", "↓"]

    /// Текст кейкапа: буквы — JetBrains Mono, модификаторы — системный моноширинный того же размера.
    static func label(_ text: String, compact: Bool) -> Text {
        let size: CGFloat = compact ? 12 : 13
        var result = Text("")
        var run = "", runIsSymbol = false
        func flush() {
            guard !run.isEmpty else { return }
            let piece = Text(run)
            result = result + (runIsSymbol ? piece.font(.system(size: size, weight: .medium, design: .monospaced))
                                           : piece.font(compact ? DS.Font.keycapCompact : DS.Font.keycap))
            run = ""
        }
        for char in text {
            let symbol = modifierSymbols.contains(char)
            if symbol != runIsSymbol { flush(); runIsSymbol = symbol }
            run.append(char)
        }
        flush()
        return result
    }

    var body: some View {
        Self.label(keys.joined(), compact: compact)
            .foregroundStyle(.dsText)
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 3)
            .padding(.horizontal, compact ? DS.Space.s : 10)
            .background(onPanel ? Color.dsPanel : Color.dsField,
                        in: RoundedRectangle(cornerRadius: DS.Radius.keycap - 1, style: .continuous))
            // Обводка 1 pt по бокам и сверху, 3 pt снизу — «нижняя грань» клавиши.
            .padding(EdgeInsets(top: 1, leading: 1, bottom: 3, trailing: 1))
            .background(Color.dsLine, in: RoundedRectangle(cornerRadius: DS.Radius.keycap, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel(Self.spoken(keys))
    }

    /// Названия клавиш для VoiceOver.
    static func spoken(_ keys: [String]) -> String {
        let names: [Character: String] = [
            "⌃": "Control", "⌥": "Option", "⌘": "Command", "⇧": "Shift", "↩": "Return", "⌫": "Delete", "⎋": "Escape",
            "←": "Left Arrow", "→": "Right Arrow", "↑": "Up Arrow", "↓": "Down Arrow", "⇥": "Tab", "␣": "Space",
        ]
        return keys.flatMap { key -> [String] in
            // «⌃⌥» в одном элементе разбираем по символам; «Tab», «Esc», «1…7» оставляем как есть.
            if key.count > 1, key.allSatisfy({ names[$0] != nil }) { return key.map { names[$0]! } }
            if key.count == 1, let char = key.first, let name = names[char] { return [name] }
            return [key]
        }
        .joined(separator: " ")
    }
}

/// Строка шпаргалки: кейкап в колонке слева, текст справа (сочетания и подсказки страниц).
struct ShortcutHintRow: View {
    private let keycap: Keycap
    let text: String

    @ScaledMetric(relativeTo: .body) private var column = DS.Size.shortcutColumn

    init(keys: [String], text: String) {
        keycap = Keycap(keys, compact: true)
        self.text = text
    }

    init(keycap: Keycap, text: String) {
        self.keycap = keycap
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            keycap.frame(minWidth: column, alignment: .leading)
            Text(text).font(DS.Font.body).foregroundStyle(.dsText).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Строка подсказки в карточке (`ListCard`, `CollapsibleCard`): кейкап в колонке слева, текст справа, отступы и
/// разделитель — как у строк карточки.
struct HintRow: View {
    private let keycap: Keycap
    let text: String

    @Environment(\.dsCardStyle) private var style
    @ScaledMetric(relativeTo: .body) private var column = DS.Size.shortcutColumn

    init(keys: [String], text: String) {
        keycap = Keycap(keys, compact: true)
        self.text = text
    }

    init(keycap: Keycap, text: String) {
        self.keycap = keycap
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            keycap.frame(minWidth: column, alignment: .leading)
            Text(text).font(DS.Font.body).foregroundStyle(.dsText).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, style == .panel ? 11 : DS.Space.s)
        .padding(.horizontal, style == .panel ? 18 : 10)
        .overlay(alignment: .top) {
            if style == .panel { Rectangle().fill(Color.dsLine).frame(height: 1).accessibilityHidden(true) }
        }
        .accessibilityElement(children: .combine)
    }
}
