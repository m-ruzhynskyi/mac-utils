import AppKit
import SwiftUI

// Контролы Graphite (`.audit/design-spec-v2.md` §2): переключатель, кнопки, кнопка-иконка, чипы, сегменты, таблетки,
// прогресс, плитки инструментов. Состояния: наведение, нажатие, выключено (45 %), фокус (кольцо `accLine`).

// MARK: - Капсула с обводкой

extension View {
    /// Фон-капсула с обводкой: внешняя капсула цвета обводки, на ней — внутренняя с отступом `width`.
    /// (`Capsule().strokeBorder` даёт на концах плоские выступы за скруглённую заливку.)
    func capsuleFill(_ fill: Color, border: Color? = nil, width: CGFloat = 1) -> some View {
        background {
            if let border {
                Capsule().fill(border).overlay(Capsule().fill(fill).padding(width))
            } else {
                Capsule().fill(fill)
            }
        }
    }
}

// MARK: - Переключатель

/// Переключатель Graphite: дорожка 42×24, включён — лайм с тёмной ручкой справа, выключен — `off` с ручкой `mute` слева.
/// Семантика `Toggle` сохраняется (VoiceOver, клавиатура). Подпись не рисуется — её даёт строка (`ToggleRow`),
/// но остаётся именем для VoiceOver; `showsLabel` — подпись слева от дорожки.
struct GraphiteToggleStyle: ToggleStyle {
    var showsLabel = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Space.m) {
            if showsLabel {
                configuration.label.font(DS.Font.bodyStrong).foregroundStyle(.dsText)
                Spacer(minLength: DS.Space.s)
            } else {
                // Подпись невидима, но остаётся именем элемента для VoiceOver.
                configuration.label.frame(width: 0, height: 0).clipped().opacity(0).accessibilityHidden(false)
            }
            ToggleTrack(isOn: configuration.$isOn)
        }
        .accessibilityElement(children: .combine)
    }
}

extension ToggleStyle where Self == GraphiteToggleStyle {
    static var graphite: GraphiteToggleStyle { GraphiteToggleStyle() }
    static var graphiteLabeled: GraphiteToggleStyle { GraphiteToggleStyle(showsLabel: true) }
}

/// Дорожка переключателя.
struct ToggleTrack: View {
    @Binding var isOn: Bool

    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused

    var body: some View {
        let size = DS.Size.toggleTrack
        ZStack(alignment: isOn ? .trailing : .leading) {
            // Светлая тема: лайм и `off` почти сливаются с фоном — обводка даёт границу ≥ 3:1 (WCAG 1.4.11).
            Color.clear
                .capsuleFill(isOn ? Color.dsAcc : Color.dsOff, border: scheme == .light ? (isOn ? Color.dsAccLine : Color.dsLine) : nil)
            Circle()
                .fill(isOn ? Color.dsAccInk : Color.dsMute)
                .frame(width: DS.Size.toggleKnob, height: DS.Size.toggleKnob)
                .padding((size.height - DS.Size.toggleKnob) / 2)
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            if focused {
                Capsule().strokeBorder(Color.dsAccLine, lineWidth: DS.State.focusRing).padding(-DS.State.focusRing - 1)
            }
        }
        .opacity(enabled ? 1 : DS.State.disabledOpacity)
        .contentShape(Capsule())
        .onTapGesture { flip() }
        // Как у системных переключателей: фокус (и кольцо) — только при «Полной навигации с клавиатуры»,
        // иначе окно при открытии отдаёт фокус первому переключателю и рисует кольцо без причины.
        .focusable(enabled && NSApplication.shared.isFullKeyboardAccessEnabled)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            flip()
            return .handled
        }
    }

    private func flip() {
        guard enabled else { return }
        withAnimation(DS.Motion.animation(DS.Motion.toggle, reduceMotion: reduceMotion)) { isOn.toggle() }
    }
}

// MARK: - Кнопки

/// Кнопка Graphite: главная (лайм), вторичная (`field` + обводка), призрачная (без фона), разрушительная (`rec`).
struct GraphiteButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    enum Size { case compact, regular, large }

    var kind: Kind = .secondary
    var size: Size = .regular
    /// Растянуть на всю ширину.
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        GraphiteButtonBody(configuration: configuration, kind: kind, size: size, fill: fill)
    }
}

extension ButtonStyle where Self == GraphiteButtonStyle {
    static func graphite(_ kind: GraphiteButtonStyle.Kind = .secondary, size: GraphiteButtonStyle.Size = .regular,
                         fill: Bool = false) -> GraphiteButtonStyle {
        GraphiteButtonStyle(kind: kind, size: size, fill: fill)
    }
}

