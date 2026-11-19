import AppKit
import MUCore
import ScreenCaptureKit

/// Движок «Скрытого экрана»: виртуальный дисплей, сторож окон выбранных программ, зеркало, ввод.
/// Интерфейс (меню, настройки, окно со строкой программ) работает с ним через `HiddenScreenControlling` (папка UI, MU · Разработчик).
@MainActor
public final class HiddenScreenEngine {
    public enum Phase: Equatable, Sendable {
        case off
        /// Помощник создаёт дисплей (обычно десятки миллисекунд).
        case starting
        case on
        case failed(String)
    }

    /// Программа из списка: запущена ли и сколько её окон на скрытом экране.
    public struct AppStatus: Equatable, Sendable {
        public var app: HiddenApp
        /// Идентификатор для интерфейса: у запущенной программы — её собственный, иначе первый из известных
        /// (у ChatGPT их два: `com.openai.chat` и `com.openai.codex`; `selectApp`/`removeApp` понимают любой).
        public var bundleID: String
        public var isRunning: Bool
        public var hiddenWindows: Int
    }

    /// Один движок на приложение: им пользуются интерфейс (`HiddenScreenUI.controller`) и отладочный запуск.
    public static let shared = HiddenScreenEngine(
        options: HiddenScreenOptions(apps: HiddenScreenOptions.apps(fromBundleIDs: UserDefaults.standard.stringArray(forKey: Pref.hiddenScreenApps))))

    /// Ключ «Окно ИИ поверх всех окон» (его хранит интерфейс, `HiddenScreenUI.alwaysOnTopKey`; по умолчанию — да).
    public static let alwaysOnTopKey = "hiddenScreenAlwaysOnTop"

    /// Включён ли скрытый экран (`state` оставлен протоколу интерфейса `HiddenScreenControlling`).
    public private(set) var phase: Phase = .off
    public private(set) var statuses: [AppStatus] = []
    /// Какая программа сейчас в зеркале.
    public private(set) var mirroredApp: HiddenApp?
    /// Состояние, список программ или зеркало изменились.
    public var onChange: (() -> Void)?
    /// Окно программы показалось на настоящем экране и не переносится (меню, подсказка) — для журнала и предупреждения.
    public var onLeak: ((HiddenWindowAction) -> Void)?

    public var options: HiddenScreenOptions {
        didSet {
            session.clickMode = options.clickMode
            session.scrollMode = options.scrollMode
            clipboard.marksTransient = options.clipboardMarks
            guard phase == .on else { return }
            attachObservers()
            sweep()
        }
    }

    /// Вид зеркала (картинка окна ИИ и весь ввод) — внутри `mirrorWindow`.
    public let mirrorView = MirrorView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    /// Окно-зеркало (`sharingType = .none`). Полоска интерфейса цепляется к нему `addChildWindow(_:ordered: .above)`
    /// и двигает его `mirrorWindow?.performDrag(with:)`.
    public private(set) var mirrorWindow: MirrorWindow?
    /// Рамка зеркала у отладочного запуска — с заголовком (можно двигать без полоски).
    public var mirrorHasTitleBar = false
    public private(set) var mirrorShown = false
    /// Самопроверка: зеркало не видно в захвате экрана (true), видно (false), не проверяли или не понять (nil).
    public private(set) var hidingVerified: Bool?
    public var isEnabled: Bool { phase == .on }
    /// `bundleID` (как в `statuses`) программы в зеркале.
    public var mirroredBundleID: String? {
        guard let app = mirroredApp else { return nil }
        return statuses.first { $0.app == app }?.bundleID ?? app.bundleIDs.sorted().first
    }
    /// Рамка окна-зеркала в координатах AppKit (начало слева снизу); nil — зеркала нет на экране.
    public var mirrorFrame: CGRect? {
        guard mirrorShown, let window = mirrorWindow, window.isVisible else { return nil }
        return window.frame
    }

    private var host: DisplayHosting?
    private var displayID: CGDirectDisplayID = kCGNullDirectDisplay
    /// Зеркало попросили показать, пока дисплей ещё создаётся.
    private var mirrorRequested = false
    /// Только для отладки: дисплей в процессе Mac Utils, без помощника (`--hs-helper=off`).
    public var useHelper = true
    private var hidden: CGRect = .null
    private let mover = WindowMover()
    private let keys = PidEventPoster()
    private let pointer = HIDPointer()
    private let clipboard = ClipboardSwap(store: SystemPasteboard())
    private var session: PointerSession
    private var observers: [pid_t: WindowObserver] = [:]
    private var sweepTimer: Timer?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var cursorMonitors: [Any] = []
    /// Рамки окон до переноса — чтобы при выключении вернуть их туда, где были.
    private var remembered: [CGWindowID: CGRect] = [:]
    private var lastWindows: [HiddenWindowInfo] = []

    private var stream: WindowStream?
    private var mirrorTarget: (pid: pid_t, windowID: CGWindowID)?
    private var resizeWork: DispatchWorkItem?
    /// Размер окна (pt), под который настроен поток зеркала.
    private var streamSize: CGSize?
    /// Фактическая рамка окна в зеркале (CGWindowList, обновляется каждым опросом): от неё считаются все переводы координат
    /// — щелчок, протягивание, наведение, прокрутка.
    private var targetFrameCache: CGRect?
    /// Движок сам меняет размер зеркала под окно — это не пользователь тянет зеркало.
    private var fittingMirror = false
    /// Курсор «заглянул» в окно (наведение): точка на скрытом дисплее, куда он поставлен; nil — курсор на своём месте.
    private var peekPoint: CGPoint?
    private var peekWork: DispatchWorkItem?
    /// Пока курсор «заглянул»: проверка 30 раз в секунду, не сдвинули ли мышь (если движение не дошло до наблюдателя).
    private var peekTimer: Timer?
    private var lastMirrorMove: TimeInterval = 0
    private var peekCount = 0
    /// Была ли программа ИИ спрятана до включения (pid → isHidden): на выходе — как было.
    private var wasHidden: [pid_t: Bool] = [:]

    private var steps: [PointerStep] = []
    private var runningSteps = false
    private var watch: HandoffWatch?
    private var handoffTimer: Timer?
    private var handoffMonitors: [Any] = []
    private var handoffTick = 0
    private var lastSurface: IOSurfaceRef?
    private var defaultsToken: NSObjectProtocol?
    /// Программа, в которой пользователь был до ИИ (Zoom, презентация): ей возвращается активность после щелчка.
    private var userApp: NSRunningApplication?
    /// Клавиши идут в зеркало (после щелчка по нему, до щелчка мимо или переключения программ).
    public private(set) var mirrorFocused = false
    /// Перехват клавиатуры при фокусе у зеркала.
    private var keyTap: EventTap?
    /// Свои возвраты активности программе пользователя — чтобы не принять их уведомления за переключение пользователя.
    private var echo = ActivationEcho()
    /// Возвраты активности, когда ИИ снова стал активным сам.
    private var reclaims = ReclaimLimiter()
    private var reclaimPausedLogged = false
    /// Протягивание: событий кнопки, из них с переадресованной точкой (для журнала в конце передачи).
    private var dragEvents = 0
    private var dragRewritten = 0
    /// Правая кнопка над зеркалом перехвачена (её отпускание тоже поглощаем).
    private var rightIntercepted = false
    /// В журнале уже написано «экран заблокирован».
    private var lockLogged = false
    /// Окна, о которых уже написано «утечка» (повтор — только после успешного переноса).
    private var reportedLeaks: Set<CGWindowID> = []
    /// Перехват нажатий над зеркалом (`PressMode.tap`).
    private var pressTap: EventTap?
    /// Нажатие над зеркалом перехвачено, кнопка ещё не отпущена.
    private var pressIntercepted = false
    /// Протягивание отдано программе: синтетическое нажатие уже отправлено, физическая мышь идёт к ней.
    private var dragLive = false
    /// Кнопку отпустили раньше, чем программа получила синтетическое нажатие.
    private var upBeforeLive = false

    public init(options: HiddenScreenOptions = HiddenScreenOptions()) {
        self.options = options
        session = PointerSession(clickMode: options.clickMode, scrollMode: options.scrollMode)
        useHelper = options.useHelper
        clipboard.marksTransient = options.clipboardMarks
        mirrorView.onInput = { [weak self] input in self?.handle(input) }
        mirrorView.onDrop = { [weak self] route, pasteboard in self?.paste(route, from: pasteboard) ?? false }
        mirrorView.onResize = { [weak self] size in self?.mirrorResized(size) }
        mirrorView.exportItems = { [weak self] in self?.exportItems() ?? [] }
        refreshStatuses(windows: [])
    }

    // MARK: Включение и выключение

    /// Создать скрытый дисплей (через процесс-помощник) за углом раскладки и перенести на него окна программ.
    public func enable() {
        switch phase {
        case .on, .starting: return
        case .off, .failed: break
        }
        phase = .starting
        onChange?()
        open(host: useHelper ? HelperDisplayHost() : InProcessDisplayHost())
    }

