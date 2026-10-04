// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Ключи UserDefaults. Значения по умолчанию регистрируются при запуске.
enum Pref {
    static let didShowWelcome = "didShowWelcome"

    static let cutPaste = "cutPasteEnabled"
    static let cutPanel = "cutPanelEnabled"

    static let smoothScroll = "smoothScrollEnabled"
    static let smoothSpeed = "smoothScrollSpeed"
    static let smoothDuration = "smoothScrollDuration"

    static let switcher = "appSwitcherEnabled"
    /// "option" — ⌥Tab, "command" — заменить системный ⌘Tab.
    static let switcherModifier = "appSwitcherModifier"
    static let switcherPreviews = "appSwitcherPreviews"

    static let screenshot = "screenshotEnabled"
    static let screenshotFolder = "screenshotFolder"
    /// Куда отправлять снимок по Enter / двойному клику: "clipboard", "folder", "both".
    static let screenshotDestination = "screenshotDestination"

    static let layoutFix = "layoutFixEnabled"
    /// Горячая клавиша: код клавиши и модификаторы Carbon (по умолчанию ⌘P).
    static let layoutFixKeyCode = "layoutFixKeyCode"
    static let layoutFixModifiers = "layoutFixModifiers"
    /// Переключать раскладку системы после исправления.
    static let layoutFixSwitchSource = "layoutFixSwitchSource"

    static let autoUpdate = "autoUpdateEnabled"
    static let updateRepo = "updateRepository"
    static let justUpdatedTo = "justUpdatedTo"

    static func register() {
        UserDefaults.standard.register(defaults: [
            cutPaste: true,
            cutPanel: true,
            smoothScroll: true,
            smoothSpeed: 1.0,
            smoothDuration: 0.35,
            switcher: true,
            switcherModifier: "option",
            switcherPreviews: true,
            screenshot: true,
            screenshotDestination: "clipboard",
            layoutFix: true,
            layoutFixSwitchSource: false,
            autoUpdate: true,
        ])
    }

    enum ScreenshotDestination: String {
        case clipboard, folder, both
    }

    static var screenshotDestinationValue: ScreenshotDestination {
        ScreenshotDestination(rawValue: UserDefaults.standard.string(forKey: screenshotDestination) ?? "") ?? .clipboard
    }

    static var screenshotDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: screenshotFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}

/// Русское склонение по числу: 1 объект, 2 объекта, 5 объектов.
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let mod10 = n % 10, mod100 = n % 100
    if mod10 == 1 && mod100 != 11 { return one }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
    return many
}
