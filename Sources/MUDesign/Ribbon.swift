import SwiftUI

// Лента «Документа» (макет `.audit/word-ui-design`, раздел «лента»): вкладки сверху на фоне `side`, под ними полоса групп на `panel`.
// Не копия Office: группы — плитки с подписью и лаймовой точкой снизу, выбранная вкладка — лаймовая черта сверху,
// включённая кнопка — лаймовая заливка (как выбранный сегмент). Контекстная вкладка («Таблица», «Колонтитулы») — синяя.

extension DS {
    /// Размеры ленты (CSS макета: `.rt`, `.b`, `.b.big`, `.fld`, `.g`).
    package enum RibbonMetrics {
        package static let tabRadius: CGFloat = 12
        package static let button: CGFloat = 30
        package static let buttonRadius: CGFloat = 9
        package static let largeButton = CGSize(width: 56, height: 62)
        package static let field: CGFloat = 30
        package static let groupPadding: CGFloat = 10
        /// Черта сверху у выбранной вкладки.
        package static let tabStripe: CGFloat = 2
    }

    /// Вкладка ленты: заголовок и признак контекстной (синей) вкладки.
    package struct RibbonTabItem: Identifiable, Hashable {
        package let id: String
        package let title: String
        package var contextual = false

        package init(_ id: String, _ title: String, contextual: Bool = false) {
            self.id = id
            self.title = title
            self.contextual = contextual
        }
    }

