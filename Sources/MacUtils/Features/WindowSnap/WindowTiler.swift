import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import MUCore

/// «Окна»: раскладка окон как в Windows. Окно, перетащенное к краю экрана,
/// встаёт на половину, к углу — на четверть, к верхнему краю — на весь экран.
/// То же — горячими клавишами (по умолчанию ⌃⌥ + стрелки / U I J K / Enter / C / ⌫).
@MainActor
final class WindowTiler: ObservableObject {
    static let shared = WindowTiler()

    @Published private(set) var isRunning = false
    /// Сочетания, которые не удалось зарегистрировать (заняты).
    @Published private(set) var failedHotKeys: [String] = []

    enum Target: Equatable {
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
        case maximize, center
    }

    /// Мышь — глобальным монитором NSEvent, а не listen-only CGEventTap. Такой tap macOS 27 отдаёт мышь только по
    /// разрешению: на стенде без разрешений он создаётся без ошибки и не получает ни одного события, а монитор
    /// получает — ошибки в журнале нет, а прилипание молчит. Монитор тоже только наблюдает: система его не ждёт,
    /// клики не задерживаются; разрешений для мыши ему не нужно.
    private var mouseMonitor: Any?
    /// Сочетания ловим своим перехватом клавиш: в новых macOS Carbon перестал отдавать ⌃⌥ + стрелки.
    private var keyTap: EventTap?
    let preview = SnapPreview()
    /// Прежние рамки окон (в координатах AX) для «вернуть размер».
    private var restoreFrames: [CGWindowID: CGRect] = [:]

    // Перетаскивание. Окно под нажатием — из списка WindowServer (номер, программа, рамка в координатах CG = AX):
    // AX при нажатии не спрашиваем вовсе — медленная программа (Electron при первом запросе строит дерево доступности
    // сотни миллисекунд) держала бы очередь, и следующие нажатия получали бы «нет ответа».
    private(set) var dragWindow: WindowDragRules.ScreenWindow?
    private(set) var dragMoving = false
    private(set) var dragTarget: Target?
    private var dragScreen: NSScreen?
    private var dragPoint: CGPoint?
    private var lastProbe: TimeInterval = 0
    private var probes = 0
    private var dragStarted: TimeInterval = 0
    /// Номер текущего нажатия/перетаскивания: ответы AX из фона для устаревшего нажатия отбрасываются.
    private var dragGeneration = 0
    /// Номер последней раскладки по отпусканию: в очереди AX выполняется только она, устаревшие пропускаются.
    private var snapGeneration = 0
    private var probing = false
    /// Диагностика перетаскивания: по записи на шаг, только после настоящего перетаскивания (простые клики не пишем).
    private var dragged = false
    private var downNote: String?
    private var notedSteps: Set<String> = []
    /// Вся работа с Accessibility — здесь, не в обработчике tap и не на главном потоке. При перетаскивании — только
    /// рамка по отпусканию; нажатия и движение сюда не попадают.
    private let axQueue = DispatchQueue(label: "macutils.windowsnap.ax", qos: .userInteractive)
    /// Список окон WindowServer — своя очередь: он отвечает за миллисекунды и не зависит от программ.
    private let windowServerQueue = DispatchQueue(label: "macutils.windowsnap.ws", qos: .userInteractive)

    /// Источники данных (в тестах — заглушки): окна на экране спереди назад, рамка окна у WindowServer,
    /// постановка рамки через AX (возвращает строку для журнала: время ответа и итог, только числа).
    nonisolated(unsafe) var windowList: @Sendable () -> [WindowDragRules.ScreenWindow] = { WindowTiler.screenWindows() }
    nonisolated(unsafe) var windowBounds: @Sendable (CGWindowID) -> CGRect? = { WindowTiler.bounds(of: $0) }
    nonisolated(unsafe) var placeWindow: @Sendable (WindowDragRules.ScreenWindow, CGRect) -> String = { WindowTiler.place($0, at: $1) }

    private init() {}

    // MARK: - Включение

