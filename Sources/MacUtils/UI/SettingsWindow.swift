// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        if !window.isVisible { FocusReturn.remember() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        PermissionsModel.shared.refresh()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Mac Utils"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.setContentSize(NSSize(width: 980, height: 620))
        window.minSize = NSSize(width: 760, height: 520)
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
