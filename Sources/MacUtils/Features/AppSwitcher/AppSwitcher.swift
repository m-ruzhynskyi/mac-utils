// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// Переключатель приложений: удерживайте ⌥ (или ⌘) и нажимайте Tab.
/// Порядок — по последнему использованию. Пока панель открыта:
/// Tab / ⇧Tab / ← → — выбор, Q — завершить, H — скрыть, Esc — отмена.
@MainActor
final class AppSwitcher: NSObject, ObservableObject {
    static let shared = AppSwitcher()

    @Published private(set) var items: [SwitcherItem] = []
    @Published var selected = 0
    @Published private(set) var isRunning = false
    /// Последние снимки главного окна каждого приложения (pid → превью).
    @Published private(set) var previews: [pid_t: NSImage] = [:]

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
        previews[app.processIdentifier] = nil
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
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        guard !apps.isEmpty else { return }
        let order = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, $0) })
        let sorted = apps.sorted {
            (order[$0.processIdentifier] ?? Int.max) < (order[$1.processIdentifier] ?? Int.max)
        }
        items = sorted.map(SwitcherItem.init)
        // Если активное приложение не первое (например, активно что-то без окон) —
        // всё равно стартуем со «второго», как системный ⌘Tab.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let startsWithFront = items.first?.id == frontPID
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

    /// Снимает главное окно каждого приложения через ScreenCaptureKit.
    /// Пока снимки не готовы, показываются прошлые превью или иконки.
    private func refreshPreviews() {
        guard Permissions.screenRecording else { return }
        let pids = items.prefix(16).map(\.id)
        let frontWindows = Self.frontWindowIDs()
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true) else { return }
            for pid in pids {
                guard self.active else { return }
                guard let windowID = frontWindows[pid],
                      let window = content.windows.first(where: { $0.windowID == windowID }) else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let frame = window.frame
                let scale = min(1, 480 / max(frame.width, frame.height)) * 2
                config.width = max(1, Int(frame.width * scale))
                config.height = max(1, Int(frame.height * scale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                          configuration: config) {
                    self.previews[pid] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                }
            }
        }
    }

    /// Самое верхнее обычное окно каждого приложения (по порядку на экране).
    private static func frontWindowIDs() -> [pid_t: CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [pid_t: CGWindowID] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  result[pid] == nil,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 80, bounds.height > 60 else { continue }
            result[pid] = number
        }
        return result
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
            WindowActivation.activate(items[selected].app)
        }
    }

    private func cancel() {
        active = false
        panel.hide()
    }

    private func quitSelected() {
        guard items.indices.contains(selected) else { return }
        items[selected].app.terminate()
        removeSelected()
    }

    private func hideSelected() {
        guard items.indices.contains(selected) else { return }
        items[selected].app.hide()
        move(1)
    }

    private func removeSelected() {
        items.remove(at: selected)
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

struct SwitcherItem: Identifiable {
    let id: pid_t
    let app: NSRunningApplication
    let name: String
    let icon: NSImage

    init(_ app: NSRunningApplication) {
        id = app.processIdentifier
        self.app = app
        name = app.localizedName ?? app.bundleIdentifier ?? "?"
        icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
    }
}

/// Надёжная активация чужого приложения из фонового процесса.
@MainActor
enum WindowActivation {
    static func activate(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)

        if hasVisibleWindow(pid: app.processIdentifier) {
            app.activate(options: [.activateAllWindows])
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            raiseMainWindow(element)
        } else if unminimizeFirstWindow(element) {
            app.activate(options: [.activateAllWindows])
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        } else if let url = app.bundleURL {
            // Нет окон: как клик по иконке в Dock — приложение откроет новое окно.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            app.activate(options: [.activateAllWindows])
        }
    }

    private static func hasVisibleWindow(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    private static func windows(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    private static func raiseMainWindow(_ element: AXUIElement) {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(value as! AXUIElement, kAXRaiseAction as CFString)
        }
    }

    private static func unminimizeFirstWindow(_ element: AXUIElement) -> Bool {
        for window in windows(of: element) {
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
               (minimized as? Bool) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return true
            }
        }
        return false
    }
}
