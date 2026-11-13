import AppKit
import MUCore
import ScreenCaptureKit

/// Движок «Скрытого экрана»: виртуальный дисплей, сторож окон выбранных программ, зеркало, ввод.
/// Интерфейс (меню, настройки, окно со строкой программ) работает с ним через `HiddenScreenControlling` (папка UI, MU · Разработчик).
@MainActor
public final class HiddenScreenEngine {
    public enum Phase: Equatable, Sendable {
        case off
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

    private var display: HiddenDisplay?
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

    private var steps: [PointerStep] = []
    private var runningSteps = false
    private var watch: HandoffWatch?
    private var handoffTimer: Timer?
    private var handoffMonitors: [Any] = []
    private var handoffTick = 0
    private var lastSurface: IOSurfaceRef?
    private var defaultsToken: NSObjectProtocol?

    public init(options: HiddenScreenOptions = HiddenScreenOptions()) {
        self.options = options
        session = PointerSession(clickMode: options.clickMode, scrollMode: options.scrollMode)
        mirrorView.onInput = { [weak self] input in self?.handle(input) }
        mirrorView.onDrop = { [weak self] route, pasteboard in self?.paste(route, from: pasteboard) ?? false }
        mirrorView.onResize = { [weak self] size in self?.mirrorResized(size) }
        mirrorView.exportItems = { [weak self] in self?.exportItems() ?? [] }
        refreshStatuses(windows: [])
    }

    // MARK: Включение и выключение

    /// Создать скрытый дисплей за углом раскладки и перенести на него окна программ.
    public func enable() {
        guard phase != .on else { return }
        let display = HiddenDisplay(pointSize: options.displaySize)
        do {
            try display.open { [weak self] in
                Task { @MainActor in self?.displayVanished() }
            }
            hidden = try display.moveBeyondCorner()
        } catch {
            display.close()
            phase = .failed("Скрытый дисплей не создан: \(error)")
            Log.hiddenScreen.error("enable: \(String(describing: error), privacy: .public)")
            onChange?()
            return
        }
        self.display = display
        phase = .on
        Log.hiddenScreen.info("enable: дисплей \(display.displayID) \(String(describing: self.hidden), privacy: .public)")
        attachObservers()
        let center = NSWorkspace.shared.notificationCenter
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
    }

    /// Выключить: вернуть окна туда, где они были до переноса, закрыть зеркало, снять дисплей.
    public func disable() {
        guard phase == .on else { return }
        restoreWindows(of: options.apps)
        tearDown()
        Log.hiddenScreen.info("disable: окна возвращены")
    }

    /// Выход Mac Utils: сначала спрятать программы (иначе macOS перенесёт их окна на настоящий экран — в демонстрацию),
    /// потом снять дисплей. При падении процесса этого не произойдёт (см. отчёт: процесс-помощник).
    public func shutdown() {
        guard phase == .on else { return }
        runningTargets.forEach { $0.hide() }
        tearDown()
        Log.hiddenScreen.info("shutdown: программы спрятаны, дисплей снят")
    }

    private func tearDown() {
        endHandoffNow()
        sweepTimer?.invalidate()
        sweepTimer = nil
        stopCursorGuard()
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceTokens.removeAll()
        observers.removeAll()
        let stream = self.stream
        self.stream = nil
        mirrorTarget = nil
        mirroredApp = nil
        Task { await stream?.stop() }
        if clipboard.isActive { clipboard.restore() }
        pointer.restoreCursor()
        display?.close()
        display = nil
        hidden = .null
        remembered.removeAll()
        mirrorWindow?.orderOut(nil)
        mirrorShown = false
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
        Log.hiddenScreen.error("дисплей снят системой — прячем программы")
        runningTargets.forEach { $0.hide() }
        tearDown()
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
        guard phase == .on, let display else { return }
        let targets = runningTargets
        let windows = mover.windows(pids: Set(targets.map(\.processIdentifier)))
        lastWindows = windows
        let physical = HiddenDisplay.physicalDisplays(excluding: display.displayID)
        let plan = HiddenWindowRules.plan(windows: windows, apps: options.apps, hidden: hidden, physical: physical)
        if !plan.isEmpty {
            let failed = mover.apply(plan, windows: windows) { [weak self] id, frame in
                if self?.remembered[id] == nil { self?.remembered[id] = frame }
                Log.hiddenScreen.info("окно \(id) перенесено с \(String(describing: frame), privacy: .public)")
            }
            for leak in failed {
                Log.hiddenScreen.error("утечка: \(String(describing: leak), privacy: .public)")
                onLeak?(leak)
            }
        }
        refreshStatuses(windows: windows)
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
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.guardCursor() }
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