    /// Лента целиком: строка вкладок (контекстные — после обычных, синие) и полоса групп выбранной вкладки.
    /// Двойной щелчок по вкладке вызывает `onDoubleClick` (сворачивание — забота владельца, R1).
    package struct Ribbon<Content: View>: View {
        package let tabs: [RibbonTabItem]
        @Binding package var selection: String
        package var collapsed = false
        package var onDoubleClick: (() -> Void)?
        @ViewBuilder package let content: () -> Content

        package init(tabs: [RibbonTabItem], selection: Binding<String>, collapsed: Bool = false,
                     onDoubleClick: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
            self.tabs = tabs
            self._selection = selection
            self.collapsed = collapsed
            self.onDoubleClick = onDoubleClick
            self.content = content
        }

        package var body: some View {
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: DS.Space.xxs) {
                    ForEach(tabs) { tab in
                        RibbonTab(tab.title, selected: !collapsed && tab.id == selection, contextual: tab.contextual) {
                            selection = tab.id
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick?() })
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, DS.Space.s)
                if !collapsed {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) { content() }
                            .padding(.vertical, DS.Space.s)
                            .padding(.horizontal, DS.Space.xs)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Высота — по самой высокой группе, а не всё, что предложит родитель (подписи групп — на одной линии).
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.dsPanel)
                    .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 1) }
                }
            }
            .background(Color.dsSide)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Лента")
        }
    }

    /// Вкладка ленты. Выбранная — фон `panel` и черта сверху (лайм; у контекстной — синяя); контекстная — синий текст и точка.
    package struct RibbonTab: View {
        package let title: String
        package let selected: Bool
        package var contextual = false
        package let action: () -> Void
        // Внутри `extension DS` имя `State` — токены `DS.State`; обёртка SwiftUI — только с полным именем (иначе CI не собирает).
        @SwiftUI.State private var hovered = false

        package init(_ title: String, selected: Bool, contextual: Bool = false, action: @escaping () -> Void) {
            self.title = title
            self.selected = selected
            self.contextual = contextual
            self.action = action
        }

        package var body: some View {
            let shape = UnevenRoundedRectangle(topLeadingRadius: RibbonMetrics.tabRadius, topTrailingRadius: RibbonMetrics.tabRadius,
                                               style: .continuous)
            let stripe = contextual ? Color.dsBlue : Color.dsAccLine
            Button(action: action) {
                HStack(spacing: 6) {
                    if contextual { Circle().fill(Color.dsBlue).frame(width: 6, height: 6).accessibilityHidden(true) }
                    Text(title).font(DS.Font.manrope(13, .bold, relativeTo: .callout)).lineLimit(1)
                }
                .foregroundStyle(contextual ? Color.dsBlue : (selected || hovered ? Color.dsText : Color.dsMute))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Color.dsPanel : .clear, in: shape)
                .overlay(alignment: .top) {
                    if selected { stripe.frame(height: RibbonMetrics.tabStripe).clipShape(shape) }
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(contextual ? "\(title), контекстная вкладка" : title)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        }
    }

    /// Группа ленты: кнопки в строку, под ними подпись капсом с лаймовой точкой; справа — разделитель (кроме последней).
    package struct RibbonGroup<Content: View>: View {
        package let title: String
        package var last = false
        @ViewBuilder package let content: () -> Content

        package init(_ title: String, last: Bool = false, @ViewBuilder content: @escaping () -> Content) {
            self.title = title
            self.last = last
            self.content = content
        }

        package var body: some View {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(alignment: .center, spacing: DS.Space.xxs) { content() }
                    .frame(maxHeight: .infinity, alignment: .center)
                HStack(spacing: 5) {
                    Circle().fill(Color.dsAccLine).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(title.uppercased())
                        .font(DS.Font.manrope(10.5, .bold, relativeTo: .caption2))
                        .tracking(DS.Font.tracking(0.07, size: 10.5))
                        .foregroundStyle(.dsMute)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, RibbonMetrics.groupPadding)
            .fixedSize(horizontal: true, vertical: false)
            .overlay(alignment: .trailing) {
                if !last { Rectangle().fill(Color.dsLine).frame(width: 1) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
    }

    /// Кнопка-плитка ленты: малая (30 pt — значок и/или короткий текст) или большая (62 pt — значок над подписью).
    /// Включённая (`isOn`, например «Ж» на жирном тексте) — лаймовая заливка; наведение — `field` с обводкой.
    package struct RibbonButton: View {
        package enum Size { case small, large }

        package let title: String
        package var systemImage: String?
        package var size: Size = .small
        package var isOn = false
        /// Короткая надпись вместо значка (Ж, К, Ч, A▲); для подсказки и VoiceOver — `title`.
        package var glyph: String?
        package var shortcut: String?
        package let action: () -> Void

        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorScheme) private var scheme
        @SwiftUI.State private var hovered = false

        package init(_ title: String, systemImage: String? = nil, glyph: String? = nil, size: Size = .small, isOn: Bool = false,
                     shortcut: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.glyph = glyph
            self.size = size
            self.isOn = isOn
            self.shortcut = shortcut
            self.action = action
        }

        package var body: some View {
            let shape = RoundedRectangle(cornerRadius: RibbonMetrics.buttonRadius, style: .continuous)
            Button(action: action) {
                label
                    .foregroundStyle(isOn ? Color.dsAccInk : Color.dsText)
                    .padding(.horizontal, 7)
                    .frame(minWidth: size == .large ? RibbonMetrics.largeButton.width : RibbonMetrics.button,
                           minHeight: size == .large ? RibbonMetrics.largeButton.height : RibbonMetrics.button)
                    .background(background, in: shape)
                    .overlay(shape.strokeBorder(border, lineWidth: 1))
                    .contentShape(shape)
            }
            .buttonStyle(PressScaleStyle())
            .fixedSize()  // подписи плиток не сжимаются: тесно — ужимает владелец ленты (уровни R1)
            .opacity(enabled ? 1 : DS.State.disabledOpacity)
            .onHover { hovered = $0 }
            .help(shortcut.map { "\(title) (\($0))" } ?? title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }

        @ViewBuilder private var label: some View {
            switch size {
            case .small:
                HStack(spacing: 5) {
                    if let systemImage { Image(systemName: systemImage).font(.system(size: 14, weight: .medium)) }
                    if let glyph { Text(glyph).font(DS.Font.manrope(13, .bold, relativeTo: .callout)) }
                }
            case .large:
                VStack(spacing: 3) {
                    if let systemImage { Image(systemName: systemImage).font(.system(size: 22, weight: .regular)).frame(height: 24) }
                    Text(glyph ?? title).font(DS.Font.manrope(11.5, .semibold, relativeTo: .caption)).lineLimit(1)
                }
            }
        }

        private var background: Color {
            if isOn { return .dsAcc }
            return hovered && enabled ? .dsField : .clear
        }

        private var border: Color {
            if isOn { return scheme == .light ? .dsAccLine : .clear }
            return hovered && enabled ? .dsLine : .clear
        }
    }

    /// Поле-выпадашка ленты (шрифт, размер, интервал): значение на `field` с обводкой и шевроном; щелчок — меню.
    package struct RibbonField<Items: View>: View {
        package let title: String
        package let value: String
        package var width: CGFloat?
        @ViewBuilder package let items: () -> Items
        @Environment(\.isEnabled) private var enabled

        package init(_ title: String, value: String, width: CGFloat? = nil, @ViewBuilder items: @escaping () -> Items) {
            self.title = title
            self.value = value
            self.width = width
            self.items = items
        }

        package var body: some View {
            let shape = RoundedRectangle(cornerRadius: RibbonMetrics.buttonRadius, style: .continuous)
            Menu(content: items) {
                HStack(spacing: 6) {
                    Text(value).font(DS.Font.manrope(13, .semibold, relativeTo: .callout)).foregroundStyle(.dsText).lineLimit(1)
                    if width != nil { Spacer(minLength: 0) }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.dsMute)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 9)
                .frame(width: width, height: RibbonMetrics.field)
                .background(Color.dsField, in: shape)
                .overlay(shape.strokeBorder(Color.dsLine, lineWidth: 1))
                .contentShape(shape)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(enabled ? 1 : DS.State.disabledOpacity)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityValue(value)
        }
    }
}
