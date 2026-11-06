import Foundation
import MUCore

/// Какие сочетания «Клавиш Windows» выключены (`Pref.winKeysDisabled`); по умолчанию включены все.
@MainActor
package final class WinKeysShortcuts: ObservableObject {
    package static let shared = WinKeysShortcuts()

    @Published package private(set) var disabled: Set<String>

    private init() { disabled = WinKeysShortcut.loadDisabled() }

    package func isEnabled(_ shortcut: WinKeysShortcut) -> Bool { !disabled.contains(shortcut.id) }

    package func setEnabled(_ shortcut: WinKeysShortcut, _ on: Bool) {
        if on { disabled.remove(shortcut.id) } else { disabled.insert(shortcut.id) }
        WinKeysShortcut.saveDisabled(disabled)
    }
}