    private func guardCursor() {
        guard session.handoff == nil, !runningSteps,
              let display, let back = HiddenScreenGeometry.pullBack(pointer.location, hidden: hidden,
                                                                    physical: HiddenDisplay.physicalDisplays(excluding: display.displayID))
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
        guard let target = HiddenWindowRules.mirrorCandidate(windows: windows, app: app, hidden: hidden) else { return }
        await stream?.stop()
        session.cancelPress()
        let viewSize = mirrorView.bounds.size
        var frame = target.frame
        if viewSize.width > 10, viewSize.height > 10,
           let element = mover.element(for: target.id, pid: pid, known: windows) {
            let size = MirrorMapping.targetSize(forMirror: viewSize, hidden: hidden)
            if mover.resize(element, to: size) { frame.size = size }
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
        mirrorTarget = (pid, target.id)
        mirroredApp = app
        Log.hiddenScreen.info("зеркало: \(app.name, privacy: .public) окно \(target.id) \(String(describing: frame), privacy: .public)")
        onChange?()
    }

    public func stopMirror() async {
        let stream = self.stream
        self.stream = nil
        mirrorTarget = nil
        mirroredApp = nil
        await stream?.stop()
        onChange?()
    }

    private func mirrorLost() {
        guard let app = mirroredApp else { return }
        stream = nil
        mirrorTarget = nil
        mirroredApp = nil
        onChange?()
        // Окно закрыли — показать следующее окно той же программы, если есть.
        Task { try? await mirror(app) }
    }

    private func pixelSize(_ size: CGSize) -> CGSize {
        let scale = NSScreen.screens.first { $0.displayID == display?.displayID }?.backingScaleFactor ?? 2
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var targetFrame: CGRect? {
        guard let mirrorTarget else { return nil }
        return mover.windows(pids: [mirrorTarget.pid]).first { $0.id == mirrorTarget.windowID }?.frame
    }

    private var mapping: MirrorMapping? {
        targetFrame.map { MirrorMapping(viewSize: mirrorView.bounds.size, target: $0) }
    }

    /// Пользователь тянет зеркало — через 0,1 с после последнего изменения меняем размер настоящего окна и кадра.
    private func mirrorResized(_ size: CGSize) {
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
        mover.resize(element, to: targetSize)
        // Окно у правого или нижнего края скрытого дисплея после увеличения может вылезти — вернуть внутрь.
        if let frame = mover.frame(of: element), !hidden.contains(frame) {
            mover.move(element, to: HiddenWindowRules.placement(of: frame, from: hidden, into: hidden))
        }
        let stream = self.stream
        let pixels = pixelSize(targetSize)
        Task { await stream?.resize(pixelSize: pixels) }
    }

    /// Рамка вида зеркала в глобальных координатах Quartz (куда возвращать курсор).
    private var mirrorRect: CGRect? {
        guard let window = mirrorView.window else { return nil }
        let cocoa = window.convertToScreen(mirrorView.convert(mirrorView.bounds, to: nil))
        return HiddenScreenGeometry.quartz(fromCocoa: cocoa, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    // MARK: Ввод

    private func handle(_ input: MirrorInput) {
        guard phase == .on, let mirrorTarget, session.handoff == nil, let mapping else { return }
        switch input {
        case let .key(code, down, flags, characters):
            let events = MirrorInputTranslator(mapping: mapping, windowNumber: mirrorTarget.windowID)
                .translate(.key(code: code, down: down, flags: flags, characters: characters))
            keys.post(events, to: mirrorTarget.pid)
        case let .mouse(.down, button, point, clicks, flags):
            run(session.down(button, at: point, clicks: clicks, flags: flags, mapping: mapping,
                             windowNumber: mirrorTarget.windowID, cursor: pointer.location))
        case let .mouse(.dragged, _, point, _, _):
            run(session.dragged(to: point, mapping: mapping))
        case .mouse(.up, .left, _, _, _):
            run(session.up(mapping: mapping, windowNumber: mirrorTarget.windowID))
        case .mouse(.up, .right, _, _, _), .moved:
            break
        case let .scroll(dx, dy, precise, point):
            run(session.scroll(dx: dx, dy: dy, precise: precise, at: point, mapping: mapping, windowNumber: mirrorTarget.windowID))
        }
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
            guard let pid, ScreenOutput.mayShow("Скрытый экран: активация программы"),
                  let app = NSRunningApplication(processIdentifier: pid) else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
            app.activate()
            let started = ProcessInfo.processInfo.systemUptime
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
                  ProcessInfo.processInfo.systemUptime - started < 0.3 {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            Log.hiddenScreen.debug("активация: \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) мс")
        case .activateSelf:
            ScreenOutput.activateApp(ignoringOtherApps: true)
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
        Log.hiddenScreen.info("передача курсора: \(String(describing: kind), privacy: .public)")
        let activity: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handoffEvent(event) }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .scrollWheel, .mouseMoved, .leftMouseDragged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: activity) { handoffMonitors.append(global) }
        // Если нажатие всё-таки осталось за зеркалом (WindowServer не передал его окну ИИ), события придут сюда — это видно в журнале.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            activity(event)
            if event.type == .leftMouseDragged || event.type == .leftMouseUp {
                Log.hiddenScreen.error("передача: \(event.type.rawValue) пришло в Mac Utils, а не в программу")
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
        self.watch = watch
        if watch.shouldEnd(at: now) {
            Log.hiddenScreen.info("передача закончена через \(Int((now - watch.started) * 1000)) мс")
            run(session.endHandoff(cursorNow: cursor, mapping: mapping, mirrorRect: mirrorRect))
        }
    }

    private func stopHandoffWatch() {
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
        ScreenOutput.activateApp(ignoringOtherApps: true)
    }

    // MARK: Вставка и перетаскивание

    /// Брошенное в зеркало: временный буфер → ⌘V в программу → через 1,5 с буфер пользователя назад.
    func paste(_ route: DropRoute, from pasteboard: NSPasteboard) -> Bool {
        guard let pid = mirrorTarget?.pid else { return false }
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
        keys.post(PasteKeystroke.events(), to: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [clipboard] in clipboard.restore() }
        Log.hiddenScreen.info("вставка: \(String(describing: route).prefix(40), privacy: .public)")
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
            mirrorWindow?.orderOut(nil)
            mirrorShown = false
            Task { await stopMirror() }
            onChange?()
            return
        }
        if phase != .on { enable() }
        guard phase == .on else { return }
        let window = ensureMirrorWindow()
        window.makeKeyAndOrderFrontOnScreen("Скрытый экран: зеркало")
        mirrorShown = true
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
        refreshStatuses(windows: lastWindows)
    }

    /// Убрать программу из списка; её окна со скрытого дисплея возвращаются туда, где были.
    public func removeApp(_ bundleID: String) {
        guard let app = options.apps.first(where: { $0.matches(bundleID: bundleID) }) else { return }
        if phase == .on { restoreWindows(of: [app]) }
        options.apps.removeAll { $0 == app }
        saveApps()
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

    func restoreWindows(of apps: [HiddenApp]) {
        let physical = HiddenDisplay.physicalDisplays(excluding: display?.displayID ?? kCGNullDirectDisplay)
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { running in apps.contains { $0.matches(bundleID: running.bundleIdentifier) } }
            .map(\.processIdentifier))
        let windows = mover.windows(pids: pids)
        for window in windows where window.layer == 0 && hidden.intersects(window.frame) {
            guard let origin = HiddenWindowRules.restoreOrigin(remembered: remembered[window.id], current: window.frame,
                                                                hidden: hidden, physical: physical),
                  let element = mover.element(for: window.id, pid: window.pid, known: windows) else { continue }
            mover.move(element, to: origin)
            remembered[window.id] = nil
        }
    }

    private func ensureMirrorWindow() -> MirrorWindow {
        if let mirrorWindow { return mirrorWindow }
        let visible = NSScreen.screens.first?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let size = CGSize(width: min(900, visible.width * 0.7), height: min(700, visible.height * 0.75))
        let window = MirrorWindow(title: "Скрытый экран", size: size, titleBar: mirrorHasTitleBar, view: mirrorView)
        window.center()
        mirrorWindow = window
        applyLevel()
        defaultsToken = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLevel() }
        }
        window.onMoveOrResize = { [weak self] in self?.onChange?() }
        return window
    }

    private func applyLevel() {
        let onTop = UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) as? Bool ?? true
        mirrorWindow?.level = onTop ? .floating : .normal
    }

