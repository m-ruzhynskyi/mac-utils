import AppKit
import ScreenCaptureKit
import SwiftUI
import MUCore

/// Длинный снимок с прокруткой: выделенная область снимается несколько раз
/// в секунду, пока пользователь прокручивает содержимое вниз, а новые строки
/// приклеиваются снизу.
@MainActor
final class ScrollCapture: NSObject, ObservableObject {
    private(set) static var current: ScrollCapture?

    @Published private(set) var capturedHeight = 0
    @Published private(set) var lostTrack = false
    /// Место потеряно на одинаковых строках: HUD советует вернуться к отличающемуся месту, а не «медленнее».
    @Published private(set) var lostOnRepeats = false

    private let rect: NSRect
    private let screen: NSScreen
    /// Фильтр захвата: приходит асинхронно (SCShareableContent), до него кадры не снимаются.
    private var filter: SCContentFilter?
    private let stitcher = StitchWorker()
    private var timer: Timer?
    private var busy = false
    /// Съёмка закончена (готово, отмена, ошибка): повторные Enter, «Готово», предел высоты ничего не делают.
    private var stopped = false
    private var borderPanel: NSPanel?
    private var hudPanel: NSPanel?
    /// Esc — отмена, Enter — готово; работает без фокуса на панели. Клавиши прокрутки — подсказка склейке.
    private var keyTap: EventTap?
    /// Колесо, трекпад и перетаскивание над областью: подсказка склейке, на сколько прокрутилось содержимое.
    private var inputMonitors: [Any] = []
    /// События ввода, ещё не отданные склейке (время по `systemUptime`).
    private var input = ScrollInput()
    /// Когда кадру последний раз раздавались события: нажатия клавиш без перехвата видны только по времени.
    private var lastTaken = ProcessInfo.processInfo.systemUptime
    /// Числовой журнал съёмки (см. `ScrollCaptureLog`); nil — папку журналов не создать.
    private let log = ScrollCaptureLog()
    private let started = ProcessInfo.processInfo.systemUptime
    private var frames = 0
    /// Тиков, пропущенных потому, что прошлый кадр ещё снимался или склеивался.
    private var skippedTicks = 0
    private var counts: [Stitcher.Result: Int] = [:]

    private init(rect: NSRect, screen: NSScreen) {
        self.rect = rect
        self.screen = screen
        super.init()
    }

