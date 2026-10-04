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

    private let image: CGImage
    private let baseImage: NSImage
    private lazy var pixelatedImage: NSImage? = makePixelated()
    private let snapRects: [CGRect]
    private let mode: ScreenshotService.Mode

    private var selection: NSRect?
    private var hoverRect: NSRect?
    private var dragStart: NSPoint?
    private var isSelecting = false
    private var annotations: [Annotation] = []
    private var current: Annotation?
    private(set) var tool: Tool = .arrow
    private(set) var color: NSColor = .systemRed
    private let lineWidth: CGFloat = 4
    private var toolbar: CaptureToolbar?
    private var textField: NSTextField?

    private var pixelScale: CGFloat { CGFloat(image.width) / max(bounds.width, 1) }

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
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    func resetSelection() {
        commitTextField()
        selection = nil
        hoverRect = nil
        isSelecting = false
        annotations.removeAll()
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

    override func mouseMoved(with event: NSEvent) {
        guard selection == nil, !isSelecting else { return }
        let p = point(event)
        let hover = snapRects.first { $0.contains(p) }
        if hover != hoverRect {
            hoverRect = hover
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        if textField != nil {
            commitTextField()
            return
        }
        if let selection, selection.contains(p), mode == .edit {
            if event.clickCount == 2 {
                current = nil
                copyResult()
                return
            }
            switch tool {
            case .text:
                beginText(at: p)
            case .pen, .marker:
                current = Annotation(tool: tool, color: color, width: lineWidth, points: [p])
            default:
                current = Annotation(tool: tool, color: color, width: lineWidth, points: [p, p])
            }
            return
        }
        // Новое выделение.
        ScreenshotService.shared.selectionBegan(in: self)
        toolbar?.isHidden = true
        dragStart = p
        isSelecting = true
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if isSelecting, let start = dragStart {
            selection = Annotation.rect(start, p)
            needsDisplay = true
            return
        }
        guard var annotation = current else { return }
        switch annotation.tool {
        case .pen, .marker:
            annotation.points.append(p)
        default:
            var end = p
            // Shift — ровная горизонталь/вертикаль для стрелки и квадрат для фигур.
            if event.modifierFlags.contains(.shift), let start = annotation.points.first {
                let dx = p.x - start.x, dy = p.y - start.y
                if annotation.tool == .arrow {
                    end = abs(dx) > abs(dy) ? NSPoint(x: p.x, y: start.y) : NSPoint(x: start.x, y: p.y)
                } else {
                    let side = max(abs(dx), abs(dy))
                    end = NSPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
                }
            }
            annotation.points = [annotation.points[0], end]
        }
        current = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isSelecting {
            isSelecting = false
            if let rect = selection, rect.width >= 4, rect.height >= 4 {
                selection = rect.integral.intersection(bounds)
            } else {
                // Простой клик: снимок окна под курсором или всего экрана.
                selection = hoverRect ?? bounds
            }
            hoverRect = nil
            finishSelection()
            return
        }
        if let annotation = current {
            current = nil
            if annotation.isMeaningful { annotations.append(annotation) }
            needsDisplay = true
        }
    }

    private func finishSelection() {
        if mode == .ocr {
            if let cropped = renderSelection(includeAnnotations: false) {
                ScreenshotService.shared.recognizeText(cropped)
            }
            return
        }
        showToolbar()
        needsDisplay = true
    }

    // MARK: - Клавиатура

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            ScreenshotService.shared.close()
        case 36, 76: // Return / Enter
            if selection != nil { copyResult() }
        default:
            if selection != nil, mode == .edit,
               let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...Tool.allCases.count).contains(n) {
                select(tool: Tool.allCases[n - 1])
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true,
              event.modifierFlags.contains(.command),
              !(window?.firstResponder is NSText) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "c":
            if selection != nil { copyResult() }
            return true
        case "s":
            if selection != nil { saveResult() }
            return true
        case "z":
            undo()
            return true
        case "w":
            ScreenshotService.shared.close()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
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
        toolbar?.update(tool: tool, color: color)
    }

    func undo() {
        if textField != nil {
            textField?.removeFromSuperview()
            textField = nil
            window?.makeFirstResponder(self)
        } else if !annotations.isEmpty {
            annotations.removeLast()
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
        var y = selection.minY - size.height - 10
        if y < 8 { y = selection.maxY + 10 }
        if y + size.height > bounds.height - 8 { y = selection.minY + 10 }
        bar.setFrameOrigin(NSPoint(x: x, y: y))
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
        if annotation.isMeaningful { annotations.append(annotation) }
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

        if isSelecting { drawSizeLabel(for: selection) }
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
