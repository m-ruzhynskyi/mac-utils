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

    /// Итог шага: мигание = раскладка с затемнением (или долгая, > 0,1 с) либо перестройка настоящего дисплея (HSCR-45:
    /// затемнение системы флагом перестройки не отмечается — прежний итог «нет» вводил в заблуждение).
    public static func verdict(physical: [(CGDirectDisplayID, UInt32)], layouts: [LayoutRecord]) -> String {
        let rebuilt = physical.filter { isRebuild($0.1) }
        let faded = layouts.filter(\.flickered)
        var reasons: [String] = faded.map { "раскладка «\($0.attempt.description)» \(Int(($0.duration * 1000).rounded())) мс" }
        reasons += rebuilt.map { "дисплей \($0.0): \(describe($0.1))" }
        if !reasons.isEmpty { return "мигание: да (\(reasons.joined(separator: "; ")))" }
        let layoutText = layouts.isEmpty ? "раскладки не было" : "раскладка без затемнения"
        let physicalText = physical.isEmpty ? "событий дисплеев нет" : "у дисплеев только \(Set(physical.map { describe($0.1) }).sorted().joined(separator: ", "))"
        return "мигание: нет (\(layoutText); \(physicalText))"
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

        await performance()

        for status in engine.statuses where status.isRunning {
            await click(status)
        }

        monitor.start()
        _ = HiddenScreenLayout.takeHistory()
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

    /// Раздел perf (HSCR-47): по 10 с при текущих настройках и при каждом ключе из подозреваемых — по одному журналу
    /// видно, что из нового тормозит. Во время замера прокручивайте колесом над зеркалом и печатайте в поле.
    private func performance() async {
        // Нагрузку в замере создаёт сама Mac Utils — у менеджера нет прав на синтетические события (HSCR-47, 23:30).
        // Мерим на Claude (у него поток ответа и дерево страницы), иначе — на первой программе с окнами.
        let running = engine.statuses.filter { $0.isRunning && $0.hiddenWindows > 0 }
        if let status = running.first(where: { $0.app == .claude }) ?? running.first {
            engine.selectApp(status.bundleID)
            _ = await wait(8, { engine.mirroredApp == status.app && engine.selfTestTarget != nil })
        }
        guard let app = engine.mirroredApp, engine.selfTestMirrorRect != nil else {
            log("perf: зеркало ничего не показывает — замер пропущен")
            return
        }
        let base = engine.options
        let phases: [(String, (inout HiddenScreenOptions) -> Void)] = [
            ("как есть (\(base.axTree.rawValue), dock \(base.dockAway ? "away" : "keep"), click \(base.clickMode.rawValue))", { _ in }),
            ("--hs-dock=keep", { $0.dockAway = false }),
            ("--hs-click=warp", { $0.clickMode = .warp }),
            ("--hs-warm=off (влияет только на вкл/выкл)", { $0.keepWarm = false }),
            ("--hs-ax=off", { $0.axTree = .off }),
            ("--hs-ax=show (дерево страницы включено всё время, как в 1.11.1)", { $0.axTree = .show }),
        ]
        log("perf: \(phases.count) фаз на \(app.name): в каждой — прокрутка колесом над зеркалом \(Int(PerfLoad.scrollSeconds)) с вверх и \(Int(PerfLoad.scrollSeconds)) с вниз (\(Int(PerfLoad.rate)) событий/с, как от мыши), затем \(Int(PerfLoad.moveSeconds)) с движения курсора над зеркалом; ничего не набирается и не нажимается. Мышь не трогать")
        let origin = CGEvent(source: nil)?.location
        for (name, change) in phases {
            var options = base
            change(&options)
            engine.options = options
            if options.axTree == .show, let pid = engine.selfTestTarget?.pid { engine.requestAccessibility(pid) }
            await sleep(1)
            guard let mirror = engine.selfTestMirrorRect else { break }
            engine.perf.start(view: engine.mirrorView, processes: processes())
            log("perf: фаза «\(name)»")
            let scrolled = await PerfLoad.scroll(over: mirror)
            let scrollFrames = engine.perf.streamFramesSoFar
            let moved = await PerfLoad.move(over: engine.selfTestMirrorRect ?? mirror)
            let sizes = engine.selfTestSizes
            let sample = engine.perf.stop(framePixels: sizes.frame, displayPoints: sizes.display)
            log(sample.line(phase: name) + "; нагрузка: прокрутка \(scrolled) событий, движение \(moved)")
            if let note = PerfLoad.scrollVerdict(framesDuringScroll: scrollFrames) { log("perf: фаза «\(name)» — \(note)") }
            // Пусть передача курсора закончится, прежде чем менять настройки.
            await sleep(1)
        }
        if let origin { PerfLoad.post(.mouseMoved, at: origin) }
        engine.options = base
        engine.releaseAllAccessibility()
    }

    static let perfPhase: Double = 10

    /// Чей процессор считать: Mac Utils, помощник, программы ИИ с дочерними процессами (отрисовка Electron — в них).
    private func processes() -> [(String, [pid_t])] {
        var list: [(String, [pid_t])] = [("Mac Utils", [getpid()])]
        if let helper = engine.selfTestHelperPID { list.append(("помощник", [helper])) }
        for app in engine.runningTargets {
            list.append((app.localizedName ?? app.bundleIdentifier ?? "?", PerfMeter.family(app.processIdentifier)))
        }
        return list
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
        log("самопроверка мигания, \(step): \(DisplayChange.verdict(physical: physical, layouts: HiddenScreenLayout.takeHistory())); скрытый дисплей: \(hidden.isEmpty ? "без событий" : hidden.map { DisplayChange.describe($0.1) }.joined(separator: "; "))")
    }

    /// Увести фокус с поля: на первую кнопку или ссылку окна, иначе `AXFocused = false`. Возвращает «фокус всё ещё в поле».
    private func unfocus(_ field: AXUIElement, app: AXUIElement, pid: pid_t, window: CGRect) async -> Bool {
        if let other = SelfTestAX.focusableControl(pid: pid, window: window) {
            AXUIElementSetAttributeValue(other, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            await sleep(0.3)
            if !SelfTestAX.isFocused(field, app: app) { return false }
        }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanFalse)
        await sleep(0.3)
        return SelfTestAX.isFocused(field, app: app)
    }

    private func click(_ status: HiddenScreenEngine.AppStatus) async {
        let name = status.app.name
        engine.selectApp(status.bundleID)
        guard await wait(8, { engine.mirroredApp == status.app && engine.selfTestTarget != nil }), let target = engine.selfTestTarget else {
            log("самопроверка щелчка: \(name) — зеркало не показало окно за 8 с")
            return
        }
        await sleep(1)
        // Chromium (Claude, ChatGPT) отдаёт дерево веб-страницы в AX только по просьбе (движок просит при показе в зеркале).
        engine.requestAccessibility(target.pid)
        let app = AXWindowSource.application(target.pid)
        await sleep(1)
        guard let field = SelfTestAX.inputField(pid: target.pid, window: target.frame) else {
            log("самопроверка щелчка: \(name) — поле ввода через AX не найдено (окно \(target.frame))")
            return
        }
        var before = SelfTestAX.isFocused(field.element, app: app)
        if before {
            // Чтобы проверка доказывала: снять фокус с поля — на кнопку окна, иначе просто «не в фокусе» (HSCR-46).
            before = await unfocus(field.element, app: app, pid: target.pid, window: target.frame)
            log("самопроверка щелчка: \(name) — фокус снят с поля перед щелчком: \(before ? "нет" : "да")")
        }
        let point = CGPoint(x: field.frame.midX, y: field.frame.midY)
        // Зеркало может быть на миг перекрыто (окно-проба самопроверки скрытия) — ждём до 3 с.
        var problem: String? = engine.selfTestPress(atTarget: point)
        for _ in 0..<6 where problem?.hasPrefix("зеркало перекрыто") == true {
            log("самопроверка щелчка: \(name) — \(problem ?? ""), жду")
            await sleep(0.5)
            problem = engine.selfTestPress(atTarget: point)
        }
        if let problem {
            log("самопроверка щелчка: \(name) — \(problem)")
            return
        }
        await sleep(1.5)
        let after = SelfTestAX.isFocused(field.element, app: app)
        log(SelfTestText.focus(app: name, before: before, after: after, role: field.role, frame: field.frame))
    }
}

