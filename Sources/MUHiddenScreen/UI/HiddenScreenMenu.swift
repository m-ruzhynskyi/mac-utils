import AppKit
import Carbon.HIToolbox
import MUCore

/// Раздел «Скрытый экран» в меню Mac Utils: собирает `NSMenuItem` по чистому списку `HiddenScreenRules.menu`.
@MainActor
package final class HiddenScreenMenuBuilder: NSObject {
    private let controller: HiddenScreenControlling
    private let addApp: () -> Void

    /// `addApp` — вызывает выбор программы (панель выбора живёт в приложении).
    package init(controller: HiddenScreenControlling, addApp: @escaping () -> Void) {
        self.controller = controller
        self.addApp = addApp
    }

    package func items(toggleKey: LayoutHotKey, windowKey: LayoutHotKey) -> [NSMenuItem] {
        let state = controller.state
        return HiddenScreenRules.menu(state, toggleKey: toggleKey.title, windowKey: windowKey.title).map { entry in
            switch entry {
            case .separator: return .separator()
            case .header(let title):
                let item = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            case .toggle(let title, let on, _):
                let item = make(title, #selector(toggle), key: toggleKey)
                item.state = on ? .on : .off
                return item
            case .showWindow(let title, _, let enabled):
                let item = make(title, #selector(toggleWindow), key: windowKey)
                item.isEnabled = enabled
                return item
            case .app(let id, let name, let on):
                let item = make(name, #selector(removeApp(_:)), key: nil)
                item.representedObject = id
                item.state = on ? .on : .off
                item.indentationLevel = 1
                return item
            case .addApp:
                let item = make("Добавить программу…", #selector(add), key: nil)
                item.indentationLevel = 1
                return item
            case .returnAll(let enabled):
                let item = make("Вернуть все окна на экран", #selector(returnAll), key: nil)
                item.isEnabled = enabled
                return item
            }
        }
    }

    private func make(_ title: String, _ action: Selector, key: LayoutHotKey?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let key, let equivalent = Self.keyEquivalent(key) {
            item.keyEquivalent = equivalent.character
            item.keyEquivalentModifierMask = equivalent.mask
        }
        return item
    }

    /// Только для подписи в меню: само сочетание глобальное и зарегистрировано отдельно.
    static func keyEquivalent(_ key: LayoutHotKey) -> (character: String, mask: NSEvent.ModifierFlags)? {
        var mask: NSEvent.ModifierFlags = []
        if key.modifiers & 0x0100 != 0 { mask.insert(.command) }
        if key.modifiers & 0x0200 != 0 { mask.insert(.shift) }
        if key.modifiers & 0x0800 != 0 { mask.insert(.option) }
        if key.modifiers & 0x1000 != 0 { mask.insert(.control) }
        let character: String
        if key.keyCode == kVK_Space { character = " " }
        else if let last = key.title.last, last.isLetter || last.isNumber { character = String(last).lowercased() }
        else { character = "" }
        return character.isEmpty ? nil : (character, mask)
    }

    @objc private func toggle() { controller.setEnabled(!controller.state.isEnabled) }
    @objc private func toggleWindow() { controller.setMirrorShown(!controller.state.mirrorShown) }
    @objc private func removeApp(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { controller.removeApp(id) }
    }
    @objc private func add() { addApp() }
    @objc private func returnAll() { controller.returnAllWindows() }
}
