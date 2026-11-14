import AppKit
import CoreVideo
import MUCore
import MUDesign
import SwiftUI

/// Отладка «Взгляда в камеру» для проверки на своей камере: «до | после» рядом, ползунки, к/с и задержка,
/// запись 10 с «до | после» в ~/Movies/Mac Utils. Открывается только ключом запуска `--gaze-debug`.
/// Окно включает функцию (это и есть ручное включение) и выключает её при закрытии — камера гаснет.
@MainActor
package final class GazeDebugWindowController: NSObject, NSWindowDelegate {
    package static let shared = GazeDebugWindowController()
    package static let launchArgument = "--gaze-debug"

    private var window: NSWindow?
    private let before = SurfaceView(), after = SurfaceView()
    private let overlay = CATextLayer()
    private let frames = LatestFrames()
    private var timer: Timer?

    package func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let service = GazeService.shared
        service.debugFrames = { [frames] b, a in frames.set(b, a) }
        service.setOn(true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Взгляд в камеру — отладка"
        w.delegate = self
        w.isReleasedWhenClosed = false
        let pair = NSStackView(views: [labeled(before, "до (камера)"), labeled(after, "после (то, что получает OBS)")])
        // Индикатор прямо на кадре «после»: сколько пикселей сдвинуто, итоговая сила и почему ослаблено.
        overlay.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        overlay.fontSize = 13
        overlay.foregroundColor = NSColor.white.cgColor
        overlay.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        overlay.cornerRadius = 6
        overlay.isWrapped = true
        overlay.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        overlay.frame = CGRect(x: 8, y: 8, width: 600, height: 44)
        after.layer?.addSublayer(overlay)
        pair.distribution = .fillEqually
        pair.spacing = 8
        let controls = NSHostingView(rootView: GazeDebugControls(service: .shared))
        let root = NSStackView(views: [pair, controls])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.setHuggingPriority(.defaultLow, for: .vertical)
        controls.setContentHuggingPriority(.required, for: .vertical)
        w.contentView = root
        w.center()
        window = w
    }

    private func labeled(_ view: NSView, _ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let stack = NSStackView(views: [label, view])
        stack.orientation = .vertical
        stack.alignment = .leading
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: view.heightAnchor, multiplier: 16.0 / 9.0).isActive = true
        return stack
    }

    private func tick() {
        guard let (b, a) = frames.take() else { return }
        before.show(b); after.show(a)
        let service = GazeService.shared
        let text = service.bypass ? " поправка выключена (сравнение)" : Self.overlayText(service.liveStats ?? GazeStats())
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay.string = text
        overlay.frame.origin.y = max(after.bounds.height - overlay.frame.height - 8, 8)
        CATransaction.commit()
    }

    /// «поправка: 9 px вверх / 1 px вбок, сила 0.92» и вторая строка — почему ослаблена.
    nonisolated static func overlayText(_ s: GazeStats) -> String {
        let a = s.applied
        let up = a.pixels.y, side = a.pixels.x
        var line = String(format: " поправка: %.0f px %@ / %.0f px вбок, сила %.2f", abs(up), up >= 0 ? "вверх" : "вниз", abs(side), a.strength)
        var why: [String] = []
        if !s.faceFound { why.append("нет лица") }
        if s.state.contains(.headTurned) { why.append("голова повёрнута") }
        if s.state.contains(.blink) { why.append("моргание") }
        if s.state.contains(.irisLost) { why.append("радужка не найдена") }
        if s.state.contains(.lookingFarAway) { why.append("смотрит далеко") }
        if s.state.contains(.narrowEyes) { why.append(String(format: "узкие глаза ×%.2f", a.openFactor)) }
        if s.state.contains(.sideGaze) { why.append(String(format: "взгляд в сторону ×%.2f (радужка %.2f)", a.sideFactor, a.irisSide)) }
        line += "\n " + (why.isEmpty ? "не ослаблена" : "ослаблена: " + why.joined(separator: ", "))
        return line
    }

    package func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        GazeService.shared.debugFrames = nil
        GazeService.shared.debugOverrides = nil
        GazeService.shared.bypass = false
        GazeService.shared.setOn(false)
    }
}

/// Последняя пара кадров с очереди конвейера (под замком).
private final class LatestFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var pair: (CVPixelBuffer, CVPixelBuffer)?
    func set(_ b: CVPixelBuffer, _ a: CVPixelBuffer) { lock.withLock { pair = (b, a) } }
    func take() -> (CVPixelBuffer, CVPixelBuffer)? { lock.withLock { defer { pair = nil }; return pair } }
}

/// Кадр как содержимое слоя (IOSurface), без копий.
private final class SurfaceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ buffer: CVPixelBuffer) {
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() { layer?.contents = surface }
    }
}