    private func open(host: DisplayHosting) {
        self.host = host
        let started = ProcessInfo.processInfo.systemUptime
        host.open(size: options.displaySize, apps: hiddenBundleIDs, onReady: { [weak self, weak host] result in
            guard let self, let host, self.host === host, self.phase == .starting else { return }
            switch result {
            case let .success(id):
                Log.hiddenScreen.info("дисплей \(id) создан (\(host.name, privacy: .public)) за \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) мс")
                self.finishEnable(displayID: id)
            case let .failure(error):
                Log.hiddenScreen.error("дисплей (\(host.name, privacy: .public)): \(String(describing: error), privacy: .public)")
                host.close(hiding: false)
                if host is HelperDisplayHost {
                    // Без помощника скрытие работает, но при падении Mac Utils окна выпадут на экран — это видно в журнале.
                    Log.hiddenScreen.error("помощник недоступен — дисплей в процессе Mac Utils")
                    self.open(host: InProcessDisplayHost())
                } else {
                    self.host = nil
                    self.phase = .failed("Скрытый дисплей не создан: \(error)")
                    self.onChange?()
                }
            }
        }, onLost: { [weak self, weak host] in
            guard let self, let host, self.host === host else { return }
            self.displayVanished()
        })
    }

    private func finishEnable(displayID id: CGDirectDisplayID) {
        displayID = id
        do {
            hidden = try HiddenScreenLayout.moveBeyondCorner(id, size: options.displaySize)
        } catch {
            // Дисплей есть, но не отодвинут: работать можно, курсор сторожит `guardCursor`.
            hidden = CGDisplayBounds(id)
            Log.hiddenScreen.error("раскладка: \(String(describing: error), privacy: .public)")
        }
        phase = .on
        Log.hiddenScreen.info("enable: дисплей \(id) \(String(describing: self.hidden), privacy: .public); активная программа — по \(Activator.readsWindowServer ? "WindowServer" : "NSWorkspace", privacy: .public); наведение \(self.options.hover.rawValue, privacy: .public)")
        attachObservers()
        for app in runningTargets { wasHidden[app.processIdentifier] = app.isHidden }
        Log.hiddenScreen.info("видимость до: \(self.visibilityText(self.runningTargets.map { ($0, $0.isHidden) }), privacy: .public)")
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.applicationActivated(activated) }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.attachObservers()
                    self?.sweep()
                }
            })
        }
        sweep()
        // AX сообщает не обо всём (меню, окна Electron без AX, Sparkle) — опрос раз в 0,25 с, как у DeskPad.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        startCursorGuard()
        onChange?()
        // Окна ИИ уже на скрытом дисплее, но активной могла остаться программа ИИ — её строка меню на основном экране выдаёт.
        noteActivated(NSWorkspace.shared.frontmostApplication)
        if let front = NSWorkspace.shared.frontmostApplication, isTarget(front) {
            Log.hiddenScreen.info("после переноса активна \(front.bundleIdentifier ?? "?", privacy: .public) — возвращаю программе пользователя")
            run([.returnFocus])
        }
        if mirrorRequested {
            mirrorRequested = false
            setMirrorShown(true)
        }
    }

    func isTarget(_ app: NSRunningApplication?) -> Bool {
        options.apps.contains { $0.matches(bundleID: app?.bundleIdentifier) }
    }

    /// Запомнить программу пользователя (обычная, не ИИ, не Mac Utils).
    private func noteActivated(_ app: NSRunningApplication?) {
        guard let app, FocusRules.isUserApp(isRegular: app.activationPolicy == .regular, isTarget: isTarget(app),
                                            isSelf: app.processIdentifier == getpid(), bundleID: app.bundleIdentifier) else { return }
        userApp = app
    }

    /// Активной стала другая программа. ИИ не нашим шагом (Dock, ⌘Tab, сама) — вернуть программе пользователя;
    /// пользователь сам перешёл в другую программу — запомнить её, клавиши больше не перехватывать.
    private func applicationActivated(_ app: NSRunningApplication?) {
        let target = isTarget(app)
        // Эхо — только наших возвратов программе пользователя; активацию ИИ им не гасим.
        let isEcho = !target && app.map { echo.consume($0.processIdentifier, at: ProcessInfo.processInfo.systemUptime) } == true
        switch FocusRules.reaction(isTarget: target, isSelf: app?.processIdentifier == getpid(), isEcho: isEcho,
                                   stepsRunning: runningSteps || !steps.isEmpty, mirrorShown: mirrorShown, handoff: session.handoff) {
        case .userSwitched:
            noteActivated(app)
            setMirrorFocused(false, reason: "активна \(app?.bundleIdentifier ?? "?")")
        case .reclaim:
            checkFocus(reason: "уведомление")
        case .ignore:
            break
        }
    }

    /// ИИ активен (по WindowServer), а мышь и шаги свободны — вернуть активность программе пользователя.
    /// Вызывается из уведомления, повторных проверок после возврата и опроса `sweep`.
    private func checkFocus(reason: String) {
        guard phase == .on, mirrorShown, session.handoff == nil, !runningSteps, steps.isEmpty,
              let front = Activator.frontPID(), runningTargets.contains(where: { $0.processIdentifier == front }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard reclaims.allow(at: now) else {
            if !reclaimPausedLogged {
                reclaimPausedLogged = true
                Log.hiddenScreen.error("ИИ (pid \(front)) снова и снова становится активным — пауза в возвратах на \(Int(ReclaimLimiter.window)) с")
            }
            return
        }
        reclaimPausedLogged = false
        let bundle = NSRunningApplication(processIdentifier: front)?.bundleIdentifier ?? "pid \(front)"
        Log.hiddenScreen.info("активной стала \(bundle, privacy: .public) (\(reason, privacy: .public)) — возвращаю программе пользователя")
        run([.returnFocus])
    }

    /// После каждого возврата: не активировался ли ИИ сам чуть позже (нажатие, дошедшее до него с опозданием).
    private func scheduleFocusRechecks() {
        for delay in FocusRules.recheckDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.checkFocus(reason: "проверка через \(Int(delay * 1000)) мс") }
            }
        }
    }

    /// Активность — программе пользователя (не ИИ, не Mac Utils): тогда строка меню основного экрана показывает её.
    /// Неизвестна или закрыта — Finder (нейтральное меню).
    private func returnFocus() async {
        let target = (userApp.flatMap { $0.isTerminated ? nil : $0 })
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        guard let target else { return }
        echo.note(target.processIdentifier, at: ProcessInfo.processInfo.systemUptime)
        let path = await Activator.activate(pid: target.processIdentifier, mode: options.activationMode)
        Log.hiddenScreen.info("фокус — \(target.bundleIdentifier ?? "?", privacy: .public): \(path, privacy: .public); активная программа — \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
    }

    /// Фокус у зеркала: клавиши перехватываются и идут в программу ИИ (`postToPid`), активной остаётся программа пользователя.
    private func setMirrorFocused(_ focused: Bool, reason: String) {
        guard focused != mirrorFocused else { return }
        mirrorFocused = focused
        mirrorView.showFocus(focused)
        if focused { installKeyTap() } else { keyTap?.stop(); keyTap = nil }
        Log.hiddenScreen.info("фокус клавиатуры: \(focused ? "зеркало" : "не зеркало", privacy: .public) (\(reason, privacy: .public))")
        onChange?()
    }

    private func installKeyTap() {
        guard keyTap == nil else { return }
        let tap = EventTap(types: [.keyDown, .keyUp]) { [weak self] type, event in
            guard let self else { return true }
            return !self.interceptKey(type, event)
        }
        tap.onDisabled = { Log.hiddenScreen.error("перехват клавиатуры отключён системой") }
        if tap.start() {
            keyTap = tap
        } else {
            Log.hiddenScreen.error("перехват клавиатуры не создан — набор в зеркало не работает")
        }
    }

    /// true — клавиша поглощена (ушла в ИИ или отброшена).
    private func interceptKey(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticEventFactory.marker { return false }
        guard phase == .on, mirrorShown, let mirrorTarget, let mapping else { return false }
        let rewritten = MirrorKeys.winKeysRewrite(code: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
                                                  enabled: UserDefaults.standard.bool(forKey: Pref.winKeys),
                                                  disabled: WinKeysShortcut.loadDisabled())
        switch FocusRules.keyDecision(code: rewritten.code, flags: rewritten.flags, mirrorFocused: mirrorFocused, handoff: session.handoff) {
        case .pass:
            if rewritten.flags.contains(.maskCommand), rewritten.code == MirrorKeys.tab { setMirrorFocused(false, reason: "⌘Tab") }
            return false
        case .drop:
            if type == .keyDown { Log.hiddenScreen.info("клавиатура: ⌘-сочетание код \(rewritten.code) отброшено") }
            return true
        case .forward:
            var length = 0
            var units = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
            let characters = length > 0 ? String(utf16CodeUnits: units, count: length) : nil
            handleKey(code: rewritten.code, down: type == .keyDown, flags: rewritten.flags, characters: characters, pid: mirrorTarget.pid,
                      translator: MirrorInputTranslator(mapping: mapping, windowNumber: mirrorTarget.windowID))
            return true
        }
    }

    /// bundle id всех программ из списка — помощнику, чтобы прятать их, если Mac Utils пропадёт.
    var hiddenBundleIDs: [String] { options.apps.flatMap { $0.bundleIDs.sorted() } }

    /// Выключить: вернуть окна туда, где они были до переноса, закрыть зеркало, снять дисплей.
    public func disable() {
        if phase == .starting {
            mirrorRequested = false
            host?.close(hiding: false)
            host = nil
            phase = .off
            onChange?()
            return
        }
        guard phase == .on else { return }
        let restored = restoreWindows(of: options.apps)
        let visibility = visibilityPlan()
        tearDown(hiding: false)
        applyVisibility(visibility)
        Log.hiddenScreen.info("disable: окон возвращено \(restored.moved), не сдвинулось \(restored.failed)")
    }

    /// Выход Mac Utils: окна — на прежние места и размеры, пока дисплей ещё есть, потом снять дисплей; видимость —
    /// как до включения. Прячем заранее только те программы, что были спрятаны: видимые и так окажутся на экране
    /// (так было до включения), а прятать-и-тут-же-показывать — гонка (deedf02: Claude остался спрятан).
    /// При падении Mac Utils помощник по-прежнему просто прячет все.
    public func shutdown() {
        guard phase == .on || phase == .starting else { return }
        // Видимость запоминается при включении; выход ещё во время запуска (дисплея нет, окна не тронуты) — не трогаем.
        let visibility: (unhide: [pid_t], hide: [pid_t]) = phase == .on ? visibilityPlan() : ([], [])
        visibility.hide.forEach { NSRunningApplication(processIdentifier: $0)?.hide() }
        // AX двигает окна и у спрятанных программ: иначе (643b753) ChatGPT остался на (1710, 1111) — macOS переставляет
        // окна спрятанной программы только при показе.
        let restored = restoreWindows(of: options.apps)
        // Помощнику прятать незачем (иначе он спрятал бы программы после нашего показа ниже).
        tearDown(hiding: false)
        applyVisibility(visibility)
        Log.hiddenScreen.info("shutdown: окон возвращено \(restored.moved), не сдвинулось \(restored.failed), дисплей снят")
    }

    /// Какие программы ИИ показать и какие спрятать, чтобы стало как до включения.
    private func visibilityPlan() -> (unhide: [pid_t], hide: [pid_t]) {
        VisibilityRestore.plan(wasHidden: wasHidden, running: runningTargets.map(\.processIdentifier))
    }

    private func applyVisibility(_ plan: (unhide: [pid_t], hide: [pid_t])) {
        let unhide = plan.unhide.compactMap { NSRunningApplication(processIdentifier: $0) }
        let hide = plan.hide.compactMap { NSRunningApplication(processIdentifier: $0) }
        unhide.forEach { $0.unhide() }
        hide.forEach { $0.hide() }
        Log.hiddenScreen.info("видимость после: показаны: \(self.bundles(unhide), privacy: .public); спрятаны: \(self.bundles(hide), privacy: .public)")
    }

    private func bundles(_ apps: [NSRunningApplication]) -> String {
        apps.isEmpty ? "—" : apps.map { $0.bundleIdentifier ?? "pid \($0.processIdentifier)" }.joined(separator: ", ")
    }

    private func visibilityText(_ apps: [(NSRunningApplication, Bool)]) -> String {
        apps.isEmpty ? "программ ИИ нет"
            : apps.map { "\($0.0.localizedName ?? $0.0.bundleIdentifier ?? "?") [\($0.0.bundleIdentifier ?? "?")] \($0.1 ? "спрятана" : "видима")" }
                .joined(separator: ", ")
    }

    private func tearDown(hiding: Bool) {
        endPeek(reason: "выключение")
        endHandoffNow()
        setMirrorFocused(false, reason: "выключение")
        pressTap?.stop()
        pressTap = nil
        sweepTimer?.invalidate()
        sweepTimer = nil
        stopCursorGuard()
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceTokens.removeAll()
        observers.removeAll()
        let stream = self.stream
        self.stream = nil
        mirrorTarget = nil
        streamSize = nil
        targetFrameCache = nil
        mirroredApp = nil
        Task { await stream?.stop() }
        if clipboard.isActive { clipboard.restore() }
        pointer.restoreCursor()
        host?.close(hiding: hiding)
        host = nil
        displayID = kCGNullDirectDisplay
        hidden = .null
        remembered.removeAll()
        wasHidden.removeAll()
        reportedLeaks.removeAll()
        mirrorWindow?.orderOut(nil)
        mirrorShown = false
        mirrorRequested = false
        hidingVerified = nil
        lastSurface = nil
        if let defaultsToken { NotificationCenter.default.removeObserver(defaultsToken) }
        defaultsToken = nil
        phase = .off
        refreshStatuses(windows: [])
        onChange?()
    }

    private func displayVanished() {
        guard phase == .on else { return }
        Log.hiddenScreen.error("дисплей пропал — прячем программы")
        runningTargets.forEach { $0.hide() }
        tearDown(hiding: true)
        phase = .failed("Скрытый дисплей пропал, программы спрятаны")
        onChange?()
    }

    // MARK: Сторож окон

    var runningTargets: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { running in
            options.apps.contains { $0.matches(bundleID: running.bundleIdentifier) }
        }
    }

    private func attachObservers() {
        let pids = Set(runningTargets.map(\.processIdentifier))
        observers = observers.filter { pids.contains($0.key) }
        for pid in pids where observers[pid] == nil {
            // Новое окно, перенос, смена размера — пересчитать сразу, не дожидаясь опроса.
            observers[pid] = WindowObserver(pid: pid) { [weak self] in
                MainActor.assumeIsolated { self?.sweep() }
            }
        }
    }

    /// Окна программ на настоящих экранах → на скрытый; статусы для интерфейса; зеркало за своим окном.
    public func sweep() {
        guard phase == .on, displayID != kCGNullDirectDisplay else { return }
        // Экран заблокирован: AX отдаёт окна без позиции и размера — переносить нечем, ждём разблокировки.
        if ScreenLock.isLocked {
            if !lockLogged {
                lockLogged = true
                Log.hiddenScreen.info("экран заблокирован — перенос окон подождёт")
            }
            return
        }
        if lockLogged {
            lockLogged = false
            reportedLeaks.removeAll()
            Log.hiddenScreen.info("экран разблокирован — переношу окна")
        }
        let targets = runningTargets
        let windows = mover.windows(pids: Set(targets.map(\.processIdentifier)))
        lastWindows = windows
        let physical = HiddenDisplay.physicalDisplays(excluding: displayID)
        let plan = HiddenWindowRules.plan(windows: windows, apps: options.apps, hidden: hidden, physical: physical)
        if !plan.isEmpty {
            let failed = mover.apply(plan, windows: windows) { [weak self] id, frame in
                if self?.remembered[id] == nil { self?.remembered[id] = frame }
                self?.reportedLeaks.remove(id)
                Log.hiddenScreen.info("окно \(id) перенесено с \(String(describing: frame), privacy: .public)")
            }
            // Одна строка на окно, пока оно не перенесётся (13.11 было 368 одинаковых строк за 30 с).
            for (leak, reason) in failed {
                guard case let .leak(id, _) = leak, !reportedLeaks.contains(id) else { continue }
                reportedLeaks.insert(id)
                Log.hiddenScreen.error("утечка: \(String(describing: leak), privacy: .public) — \(reason, privacy: .public)")
                onLeak?(leak)
            }
        }
        refreshStatuses(windows: windows)
        rescueMirrorIfHidden()
        refitMirror()
        autoSelectMirror()
        checkFocus(reason: "опрос")
    }

    /// Статусы программ для интерфейса (и когда скрытый экран выключен: запущена ли, окон — 0).
    private func refreshStatuses(windows: [HiddenWindowInfo]) {
        let running = NSWorkspace.shared.runningApplications
        let fresh = options.apps.map { app -> AppStatus in
            let instance = running.first { app.matches(bundleID: $0.bundleIdentifier) }
            return AppStatus(app: app, bundleID: instance?.bundleIdentifier ?? app.bundleIDs.sorted().first ?? app.name,
                             isRunning: instance != nil,
                             hiddenWindows: phase == .on ? HiddenWindowRules.hiddenWindowCount(windows: windows, app: app, hidden: hidden) : 0)
        }
        if fresh != statuses {
            statuses = fresh
            onChange?()
        }
    }

    // MARK: Курсор не заходит на скрытый дисплей сам

    private func startCursorGuard() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            let own = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SyntheticEventFactory.marker
            let location = event.cgEvent?.location
            MainActor.assumeIsolated { self?.guardCursor(ownEvent: own, location: location) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler) { cursorMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in handler(event); return event }) {
            cursorMonitors.append(local)
        }
    }

    private func stopCursorGuard() {
        cursorMonitors.forEach(NSEvent.removeMonitor)
        cursorMonitors.removeAll()
    }

    private func guardCursor(ownEvent: Bool = false, location: CGPoint? = nil) {
        if let peekPoint {
            if HoverPeek.endsPeek(isOwnEvent: ownEvent, location: location ?? pointer.location, peekPoint: peekPoint) {
                endPeek(reason: "движение")
            }
            return
        }
        guard session.handoff == nil, !runningSteps,
              displayID != kCGNullDirectDisplay, let back = HiddenScreenGeometry.pullBack(pointer.location, hidden: hidden,
                                                                    physical: HiddenDisplay.physicalDisplays(excluding: displayID))
        else { return }
        pointer.warp(to: back)
    }

    // MARK: Зеркало

    /// Показать в зеркале самое большое окно программы; размер настоящего окна подгоняется под зеркало (1:1).
    public func mirror(_ app: HiddenApp) async throws {
        guard phase == .on,
              let running = runningTargets.first(where: { app.matches(bundleID: $0.bundleIdentifier) }) else { return }
        let pid = running.processIdentifier
        let windows = mover.windows(pids: [pid])
        guard let target = HiddenWindowRules.mirrorCandidate(windows: windows, app: app, hidden: hidden) else {
            Log.hiddenScreen.info("зеркало: у \(app.name, privacy: .public) нет окон на скрытом экране (окон программы \(windows.count): \(windows.map { "\($0.id) уровень \($0.layer)" }.joined(separator: ", "), privacy: .public))")
            return
        }
        endPeek(reason: "другое окно")
        await stream?.stop()
        session.cancelPress()
        let viewSize = mirrorView.bounds.size
        var frame = target.frame
        var requested = "—"
        if viewSize.width > 10, viewSize.height > 10,
           let element = mover.element(for: target.id, pid: pid, known: windows) {
            let size = MirrorMapping.targetSize(forMirror: viewSize, hidden: hidden)
            requested = "\(Int(size.width))×\(Int(size.height))"
            // Код AX «успех» ничего не значит: окно может не дать себя растянуть (быстрый чат Claude — не выше 535 pt).
            frame = resizeTarget(element, to: size) ?? frame
        }
        let stream = WindowStream { [weak self] surface in
            self?.lastSurface = surface
            self?.mirrorView.show(surface: surface)
        }
        stream.onStop = { [weak self] error in
            Log.hiddenScreen.error("зеркало остановлено: \(String(describing: error), privacy: .public)")
            self?.mirrorLost()
        }
        try await stream.start(windowID: target.id, pixelSize: pixelSize(frame.size))
        self.stream = stream
        streamSize = frame.size
        targetFrameCache = frame
        mirrorTarget = (pid, target.id)
        mirroredApp = app
        Log.hiddenScreen.info("зеркало: \(app.name, privacy: .public) окно \(target.id) фактически \(String(describing: frame), privacy: .public), просили \(requested, privacy: .public)")
        fitMirror(to: frame.size, reason: "новое окно")
        updateMirrorClickThrough()
        onChange?()
    }

    public func stopMirror() async {
        let stream = self.stream
        self.stream = nil
        mirrorTarget = nil
        streamSize = nil
        targetFrameCache = nil
        mirroredApp = nil
        await stream?.stop()
        onChange?()
    }

    private func mirrorLost() {
        guard let app = mirroredApp else { return }
        stream = nil
        mirrorTarget = nil
        streamSize = nil
        targetFrameCache = nil
        mirroredApp = nil
        onChange?()
        // Окно закрыли — показать следующее окно той же программы, если есть.
        Task { try? await mirror(app) }
    }

    private func pixelSize(_ size: CGSize) -> CGSize {
        let scale = NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor ?? 2
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var targetFrame: CGRect? {
        guard let mirrorTarget else { return nil }
        if let targetFrameCache { return targetFrameCache }
        let frame = mover.windows(pids: [mirrorTarget.pid]).first { $0.id == mirrorTarget.windowID }?.frame
        targetFrameCache = frame
        return frame
    }

    /// Изменить размер окна ИИ (не больше скрытого дисплея), вернуть внутрь дисплея, если вылезло; фактическая рамка (AX).
    private func resizeTarget(_ element: AXUIElement, to size: CGSize) -> CGRect? {
        mover.resize(element, to: MirrorFit.clamp(size, to: hidden.size))
        if let frame = mover.frame(of: element), !hidden.contains(frame) {
            mover.move(element, to: HiddenWindowRules.placement(of: frame, from: hidden, into: hidden))
        }
        return mover.frame(of: element)
    }

    /// Окно ИИ сменило размер не по нашей просьбе (или отказалось меняться, или переключилась вкладка) — поток и зеркало
    /// под фактическую рамку. Из опроса `sweep`, пока зеркало не тянут и курсор не передан программе.
    private func refitMirror() {
        guard let mirrorTarget, stream != nil, session.handoff == nil, peekPoint == nil,
              !(mirrorView.window?.inLiveResize ?? false) else { return }
        guard let actual = lastWindows.first(where: { $0.id == mirrorTarget.windowID })?.frame else { return }
        targetFrameCache = actual
        guard MirrorFit.differs(streamSize, actual.size) else { return }
        var size = actual.size
        if MirrorFit.differs(MirrorFit.clamp(size, to: hidden.size), size),
           let element = mover.element(for: mirrorTarget.windowID, pid: mirrorTarget.pid, known: lastWindows),
           let frame = resizeTarget(element, to: size) {
            // Окно больше скрытого дисплея — ужать.
            size = frame.size
            targetFrameCache = frame
        }
        Log.hiddenScreen.info("зеркало: окно \(mirrorTarget.windowID) теперь \(Int(size.width))×\(Int(size.height)) (поток был \(self.streamSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "—", privacy: .public)) — поток и зеркало подогнаны")
        streamSize = size
        let stream = self.stream
        let pixels = pixelSize(size)
        Task { await stream?.resize(pixelSize: pixels) }
        fitMirror(to: size, reason: "окно сменило размер")
    }

    /// Размер вида зеркала — под окно (1:1, если помещается на экране; иначе уменьшенное с теми же пропорциями).
    private func fitMirror(to size: CGSize, reason: String) {
        guard let window = mirrorView.window, !window.inLiveResize, let screen = window.screen else { return }
        let current = mirrorView.bounds.size
        let chrome = CGSize(width: window.frame.width - current.width, height: window.frame.height - current.height)
        let available = CGSize(width: screen.visibleFrame.width - chrome.width, height: screen.visibleFrame.height - chrome.height)
        let view = MirrorFit.viewSize(window: size, available: available)
        guard MirrorFit.differs(current, view) else { return }
        fittingMirror = true
        window.setFrame(MirrorFit.mirrorFrame(current: window.frame, chrome: chrome, view: view, visible: screen.visibleFrame), display: true)
        fittingMirror = false
        Log.hiddenScreen.info("зеркало: размер \(Int(current.width))×\(Int(current.height)) → \(Int(self.mirrorView.bounds.width))×\(Int(self.mirrorView.bounds.height)) под окно \(Int(size.width))×\(Int(size.height)) (\(reason, privacy: .public))")
    }

    private var mapping: MirrorMapping? {
        targetFrame.map { MirrorMapping(viewSize: mirrorView.bounds.size, target: $0) }
    }

    /// Пользователь тянет зеркало — через 0,1 с после последнего изменения меняем размер настоящего окна и кадра.
    private func mirrorResized(_ size: CGSize) {
        guard !fittingMirror else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.applyMirrorSize(size) }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func applyMirrorSize(_ size: CGSize) {
        guard let mirrorTarget, size.width > 10, size.height > 10 else { return }
        let windows = mover.windows(pids: [mirrorTarget.pid])
        guard let element = mover.element(for: mirrorTarget.windowID, pid: mirrorTarget.pid, known: windows) else { return }
        let targetSize = MirrorMapping.targetSize(forMirror: size, hidden: hidden)
        // Окно у правого или нижнего края скрытого дисплея после увеличения может вылезти — `resizeTarget` вернёт внутрь.
        // Поток — под фактический размер: окно могло не дать себя растянуть.
        guard let frame = resizeTarget(element, to: targetSize) else { return }
        targetFrameCache = frame
        streamSize = frame.size
        let stream = self.stream
        let pixels = pixelSize(frame.size)
        Task { await stream?.resize(pixelSize: pixels) }
        if MirrorFit.differs(frame.size, targetSize) {
            Log.hiddenScreen.info("зеркало: окно не стало \(Int(targetSize.width))×\(Int(targetSize.height)), фактически \(Int(frame.width))×\(Int(frame.height))")
            fitMirror(to: frame.size, reason: "окно отказалось менять размер")
        }
    }

    /// Рамка вида зеркала в глобальных координатах Quartz (куда возвращать курсор).
    private var mirrorRect: CGRect? {
        guard let window = mirrorView.window else { return nil }
        let cocoa = window.convertToScreen(mirrorView.convert(mirrorView.bounds, to: nil))
        return HiddenScreenGeometry.quartz(fromCocoa: cocoa, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    // MARK: Ввод

    private func handle(_ input: MirrorInput) {
        guard phase == .on, let mirrorTarget, let mapping else { return }
        if case let .key(code, down, flags, characters) = input {
            handleKey(code: code, down: down, flags: flags, characters: characters, pid: mirrorTarget.pid,
                      translator: MirrorInputTranslator(mapping: mapping, windowNumber: mirrorTarget.windowID))
            return
        }
        guard session.handoff == nil else { return }
        switch input {
        case let .moved(point):
            switch options.hover {
            case .pid: hover(at: point, mapping: mapping, windowNumber: mirrorTarget.windowID, pid: mirrorTarget.pid)
            case .peek: schedulePeek()
            case .off: break
            }
            return
        case .exited:
            peekWork?.cancel()
            guard options.hover == .pid, !runningSteps, steps.isEmpty else { return }
            postHover(session.hoverExit(mapping: mapping, windowNumber: mirrorTarget.windowID), pid: mirrorTarget.pid)
            return
        default:
            break
        }
        switch input {
        case let .mouse(.down, button, point, clicks, flags):
            Log.hiddenScreen.info("зеркало: нажатие пришло окну зеркала (\(Int(point.x)), \(Int(point.y))), перехват \(self.pressTap != nil ? "есть" : "нет", privacy: .public)")
            run(session.down(button, at: point, clicks: clicks, flags: flags, mapping: mapping,
                             windowNumber: mirrorTarget.windowID, cursor: pointer.location))
        case let .mouse(.dragged, _, point, _, _):
            run(session.dragged(to: point, mapping: mapping))
        case .mouse(.up, .left, _, _, _):
            run(session.up(mapping: mapping, windowNumber: mirrorTarget.windowID))
        case .mouse(.up, .right, _, _, _), .moved, .exited, .key:
            break
        case let .scroll(dx, dy, precise, point):
            run(session.scroll(dx: dx, dy: dy, precise: precise, at: point, mapping: mapping, windowNumber: mirrorTarget.windowID))
        }
    }

    /// Наведение — сразу (`postToPid`), мимо очереди шагов; пока шаги идут (щелчок, ⌘-сочетание), не шлём.
    // MARK: Наведение «заглядыванием»

    /// Мышь двинулась над зеркалом: через `HoverPeek.dwell` покоя — заглянуть.
    private func schedulePeek() {
        lastMirrorMove = ProcessInfo.processInfo.systemUptime
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.startPeek() }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverPeek.dwell, execute: work)
    }

    /// Настоящий курсор — в ту же точку окна на скрытом дисплее (Chromium подсвечивает только под настоящим курсором);
    /// в зеркале на его месте курсор-подсказка. Программу не активируем.
    private func startPeek() {
        guard peekPoint == nil, phase == .on, mirrorShown, options.hover == .peek, session.state == .idle,
              !runningSteps, steps.isEmpty, !pressIntercepted, let mapping, let rect = mirrorRect,
              let window = mirrorView.window else { return }
        let cursor = pointer.location
        let view = CGPoint(x: cursor.x - rect.minX, y: cursor.y - rect.minY)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let onTop = NSWindow.windowNumber(at: HiddenScreenGeometry.cocoa(fromQuartz: cursor, primaryHeight: primaryHeight),
                                          belowWindowWithWindowNumber: 0) == window.windowNumber
        guard let exact = mapping.toTarget(view),
              HoverPeek.shouldStart(idle: true, overContent: rect.contains(cursor) && onTop,
                                    lastMove: lastMirrorMove, now: ProcessInfo.processInfo.systemUptime) else { return }
        let target = CGPoint(x: exact.x.rounded(), y: exact.y.rounded())
        mirrorView.showHandoffCursor(at: view)
        pointer.warp(to: target)
        pointer.post(SyntheticEvent(kind: .moved, location: target))
        peekPoint = target
        peekTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let point = self.peekPoint,
                      HoverPeek.endsPeek(isOwnEvent: false, location: self.pointer.location, peekPoint: point) else { return }
                self.endPeek(reason: "движение")
            }
        }
        peekCount += 1
        if HoverLog.shouldLog(count: peekCount, exit: false) || peekCount % 10 == 0 {
            Log.hiddenScreen.info("наведение: курсор у окна (\(Int(target.x - mapping.target.minX)), \(Int(target.y - mapping.target.minY))) после покоя \(Int(HoverPeek.dwell * 1000)) мс, №\(self.peekCount)")
        }
    }

    /// Курсор назад на зеркало — в точку картинки, где он сейчас у окна (рука «продолжает» движение).
    private func endPeek(reason: String) {
        guard peekPoint != nil else { return }
        peekPoint = nil
        peekWork?.cancel()
        peekTimer?.invalidate()
        peekTimer = nil
        mirrorView.showHandoffCursor(at: nil)
        guard let mapping, let rect = mirrorRect else { return }
        let back = PointerSession.returnPoint(pointer.location, mapping: mapping, mirrorRect: rect)
        pointer.warp(to: back)
        if peekCount == 1 || peekCount % 10 == 0 {
            Log.hiddenScreen.info("наведение: курсор назад на зеркало (\(reason, privacy: .public))")
        }
    }

    private func hover(at point: CGPoint, mapping: MirrorMapping, windowNumber: CGWindowID, pid: pid_t) {
        guard options.hover == .pid, !runningSteps, steps.isEmpty, !pressIntercepted else { return }
        postHover(session.hover(at: point, mapping: mapping, windowNumber: windowNumber), pid: pid)
    }

    /// Движений наведения отправлено (журнал — первое, каждое `HoverLog.every`-е и уход с зеркала).
    private var hoverCount = 0

    private func postHover(_ hoverSteps: [PointerStep], pid: pid_t) {
        for case let .postToPid(event) in hoverSteps {
            let before = pointer.location
            let inWindow = keys.postReadingBack(event, to: pid)
            hoverCount += 1
            let exit = event.location.map { !(mapping?.target.contains($0) ?? true) } ?? false
            guard HoverLog.shouldLog(count: hoverCount, exit: exit) else { continue }
            let after = pointer.location
            let local = inWindow.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "— (нет CGEventSetWindowLocation)"
            let cursor = before == after ? "на месте" : "СДВИНУЛСЯ \(before) → \(after)"
            Log.hiddenScreen.info("наведение: \(exit ? "уход" : "движение", privacy: .public) №\(self.hoverCount) → (\(Int(event.location?.x ?? 0)), \(Int(event.location?.y ?? 0))), в окне \(local, privacy: .public), окно \(event.windowNumber), pid \(pid); курсор \(cursor, privacy: .public)")
        }
    }

    /// Текст — `postToPid` без активации (проверено). ⌘-сочетания — по `KeyMode` (по умолчанию с активацией программы),
    /// каждое — строкой в журнал: получено, маршрут, путь, pid.
    private func handleKey(code: CGKeyCode, down: Bool, flags: CGEventFlags, characters: String?, pid: pid_t,
                           translator: MirrorInputTranslator) {
        let events = translator.translate(.key(code: code, down: down, flags: flags, characters: characters))
        guard flags.contains(.maskCommand) else {
            keys.post(events, to: pid)
            return
        }
        // Пара «нажатие + отпускание» уходит по нажатию; настоящее отпускание с ⌘ не нужно.
        guard down else { return }
        let route = MirrorKeys.route(code: code, flags: flags)
        guard !events.isEmpty else {
            Log.hiddenScreen.info("⌘-сочетание: код \(code), маршрут \(String(describing: route), privacy: .public) — в программу не отправлено")
            return
        }
        let up = events.map { event -> SyntheticEvent in
            var event = event
            event.kind = .keyUp
            return event
        }
        let steps = session.shortcut(events + up, mode: options.keyMode)
        Log.hiddenScreen.info("⌘-сочетание: код \(code), флаги \(flags.rawValue), путь \(self.options.keyMode.rawValue, privacy: .public)\(self.session.handoff != nil ? " (курсор у программы)" : ""), pid \(pid), шагов \(steps.count)")
        run(steps)
    }

    /// Шаги выполняются строго по очереди; активация ждёт, пока программа действительно станет активной.
    private func run(_ newSteps: [PointerStep]) {
        guard !newSteps.isEmpty else { return }
        steps.append(contentsOf: newSteps)
        guard !runningSteps else { return }
        runningSteps = true
        Task { @MainActor in
            while !steps.isEmpty {
                let step = steps.removeFirst()
                await perform(step)
            }
            runningSteps = false
        }
    }

    private func perform(_ step: PointerStep) async {
        // Без зеркала (окно закрылось посреди шагов) курсор и передачу всё равно доводим до конца, а в программу не шлём.
        let pid = mirrorTarget?.pid
        switch step {
        case .hideCursor:
            pointer.hideCursor()
        case .showCursor:
            pointer.showCursor()
        case .activateTarget:
            guard let pid else { return }
            let started = ProcessInfo.processInfo.systemUptime
            let path = await Activator.activate(pid: pid, mode: options.activationMode, timeout: 0.3)
            Log.hiddenScreen.debug("активация ИИ: \(path, privacy: .public), \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) мс")
        case .returnFocus:
            await returnFocus()
            scheduleFocusRechecks()
        case let .wait(seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        case let .warp(point):
            pointer.warp(to: point)
        case let .postHID(event):
            guard pid != nil else { return }
            pointer.post(event)
        case let .postToPid(event):
            guard let pid else { return }
            keys.post([event], to: pid)
        case let .beginHandoff(kind):
            beginHandoff(kind)
        case .endHandoff:
            stopHandoffWatch()
        }
    }

    // MARK: Передача курсора (перетаскивание, меню, прокрутка)

    private func beginHandoff(_ kind: HandoffKind) {
        watch = HandoffWatch(kind: kind, at: ProcessInfo.processInfo.systemUptime)
        dragEvents = 0
        dragRewritten = 0
        Log.hiddenScreen.info("передача курсора: \(String(describing: kind), privacy: .public)")
        if kind == .drag {
            dragLive = true
            if upBeforeLive {
                // Кнопку уже отпустили: довести нажатие в программе до конца самим.
                upBeforeLive = false
                pointer.post(SyntheticEvent(kind: .leftUp, location: pointer.location, clicks: 1))
                watch?.noteButtonUp()
                Log.hiddenScreen.info("протягивание: отпускание раньше передачи — отпущено синтетически")
            }
        }
        let activity: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handoffEvent(event) }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .scrollWheel, .mouseMoved, .leftMouseDragged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: activity) { handoffMonitors.append(global) }
        // Если нажатие всё-таки осталось за зеркалом (WindowServer не передал его окну ИИ), события придут сюда — это видно в журнале.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            activity(event)
            if event.type == .leftMouseDragged || event.type == .leftMouseUp {
                Log.hiddenScreen.error("передача: \(event.type.rawValue) пришло в Mac Utils, а не в программу (перехват: \(self.pressTap != nil ? "есть" : "нет", privacy: .public))")
            }
            return event
        }) { handoffMonitors.append(local) }
        handoffTick = 0
        handoffTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handoffFrame() }
        }
    }

    private func handoffEvent(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        switch event.type {
        case .leftMouseUp:
            watch?.noteButtonUp()
        case .scrollWheel, .mouseMoved, .leftMouseDragged:
            watch?.noteActivity(at: now)
        default:
            break
        }
    }

    private func handoffFrame() {
        guard var watch, let mapping, let mirrorRect else {
            endHandoffNow()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let cursor = pointer.location
        mirrorView.showHandoffCursor(at: mapping.target.contains(cursor) ? mapping.toView(cursor) : nil)
        handoffTick += 1
        if watch.kind == .menu, handoffTick % 6 == 0, let pid = mirrorTarget?.pid {
            watch.noteMenu(visible: HiddenWindowRules.hasMenu(windows: mover.windows(pids: [pid]), pid: pid, hidden: hidden), at: now)
        }
        let ending = watch.takeEnd(at: now)
        self.watch = watch
        if ending {
            let drag = watch.kind == .drag ? "; событий кнопки \(dragEvents), переадресовано в окно \(dragRewritten)" : ""
            Log.hiddenScreen.info("передача закончена через \(Int((now - watch.started) * 1000)) мс\(drag, privacy: .public)")
            run(session.endHandoff(cursorNow: cursor, mapping: mapping, mirrorRect: mirrorRect))
        }
    }

    private func stopHandoffWatch() {
        dragLive = false
        handoffTimer?.invalidate()
        handoffTimer = nil
        handoffMonitors.forEach(NSEvent.removeMonitor)
        handoffMonitors.removeAll()
        watch = nil
        mirrorView.showHandoffCursor(at: nil)
    }

    /// Аварийно (выключение, пропало окно): курсор на основной экран, Mac Utils активна.
    private func endHandoffNow() {
        guard session.handoff != nil else { return }
        let back = mirrorRect.map { CGPoint(x: $0.midX, y: $0.midY) }
        let fallback = MirrorMapping(viewSize: .zero, target: .zero)
        _ = session.endHandoff(cursorNow: .zero, mapping: fallback, mirrorRect: .zero)
        stopHandoffWatch()
        if let back { pointer.warp(to: back) }
        Task { @MainActor in await returnFocus() }
    }

    // MARK: Перехват нажатий над зеркалом (протягивание)

    /// Физическое нажатие над картинкой зеркала не доходит до зеркала: иначе WindowServer считает зеркало владельцем нажатия
    /// и отдаёт ему всё протягивание (проверка 13.11: «передача: 6 пришло в Mac Utils»). Щелчок по-прежнему выполняется
    /// по отпусканию; протягивание начинается синтетическим нажатием в окне программы — оно и становится владельцем.
    private func installPressTap() {
        guard options.pressMode == .tap, pressTap == nil else { return }
        let tap = EventTap(types: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown]) { [weak self] type, event in
            guard let self else { return true }
            return !self.intercept(type, event)
        }
        tap.onDisabled = { [weak self] in
            Log.hiddenScreen.error("перехват нажатий отключён системой — состояние сброшено")
            self?.pressIntercepted = false
        }
        if tap.start() {
            pressTap = tap
            Log.hiddenScreen.info("перехват нажатий над зеркалом включён")
        } else {
            Log.hiddenScreen.error("перехват нажатий не создан (нет «Универсального доступа»?) — нажатия через события зеркала, протягивание не работает")
        }
    }

    /// true — событие поглощено.
    private func intercept(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticEventFactory.marker { return false }
        if let swallowed = interceptOnEmptyMirror(type, event) { return swallowed }
        guard phase == .on, mirrorShown, let window = mirrorWindow, window.isVisible,
              let target = mirrorTarget, let mapping, let rect = mirrorRect else {
            pressIntercepted = false
            return false
        }
        var location = event.location
        if peekPoint != nil, type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            // Нажатие, пока курсор «заглянул» в окно: курсор назад, а нажатие — как по зеркалу в той же точке картинки.
            endPeek(reason: "нажатие")
            if mapping.target.contains(location) { location = PointerSession.returnPoint(location, mapping: mapping, mirrorRect: rect) }
        }
        let view = CGPoint(x: location.x - rect.minX, y: location.y - rect.minY)
        // Окно сверху — в точке самого события, а не там, где курсор сейчас (`NSEvent.mouseLocation`): нажатие без
        // движения перед ним (инструмент проверки, планшет) приходит раньше, чем курсор туда переедет (643b753:
        // первые три щелчка после запуска прошли мимо перехвата).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let topWindow = rect.contains(location)
            ? NSWindow.windowNumber(at: HiddenScreenGeometry.cocoa(fromQuartz: location, primaryHeight: primaryHeight), belowWindowWithWindowNumber: 0)
            : 0
        let overMirror = rect.contains(location) && mapping.toTarget(view) != nil && topWindow == window.windowNumber
        if type == .leftMouseDown, rect.contains(location), !overMirror {
            logMissedPress(location: location, view: view, topWindow: topWindow, mirror: window.windowNumber)
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Нажатие мимо зеркала (пока курсор не передан программе) — клавиши снова идут активной программе.
            if !overMirror, session.handoff == nil { setMirrorFocused(false, reason: "щелчок мимо зеркала") }
        default:
            break
        }
        switch type {
        case .rightMouseDown:
            guard overMirror, session.state == .idle else { return false }
            // Правая кнопка тоже перехватывается: настоящий щелчок по зеркалу сделал бы активной Mac Utils.
            rightIntercepted = true
            setMirrorFocused(true, reason: "правая кнопка по зеркалу")
            run(session.down(.right, at: view, clicks: Int(event.getIntegerValueField(.mouseEventClickState)), flags: event.flags,
                             mapping: mapping, windowNumber: target.windowID, cursor: location))
            return true
        case .rightMouseUp:
            guard rightIntercepted else { return false }
            rightIntercepted = false
            return true
        case .leftMouseDown:
            guard session.state == .idle, overMirror else { return false }
            setMirrorFocused(true, reason: "щелчок по зеркалу")
            pressIntercepted = true
            upBeforeLive = false
            let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
            let local = mapping.toTarget(view).map { "(\(Int($0.x - mapping.target.minX)), \(Int($0.y - mapping.target.minY)))" } ?? "—"
            Log.hiddenScreen.debug("перехват: нажатие (\(Int(view.x)), \(Int(view.y))) зеркала → в окне \(local, privacy: .public), щелчков \(clicks)")
            run(session.down(.left, at: view, clicks: clicks, flags: event.flags, mapping: mapping,
                             windowNumber: target.windowID, cursor: location))
            return true
        case .leftMouseDragged:
            guard pressIntercepted else { return false }
            if session.handoff == .drag {
                if dragLive { forwardDrag(event, kind: .leftDragged, mapping: mapping, mirrorRect: rect) }
                return true
            }
            let steps = session.dragged(to: view, mapping: mapping)
            if !steps.isEmpty {
                Log.hiddenScreen.info("перехват: протягивание → программе")
                run(steps)
            }
            return true
        case .leftMouseUp:
            guard pressIntercepted else { return false }
            pressIntercepted = false
            if session.handoff == .drag {
                if dragLive {
                    forwardDrag(event, kind: .leftUp, mapping: mapping, mirrorRect: rect)
                    watch?.noteButtonUp()
                    return true
                }
                upBeforeLive = true
                return true
            }
            run(session.up(mapping: mapping, windowNumber: target.windowID))
            return true
        default:
            return false
        }
    }

    /// Нажатие ушло бы в окно-зеркало без картинки — оно сделало бы активной Mac Utils. nil — не наш случай.
    private var emptyPressSwallowed = false

    private func interceptOnEmptyMirror(_ type: CGEventType, _ event: CGEvent) -> Bool? {
        switch type {
        case .leftMouseUp, .rightMouseUp:
            guard emptyPressSwallowed else { return nil }
            emptyPressSwallowed = false
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard phase == .on, mirrorShown, mirrorTarget == nil, let window = mirrorWindow, window.isVisible,
                  EmptyMirrorClick.policy(hasTitleBar: mirrorHasTitleBar) == .swallow, let rect = mirrorRect,
                  rect.contains(event.location) else { return nil }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            guard NSWindow.windowNumber(at: HiddenScreenGeometry.cocoa(fromQuartz: event.location, primaryHeight: primaryHeight),
                                        belowWindowWithWindowNumber: 0) == window.windowNumber else { return nil }
            emptyPressSwallowed = true
            Log.hiddenScreen.info("зеркало пустое — нажатие не отдаю окну зеркала (Mac Utils не станет активной)")
            return true
        default:
            return nil
        }
    }

    /// Пустое зеркало без рамки пропускает мышь насквозь; с картинкой — снова принимает.
    private func updateMirrorClickThrough() {
        guard let window = mirrorWindow else { return }
        let through = mirrorTarget == nil && EmptyMirrorClick.policy(hasTitleBar: mirrorHasTitleBar) == .passThrough
        if window.ignoresMouseEvents != through { window.ignoresMouseEvents = through }
    }

    /// Выбранная программа без окон (или зеркало ещё ничего не показывает) — показать программу с окнами.
    private var lastMirrorAttempt: (app: HiddenApp, at: TimeInterval)?

    private func autoSelectMirror() {
        updateMirrorClickThrough()
        guard phase == .on, mirrorShown, mirrorTarget == nil else { return }
        let counts = statuses.map { (app: $0.app, count: $0.hiddenWindows) }
        guard let app = MirrorChoice.app(selected: mirroredApp ?? lastMirrorAttempt?.app, windows: counts) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard MirrorChoice.shouldTry(app, last: lastMirrorAttempt, now: now) else { return }
        if let previous = lastMirrorAttempt?.app, previous != app {
            Log.hiddenScreen.info("зеркало: у \(previous.name, privacy: .public) окон нет — показываю \(app.name, privacy: .public)")
        }
        lastMirrorAttempt = (app, now)
        show(app)
    }

    /// Протягивание у программы: каждое событие кнопки (физическое или инструмента проверки) поглощается и уходит заново
    /// через HID — так же, как нажатие, с которого протягивание началось, и как работающий щелчок. Точка не со скрытого
    /// дисплея (курсор над зеркалом) переводится в окно. 643b753 правил точку прямо в событии: все 19 событий
    /// переадресованы, а выделения не было — нажатие шло через HID, а протягивание — чужим потоком событий.
    private func forwardDrag(_ event: CGEvent, kind: SyntheticEvent.Kind, mapping: MirrorMapping, mirrorRect: CGRect) {
        dragEvents += 1
        let mapped = PointerSession.dragLocation(event.location, hidden: hidden, mirrorRect: mirrorRect, mapping: mapping)
        if mapped != nil { dragRewritten += 1 }
        let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
        pointer.post(SyntheticEvent(kind: kind, location: mapped ?? event.location, clicks: max(clicks, 1), flags: event.flags))
    }

    /// Нажатие в рамке зеркала, но не перехвачено — почему (первые `MissedPressLog.limit` за запуск).
    private var missedPresses = 0

    private func logMissedPress(location: CGPoint, view: CGPoint, topWindow: Int, mirror: Int) {
        missedPresses += 1
        guard missedPresses <= MissedPressLog.limit else { return }
        let owner = MissedPressLog.owner(of: CGWindowID(clamping: topWindow))
        Log.hiddenScreen.info("перехват: нажатие (\(Int(location.x)), \(Int(location.y))) в рамке зеркала НЕ перехвачено — сверху окно \(topWindow) (\(owner, privacy: .public)), зеркало \(mirror), точка зеркала (\(Int(view.x)), \(Int(view.y))), состояние \(String(describing: self.session.state), privacy: .public)")
    }

    // MARK: Вставка и перетаскивание

    /// Брошенное в зеркало: временный буфер → ⌘V в программу → через 1,5 с буфер пользователя назад.
    func paste(_ route: DropRoute, from pasteboard: NSPasteboard) -> Bool {
        guard let pid = mirrorTarget?.pid else {
            Log.hiddenScreen.error("вставка: нет программы в зеркале")
            return false
        }
        let items: [[String: Data]]
        switch route {
        case let .imageFiles(urls):
            items = urls.map { url in
                var item = ["public.file-url": url.dataRepresentation]
                if let png = Self.pngData(contentsOf: url) { item["public.png"] = png }
                return item
            }
        case let .files(urls):
            items = urls.map { ["public.file-url": $0.dataRepresentation] }
        case let .imageData(type):
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) else { return false }
            var item = [type: data]
            if type != "public.png", let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                item["public.png"] = png
            }
            items = [item]
        case let .text(text):
            items = [["public.utf8-plain-text": Data(text.utf8)]]
        case .unsupported:
            return false
        }
        clipboard.begin(with: items)
        let steps = session.shortcut(PasteKeystroke.events(), mode: options.keyMode)
        run(steps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [clipboard] in
            Log.hiddenScreen.info("вставка: буфер пользователя \(clipboard.restore() ? "возвращён" : "не тронут (в нём уже новое)", privacy: .public)")
        }
        Log.hiddenScreen.info("вставка: \(String(describing: route).prefix(40), privacy: .public) → ⌘V, путь \(self.options.keyMode.rawValue, privacy: .public), pid \(pid)")
        return true
    }

    static func pngData(contentsOf url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// Наружу: содержимое буфера (после «Скопировать» в меню программы) — как файлы, картинка-файл или текст.
    func exportItems() -> [NSDraggingItem] {
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let route = ClipboardExport.route(fileURLs: urls, types: pasteboard.types?.map(\.rawValue) ?? [],
                                          text: pasteboard.string(forType: .string))
        let writers: [NSPasteboardWriting]
        switch route {
        case let .files(files):
            writers = files.map { $0 as NSURL }
        case let .image(type):
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)),
                  let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return [] }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacUtils-HiddenScreen", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(ClipboardExport.imageFileName(at: Date()))
            guard (try? png.write(to: file)) != nil else { return [] }
            writers = [file as NSURL]
        case let .text(text):
            writers = [text as NSString]
        case .nothing:
            return []
        }
        let origin = mirrorView.convert(mirrorView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        return writers.enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            let image = (writer as? NSURL).flatMap { NSWorkspace.shared.icon(forFile: ($0 as URL).path) } ?? NSImage(named: NSImage.multipleDocumentsName)
            item.setDraggingFrame(CGRect(x: origin.x + CGFloat(index) * 6, y: origin.y, width: 48, height: 48), contents: image)
            return item
        }
    }
}

