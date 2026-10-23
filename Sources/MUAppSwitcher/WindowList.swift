import AppKit
import ApplicationServices
import CoreGraphics
import MUCore

/// Одна карточка переключателя — одно окно, как в Mission Control.
package struct SwitcherItem: Identifiable {
    package let id: String
    package let app: NSRunningApplication
    package let appName: String
    package let title: String
    package let icon: NSImage
    package let windowID: CGWindowID?
    package let axWindow: AXUIElement?
    package let isMinimized: Bool

    package var pid: pid_t { app.processIdentifier }
    package var isHidden: Bool { app.isHidden }
    /// Подпись под превью: заголовок окна, а без него — имя приложения.
    package var label: String { title.isEmpty ? appName : title }
}

/// Собирает окна для переключателя: обычные окна текущего рабочего стола
/// (по порядку на экране, спереди назад), затем свёрнутые и окна скрытых приложений.
/// Служебные окна, панели и приложения без окон не попадают в список.
package enum WindowList {
    private static let minSize = CGSize(width: 100, height: 60)

    /// Сколько секунд суммарно можно ходить в Accessibility за один сбор: зависшее приложение не должно растягивать сбор
    /// (AX-запрос к нему ждёт свой таймаут). Приложения сверх бюджета берутся только по CG, без проверки через AX.
    package static let axBudget: TimeInterval = 1.0

    /// Собирает список. Вызывается НЕ из обработчика tap и не на главном потоке: AX-запросы могут быть медленными.
    /// `axBudget: 0` — только CG (быстрый черновик без Accessibility, пока идёт полный сбор).
    /// Программа и то, что про неё читается из NSWorkspace: снимается на главном потоке (Apple гарантирует актуальность
    /// этих свойств только там), а в фон уходит готовый снимок.
    package struct AppInfo {
        package let app: NSRunningApplication
        package let name: String
        package let icon: NSImage
        package let isHidden: Bool
        /// Только у самого Mac Utils: его окна из `NSApp.windows` (к своему процессу AX не ходим — из фона это падение AppKit).
        package var ownWindows: [OwnWindow]?
    }

    /// Своё окно для переключателя — снимок с главного потока.
    package struct OwnWindow: Equatable {
        package let number: CGWindowID
        package let title: String
        package let isMinimized: Bool
        package let isVisible: Bool
    }

    package static var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    /// Mac Utils в своём переключателе — пока у него есть значок в Dock (открыт редактор или трансляция, либо
    /// включено «Показывать в Dock»); с `.accessory` его в списке нет.
    @MainActor
    package static func snapshotApps(includeSelf: Bool? = nil) -> UncheckedSendable<[pid_t: AppInfo]> {
        let includeSelf = includeSelf ?? (NSApp.activationPolicy() == .regular)
        let ownPID = ownPID
        var apps = Dictionary(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ownPID }
            .map { app in
                (app.processIdentifier, AppInfo(app: app, name: app.localizedName ?? app.bundleIdentifier ?? "?",
                                                 icon: app.icon ?? NSWorkspace.shared.icon(for: .application), isHidden: app.isHidden))
            }, uniquingKeysWith: { first, _ in first })
        if includeSelf {
            let app = NSRunningApplication.current
            apps[ownPID] = AppInfo(app: app, name: app.localizedName ?? "Mac Utils", icon: NSApp.applicationIconImage ?? icon(of: app),
                                   isHidden: NSApp.isHidden, ownWindows: ownWindows(NSApp.windows))
        }
        return UncheckedSendable(apps)
    }

    /// Свои обычные окна: редактор, просмотр трансляции, настройки. Панели (в том числе сам переключатель), оверлеи,
    /// окна без заголовка и не на обычном уровне — нет. `canBecomeMain` у не показанного (свёрнутого) окна всегда false —
    /// проверяем его только у показанного.
    @MainActor
    package static func isSwitchable(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && (!window.isVisible || window.canBecomeMain) && window.styleMask.contains(.titled)
            && !window.title.isEmpty && window.level == .normal && !window.ignoresMouseEvents
    }

    @MainActor
    package static func ownWindows(_ windows: [NSWindow]) -> [OwnWindow] {
        windows.filter { isSwitchable($0) && ($0.isVisible || $0.isMiniaturized) && $0.windowNumber > 0 }.map {
            OwnWindow(number: CGWindowID($0.windowNumber), title: $0.title, isMinimized: $0.isMiniaturized, isVisible: $0.isVisible)
        }
    }

    /// Свои окна, которых нет среди видимых по CG (свёрнутые или все — если Mac Utils скрыт), в порядке `NSApp.windows`.
    package static func ownBackground(_ windows: [OwnWindow], appHidden: Bool, used: Set<CGWindowID>) -> [OwnWindow] {
        windows.filter { ($0.isMinimized || appHidden) && !used.contains($0.number) }
    }

    /// Ключи видимых окон текущего рабочего стола (`w<номер>`): быстрый запрос CG без Accessibility.
    package static func visibleWindowKeys() -> Set<String> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? UInt32 else { return nil }
            return "w\(number)"
        })
    }

    package static func collect(recent: [pid_t], apps snapshot: UncheckedSendable<[pid_t: AppInfo]>,
                        axBudget: TimeInterval = WindowList.axBudget) -> [SwitcherItem] {
        let deadline = Date().addingTimeInterval(axBudget)
        let infos = snapshot.value
        let apps = infos.mapValues(\.app)

        var axCache: [pid_t: [AXWindowInfo]?] = [:]
        func axWindows(_ pid: pid_t) -> [AXWindowInfo]? {
            if let cached = axCache[pid] { return cached }
            guard Date() < deadline else { return nil }
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

            // Свои окна — только из снимка `NSApp.windows`, без AX.
            if let own = infos[pid]?.ownWindows {
                guard let window = own.first(where: { $0.number == number }) else { continue }
                used.insert(number)
                items.append(SwitcherItem(id: "w\(number)", app: app, appName: infos[pid]?.name ?? name(of: app), title: window.title,
                                          icon: infos[pid]?.icon ?? icon(of: app), windowID: number, axWindow: nil, isMinimized: false))
                continue
            }
            let cgTitle = info[kCGWindowName as String] as? String ?? ""
            var ax: AXWindowInfo?
            if let windows = axWindows(pid) {
                // Приложение отвечает по AX: берём только настоящие окна.
                ax = windows.first { $0.windowID == number }
                    ?? windows.first { $0.windowID == nil && $0.frame == bounds && (cgTitle.isEmpty || $0.title == cgTitle) }
                guard let ax, ax.isStandard else { continue }
            }
            used.insert(number)
            items.append(SwitcherItem(id: "w\(number)", app: app, appName: infos[pid]?.name ?? name(of: app),
                                      title: ax?.title ?? cgTitle, icon: infos[pid]?.icon ?? icon(of: app),
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
            if let own = infos[app.processIdentifier]?.ownWindows {
                let info = infos[app.processIdentifier]
                for window in ownBackground(own, appHidden: info?.isHidden ?? false, used: used) {
                    used.insert(window.number)
                    items.append(SwitcherItem(id: "w\(window.number)", app: app, appName: info?.name ?? name(of: app), title: window.title,
                                              icon: info?.icon ?? icon(of: app), windowID: window.number, axWindow: nil,
                                              isMinimized: window.isMinimized))
                }
                // Скрытый Mac Utils, окна которого AppKit не отдал: одна карточка самого приложения — выбор показывает его.
                if info?.isHidden == true, !items.contains(where: { $0.pid == app.processIdentifier }) {
                    items.append(SwitcherItem(id: "app\(app.processIdentifier)", app: app, appName: info?.name ?? name(of: app),
                                              title: "", icon: info?.icon ?? icon(of: app), windowID: nil, axWindow: nil, isMinimized: false))
                }
                continue
            }
            guard let windows = axWindows(app.processIdentifier) else { continue }
            for (index, window) in windows.enumerated() where window.isStandard {
                guard window.isMinimized || (infos[app.processIdentifier]?.isHidden ?? false) else { continue }
                if let id = window.windowID, used.contains(id) { continue }
                guard window.frame.width >= minSize.width, window.frame.height >= minSize.height else { continue }
                if let id = window.windowID { used.insert(id) }
                let key = window.windowID.map { "w\($0)" } ?? "ax\(app.processIdentifier)-\(index)"
                items.append(SwitcherItem(id: key, app: app, appName: infos[app.processIdentifier]?.name ?? name(of: app), title: window.title,
                                          icon: infos[app.processIdentifier]?.icon ?? icon(of: app), windowID: window.windowID,
                                          axWindow: window.element, isMinimized: window.isMinimized))
            }
        }
        Log.switcher.debug("Окон в переключателе: \(items.count)")
        return items
    }

    private static func name(of app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "?"
    }

    package static func icon(of app: NSRunningApplication) -> NSImage {
        app.icon ?? NSWorkspace.shared.icon(for: .application)
    }
}

/// Окно приложения по данным Accessibility.
package struct AXWindowInfo {
    package let element: AXUIElement
    package let windowID: CGWindowID?
    package let title: String
    package let frame: CGRect
    package let isMinimized: Bool
    package let isStandard: Bool

    /// nil — приложение не ответило по AX (тогда окна проверяются только по CG).
    package static func windows(pid: pid_t) -> [AXWindowInfo]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return nil }
        return elements.map(AXWindowInfo.init)
    }

    package init(_ element: AXUIElement) {
        self.element = element
        // Таймаут задаём на самом окне: наследуют ли его дочерние элементы приложения, не гарантировано.
        AXUIElementSetMessagingTimeout(element, 0.15)
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

/// Надёжная активация выбранного окна из фонового процесса.
@MainActor
package enum WindowActivation {
    package static func activate(_ item: SwitcherItem) {
        if item.pid == WindowList.ownPID { return activateOwn(item) }
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

    /// Своё окно — средствами AppKit (AX к своему процессу не ходим): свёрнутое разворачивается.
    private static func activateOwn(_ item: SwitcherItem) {
        if NSApp.isHidden { NSApp.unhide(nil) }
        ScreenOutput.activateApp(ignoringOtherApps: true)
        guard let number = item.windowID, let window = NSApp.window(withWindowNumber: Int(number)) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFrontOnScreen()
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
