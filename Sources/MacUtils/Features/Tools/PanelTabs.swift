import Foundation

/// Какие разделы Mac Utils показываются вкладками в панели 🔧.
enum PanelTabs {
    static let defaultValue = "uninstaller,monitor,tasks,cleanup,shots"

    /// Всё, кроме «Общих» (они в шапке панели — ⚙︎).
    static var available: [SettingsSection] { SettingsSection.allCases.filter { $0 != .general } }

    static func sections(_ value: String) -> [SettingsSection] {
        let ids = Set(value.split(separator: ",").map(String.init))
        let list = available.filter { ids.contains($0.rawValue) }
        return list.isEmpty ? [.uninstaller] : list
    }

    static func value(_ sections: [SettingsSection]) -> String {
        available.filter(sections.contains).map(\.rawValue).joined(separator: ",")
    }

    /// Перенос прежней настройки (скрытые вкладки инструментов) — один раз.
    static func migrate() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Pref.toolsPanelTabs) == nil,
              let hidden = defaults.string(forKey: Pref.toolsHiddenTabs), !hidden.isEmpty else { return }
        let hiddenSet = Set(hidden.split(separator: ",").map(String.init))
        let kept = defaultValue.split(separator: ",").map(String.init).filter { !hiddenSet.contains($0) }
        defaults.set(kept.joined(separator: ","), forKey: Pref.toolsPanelTabs)
    }
}