    func sync() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Pref.windowSnap) && Permissions.accessibility
        let wantsDrag = enabled && defaults.bool(forKey: Pref.windowSnapDrag)

        if wantsDrag {
            if mouseMonitor == nil {
                mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                    MainActor.assumeIsolated { self?.handleMouse(event) }
                }
                let systemTiling = UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true
                Log.window.notice("Окна: перетаскивание monitor=\(self.mouseMonitor != nil ? 1 : 0) ax=\(Permissions.accessibility ? 1 : 0) listenEvents=\(CGPreflightListenEventAccess() ? 1 : 0) systemTiling=\(systemTiling ? 1 : 0) screens=\(NSScreen.screens.count)")
                if mouseMonitor == nil { Log.window.error("Окна: не удалось подписаться на мышь") }
            }
        } else {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            endDrag()
        }

        registerHotKeys(enabled: enabled)
        isRunning = enabled && (!wantsDrag || mouseMonitor != nil)
    }

    private func registerHotKeys(enabled: Bool) {
        // Прежние регистрации Carbon (до этой версии) снимаем.
        for index in Self.bindings.indices {
            HotKeyCenter.shared.unregister(id: HotKeyID.windowSnapBase + UInt32(index))
        }
        guard enabled else {
            keyTap?.stop()
            keyTap = nil
            failedHotKeys = []
            return
        }
        if keyTap == nil {
            keyTap = EventTap(types: [.keyDown]) { _, event in
                WindowTiler.shared.handleKey(event)
            }
        }
        failedHotKeys = keyTap?.start() == true ? [] : Self.bindings.map { WindowSnapModifier.current.symbols + $0.label }
    }

    /// true — пропустить клавишу дальше, false — это наше сочетание, поглощаем.
    private func handleKey(_ event: CGEvent) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard event.flags.intersection(relevant) == WindowSnapModifier.current.flags else { return true }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard let binding = Self.bindings.first(where: { $0.keyCode == code }) else { return true }
        // Автоповтор при удержании не переносит окно по мониторам.
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { perform(binding.action) }
        return false
    }

    enum Action {
        case snap(Target)
        case restore
    }

    struct Binding {
        let keyCode: Int
        let label: String
        let title: String
        let action: Action
    }

    static let bindings: [Binding] = [
        Binding(keyCode: kVK_LeftArrow, label: "←", title: "Левая половина", action: .snap(.left)),
        Binding(keyCode: kVK_RightArrow, label: "→", title: "Правая половина", action: .snap(.right)),
        Binding(keyCode: kVK_UpArrow, label: "↑", title: "Верхняя половина", action: .snap(.top)),
        Binding(keyCode: kVK_DownArrow, label: "↓", title: "Нижняя половина", action: .snap(.bottom)),
        Binding(keyCode: kVK_ANSI_U, label: "U", title: "Левая верхняя четверть", action: .snap(.topLeft)),
        Binding(keyCode: kVK_ANSI_I, label: "I", title: "Правая верхняя четверть", action: .snap(.topRight)),
        Binding(keyCode: kVK_ANSI_J, label: "J", title: "Левая нижняя четверть", action: .snap(.bottomLeft)),
        Binding(keyCode: kVK_ANSI_K, label: "K", title: "Правая нижняя четверть", action: .snap(.bottomRight)),
        Binding(keyCode: kVK_Return, label: "↩", title: "На весь экран", action: .snap(.maximize)),
        Binding(keyCode: kVK_ANSI_C, label: "C", title: "По центру", action: .snap(.center)),
        Binding(keyCode: kVK_Delete, label: "⌫", title: "Вернуть прежний размер", action: .restore),
    ]

    // MARK: - Горячие клавиши

    func perform(_ action: Action) {
        guard let window = Self.focusedWindow() else {
            Log.window.info("Окна: нет активного окна")
            return
        }
        perform(action, on: window)
    }

    /// Раскладка окна клавишами: короткая вспышка рамки там, куда встало окно, как в Rectangle.
    func perform(_ action: Action, on window: AXUIElement) {
        guard let frame = Self.frame(of: window) else { return }
        switch action {
        case .restore:
            guard let id = AXWindowID.of(window), let previous = restoreFrames.removeValue(forKey: id) else { return }
            Self.setFrame(previous, of: window)
            preview.flash(Self.cocoaRect(fromAX: previous))
        case .snap(let target):
            var screen = Self.screen(containing: frame)
            var targetFrame = Self.frame(for: target, on: screen, window: frame)
            // Повтор той же половины — на следующий монитор.
            if target != .center, Self.isClose(frame, targetFrame), NSScreen.screens.count > 1,
               let index = NSScreen.screens.firstIndex(of: screen) {
                screen = NSScreen.screens[(index + 1) % NSScreen.screens.count]
                targetFrame = Self.frame(for: target, on: screen, window: frame)
            }
            remember(frame, of: window)
            Self.setFrame(targetFrame, of: window)
            preview.flash(Self.cocoaRect(fromAX: targetFrame))
        }
    }

    private func remember(_ frame: CGRect, of window: AXUIElement) {
        guard let id = AXWindowID.of(window) else { return }
        remember(frame, id: id)
    }

    private func remember(_ frame: CGRect, id: CGWindowID) {
        // Помним размер «до раскладки», а не промежуточные половины.
        if restoreFrames[id] == nil || !Self.isSnapped(frame) { restoreFrames[id] = frame }
    }

    // MARK: - Перетаскивание

    enum MouseStep { case down, dragged, up }

    /// Событие глобального монитора: точка — в координатах CG (как у AX и WindowServer), из самого события,
    /// а не текущее положение курсора. Нет точки у события или она вне всех экранов — положение курсора.
    private func handleMouse(_ event: NSEvent) {
        let step: MouseStep
        switch event.type {
        case .leftMouseDown: step = .down
        case .leftMouseDragged: step = .dragged
        case .leftMouseUp: step = .up
        default: return
        }
        let screens = NSScreen.screens.map { Self.axRect(fromCocoa: $0.frame) }
        handleMouse(step, at: WindowDragRules.eventPoint(event.cgEvent?.location, mouse: Self.axPoint(fromCocoa: NSEvent.mouseLocation),
                                                         screens: screens))
    }

    /// Только запоминает события; окно и его движение узнаёт по списку WindowServer в фоне, AX — только по отпусканию.
    func handleMouse(_ step: MouseStep, at point: CGPoint) {
        switch step {
        case .down:
            endDrag()
            let generation = dragGeneration
            // Наши окна, которые принимают мышь (настройки, панель в строке меню) — их нажатие не трогает.
            let ownWindows = Set(NSApp.windows.filter { $0.isVisible && !$0.ignoresMouseEvents }.map(\.windowNumber))
            let ownPID = ProcessInfo.processInfo.processIdentifier
            // Для журнала при отказе: точка события и положение курсора (CG) — расходятся, если точка события не та.
            let mouse = Self.axPoint(fromCocoa: NSEvent.mouseLocation)
            let points = "cg=\(Int(point.x)),\(Int(point.y)) mouse=\(Int(mouse.x)),\(Int(mouse.y))"
            let list = windowList
            windowServerQueue.async { [weak self] in
                let started = ProcessInfo.processInfo.systemUptime
                let result = WindowDragRules.press(at: point, windows: list(), ownPID: ownPID, ownWindows: ownWindows)
                let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.dragGeneration == generation else { return }
                        switch result {
                        case .rejected(let reason):
                            self.noteDown("отклонено: \(reason) \(points)")
                        case .accepted(let window, let height):
                            self.dragWindow = window
                            self.noteDown("принято y=\(height) окно=\(Int(window.bounds.width))x\(Int(window.bounds.height)) " +
                                          "ws=\(ms)мс путь=ws")
                        }
                    }
                }
            }

        case .dragged:
            dragPoint = point
            if !dragged {
                dragged = true
                dragStarted = ProcessInfo.processInfo.systemUptime
                if let downNote { note("down", downNote) }
            }
            guard let window = dragWindow else { return }
            if !dragMoving {
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastProbe > 0.05, !probing else { return }
                lastProbe = now
                probing = true
                probes += 1
                let generation = dragGeneration
                let bounds = windowBounds
                // Окно двигается, а размер прежний — значит, его тащат за заголовок. Рамка — у WindowServer: окно,
                // которое тащит система или сама программа, WindowServer двигает сразу.
                windowServerQueue.async { [weak self] in
                    let now = bounds(CGWindowID(window.number))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.dragGeneration == generation else { return }
                            self.probing = false
                            guard let now, WindowDragRules.isMoveDrag(start: window.bounds, now: now) else { return }
                            self.dragMoving = true
                            let ms = Int((ProcessInfo.processInfo.systemUptime - self.dragStarted) * 1000)
                            self.note("move", "источник=ws через=\(ms)мс проверок=\(self.probes)")
                            self.updateDragTarget()
                        }
                    }
                }
                return
            }
            updateDragTarget()

        case .up:
            if dragged, dragWindow == nil, downNote == nil { note("down", "нет ответа WindowServer") }
            if dragMoving, let window = dragWindow, let target = dragTarget, let screen = dragScreen {
                remember(window.bounds, id: CGWindowID(window.number))
                let frame = Self.frame(for: target, on: screen, window: window.bounds)
                note("up", "раскладка=\(target) экран=\(NSScreen.screens.firstIndex(of: screen).map { $0 + 1 } ?? 0)")
                snapGeneration += 1
                currentSnap = snapGeneration
                let generation = snapGeneration
                let place = placeWindow
                // Даём системе закончить перетаскивание, затем ставим рамку через AX (в фоне, с таймаутом). Если за это время
                // отпустили ещё одно окно, эта раскладка уже не нужна — очередь не копит устаревшие запросы.
                axQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.isCurrentSnap(generation) else { return }
                    let result = place(window, frame)
                    Log.window.notice("Окна: ax \(result, privacy: .public)")
                }
            } else if dragged, dragWindow != nil {
                note("up", dragMoving ? "без зоны" : "окно не сдвинулось, проверок=\(probes)")
            }
            endDrag()
        }
    }

    /// Номер последней раскладки — читается из очереди AX.
    private nonisolated(unsafe) var currentSnap = 0
    private nonisolated func isCurrentSnap(_ generation: Int) -> Bool { currentSnap == generation }

    private func updateDragTarget() {
        guard let point = dragPoint else { return }
        let screens = NSScreen.screens
        let frames = screens.map(\.frame)
        let mouse = Self.cocoaPoint(fromAX: point)
        guard let index = WindowDragRules.screenIndex(containing: mouse, frames: frames) else {
            dragTarget = nil
            dragScreen = nil
            preview.hide()
            return
        }
        let screen = screens[index]
        let target = Self.zone(for: mouse, in: screen.frame, screens: frames)
        guard target != dragTarget || screen != dragScreen else { return }
        dragTarget = target
        dragScreen = screen
        if let target, let start = dragWindow?.bounds {
            note("zone", "\(target) экран=\(index + 1) из \(screens.count)")
            preview.show(Self.cocoaRect(fromAX: Self.frame(for: target, on: screen, window: start)))
        } else {
            preview.hide()
        }
    }

    private func endDrag() {
        dragGeneration += 1
        probing = false
        probes = 0
        dragWindow = nil
        dragMoving = false
        dragTarget = nil
        dragScreen = nil
        dragPoint = nil
        dragged = false
        downNote = nil
        notedSteps = []
        preview.hide()
    }

    /// Итог нажатия пишем, только когда за ним пошло перетаскивание: простые клики журнал не засоряют.
    private func noteDown(_ text: String) {
        downNote = text
        if dragged { note("down", text) }
    }

    /// Шаг перетаскивания в журнал — не больше одной записи на шаг за перетаскивание. Только числа и названия шагов.
    private func note(_ step: String, _ text: String) {
        guard notedSteps.insert(step).inserted else { return }
        Log.window.notice("Окна: \(step, privacy: .public) \(text, privacy: .public)")
    }

    /// Зона у края экрана: углы — четверти, бока — половины, верх — весь экран. Край, за которым вплотную другой
    /// монитор, — не край: курсор уходит через него дальше (`screens` — рамки всех экранов, Cocoa).
    static func zone(for p: NSPoint, in frame: NSRect, screens: [NSRect] = []) -> Target? {
        let edge: CGFloat = 6, corner: CGFloat = 60
        let shared = WindowDragRules.sharedEdges(of: frame, at: p, screens: screens)
        let left = !shared.left && p.x <= frame.minX + edge, right = !shared.right && p.x >= frame.maxX - edge - 1
        let top = !shared.top && p.y >= frame.maxY - edge - 1, bottom = !shared.bottom && p.y <= frame.minY + edge
        let nearLeft = p.x <= frame.minX + corner, nearRight = p.x >= frame.maxX - corner
        let nearTop = p.y >= frame.maxY - corner, nearBottom = p.y <= frame.minY + corner
        if (left && nearTop) || (top && nearLeft) { return .topLeft }
        if (right && nearTop) || (top && nearRight) { return .topRight }
        if (left && nearBottom) || (bottom && nearLeft) { return .bottomLeft }
        if (right && nearBottom) || (bottom && nearRight) { return .bottomRight }
        if left { return .left }
        if right { return .right }
        if top { return .maximize }
        return nil
    }

    // MARK: - Геометрия (координаты AX: от левого верхнего угла основного экрана)

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoaRect(fromAX r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func axRect(fromCocoa r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cocoaPoint(fromAX p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: primaryHeight - p.y) }

    static func axPoint(fromCocoa p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    private static func screen(containing frame: CGRect) -> NSScreen {
        let cocoa = cocoaRect(fromAX: frame)
        return NSScreen.screens.max {
            $0.frame.intersection(cocoa).width * $0.frame.intersection(cocoa).height
                < $1.frame.intersection(cocoa).width * $1.frame.intersection(cocoa).height
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Рамка цели в координатах AX с учётом отступа между окнами.
    static func frame(for target: Target, on screen: NSScreen, window: CGRect) -> CGRect {
        let gap = CGFloat(UserDefaults.standard.integer(forKey: Pref.windowSnapGap))
        let area = screen.visibleFrame.insetBy(dx: gap / 2, dy: gap / 2)
        let halfW = area.width / 2, halfH = area.height / 2
        var r: NSRect
        switch target {
        case .left: r = NSRect(x: area.minX, y: area.minY, width: halfW, height: area.height)
        case .right: r = NSRect(x: area.midX, y: area.minY, width: halfW, height: area.height)
        case .top: r = NSRect(x: area.minX, y: area.midY, width: area.width, height: halfH)
        case .bottom: r = NSRect(x: area.minX, y: area.minY, width: area.width, height: halfH)
        case .topLeft: r = NSRect(x: area.minX, y: area.midY, width: halfW, height: halfH)
        case .topRight: r = NSRect(x: area.midX, y: area.midY, width: halfW, height: halfH)
        case .bottomLeft: r = NSRect(x: area.minX, y: area.minY, width: halfW, height: halfH)
        case .bottomRight: r = NSRect(x: area.midX, y: area.minY, width: halfW, height: halfH)
        case .maximize: r = area
        case .center:
            let visible = screen.visibleFrame
            let w = min(window.width, visible.width), h = min(window.height, visible.height)
            return axRect(fromCocoa: NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h))
        }
        return axRect(fromCocoa: r.insetBy(dx: gap / 2, dy: gap / 2))
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 8 && abs(a.minY - b.minY) < 8 && abs(a.width - b.width) < 16 && abs(a.height - b.height) < 16
    }

    /// Окно уже стоит в одной из раскладок на своём экране.
    private static func isSnapped(_ frame: CGRect) -> Bool {
        let screen = screen(containing: frame)
        let targets: [Target] = [.left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight, .maximize]
        return targets.contains { isClose(frame, self.frame(for: $0, on: screen, window: frame)) }
    }

    // MARK: - Accessibility

    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Окна на экране спереди назад (без рабочего стола), координаты CG.
    nonisolated static func screenWindows() -> [WindowDragRules.ScreenWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap(WindowDragRules.ScreenWindow.init)
    }

    /// Таймаут каждого AX-запроса раскладки: без него — системный, около 6 с.
    nonisolated static let axTimeout: Float = 0.25

    /// Поставить окно (номер и программа — из WindowServer) в рамку через AX. Окно программы ищем по номеру
    /// (`_AXUIElementGetWindow`), а если номер не отдаётся — по совпадению рамки с WindowServer. Для журнала — время и итог.
    nonisolated static func place(_ window: WindowDragRules.ScreenWindow, at frame: CGRect) -> String {
        let started = ProcessInfo.processInfo.systemUptime
        func ms() -> Int { Int((ProcessInfo.processInfo.systemUptime - started) * 1000) }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var value: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        // Первый запрос к Electron-программе может не успеть (строится дерево доступности) — ещё одна попытка.
        if result == .cannotComplete { result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) }
        guard result == .success, let elements = value as? [AXUIElement] else { return "окна=\(result.rawValue) за \(ms())мс" }
        let current = bounds(of: CGWindowID(window.number)) ?? window.bounds
        for element in elements { AXUIElementSetMessagingTimeout(element, axTimeout) }
        let match = elements.first { AXWindowID.of($0) == CGWindowID(window.number) }
            ?? elements.first { candidate in
                guard let rect = self.frame(of: candidate) else { return false }
                return abs(rect.minX - current.minX) < 2 && abs(rect.minY - current.minY) < 2
                    && abs(rect.width - current.width) < 2 && abs(rect.height - current.height) < 2
            }
        guard let match else { return "окно не найдено среди \(elements.count) за \(ms())мс" }
        setFrame(frame, of: match)
        return "рамка за \(ms())мс"
    }

    /// Рамка окна у WindowServer (координаты CG).
    nonisolated static func bounds(of id: CGWindowID) -> CGRect? {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        return info.first.flatMap(WindowDragRules.ScreenWindow.init)?.bounds
    }

    nonisolated static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// Позиция, размер и ещё раз позиция: при переезде на другой монитор
    /// система может подрезать размер по старому экрану.
    nonisolated static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var origin = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }
}

