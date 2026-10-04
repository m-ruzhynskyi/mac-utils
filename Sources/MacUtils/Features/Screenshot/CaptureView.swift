// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreImage

/// Полноэкранное окно с «замороженным» снимком одного монитора.
@MainActor
final class CaptureWindow: NSWindow {
    private(set) var captureView: CaptureView!

    static func make(shot: ScreenShot, snapFrames: [CGRect], mode: ScreenshotService.Mode) -> CaptureWindow {
        let frame = shot.screen.frame
        let local = snapFrames.compactMap { rect -> CGRect? in
            let visible = rect.intersection(frame)
            guard !visible.isNull, visible.width > 40, visible.height > 40 else { return nil }
            return visible.offsetBy(dx: -frame.minX, dy: -frame.minY)
        }
        let view = CaptureView(frame: NSRect(origin: .zero, size: frame.size),
                               image: shot.image, snapRects: local, mode: mode)
        let window = CaptureWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = view
        window.captureView = view
        window.makeFirstResponder(view)
        return window
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Выделение области, «прилипание» к окнам и разметка.
@MainActor
final class CaptureView: NSView, NSTextFieldDelegate {
    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                     .systemBlue, .systemPurple, .white, .black]

    /// Ручки изменения размера выделения.
    private enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left
    }

    /// Что делает текущее перетаскивание мышью.
    private enum Drag {
        case none
        case selecting(start: NSPoint)
        case drawing
        case movingAnnotation(index: Int, last: NSPoint)
        case movingSelection(last: NSPoint)
        case resizing(handle: Handle, original: NSRect, start: NSPoint)
    }

    private let image: CGImage
    private let baseImage: NSImage
    private lazy var pixelatedImage: NSImage? = makePixelated()
    private let snapRects: [CGRect]
    private let mode: ScreenshotService.Mode

    private var selection: NSRect?
    private var hoverRect: NSRect?
    private var drag: Drag = .none
    private var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var selectedIndex: Int?
    private var current: Annotation?
    private(set) var tool: Tool = .arrow
    private(set) var color: NSColor = .systemRed
    private let lineWidth: CGFloat = 4
    private var toolbar: CaptureToolbar?
    private var textField: NSTextField?

    private var pixelScale: CGFloat { CGFloat(image.width) / max(bounds.width, 1) }

    private var isSelecting: Bool {
        if case .selecting = drag { return true }
        return false
    }

