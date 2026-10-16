import SwiftUI

/// Плитка шапки страницы: 46×46, радиус 14, лайм, значок раздела цветом `accInk`.
struct HeaderTile: View {
    let systemImage: String
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var side = DS.Size.headerTile

    var body: some View {
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
struct PageHeader<Accessory: View>: View {
    let section: SettingsSection
    var subtitle: String?
    var isOn: Binding<Bool>?
    var toggleLabel: String?
    let accessory: Accessory

    init(_ section: SettingsSection, subtitle: String? = nil, isOn: Binding<Bool>? = nil, toggleLabel: String? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.section = section
        self.subtitle = subtitle
        self.isOn = isOn
        self.toggleLabel = toggleLabel
        self.accessory = accessory()
    }

    private var text: String { subtitle ?? section.subtitle }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
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
            Spacer(minLength: DS.Space.m)
            accessory
            if let isOn {
                Toggle(toggleLabel ?? section.title, isOn: isOn).toggleStyle(.graphite)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(_ section: SettingsSection, subtitle: String? = nil, isOn: Binding<Bool>? = nil, toggleLabel: String? = nil) {
        self.init(section, subtitle: subtitle, isOn: isOn, toggleLabel: toggleLabel) { EmptyView() }
    }
}

/// Заголовок группы: точка `accLine` и капс 11/800 цветом `mute`.
struct GroupLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
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
struct SettingsPage<Content: View, Accessory: View>: View {
    let section: SettingsSection
    var subtitle: String?
    var isOn: Binding<Bool>?
    var toggleLabel: String?
    let accessory: Accessory
    let content: Content

    init(_ section: SettingsSection, subtitle: String? = nil, isOn: Binding<Bool>? = nil, toggleLabel: String? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.section = section
        self.subtitle = subtitle
        self.isOn = isOn
        self.toggleLabel = toggleLabel
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                PageHeader(section, subtitle: subtitle, isOn: isOn, toggleLabel: toggleLabel) { accessory }
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
    init(_ section: SettingsSection, subtitle: String? = nil, isOn: Binding<Bool>? = nil, toggleLabel: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(section, subtitle: subtitle, isOn: isOn, toggleLabel: toggleLabel, accessory: { EmptyView() }, content: content)
    }
}
