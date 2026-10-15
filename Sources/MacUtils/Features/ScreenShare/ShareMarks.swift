import AppKit
import ScreenCaptureKit
import SwiftUI

/// Метки и рисунки зрителей поверх трансляции (как пинг в League of Legends).
/// Координаты — доли кадра (0…1, от левого верхнего угла), так они одинаковы у всех.
struct ShareMark: Identifiable {
    enum Kind { case ping, stroke }

    let id = UUID()
    let kind: Kind
    let points: [CGPoint]
    let color: Color
    let born = Date()

    /// Пинг живёт 1.6 с, рисунок — 5 с (последняя секунда — плавное исчезновение).
    var lifetime: TimeInterval { kind == .ping ? 1.6 : 5 }

    static let palette: [(name: String, color: Color)] = [
        ("red", .red), ("yellow", .yellow), ("green", .green), ("blue", .blue), ("white", .white),
    ]

    static func color(named name: String?) -> Color {
        palette.first { $0.name == name }?.color ?? .red
    }

    /// Сообщение зрителя: {"type":"ping","x":0.5,"y":0.3,"color":"red"} или
    /// {"type":"stroke","points":[[x,y],…],"color":"blue"}.
    static func parse(_ text: String) -> ShareMark? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        let color = color(named: json["color"] as? String)
        func clamp(_ value: Double) -> CGFloat { CGFloat(min(max(value, 0), 1)) }
        switch type {
        case "ping":
            guard let x = json["x"] as? Double, let y = json["y"] as? Double else { return nil }
            return ShareMark(kind: .ping, points: [CGPoint(x: clamp(x), y: clamp(y))], color: color)
        case "stroke":
            guard let raw = json["points"] as? [[Double]] else { return nil }
            let points = raw.prefix(2000).compactMap { $0.count == 2 ? CGPoint(x: clamp($0[0]), y: clamp($0[1])) : nil }
            return points.count >= 2 ? ShareMark(kind: .stroke, points: points, color: color) : nil
        default:
            return nil
        }
    }

    static func message(ping point: CGPoint, color: String) -> String {
        String(format: #"{"type":"ping","x":%.4f,"y":%.4f,"color":"%@"}"#, point.x, point.y, color)
    }

    static func message(stroke points: [CGPoint], color: String) -> String {
        let list = points.map { String(format: "[%.4f,%.4f]", $0.x, $0.y) }.joined(separator: ",")
        return #"{"type":"stroke","points":["# + list + #"],"color":""# + color + #""}"#
    }
}

/// Хранилище меток с автоочисткой.
@MainActor
final class ShareMarkStore: ObservableObject {
    @Published private(set) var marks: [ShareMark] = []
    private var timer: Timer?

    func add(_ mark: ShareMark) {
        marks.append(mark)
        if marks.count > 200 { marks.removeFirst(marks.count - 200) }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func clear() {
        marks.removeAll()
    }

    private func prune() {
        let now = Date()
        marks.removeAll { now.timeIntervalSince($0.born) > $0.lifetime }
        if marks.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}

/// Рисует метки в прямоугольнике кадра (rect — где кадр внутри вида).
struct ShareMarksLayer: View {
    @ObservedObject var store: ShareMarkStore
    var rect: CGRect

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: store.marks.isEmpty)) { context in
            Canvas { canvas, _ in
                for mark in store.marks {
                    let age = context.date.timeIntervalSince(mark.born)
                    let point = { (p: CGPoint) in CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height) }
                    switch mark.kind {
                    case .ping:
                        let center = point(mark.points[0])
                        // Три расходящихся кольца и точка — как пинг в играх.
                        for wave in 0..<3 {
                            let t = (age - Double(wave) * 0.25) / 1.0
                            guard t > 0, t < 1 else { continue }
                            let radius = 10 + 46 * t
                            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                              width: radius * 2, height: radius * 2))
                            canvas.stroke(ring, with: .color(mark.color.opacity(1 - t)), lineWidth: 3)
                        }
                        let dotAlpha = max(0, 1 - max(0, age - 1.1) / 0.5)
                        let dot = Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
                        canvas.fill(dot, with: .color(mark.color.opacity(dotAlpha)))
                        canvas.stroke(dot, with: .color(.white.opacity(dotAlpha)), lineWidth: 2)
                    case .stroke:
                        let alpha = age < mark.lifetime - 1 ? 1 : max(0, mark.lifetime - age)
                        var path = Path()
                        path.addLines(mark.points.map(point))
                        canvas.stroke(path, with: .color(.black.opacity(0.35 * alpha)),
                                      style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                        canvas.stroke(path, with: .color(mark.color.opacity(alpha)),
                                      style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Метки на экране ведущего

/// Прозрачная панель поверх того, что транслируется (экран или окно): клики проходят сквозь неё.
@MainActor
final class ShareMarksOverlay {
    static let shared = ShareMarksOverlay()

    let store = ShareMarkStore()
    private var panel: NSPanel?
    private var filter: SCContentFilter?
    private var follow: Timer?

    /// Окно меток — его в трансляцию не берём.
    var windowNumber: Int? { panel?.windowNumber }

    func attach(to filter: SCContentFilter) {
        self.filter = filter
        updateFrame()
        if follow == nil {
            // Окно могут двигать — догоняем.
            let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { ShareMarksOverlay.shared.updateFrame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            follow = timer
        }
    }

    func detach() {
        follow?.invalidate()
        follow = nil
        panel?.orderOut(nil)
        panel = nil
        filter = nil
        store.clear()
    }

    func show(_ mark: ShareMark) {
        guard UserDefaults.standard.bool(forKey: Pref.shareAllowMarks), panel != nil || filter != nil else { return }
        if panel == nil { updateFrame() }
        store.add(mark)
        panel?.orderFrontRegardless()
    }

    private func updateFrame() {
        guard let frame = targetFrame() else { return }
        let panel = self.panel ?? makePanel()
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: GeometryReader { proxy in
            ShareMarksLayer(store: ShareMarksOverlay.shared.store, rect: CGRect(origin: .zero, size: proxy.size))
        })
        panel.contentView = host
        self.panel = panel
        ScreenShare.shared.refreshVideoFilter()
        return panel
    }

    /// Где на экране то, что транслируется (в координатах Cocoa).
    private func targetFrame() -> NSRect? {
        guard let filter else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func cocoa(_ rect: CGRect) -> NSRect {
            NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        if #available(macOS 15.2, *) {
            if filter.style == .window, let window = filter.includedWindows.first {
                // Актуальная рамка окна — из списка окон (оно могло сдвинуться).
                let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], window.windowID) as? [[String: Any]]
                if let bounds = info?.first?[kCGWindowBounds as String] as? [String: CGFloat],
                   let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                    return cocoa(rect)
                }
                return cocoa(window.frame)
            }
            if let display = filter.includedDisplays.first {
                return cocoa(CGDisplayBounds(display.displayID))
            }
        }
        return (NSScreen.withMouse ?? NSScreen.main)?.frame
    }
}
