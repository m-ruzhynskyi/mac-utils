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
    }

    func sync() {
        let defaults = UserDefaults.standard
        let wanted = defaults.bool(forKey: Pref.switcher) && Permissions.accessibility
        let useCommand = defaults.string(forKey: Pref.switcherModifier) == "command"
        modifier = useCommand ? .maskCommand : .maskAlternate

        if wanted {
            if tap == nil {
                tap = EventTap(types: [.keyDown, .keyUp, .flagsChanged]) { [weak self] type, event in
                    self?.handle(type: type, event: event) ?? true
                }
            }
            isRunning = tap?.start() ?? false
            setSystemSwitcher(disabled: isRunning && useCommand)
        } else {
            cancel()
            tap?.stop()
            tap = nil
            isRunning = false
            setSystemSwitcher(disabled: false)
        }
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
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        recent.removeAll { $0 == app.processIdentifier }
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
                open(reverse: flags.contains(.maskShift))
                return false
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

    private func open(reverse: Bool) {
        items = WindowList.collect(recent: recent)
        guard !items.isEmpty else { return }
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
        if UserDefaults.standard.bool(forKey: Pref.switcherPreviews) {
            refreshPreviews()
        }

        // Небольшая задержка: при быстром ⌥Tab панель не мигает.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if self.active { self.panel.show() }
        }
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
