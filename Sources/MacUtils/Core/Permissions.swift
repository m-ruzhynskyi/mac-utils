// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices

@MainActor
enum Permissions {
    /// «Универсальный доступ»: нужен для перехвата клавиш и прокрутки.
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// «Запись экрана»: нужна для снимков.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case automation = "Privacy_Automation"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
