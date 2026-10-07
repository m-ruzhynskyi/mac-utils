import AppKit
import Carbon.HIToolbox

/// Приложение живёт без иконки в Dock и в строке меню (LSUIElement).
/// Окно настроек открывается при повторном запуске приложения
/// (двойной клик в Finder / Launchpad / Spotlight) и по ⌃⌥⌘ ,
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var trustTimer: Timer?
    private var lastTrusted = false
    private var syncScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()
        MainMenu.install()
        lastTrusted = Permissions.accessibility

        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil)

        HotKeyCenter.shared.register(
            id: HotKeyID.settings,
            keyCode: kVK_ANSI_Comma,
            modifiers: cmdKey | optionKey | controlKey
        ) {
            SettingsWindowController.shared.show()
        }

        syncFeatures()
        Updater.shared.start()

        // Пока нет доступа к «Универсальному доступу», периодически проверяем:
        // как только пользователь выдаст разрешение, утилиты включатся сами.
        let timer = Timer(timeInterval: 2, target: self, selector: #selector(checkTrust),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Pref.didShowWelcome) || !Permissions.accessibility {
            defaults.set(true, forKey: Pref.didShowWelcome)
            SettingsWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppSwitcher.shared.shutdown()
    }

    @objc private func defaultsChanged() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async {
            self.syncScheduled = false
            self.syncFeatures()
        }
    }

    @objc private func checkTrust() {
        let trusted = Permissions.accessibility
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        syncFeatures()
    }

    private func syncFeatures() {
        FinderCutPaste.shared.sync()
        SmoothScroll.shared.sync()
        AppSwitcher.shared.sync()
        ScreenshotService.shared.sync()
        LayoutFix.shared.sync()
        WindowTiler.shared.sync()
        AppVolume.shared.sync()
    }
}

enum HotKeyID {
    static let settings: UInt32 = 1
    static let screenshot: UInt32 = 2
    static let screenshotOCR: UInt32 = 3
    static let layoutFix: UInt32 = 4
    /// 10…20 — раскладка окон (по одному на сочетание).
    static let windowSnapBase: UInt32 = 10
    static let appVolume: UInt32 = 30
    static let menuBarToggle: UInt32 = 31
}
