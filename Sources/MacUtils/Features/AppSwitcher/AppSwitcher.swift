import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// Переключатель окон: удерживайте ⌥ (или ⌘) и нажимайте Tab.
/// Каждое окно — отдельная карточка, как в Mission Control; порядок — по
/// последнему использованию. Пока панель открыта:
/// Tab / ⇧Tab / ← → — выбор, Q — завершить, H — скрыть, Esc — отмена.
@MainActor
final class AppSwitcher: NSObject, ObservableObject {
    static let shared = AppSwitcher()

    @Published private(set) var items: [SwitcherItem] = []
    @Published var selected = 0
    @Published private(set) var isRunning = false
    /// Последние снимки окон (CGWindowID → превью).
    @Published private(set) var previews: [CGWindowID: NSImage] = [:]

    private enum Key {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let returnKey: Int64 = 36
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let q: Int64 = 12
        static let h: Int64 = 4
    }

    private var tap: EventTap?
    private var modifier: CGEventFlags = .maskAlternate
    private var active = false
    private var recent: [pid_t] = []
    private var systemSwitcherDisabled = false
    /// Режим «⌘Tab (заменить системный)».
    private var commandMode = false
    /// Последний собранный список окон: ⌥Tab показывает его сразу, не обращаясь к Accessibility в обработчике tap.
    private var cache: [SwitcherItem] = []
    /// Ключи окон, которые CG показывал в момент последнего сбора: окно из свежего CG-списка, которого там не было, — новое.
    private var seenKeys: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var cacheTimer: Timer?
    private let panel = SwitcherPanelController()

