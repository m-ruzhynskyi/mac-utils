// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// «Коллаж шагов»: несколько снимков подряд (кнопка «Шаг +» или клавиша A)
/// складываются в одну картинку с большими номерами 1, 2, 3.
@MainActor
final class StepsSession: ObservableObject {
    private(set) static var current: StepsSession?

    @Published private(set) var images: [CGImage] = []
    /// Пикселей в точке у снятых шагов (2 на Retina).
    private var unit: CGFloat = 1
    private var hudPanel: NSPanel?

    /// Добавляет шаг; первая же картинка начинает сессию.
    static func add(_ image: CGImage, unit: CGFloat) {
        let session = current ?? StepsSession()
        current = session
        session.images.append(image)
        session.unit = max(session.unit, unit)
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
        let defaults = UserDefaults.standard
        var options = ShotComposer.Options()
        options.layout = StepsLayout(rawValue: defaults.string(forKey: Pref.screenshotStepsLayout) ?? "") ?? .auto
        options.equalSize = defaults.bool(forKey: Pref.screenshotStepsEqualSize)
        options.windowFrame = defaults.bool(forKey: Pref.screenshotStepsFrame)
        options.titles = defaults.bool(forKey: Pref.screenshotStepsTitles)
        options.badges = true
        options.background = .current
        options.unit = unit
        options.dark = ShotComposer.systemIsDark
        let images = self.images
        end()
        guard let collage = ShotComposer.compose(images, options: options) else {
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
    case auto, vertical, horizontal, grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто (ближе к квадрату)"
        case .vertical: return "Столбиком"
        case .horizontal: return "В ряд"
        case .grid: return "Сеткой (квадратом)"
        }
    }
}