/// Модификатор для горячих клавиш окон.
enum WindowSnapModifier: String, CaseIterable, Identifiable {
    case controlOption, controlCommand, optionCommand

    var id: String { rawValue }

    var symbols: String {
        switch self {
        case .controlOption: return "⌃⌥"
        case .controlCommand: return "⌃⌘"
        case .optionCommand: return "⌥⌘"
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .controlOption: return [.maskControl, .maskAlternate]
        case .controlCommand: return [.maskControl, .maskCommand]
        case .optionCommand: return [.maskAlternate, .maskCommand]
        }
    }

    var carbon: Int {
        switch self {
        case .controlOption: return controlKey | optionKey
        case .controlCommand: return controlKey | cmdKey
        case .optionCommand: return optionKey | cmdKey
        }
    }

    static var current: WindowSnapModifier {
        WindowSnapModifier(rawValue: UserDefaults.standard.string(forKey: Pref.windowSnapModifier) ?? "") ?? .controlOption
    }
}

/// Полупрозрачная подсказка, куда встанет окно.
@MainActor
final class SnapPreview {
    private var panel: NSPanel?
    /// Номер показа: скрытие после вспышки не гасит показ, начатый позже.
    private var shown = 0

    /// Подсказка показана (модель): под тестами панель на экран не выводится, а показ виден здесь.
    private(set) var isVisible = false