    /// Запустить (спрятанной) или вернуть из «скрыть» программу, перенести её окна и показать в зеркале.
    func show(_ app: HiddenApp) {
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
        let physical = HiddenDisplay.physicalDisplays(excluding: display?.displayID ?? kCGNullDirectDisplay)
        for (element, frame) in mover.axWindows(pid: running.processIdentifier) {
            guard let source = physical.first(where: { HiddenWindowRules.visibleArea(frame, $0) > 0 }) else { continue }
            if let id = AXWindowID.of(element), remembered[id] == nil { remembered[id] = frame }
            mover.move(element, to: HiddenWindowRules.placement(of: frame, from: source, into: hidden))
        }
        running.unhide()
    }

    // MARK: Самопроверка скрытия

    /// Через секунду после показа зеркала: снимок основного экрана и сравнение с кадром зеркала (`HidingCheck`).
    func verifyHidingSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await verifyHiding()
        }
    }

    public func verifyHiding() async {
        guard mirrorShown, let window = mirrorWindow, let surface = lastSurface,
              let screen = window.screen, let displayID = screen.displayID else { return }
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
            guard let mirrorRect,
                  let crop = HidingCheck.cropRect(mirror: mirrorRect, display: CGDisplayBounds(displayID), scale: scale),
                  let region = shot.cropping(to: crop),
                  let frame = Self.image(from: surface) else { return }
            let verdict = HidingCheck.verdict(captured: HidingCheck.thumbnail(region), mirror: HidingCheck.thumbnail(frame))
            Log.hiddenScreen.info("самопроверка скрытия: \(verdict.map { $0 ? "не видно" : "ВИДНО" } ?? "не понять", privacy: .public)")
            if verdict != hidingVerified {
                hidingVerified = verdict
                onChange?()
            }
        } catch {
            Log.hiddenScreen.error("самопроверка скрытия: \(String(describing: error), privacy: .public)")
        }
    }

    static func image(from surface: IOSurfaceRef) -> CGImage? {
        let image = CIImage(ioSurface: surface)
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(image, from: image.extent)
    }
}
