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

/// Геометрия меток, общая для всех сторон трансляции: точка — доля кадра (0…1) от его левого верхнего угла, кадр —
/// ровно транслируемая область. Зритель Mac, страница relay и окно меток Windows считают одинаково
/// (страница — `imageRect`/`framePoint`, Windows — overlay-place.js).
enum ShareMarkGeometry {
    /// Где кадр внутри вида: вписан с сохранением пропорций и по центру (как `resizeAspect` у слоя видео).
    static func imageRect(frame: CGSize?, in size: CGSize) -> CGRect {
        guard let frame, frame.width > 0, frame.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / frame.width, size.height / frame.height)
        let fitted = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// Точка вида (y вниз, как у SwiftUI) → доля кадра; вне кадра — nil.
    static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    /// Доля кадра → точка вида.
    static func point(_ unit: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
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
                    let point = { (p: CGPoint) in ShareMarkGeometry.point(p, in: rect) }
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
/// В ней же — уведомление ведущему «‹имя› переключает на монитор N»: панель исключена из захвата, зрители его не видят.
@MainActor
final class ShareMarksOverlay {
    static let shared = ShareMarksOverlay()

    let store = ShareMarkStore()
    let notices = ShareHostNotices()
    private var panel: NSPanel?
    private var filter: SCContentFilter?
    /// Транслируемый экран, если известен: рамка по нему, а не по экрану под курсором (macOS до 15.2).
    private var display: CGDirectDisplayID?
    private var follow: Timer?

    /// Окно меток — его в трансляцию не берём.
    var windowNumber: Int? { panel?.windowNumber }

    func attach(to filter: SCContentFilter, display: CGDirectDisplayID? = nil) {
        self.filter = filter
        self.display = filter.style == .display ? display : nil
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
        display = nil
        store.clear()
        notices.hide()
    }

    /// Зритель переключил монитор: короткое уведомление в правом верхнем углу нового монитора, 4 с, без кнопок и звука.
    /// Показывается и при выключенных метках.
    func notice(name: String, monitor: Int, displays: [ShareDisplay]) {
        guard filter != nil else { return }
        if panel == nil { updateFrame() }
        let screen = display.flatMap { id in NSScreen.screens.first { $0.displayID == id } }
        // Под строкой меню и индикатором «Эфир».
        let top = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        notices.show(ShareHostNotice(name: name, monitor: monitor, displays: displays), top: top + 44)
        panel?.orderFrontRegardless()
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
        if panel.frame != frame {
            // Транслируемое окно изменило размер — поток под новый размер, иначе кадр и панель меток разойдутся.
            if panel.frame.size != frame.size, panel.frame.width > 0 { ScreenShare.shared.sharedWindowResized(to: frame.size) }
            panel.setFrame(frame, display: true)
        }
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
            ZStack(alignment: .topTrailing) {
                ShareMarksLayer(store: ShareMarksOverlay.shared.store, rect: CGRect(origin: .zero, size: proxy.size))
                ShareHostNoticeLayer(notices: ShareMarksOverlay.shared.notices)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
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
        if let display { return cocoa(CGDisplayBounds(display)) }
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