    /// Номер окна подсказки у WindowServer (для стенда).
    var windowNumber: Int? { panel?.windowNumber }
    var frame: NSRect? { panel?.frame }

    func show(_ frame: NSRect) {
        shown += 1
        isVisible = true
        let panel = self.panel ?? make()
        panel.setFrame(frame.insetBy(dx: 4, dy: 4), display: true)
        panel.orderFrontRegardlessOnScreen("SnapPreview")
    }

    /// Короткая вспышка рамки после раскладки клавишами, без анимации окна.
    func flash(_ frame: NSRect, duration: TimeInterval = 0.25) {
        show(frame)
        let token = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shown == token else { return }
                self.hide()
            }
        }
    }

    func hide() {
        shown += 1
        isVisible = false
        panel?.orderOut(nil)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)))
        self.panel = panel
        return panel
    }
}

/// Чистые правила перетаскивания окна (для тестов).
enum WindowDragRules {
    /// Высота полосы заголовка с панелью инструментов, за которую окно можно тащить к краю. На macOS 27 (стенд) полоса над
    /// содержимым: заголовок без панели 32 pt, компактная панель 40, SwiftUI-окно с панелью 52, объединённая панель
    /// (Finder, Safari, Заметки) 66, панель с заголовком над ней 83, панель настроек 88. Прежние 40 pt отбрасывали
    /// нижнюю часть панели. Лишняя высота безопасна: тянут содержимое (выделение, список) — окно не двигается,
    /// и `moveSource` перетаскиванием окна это не считает.
    static let titleBarHeight: CGFloat = 96

