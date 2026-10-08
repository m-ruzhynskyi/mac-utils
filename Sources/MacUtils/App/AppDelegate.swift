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
        HotKeyCenter.shared.register(
            id: HotKeyID.tools,
            keyCode: kVK_ANSI_T,
            modifiers: cmdKey | optionKey | controlKey
        ) {
            ToolsWindowController.shared.show()
        }

        syncFeatures()
        if Ollama.enabled { Ollama.shared.refresh() }
        Updater.shared.start()
        ToolsLauncher.installIfNeeded()

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

    /// macutils://tools — значок «Инструменты»; macutils://settings — настройки;
    /// annotate, pin, fix-text, meeting, break, warm — то же, что горячие клавиши (для «Команд»).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "macutils" {
            switch url.host {
            case "tools": ToolsWindowController.shared.show()
            case "annotate": ScreenAnnotator.shared.toggle()
            case "pin": WindowPin.shared.toggleFocused()
            case "fix-text": TextFixer.shared.fix()
            case "meeting": MeetingRecorder.shared.toggle()
            case "meeting-process":
                // macutils://meeting-process?2026-10-07%2020.30 — заново расшифровать встречу из папки «Встречи».
                if let name = url.query?.removingPercentEncoding {
                    let folder = MeetingRecorder.root.appendingPathComponent(name, isDirectory: true)
                    Task { await MeetingRecorder.shared.process(.init(folder: folder)) }
                }
            case "break": BreakReminder.shared.show()
            case "warm": WarmScreen.shared.preview()
            default: SettingsWindowController.shared.show()
            }
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
        WarmScreen.shared.shutdown()
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
        DropShelf.shared.sync()
        CheatSheet.shared.sync()
        DownloadsSorter.shared.sync()
        ScreenshotLibrary.shared.sync()
        QRCodeService.shared.sync()
        AppInputSource.shared.sync()
        BreakReminder.shared.sync()
        WarmScreen.shared.sync()
        ScreenAnnotator.shared.sync()
        WindowPin.shared.sync()
        WindowMemory.shared.sync()
        TextFixer.shared.sync()
        MeetingRecorder.shared.sync()
        AppStatusItem.shared.sync()
    }
}

enum HotKeyID {
    static let settings: UInt32 = 1
    static let screenshot: UInt32 = 2
    static let screenshotOCR: UInt32 = 3
    static let layoutFix: UInt32 = 4
    static let tools: UInt32 = 5
    static let dropShelf: UInt32 = 6
    static let annotate: UInt32 = 8
    static let fixText: UInt32 = 9
    static let qr: UInt32 = 7
    /// 10…20 — раскладка окон (по одному на сочетание).
    static let windowSnapBase: UInt32 = 10
    static let appVolume: UInt32 = 30
    static let windowPin: UInt32 = 31
    static let meeting: UInt32 = 32
}
