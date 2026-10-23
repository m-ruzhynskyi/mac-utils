import SwiftUI

/// Плитка шапки страницы: 46×46, радиус 14, лайм, значок раздела цветом `accInk`.
package struct HeaderTile: View {
    package let systemImage: String
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var side = DS.Size.headerTile

    package init(systemImage: String) { self.systemImage = systemImage }

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: side * 0.48, weight: .medium))
            .foregroundStyle(.dsAccInk)
            .frame(width: side, height: side)
            .background(Color.dsAcc, in: shape)
            .overlay(shape.strokeBorder(scheme == .light ? Color.dsAccLine : .clear, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Шапка страницы настроек: лаймовая плитка, заголовок, подзаголовок, справа — дополнительный контрол и главный переключатель.
package struct PageHeader<Accessory: View>: View {
    package let section: SettingsSection
    package var subtitle: String?
    package var isOn: Binding<Bool>?
    package var toggleLabel: String?
    /// Переключатель виден, но недоступен (например, функция не поддерживается этой macOS).
    package var toggleEnabled = true
    package let accessory: Accessory

    package init(_ section: SettingsSection, subtitle: String? = nil, isOn: Binding<Bool>? = nil, toggleLabel: String? = nil,
         toggleEnabled: Bool = true, @ViewBuilder accessory: () -> Accessory) {
        self.section = section
        self.subtitle = subtitle
        self.isOn = isOn
        self.toggleLabel = toggleLabel
        self.toggleEnabled = toggleEnabled
        self.accessory = accessory()
    }

    private var text: String { subtitle ?? section.subtitle }

    @ScaledMetric(relativeTo: .largeTitle) private var tileSide = DS.Size.headerTile

    package var body: some View {
        // По верху: при подзаголовке в 2–3 строки плитка остаётся рядом с заголовком, а переключатель — по центру плитки.
        HStack(alignment: .top, spacing: 14) {
            HeaderTile(systemImage: section.symbol)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(section.title)
                    .font(DS.Font.display)
                    .tracking(DS.Font.tracking(-0.02, size: 26))
                    .foregroundStyle(.dsText)
                    .accessibilityAddTraits(.isHeader)
                if !text.isEmpty {
                    Text(text)
                        .font(DS.Font.body)
                        .foregroundStyle(.dsMute)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: tileSide)
            Spacer(minLength: DS.Space.m)
            HStack(spacing: DS.Space.m) {
                accessory
                if let isOn {
                    Toggle(toggleLabel ?? section.title, isOn: isOn).toggleStyle(.graphite).disabled(!toggleEnabled)
                }
            }
            .frame(height: tileSide)
        }
        .accessibilityElement(children: .contain)
    }
}

extension PageHeader where Accessory == EmptyView {
    package init(_ section: SettingsSection, subtitle: String? = nil, isOn: Binding<Bool>? = nil, toggleLabel: String? = nil,
         toggleEnabled: Bool = true) {
        self.init(section, subtitle: subtitle, isOn: isOn, toggleLabel: toggleLabel, toggleEnabled: toggleEnabled) { EmptyView() }
    }
}

/// Заголовок группы: точка `accLine` и капс 11/800 цветом `mute`.
package struct GroupLabel: View {
    package let title: String

    package init(_ title: String) { self.title = title }

    package var body: some View {
        HStack(spacing: DS.Space.s) {
            Circle().fill(Color.dsAccLine).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(title.uppercased())
                .font(DS.Font.groupLabel)
                .tracking(DS.Font.tracking(0.12, size: 11))
                .foregroundStyle(.dsMute)
        }
        .padding(.top, DS.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Страница настроек Graphite: фон `bg`, поля 30×36, шапка, затем блоки через 18 pt; ширина содержимого ≤ 760, по центру.
package struct SettingsPage<Content: View, Accessory: View>: View {
    package let section: SettingsSection
    package var subtitle: String?
    package var isOn: Binding<Bool>?
    package var toggleLabel: String?
    package var toggleEnabled = true
    package let accessory: Accessory
    package let content: Content

    package init(_ section: SettingsSection, subtitle: String? = nil, isOn: Binding<Bool>? = nil, toggleLabel: String? = nil,
         toggleEnabled: Bool = true, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.section = section
        self.subtitle = subtitle
        self.isOn = isOn
        self.toggleLabel = toggleLabel
        self.toggleEnabled = toggleEnabled
        self.accessory = accessory()
        self.content = content()
    }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                PageHeader(section, subtitle: subtitle, isOn: isOn, toggleLabel: toggleLabel, toggleEnabled: toggleEnabled) { accessory }
                content
            }
            .padding(.vertical, DS.Space.pageVertical)
            .padding(.horizontal, DS.Space.pageHorizontal)
            .frame(maxWidth: DS.Size.contentMaxWidth + 2 * DS.Space.pageHorizontal, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dsBg)
        .navigationTitle(section.title)
    }
}

extension SettingsPage where Accessory == EmptyView {
    package init(_ section: SettingsSection, subtitle: String? = nil, isOn: Binding<Bool>? = nil, toggleLabel: String? = nil,
         toggleEnabled: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(section, subtitle: subtitle, isOn: isOn, toggleLabel: toggleLabel, toggleEnabled: toggleEnabled,
                  accessory: { EmptyView() }, content: content)
    }
}

/// Сноска под карточкой или шапкой: мелкий текст `mute` с отступом как у строк карточки.
package struct Footnote: View {
    package let text: String

    package init(_ text: String) { self.text = text }

    package var body: some View {
        Text(text)
            .font(DS.Font.rowSub)
            .foregroundStyle(.dsMute)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.top, -DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