    /// Нажатие пришлось на верхнюю полосу окна (координаты AX).
    static func isTitleBarPoint(_ point: CGPoint, in frame: CGRect) -> Bool {
        point.y - frame.minY < titleBarHeight
    }

    /// Окно из списка WindowServer (CGWindowListCopyWindowInfo), координаты CG.
    struct ScreenWindow: Equatable {
        var number: Int
        var pid: pid_t
        var layer: Int
        var alpha: Double
        var bounds: CGRect

        init(number: Int, pid: pid_t, layer: Int, alpha: Double = 1, bounds: CGRect) {
            self.number = number; self.pid = pid; self.layer = layer; self.alpha = alpha; self.bounds = bounds
        }

        init?(_ info: [String: Any]) {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            self.init(number: number, pid: pid_t(pid), layer: info[kCGWindowLayer as String] as? Int ?? 0,
                      alpha: info[kCGWindowAlpha as String] as? Double ?? 1, bounds: bounds)
        }
    }

    /// Обычные окна и окна «поверх всех» (kCGFloatingWindowLevel). Меню, Dock, строка меню и панели (≥ 8) не трогаем.
    static let draggableLayers: Set<Int> = [Int(CGWindowLevelForKey(.normalWindow)), Int(CGWindowLevelForKey(.floatingWindow))]