    private override init() {
        super.init()
        if let front = NSWorkspace.shared.frontmostApplication {
            recent = [front.processIdentifier]
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // Новая программа, скрытая или снова показанная — в кэше её окна и их состояние.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(self, selector: #selector(appsChanged(_:)), name: name, object: nil)
        }
        // Исключённая программа вышла на передний план или ушла с него — системный ⌘Tab включаем и выключаем.
        NotificationCenter.default.addObserver(forName: AppExclusions.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppSwitcher.shared.exclusionChanged() }
        }
    }

    func sync() {
        let defaults = UserDefaults.standard
        let wanted = defaults.bool(forKey: Pref.switcher) && Permissions.accessibility
        let useCommand = defaults.string(forKey: Pref.switcherModifier) == "command"
        commandMode = useCommand
        modifier = useCommand ? .maskCommand : .maskAlternate

        if wanted {
            if tap == nil {
                let tap = EventTap(types: [.keyDown, .keyUp, .flagsChanged]) { [weak self] type, event in
                    self?.handle(type: type, event: event) ?? true
                }
                // Tap отключился по таймауту: отпускание ⌥ могло потеряться, и тогда `active` остался бы true
                // и поглощал бы все клавиши. Закрываем панель и сбрасываем состояние.
                tap.onDisabled = { [weak self] in self?.cancel() }
                self.tap = tap
            }
            isRunning = tap?.start() ?? false
            if isRunning { startCacheRefresh() }
            applySystemSwitcher()
        } else {
            cancel()
            tap?.stop()
            tap = nil
            isRunning = false
            cacheTimer?.invalidate()
            cacheTimer = nil
            cache = []
            setSystemSwitcher(disabled: false)
        }
    }

    /// Системный ⌘Tab выключен, только пока наш переключатель его заменяет. В исключённой программе (виртуальная машина,
    /// удалённый стол) наш перехват пропускает ⌘Tab, поэтому там системный переключатель должен работать: иначе из неё
    /// нельзя уйти с клавиатуры.
    static func shouldDisableSystemSwitcher(running: Bool, commandMode: Bool, frontExcluded: Bool) -> Bool {
        running && commandMode && !frontExcluded
    }

    private func applySystemSwitcher() {
        setSystemSwitcher(disabled: Self.shouldDisableSystemSwitcher(
            running: isRunning, commandMode: commandMode, frontExcluded: AppExclusions.shared.isFrontExcluded))
    }

    private func exclusionChanged() {
        if AppExclusions.shared.isFrontExcluded { cancel() }
        guard isRunning else { return }
        applySystemSwitcher()
    }

    /// Возвращает системный ⌘Tab при выходе.
    func shutdown() {
        setSystemSwitcher(disabled: false)
    }

    // MARK: - История активации

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        recent.removeAll { $0 == pid }
        recent.insert(pid, at: 0)
        refreshItems()
    }

    @objc private func appsChanged(_ note: Notification) {
        refreshItems()
    }

    /// Mac Utils получил или потерял значок в Dock: в кэше появляются или пропадают его окна.
    func activationPolicyChanged() {
        refreshItems()
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        recent.removeAll { $0 == app.processIdentifier }
        refreshItems()
    }

    // MARK: - Кэш списка окон (вне обработчика tap)

    /// Список окон обновляется в фоне, чтобы ⌥Tab не ждал Accessibility: по событиям программ (активация, запуск,
    /// завершение, скрытие) и при открытии панели. Порядок окон панель всё равно берёт свежим из CG, а таймер — запасной,
    /// для заголовков и свёрнутых окон внутри одной программы: раз в минуту (было раз в 5 с — перебор окон через AX).
    static let cacheRefreshInterval: TimeInterval = 60

    private func startCacheRefresh() {
        refreshItems()
        guard cacheTimer == nil else { return }
        let timer = Timer(timeInterval: Self.cacheRefreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { AppSwitcher.shared.refreshItems() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        cacheTimer = timer
    }

    /// Полный сбор в фоновом потоке. Один сбор за раз; пришёл запрос во время сбора — после него повторим.
    /// Если панель открыта, список в ней уточняется на месте (выбор сохраняется).
    private func refreshItems() {
        guard isRunning else { return }
        guard refreshTask == nil else { refreshAgain = true; return }
        let recent = self.recent
        // Программы и иконки — на главном потоке; в фон уходит только Accessibility и CG.
        let apps = WindowList.snapshotApps()
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                UncheckedSendable(WindowList.collect(recent: recent, apps: apps))
            }.value
            guard let self else { return }
            self.refreshTask = nil
            self.cache = result.value
            self.seenKeys = WindowList.visibleWindowKeys()
            if self.active { self.applyRefined(result.value) }
            if self.refreshAgain {
                self.refreshAgain = false
                self.refreshItems()
            }
        }
    }

    /// Подменяет список в открытой панели, оставляя выбранным то же окно.
    private func applyRefined(_ fresh: [SwitcherItem]) {
        guard !fresh.isEmpty else { return }
        let selectedID = items.indices.contains(selected) ? items[selected].id : nil
        selected = SwitcherSelection.index(keeping: selectedID, in: fresh.map(\.id), fallback: selected)
        items = fresh
        panel.show()
    }

    // MARK: - Клавиши

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        switch type {
        case .keyDown:
            if !active {
                var others: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
                others.remove(modifier)
                guard key == Key.tab,
                      flags.contains(modifier),
                      flags.intersection(others).isEmpty else { return true }
                // Виртуальная машина или удалённый рабочий стол сами забирают Tab: отдаём событие им.
                if AppExclusions.shared.isFrontExcluded { return true }
                // Список окон не нашёлся: событие не поглощаем (в режиме ⌘ системный ⌘Tab отключён, но хотя бы не «съедаем» клавишу).
                return !open(reverse: flags.contains(.maskShift))
            }
            switch key {
            case Key.tab: move(flags.contains(.maskShift) ? -1 : 1)
            case Key.left: move(-1)
            case Key.right: move(1)
            case Key.escape: cancel()
            case Key.returnKey: commit()
            case Key.q: quitSelected()
            case Key.h: hideSelected()
            default: break
            }
            return false

        case .keyUp:
            return !active

        case .flagsChanged:
            if active && !flags.contains(modifier) {
                commit()
            }
            return true

        default:
            return true
        }
    }

    // MARK: - Действия

    /// Открывает панель из кэша (в обработчике tap нельзя ходить в Accessibility) и запускает уточнение в фоне.
    /// false — окон нет, панель не открылась.
    private func open(reverse: Bool) -> Bool {
        // Свежий порядок окон берём из CG (1–3 мс, без Accessibility); подробности (заголовки, свёрнутые) — из кэша.
        // Кэш мог устареть (клик между окнами одной программы не обновляет его), а ⌥Tab должен вести к предыдущему окну.
        let draft = WindowList.collect(recent: recent, apps: WindowList.snapshotApps(), axBudget: 0)
        let merged = SwitcherMerge.merge(draft: draft, cached: cache, seen: seenKeys, id: \.id,
                                         isBackground: { $0.isMinimized || $0.isHidden })
        // Значок из Dock ушёл (`.accessory`) — своих окон из кэша в списке быть не должно.
        let list = Self.withoutOwnIfAccessory(merged.isEmpty ? (cache.isEmpty ? draft : cache) : merged,
                                              policy: NSApp.activationPolicy())
        guard !list.isEmpty else {
            refreshItems()
            return false
        }
        items = list
        // Первое окно — текущее; стартуем со второго, как системный ⌘Tab.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let startsWithFront = items.first?.pid == frontPID
        if items.count == 1 {
            selected = 0
        } else if reverse {
            selected = items.count - 1
        } else {
            selected = startsWithFront ? 1 : 0
        }
        active = true
        refreshItems()
        if UserDefaults.standard.bool(forKey: Pref.switcherPreviews) {
            refreshPreviews()
        }

        // Небольшая задержка: при быстром ⌥Tab панель не мигает.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if self.active { self.panel.show() }
        }
        return true
    }

    /// Снимает окна через ScreenCaptureKit (свёрнутые — если система отдаст кадр).
    /// Пока снимки не готовы, показываются прошлые превью или иконки.
    private func refreshPreviews() {
        guard Permissions.screenRecording else { return }
        let ids = items.prefix(24).compactMap(\.windowID)
        let alive = Set(items.compactMap(\.windowID))
        previews = previews.filter { alive.contains($0.key) }
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false) else { return }
            for windowID in ids {
                guard self.active else { return }
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let frame = window.frame
                let scale = min(1, 480 / max(frame.width, frame.height, 1)) * 2
                config.width = max(1, Int(frame.width * scale))
                config.height = max(1, Int(frame.height * scale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                          configuration: config) {
                    self.previews[windowID] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                }
            }
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
        if active { panel.show() }
    }

    func choose(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selected = index
        commit()
    }

    private func commit() {
        guard active else { return }
        active = false
        panel.hide()
        if items.indices.contains(selected) {
            WindowActivation.activate(items[selected])
        }
    }

    private func cancel() {
        active = false
        panel.hide()
    }

    private func quitSelected() {
        guard items.indices.contains(selected) else { return }
        // Q на своей карточке завершил бы сам Mac Utils вместе с переключателем.
        guard items[selected].pid != WindowList.ownPID else { return NSSound.beep() }
        let pid = items[selected].pid
        items[selected].app.terminate()
        removeItems(of: pid)
    }

    private func hideSelected() {
        guard items.indices.contains(selected) else { return }
        items[selected].app.hide()
        move(1)
    }

    private func removeItems(of pid: pid_t) {
        let before = items[..<selected].filter { $0.pid == pid }.count
        items.removeAll { $0.pid == pid }
        selected -= before
        if items.isEmpty {
            cancel()
            return
        }
        selected = min(selected, items.count - 1)
        panel.show()
    }

    static func withoutOwnIfAccessory(_ items: [SwitcherItem], policy: NSApplication.ActivationPolicy) -> [SwitcherItem] {
        policy == .regular ? items : items.filter { $0.pid != WindowList.ownPID }
    }

    // MARK: - Системный ⌘Tab

    private typealias SetSymbolicHotKeyEnabled = @convention(c) (Int32, Bool) -> Int32

    /// Отключает системный ⌘Tab / ⌘⇧Tab, чтобы его заменил наш переключатель.
    /// Использует закрытую функцию CGS; если её нет — просто ничего не делает.
    private func setSystemSwitcher(disabled: Bool) {
        guard disabled != systemSwitcherDisabled else { return }
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else { return }
        let setEnabled = unsafeBitCast(symbol, to: SetSymbolicHotKeyEnabled.self)
        _ = setEnabled(1, !disabled) // ⌘Tab
        _ = setEnabled(2, !disabled) // ⌘⇧Tab
        systemSwitcherDisabled = disabled
    }
}

