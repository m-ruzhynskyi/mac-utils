import Foundation
import MUCore

/// Свой список программ, где Ctrl остаётся как есть, только для «Клавиш Windows» (общий список «Исключённые программы»
/// не затрагивается). Хранится в `Pref.winKeysExcluded`; ключа нет — значения по умолчанию.
@MainActor
package final class WinKeysExclusions: ObservableObject {
    package static let shared = WinKeysExclusions()

    @Published package private(set) var list: [String]

    private init() { list = Self.load() }

    package static func load(defaults: UserDefaults = .standard) -> [String] {
        (defaults.array(forKey: Pref.winKeysExcluded) as? [String]) ?? WinKeysRules.defaultExcluded
    }

    package func set(_ newList: [String]) {
        list = newList
        UserDefaults.standard.set(newList, forKey: Pref.winKeysExcluded)
    }

    package func add(_ entry: String) { set(AppExclusions.adding(entry, to: list)) }

    package func remove(_ entry: String) { set(list.filter { $0 != entry }) }

    package func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: Pref.winKeysExcluded)
        list = WinKeysRules.defaultExcluded
    }

    package func isExcluded(_ bundleID: String?) -> Bool { AppExclusions.matches(bundleID, in: list) }
}