    static func start(rect: NSRect) {
        guard current == nil else {
            Log.capture.error("Длинный снимок уже идёт")
            return
        }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.displayID else {
            Log.capture.error("Длинный снимок: экран не найден")
            return
        }
        // `current` — сразу: второй запуск, пока идёт запрос SCShareableContent, иначе создал бы вторую съёмку.
        let capture = ScrollCapture(rect: rect.intersection(screen.frame), screen: screen)
        current = capture
        capture.logHeader()
        Log.capture.notice("Длинный снимок: старт, журнал \(capture.log?.url.lastPathComponent ?? "-", privacy: .public)")
        // SCShareableContent может не ответить (завис replayd, открыт системный запрос): тогда съёмка без панелей
        // висела бы в `current`, а новые снимки молча не запускались.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard capture.filter == nil, !capture.stopped else { return }
            Log.capture.error("Длинный снимок: SCShareableContent не ответил")
            capture.stop(reason: "sckTimeout")
            Toast.show("Не удалось начать длинный снимок: нет ответа от системы захвата экрана",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !capture.stopped else { return }
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    Log.capture.error("Длинный снимок: дисплей \(displayID) не найден в SCShareableContent")
                    capture.stop(reason: "displayNotFound")
                    Toast.show("Не удалось начать длинный снимок: экран не найден (монитор отключён?)",
                               symbol: "exclamationmark.triangle.fill", tint: .orange)
                    return
                }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let own = content.applications.filter { $0.processID == ownPID }
                capture.filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                capture.begin()
            } catch {
                Log.capture.error("Длинный снимок: SCShareableContent: \(error.localizedDescription, privacy: .public)")
                capture.stop(reason: "sckError \(ScrollCaptureLog.code(error))")
                Toast.show("Не удалось начать длинный снимок: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    // MARK: - Жизненный цикл

    private func begin() {
        showPanels()
        startKeyTap()
        startInputMonitors()
        log?.write("input wheel=\(inputMonitors.count > 0 ? 1 : 0) pointer=\(inputMonitors.count > 1 ? 1 : 0) "
                   + "keyTap=\(keyTap?.isRunning == true ? 1 : 0) accessibility=\(Permissions.accessibility ? 1 : 0) "
                   + "listenEvents=\(CGPreflightListenEventAccess() ? 1 : 0) "
                   + "smoothScroll=\(UserDefaults.standard.bool(forKey: Pref.smoothScroll) ? 1 : 0)/\(SmoothScroll.shared.isRunning ? 1 : 0)")
        log?.write(ScrollCaptureLog.frameColumns)
        // Первый кадр — не сразу: только что выведенное окно система может показать анимацией, а её кадры рисует не
        // наше приложение, и фильтр их не исключает (1.6.6: рамка в нижнем куске снимка, кадр 0 через 0,09 с).
        let timer = Timer(fireAt: Date(timeIntervalSinceNow: Self.firstFrameDelay), interval: 0.15, target: self,
                          selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func finish() {
        // Enter, «Готово» и предел высоты могут прийти почти одновременно: второй вызов отдал бы снимок дважды.
        guard !stopped else { return }
        // `current` обнуляется в stop(): пока склеивается и доставляется результат, занятость держит отдельная причина.
        BusyRegistry.shared.begin(.screenshotSaving)
        stop(reason: "done")
        Log.capture.notice("Длинный снимок: готово, \(self.capturedHeight) px, кадров \(self.frames)")
        let stitcher = self.stitcher
        // Склейка до 40 000 строк — на отдельной очереди, после кадров, которые ещё в работе.
        Task { @MainActor in
            defer { BusyRegistry.shared.end(.screenshotSaving) }
            guard let image = await stitcher.makeImage() else {
                Toast.show("Длинный снимок пуст: кадры не сняты", symbol: "exclamationmark.triangle.fill", tint: .orange)
                return
            }
            ScreenshotService.shared.deliverLongImage(image)
        }
    }

    func cancel() {
        guard !stopped else { return }
        stop(reason: "cancel")
        Toast.show("Длинный снимок отменён", symbol: "xmark.circle.fill", tint: .secondary)
    }

    private func stop(reason: String) {
        if !stopped {
            let time = ScrollCaptureLog.number(ProcessInfo.processInfo.systemUptime - started, digits: 3)
            let results = [Stitcher.Result.first, .appended, .unchanged, .lost].map { "\($0)=\(counts[$0, default: 0])" }
            log?.write("end \(reason) t=\(time) height=\(capturedHeight) frames=\(frames) skippedTicks=\(skippedTicks) "
                       + results.joined(separator: " "))
            log?.close()
        }
        stopped = true
        keyTap?.stop()
        keyTap = nil
        inputMonitors.forEach(NSEvent.removeMonitor)
        inputMonitors = []
        timer?.invalidate()
        timer = nil
        borderPanel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        borderPanel = nil
        hudPanel = nil
        if Self.current === self { Self.current = nil }
    }

    // MARK: - Кадры

    @objc private func tick() {
        guard !stopped, let filter, timer != nil || capturedHeight == 0 else { return }
        guard !busy else {
            skippedTicks += 1
            return
        }
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            let frame: CGImage
            let requested = ProcessInfo.processInfo.systemUptime
            do {
                frame = try await self.grab(filter)
            } catch {
                Log.capture.error("Длинный снимок: кадр не снят: \(error.localizedDescription, privacy: .public)")
                self.log?.write("grabError t=\(ScrollCaptureLog.number(requested - self.started, digits: 3)) \(ScrollCaptureLog.code(error))")
                return
            }
            guard !self.stopped else { return }
            let grabbed = ProcessInfo.processInfo.systemUptime
            // Кадр снят где-то между запросом и ответом; на экране — события, которые приложение успело отрисовать
            // (~кадр дисплея назад). Остальные события достанутся следующему кадру.
            let shown = (requested + grabbed) / 2 - 0.016
            let motion = self.takeMotion(upTo: shown)
            let before = self.capturedHeight
            let index = self.frames
            self.frames += 1
            if index == 0 { self.log?.write("frameSize \(frame.width)x\(frame.height) px bpp=\(frame.bitsPerPixel)") }
            self.log?.saveFrame(frame, index: index)
            // Подписи строк и поиск сдвига — на отдельной очереди: главный поток во время прокрутки свободен.
            let report = await self.stitcher.addReporting(frame, motion: motion)
            let result = report.result, height = report.height, isFull = report.isFull
            guard !self.stopped else { return }
            self.counts[result, default: 0] += 1
            // Откат склейки рваного кадра: высота до него — в строке кадра прирост считается от неё.
            if report.trace.undone { self.log?.write("undo height=\(before)") }
            self.log?.write(ScrollCaptureLog.frameLine(index: index, time: requested - self.started,
                                                       grabMs: (grabbed - requested) * 1000, addMs: report.milliseconds,
                                                       result: result, added: height - before, height: height,
                                                       trace: report.trace, motion: motion))
            switch result {
            case .appended, .first:
                self.lostTrack = false
            case .unchanged:
                break
            case .lost:
                self.lostTrack = true
                self.lostOnRepeats = report.lostOnRepeats
            }
            self.capturedHeight = height
            if isFull {
                Log.capture.notice("Длинный снимок: предел высоты, \(height) px")
                Toast.show("Достигнут предел длинного снимка: сохраняю снятое", symbol: "scroll.fill", tint: .orange)
                self.finish()
            }
        }
    }

    private func grab(_ filter: SCContentFilter) async throws -> CGImage {
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        // sourceRect — в точках дисплея, начало координат сверху слева.
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX,
                                   y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Ввод (подсказка склейке)

    /// Колесо и трекпад над областью съёмки: точные дельты (трекпад, плавная прокрутка) — в пикселях кадра,
    /// колесо без точных дельт — в строках. Перетаскивание и щелчки (ползунок, его дорожка, выделение) — прокрутка
    /// неизвестной величины. Глобальный монитор мыши разрешений не требует и видит то, что доставлено окнам, —
    /// уже после «Плавной прокрутки» Mac Utils, без двойного счёта.
    private func startInputMonitors() {
        if let wheel = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.noteScroll(event) }
        }) { inputMonitors.append(wheel) }
        if let pointer = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .otherMouseDragged, .leftMouseDown, .otherMouseDown],
                                                           handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .leftMouseDown || event.type == .otherMouseDown {
                    self.logEvent("mouseDown over=\(NSMouseInRect(NSEvent.mouseLocation, self.rect, false) ? 1 : 0)")
                }
                self.noteInput(Stitcher.Motion(unknown: 1), animated: true)
            }
        }) { inputMonitors.append(pointer) }
        if inputMonitors.isEmpty { Log.capture.error("Длинный снимок: нет монитора прокрутки, склейка только по изображению") }
    }

    private func noteScroll(_ event: NSEvent) {
        let overArea = NSMouseInRect(NSEvent.mouseLocation, rect, false)
        logEvent("wheel dy=\(ScrollCaptureLog.number(event.scrollingDeltaY, digits: 2)) precise=\(event.hasPreciseScrollingDeltas ? 1 : 0) "
                 + "phase=\(event.phase.rawValue)/\(event.momentumPhase.rawValue) over=\(overArea ? 1 : 0)")
        guard let wheel = ScrollInput.wheel(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                                            scale: screen.backingScaleFactor, overArea: overArea) else { return }
        noteInput(wheel.motion, anywhere: true, animated: wheel.animated)
    }

    private func logEvent(_ text: String) {
        guard !stopped else { return }
        log?.write("ev t=\(ScrollCaptureLog.number(ProcessInfo.processInfo.systemUptime - started, digits: 3)) \(text)")
    }

    /// `anywhere` — клавиши и колесо: у клавиш нет места, колесо мимо области учтено в `ScrollInput.wheel`.
    /// `animated` — после события приложение может ещё прокручивать само (см. `ScrollInput.animationTail`).
    private func noteInput(_ motion: Stitcher.Motion, anywhere: Bool = false, animated: Bool = false) {
        // Перетаскивание или щелчок над другим окном к области не относится.
        guard !stopped, anywhere || NSMouseInRect(NSEvent.mouseLocation, rect, false) else { return }
        input.note(motion, at: ProcessInfo.processInfo.systemUptime, animated: animated)
    }

    /// События до момента `time` — для очередного кадра; nil, пока событий не было (склейка только по изображению).
    private func takeMotion(upTo time: TimeInterval) -> Stitcher.Motion? {
        // Без перехвата клавиш (нет «Универсального доступа») нажатия видны только по времени последнего нажатия —
        // без кода клавиши. Любое нажатие — «могла быть прокрутка» (PageDown, пробел, стрелки): иначе после первого
        // события колеса прокрутка клавишами навсегда считалась бы «прокрутки нет».
        if keyTap?.isRunning != true {
            let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            let now = ProcessInfo.processInfo.systemUptime
            if !stopped, sinceKey < now - lastTaken {
                logEvent("keyPoll ago=\(ScrollCaptureLog.number(sinceKey, digits: 3))")
                input.note(Stitcher.Motion(unknown: 1), at: now - sinceKey, animated: true)
            }
            lastTaken = now
        }
        return input.take(upTo: time)
    }

    /// Стрелки, Home/End — прокрутка неизвестной величины; пробел и Page Up/Down — на страницу.
    private static let scrollKeys: Set<Int64> = [125, 126, 115, 119]

    /// PageDown и пробел — страница вниз, PageUp и Shift+пробел — вверх.
    private static func pages(_ code: Int64, _ flags: CGEventFlags) -> Double? {
        switch code {
        case 121: return 1
        case 116: return -1
        case 49: return flags.contains(.maskShift) ? -1 : 1
        default: return nil
        }
    }

    private func startKeyTap() {
        let tap = EventTap(types: [.keyDown]) { [weak self] _, event in
            guard let self else { return true }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            switch code {
            case 53: self.cancel()          // Esc
            case 36, 76: self.finish()      // Return / Enter
            default:
                if let pages = Self.pages(code, event.flags) {
                    self.logEvent("key pages=\(ScrollCaptureLog.number(pages, digits: 0))")
                    self.noteInput(Stitcher.Motion(pages: pages), anywhere: true, animated: true)
                } else if Self.scrollKeys.contains(code) {
                    self.logEvent("key code=\(code)")
                    self.noteInput(Stitcher.Motion(unknown: 1), anywhere: true, animated: true)
                }
                return true
            }
            return false
        }
        if !tap.start() { Log.capture.error("Длинный снимок: нет перехвата клавиш") }
        tap.onDisabled = { [weak self] in self?.logEvent("keyTapDisabled") }
        keyTap = tap
    }

    // MARK: - Журнал

    private func logHeader() {
        guard let log else { return }
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        log.write("mac-utils long screenshot log")
        log.write("app \(info?["CFBundleShortVersionString"] as? String ?? "-") (\(info?["CFBundleVersion"] as? String ?? "-")) "
                  + "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        log.write("area \(Int(rect.width))x\(Int(rect.height)) pt scale \(ScrollCaptureLog.number(screen.backingScaleFactor)) "
                  + "display \(Int(screen.frame.width))x\(Int(screen.frame.height)) pt screens \(NSScreen.screens.count) "
                  + "tick \(ScrollCaptureLog.number(0.15, digits: 2)) s framesSaved=\(log.framesDirectory == nil ? 0 : 1)")
    }

    // MARK: - Панели

    /// Через сколько секунд после показа панелей снимается первый кадр.
    static let firstFrameDelay: TimeInterval = 0.3
    /// Рамка лежит снаружи области съёмки: линия — в полях панели, внутри области — ни одной точки.
    static let borderMargin: CGFloat = 3

    /// Рамка вокруг области: без анимации появления — анимацию рисует система, а не наше приложение (её кадры фильтр
    /// захвата не исключает), и рамка в ней меньше настоящей, то есть внутри области.
    static func makeBorderPanel(around rect: NSRect) -> NSPanel {
        let border = NSPanel(contentRect: rect.insetBy(dx: -borderMargin, dy: -borderMargin),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.ignoresMouseEvents = true
        border.hasShadow = false
        border.animationBehavior = .none
        border.level = .statusBar
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: borderMargin)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(Color.red))
        return border
    }

    private func showPanels() {
        let border = Self.makeBorderPanel(around: rect)
        border.orderFrontRegardlessOnScreen()
        borderPanel = border

        let host = FirstMouseHostingView(rootView: ScrollCaptureHUD(capture: self))
        let size = host.fittingSize
        let hud = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.animationBehavior = .none
        hud.level = .statusBar
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = host
        let visible = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < visible.minY + 8 { origin.y = rect.maxY + 12 }
        if origin.y + size.height > visible.maxY { origin.y = rect.minY + 12 }
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        hud.setFrameOrigin(origin)
        hud.orderFrontRegardlessOnScreen()
        hudPanel = hud
    }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ScrollCaptureHUD: View {
    @ObservedObject var capture: ScrollCapture

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: capture.lostTrack ? "exclamationmark.triangle.fill" : "scroll")
                .foregroundStyle(capture.lostTrack ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                // Не только «быстро»: так же выглядят повторяющиеся строки, переход на другую страницу и рывок.
                Text(!capture.lostTrack ? "Медленно прокручивайте вниз"
                     : capture.lostOnRepeats ? "Одинаковые строки: прокрутите назад, к последнему отличающемуся месту"
                     : "Потерял место: прокрутите чуть назад и медленнее")
                    .font(.system(size: 12, weight: .semibold))
                Text("Снято: \(capture.capturedHeight) px")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Отмена") { capture.cancel() }
                .help("Esc")
            Button("Готово") { capture.finish() }
                .help("Enter")
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(4)
    }
}

