import AppKit
import SwiftUI
import MUCore
import MUDesign

/// Значок Mac Utils в строке меню: клик — панель «Инструменты» со вкладками
/// прямо под значком (настройки и выход — в её шапке). Можно выключить в настройках.
@MainActor
final class AppStatusItem: NSObject {
    static let shared = AppStatusItem()

    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var keepAwakeObserver: NSObjectProtocol?

    func sync() {
        if UserDefaults.standard.bool(forKey: Pref.menuBarIcon) {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "MacUtilsAppIcon"
            if let button = item.button {
                let image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Mac Utils")
                image?.isTemplate = true
                button.image = image
                button.toolTip = "Mac Utils — инструменты (⌥-клик — в окне)"
                button.setAccessibilityLabel("Mac Utils — инструменты")
                button.target = self
                button.action = #selector(clicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            self.item = item
            if keepAwakeObserver == nil {
                keepAwakeObserver = NotificationCenter.default.addObserver(forName: .keepAwakeChanged, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { AppStatusItem.shared.updateIcon() }
                }
            }
            updateIcon()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// ⌥-клик по значку открывает полное окно вместо панели.
    nonisolated static func opensWindow(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection(.deviceIndependentFlagsMask).contains(.option)
    }

    /// «Не засыпать» включено — на значке чашка и подсказка; иначе обычный значок.
    func updateIcon() {
        guard let button = item?.button else { return }
        let active = KeepAwake.shared.isActive
        let image = NSImage(systemSymbolName: active ? "cup.and.saucer.fill" : "wrench.and.screwdriver",
                            accessibilityDescription: active ? "Mac Utils: не засыпать включено" : "Mac Utils")
        image?.isTemplate = true
        button.image = image
        button.toolTip = active ? "Mac Utils — не засыпать включено (правая кнопка — меню)" : "Mac Utils — инструменты (⌥-клик — в окне, правая кнопка — меню)"
        button.setAccessibilityLabel(active ? "Mac Utils — не засыпать включено" : "Mac Utils — инструменты")
    }

    /// Меню значка (правая кнопка или ⌃-клик): «Не засыпать» и панель.
    private func showMenu() {
        closeTools()
        let keepAwake = KeepAwake.shared
        let menu = NSMenu()
        let title = menu.addItem(withTitle: keepAwake.isActive ? "Не засыпать: \(keepAwake.statusText())" : "Не засыпать", action: nil, keyEquivalent: "")
        title.isEnabled = false
        for duration in KeepAwakeDuration.allCases {
            let entry = menu.addItem(withTitle: duration.title, action: #selector(keepAwakeFor(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = duration.rawValue
            entry.indentationLevel = 1
            if keepAwake.isActive, keepAwake.currentDuration == duration { entry.state = .on }
        }
        if keepAwake.isActive {
            let off = menu.addItem(withTitle: "Выключить", action: #selector(keepAwakeOff), keyEquivalent: "")
            off.target = self
            off.indentationLevel = 1
        }
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Открыть панель", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    @objc private func keepAwakeFor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let duration = KeepAwakeDuration(rawValue: raw) else { return }
        UserDefaults.standard.set(raw, forKey: Pref.keepAwakeDuration)
        KeepAwake.shared.start(duration)
    }

    @objc private func keepAwakeOff() { KeepAwake.shared.stop() }

    @objc private func openPanel() { _ = showTools() }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) == true) {
            showMenu()
        } else if Self.opensWindow(modifiers: NSEvent.modifierFlags) {
            ToolsWindowController.shared.showWindow()
        } else if popover?.isShown == true {
            closeTools()
        } else {
            _ = showTools()
        }
    }

    /// Показывает панель инструментов под значком; false — значка нет.
    func showTools() -> Bool {
        guard let button = item?.button else { return false }
        let popover = self.popover ?? makePopover()
        if !popover.isShown, ScreenOutput.mayShow("Панель в строке меню") {
            ScreenOutput.activateApp()
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
        let controller = NSHostingController(rootView: ToolsView(inPopover: true)
            .frame(width: DS.Size.popover.width, height: DS.Size.popover.height)
            .clipped())
        // Размер задаёт поповер, а не «идеальный» размер содержимого: иначе широкий вид внутри раздувал поповер,
        // и справа за фоном оставалась тёмная полоса.
        controller.sizingOptions = []
        popover.contentViewController = controller
        popover.contentSize = DS.Size.popover
        self.popover = popover
        return popover
    }
}
