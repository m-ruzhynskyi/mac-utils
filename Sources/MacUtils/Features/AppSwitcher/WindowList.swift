// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import CoreGraphics

/// Одна карточка переключателя — одно окно, как в Mission Control.
struct SwitcherItem: Identifiable {
    let id: String
    let app: NSRunningApplication
    let appName: String
    let title: String
    let icon: NSImage
    let windowID: CGWindowID?
    let axWindow: AXUIElement?
    let isMinimized: Bool

    var pid: pid_t { app.processIdentifier }
    var isHidden: Bool { app.isHidden }
    /// Подпись под превью: заголовок окна, а без него — имя приложения.
    var label: String { title.isEmpty ? appName : title }
}

/// Собирает окна для переключателя: обычные окна текущего рабочего стола
/// (по порядку на экране, спереди назад), затем свёрнутые и окна скрытых приложений.
/// Служебные окна, панели и приложения без окон не попадают в список.
@MainActor
enum WindowList {
    private static let minSize = CGSize(width: 100, height: 60)

    static func collect(recent: [pid_t]) -> [SwitcherItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ownPID }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first })

        var axCache: [pid_t: [AXWindowInfo]?] = [:]
        func axWindows(_ pid: pid_t) -> [AXWindowInfo]? {
            if let cached = axCache[pid] { return cached }
            let value = AXWindowInfo.windows(pid: pid)
            axCache[pid] = value
            return value
        }

        var items: [SwitcherItem] = []
        var used = Set<CGWindowID>()

        // 1. Видимые окна текущего рабочего стола, спереди назад.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let app = apps[pid],
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= minSize.width, bounds.height >= minSize.height else { continue }

            let cgTitle = info[kCGWindowName as String] as? String ?? ""
            var ax: AXWindowInfo?
            if let windows = axWindows(pid) {
                // Приложение отвечает по AX: берём только настоящие окна.
                ax = windows.first { $0.windowID == number }
                    ?? windows.first { $0.windowID == nil && $0.frame == bounds && (cgTitle.isEmpty || $0.title == cgTitle) }
                guard let ax, ax.isStandard else { continue }
            }
            used.insert(number)
            items.append(SwitcherItem(id: "w\(number)", app: app, appName: name(of: app),
                                      title: ax?.title ?? cgTitle, icon: icon(of: app),
                                      windowID: number, axWindow: ax?.element, isMinimized: false))
        }

        // 2. Свёрнутые окна и окна скрытых приложений — после видимых,
        //    по последнему использованию приложения.
        let order = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let rest = apps.values.sorted {
            (order[$0.processIdentifier] ?? Int.max, $0.processIdentifier)
                < (order[$1.processIdentifier] ?? Int.max, $1.processIdentifier)
        }
        for app in rest {
            guard let windows = axWindows(app.processIdentifier) else { continue }
            for (index, window) in windows.enumerated() where window.isStandard {
                guard window.isMinimized || app.isHidden else { continue }
                if let id = window.windowID, used.contains(id) { continue }
                guard window.frame.width >= minSize.width, window.frame.height >= minSize.height else { continue }
                if let id = window.windowID { used.insert(id) }
                let key = window.windowID.map { "w\($0)" } ?? "ax\(app.processIdentifier)-\(index)"
                items.append(SwitcherItem(id: key, app: app, appName: name(of: app), title: window.title,
                                          icon: icon(of: app), windowID: window.windowID,
                                          axWindow: window.element, isMinimized: window.isMinimized))
            }
        }
        Log.switcher.debug("Окон в переключателе: \(items.count)")
        return items
    }

    private static func name(of app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "?"
    }

    private static func icon(of app: NSRunningApplication) -> NSImage {
        app.icon ?? NSWorkspace.shared.icon(for: .application)
    }
}

/// Окно приложения по данным Accessibility.
struct AXWindowInfo {
    let element: AXUIElement
    let windowID: CGWindowID?
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let isStandard: Bool

    /// nil — приложение не ответило по AX (тогда окна проверяются только по CG).
    static func windows(pid: pid_t) -> [AXWindowInfo]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return nil }
        return elements.map(AXWindowInfo.init)
    }

    init(_ element: AXUIElement) {
        self.element = element
        windowID = AXWindowID.of(element)
        title = Self.string(element, kAXTitleAttribute) ?? ""
        isMinimized = Self.bool(element, kAXMinimizedAttribute) ?? false
        let role = Self.string(element, kAXRoleAttribute)
        let subrole = Self.string(element, kAXSubroleAttribute)
        isStandard = role == kAXWindowRole as String
            && (subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String)
        var origin = CGPoint.zero, size = CGSize.zero
        if let position = Self.value(element, kAXPositionAttribute) { AXValueGetValue(position, .cgPoint, &origin) }
        if let sizeValue = Self.value(element, kAXSizeAttribute) { AXValueGetValue(sizeValue, .cgSize, &size) }
        frame = CGRect(origin: origin, size: size)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }

    private static func value(_ element: AXUIElement, _ name: String) -> AXValue? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}

/// CGWindowID окна Accessibility через закрытую `_AXUIElementGetWindow`.
enum AXWindowID {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let function: GetWindow? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    static func of(_ element: AXUIElement) -> CGWindowID? {
        guard let function else { return nil }
        var id: CGWindowID = 0
        return function(element, &id) == .success && id != 0 ? id : nil
    }
}

/// Надёжная активация выбранного окна из фонового процесса.
@MainActor
enum WindowActivation {
    static func activate(_ item: SwitcherItem) {
        let app = item.app
        if app.isHidden { app.unhide() }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        let window = item.axWindow ?? findWindow(item, in: appElement)

        if let window {
            if item.isMinimized || (attribute(window, kAXMinimizedAttribute) as? Bool) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            app.activate(options: [])
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        } else {
            app.activate(options: [])
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// Если AX-окно не сохранилось — ищем его по номеру, затем по заголовку.
    private static func findWindow(_ item: SwitcherItem, in appElement: AXUIElement) -> AXUIElement? {
        guard let windows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        if let id = item.windowID, let match = windows.first(where: { AXWindowID.of($0) == id }) {
            return match
        }
        return windows.first { (attribute($0, kAXTitleAttribute) as? String) == item.title }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
