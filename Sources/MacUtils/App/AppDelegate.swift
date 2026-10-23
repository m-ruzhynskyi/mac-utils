import AppKit
import Carbon.HIToolbox
import MUCore
import MUDesign
import MUCutPaste
import MUFocus
import MUSmoothScroll
import MUAppSwitcher
import MUWellbeing
import MUAppInputSource
import MUMeetings
import MUQR
import MUUpdate

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
        SettingsSection.installAppSubtitles()
        AppRouter.shared.showWhatsNewIfUpdated = { WhatsNewWindowController.shared.showIfUpdated() }
        AppRouter.shared.isInApplications = { MoveToApplications.isInApplications }
        AppRouter.shared.runHotKey = { id in HotKeyAction.action(forHotKeyID: id).map { AppAction(hotKey: $0).run() } }
        KeepAwake.shared.observeWake()
        BusyRegistry.shared.installDefaultProviders()
        observeSystemShutdown()
        PanelTabs.migrate()
        HotKeyCenter.shared.resolver = { HotKeyRegistry.resolve(id: $0, requested: $1) }
        RemoteConnectionsCenter.addPanelTabOnce()
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
            AppAction(hotKey: .settings).run()
        }
        HotKeyCenter.shared.register(
            id: HotKeyID.tools,
            keyCode: kVK_ANSI_T,
            modifiers: cmdKey | optionKey | controlKey
        ) {
            AppAction(hotKey: .tools).run()
        }
        HotKeyCenter.shared.register(
            id: HotKeyID.textEditor,
            keyCode: kVK_ANSI_E,
            modifiers: cmdKey | optionKey | controlKey
        ) {
            AppAction(hotKey: .textEditor).run()
        }
        HotKeyCenter.shared.register(
            id: HotKeyID.videoPlayer,
            keyCode: kVK_ANSI_P,
            modifiers: cmdKey | optionKey | controlKey
        ) {
            AppAction(hotKey: .videoPlayer).run()
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

    /// Ссылки `macutils://…` — те же действия, что горячие клавиши, панель и «Команды» (`AppAction`, список — страница
    /// «Команды и ссылки»). Файлы («Открыть с помощью», перетаскивание на значок в Dock): видео и звук — в плеер,
    /// субтитры — к видео в открытом плеере, остальное — вкладками текстового редактора.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        let route = FileRoute.split(files, playerOpen: PlayerWindowController.anyOpen)
        if !route.player.isEmpty { PlayerWindowController.open(route.player) }
        if !route.editor.isEmpty { EditorWindowController.shared.open(route.editor) }
        for url in urls where url.scheme == "macutils" {
            if let action = AppAction(url: url) {
                action.run()
                continue
            }
            switch url.host {
            case "share-drop": ScreenShare.shared.simulateDrop()
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
        // Значок в Dock появился из-за плеера или редактора — к ним (последний активный).
        if PlayerWindowController.anyOpen, !EditorWindowController.shared.isKey {
            PlayerWindowController.show()
            return false
        }
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
        // Плеер: место запоминается и при выходе с открытым окном.
        for controller in PlayerWindowController.windows { controller.model.savePosition() }
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
        RemoteConnectionsCenter.syncHotKey()
        syncDock()
    }

    /// В Dock — обычное приложение (клик по значку открывает настройки), иначе — фоновое.
    private func syncDock() { Self.syncDock() }

    /// В Dock — если так выбрано в настройках, открыт просмотр трансляции (чтобы окно было легко найти), окно
    /// текстового редактора (у него строка меню «Файл / Правка / … / Кодировка») или окно плеера (полный экран,
    /// PiP и ⌘Tab работают только у обычного приложения). `editorOpen`, `playerOpen` — пока окно открывается или закрывается.
    static func syncDock(editorOpen: Bool? = nil, playerOpen: Bool? = nil) {
        let visible = UserDefaults.standard.bool(forKey: Pref.showInDock) || ShareViewer.shared.isWindowOpen
            || (editorOpen ?? EditorWindowController.shared.isOpen) || (playerOpen ?? PlayerWindowController.anyOpen)
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

/// Куда открыть файлы из Finder и Dock: видео и звук — в плеер; субтитры — в плеер, если он открыт (к текущему видео),
/// иначе в редактор как текст; остальное — в редактор.
enum FileRoute {
    static func split(_ urls: [URL], playerOpen: Bool) -> (player: [URL], editor: [URL]) {
        var player: [URL] = [], editor: [URL] = []
        for url in urls {
            if PlayerMedia.isMedia(url) || (playerOpen && PlayerMedia.isSubtitle(url)) { player.append(url) } else { editor.append(url) }
        }
        return (player, editor)
    }
}