/// Поиск поля ввода и проверка фокуса через AX.
@MainActor
enum SelfTestAX {
    static let roles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    /// Кнопка или ссылка окна, которой можно дать фокус (увести фокус с поля перед проверкой щелчка).
    static func focusableControl(pid: pid_t, window: CGRect) -> AXUIElement? {
        guard let root = windowElement(pid: pid, window: window) else { return nil }
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let element = queue.removeFirst()
            visited += 1
            let node = HiddenScreenEngine.axNode(element)
            if ["AXButton", "AXLink"].contains(node.role), node.focusSettable { return element }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success {
                queue += AXWindowSource.elements(children)
            }
        }
        return nil
    }

    static func windowElement(pid: pid_t, window: CGRect) -> AXUIElement? {
        let windows = AXWindowSource.windows(pid: pid).elements
        return windows.first(where: { element in
            guard let frame = AXGeometry.read(element).frame else { return false }
            return abs(frame.minX - window.minX) < 4 && abs(frame.minY - window.minY) < 4
        }) ?? windows.first
    }

    /// Поле ввода в окне с рамкой `window`: самое нижнее (поле сообщения у Claude и ChatGPT внизу), затем самое большое.
    static func inputField(pid: pid_t, window: CGRect) -> (element: AXUIElement, frame: CGRect, role: String)? {
        guard let root = windowElement(pid: pid, window: window) else { return nil }
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

    /// Фокус в поле — та же проверка, что у щелчка через AX.
    static func isFocused(_ field: AXUIElement, app: AXUIElement) -> Bool {
        HiddenScreenEngine.axFocused(field, app: app)
    }
}

