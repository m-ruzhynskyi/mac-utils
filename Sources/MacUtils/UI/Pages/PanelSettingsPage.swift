import AppKit
import SwiftUI

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

    var body: some View {
        Form {
            Section {
                Toggle("Значок 🔧 в строке меню", isOn: $menuBarIcon)
                Text("Клик по значку — панель с вкладками прямо под ним (или \(HotKeyRegistry.combo(for: .tools).title)). Настройки, тёплый экран и выход — в шапке панели.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Порядок вкладок") {
                let order = PanelTabs.sections(panelTabs)
                ForEach(Array(order.enumerated()), id: \.element) { index, section in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Label(section.title, systemImage: section.symbol)
                        Spacer()
                        Button { move(section, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).help("Левее")
                        Button { move(section, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == order.count - 1).help("Правее")
                    }
                    .buttonStyle(.borderless)
                }
                .onMove { from, to in
                    var list = PanelTabs.sections(panelTabs)
                    list.move(fromOffsets: from, toOffset: to)
                    panelTabs = PanelTabs.value(list)
                }
                Text("Сверху вниз — слева направо в панели. Перетащите строку или нажмите стрелки.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!menuBarIcon)
            Section("Вкладки панели") {
                Text("Любые возможности Mac Utils — отметьте, что должно быть под рукой. Если вкладок много, их ряд листается вбок.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(PanelTabs.available) { section in
                        Toggle(isOn: tabBinding(section)) {
                            Label(section.title, systemImage: section.symbol)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .disabled(!menuBarIcon)
        }
        .formStyle(.grouped)
        .navigationTitle("Панель в строке меню")
    }
}
