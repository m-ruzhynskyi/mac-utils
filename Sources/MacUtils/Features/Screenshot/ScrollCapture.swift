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
    private let filter: SCContentFilter
    private let stitcher = StitchWorker()
    private var timer: Timer?
    private var busy = false
    private var borderPanel: NSPanel?
    private var hudPanel: NSPanel?
    /// Esc — отмена, Enter — готово; работает без фокуса на панели.
    private var keyTap: EventTap?

    private init(rect: NSRect, screen: NSScreen, filter: SCContentFilter) {
        self.rect = rect
        self.screen = screen
        self.filter = filter
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
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    Log.capture.error("Длинный снимок: дисплей \(displayID) не найден в SCShareableContent")
                    return
                }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let own = content.applications.filter { $0.processID == ownPID }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let capture = ScrollCapture(rect: rect.intersection(screen.frame), screen: screen, filter: filter)
                current = capture
                capture.begin()
            } catch {
                Log.capture.error("Длинный снимок: SCShareableContent: \(error.localizedDescription, privacy: .public)")
                Toast.show("Не удалось начать длинный снимок: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    // MARK: - Жизненный цикл

    private func begin() {
        showPanels()
        startKeyTap()
        tick()
        let timer = Timer(timeInterval: 0.15, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func finish() {
        // Enter, «Готово» и предел высоты могут прийти почти одновременно: второй вызов отдал бы снимок дважды.
        guard Self.current === self else { return }
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
        guard Self.current === self else { return }
        stop()
        Toast.show("Длинный снимок отменён", symbol: "xmark.circle.fill", tint: .secondary)
    }

    private func stop() {
        keyTap?.stop()
        keyTap = nil
        timer?.invalidate()
        timer = nil
        borderPanel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        borderPanel = nil
        hudPanel = nil
        Self.current = nil
    }

    // MARK: - Кадры

    @objc private func tick() {
        guard !busy, timer != nil || capturedHeight == 0 else { return }
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            let frame: CGImage
            do {
                frame = try await self.grab()
            } catch {
                Log.capture.error("Длинный снимок: кадр не снят: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard Self.current === self else { return }
            let before = self.capturedHeight
            // Подписи строк и поиск сдвига — на отдельной очереди: главный поток во время прокрутки свободен.
            let (result, height, isFull) = await self.stitcher.add(frame)
            guard Self.current === self else { return }
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
            if isFull { self.finish() }
        }
    }

    private func grab() async throws -> CGImage {
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

    // MARK: - Клавиши

    private func startKeyTap() {
        let tap = EventTap(types: [.keyDown]) { [weak self] _, event in
            guard let self else { return true }
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 53: self.cancel()          // Esc
            case 36, 76: self.finish()      // Return / Enter
            default: return true
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
                Text(capture.lostTrack ? "Слишком быстро: прокрутите чуть назад" : "Медленно прокручивайте вниз")
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

    func add(_ frame: CGImage) async -> (Stitcher.Result, Int, Bool) {
        let boxed = UncheckedSendable(frame)
        return await withCheckedContinuation { continuation in
            queue.async {
                let result = self.stitcher.add(boxed.value)
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