    /// Уровень курсора и выше. На macOS 27 (трансляция экрана, удалённый доступ) WindowServer рисует курсор отдельным окном
    /// этого уровня, левый верхний угол — ровно в точке курсора: оно первым в списке накрывало каждое нажатие (1.6.10).
    /// Клики такие окна не забирают.
    static let passThroughLayer = Int(CGWindowLevelForKey(.cursorWindow))
    /// Картинка перетаскивания (drag & drop) — тоже под курсором и клик не забирает.
    static let draggingLayer = Int(CGWindowLevelForKey(.draggingWindow))
    /// Окна не больше этого по обеим сторонам — курсор или его тень (на macOS 27 бывают и не на уровне курсора).
    static let tinySide: CGFloat = 64

    /// Окно, сквозь которое клик проходит дальше: прозрачное, курсор, картинка перетаскивания, крошечное.
    static func passesClicks(_ window: ScreenWindow) -> Bool {
        window.alpha <= 0 || window.layer >= passThroughLayer || window.layer == draggingLayer
            || (window.bounds.width <= tinySide && window.bounds.height <= tinySide)
    }

    /// Чужое обычное окно, которому достался клик (список окон — спереди назад). nil — клик не по чужому обычному окну:
    /// по нашему окну, меню, панели или вообще мимо. Окна, сквозь которые клик проходит, и наши окна, пропускающие мышь
    /// (тёплый экран, рисование «сквозь клики»), пропускаем — смотрим под них.
    static func windowUnder(_ point: CGPoint, windows: [ScreenWindow], ownPID: pid_t, ownWindows: Set<Int>) -> ScreenWindow? {
        for window in windows where window.bounds.contains(point) {
            if window.pid == ownPID {
                if ownWindows.contains(window.number) { return nil }
                continue
            }
            if passesClicks(window) { continue }
            return draggableLayers.contains(window.layer) ? window : nil
        }
        return nil
    }

