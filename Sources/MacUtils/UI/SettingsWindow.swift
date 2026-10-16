import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Открыть настройки сразу на нужном разделе.
    func show(section: SettingsSection) {
        show()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openSettingsSection, object: section)
        }
    }

    func show() {
        let window = self.window ?? makeWindow()
        if !window.isVisible { FocusReturn.remember() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        PermissionsModel.shared.refresh()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: DS.Size.settingsWindow),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Mac Utils"
        // Graphite: «светофор» над боковой панелью, без полосы заголовка (название окна — для Mission Control и меню «Окно»).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.setContentSize(DS.Size.settingsWindow)
        window.minSize = DS.Size.settingsWindowMin
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Возвращаем фокус предыдущему приложению.
        FocusReturn.restore()
    }
}