    init(frame: NSRect, image: CGImage, snapRects: [CGRect], mode: ScreenshotService.Mode) {
        self.image = image
        self.baseImage = NSImage(cgImage: image, size: frame.size)
        self.snapRects = snapRects
        self.mode = mode
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    var hasSelection: Bool { selection != nil }

    func resetSelection() {
        commitTextField()
        selection = nil
        hoverRect = nil
        drag = .none
        annotations.removeAll()
        undoStack.removeAll()
        selectedIndex = nil
        current = nil
        toolbar?.removeFromSuperview()
        toolbar = nil
        needsDisplay = true
    }

    // MARK: - Мышь

    private func point(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private var isEditing: Bool { mode == .edit && selection != nil && toolbar?.isHidden == false }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        updateCursor(at: p)
        guard selection == nil, !isSelecting else { return }
        let hover = snapRects.first { $0.contains(p) }
        if hover != hoverRect {
            hoverRect = hover
            needsDisplay = true
        }
    }

    private func updateCursor(at p: NSPoint) {
        guard isEditing, let selection else {
            NSCursor.crosshair.set()
            return
        }
        if let handle = handle(at: p) {
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        } else if annotationIndex(at: p) != nil {
            NSCursor.openHand.set()
        } else if selection.contains(p) && tool == .select {
            NSCursor.openHand.set()
        } else if selection.contains(p) && tool == .text {
            NSCursor.iBeam.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        if textField != nil {
            commitTextField()
            return
        }

        if isEditing, let selection {
            if let handle = handle(at: p) {
                drag = .resizing(handle: handle, original: selection, start: p)
                return
            }
            if selection.contains(p) {
                if event.clickCount == 2 && annotationIndex(at: p) == nil {
                    copyResult()
                    return
                }
                // Клик по нарисованному — выбрать и перетаскивать.
                if let index = annotationIndex(at: p) {
                    pushUndo()
                    selectedIndex = index
                    drag = .movingAnnotation(index: index, last: p)
                    NSCursor.closedHand.set()
                    needsDisplay = true
                    return
                }
                selectedIndex = nil
                switch tool {
                case .select:
                    drag = .movingSelection(last: p)
                    NSCursor.closedHand.set()
                case .text:
                    beginText(at: p)
                case .counter:
                    pushUndo()
                    var marker = Annotation(tool: .counter, color: color, width: lineWidth, points: [p])
                    marker.number = nextCounterNumber()
                    annotations.append(marker)
                    selectedIndex = annotations.count - 1
                    drag = .movingAnnotation(index: annotations.count - 1, last: p)
                case .pen, .marker:
                    current = Annotation(tool: tool, color: color, width: lineWidth, points: [p])
                    drag = .drawing
                default:
                    current = Annotation(tool: tool, color: color, width: lineWidth, points: [p, p])
                    drag = .drawing
                }
                needsDisplay = true
                return
            }
        }

        // Новое выделение.
        ScreenshotService.shared.selectionBegan(in: self)
        toolbar?.isHidden = true
        selectedIndex = nil
        drag = .selecting(start: p)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .none:
            return

        case .selecting(let start):
            selection = Annotation.rect(start, p)

        case .drawing:
            guard var annotation = current else { return }
            switch annotation.tool {
            case .pen, .marker:
                annotation.points.append(p)
            default:
                annotation.points = [annotation.points[0], constrained(p, from: annotation.points[0],
                                                                       tool: annotation.tool, event: event)]
            }
            current = annotation

        case .movingAnnotation(let index, let last):
            guard annotations.indices.contains(index) else { return }
            annotations[index].offset(dx: p.x - last.x, dy: p.y - last.y)
            drag = .movingAnnotation(index: index, last: p)

        case .movingSelection(let last):
            guard var rect = selection else { return }
            rect.origin.x = min(max(0, rect.minX + p.x - last.x), bounds.width - rect.width)
            rect.origin.y = min(max(0, rect.minY + p.y - last.y), bounds.height - rect.height)
            selection = rect
            toolbar?.isHidden = true
            drag = .movingSelection(last: p)

        case .resizing(let handle, let original, let start):
            selection = resized(original, handle: handle, dx: p.x - start.x, dy: p.y - start.y)
            toolbar?.isHidden = true
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = .none
        switch finished {
        case .selecting:
            if let rect = selection, rect.width >= 4, rect.height >= 4 {
                selection = rect.integral.intersection(bounds)
            } else {
                // Простой клик: снимок окна под курсором или всего экрана.
                selection = hoverRect ?? bounds
            }
            hoverRect = nil
            finishSelection()

        case .drawing:
            if let annotation = current, annotation.isMeaningful {
                pushUndo()
                annotations.append(annotation)
            }
            current = nil

        case .movingAnnotation:
            NSCursor.openHand.set()

        case .movingSelection, .resizing:
            if let rect = selection {
                selection = rect.integral.intersection(bounds)
            }
            showToolbar()

        case .none:
            break
        }
        needsDisplay = true
    }

    /// Shift — ровная горизонталь/вертикаль для стрелки и квадрат для фигур.
    private func constrained(_ p: NSPoint, from start: NSPoint, tool: Tool, event: NSEvent) -> NSPoint {
        guard event.modifierFlags.contains(.shift) else { return p }
        let dx = p.x - start.x, dy = p.y - start.y
        if tool == .arrow {
            return abs(dx) > abs(dy) ? NSPoint(x: p.x, y: start.y) : NSPoint(x: start.x, y: p.y)
        }
        let side = max(abs(dx), abs(dy))
        return NSPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    private func finishSelection() {
        if mode == .ocr {
            if let cropped = renderSelection(includeAnnotations: false) {
                ScreenshotService.shared.recognizeText(cropped)
            }
            return
        }
        showToolbar()
    }

    // MARK: - Ручки выделения

    private func handlePoint(_ handle: Handle, in rect: NSRect) -> NSPoint {
        switch handle {
        case .bottomLeft: return NSPoint(x: rect.minX, y: rect.minY)
        case .bottom: return NSPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: return NSPoint(x: rect.maxX, y: rect.minY)
        case .right: return NSPoint(x: rect.maxX, y: rect.midY)
        case .topRight: return NSPoint(x: rect.maxX, y: rect.maxY)
        case .top: return NSPoint(x: rect.midX, y: rect.maxY)
        case .topLeft: return NSPoint(x: rect.minX, y: rect.maxY)
        case .left: return NSPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handle(at p: NSPoint) -> Handle? {
        guard let selection else { return nil }
        return Handle.allCases.first { handle in
            let c = handlePoint(handle, in: selection)
            return abs(c.x - p.x) <= 7 && abs(c.y - p.y) <= 7
        }
    }

    private func resized(_ rect: NSRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> NSRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft: minX += dx
        case .right, .topRight, .bottomRight: maxX += dx
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: minY += dy
        case .top, .topLeft, .topRight: maxY += dy
        default: break
        }
        let a = NSPoint(x: min(max(minX, 0), bounds.width), y: min(max(minY, 0), bounds.height))
        let b = NSPoint(x: min(max(maxX, 0), bounds.width), y: min(max(maxY, 0), bounds.height))
        var result = Annotation.rect(a, b)
        result.size.width = max(result.width, 8)
        result.size.height = max(result.height, 8)
        return result
    }

    // MARK: - Нарисованные элементы

    private func annotationIndex(at p: NSPoint) -> Int? {
        annotations.indices.reversed().first { annotations[$0].hitTest(p) }
    }

    private func nextCounterNumber() -> Int {
        (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
    }

    private func pushUndo() {
        undoStack.append(annotations)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    private func deleteSelected() {
        guard let index = selectedIndex, annotations.indices.contains(index) else { return }
        pushUndo()
        annotations.remove(at: index)
        selectedIndex = nil
        needsDisplay = true
    }

    // MARK: - Клавиатура

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true,
              event.modifierFlags.contains(.command),
              !(window?.firstResponder is NSText) else {
            return super.performKeyEquivalent(with: event)
        }
        return handleKey(event) || super.performKeyEquivalent(with: event)
    }

    /// Идёт ввод текста в поле надписи: клавиши должны попадать в него.
    var isEditingText: Bool { textField != nil }

    /// Обрабатывает клавишу оверлея; `false` — клавиша не наша.
    /// Вызывается и из keyDown, и из перехватчика клавиш ScreenshotService,
    /// который работает, даже если окно оверлея не стало ключевым.
    func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "c":
                if selection != nil { copyResult() }
            case "s":
                if selection != nil { saveResult() }
            case "z":
                undo()
            case "w":
                ScreenshotService.shared.close()
            default:
                return false
            }
            return true
        }
        switch event.keyCode {
        case 53: // Esc
            if selectedIndex != nil {
                selectedIndex = nil
                needsDisplay = true
            } else {
                ScreenshotService.shared.close()
            }
        case 36, 76: // Return / Enter
            if selection != nil { copyResult() }
        case 51, 117: // Delete / Forward Delete
            deleteSelected()
        default:
            guard selection != nil, mode == .edit,
                  let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
            if chars == "v" {
                select(tool: .select)
            } else if let n = Int(chars), (1...Tool.numbered.count).contains(n) {
                select(tool: Tool.numbered[n - 1])
            } else {
                return false
            }
        }
        return true
    }

    // MARK: - Действия панели

    func select(tool: Tool) {
        commitTextField()
        self.tool = tool
        toolbar?.update(tool: tool, color: color)
    }

    func cycleColor() {
        let index = Self.palette.firstIndex(of: color) ?? 0
        color = Self.palette[(index + 1) % Self.palette.count]
        textField?.textColor = color
        if let selectedIndex, annotations.indices.contains(selectedIndex) {
            pushUndo()
            annotations[selectedIndex].color = color
        }
        toolbar?.update(tool: tool, color: color)
        needsDisplay = true
    }

    func undo() {
        if textField != nil {
            textField?.removeFromSuperview()
            textField = nil
            window?.makeFirstResponder(self)
        } else if let previous = undoStack.popLast() {
            annotations = previous
            selectedIndex = nil
        }
        needsDisplay = true
    }

    func copyResult() {
        guard let result = renderSelection() else { return }
        ScreenshotService.shared.copy(result)
    }

    func saveResult() {
        guard let result = renderSelection() else { return }
        ScreenshotService.shared.save(result)
    }

    func recognizeText() {
        guard let result = renderSelection(includeAnnotations: false) else { return }
        ScreenshotService.shared.recognizeText(result)
    }

    func startScrollCapture() {
        guard let selection, let window else { return }
        let global = selection.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        ScreenshotService.shared.startScrollCapture(rect: global)
    }

    func closeCapture() {
        ScreenshotService.shared.close()
    }

    private func showToolbar() {
        guard let selection else { return }
        let bar = toolbar ?? CaptureToolbar(owner: self)
        if toolbar == nil {
            addSubview(bar)
            toolbar = bar
        }
        bar.isHidden = false
        bar.update(tool: tool, color: color)
        let size = bar.frame.size
        let x = min(max(8, selection.midX - size.width / 2), bounds.width - size.width - 8)
        var y = selection.minY - size.height - 12
        if y < 8 { y = selection.maxY + 12 }
        if y + size.height > bounds.height - 8 { y = selection.minY + 12 }
        bar.setFrameOrigin(NSPoint(x: x, y: y))
        needsDisplay = true
    }

    // MARK: - Текст

    private func beginText(at p: NSPoint) {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        field.textColor = color
        field.placeholderString = "Текст"
        field.delegate = self
        field.frame = NSRect(x: p.x, y: p.y - 15, width: max(120, min(500, bounds.width - p.x - 8)), height: 30)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextField()
    }

    private func commitTextField() {
        guard let field = textField else { return }
        textField = nil
        var annotation = Annotation(tool: .text, color: field.textColor ?? color, width: lineWidth,
                                    points: [NSPoint(x: field.frame.minX + 2, y: field.frame.minY + 3)])
        annotation.text = field.stringValue
        field.removeFromSuperview()
        if annotation.isMeaningful {
            pushUndo()
            annotations.append(annotation)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Отрисовка

    override func draw(_ dirtyRect: NSRect) {
        baseImage.draw(in: bounds)

        guard let selection else {
            if let hoverRect {
                dim(outside: hoverRect, alpha: 0.3)
                let border = NSBezierPath(rect: hoverRect.insetBy(dx: 1, dy: 1))
                border.lineWidth = 2
                NSColor.systemBlue.setStroke()
                border.stroke()
            } else {
                NSColor.black.withAlphaComponent(0.3).setFill()
                bounds.fill()
            }
            return
        }

        let needsPixelated = annotations.contains { $0.tool == .pixelate } || current?.tool == .pixelate
        let pixelated = needsPixelated ? pixelatedImage : nil
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        for annotation in annotations { annotation.draw(pixelated: pixelated, canvas: bounds) }
        current?.draw(pixelated: pixelated, canvas: bounds)
        NSGraphicsContext.restoreGraphicsState()

        dim(outside: selection, alpha: 0.45)
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()

        if let selectedIndex, annotations.indices.contains(selectedIndex) {
            let outline = NSBezierPath(rect: annotations[selectedIndex].bounds.insetBy(dx: -6, dy: -6))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            outline.stroke()
        }

        if isEditing {
            for handle in Handle.allCases {
                let c = handlePoint(handle, in: selection)
                let square = NSBezierPath(roundedRect: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8),
                                          xRadius: 2, yRadius: 2)
                NSColor.white.setFill()
                square.fill()
                NSColor.black.withAlphaComponent(0.4).setStroke()
                square.lineWidth = 0.5
                square.stroke()
            }
        }

        switch drag {
        case .selecting, .resizing, .movingSelection: drawSizeLabel(for: selection)
        default: break
        }
    }

    private func dim(outside rect: NSRect, alpha: CGFloat) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: rect))
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    private func drawSizeLabel(for rect: NSRect) {
        let text = "\(Int(rect.width * pixelScale)) × \(Int(rect.height * pixelScale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + size.height + 6 > bounds.height { origin.y = rect.maxY - size.height - 10 }
        let background = NSRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        string.draw(at: NSPoint(x: origin.x + 6, y: origin.y + 2))
    }

    // MARK: - Итоговое изображение

    func renderSelection(includeAnnotations: Bool = true) -> CGImage? {
        commitTextField()
        guard let rect = selection?.intersection(bounds), rect.width >= 1, rect.height >= 1 else { return nil }
        let scale = pixelScale
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let preferred = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: preferred, bitmapInfo: bitmapInfo)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo) else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        baseImage.draw(in: bounds)
        if includeAnnotations {
            let pixelated = annotations.contains { $0.tool == .pixelate } ? pixelatedImage : nil
            for annotation in annotations { annotation.draw(pixelated: pixelated, canvas: bounds) }
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private func makePixelated() -> NSImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(12 * pixelScale, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cgImage = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: bounds.size)
    }
}