// MARK: - Команды интерфейса (контракт `.audit/hidden-screen-contract.md`, протокол `HiddenScreenControlling`)

extension HiddenScreenEngine {
    public func setEnabled(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    /// Показать зеркало (включив скрытый экран, если он выключен) или спрятать его.
    public func setMirrorShown(_ shown: Bool) {
        guard shown else {
            endPeek(reason: "зеркало спрятано")
            mirrorRequested = false
            mirrorWindow?.orderOut(nil)
            mirrorShown = false
            setMirrorFocused(false, reason: "зеркало спрятано")
            pressTap?.stop()
            pressTap = nil
            Task { await stopMirror() }
            onChange?()
            return
        }
        if phase != .on {
            // Дисплей создаётся асинхронно (помощник) — зеркало покажется, когда он будет готов.
            mirrorRequested = true
            enable()
            return
        }
        let window = ensureMirrorWindow()
        rescueMirrorIfHidden()
        // Не делаем Mac Utils активной: у неё нет своей строки меню, и macOS показала бы меню последней обычной программы
        // (14.11 — ChatGPT). Зеркало просто поверх; клавиши — через перехват после щелчка по нему.
        window.orderFrontRegardlessOnScreen("Скрытый экран: зеркало")
        mirrorShown = true
        rescueMirrorIfHidden()
        if isTarget(NSWorkspace.shared.frontmostApplication) { run([.returnFocus]) }
        installPressTap()
        updateMirrorClickThrough()
        onChange?()
        let app = mirroredApp ?? statuses.first(where: { $0.hiddenWindows > 0 })?.app ?? statuses.first(where: \.isRunning)?.app
        if let app { show(app) }
    }

    /// Показать в зеркале программу. Не запущена — запускается спрятанной, её окна сначала уходят на скрытый дисплей.
    public func selectApp(_ bundleID: String) {
        guard let app = options.apps.first(where: { $0.matches(bundleID: bundleID) }) else { return }
        show(app)
    }

    public func addApp(bundleID: String, name: String) {
        guard !bundleID.isEmpty, !options.apps.contains(where: { $0.matches(bundleID: bundleID) }) else { return }
        options.apps.append(HiddenScreenOptions.defaultApps.first { $0.matches(bundleID: bundleID) }
            ?? HiddenApp(name: name, bundleIDs: [bundleID]))
        saveApps()
        host?.update(apps: hiddenBundleIDs)
        refreshStatuses(windows: lastWindows)
    }

    /// Убрать программу из списка; её окна со скрытого дисплея возвращаются туда, где были.
    public func removeApp(_ bundleID: String) {
        guard let app = options.apps.first(where: { $0.matches(bundleID: bundleID) }) else { return }
        if phase == .on { restoreWindows(of: [app]) }
        options.apps.removeAll { $0 == app }
        saveApps()
        host?.update(apps: hiddenBundleIDs)
        if mirroredApp == app {
            Task { await stopMirror() }
        }
        refreshStatuses(windows: lastWindows)
    }

    /// «Вернуть все окна на экран»: выключить, окна — туда, где были.
    public func returnAllWindows() {
        disable()
    }

    /// Полоска интерфейса тянет зеркало (если она не дочернее окно и не зовёт `performDrag` сама).
    public func dragMirror(with event: NSEvent) {
        mirrorWindow?.performDrag(with: event)
    }

    private func saveApps() {
        UserDefaults.standard.set(options.apps.flatMap { $0.bundleIDs.sorted() }, forKey: Pref.hiddenScreenApps)
    }

    /// Окна программ со скрытого дисплея — туда, где были до переноса (или на первый настоящий экран). Через AX, а не
    /// CGWindowList: у спрятанной программы (выход Mac Utils) окон в списке экрана нет, а AX их видит и двигает.
    @discardableResult
    func restoreWindows(of apps: [HiddenApp]) -> (moved: Int, failed: Int) {
        guard !hidden.isNull else { return (0, 0) }
        let physical = HiddenDisplay.physicalDisplays(excluding: displayID)
        let targets = NSWorkspace.shared.runningApplications.filter { running in apps.contains { $0.matches(bundleID: running.bundleIdentifier) } }
        var moved = 0, failed = 0
        for app in targets {
            let candidates = mover.axCandidates(pid: app.processIdentifier).windows
            let plan = HiddenWindowRules.restorePlan(windows: candidates.map { ($0.windowID, $0.frame) }, remembered: remembered,
                                                     hidden: hidden, physical: physical)
            for item in plan {
                let element = candidates[item.index].element
                let frame = candidates[item.index].frame
                // Размер — пока окно на скрытом дисплее (там места хватает), потом место; не доехало — ещё раз (как при переносе).
                mover.resize(element, to: item.size)
                mover.move(element, to: item.origin)
                if !HiddenWindowRules.arrived(mover.frame(of: element), at: item.origin)
                    || MirrorFit.differs(mover.frame(of: element)?.size, item.size) {
                    mover.resize(element, to: item.size)
                    mover.move(element, to: item.origin)
                }
                let now = mover.frame(of: element)
                let ok = HiddenWindowRules.arrived(now, at: item.origin)
                if ok { moved += 1 } else { failed += 1 }
                if let id = candidates[item.index].windowID { remembered[id] = nil }
                let result = ok ? "ок" : "НЕ сдвинулось, сейчас \(now.map(WindowMover.text) ?? "—")"
                Log.hiddenScreen.info("возврат окна \(app.bundleIdentifier ?? "?", privacy: .public) \(candidates[item.index].windowID.map(String.init) ?? "?", privacy: .public): \(WindowMover.text(frame), privacy: .public) → \(Int(item.origin.x)),\(Int(item.origin.y)) \(Int(item.size.width))×\(Int(item.size.height)) \(result, privacy: .public)")
            }
        }
        return (moved, failed)
    }

    private func ensureMirrorWindow() -> MirrorWindow {
        if let mirrorWindow { return mirrorWindow }
        let visible = NSScreen.screens.first?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let size = CGSize(width: min(900, visible.width * 0.7), height: min(700, visible.height * 0.75))
        let window = MirrorWindow(title: "Скрытый экран", size: size, titleBar: mirrorHasTitleBar, view: mirrorView)
        placeMirrorOnRealScreen(window)
        mirrorWindow = window
        applyLevel()
        defaultsToken = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLevel() }
        }
        window.onMoveOrResize = { [weak self] in self?.onChange?() }
        return window
    }

    /// Зеркало — на настоящий экран (с курсором или со строкой меню), по центру. Не `center()`: тот берёт экран
    /// ключевого окна активной программы, а оно может быть уже на скрытом дисплее.
    func placeMirrorOnRealScreen(_ window: NSWindow) {
        let screens = NSScreen.screens.compactMap { screen in
            screen.displayID.map { FocusRules.Screen(id: $0, frame: screen.frame, visibleFrame: screen.visibleFrame) }
        }
        guard let screen = FocusRules.mirrorScreen(screens, hidden: displayID, mouse: NSEvent.mouseLocation) else { return }
        let frame = FocusRules.centered(window.frame.size, in: screen.visibleFrame)
        window.setFrame(frame, display: false)
        Log.hiddenScreen.info("зеркало: на экране \(screen.id), \(String(describing: frame), privacy: .public)")
    }

    /// Сторож: зеркало оказалось на скрытом дисплее (перетащили, macOS переставила) — вернуть.
    func rescueMirrorIfHidden() {
        guard mirrorShown, let window = mirrorWindow, displayID != kCGNullDirectDisplay,
              let hiddenScreen = NSScreen.screens.first(where: { $0.displayID == displayID }),
              FocusRules.needsRescue(mirror: window.frame, hiddenCocoa: hiddenScreen.frame) else { return }
        Log.hiddenScreen.error("зеркало на скрытом дисплее — возвращаю на основной экран")
        placeMirrorOnRealScreen(window)
    }

    private func applyLevel() {
        let onTop = UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) as? Bool ?? true
        mirrorWindow?.level = onTop ? .floating : .normal
    }

    /// Запустить (спрятанной) или вернуть из «скрыть» программу, перенести её окна и показать в зеркале.
    func show(_ app: HiddenApp) {
        lastMirrorAttempt = (app, ProcessInfo.processInfo.systemUptime)
        Task { @MainActor in
            if let running = NSWorkspace.shared.runningApplications.first(where: { app.matches(bundleID: $0.bundleIdentifier) }) {
                if running.isHidden { revealOnHidden(running) }
            } else if let id = app.bundleIDs.sorted().first(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }),
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.hides = true
                guard let launched = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) else { return }
                // Окна появляются не сразу после запуска: ждём до 5 с первое окно в AX.
                for _ in 0..<50 where mover.axWindows(pid: launched.processIdentifier).isEmpty {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                revealOnHidden(launched)
                attachObservers()
            }
            sweep()
            do {
                try await mirror(app)
                verifyHidingSoon()
            } catch {
                Log.hiddenScreen.error("зеркало \(app.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Окна спрятанной программы (⌘H или запуск с `hides`) переносятся через AX ещё невидимыми, потом программа показывается —
    /// сразу на скрытом дисплее, без кадра на основном (на Mac пользователя не проверено).
    private func revealOnHidden(_ running: NSRunningApplication) {
        guard phase == .on else { return }
        let physical = HiddenDisplay.physicalDisplays(excluding: displayID)
        for (element, frame) in mover.axWindows(pid: running.processIdentifier) {
            guard let source = physical.first(where: { HiddenWindowRules.visibleArea(frame, $0) > 0 }) else { continue }
            if let id = AXWindowID.of(element), remembered[id] == nil { remembered[id] = frame }
            mover.move(element, to: HiddenWindowRules.placement(of: frame, from: source, into: hidden))
        }
        running.unhide()
    }

    // MARK: Самопроверка скрытия

    /// Через секунду после показа зеркала — проба (`HidingCheck`): окно с `.none` и шахматкой, снимок дисплея, поиск шахматки.
    func verifyHidingSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await verifyHiding()
        }
    }

    public func verifyHiding() async {
        // На заблокированном экране снимок — это экран блокировки: пробы «не видно» при любом исходе. Не считаем.
        if ScreenLock.isLocked {
            Log.hiddenScreen.info("самопроверка скрытия: экран заблокирован — не проверяю")
            if hidingVerified != nil {
                hidingVerified = nil
                onChange?()
            }
            return
        }
        guard mirrorShown, let window = mirrorWindow, let screen = window.screen, let displayID = screen.displayID,
              let image = HidingCheck.probeImage(scale: screen.backingScaleFactor) else { return }
        // Проба — в левом верхнем углу зеркала, на 0,15 с.
        let frame = CGRect(x: window.frame.minX + 8, y: window.frame.maxY - 8 - HidingCheck.side,
                           width: HidingCheck.side, height: HidingCheck.side)
        let probe = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        probe.animationBehavior = .none
        probe.ignoresMouseEvents = true
        probe.hasShadow = false
        probe.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        MirrorView.protect(probe)
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.contents = image
        probe.contentView = view
        probe.orderFrontRegardlessOnScreen("Скрытый экран: проба скрытия")
        defer { probe.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else { return }
            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(scDisplay.width) * scale)
            config.height = Int(CGFloat(scDisplay.height) * scale)
            config.showsCursor = false
            let shot = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: scDisplay, excludingWindows: []),
                                                                  configuration: config)
            let probeRect = HiddenScreenGeometry.quartz(fromCocoa: probe.frame, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
            let shotScale = CGFloat(shot.width) / CGDisplayBounds(displayID).width
            guard let crop = HidingCheck.cropRect(probeRect, display: CGDisplayBounds(displayID), scale: shotScale),
                  let region = shot.cropping(to: crop) else {
                Log.hiddenScreen.error("самопроверка скрытия: проба вне снимка")
                return
            }
            let colors = HidingCheck.cellColors(region)
            let verdict = HidingCheck.verdict(cells: colors)
            Log.hiddenScreen.info("самопроверка скрытия: \(verdict.map { $0 ? "не видно" : "ВИДНО" } ?? "не понять", privacy: .public) (клетки: \(colors.map { "\($0.r)/\($0.g)/\($0.b)" }.joined(separator: " "), privacy: .public))")
            if verdict != hidingVerified {
                hidingVerified = verdict
                onChange?()
            }
        } catch {
            Log.hiddenScreen.error("самопроверка скрытия: \(String(describing: error), privacy: .public)")
        }
    }
}
