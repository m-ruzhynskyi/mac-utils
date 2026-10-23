import AppKit
import SwiftUI

/// Плитка значка строки: 34×34, радиус 10. Обычная — `field` (в карточке `panel`) или `panel` с обводкой (в карточке `field`);
/// `accent` — лайм, `record` — красная (запись).
package struct RowTile: View {
    package init(systemImage: String, kind: Kind = .neutral) {
        self.systemImage = systemImage
        self.kind = kind
    }

    package enum Kind { case neutral, accent, record }

    package let systemImage: String
    package var kind: Kind = .neutral

    @Environment(\.dsCardStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var side = DS.Size.rowTile

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: side * 0.48, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: side, height: side)
            .background(background, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var foreground: Color {
        switch kind {
        case .neutral: return .dsText
        case .accent: return .dsAccInk
        case .record: return .dsRecInk
        }
    }

    private var background: Color {
        switch kind {
        case .neutral: return style == .panel ? .dsField : .dsPanel
        case .accent: return .dsAcc
        case .record: return .dsRec
        }
    }

    private var border: Color {
        switch kind {
        case .neutral: return style == .panel ? .clear : .dsLine
        case .accent: return scheme == .light ? .dsAccLine : .clear
        case .record: return .clear
        }
    }
}

/// Каркас строки карточки: слева — плитка или значок, заголовок, подпись, справа — контрол. Отступы и разделитель —
/// по виду карточки (`CardStyle`). Вся строка — один элемент VoiceOver.
package struct RowContainer<Leading: View, Trailing: View>: View {
    package let title: String
    package var subtitle: String?
    package let leading: Leading
    package let trailing: Trailing

    @Environment(\.dsCardStyle) private var style

    package init(_ title: String, subtitle: String? = nil, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    /// Меньше этой ширины тексту не оставляем: контрол уходит под текст (иначе узкая панель рвёт слова по буквам).
    private static var minTextWidth: CGFloat { 140 }

    package var body: some View {
        let spacing: CGFloat = style == .panel ? 14 : DS.Space.m
        ViewThatFits(in: .horizontal) {
            // Обычно — в одну строку; текст переносится по словам в оставшейся ширине (не меньше minTextWidth).
            HStack(spacing: spacing) {
                leading
                text.frame(minWidth: 0, idealWidth: Self.minTextWidth, maxWidth: .infinity, alignment: .leading)
                // Контролы не сжимаются (иначе подписи кнопок обрезаются многоточием); не помещаются — второй вариант.
                trailing.fixedSize(horizontal: true, vertical: false)
            }
            // Узко — контрол под текстом, с отступом под плиткой.
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .top, spacing: spacing) {
                    leading
                    text.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: DS.Space.s) { trailing }
            }
        }
        .padding(.vertical, style == .panel ? 13 : DS.Space.s)
        .padding(.horizontal, style == .panel ? 18 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            // Разделитель сверху; у первой строки он совпадает с обводкой карточки.
            if style == .panel { Rectangle().fill(Color.dsLine).frame(height: 1).accessibilityHidden(true) }
        }
        .accessibilityElement(children: .combine)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(style == .panel ? DS.Font.rowTitle : DS.Font.bodyStrong)
                .foregroundStyle(.dsText)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(DS.Font.rowSub)
                    .foregroundStyle(.dsMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Строка карточки: плитка со значком, заголовок, подпись, контрол справа.
package struct Row<Trailing: View>: View {
    package var systemImage: String?
    package let title: String
    package var subtitle: String?
    package var tile: RowTile.Kind = .neutral
    package let trailing: Trailing

    package init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tile: RowTile.Kind = .neutral,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tile = tile
        self.trailing = trailing()
    }

    package var body: some View {
        RowContainer(title, subtitle: subtitle) {
            if let systemImage { RowTile(systemImage: systemImage, kind: tile) }
        } trailing: {
            trailing
        }
    }
}

/// Строка программы: настоящий значок программы (по bundle id или пути), если она найдена, иначе — плитка с `fallbackSymbol`.
package struct AppRow<Trailing: View>: View {
    package let title: String
    package var subtitle: String?
    package var bundleID: String?
    package var url: URL?
    package var fallbackSymbol = "app.dashed"
    package let trailing: Trailing

    @ScaledMetric(relativeTo: .body) private var side = DS.Size.rowTile

    package init(_ title: String, subtitle: String? = nil, bundleID: String? = nil, url: URL? = nil, fallbackSymbol: String = "app.dashed",
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.bundleID = bundleID
        self.url = url
        self.fallbackSymbol = fallbackSymbol
        self.trailing = trailing()
    }

    private var appURL: URL? {
        url ?? bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    package var body: some View {
        RowContainer(title, subtitle: subtitle) {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: side, height: side)
                    .accessibilityHidden(true)
            } else {
                RowTile(systemImage: fallbackSymbol)
            }
        } trailing: {
            trailing
        }
    }
}

extension Row where Trailing == EmptyView {
    package init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tile: RowTile.Kind = .neutral) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, tile: tile) { EmptyView() }
    }
}

