import AppKit
import SwiftUI
import MUDesign
import MUAudio

/// Панель инструментов под выделенной областью (Graphite: `panel`, обводка `line`, радиус 20, кнопки 36×36).
@MainActor
final class CaptureToolbar: NSView {
    private weak var owner: CaptureView?
    private var toolButtons: [Tool: ToolbarButton] = [:]
    private var colorButton: ToolbarButton?
    private var frameButton: ToolbarButton?

    /// Для снимков интерфейса: панель без владельца (кнопки ничего не делают).
    convenience init() { self.init(owner: nil) }

    init(owner: CaptureView?) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.floating
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -8)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        for (index, tool) in Tool.allCases.enumerated() {
            let button = makeButton(symbol: tool.symbol, fallback: String(tool.title.prefix(1)), tip: tool.title,
                                    label: tool.shortTitle, action: #selector(toolPressed(_:)))
            button.tag = index
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())

        let color = makeButton(symbol: nil, fallback: "●", tip: "Цвет", label: "Цвет", action: #selector(colorPressed))
        colorButton = color
        stack.addArrangedSubview(color)
        stack.addArrangedSubview(makeButton(symbol: "arrow.uturn.backward", fallback: "↶",
                                            tip: "Отменить (⌘Z или ⌃Z), повторить — ⇧⌘Z", label: "Отменить", action: #selector(undoPressed)))
        stack.addArrangedSubview(separator())
        let frame = makeButton(symbol: "macwindow", fallback: "▭",
                               tip: "Рамка окна macOS (F)", label: "Окно", action: #selector(framePressed))
        frameButton = frame
        stack.addArrangedSubview(frame)
        stack.addArrangedSubview(makeButton(symbol: "square.stack.3d.down.right", fallback: "+",
                                            tip: "Шаг + в коллаж (A)", label: "Шаг +", action: #selector(stepPressed)))
        stack.addArrangedSubview(separator())
        let record = makeButton(symbol: "record.circle", fallback: "●",
                                tip: "Запись экрана (R)", label: "Запись", action: #selector(recordPressed))
        record.look = .record
        stack.addArrangedSubview(record)
        stack.addArrangedSubview(makeButton(symbol: "scroll", fallback: "⇕",
                                            tip: "Длинный снимок с прокруткой", label: "Длинный", action: #selector(scrollPressed)))
        stack.addArrangedSubview(makeButton(symbol: "text.viewfinder", fallback: "OCR",
                                            tip: "Распознать текст", label: "OCR", action: #selector(ocrPressed)))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(makeButton(symbol: "square.and.arrow.down", fallback: "S",
                                            tip: "Сохранить (⌘S)", label: "Сохранить", action: #selector(savePressed)))
        let copy = makeButton(symbol: "doc.on.doc", fallback: "C",
                              tip: "Скопировать (⌘C)", label: "Копия", action: #selector(copyPressed))
        copy.look = .main
        stack.addArrangedSubview(copy)
        stack.addArrangedSubview(makeButton(symbol: "xmark", fallback: "×",
                                            tip: "Закрыть (Esc)", label: "Закрыть", action: #selector(closePressed)))

        let size = stack.fittingSize
        setFrameSize(size)
        stack.frame = NSRect(origin: .zero, size: size)
        addSubview(stack)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// Динамические цвета слоя пересчитываются под текущую тему.
    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DS.Palette.panel.cgColor
            layer?.borderColor = DS.Palette.line.cgColor
        }
    }

    func update(tool: Tool, color: NSColor) {
        for (candidate, button) in toolButtons {
            button.look = candidate == tool ? .active : .plain
        }
        colorButton?.image = Self.colorDot(color)
    }

    private func makeButton(symbol: String?, fallback: String, tip: String, label: String,
                            action: Selector) -> ToolbarButton {
        let button = ToolbarButton(title: fallback, target: self, action: action)
        if let symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
               .withSymbolConfiguration(.init(pointSize: 17, weight: .medium)) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.isBordered = false
        // Название — сразу при наведении (подсказка над панелью), без системной задержки.
        button.hint = tip
        button.onHover = { [weak self, weak button] inside in
            guard let self, let button else { return }
            inside ? self.showHint(tip, over: button) : self.hideHint()
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }

    // MARK: - Подсказка при наведении

    private var hintLabel: NSTextField?

    private func showHint(_ text: String, over button: NSView) {
        guard let host = superview else { return }
        let label = hintLabel ?? {
            let field = NSTextField(labelWithString: "")
            field.font = CaptureFont.manrope(12, .bold)
            field.textColor = DS.Palette.bg
            field.alignment = .center
            field.drawsBackground = true
            field.backgroundColor = DS.Palette.text
            field.wantsLayer = true
            field.layer?.cornerRadius = 8
            field.layer?.masksToBounds = true
            hintLabel = field
            return field
        }()
        label.stringValue = "  \(text)  "
        label.sizeToFit()
        let buttonFrame = host.convert(button.bounds, from: button)
        var origin = NSPoint(x: buttonFrame.midX - label.frame.width / 2, y: frame.maxY + 6)
        // У верхнего края экрана — под панелью.
        if origin.y + label.frame.height > host.bounds.maxY { origin.y = frame.minY - label.frame.height - 6 }
        origin.x = min(max(origin.x, host.bounds.minX + 4), host.bounds.maxX - label.frame.width - 4)
        label.setFrameOrigin(origin)
        if label.superview !== host { host.addSubview(label) }
        label.isHidden = false
    }

    private func hideHint() {
        hintLabel?.isHidden = true
    }

    override func removeFromSuperview() {
        hintLabel?.removeFromSuperview()
        super.removeFromSuperview()
    }

    private func separator() -> NSView {
        let line = SeparatorLine()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 13).isActive = true
        line.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return line
    }

    private static func colorDot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let rect = NSRect(x: 2, y: 2, width: 14, height: 14)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        DS.Palette.text.setStroke()
        let ring = NSBezierPath(ovalIn: rect)
        ring.lineWidth = 1.5
        ring.stroke()
        image.unlockFocus()
        return image
    }

    @objc private func toolPressed(_ sender: NSButton) {
        guard Tool.allCases.indices.contains(sender.tag) else { return }
        owner?.select(tool: Tool.allCases[sender.tag])
    }

    @objc private func colorPressed() { owner?.cycleColor() }
    @objc private func undoPressed() { owner?.undo() }
    @objc private func ocrPressed() { owner?.recognizeText() }
    @objc private func savePressed() { owner?.saveResult() }
    @objc private func copyPressed() { owner?.copyResult() }
    @objc private func closePressed() { owner?.closeCapture() }
    @objc private func scrollPressed() { owner?.startScrollCapture() }
    @objc private func stepPressed() { owner?.addStep() }
    @objc private func framePressed() { owner?.toggleFrame() }
    @objc private func recordPressed() { owner?.startRecording() }

    func update(framed: Bool) {
        frameButton?.look = framed ? .active : .plain
    }
}

/// Вертикальный разделитель групп кнопок: линия 1 pt `line` по центру.
private final class SeparatorLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DS.Palette.line.setFill()
        NSRect(x: bounds.midX - 0.5, y: bounds.midY - 14, width: 1, height: 28).fill()
    }
}

/// Кнопка срабатывает с первого клика, даже если окно оверлея не ключевое.
/// Вид: обычная — прозрачная, `text`; активная и главная — лайм (`acc`/`accInk`); запись — `field`, значок `rec`.
final class ToolbarButton: NSButton {
    enum Look { case plain, active, record, main }

    var hint = ""
    var onHover: ((Bool) -> Void)?
    var look = Look.plain {
        didSet { if look != oldValue { refresh() } }
    }
    private var hovered = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; onHover?(false) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        contentTintColor = switch look {
        case .plain: DS.Palette.text
        case .active, .main: DS.Palette.accInk
        case .record: DS.Palette.rec
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        refresh()
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        switch look {
        case .active, .main: DS.Palette.acc.setFill(); shape.fill()
        case .record: DS.Palette.field.setFill(); shape.fill()
        case .plain:
            if hovered { DS.Palette.field.setFill(); shape.fill() }
        }
        super.draw(dirtyRect)
    }
}

/// NSFont из шрифтов дизайн-системы (если не зарегистрированы — системный).
enum CaptureFont {
    static func manrope(_ size: CGFloat, _ weight: Font.Weight) -> NSFont {
        guard DSFonts.isAvailable(DSFonts.manrope), let font = NSFont(name: DSFonts.manropeName(weight), size: size) else {
            return .systemFont(ofSize: size, weight: NSFont.Weight(rawValue: weight == .heavy ? 0.56 : weight == .bold ? 0.4 : 0.3))
        }
        return font
    }

    static func mono(_ size: CGFloat) -> NSFont {
        guard DSFonts.isAvailable(DSFonts.jetBrainsMono), let font = NSFont(name: "JetBrainsMonoRoman-Medium", size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .medium)
        }
        return font
    }
}
