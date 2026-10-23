import AppKit
import SwiftUI
import MUDesign

/// Линейка под панелью форматирования (`d01`): поля страницы (серые края), отступы абзаца у курсора — треугольники
/// Word (первая строка сверху, левый и правый снизу) — и позиции табуляции. Отступы и позиции тянутся мышью: шаг
/// 0,25 см, с ⌥ — без шага. Щелчок по линейке — новая позиция табуляции, позицию стащить вниз — убрать. Отпустили —
/// одна правка абзацев выделения.
struct FormatRuler: NSViewRepresentable {
    @ObservedObject var document: DocumentController
    @ObservedObject var formatter: DocFormatter

    func makeNSView(context: Context) -> FormatRulerView {
        let view = FormatRulerView()
        view.attach(document, formatter: formatter)
        return view
    }

    func updateNSView(_ view: FormatRulerView, context: Context) {
        view.attach(document, formatter: formatter)
        view.paragraph = formatter.state.paragraph
        view.needsDisplay = true
    }
}

final class FormatRulerView: NSView {
    private weak var controller: DocumentController?
    private weak var formatter: DocFormatter?
    var paragraph: RTFParaProps?
    private var observers: [NSObjectProtocol] = []
    private var drag: (marker: Marker, left: Int, firstLine: Int, right: Int)?
    /// Перетаскивание позиции табуляции (или щелчок для новой): номер, новая позиция, убрать ли.
    private var tabDrag: (index: Int?, position: Int, removing: Bool, moved: Bool)?

    enum Marker { case firstLine, left, right }

