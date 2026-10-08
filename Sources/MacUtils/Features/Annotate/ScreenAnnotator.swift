import AppKit
import Carbon.HIToolbox
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

    private var canvasPanel: NSPanel?
    private var toolbarPanel: NSPanel?
    private weak var canvas: AnnotationCanvas?

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

    func start() {
        guard !isActive, let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        isActive = true
        let canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.annotator = self
        let panel = HUDPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.title = ScreenRecorder.recordedWindowTitle
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = canvas
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        canvasPanel = panel
        self.canvas = canvas

        let host = FirstMouseHostingView(rootView: AnnotationToolbar(annotator: self))
        let size = host.fittingSize
        let bar = HUDPanel(contentRect: NSRect(x: screen.frame.midX - size.width / 2,
                                               y: screen.visibleFrame.maxY - size.height - 12,
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
        ScreenRecorder.current?.refreshFilter()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        canvasPanel?.orderOut(nil)
        toolbarPanel?.orderOut(nil)
        canvasPanel = nil
        toolbarPanel = nil
        ScreenRecorder.current?.refreshFilter()
    }

    func undo() { canvas?.undo() }
    func clear() { canvas?.clear() }
}

// MARK: - Холст

final class AnnotationCanvas: NSView {
    struct Stroke {
        var tool: ScreenAnnotator.Tool
        var color: NSColor
        var points: [NSPoint]
        var born = Date()
    }

    weak var annotator: ScreenAnnotator?
    private var strokes: [Stroke] = []
    private var current: Stroke?
    private var fadeTimer: Timer?
    private static let fadeAfter: TimeInterval = 3

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let annotator else { return }
        let point = convert(event.locationInWindow, from: nil)
        current = Stroke(tool: annotator.tool, color: annotator.color, points: [point])
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
        strokes.append(stroke)
        needsDisplay = true
        scheduleFade()
    }

    override func keyDown(with event: NSEvent) {
        let annotator = self.annotator
        switch Int(event.keyCode) {
        case kVK_Escape: annotator?.stop()
        case kVK_Delete, kVK_ForwardDelete: clear()
        case kVK_ANSI_1: annotator?.tool = .pen
        case kVK_ANSI_2: annotator?.tool = .arrow
        case kVK_ANSI_3: annotator?.tool = .rectangle
        case kVK_ANSI_4: annotator?.tool = .highlighter
        case kVK_ANSI_Z where event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control): undo()
        default: super.keyDown(with: event)
        }
    }

    func undo() {
        _ = strokes.popLast()
        needsDisplay = true
    }

    func clear() {
        strokes.removeAll()
        needsDisplay = true
    }

    private func scheduleFade() {
        guard annotator?.fading == true, fadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let now = Date()
                self.strokes.removeAll { now.timeIntervalSince($0.born) > Self.fadeAfter + 0.6 }
                self.needsDisplay = true
                if self.strokes.isEmpty || self.annotator?.fading != true {
                    timer.invalidate()
                    self.fadeTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        let fading = annotator?.fading == true
        let now = Date()
        for stroke in strokes {
            var alpha: CGFloat = 1
            if fading {
                let age = now.timeIntervalSince(stroke.born)
                alpha = age < Self.fadeAfter ? 1 : max(0, 1 - CGFloat(age - Self.fadeAfter) / 0.6)
            }
            draw(stroke, alpha: alpha)
        }
        if let current { draw(current, alpha: 1) }
    }

    private func draw(_ stroke: Stroke, alpha: CGFloat) {
        guard let first = stroke.points.first, let last = stroke.points.last else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var color = stroke.color
        switch stroke.tool {
        case .pen, .highlighter:
            path.move(to: first)
            for point in stroke.points.dropFirst() { path.line(to: point) }
            path.lineWidth = stroke.tool == .pen ? 4 : 22
            if stroke.tool == .highlighter { color = color.withAlphaComponent(0.35) }
        case .rectangle:
            let rect = NSRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(last.x - first.x), height: abs(last.y - first.y))
            path.appendRoundedRect(rect, xRadius: 6, yRadius: 6)
            path.lineWidth = 4
        case .arrow:
            path.move(to: first)
            path.line(to: last)
            path.lineWidth = 5
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head: CGFloat = 22
            for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                path.move(to: last)
                path.line(to: NSPoint(x: last.x + head * cos(angle + side), y: last.y + head * sin(angle + side)))
            }
        }
        // Тёмная подложка — видно и на светлом, и на тёмном фоне.
        if stroke.tool != .highlighter {
            NSColor.black.withAlphaComponent(0.35 * alpha).setStroke()
            let shadow = path.copy() as! NSBezierPath
            shadow.lineWidth = path.lineWidth + 2
            shadow.stroke()
        }
        color.withAlphaComponent(color.alphaComponent * alpha).setStroke()
        path.stroke()
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