/// Нагрузка для замера perf: события как от мыши (HID, без пометки Mac Utils) — их разбирает тот же путь, что и
/// настоящие: колесо над зеркалом → передача курсора → прокрутка в окне ИИ; движение → наведение и сторож курсора.
@MainActor
enum PerfLoad {
    static let scrollSeconds: Double = 5
    static let moveSeconds: Double = 3
    static let rate: Double = 60
    /// Сдвиг за событие, точки (плавная прокрутка трекпада — десятки точек за событие).
    static let scrollStep: Int32 = 24
    /// Кадров за 10 с прокрутки меньше — значит, двигать было нечего (короткий чат).
    static let minScrollFrames = 20

    static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Вверх, потом вниз (чат обычно стоит внизу — сначала вниз двигать было бы нечего). Возвращает число событий.
    static func scroll(over mirror: CGRect) async -> Int {
        post(.mouseMoved, at: CGPoint(x: mirror.midX, y: mirror.midY))
        try? await Task.sleep(nanoseconds: 50_000_000)
        var count = 0
        for direction: Int32 in [1, -1] {
            let end = ProcessInfo.processInfo.systemUptime + scrollSeconds
            while ProcessInfo.processInfo.systemUptime < end {
                if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: direction * scrollStep, wheel2: 0, wheel3: 0) {
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    event.post(tap: .cghidEventTap)
                    count += 1
                }
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / rate))
            }
        }
        return count
    }

    /// Курсор по кругу над картинкой зеркала (наведение и сторож курсора), без нажатий. Возвращает число событий.
    static func move(over mirror: CGRect) async -> Int {
        let radius = min(mirror.width, mirror.height) / 4
        let center = CGPoint(x: mirror.midX, y: mirror.midY)
        let start = ProcessInfo.processInfo.systemUptime
        var count = 0
        while ProcessInfo.processInfo.systemUptime - start < moveSeconds {
            let angle = (ProcessInfo.processInfo.systemUptime - start) * 2 * .pi
            post(.mouseMoved, at: CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
            count += 1
            try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / rate))
        }
        return count
    }

    /// Прокрутка ничего не сдвинула — фаза не доказательна.
    nonisolated static func scrollVerdict(framesDuringScroll: Int) -> String? {
        framesDuringScroll < minScrollFrames
            ? "прокрутке нечего двигать (кадров за прокрутку \(framesDuringScroll)) — фаза недоказательна" : nil
    }
}