    /// 1 см в твипах.
    static let centimetre = 566.93
    override var isFlipped: Bool { true }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func attach(_ controller: DocumentController, formatter: DocFormatter) {
        self.formatter = formatter
        setAccessibilityRole(.ruler)
        setAccessibilityLabel("Линейка: поля, отступы и табуляции абзаца")
        guard self.controller !== controller else { return }
        self.controller = controller
        observers.forEach(NotificationCenter.default.removeObserver)
        let clip = controller.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        controller.pagesView.postsFrameChangedNotifications = true
        let redraw: (Notification) -> Void = { [weak self] _ in self?.needsDisplay = true }
        observers = [
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: redraw),
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: controller.pagesView, queue: .main, using: redraw),
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: controller.scrollView, queue: .main, using: redraw),
        ]
    }

    // MARK: - Геометрия

    /// Где на линейке бумага и текст страницы у курсора, и сколько точек линейки в одном твипе.
    private struct Geometry {
        var paper: ClosedRange<CGFloat>
        var body: ClosedRange<CGFloat>
        var perTwip: CGFloat
        var props: RTFSectionProps

        func x(_ twips: Int, fromRight: Bool = false) -> CGFloat {
            fromRight ? body.upperBound - CGFloat(twips) * perTwip : body.lowerBound + CGFloat(twips) * perTwip
        }
    }

    private var page: DocPageView? {
        MainActor.assumeIsolated {
            guard let controller else { return nil }
            if let page = formatter?.headerSession?.page { return page }
            return controller.textView(forUnit: controller.selectedUnits.location)?.page ?? controller.pagesView.pages.first
        }
    }

    private func geometry() -> Geometry? {
        guard let page, page.window != nil, window != nil, page.bounds.width > 0 else { return nil }
        let paper = convert(page.convert(page.bounds, to: nil), from: nil)
        let body = convert(page.convert(page.bodyRect, to: nil), from: nil)
        let perPoint = paper.width / page.bounds.width
        return Geometry(paper: paper.minX...paper.maxX, body: body.minX...body.maxX, perTwip: perPoint / 20, props: page.props)
    }

    // MARK: - Рисование

    override func draw(_ dirtyRect: NSRect) {
        guard let geometry = geometry() else { return }
        let band = NSRect(x: geometry.paper.lowerBound, y: 5, width: geometry.paper.upperBound - geometry.paper.lowerBound, height: 16)
        DS.Palette.off.withAlphaComponent(0.6).setFill()
        band.fill()
        DS.Palette.panel.setFill()
        NSRect(x: geometry.body.lowerBound, y: band.minY, width: geometry.body.upperBound - geometry.body.lowerBound, height: band.height).fill()
        drawTicks(geometry, band: band)
        drawTabs(geometry, band: band)
        drawIndents(geometry, band: band)
    }

    private func drawTicks(_ geometry: Geometry, band: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
                                                         .foregroundColor: DS.Palette.mute]
        DS.Palette.mute.setFill()
        let step = Self.centimetre / 2 * Double(geometry.perTwip)
        guard step > 2 else { return }
        let origin = geometry.body.lowerBound
        var k = -Int(((origin - geometry.paper.lowerBound) / CGFloat(step)).rounded(.down))
        while true {
            let x = origin + CGFloat(Double(k) * step)
            if x > geometry.paper.upperBound { break }
            if x >= geometry.paper.lowerBound, k != 0 {
                if k % 2 == 0, (k / 2) % 2 == 0 {
                    let label = "\(abs(k / 2))" as NSString
                    let size = label.size(withAttributes: attributes)
                    label.draw(at: NSPoint(x: x - size.width / 2, y: band.minY + 1), withAttributes: attributes)
                } else {
                    let height: CGFloat = k % 2 == 0 ? 6 : 3
                    NSRect(x: x - 0.5, y: band.midY - height / 2 + 2, width: 1, height: height).fill()
                }
            }
            k += 1
        }
    }

    private func drawTabs(_ geometry: Geometry, band: NSRect) {
        var tabs = paragraph?.tabs ?? []
        if let tabDrag, let index = tabDrag.index, tabs.indices.contains(index) {
            if tabDrag.removing { tabs.remove(at: index) } else { tabs[index].position = tabDrag.position }
        }
        guard !tabs.isEmpty else { return }
        DS.Palette.text.setFill()
        for tab in tabs {
            let x = geometry.x(tab.position)
            NSRect(x: x - 0.75, y: band.maxY - 7, width: 1.5, height: 6).fill()
            switch tab.kind {
            case .left: NSRect(x: x - 0.75, y: band.maxY - 2.5, width: 5, height: 1.5).fill()
            case .right, .decimal: NSRect(x: x - 4.25, y: band.maxY - 2.5, width: 5, height: 1.5).fill()
            case .center, .bar: NSRect(x: x - 3, y: band.maxY - 2.5, width: 6, height: 1.5).fill()
            }
        }
    }

    private func drawIndents(_ geometry: Geometry, band: NSRect) {
        let props = current
        DS.Palette.text.setFill()
        triangle(at: geometry.x(props.left + props.firstLine), y: band.minY - 1, down: true).fill()
        triangle(at: geometry.x(props.left), y: band.maxY + 1, down: false).fill()
        triangle(at: geometry.x(props.right, fromRight: true), y: band.maxY + 1, down: false).fill()
    }

    /// Отступы, которые видно: во время перетаскивания — новые.
    private var current: (left: Int, firstLine: Int, right: Int) {
        if let drag { return (drag.left, drag.firstLine, drag.right) }
        return (paragraph?.left ?? 0, paragraph?.firstLine ?? 0, paragraph?.right ?? 0)
    }

    private func triangle(at x: CGFloat, y: CGFloat, down: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let size: CGFloat = 5
        if down {
            path.move(to: NSPoint(x: x - size, y: y - size))
            path.line(to: NSPoint(x: x + size, y: y - size))
            path.line(to: NSPoint(x: x, y: y + 2))
        } else {
            path.move(to: NSPoint(x: x - size, y: y + size))
            path.line(to: NSPoint(x: x + size, y: y + size))
            path.line(to: NSPoint(x: x, y: y - 2))
        }
        path.close()
        return path
    }

    // MARK: - Перетаскивание отступов

    private func snapped(_ point: NSPoint, geometry: Geometry, free: Bool) -> Int {
        let twips = Double((point.x - geometry.body.lowerBound) / geometry.perTwip)
        return free ? Int(twips.rounded()) : Int(((twips / (Self.centimetre / 4)).rounded() * (Self.centimetre / 4)).rounded())
    }

    override func mouseDown(with event: NSEvent) {
        guard paragraph != nil, let geometry = geometry(), geometry.perTwip > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let props = current
        let candidates: [(Marker, CGFloat, Bool)] = [
            (.firstLine, geometry.x(props.left + props.firstLine), true),
            (.left, geometry.x(props.left), false),
            (.right, geometry.x(props.right, fromRight: true), false),
        ]
        // Верхний треугольник — над серединой полосы, нижние — под ней.
        let top = point.y < bounds.midY
        if let hit = candidates.filter({ $0.2 == top || abs($0.1 - point.x) < 3 }).min(by: { abs($0.1 - point.x) < abs($1.1 - point.x) }),
           abs(hit.1 - point.x) <= 7 {
            drag = (hit.0, props.left, props.firstLine, props.right)
            return
        }
        // Позиция табуляции под мышью — тянуть; иначе щелчок по тексту линейки — новая позиция.
        let tabs = paragraph?.tabs ?? []
        if let index = tabs.indices.min(by: { abs(geometry.x(tabs[$0].position) - point.x) < abs(geometry.x(tabs[$1].position) - point.x) }),
           abs(geometry.x(tabs[index].position) - point.x) <= 5 {
            tabDrag = (index, tabs[index].position, false, false)
        } else if geometry.body.contains(point.x) {
            tabDrag = (nil, snapped(point, geometry: geometry, free: event.modifierFlags.contains(.option)), false, false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let geometry = geometry(), geometry.perTwip > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let free = event.modifierFlags.contains(.option)
        if var tabDrag {
            tabDrag.position = max(0, snapped(point, geometry: geometry, free: free))
            tabDrag.removing = tabDrag.index != nil && point.y > bounds.maxY + 10
            tabDrag.moved = true
            self.tabDrag = tabDrag
            needsDisplay = true
            return
        }
        guard var drag else { return }
        let width = Int((geometry.body.upperBound - geometry.body.lowerBound) / geometry.perTwip)
        let fromLeft = snapped(point, geometry: geometry, free: free)
        let marginLeft = geometry.props.marginLeft, marginRight = geometry.props.marginRight
        switch drag.marker {
        case .firstLine:
            drag.firstLine = min(max(fromLeft, -marginLeft), width - drag.right - 144) - drag.left
        case .left:
            drag.left = min(max(fromLeft, -marginLeft), width - drag.right - 144)
        case .right:
            drag.right = min(max(width - fromLeft, -marginRight), width - max(drag.left, drag.left + drag.firstLine) - 144)
        }
        self.drag = drag
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let tabDrag {
            self.tabDrag = nil
            needsDisplay = true
            let edit: TabEdit?
            switch (tabDrag.index, tabDrag.removing) {
            case (let index?, true): edit = .remove(index)
            case (let index?, false): edit = tabDrag.moved && paragraph?.tabs[safe: index]?.position != tabDrag.position ? .move(index, to: tabDrag.position) : nil
            case (nil, _): edit = .add(RTFTabStop(position: tabDrag.position))
            }
            if let edit { MainActor.assumeIsolated { formatter?.editTabs(edit) } }
            return
        }
        guard let drag else { return }
        self.drag = nil
        needsDisplay = true
        let before = (paragraph?.left ?? 0, paragraph?.firstLine ?? 0, paragraph?.right ?? 0)
        guard (drag.left, drag.firstLine, drag.right) != before else { return }
        MainActor.assumeIsolated { formatter?.setIndents(left: drag.left, firstLine: drag.firstLine, right: drag.right) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
