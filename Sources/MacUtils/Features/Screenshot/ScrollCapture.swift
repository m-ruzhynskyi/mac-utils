import AppKit
import ScreenCaptureKit
import SwiftUI

/// Длинный снимок с прокруткой: выделенная область снимается несколько раз
/// в секунду, пока пользователь прокручивает содержимое вниз, а новые строки
/// приклеиваются снизу.
@MainActor
final class ScrollCapture: NSObject, ObservableObject {
    private(set) static var current: ScrollCapture?

    @Published private(set) var capturedHeight = 0
    @Published private(set) var lostTrack = false

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

    private init(rect: NSRect, screen: NSScreen) {
        self.rect = rect
        self.screen = screen
        super.init()
    }

    static func start(rect: NSRect) {
        Log.capture.info("Длинный снимок: старт, область \(NSStringFromRect(rect), privacy: .public)")
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
        // SCShareableContent может не ответить (завис replayd, открыт системный запрос): тогда съёмка без панелей
        // висела бы в `current`, а новые снимки молча не запускались.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard capture.filter == nil, !capture.stopped else { return }
            Log.capture.error("Длинный снимок: SCShareableContent не ответил")
            capture.stop()
            Toast.show("Не удалось начать длинный снимок: нет ответа от системы захвата экрана",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !capture.stopped else { return }
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    Log.capture.error("Длинный снимок: дисплей \(displayID) не найден в SCShareableContent")
                    capture.stop()
                    return
                }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let own = content.applications.filter { $0.processID == ownPID }
                capture.filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                capture.begin()
            } catch {
                Log.capture.error("Длинный снимок: SCShareableContent: \(error.localizedDescription, privacy: .public)")
                capture.stop()
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
        tick()
        let timer = Timer(timeInterval: 0.15, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func finish() {
        // Enter, «Готово» и предел высоты могут прийти почти одновременно: второй вызов отдал бы снимок дважды.
        guard !stopped else { return }
        // `current` обнуляется в stop(): пока склеивается и доставляется результат, занятость держит отдельная причина.
        BusyRegistry.shared.begin(.screenshotSaving)
        stop()
        Log.capture.info("Длинный снимок: готово, \(self.capturedHeight) px")
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
        stop()
        Toast.show("Длинный снимок отменён", symbol: "xmark.circle.fill", tint: .secondary)
    }

    private func stop() {
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
        guard !busy, !stopped, let filter, timer != nil || capturedHeight == 0 else { return }
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            let frame: CGImage
            let requested = ProcessInfo.processInfo.systemUptime
            do {
                frame = try await self.grab(filter)
            } catch {
                Log.capture.error("Длинный снимок: кадр не снят: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard !self.stopped else { return }
            // Кадр снят где-то между запросом и ответом; на экране — события, которые приложение успело отрисовать
            // (~кадр дисплея назад). Остальные события достанутся следующему кадру.
            let shown = (requested + ProcessInfo.processInfo.systemUptime) / 2 - 0.016
            let motion = self.takeMotion(upTo: shown)
            let before = self.capturedHeight
            // Подписи строк и поиск сдвига — на отдельной очереди: главный поток во время прокрутки свободен.
            let (result, height, isFull) = await self.stitcher.add(frame, motion: motion)
            guard !self.stopped else { return }
            Log.capture.debug("Кадр \(frame.width)×\(frame.height): \(String(describing: result), privacy: .public), +\(height - before) px")
            switch result {
            case .appended, .first:
                self.lostTrack = false
            case .unchanged:
                break
            case .lost:
                self.lostTrack = true
            }
            self.capturedHeight = height
            if isFull {
                Log.capture.info("Длинный снимок: предел высоты, \(height) px")
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
                                                           handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.noteInput(Stitcher.Motion(unknown: 1), animated: true) }
        }) { inputMonitors.append(pointer) }
        if inputMonitors.isEmpty { Log.capture.error("Длинный снимок: нет монитора прокрутки, склейка только по изображению") }
    }

    private func noteScroll(_ event: NSEvent) {
        let overArea = NSMouseInRect(NSEvent.mouseLocation, rect, false)
        guard let wheel = ScrollInput.wheel(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                                            scale: screen.backingScaleFactor, overArea: overArea) else { return }
        noteInput(wheel.motion, anywhere: true, animated: wheel.animated)
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
            if !stopped, sinceKey < now - lastTaken { input.note(Stitcher.Motion(unknown: 1), at: now - sinceKey, animated: true) }
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
                    self.noteInput(Stitcher.Motion(pages: pages), anywhere: true, animated: true)
                } else if Self.scrollKeys.contains(code) {
                    self.noteInput(Stitcher.Motion(unknown: 1), anywhere: true, animated: true)
                }
                return true
            }
            return false
        }
        if !tap.start() { Log.capture.error("Длинный снимок: нет перехвата клавиш") }
        keyTap = tap
    }

    // MARK: - Панели

    private func showPanels() {
        let border = NSPanel(contentRect: rect.insetBy(dx: -3, dy: -3),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.ignoresMouseEvents = true
        border.hasShadow = false
        border.level = .statusBar
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(Color.red))
        border.orderFrontRegardless()
        borderPanel = border

        let host = FirstMouseHostingView(rootView: ScrollCaptureHUD(capture: self))
        let size = host.fittingSize
        let hud = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.level = .statusBar
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = host
        let visible = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < visible.minY + 8 { origin.y = rect.maxY + 12 }
        if origin.y + size.height > visible.maxY { origin.y = rect.minY + 12 }
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        hud.setFrameOrigin(origin)
        hud.orderFrontRegardless()
        hudPanel = hud
    }
}

/// Кнопки HUD должны нажиматься с первого клика: панель не активирует приложение.
/// Курсор над HUD — обычная стрелка, даже когда приложение неактивно.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["cursor"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["cursor": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        NSCursor.arrow.set()
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
                Text(capture.lostTrack ? "Потерял место: прокрутите чуть назад и медленнее" : "Медленно прокручивайте вниз")
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

    func add(_ frame: CGImage, motion: Stitcher.Motion? = nil) async -> (Stitcher.Result, Int, Bool) {
        let boxed = UncheckedSendable(frame)
        return await withCheckedContinuation { continuation in
            queue.async {
                let result = self.stitcher.add(boxed.value, motion: motion)
                continuation.resume(returning: (result, self.stitcher.height, self.stitcher.isFull))
            }
        }
    }

    func makeImage() async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.stitcher.makeImage().map(UncheckedSendable.init)) }
        }?.value
    }
}
