import AppKit
import MUDesign

/// Штрих на холсте одного экрана. Координаты — в точках холста этого экрана (начало внизу слева).
struct AnnotationStroke: Equatable {
    var display: CGDirectDisplayID
    var tool: ScreenAnnotator.Tool
    var color: NSColor
    var points: [NSPoint]
    var born = Date()
}

/// Все штрихи рисования на всех экранах, в порядке создания: одна «отмена» и один «стереть всё» на весь набор.
struct AnnotationStore {
    static let fadeAfter: TimeInterval = 3
    static let fadeDuration: TimeInterval = 0.6

    private(set) var strokes: [AnnotationStroke] = []

    var isEmpty: Bool { strokes.isEmpty }

    mutating func add(_ stroke: AnnotationStroke) { strokes.append(stroke) }

    /// Убирает последний нарисованный штрих (на любом экране). nil — рисовать было нечего.
    @discardableResult
    mutating func undo() -> AnnotationStroke? { strokes.popLast() }

    mutating func clear() { strokes.removeAll() }

    func strokes(on display: CGDirectDisplayID) -> [AnnotationStroke] { strokes.filter { $0.display == display } }

    /// Экран пропал (или сменил размер): его штрихи больше не имеют смысла.
    mutating func drop(displays: Set<CGDirectDisplayID>) { strokes.removeAll { displays.contains($0.display) } }

    /// Непрозрачность штриха: пока он свежий — 1, затем плавно гаснет.
    static func alpha(age: TimeInterval, fading: Bool) -> CGFloat {
        guard fading else { return 1 }
        return age < fadeAfter ? 1 : max(0, 1 - CGFloat(age - fadeAfter) / CGFloat(fadeDuration))
    }

    /// Удаляет угасшие штрихи; true, если что-то убрано.
    @discardableResult
    mutating func removeExpired(now: Date) -> Bool {
        let before = strokes.count
        strokes.removeAll { now.timeIntervalSince($0.born) > Self.fadeAfter + Self.fadeDuration }
        return strokes.count != before
    }
}

/// Что делать с оверлеями при изменении набора экранов.
enum AnnotationScreens {
    struct Plan: Equatable {
        /// Новые экраны: нужен оверлей.
        var add: [CGDirectDisplayID] = []
        /// Пропавшие экраны: оверлей убрать.
        var remove: [CGDirectDisplayID] = []
        /// Остались, но рамка изменилась (разрешение, расположение): оверлей подогнать, штрихи этого экрана сбросить.
        var resize: [CGDirectDisplayID] = []
        /// Остались без изменений.
        var keep: [CGDirectDisplayID] = []

        var isEmpty: Bool { add.isEmpty && remove.isEmpty && resize.isEmpty }
    }

    static func plan(existing: [CGDirectDisplayID: CGRect], current: [CGDirectDisplayID: CGRect]) -> Plan {
        var plan = Plan()
        for id in current.keys.sorted() {
            guard let old = existing[id] else { plan.add.append(id); continue }
            if old == current[id] { plan.keep.append(id) } else { plan.resize.append(id) }
        }
        plan.remove = existing.keys.filter { current[$0] == nil }.sorted()
        return plan
    }
}

/// Режим «сквозь клики»: рисунок остаётся на экране, а мышь работает с программами под ним.
enum AnnotationMode {
    /// Удержание ⌥ на время переворачивает режим: в «сквозь клики» — можно порисовать, при рисовании — можно кликнуть.
    static func ignoresMouse(clickThrough: Bool, optionHeld: Bool) -> Bool { clickThrough != optionHeld }
}

/// Рисование штрихов и склейка с кадром экрана.
enum AnnotationRenderer {
    /// Рисует штрих в текущем графическом контексте.
    static func draw(_ stroke: AnnotationStroke, alpha: CGFloat) {
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

    /// Кадр экрана с нарисованным поверх: `pointSize` — размер экрана в точках (штрихи заданы в них),
    /// кадр может быть крупнее (Retina). Размер результата равен размеру кадра.
    static func compose(base: CGImage, strokes: [(stroke: AnnotationStroke, alpha: CGFloat)], pointSize: CGSize) -> CGImage? {
        let width = base.width, height = base.height
        guard width > 0, height > 0, pointSize.width > 0, pointSize.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.cgContext.scaleBy(x: CGFloat(width) / pointSize.width, y: CGFloat(height) / pointSize.height)
        for item in strokes where item.alpha > 0 { draw(item.stroke, alpha: item.alpha) }
        context.flushGraphics()
        return rep.cgImage
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Пишет файл, не затирая существующий: занятое имя получает номер «(2)», «(3)».
    static func writeUnique(_ data: Data, to url: URL, limit: Int = 1000) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        guard limit >= 1 else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path]) }
        for index in 1...limit {
            let name = index == 1 ? url.lastPathComponent : (ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)")
            let candidate = folder.appendingPathComponent(name)
            do {
                try data.write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
    }

    /// Имя файла снимка с рисунком.
    static func snapshotName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return "Снимок с рисунком \(formatter.string(from: date)).png"
    }
}
