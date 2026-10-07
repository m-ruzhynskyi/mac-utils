import AppKit

/// Значок Mac Utils в строке меню: клик — окно «Инструменты»,
/// правый клик — меню (инструменты, настройки, выход). Можно выключить в настройках.
@MainActor
final class AppStatusItem: NSObject {
    static let shared = AppStatusItem()

    private var item: NSStatusItem?

    func sync() {
        if UserDefaults.standard.bool(forKey: Pref.menuBarIcon) {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "MacUtilsAppIcon"
            if let button = item.button {
                let image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Mac Utils")
                image?.isTemplate = true
                button.image = image
                button.toolTip = "Mac Utils — инструменты (правый клик — меню)"
                button.target = self
                button.action = #selector(clicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            self.item = item
            // Стрелку «Строки меню» пересоздаём, чтобы она оказалась левее значка.
            MenuBarHider.shared.recreate()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu, let button = item?.button else {
            ToolsWindowController.shared.show()
            return
        }
        let menu = NSMenu()
        for tab in ToolsWindowController.Tab.allCases {
            let entry = NSMenuItem(title: tab.title, action: #selector(openTab(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = tab.rawValue
            entry.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти из Mac Utils", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openTab(_ sender: NSMenuItem) {
        let tab = (sender.representedObject as? String).flatMap(ToolsWindowController.Tab.init(rawValue:))
        ToolsWindowController.shared.show(tab)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
}
