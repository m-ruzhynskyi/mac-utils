import Foundation
import MUCore
import MUDesign

/// Какие разделы Mac Utils показываются вкладками в панели 🔧.
enum PanelTabs {
    static let defaultValue = "music,textEditor,uninstaller,monitor,tasks,cleanup,shots"

    /// Всё, кроме «Общих» (они в шапке панели — ⚙︎).
    static var available: [SettingsSection] { SettingsSection.allCases.filter { $0 != .general && $0 != .panel } }

    /// В порядке, который выбрал пользователь.
    static func sections(_ value: String) -> [SettingsSection] {
        var seen = Set<SettingsSection>()
        let list = value.split(separator: ",").compactMap { SettingsSection(rawValue: String($0)) }
            .filter { available.contains($0) && seen.insert($0).inserted }
        return list.isEmpty ? [.uninstaller] : list
    }

    static func value(_ sections: [SettingsSection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Перенос прежней настройки (скрытые вкладки инструментов) — один раз.
    static func migrate() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Pref.toolsPanelTabs) == nil,
           let hidden = defaults.string(forKey: Pref.toolsHiddenTabs), !hidden.isEmpty {
            let hiddenSet = Set(hidden.split(separator: ",").map(String.init))
            let kept = defaultValue.split(separator: ",").map(String.init).filter { !hiddenSet.contains($0) }
            defaults.set(kept.joined(separator: ","), forKey: Pref.toolsPanelTabs)
        }
        // Новая вкладка «Музыка» — один раз добавляем первой.
        if !defaults.bool(forKey: Pref.panelTabsMusicAdded) {
            defaults.set(true, forKey: Pref.panelTabsMusicAdded)
            let current = defaults.string(forKey: Pref.toolsPanelTabs) ?? defaultValue
            if !current.split(separator: ",").contains("music") {
                defaults.set("music," + current, forKey: Pref.toolsPanelTabs)
            }
        }
        // Вкладка «Редактор» — один раз, сразу после «Музыки» (или первой).
        if !defaults.bool(forKey: Pref.panelTabsEditorAdded) {
            defaults.set(true, forKey: Pref.panelTabsEditorAdded)
            var tabs = (defaults.string(forKey: Pref.toolsPanelTabs) ?? defaultValue).split(separator: ",").map(String.init)
            if !tabs.contains("textEditor") {
                tabs.insert("textEditor", at: tabs.firstIndex(of: "music").map { $0 + 1 } ?? 0)
                defaults.set(tabs.joined(separator: ","), forKey: Pref.toolsPanelTabs)
            }
        }
    }
}
