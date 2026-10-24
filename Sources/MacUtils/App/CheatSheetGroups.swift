import Foundation
import MUCore
import MUWindowSnap

/// Группа «Mac Utils» для «Шпаргалки»: собирается здесь, потому что знает все горячие клавиши приложения.
@MainActor
enum CheatSheetGroups {
    /// Сочетания Mac Utils, которые действительно работают сейчас (из реестра `HotKeyCenter`):
    /// выключенные функции и занятые другими программами не показываются, переназначенные — с новым сочетанием.
    static func macUtilsGroup() -> CheatGroup {
        let active = HotKeyCenter.shared.active
        var items = HotKeyAction.allCases.compactMap { action in
            active[action.hotKeyID].map { CheatItem(title: action.title, shortcut: $0.title) }
        }
        if UserDefaults.standard.bool(forKey: Pref.windowSnap) {
            let symbols = WindowSnapModifier.current.symbols
            items.append(CheatItem(title: "Окно влево / вправо", shortcut: "\(symbols)← / →"))
            items.append(CheatItem(title: "На весь экран", shortcut: "\(symbols)↩"))
        }
        return CheatGroup(title: "Mac Utils", items: items)
    }
}
