// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Панель инструментов под выделенной областью.
@MainActor
final class CaptureToolbar: NSVisualEffectView {
    private weak var owner: CaptureView?
    private var toolButtons: [Tool: NSButton] = [:]
    private var colorButton: NSButton?

    init(owner: CaptureView) {
        self.owner = owner
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)

        for (index, tool) in Tool.allCases.enumerated() {
            let button = makeButton(symbol: tool.symbol, fallback: String(tool.title.prefix(1)), tip: tool.title,
                                    action: #selector(toolPressed(_:)))
            button.tag = index
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())

        let color = makeButton(symbol: nil, fallback: "●", tip: "Цвет", action: #selector(colorPressed))
        colorButton = color
        stack.addArrangedSubview(color)
        stack.addArrangedSubview(makeButton(symbol: "arrow.uturn.backward", fallback: "↶",
                                            tip: "Отменить (⌘Z)", action: #selector(undoPressed)))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(makeButton(symbol: "scroll", fallback: "⇕",
                                            tip: "Длинный снимок с прокруткой", action: #selector(scrollPressed)))
        stack.addArrangedSubview(makeButton(symbol: "text.viewfinder", fallback: "OCR",
                                            tip: "Распознать текст", action: #selector(ocrPressed)))
        stack.addArrangedSubview(makeButton(symbol: "square.and.arrow.down", fallback: "S",
                                            tip: "Сохранить (⌘S)", action: #selector(savePressed)))
        stack.addArrangedSubview(makeButton(symbol: "doc.on.doc", fallback: "C",
                                            tip: "Скопировать (⌘C, Enter, двойной клик)", action: #selector(copyPressed)))
        stack.addArrangedSubview(makeButton(symbol: "xmark", fallback: "×",
                                            tip: "Закрыть (Esc)", action: #selector(closePressed)))

        let size = stack.fittingSize
        setFrameSize(size)
        stack.frame = NSRect(origin: .zero, size: size)
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(tool: Tool, color: NSColor) {
        for (candidate, button) in toolButtons {
            button.contentTintColor = candidate == tool ? .systemBlue : .white
        }
        colorButton?.image = Self.colorDot(color)
    }

    private func makeButton(symbol: String?, fallback: String, tip: String, action: Selector) -> NSButton {
        let button = ToolbarButton(title: fallback, target: self, action: action)
        if let symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
               .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }

    private static func colorDot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let rect = NSRect(x: 2, y: 2, width: 14, height: 14)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
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
}

/// Кнопка срабатывает с первого клика, даже если окно оверлея не ключевое.
private final class ToolbarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
