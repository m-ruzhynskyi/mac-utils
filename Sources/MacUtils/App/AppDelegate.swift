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
        // Шрифты интерфейса (Graphite) — до первого окна; не вышло — системный шрифт.
        DSFonts.registerAll()
        Pref.register()
        KeepAwake.shared.observeWake()
        BusyRegistry.shared.installDefaultProviders()
        observeSystemShutdown()
        PanelTabs.migrate()
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
        HotKeyCenter.shared.register(
            id: HotKeyID.textEditor,
            keyCode: kVK_ANSI_E,
            modifiers: cmdKey | optionKey | controlKey
        ) {
            EditorWindowController.shared.show()
        }

        // Чистая установка: «Что нового» не нужно (оно только после обновления). Делаем до `Updater.start()`.
        let launchDefaults = UserDefaults.standard
        let firstLaunch = !launchDefaults.bool(forKey: Pref.didShowWelcome)
        FirstRun.beginOnboardingIfFirstLaunch(defaults: launchDefaults, firstLaunch: firstLaunch)
        FirstRun.seedChangelog(defaults: launchDefaults, current: Changelog.family(Updater.shared.currentVersion), welcomeShown: !firstLaunch)
        let plan = FirstRun.plan(firstLaunch: firstLaunch, accessibility: Permissions.accessibility,
                                 wantsMoveOffer: MoveToApplications.wantsOffer)
        syncFeatures()
        if plan.offerMove { DispatchQueue.main.async { MoveToApplications.offerIfNeeded() } }
        // Модель не грузим заранее: она держит ~5 ГБ памяти; загрузится при первом запросе.
        Updater.shared.start()
        // Спрашиваем не посреди запуска (там и так «Перенести?»/разрешения), а чуть позже.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { ToolsLauncher.start() } }

        // Выдали или отозвали «Универсальный доступ» — утилиты включаются и выключаются сами. Система сообщает об этом
        // уведомлением; опрос — запасной: раз в 2 с, пока доступа нет, и раз в 5 с, когда он есть (отзыв доступа
        // при живом перехвате клавиш не должен затягиваться).
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { _ in
            // Список доверенных программ система обновляет чуть позже уведомления.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.checkTrust() }
            }
        }
        scheduleTrustCheck()

        if plan.showSettings {
            launchDefaults.set(true, forKey: Pref.didShowWelcome)
            SettingsWindowController.shared.show()
        }
    }

    /// macutils://tools — значок «Инструменты»; macutils://settings — настройки;
    /// annotate, pin, fix-text, meeting, break, warm, snap?left… — то же, что горячие клавиши (для «Команд»).
    /// Файлы («Открыть с помощью», перетаскивание на значок в Dock) открываются вкладками текстового редактора.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { EditorWindowController.shared.open(files) }
        for url in urls where url.scheme == "macutils" {
            switch url.host {
            case "tools": ToolsWindowController.shared.show()
            case "editor":
                // macutils://editor — открыть редактор; macutils://editor?path=/путь/к/файлу — открыть файл.
                let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
                if let path, !path.isEmpty {
                    EditorWindowController.shared.openFromLink(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                } else {
                    EditorWindowController.shared.show()
                }
            case "snap":
                // macutils://snap?left — left/right/top/bottom/topLeft/…/maximize/center/restore.
                let targets: [String: WindowTiler.Target] = [
                    "left": .left, "right": .right, "top": .top, "bottom": .bottom, "topLeft": .topLeft,
                    "topRight": .topRight, "bottomLeft": .bottomLeft, "bottomRight": .bottomRight,
                    "maximize": .maximize, "center": .center,
                ]
                if url.query == "restore" { WindowTiler.shared.perform(.restore) }
                else if let target = targets[url.query ?? ""] { WindowTiler.shared.perform(.snap(target)) }
            case "share": ScreenShare.shared.isLive ? ScreenShare.shared.stop() : ScreenShare.shared.start(screen: url.query == "screen")
            case "watch": if let code = url.query { ShareViewer.shared.watch(code: code) }
            case "share-drop": ScreenShare.shared.simulateDrop()
            case "annotate": ScreenAnnotator.shared.toggle()
            case "pin": WindowPin.shared.toggleFocused()
            case "fix-text": TextFixer.shared.fix()
            case "meeting": MeetingRecorder.shared.toggle()
            case "meeting-report":
                if let name = url.query?.removingPercentEncoding {
                    let folder = MeetingRecorder.root.appendingPathComponent(name, isDirectory: true)
                    Task { await MeetingRecorder.shared.process(.init(folder: folder), reportOnly: true) }
                }
            case "meeting-process":
                // macutils://meeting-process?2026-10-07%2020.30 — заново расшифровать встречу из папки «Встречи».
                if let name = url.query?.removingPercentEncoding {
                    let folder = MeetingRecorder.root.appendingPathComponent(name, isDirectory: true)
                    Task { await MeetingRecorder.shared.process(.init(folder: folder)) }
                }
            case "break": BreakReminder.shared.show()
            case "warm": WarmScreen.shared.preview()
            case "warm-toggle": WarmScreen.shared.toggleManual()
            case "keep-awake": KeepAwake.shared.toggle()
            case "focus": FocusBlur.shared.toggle()
            default: SettingsWindowController.shared.show()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Клик по значку в Dock во время просмотра — к окну трансляции.
        if ShareViewer.shared.isWindowOpen {
            ShareViewer.shared.showWindow()
            return false
        }
        // Значок в Dock появился из-за редактора — к нему.
        if EditorWindowController.shared.isOpen {
            EditorWindowController.shared.show()
            return false
        }
        SettingsWindowController.shared.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Выключение, перезагрузка или выход из системы уже запрошены: окон не показываем, человека может не быть рядом.
    private var shutdownFlag = SystemShutdownFlag()
    private var systemIsShuttingDown: Bool { shutdownFlag.isActive() }
    private var terminationReplied = false

    private func observeSystemShutdown() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdownFlag.note() }
        }
    }

    /// Выход (⌘Q, «Выйти») во время записи, эфира и т. п.: спросить, остановить штатно и только потом выйти.
    /// При системном завершении (и после подтверждения перезапуска ради обновления) — без вопроса, с коротким пределом ожидания.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Редактор: черновики и сессия записываются сразу; без автосохранения — вопрос о несохранённом.
        guard EditorWindowController.shared.prepareForTermination() else { return .terminateCancel }
        let reasons = BusyRegistry.shared.active
        // Две независимые проверки: уведомление о выключении (за последние две минуты) и причина в самом событии выхода.
        let quitCode = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        let systemQuit = systemIsShuttingDown || QuitReason.isSystemShutdown(quitCode)
        if systemQuit { shutdownFlag.note() }
        let plan = BusyRegistry.terminationPlan(reasons: reasons, systemShutdown: systemQuit,
                                                confirmed: BusyRegistry.shared.terminationConfirmed)
        let silent: Bool
        switch plan {
        case .now:
            return .terminateNow
        case .windDownSilently:
            silent = true
        case .ask(let prompt):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = prompt.title
            alert.informativeText = prompt.message
            alert.addButton(withTitle: prompt.confirm)
            alert.addButton(withTitle: prompt.cancel)
            ScreenOutput.activateApp(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            silent = false
        }
        terminationReplied = false
        func reply() {
            guard !terminationReplied else { return }
            terminationReplied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await Self.windDown(BusyRegistry.windDownOrder(reasons), silent: silent)
            reply()
        }
        if systemQuit {
            // Система не ждёт: после короткого предела выходим в любом случае.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(BusyRegistry.systemShutdownLimit * 1_000_000_000))
                reply()
            }
        }
        return .terminateLater
    }

    /// Штатно завершает идущее: запись сохраняется, эфир закрывается. Ждёт ограниченное время на каждое.
    private static func windDown(_ reasons: [BusyRegistry.Reason], silent: Bool) async {
        let registry = BusyRegistry.shared
        for reason in reasons {
            switch reason {
            case .screenRecording:
                ScreenRecorder.current?.stop()
            case .meetingRecording:
                MeetingRecorder.shared.stop()
            case .scrollCapture:
                ScrollCapture.current?.finish()
            case .steps:
                StepsSession.current?.finish()
            case .broadcast:
                ScreenShare.shared.stop()
            case .viewing:
                ShareViewer.shared.stopWatching()
            case .screenshotSaving:
                break   // останавливать нечего: ждём, пока снимок закодируется и запишется
            case .meetingProcessing, .uninstalling:
                continue
            }
            // Запись дописывается в файл (GIF собирается долго): даём закончиться, но в рамках предела.
            for _ in 0..<BusyRegistry.waitAttempts(for: reason, silent: silent) where registry.isActive(reason) {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            // Запись встречи сразу уходит в «обработку», а файл закрывается чуть позже: ждём закрытия, но не расшифровку.
            if reason == .meetingRecording { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WarmScreen.shared.shutdown()
        KeepAwake.shared.shutdown()
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
        scheduleTrustCheck()
    }

    /// Запасной опрос доступа: чаще, пока его ждём, реже — когда он есть.
    private func scheduleTrustCheck() {
        trustTimer?.invalidate()
        let interval = AppDelegate.trustCheckInterval(trusted: lastTrusted)
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(checkTrust), userInfo: nil, repeats: true)
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    static func trustCheckInterval(trusted: Bool) -> TimeInterval { trusted ? 5 : 2 }

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
        FocusBlur.shared.sync()
        AppStatusItem.shared.sync()
        syncDock()
    }

    /// В Dock — обычное приложение (клик по значку открывает настройки), иначе — фоновое.
    private func syncDock() { Self.syncDock() }

    /// В Dock — если так выбрано в настройках, открыт просмотр трансляции (чтобы окно было легко найти) или окно
    /// текстового редактора (у него строка меню «Файл / Правка / … / Кодировка»). `editorOpen` — пока окно открывается
    /// или закрывается.
    static func syncDock(editorOpen: Bool? = nil) {
        let visible = UserDefaults.standard.bool(forKey: Pref.showInDock) || ShareViewer.shared.isWindowOpen
            || (editorOpen ?? EditorWindowController.shared.isOpen)
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Со значком в Dock Mac Utils есть в своём переключателе, без значка — нет. Системный ⌘Tab эта смена не трогает.
        AppSwitcher.shared.activationPolicyChanged()
        // Окно настроек не должно пропадать при смене режима.
        if policy == .accessory, SettingsWindowController.shared.isVisible {
            DispatchQueue.main.async { SettingsWindowController.shared.show() }
        }
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
    static let focus: UInt32 = 33
    static let textEditor: UInt32 = 34
}