// MARK: - Склейка

/// `Stitcher` на отдельной последовательной очереди: вызовы выстраиваются по порядку, главный поток не занят.
final class StitchWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macutils.stitch", qos: .userInitiated)
    private var stitcher = Stitcher()

    /// Итог кадра: результат, высота, предел достигнут, `.lost` ли из-за одинаковых строк, как решён кадр (для
    /// журнала) и сколько заняла склейка.
    struct Report {
        var result: Stitcher.Result
        var height: Int
        var isFull: Bool
        var lostOnRepeats: Bool
        var trace: Stitcher.Trace
        var milliseconds: Double
    }

    func add(_ frame: CGImage, motion: Stitcher.Motion? = nil) async -> (Stitcher.Result, Int, Bool) {
        let report = await addReporting(frame, motion: motion)
        return (report.result, report.height, report.isFull)
    }

    func addReporting(_ frame: CGImage, motion: Stitcher.Motion? = nil) async -> Report {
        let boxed = UncheckedSendable(frame)
        return await withCheckedContinuation { continuation in
            queue.async {
                let start = ProcessInfo.processInfo.systemUptime
                let result = self.stitcher.add(boxed.value, motion: motion)
                let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                continuation.resume(returning: Report(result: result, height: self.stitcher.height, isFull: self.stitcher.isFull,
                                                      lostOnRepeats: self.stitcher.lostOnRepeats, trace: self.stitcher.trace,
                                                      milliseconds: milliseconds))
            }
        }
    }

    func makeImage() async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.stitcher.makeImage().map(UncheckedSendable.init)) }
        }?.value
    }
}