    static func ownerUnder(_ point: CGPoint, windows: [ScreenWindow], ownPID: pid_t, ownWindows: Set<Int>) -> pid_t? {
        windowUnder(point, windows: windows, ownPID: ownPID, ownWindows: ownWindows)?.pid
    }

    enum PressResult: Equatable {
        /// Нажатие на верхнюю полосу чужого обычного окна; `height` — от верха окна, pt.
        case accepted(ScreenWindow, height: Int)
        /// Почему нет (для журнала: только числа и названия шагов).
        case rejected(String)
    }

    /// Нажатие только по списку WindowServer: окно под точкой и попадание в верхние `titleBarHeight` по его рамке.
    static func press(at point: CGPoint, windows: [ScreenWindow], ownPID: pid_t, ownWindows: Set<Int>) -> PressResult {
        guard let window = windowUnder(point, windows: windows, ownPID: ownPID, ownWindows: ownWindows) else {
            return .rejected("не чужое обычное окно " + underNote(point, windows: windows, ownPID: ownPID, ownWindows: ownWindows))
        }
        let height = Int((point.y - window.bounds.minY).rounded())
        guard isTitleBarPoint(point, in: window.bounds) else {
            return .rejected("ниже заголовка y=\(height) полоса=\(Int(titleBarHeight))")
        }
        return .accepted(window, height: height)
    }