/// Выбор в списке после его обновления.
enum SwitcherSelection {
    /// Индекс прежнего выбранного окна в новом списке; нет такого — прежний индекс, зажатый в границы.
    static func index(keeping id: String?, in ids: [String], fallback: Int) -> Int {
        guard !ids.isEmpty else { return 0 }
        if let id, let found = ids.firstIndex(of: id) { return found }
        return min(max(fallback, 0), ids.count - 1)
    }
}

/// Склейка свежего списка CG (правильный порядок окон) с кэшем (заголовки, AX-окна, свёрнутые).
enum SwitcherMerge {
    /// - `draft` — окна, которые CG видит сейчас, спереди назад (без Accessibility);
    /// - `cached` — прошлый полный список;
    /// - `seen` — ключи окон, которые CG показывал при последнем полном сборе. Окно из `draft` без записи в кэше:
    ///   новое (его `seen` не знает) — добавляется; известное, но отсутствующее в кэше, Accessibility отсеял
    ///   (панель, вспомогательное окно) — не добавляется;
    /// - окно из кэша, которого нет в `draft`, остаётся только если оно свёрнуто или программа скрыта (`isBackground`);
    ///   иначе оно закрыто или ушло с этого рабочего стола.
    static func merge<T>(draft: [T], cached: [T], seen: Set<String>, id: (T) -> String, isBackground: (T) -> Bool) -> [T] {
        let cachedByID = Dictionary(cached.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var result: [T] = []
        var used = Set<String>()
        for window in draft {
            let key = id(window)
            if let known = cachedByID[key] {
                result.append(known)
                used.insert(key)
            } else if !seen.contains(key) {
                result.append(window)
                used.insert(key)
            }
        }
        for window in cached where isBackground(window) && !used.contains(id(window)) {
            result.append(window)
            used.insert(id(window))
        }
        return result
    }
}
