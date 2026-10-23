import SwiftUI

/// Рама страницы-инструмента. В окне настроек: фон `bg`, шапка `PageHeader`, поля как у страниц настроек;
/// в панели из строки меню (`compact`) — только содержимое.
package struct ToolsPageFrame<Accessory: View, Content: View>: View {
    package let section: SettingsSection
    package var compact = false
    package let accessory: Accessory
    package let content: Content

    package init(_ section: SettingsSection, compact: Bool, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.section = section
        self.compact = compact
        self.accessory = accessory()
        self.content = content()
    }

    package var body: some View {
        if compact {
            content
        } else {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                PageHeader(section) { accessory }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, DS.Space.pageVertical)
            .padding(.horizontal, DS.Space.pageHorizontal)
            .padding(.bottom, DS.Space.xl)
            .frame(maxWidth: DS.Size.contentMaxWidth + 2 * DS.Space.pageHorizontal, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.dsBg)
            .navigationTitle(section.title)
        }
    }
}
/// Поле поиска: `field`, обводка `line`, радиус 10, лупа.
package struct ToolsSearchField: View {
    package init(prompt: String, text: Binding<String>) {
        self.prompt = prompt
        self._text = text
    }

    package let prompt: String
    @Binding package var text: String

    @FocusState private var focused: Bool

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.dsMute)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Color.dsMute))
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(.dsText)
                .focused($focused)
                .accessibilityLabel(prompt)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.dsField, in: shape)
        .overlay(shape.strokeBorder(focused ? Color.dsAccLine : Color.dsLine, lineWidth: focused ? DS.State.focusRing : 1))
    }
}

extension ToolsPageFrame where Accessory == EmptyView {
    package init(_ section: SettingsSection, compact: Bool, @ViewBuilder content: () -> Content) {
        self.init(section, compact: compact, accessory: { EmptyView() }, content: content)
    }
}
/// Сегментный выбор на всю доступную ширину (сегменты равной ширины): `panel` + `line`, радиус 12, выбранный — лайм.
/// Свой, потому что `Segmented` из компонентов имеет фиксированную ширину.
package struct ToolsSegmented<Value: Hashable>: View {
    @Binding package var selection: Value
    package let options: [(value: Value, title: String)]

    package init(selection: Binding<Value>, options: [(value: Value, title: String)]) {
        self._selection = selection
        self.options = options
    }

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous)
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(on ? DS.Font.buttonPrimary : DS.Font.bodyStrong)
                        .foregroundStyle(on ? Color.dsAccInk : Color.dsMute)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(on ? Color.dsAcc : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(DS.Space.xs)
        .frame(maxWidth: .infinity)
        .background(Color.dsPanel, in: shape)
        .overlay(shape.strokeBorder(Color.dsLine, lineWidth: 1))
    }
}