private struct GraphiteButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: GraphiteButtonStyle.Kind
    let size: GraphiteButtonStyle.Size
    let fill: Bool

    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    private var height: CGFloat {
        switch size {
        case .compact: return 30
        case .regular: return DS.Size.button
        case .large: return DS.Size.buttonLarge
        }
    }

    private var radius: CGFloat { size == .large ? DS.Radius.iconButton : DS.Radius.control }

    private var background: Color {
        switch kind {
        case .primary: return .dsAcc
        case .secondary: return .dsField
        case .ghost: return .clear
        case .danger: return .dsRec
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .dsAccInk
        case .secondary: return .dsText
        case .ghost: return .dsMute
        case .danger: return .dsRecInk
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return scheme == .light ? .dsAccLine : .clear
        case .secondary: return .dsLine
        case .ghost, .danger: return .clear
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let pressed = configuration.isPressed
        configuration.label
            .font(kind == .primary ? DS.Font.buttonPrimary : (size == .compact ? DS.Font.chip : DS.Font.button))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, size == .large ? DS.Space.xl : (size == .compact ? DS.Space.m : DS.Space.l))
            .frame(minHeight: height)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(background, in: shape)
            .overlay {
                // Наведение: светлее в тёмной теме, темнее в светлой.
                shape.fill((scheme == .dark ? Color.white : Color.black).opacity(hovered && enabled ? DS.State.hoverOverlay : 0))
            }
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .contentShape(shape)
            .opacity(enabled ? (pressed ? DS.State.pressedOpacity : 1) : DS.State.disabledOpacity)
            .scaleEffect(pressed ? DS.State.pressedScale : 1)
            .onHover { hovered = $0 }
    }
}

/// Кнопка-иконка 40×40: подпись обязательна — она и подсказка, и имя для VoiceOver. `active` — включённое состояние (лайм).
struct IconButton: View {
    let title: String
    let systemImage: String
    var active = false
    var compact = false
    let action: () -> Void

    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    init(_ title: String, systemImage: String, active: Bool = false, compact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.active = active
        self.compact = compact
        self.action = action
    }

    var body: some View {
        let side = compact ? DS.Size.rowTile : DS.Size.iconButton
        let shape = RoundedRectangle(cornerRadius: compact ? DS.Radius.control : DS.Radius.iconButton, style: .continuous)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 15 : 17, weight: .medium))
                .foregroundStyle(active ? Color.dsAccInk : Color.dsText)
                .frame(width: side, height: side)
                .background(active ? Color.dsAcc : Color.dsField, in: shape)
                .overlay {
                    shape.fill((scheme == .dark ? Color.white : Color.black).opacity(hovered && enabled ? DS.State.hoverOverlay : 0))
                }
                .overlay(shape.strokeBorder(active ? (scheme == .light ? Color.dsAccLine : .clear) : Color.dsLine, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle())
        .opacity(enabled ? 1 : DS.State.disabledOpacity)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Нажатие: лёгкое уменьшение и затемнение (для кнопок со своим фоном).
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? DS.State.pressedOpacity : 1)
            .scaleEffect(configuration.isPressed ? DS.State.pressedScale : 1)
    }
}

// MARK: - Чипы, сегменты, таблетки

/// Чип: выбран — лайм, иначе `field` с обводкой (например, вкладки панели в настройках).
struct Chip: View {
    let title: String
    var selected: Bool
    var action: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    init(_ title: String, selected: Bool, action: (() -> Void)? = nil) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    var body: some View {
        let label = Text(title)
            .font(selected ? DS.Font.chip : DS.Font.manrope(13, .semibold, relativeTo: .callout))
            .foregroundStyle(selected ? Color.dsAccInk : Color.dsMute)
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            .capsuleFill(selected ? Color.dsAcc : Color.dsField,
                         border: selected ? (scheme == .light ? Color.dsAccLine : nil) : Color.dsLine)
        if let action {
            Button(action: action) { label }
                .buttonStyle(PressScaleStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            label
        }
    }
}

/// Сегментный выбор (MP4 / GIF и т. п.): выбранный сегмент — лайм. ← → с клавиатуры.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused

