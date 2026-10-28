import AppKit
import MUCore
import MUDesign

/// Набор мониторов и положения окон для него (без UI — для тестов).
package enum WindowLayoutRules {
    /// Подпись набора мониторов: порядок не важен.
    package static func signature(_ displays: [String]) -> String {
        displays.sorted().joined(separator: "+")
    }

    /// Ключ окна: программа и заголовок; одинаковые заголовки нумеруются.
    package static func keys(bundleID: String, titles: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return titles.map { title in
            let base = "\(bundleID)|\(title)"
            let count = seen[base, default: 0]
            seen[base] = count + 1
            return count == 0 ? base : "\(base)#\(count)"
        }
    }
}

/// Запоминает, где стояли окна при каждом наборе мониторов, и расставляет их обратно,
/// когда этот набор снова подключён (например, ноутбук вернулся к внешнему монитору).
@MainActor
package final class WindowMemory: ObservableObject {
    package static let shared = WindowMemory()

    package struct Frame: Codable, Equatable {
        package var x, y, width, height: Double
        package var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        package init(_ rect: CGRect) {
            x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
        }
    }

    @Published package private(set) var layouts: [String: [String: Frame]] = [:]
    @Published package private(set) var lastRestored = 0

    private var timer: Timer?
    private var observer: Any?
    /// После смены мониторов система двигает окна сама — какое-то время не сохраняем.
    private var quietUntil = Date.distantPast
    private var currentSignature = ""

    private var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac Utils", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("window-layouts.json")
    }

    package func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.windowMemory) && Permissions.accessibility
        if enabled, timer == nil {
            if let data = try? Data(contentsOf: file),
               let saved = try? JSONDecoder().decode([String: [String: Frame]].self, from: data) {
                layouts = saved
            }
            currentSignature = Self.currentSignature()
            let timer = Timer(timeInterval: 20, repeats: true) { _ in
                MainActor.assumeIsolated { WindowMemory.shared.snapshot() }
            }
            timer.tolerance = 4
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowMemory.shared.screensChanged() }
            }
            snapshot()
        } else if !enabled, let timer {
            timer.invalidate()
            self.timer = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    package var monitorsDescription: String {
        "\(NSScreen.screens.count) \(plural(NSScreen.screens.count, "монитор", "монитора", "мониторов"))"
    }

    package static func currentSignature() -> String {
        WindowLayoutRules.signature(NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let size = CGDisplayBounds(id).size
            return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))-\(Int(size.width))x\(Int(size.height))"
        })
    }

    private func screensChanged() {
        quietUntil = Date().addingTimeInterval(6)
        let signature = Self.currentSignature()
        guard signature != currentSignature else { return }
        currentSignature = signature
        // Даём системе закончить перестановку, потом ставим окна на свои места.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated { _ = WindowMemory.shared.restore() }
        }
    }

    /// Запомнить, где сейчас окна (для текущего набора мониторов).
    package func snapshot(force: Bool = false) {
        guard force || Date() > quietUntil else { return }
        let signature = Self.currentSignature()
        var frames: [String: Frame] = [:]
        for (key, window) in Self.windows() {
            if let frame = WindowTiler.frame(of: window) { frames[key] = Frame(frame) }
        }
        guard !frames.isEmpty else { return }
        // Окна закрытых программ не забываем — вдруг их откроют снова.
        let before = layouts[signature]
        layouts[signature, default: [:]].merge(frames) { $1 }
        // Окна не двигались — файл не переписываем (снимок раз в 20 с).
        guard layouts[signature] != before else { return }
        save()
    }

    /// Расставить окна так, как они стояли при этом наборе мониторов.
    @discardableResult
    package func restore() -> Int {
        guard let saved = layouts[Self.currentSignature()] else { return 0 }
        var moved = 0
        for (key, window) in Self.windows() {
            guard let target = saved[key]?.rect, let frame = WindowTiler.frame(of: window),
                  frame != target else { continue }
            WindowTiler.setFrame(target, of: window)
            moved += 1
        }
        lastRestored = moved
        quietUntil = Date().addingTimeInterval(3)
        return moved
    }

    package func forget() {
        layouts.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(layouts) { try? data.write(to: file, options: .atomic) }
    }

    /// Обычные окна всех видимых программ с ключами.
    private static func windows() -> [(String, AXUIElement)] {
        var result: [(String, AXUIElement)] = []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && !app.isHidden && app.processIdentifier != ownPID {
            guard let bundleID = app.bundleIdentifier else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.2)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            let standard = windows.filter { window in
                var subrole: CFTypeRef?, minimized: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
                AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
                return (subrole as? String) == kAXStandardWindowSubrole as String && (minimized as? Bool) != true
            }
            let titles = standard.map { window -> String in
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                return title as? String ?? ""
            }
            result += zip(WindowLayoutRules.keys(bundleID: bundleID, titles: titles), standard).map { ($0, $1) }
        }
        return result
    }
}
