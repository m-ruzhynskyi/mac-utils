import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

/// Рисование поверх экрана (⌃⌥A): стрелки, рамки, маркер и перо — во время созвона или записи.
@MainActor
final class ScreenAnnotator: ObservableObject {
    static let shared = ScreenAnnotator()

    enum Tool: String, CaseIterable, Identifiable {
        case pen, arrow, rectangle, highlighter
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .pen: return "pencil.tip"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .highlighter: return "highlighter"
            }
        }
        var title: String {
            switch self {
            case .pen: return "Перо (1)"
            case .arrow: return "Стрелка (2)"
            case .rectangle: return "Рамка (3)"
            case .highlighter: return "Маркер (4)"
            }
        }
    }

    static let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]

    @Published var tool: Tool = .arrow
    @Published var color: NSColor = .systemRed
    /// Штрихи сами исчезают через несколько секунд — удобно на демонстрации.
    @Published var fading = false
    @Published private(set) var isActive = false

    /// Рисовать «сквозь клики»: рисунок остаётся, мышь работает с программами. Удержание ⌥ на время переворачивает режим.
    @Published var clickThrough = false {
        didSet { applyMouseMode() }
    }
    @Published private(set) var snapshotBusy = false

    private(set) var store = AnnotationStore()
    private struct Overlay {
        let panel: NSPanel
        let canvas: AnnotationCanvas
    }
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var toolbarPanel: NSPanel?
    private var optionHeld = false
    private var flagMonitors: [Any] = []
    private var screenObserver: Any?
    private var fadeTimer: Timer?

    func sync() {
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.annotate)
        guard UserDefaults.standard.bool(forKey: Pref.annotate) else {
            stop()
            return
        }
        center.register(id: HotKeyID.annotate, keyCode: kVK_ANSI_A, modifiers: controlKey | optionKey) {
            ScreenAnnotator.shared.toggle()
        }
    }

    func toggle() {
        isActive ? stop() : start()
    }

    private static func frames() -> [CGDirectDisplayID: CGRect] {
        Dictionary(NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen.frame) } },
                   uniquingKeysWith: { first, _ in first })
    }

    func start() {
        guard !isActive, let mouseScreen = NSScreen.withMouse ?? NSScreen.main else { return }
        isActive = true
        optionHeld = false
        // Холст на каждом экране: рисовать можно на любом мониторе без перезапуска.
        rebuildOverlays(preferred: mouseScreen.displayID)

        let host = FirstMouseHostingView(rootView: AnnotationToolbar(annotator: self))
        let size = host.fittingSize
        let bar = HUDPanel(contentRect: NSRect(x: mouseScreen.frame.midX - size.width / 2,
                                               y: mouseScreen.visibleFrame.maxY - size.height - 12,
                                               width: size.width, height: size.height),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bar.isOpaque = false
        bar.backgroundColor = .clear
        bar.hasShadow = true
        bar.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        bar.isMovableByWindowBackground = true
        bar.contentView = host
        bar.orderFrontRegardless()
        toolbarPanel = bar

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenAnnotator.shared.screensChanged() }
        }
        installOptionMonitors()
        ScreenRecorder.current?.refreshFilter()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        for overlay in overlays.values { overlay.panel.orderOut(nil) }
        overlays = [:]
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        store.clear()
        fadeTimer?.invalidate()
        fadeTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for monitor in flagMonitors { NSEvent.removeMonitor(monitor) }
        flagMonitors = []
        ScreenRecorder.current?.refreshFilter()
    }

    // MARK: Экраны

    /// Подключили или отключили монитор, сменили разрешение: оверлеи пересобираются, штрихи остальных экранов сохраняются.
    private func screensChanged() {
        guard isActive else { return }
        rebuildOverlays(preferred: nil)
        // Панель инструментов должна остаться на существующем экране.
        if let bar = toolbarPanel, !NSScreen.screens.contains(where: { $0.frame.intersects(bar.frame) }),
           let screen = NSScreen.main {
            bar.setFrameOrigin(NSPoint(x: screen.frame.midX - bar.frame.width / 2, y: screen.visibleFrame.maxY - bar.frame.height - 12))
        }
        if overlays.isEmpty { stop() }
    }

    private func rebuildOverlays(preferred: CGDirectDisplayID?) {
        let current = Self.frames()
        let plan = AnnotationScreens.plan(existing: overlays.mapValues { $0.panel.frame }, current: current)
        for id in plan.remove {
            overlays[id]?.panel.orderOut(nil)
            overlays[id] = nil
        }
        store.drop(displays: Set(plan.remove + plan.resize))
        for id in plan.resize {
            guard let frame = current[id], let overlay = overlays[id] else { continue }
            overlay.panel.setFrame(frame, display: true)
            overlay.canvas.frame = NSRect(origin: .zero, size: frame.size)
        }
        for id in plan.add {
            guard let frame = current[id] else { continue }
            overlays[id] = makeOverlay(display: id, frame: frame)
        }
        applyMouseMode()
        let key = preferred.flatMap { overlays[$0] } ?? overlays.values.first
        for overlay in overlays.values {
            if overlay.panel === key?.panel, !isClickThroughNow {
                overlay.panel.makeKeyAndOrderFront(nil)
                overlay.panel.makeFirstResponder(overlay.canvas)
            } else {
                overlay.panel.orderFrontRegardless()
            }
        }
        redrawAll()
        ScreenRecorder.current?.refreshFilter()
    }

    private func makeOverlay(display: CGDirectDisplayID, frame: CGRect) -> Overlay {
        let canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: frame.size))
        canvas.annotator = self
        canvas.display = display
        let panel = HUDPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.title = ScreenRecorder.recordedWindowTitle
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = canvas
        panel.setFrame(frame, display: true)
        return Overlay(panel: panel, canvas: canvas)
    }

    // MARK: Режим «сквозь клики»

    private var isClickThroughNow: Bool { AnnotationMode.ignoresMouse(clickThrough: clickThrough, optionHeld: optionHeld) }

    private func applyMouseMode() {
        let ignore = isClickThroughNow
        for overlay in overlays.values {
            overlay.panel.ignoresMouseEvents = ignore
            overlay.panel.invalidateCursorRects(for: overlay.canvas)
        }
        // Вернулись к рисованию — клавиши (Esc, 1–4) снова должны попадать на холст.
        if !ignore, let overlay = overlays.values.first(where: { $0.panel.isKeyWindow }) ?? overlays.values.first {
            overlay.panel.makeKeyAndOrderFront(nil)
            overlay.panel.makeFirstResponder(overlay.canvas)
        }
    }

    private func installOptionMonitors() {
        let handler: (NSEvent) -> Void = { event in
            let held = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated {
                let annotator = ScreenAnnotator.shared
                guard annotator.isActive, annotator.optionHeld != held else { return }
                annotator.optionHeld = held
                annotator.applyMouseMode()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { flagMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in handler(event); return event }) {
            flagMonitors.append(local)
        }
    }

    // MARK: Штрихи

    func commit(_ stroke: AnnotationStroke) {
        store.add(stroke)
        redrawAll()
        scheduleFade()
    }

    func redrawAll() {
        for overlay in overlays.values { overlay.canvas.needsDisplay = true }
    }

    func undo() {
        store.undo()
        redrawAll()
    }

    func clear() {
        store.clear()
        redrawAll()
    }

    private func scheduleFade() {
        guard fading, fadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { timer in
            MainActor.assumeIsolated {
                let annotator = ScreenAnnotator.shared
                annotator.store.removeExpired(now: Date())
                annotator.redrawAll()
                if annotator.store.isEmpty || !annotator.fading || !annotator.isActive {
                    timer.invalidate()
                    annotator.fadeTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    // MARK: Снимок экрана с рисунком

    /// Снимает экран, на котором панель инструментов (без окон Mac Utils), накладывает штрихи этого экрана и отдаёт по
    /// настройке «Куда сохранять»: в буфер, в папку или туда и туда.
    func snapshot() {
        guard !snapshotBusy, isActive else { return }
        guard Permissions.screenRecording else {
            Permissions.requestScreenRecording()
            Toast.show("Чтобы снять экран с рисунком, разрешите «Запись экрана»", symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        let screen = toolbarPanel?.screen ?? NSScreen.withMouse ?? NSScreen.main
        guard let screen, let display = screen.displayID else { return }
        snapshotBusy = true
        let items = store.strokes(on: display).map { ($0, AnnotationStore.alpha(age: Date().timeIntervalSince($0.born), fading: fading)) }
        Task { @MainActor in
            defer { snapshotBusy = false }
            do {
                let base = try await Self.captureClean(screen: screen, display: display)
                guard let image = AnnotationRenderer.compose(base: base, strokes: items, pointSize: screen.frame.size),
                      let png = AnnotationRenderer.png(image) else {
                    Toast.show("Не удалось собрать снимок с рисунком", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    return
                }
                deliver(png: png)
            } catch {
                Toast.show("Не удалось снять экран: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    private func deliver(png: Data) {
        let destination = Pref.screenshotDestinationValue
        if destination != .folder {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        }
        if destination != .clipboard {
            do {
                let folder = Pref.screenshotDirectory
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = try AnnotationRenderer.writeUnique(png, to: folder.appendingPathComponent(AnnotationRenderer.snapshotName()))
                Toast.show(destination == .both ? "Снимок с рисунком скопирован и сохранён" : "Сохранено: \(url.lastPathComponent)",
                           symbol: "camera.fill", tint: .green)
                return
            } catch {
                Toast.show("Не удалось сохранить: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", tint: .orange)
                return
            }
        }
        Toast.show("Снимок с рисунком скопирован", symbol: "camera.fill", tint: .green)
    }

    /// Экран без окон Mac Utils (холст и панель инструментов): рисунок накладывается отдельно, из хранилища штрихов.
    private static func captureClean(screen: NSScreen, display: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.displays.first(where: { $0.displayID == display }) else {
            throw NSError(domain: "MacUtils.Annotate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Экран не найден"])
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: target, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

// MARK: - Холст

final class AnnotationCanvas: NSView {
    weak var annotator: ScreenAnnotator?
    var display: CGDirectDisplayID = 0
    private var current: AnnotationStroke?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let annotator else { return }
        let point = convert(event.locationInWindow, from: nil)
        current = AnnotationStroke(display: display, tool: annotator.tool, color: annotator.color, points: [point])
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard var stroke = current else { return }
        if stroke.tool == .pen || stroke.tool == .highlighter {
            stroke.points.append(point)
        } else {
            stroke.points = [stroke.points[0], point]
        }
        current = stroke
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var stroke = current else { return }
        current = nil
        if stroke.points.count == 1 { stroke.points.append(stroke.points[0]) }
        stroke.born = Date()
        annotator?.commit(stroke)
    }

    override func keyDown(with event: NSEvent) {
        let annotator = self.annotator
        switch Int(event.keyCode) {
        case kVK_Escape: annotator?.stop()
        case kVK_Delete, kVK_ForwardDelete: annotator?.clear()
        case kVK_ANSI_1: annotator?.tool = .pen
        case kVK_ANSI_2: annotator?.tool = .arrow
        case kVK_ANSI_3: annotator?.tool = .rectangle
        case kVK_ANSI_4: annotator?.tool = .highlighter
        case kVK_ANSI_Z where event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control): annotator?.undo()
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let annotator else { return }
        let fading = annotator.fading
        let now = Date()
        for stroke in annotator.store.strokes(on: display) {
            AnnotationRenderer.draw(stroke, alpha: AnnotationStore.alpha(age: now.timeIntervalSince(stroke.born), fading: fading))
        }
        if let current { AnnotationRenderer.draw(current, alpha: 1) }
    }
}

// MARK: - Панель инструментов

private struct AnnotationToolbar: View {
    @ObservedObject var annotator: ScreenAnnotator

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ScreenAnnotator.Tool.allCases) { tool in
                Button { annotator.tool = tool } label: {
                    Image(systemName: tool.symbol).frame(width: 26, height: 24)
                        .background(annotator.tool == tool ? Color.accentColor.opacity(0.35) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .help(tool.title)
            }
            Divider().frame(height: 20)
            ForEach(ScreenAnnotator.colors, id: \.self) { color in
                Button { annotator.color = color } label: {
                    Circle().fill(Color(nsColor: color)).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white, lineWidth: annotator.color == color ? 2 : 0))
                }
            }
            Divider().frame(height: 20)
            Button { annotator.fading.toggle() } label: {
                Image(systemName: annotator.fading ? "timer" : "infinity").frame(width: 24, height: 24)
            }
            .help(annotator.fading ? "Штрихи исчезают через 3 секунды" : "Штрихи остаются")
            Button { annotator.clickThrough.toggle() } label: {
                Image(systemName: annotator.clickThrough ? "cursorarrow.click.2" : "pencil.line")
                    .frame(width: 24, height: 24)
                    .background(annotator.clickThrough ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .help(annotator.clickThrough ? "Сквозь клики: мышь работает с программами (⌥ — порисовать)" : "Рисование: клики идут на холст (⌥ — пропустить клик)")
            Button { annotator.snapshot() } label: {
                Image(systemName: annotator.snapshotBusy ? "hourglass" : "camera").frame(width: 24, height: 24)
            }
            .disabled(annotator.snapshotBusy)
            .help("Снимок экрана вместе с рисунком")
            Button { annotator.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 24) }
                .help("Отменить (⌘Z)")
            Button { annotator.clear() } label: { Image(systemName: "trash").frame(width: 24, height: 24) }
                .help("Стереть всё (⌫)")
            Button { annotator.stop() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .help("Закончить (Esc или ⌃⌥A)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(2)
    }
}
