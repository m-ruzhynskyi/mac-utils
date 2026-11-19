import AppKit
import MUCore

/// Флаги `CGDisplayRegisterReconfigurationCallback` по-человечески (самопроверка мигания).
public enum DisplayChange {
    private static let names: [(UInt32, String)] = [
        (1, "начало"), (2, "перемещён"), (4, "стал основным"), (8, "режим"), (16, "добавлен"), (32, "снят"),
        (256, "включён"), (512, "выключен"), (1024, "зеркалирование"), (2048, "без зеркалирования"), (4096, "форма рабочего стола"),
    ]
    /// Перестройка самого дисплея (то, что мигает): режим, добавление, снятие, вкл/выкл, зеркалирование, смена основного.
    /// Перемещение и «форма рабочего стола» — только раскладка.
    private static let rebuild: UInt32 = 4 | 8 | 16 | 32 | 256 | 512 | 1024 | 2048

    public static func describe(_ flags: UInt32) -> String {
        let parts = names.filter { flags & $0.0 != 0 }.map(\.1)
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    public static func isRebuild(_ flags: UInt32) -> Bool { flags & rebuild != 0 }

    /// Итог для набора событий настоящих дисплеев.
    public static func verdict(physical: [(CGDirectDisplayID, UInt32)]) -> String {
        let rebuilt = physical.filter { isRebuild($0.1) }
        if rebuilt.isEmpty {
            return physical.isEmpty ? "физические дисплеи перестраивались: нет (событий нет)"
                : "физические дисплеи перестраивались: нет (только раскладка: \(physical.map { "\($0.0) \(describe($0.1))" }.joined(separator: "; ")))"
        }
        return "физические дисплеи перестраивались: да (\(rebuilt.map { "\($0.0) \(describe($0.1))" }.joined(separator: "; ")))"
    }
}

/// Строки самопроверки щелчка.
public enum SelfTestText {
    public static func focus(app: String, before: Bool, after: Bool, role: String, frame: CGRect) -> String {
        let field = "\(role) (\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)))"
        let note = before ? " — фокус был в поле и до щелчка, проверка не доказательна" : ""
        return "самопроверка щелчка: \(app) фокус в поле \(after ? "да" : "нет") (до щелчка: \(before ? "да" : "нет"); поле \(field))\(note)"
    }
}

/// События перестройки дисплеев на время самопроверки. Обратный вызов CoreGraphics приходит в главном потоке.
@MainActor
final class DisplayChangeMonitor {
    nonisolated(unsafe) private static var events: [(CGDirectDisplayID, UInt32)] = []
    private static let callback: CGDisplayReconfigurationCallBack = { id, flags, _ in
        events.append((id, flags.rawValue))
    }

    func start() {
        Self.events.removeAll()
        CGDisplayRegisterReconfigurationCallback(Self.callback, nil)
    }

    func stop() { CGDisplayRemoveReconfigurationCallback(Self.callback, nil) }

    func take() -> [(CGDirectDisplayID, UInt32)] {
        defer { Self.events.removeAll() }
        return Self.events
    }
}

/// `--hidden-screen-debug --hs-selftest`: проверка для менеджера правами самой Mac Utils, без событий извне.
/// 1) итог Dock; 2) щелчок в поле ввода Claude и ChatGPT настоящим путём (перехват нажатий → `background`),
/// фокус — через AX, ничего не набирается; 3) три раза выкл → вкл с паузой 2 с, события перестройки дисплеев;
/// 4) выход, как по SIGTERM.
@MainActor
final class HiddenScreenSelfTest {
    private let engine: HiddenScreenEngine
    private let finish: () -> Void
    private let monitor = DisplayChangeMonitor()
    private var hiddenIDs: Set<CGDirectDisplayID> = []

    init(engine: HiddenScreenEngine, finish: @escaping () -> Void) {
        self.engine = engine
        self.finish = finish
    }

    func run() {
        Task { @MainActor in
            await self.steps()
            Log.hiddenScreen.info("самопроверка: готово — выход")
            self.finish()
        }
    }

    private func log(_ text: String) { Log.hiddenScreen.info("\(text, privacy: .public)") }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private func wait(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            await sleep(0.1)
        }
        return condition()
    }

