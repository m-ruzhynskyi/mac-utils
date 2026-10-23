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