    init(selection: Binding<Value>, options: [(value: Value, title: String)]) {
        _selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    select(option.value)
                } label: {
                    Text(option.title)
                        .font(on ? DS.Font.buttonPrimary : DS.Font.bodyStrong)
                        .foregroundStyle(on ? Color.dsAccInk : Color.dsMute)
                        .padding(.vertical, DS.Space.s)
                        .padding(.horizontal, DS.Space.xl)
                        .background(on ? Color.dsAcc : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(DS.Space.xs)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous)
            .strokeBorder(focused ? Color.dsAccLine : Color.dsLine, lineWidth: focused ? DS.State.focusRing : 1))
        .focusable(NSApplication.shared.isFullKeyboardAccessEnabled)
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard let index = options.firstIndex(where: { $0.value == selection }) else { return }
            switch direction {
            case .left where index > 0: select(options[index - 1].value)
            case .right where index < options.count - 1: select(options[index + 1].value)
            default: break
            }
        }
        .fixedSize()
    }

    private func select(_ value: Value) {
        withAnimation(DS.Motion.animation(DS.Motion.quick, reduceMotion: reduceMotion)) { selection = value }
    }
}

/// Таблетка статуса — мягкая, чтобы не путать с залитыми кнопками: капсула `field` с тонкой обводкой, точка цвета тона
/// и обычный текст («● Выдано», «● Нужно», «● Позже»). Цветной текст на `field` не ставим (контраст, §1.1).
/// `caps` — сигнал «В ЭФИРЕ» / «ЗАПИСЬ»: залитый цветом тона, капсом, как в концепте.
struct Pill: View {
    let tone: DS.Tone
    let text: String
    var caps = false

    @Environment(\.colorScheme) private var scheme

    init(_ tone: DS.Tone, _ text: String, caps: Bool = false) {
        self.tone = tone
        self.text = text
        self.caps = caps
    }

    var body: some View {
        if caps {
            Text(text.uppercased())
                .font(DS.Font.groupLabel)
                .tracking(DS.Font.tracking(0.06, size: 11))
                .foregroundStyle(tone.ink)
                .lineLimit(1)
                .padding(.vertical, DS.Space.xs)
                .padding(.horizontal, 10)
                .capsuleFill(tone.fill)
                .fixedSize()
        } else {
            HStack(spacing: 6) {
                Circle().fill(tone == .neutral ? Color.dsMute : tone.line).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(text)
                    .font(DS.Font.manrope(12, .bold, relativeTo: .caption))
                    .foregroundStyle(.dsText)
                    .lineLimit(1)
            }
            .padding(.vertical, DS.Space.xs)
            .padding(.leading, 9)
            .padding(.trailing, 11)
            .capsuleFill(Color.dsField, border: Color.dsLine)
            .fixedSize()
        }
    }
}

/// Полоса прогресса: 8 pt, `off` и лайм.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dsOff)
                Capsule().fill(Color.dsAcc).frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(max(value, 0), 1) * 100).rounded())) %")
    }
}

/// Плитка инструмента в сетке (как «Инструменты редактора» в концепте): значок, название, клавиша моноширинным.
struct ToolTile: View {
    let systemImage: String
    let title: String
    var key: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 15, weight: .medium)).foregroundStyle(.dsText).frame(width: 18)
                .accessibilityHidden(true)
            Text(title).font(DS.Font.manrope(13, .semibold, relativeTo: .callout)).foregroundStyle(.dsText)
                .lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            if let key, !key.isEmpty {
                Text(key).font(DS.Font.mono(11, relativeTo: .caption2)).foregroundStyle(.dsMute)
                    .accessibilityLabel(Keycap.spoken([key]))
            }
        }
        .padding(.vertical, DS.Space.s)
        .padding(.horizontal, 10)
        .background(Color.dsField, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Поле ввода и выбор

/// Поле ввода Graphite: `field`, обводка `line`, радиус 10; фокус — рамка `accLine`.
struct GraphiteFieldStyle: TextFieldStyle {
    var monospaced = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        GraphiteFieldBody(content: configuration, monospaced: monospaced)
    }
}

private struct GraphiteFieldBody<Content: View>: View {
    let content: Content
    let monospaced: Bool
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(monospaced ? DS.Font.mono : DS.Font.body)
            .foregroundStyle(.dsText)
            .focused($focused)
            .padding(.horizontal, DS.Space.m)
            .frame(minHeight: DS.Size.button)
            .background(Color.dsField, in: shape)
            .overlay(shape.strokeBorder(focused ? Color.dsAccLine : Color.dsLine, lineWidth: focused ? DS.State.focusRing : 1))
    }
}

extension TextFieldStyle where Self == GraphiteFieldStyle {
    static var graphite: GraphiteFieldStyle { GraphiteFieldStyle() }
    static var graphiteMono: GraphiteFieldStyle { GraphiteFieldStyle(monospaced: true) }
}

extension View {
    /// Выбор из списка в строке карточки: системное меню без подписи (подпись — заголовок строки), по ширине содержимого.
    func graphitePicker() -> some View {
        labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
    }
}