    private func steps() async {
        log("самопроверка: начало")
        guard await wait(20, { engine.phase == .on }) else {
            log("самопроверка: скрытый экран не включился (\(engine.phase)) — выход")
            return
        }
        noteHidden()
        await sleep(1.5)
        log("самопроверка Dock: \(engine.dockSummary)")

        for status in engine.statuses where status.isRunning {
            await click(status)
        }

        monitor.start()
        for cycle in 1...3 {
            _ = monitor.take()
            engine.disable()
            await sleep(2)
            report("выкл №\(cycle)")
            engine.enable()
            engine.setMirrorShown(true)
            _ = await wait(5, { engine.phase == .on })
            noteHidden()
            await sleep(2)
            report("вкл №\(cycle)")
        }
        monitor.stop()
    }

    private func noteHidden() {
        if let id = engine.selfTestDisplayID { hiddenIDs.insert(id) }
    }

    private func report(_ step: String) {
        let events = monitor.take()
        let isHidden: (CGDirectDisplayID) -> Bool = { self.hiddenIDs.contains($0) || CGDisplayVendorNumber($0) == HiddenDisplay.vendorID }
        let physical = events.filter { !isHidden($0.0) }
        let hidden = events.filter { isHidden($0.0) }
        for event in events {
            log("самопроверка мигания, \(step): дисплей \(event.0) (\(isHidden(event.0) ? "скрытый" : "физический")) флаги \(event.1) — \(DisplayChange.describe(event.1))")
        }
        log("самопроверка мигания, \(step): \(DisplayChange.verdict(physical: physical)); скрытый дисплей: \(hidden.isEmpty ? "без событий" : hidden.map { DisplayChange.describe($0.1) }.joined(separator: "; "))")
    }

    private func click(_ status: HiddenScreenEngine.AppStatus) async {
        let name = status.app.name
        engine.selectApp(status.bundleID)
        guard await wait(8, { engine.mirroredApp == status.app && engine.selfTestTarget != nil }), let target = engine.selfTestTarget else {
            log("самопроверка щелчка: \(name) — зеркало не показало окно за 8 с")
            return
        }
        await sleep(1)
        // Chromium (Claude, ChatGPT) отдаёт дерево веб-страницы в AX только по просьбе.
        let app = AXWindowSource.application(target.pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        await sleep(1)
        guard let field = SelfTestAX.inputField(pid: target.pid, window: target.frame) else {
            log("самопроверка щелчка: \(name) — поле ввода через AX не найдено (окно \(target.frame))")
            return
        }
        let before = SelfTestAX.isFocused(field.element, app: app)
        let point = CGPoint(x: field.frame.midX, y: field.frame.midY)
        if let problem = engine.selfTestPress(atTarget: point) {
            log("самопроверка щелчка: \(name) — \(problem)")
            return
        }
        await sleep(1.5)
        let after = SelfTestAX.isFocused(field.element, app: app)
        log(SelfTestText.focus(app: name, before: before, after: after, role: field.role, frame: field.frame))
    }
}

/// Поиск поля ввода и проверка фокуса через AX (только чтение).
enum SelfTestAX {
    static let roles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    /// Поле ввода в окне с рамкой `window`: самое нижнее (поле сообщения у Claude и ChatGPT внизу), затем самое большое.
    static func inputField(pid: pid_t, window: CGRect) -> (element: AXUIElement, frame: CGRect, role: String)? {
        let windows = AXWindowSource.windows(pid: pid).elements
        guard let root = windows.first(where: { element in
            guard let frame = AXGeometry.read(element).frame else { return false }
            return abs(frame.minX - window.minX) < 4 && abs(frame.minY - window.minY) < 4
        }) ?? windows.first else { return nil }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var best: (element: AXUIElement, frame: CGRect, role: String)?
        while !queue.isEmpty, visited < 6000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if let role = AXWindowSource.string(element, kAXRoleAttribute), roles.contains(role),
               let frame = AXGeometry.read(element).frame, frame.width >= 20, frame.height >= 10, window.intersects(frame) {
                if best == nil || frame.maxY > best!.frame.maxY
                    || (frame.maxY == best!.frame.maxY && frame.width * frame.height > best!.frame.width * best!.frame.height) {
                    best = (element, frame, role)
                }
            }
            guard depth < 60 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success {
                queue += AXWindowSource.elements(children).map { ($0, depth + 1) }
            }
        }
        return best
    }

    /// Фокус в поле: у самого поля `AXFocused`, или фокусный элемент программы — поле или внутри него.
    static func isFocused(_ field: AXUIElement, app: AXUIElement) -> Bool {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXFocusedAttribute as CFString, &value) == .success, (value as? Bool) == true {
            return true
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var element = focused as! AXUIElement
        for _ in 0..<20 {
            if CFEqual(element, field) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            element = parent as! AXUIElement
        }
        return false
    }
}
