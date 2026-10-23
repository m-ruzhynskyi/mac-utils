import AppKit
import SwiftUI
import MUCore

// MARK: - Панель в строке меню

struct PanelSettingsPage: View {
    @ObservedObject private var hotKeys = HotKeyPrefs.shared
    @AppStorage(Pref.menuBarIcon) private var menuBarIcon = true
    @AppStorage(Pref.toolsPanelTabs) private var panelTabs = PanelTabs.defaultValue

    private func tabBinding(_ section: SettingsSection) -> Binding<Bool> {
        Binding(get: { PanelTabs.sections(panelTabs).contains(section) }, set: { show in
            var list = PanelTabs.sections(panelTabs)
            if show { list.append(section) } else { list.removeAll { $0 == section } }
            // Хотя бы одна вкладка остаётся; новая — в конец ряда.
            guard !list.isEmpty else { return }
            panelTabs = PanelTabs.value(list)
        })
    }

    private func move(_ section: SettingsSection, by offset: Int) {
        var list = PanelTabs.sections(panelTabs)
        guard let index = list.firstIndex(of: section), list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        panelTabs = PanelTabs.value(list)
    }

    /// Перетащили вкладку `dragged` на место `target`: она встаёт перед ней (или после, если тащили сверху вниз).
    private func drop(_ dragged: String, onto target: SettingsSection) -> Bool {
        guard let section = SettingsSection(rawValue: dragged), section != target else { return false }
        var list = PanelTabs.sections(panelTabs)
        guard let from = list.firstIndex(of: section), let to = list.firstIndex(of: target) else { return false }
        list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        panelTabs = PanelTabs.value(list)
        return true
    }

    var body: some View {
        SettingsPage(.panel, isOn: $menuBarIcon, toggleLabel: "Значок 🔧 в строке меню") {
            Footnote("Настройки, тёплый экран и выход — в шапке панели.")
            GroupLabel("Порядок вкладок")
            let order = PanelTabs.sections(panelTabs)
            ListCard {
                ForEach(Array(order.enumerated()), id: \.element) { index, section in
                    Row(section.title, systemImage: section.symbol) {
                        IconButton("Левее", systemImage: "chevron.up", compact: true) { move(section, by: -1) }
                            .disabled(index == 0)
                        IconButton("Правее", systemImage: "chevron.down", compact: true) { move(section, by: 1) }
                            .disabled(index == order.count - 1)
                        Image(systemName: "line.3.horizontal").foregroundStyle(.dsMute).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .draggable(section.rawValue)
                    .dropDestination(for: String.self) { items, _ in
                        items.first.map { drop($0, onto: section) } ?? false
                    }
                }
            }
            .disabled(!menuBarIcon)
            Footnote("Сверху вниз — слева направо в панели. Перетащите строку или нажмите стрелки.")
            GroupLabel("Вкладки панели")
            Card {
                Text("Любые возможности Mac Utils — отметьте, что должно быть под рукой. Если вкладок много, их ряд листается вбок.")
                    .font(DS.Font.body).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
                FlowLayout {
                    ForEach(PanelTabs.available) { section in
                        let shown = tabBinding(section)
                        Chip(shown.wrappedValue ? section.title : "+ " + section.title, selected: shown.wrappedValue) {
                            shown.wrappedValue.toggle()
                        }
                        .accessibilityLabel(section.title)
                        .accessibilityValue(shown.wrappedValue ? "Показана" : "Скрыта")
                    }
                }
            }
            .disabled(!menuBarIcon)
        }
    }
}