/// Строка с переключателем Graphite: клик по всей строке переключает.
package struct ToggleRow: View {
    package let title: String
    package var subtitle: String?
    package var systemImage: String?
    @Binding package var isOn: Bool

    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        _isOn = isOn
    }

    package var body: some View {
        Row(title, subtitle: subtitle, systemImage: systemImage) {
            Toggle(title, isOn: $isOn).toggleStyle(.graphite)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard enabled else { return }
            withAnimation(DS.Motion.animation(DS.Motion.toggle, reduceMotion: reduceMotion)) { isOn.toggle() }
        }
        .opacity(enabled ? 1 : DS.State.disabledOpacity)
    }
}

/// Строка «действие — сочетание»: заголовок слева, кейкап справа (сочетание из реестра).
package struct KeyRow: View {
    package let title: String
    private let keycap: Keycap

    @Environment(\.dsCardStyle) private var style

    package init(_ title: String, keys: [String]) {
        self.title = title
        keycap = Keycap(keys)
    }

    package init(_ title: String, keycap: Keycap) {
        self.title = title
        self.keycap = keycap
    }

    package var body: some View {
        Row(title) { keycap }
    }
}

/// Ползунок со значением справа фиксированной ширины.
package struct SliderRow: View {
    package let title: String
    package var subtitle: String?
    package var systemImage: String?
    @Binding package var value: Double
    package let range: ClosedRange<Double>
    package let format: (Double) -> String

    @ScaledMetric(relativeTo: .body) private var valueWidth: CGFloat = 52

    package init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, value: Binding<Double>,
         in range: ClosedRange<Double>, format: @escaping (Double) -> String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        _value = value
        self.range = range
        self.format = format
    }

    package var body: some View {
        Row(title, subtitle: subtitle, systemImage: systemImage) {
            HStack(spacing: DS.Space.m) {
                Slider(value: $value, in: range)
                    .tint(.dsAccLine)
                    .frame(minWidth: 160, maxWidth: 240)
                    .accessibilityLabel(title)
                    .accessibilityValue(format(value))
                Text(format(value))
                    .font(DS.Font.mono(13, relativeTo: .callout))
                    .foregroundStyle(.dsMute)
                    .frame(minWidth: valueWidth, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Плашка пути: `field`, обводка, радиус 10; середина обрезается, полный путь — в подсказке.
package struct PathChip: View {
    package let url: URL
    package var display: String?

    private var text: String {
        if let display { return display }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    package var body: some View {
        Text(text)
            .font(DS.Font.manrope(13, .regular, relativeTo: .callout))
            .foregroundStyle(.dsText)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.vertical, 7)
            .padding(.horizontal, DS.Space.m)
            .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            .help(url.path)
    }
}

/// Папка: плашка пути, «Выбрать…», «Показать в Finder», «Сбросить» (если выбрана своя).
package struct PathRow: View {
    package let title: String
    package var subtitle: String?
    package var systemImage: String?
    package let url: URL
    package var display: String?
    package let isCustom: Bool
    package let choose: () -> Void
    package let reset: () -> Void
    package let resetHelp: String

    package init(_ title: String, subtitle: String? = nil, systemImage: String? = "folder", url: URL, display: String? = nil,
         isCustom: Bool, choose: @escaping () -> Void, reset: @escaping () -> Void, resetHelp: String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.url = url
        self.display = display
        self.isCustom = isCustom
        self.choose = choose
        self.reset = reset
        self.resetHelp = resetHelp
    }

    package var body: some View {
        Row(title, subtitle: subtitle, systemImage: systemImage) {
            HStack(spacing: DS.Space.s) {
                PathChip(url: url, display: display).frame(maxWidth: 220)
                Button("Выбрать…", action: choose).buttonStyle(.graphite(.secondary, size: .compact))
                IconButton("Показать в Finder", systemImage: "folder", compact: true) { NSWorkspace.shared.open(url) }
                if isCustom { IconButton(resetHelp, systemImage: "arrow.uturn.backward", compact: true, action: reset) }
            }
        }
    }
}
