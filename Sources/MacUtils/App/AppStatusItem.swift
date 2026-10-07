import AppKit
import SwiftUI

/// Значок Mac Utils в строке меню: клик — панель «Инструменты» со вкладками
/// прямо под значком (настройки и выход — в её шапке). Можно выключить в настройках.
@MainActor
final class AppStatusItem: NSObject {
    static let shared = AppStatusItem()

    private var item: NSStatusItem?
    private var popover: NSPopover?

    func sync() {
        if UserDefaults.standard.bool(forKey: Pref.menuBarIcon) {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "MacUtilsAppIcon"
            if let button = item.button {
                let image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Mac Utils")
                image?.isTemplate = true
                button.image = image
                button.toolTip = "Mac Utils — инструменты"
                button.target = self
                button.action = #selector(clicked)
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
        if popover?.isShown == true {
            closeTools()
        } else {
            _ = showTools()
        }
    }

    /// Показывает панель инструментов под значком; false — значка нет.
    func showTools() -> Bool {
        guard let button = item?.button else { return false }
        let popover = self.popover ?? makePopover()
        if !popover.isShown {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
        return true
    }

    func closeTools() {
        popover?.performClose(nil)
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: ToolsView(inPopover: true).frame(width: 380, height: 470))
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 380, height: 470)
        self.popover = popover
        return popover
    }
}
