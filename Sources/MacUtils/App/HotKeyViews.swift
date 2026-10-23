import SwiftUI

/// Виды сочетаний из реестра: компоненты оформления клавиш не знают о каталоге действий.
extension Keycap {
    /// Сочетание действия из реестра: после переназначения показывается новое.
    init(action: HotKeyAction, compact: Bool = false, onPanel: Bool = false) {
        self.init(resolving: { HotKeyRegistry.combo(for: action).keys }, compact: compact, onPanel: onPanel)
    }
}

extension ShortcutHintRow {
    init(action: HotKeyAction, text: String) { self.init(keycap: Keycap(action: action, compact: true), text: text) }
}

extension HintRow {
    init(action: HotKeyAction, text: String) { self.init(keycap: Keycap(action: action, compact: true), text: text) }
}

extension KeyRow {
    init(_ title: String, action: HotKeyAction) { self.init(title, keycap: Keycap(action: action)) }
}