/// Панель под кадрами: цифры, ползунки, запись.
private struct GazeDebugControls: View {
    @ObservedObject var service: GazeService
    @State private var correction = true
    @State private var lift = GazeCalibration.defaultScreenLift
    @AppStorage(Pref.gazeStrength) private var strength = 1.0
    @State private var lidFollow = 0.8
    @State private var freedom: GazeFreedom = .normal
    @State private var precise = true
    @State private var faceMeshLids = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(statusLine).font(.system(.body, design: .monospaced))
            HStack(spacing: 18) {
                Toggle("Поправка", isOn: $correction).onChange(of: correction) { _, v in service.bypass = !v }
                Picker("Свобода", selection: $freedom) {
                    Text("Мало").tag(GazeFreedom.low); Text("Обычно").tag(GazeFreedom.normal); Text("Много").tag(GazeFreedom.high)
                }
                .pickerStyle(.segmented).frame(width: 260).onChange(of: freedom) { _, _ in push() }
                Toggle("Точные веки (MediaPipe)", isOn: $precise).onChange(of: precise) { _, _ in push() }
                    .help("Выключить — отрисовка по контуру Vision, как A v2 (для сравнения)")
                Toggle("Веки: Face Landmarker", isOn: $faceMeshLids).onChange(of: faceMeshLids) { _, _ in push() }
                    .help("Выключить — веки от модели Iris, как в GAZE-33 (для сравнения)")
            }
            HStack(spacing: 18) {
                slider("Экран ниже камеры", $lift, 0...0.3) { String(format: "%.2f (≈%.0f°)", $0, asin(min($0 / GazeCalibration.eyeballGain, 1)) * 180 / .pi) }
                slider("Веко за радужкой", $lidFollow, 0...1) { String(format: "%.2f", $0) }
                slider("Сила", $strength, GazeSettings.strengthRange) { String(format: "%.0f %%", $0 * 100) }
            }
            HStack(spacing: 10) {
                Button(service.recording ? "Идёт запись…" : "Записать 10 с «до | после»") { service.recordDebugClip() }
                    .disabled(service.recording || service.status != .running)
                if let url = service.lastRecording {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Text(url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Откалибровать") { service.startCalibration() }.disabled(service.status != .running)
                Text(calibrationText).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .onAppear { lift = GazeService.settingsFromPrefs().calibration.screenLift; push() }
        .onChange(of: lift) { _, _ in push() }
        .onChange(of: lidFollow) { _, _ in push() }
    }

    private func push() {
        let (lift, lidFollow, freedom, precise, faceMeshLids) = (lift, lidFollow, freedom, precise, faceMeshLids)
        service.debugOverrides = { s in
            s.calibration.screenLift = lift
            s.calibration.lidFollow = lidFollow
            s.freedom = freedom
            s.useEyeShape = precise
            s.useFaceMesh = faceMeshLids
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Slider(value: value, in: range).frame(width: 220)
            Text(format(value.wrappedValue)).font(.system(.body, design: .monospaced)).frame(width: 110, alignment: .leading)
        }
    }

    private var statusLine: String {
        let s = service.stats
        var parts = [String(format: "%2.0f к/с", s.fps), String(format: "обработка %.1f мс", s.processingMs),
                     String(format: "камера→кадр %.0f мс", s.latencyMs), "лицо: \(s.faceFound ? "да" : "нет")",
                     String(format: "сила %.2f", s.weight)]
        if !s.state.isEmpty { parts.append("ослаблена: " + Self.describe(s.state)) }
        parts.append(service.obsFPS > 0 ? String(format: "OBS: %.0f к/с", service.obsFPS) : "OBS: не подключён")
        if !service.preciseEyes { parts.append("модель Iris не загрузилась") }
        if !service.preciseLids { parts.append("Face Landmarker не загрузился") }
        if let name = service.cameraName { parts.append("камера: \(name)") }
        switch service.status {
        case .running: break
        case .starting: parts.insert("запуск…", at: 0)
        case .off: parts.insert("выключено", at: 0)
        case .cameraDenied: parts.insert("нет доступа к камере", at: 0)
        case .noCamera: parts.insert("камера не найдена", at: 0)
        case let .failed(m): parts.insert(m, at: 0)
        }
        return parts.joined(separator: " · ")
    }

    private var calibrationText: String {
        switch service.calibration {
        case .idle: return ""
        case let .collecting(step, p): return "\(step == .camera ? "Смотрите в камеру" : "Смотрите в середину экрана") \(Int(p * 100))%"
        case let .done(r): return String(format: "Готово: экран ниже камеры на %.0f°", r.screenAngleDegrees())
        case let .failed(m): return m
        }
    }

    static func describe(_ s: GazeState) -> String {
        var out: [String] = []
        if s.contains(.noFace) { out.append("нет лица") }
        if s.contains(.headTurned) { out.append("голова повёрнута") }
        if s.contains(.blink) { out.append("моргание") }
        if s.contains(.irisLost) { out.append("радужка не найдена") }
        if s.contains(.lookingFarAway) { out.append("смотрит далеко в сторону") }
        if s.contains(.narrowEyes) { out.append("узкие глаза") }
        if s.contains(.sideGaze) { out.append("взгляд в сторону") }
        return out.joined(separator: ", ")
    }
}