    /// Для журнала при отказе: первое окно под точкой и сколько их всего. Только числа: наше ли, уровень, прозрачность, размер.
    static func underNote(_ point: CGPoint, windows: [ScreenWindow], ownPID: pid_t, ownWindows: Set<Int>) -> String {
        let under = windows.filter { $0.bounds.contains(point) }
        guard let first = under.first else { return "первое=- окон=0" }
        return "первое own=\(first.pid == ownPID ? 1 : 0) inOwn=\(ownWindows.contains(first.number) ? 1 : 0) layer=\(first.layer) " +
            "alpha=\(String(format: "%.2f", first.alpha)) \(Int(first.bounds.width))x\(Int(first.bounds.height)) окон=\(under.count)"
    }

    /// Точка нажатия (CG): из события; нет её или она вне всех экранов (`screens`, CG) — положение курсора.
    static func eventPoint(_ event: CGPoint?, mouse: CGPoint, screens: [CGRect]) -> CGPoint {
        guard let event, screens.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(event) }) else { return mouse }
        return event
    }

    /// Окно сдвинулось, а размер прежний — его тащат за заголовок, а не меняют размер.
    static func isMoveDrag(start: CGRect, now: CGRect) -> Bool {
        now.origin != start.origin && abs(now.width - start.width) < 1 && abs(now.height - start.height) < 1
    }

    /// Экран под точкой (координаты Cocoa). NSMouseInRect включает верхний и левый края (курсор, прижатый к верху
    /// основного экрана, стоит ровно на maxY) и не включает нижний и правый — до них курсор не доходит.
    static func screenIndex(containing p: NSPoint, frames: [NSRect]) -> Int? {
        frames.firstIndex { NSMouseInRect(p, $0, false) }
    }

    /// Края экрана `frame`, за которыми у точки `p` вплотную другой монитор (координаты Cocoa).
    static func sharedEdges(of frame: NSRect, at p: NSPoint, screens: [NSRect]) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) {
        var edges = (left: false, right: false, top: false, bottom: false)
        for other in screens where other != frame {
            let besideY = p.y >= other.minY && p.y <= other.maxY, besideX = p.x >= other.minX && p.x <= other.maxX
            if besideY, abs(other.maxX - frame.minX) < 1 { edges.left = true }
            if besideY, abs(other.minX - frame.maxX) < 1 { edges.right = true }
            if besideX, abs(other.minY - frame.maxY) < 1 { edges.top = true }
            if besideX, abs(other.maxY - frame.minY) < 1 { edges.bottom = true }
        }
        return edges
    }
}
