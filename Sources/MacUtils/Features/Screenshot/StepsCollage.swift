// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// «Коллаж шагов»: несколько снимков подряд (кнопка «Шаг +» или клавиша A)
/// складываются в одну картинку с большими номерами 1, 2, 3.
@MainActor
final class StepsSession: ObservableObject {
    private(set) static var current: StepsSession?

    @Published private(set) var images: [CGImage] = []
    private var hudPanel: NSPanel?

    /// Добавляет шаг; первая же картинка начинает сессию.
    static func add(_ image: CGImage) {
        let session = current ?? StepsSession()
        current = session
        session.images.append(image)
        Log.capture.info("Коллаж: шаг \(session.images.count)")
    }

    // MARK: - HUD

    /// HUD прячется на время снимка, чтобы не попасть в кадр.
    static func hideHUD() {
        current?.hudPanel?.orderOut(nil)
    }

    static func showHUD() {
        guard let session = current else { return }
        if session.hudPanel == nil { session.makeHUD() }
        session.hudPanel?.orderFrontRegardless()
    }

    private func makeHUD() {
        let host = FirstMouseHostingView(rootView: StepsHUD(session: self))
        let size = host.fittingSize
        let panel = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        if let visible = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
        }
        hudPanel = panel
    }

    // MARK: - Действия

    func nextStep() {
        ScreenshotService.shared.start(.edit)
    }

    func finish() {
        let layout = StepsLayout(rawValue: UserDefaults.standard.string(forKey: Pref.screenshotStepsLayout) ?? "")
            ?? .vertical
        let images = self.images
        end()
        guard let collage = StepsComposer.compose(images, layout: layout) else {
            Toast.show("Не удалось собрать коллаж", symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        Log.capture.info("Коллаж: \(images.count) шагов, \(collage.width)×\(collage.height)")
        ScreenshotService.shared.deliver(collage)
    }

    func cancel() {
        end()
        Toast.show("Коллаж отменён", symbol: "xmark.circle.fill", tint: .secondary)
    }

    private func end() {
        hudPanel?.orderOut(nil)
        hudPanel = nil
        if Self.current === self { Self.current = nil }
    }
}

private struct StepsHUD: View {
    @ObservedObject var session: StepsSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.down.right")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Коллаж шагов")
                    .font(.system(size: 12, weight: .semibold))
                Text("Шагов: \(session.images.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Отмена") { session.cancel() }
            Button("Ещё шаг") { session.nextStep() }
                .help("⌘⇧X")
            Button("Готово") { session.finish() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(4)
    }
}

// MARK: - Сборка

enum StepsLayout: String, CaseIterable, Identifiable {
    case vertical, horizontal, grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vertical: return "Столбиком"
        case .horizontal: return "В ряд"
        case .grid: return "Сеткой в 2 колонки"
        }
    }
}

@MainActor
enum StepsComposer {
    /// Складывает шаги на белом фоне с отступами и номерами в левом верхнем углу.
    /// Все размеры — в пикселях исходных снимков (на Retina — уже ×2).
    static func compose(_ images: [CGImage], layout: StepsLayout) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let maxSide = images.map { max($0.width, $0.height) }.max() ?? 0
        let unit = CGFloat(max(1, min(3, maxSide / 900 + 1)))     // ~1× для мелких, до 3×
        let gap = 32 * unit
        let columns: Int
        switch layout {
        case .vertical: columns = 1
        case .horizontal: columns = images.count
        case .grid: columns = min(2, images.count)
        }
        let rows = (images.count + columns - 1) / columns

        // Ширина колонок и высота рядов — по самому большому снимку в них.
        var columnWidths = [CGFloat](repeating: 0, count: columns)
        var rowHeights = [CGFloat](repeating: 0, count: rows)
        for (index, image) in images.enumerated() {
            columnWidths[index % columns] = max(columnWidths[index % columns], CGFloat(image.width))
            rowHeights[index / columns] = max(rowHeights[index / columns], CGFloat(image.height))
        }
        let width = columnWidths.reduce(0, +) + gap * CGFloat(columns + 1)
        let height = rowHeights.reduce(0, +) + gap * CGFloat(rows + 1)
        guard width < 32_000, height < 32_000,
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        var top = height - gap
        for row in 0..<rows {
            var left = gap
            for column in 0..<columns {
                let index = row * columns + column
                guard index < images.count else { break }
                let image = images[index]
                let w = CGFloat(image.width), h = CGFloat(image.height)
                // Внутри ячейки — по центру по горизонтали, прижато к верху.
                let rect = CGRect(x: left + (columnWidths[column] - w) / 2, y: top - h, width: w, height: h)

                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -2 * unit), blur: 10 * unit,
                                  color: CGColor(gray: 0, alpha: 0.25))
                context.draw(image, in: rect)
                context.restoreGState()
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
                context.setLineWidth(unit)
                context.stroke(rect.insetBy(dx: -unit / 2, dy: -unit / 2))

                drawBadge(index + 1, in: rect, unit: unit)
                left += columnWidths[column] + gap
            }
            top -= rowHeights[row] + gap
        }

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Номер шага в стиле инструмента «Нумерация», крупнее.
    private static func drawBadge(_ number: Int, in rect: CGRect, unit: CGFloat) {
        let base = min(rect.width, rect.height)
        let radius = min(max(base * 0.07, 20 * unit), 40 * unit)
        let center = NSPoint(x: rect.minX + radius + 10 * unit, y: rect.maxY - radius - 10 * unit)
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                 width: radius * 2, height: radius * 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -unit)
        shadow.shadowBlurRadius = 4 * unit
        shadow.set()
        NSColor.systemRed.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        circle.lineWidth = 3 * unit
        NSColor.white.setStroke()
        circle.stroke()

        let label = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: radius * (number > 9 ? 0.9 : 1.15), weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}
