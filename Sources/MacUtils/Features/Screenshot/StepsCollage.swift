import AppKit
import SwiftUI

/// «Коллаж шагов»: несколько снимков подряд (кнопка «Шаг +» или клавиша A)
/// складываются в одну картинку с большими номерами 1, 2, 3.
@MainActor
final class StepsSession: ObservableObject {
    private(set) static var current: StepsSession?

    @Published private(set) var images: [CGImage] = []
    /// Когда добавлен последний шаг (забытая сессия не должна вечно считаться «занятостью»).
    private(set) var lastActivity = Date()
    /// Пикселей в точке у снятых шагов (2 на Retina).
    private var unit: CGFloat = 1
    private var hudPanel: NSPanel?

    /// Добавляет шаг; первая же картинка начинает сессию.
    static func add(_ image: CGImage, unit: CGFloat) {
        let session = current ?? StepsSession()
        current = session
        session.images.append(image)
        session.lastActivity = Date()
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
        StepsHUDContent(count: session.images.count, cancel: { session.cancel() }, next: { session.nextStep() },
                        finish: { session.finish() })
    }
}

/// Панель коллажа шагов: плитка, «Коллаж шагов», счётчик, «Отмена / Ещё шаг / Готово». Значения готовые, без модели.
struct StepsHUDContent: View {
    let count: Int
    let cancel: () -> Void
    let next: () -> Void
    let finish: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.dsText)
                .frame(width: DS.Size.rowTile, height: DS.Size.rowTile)
                .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Коллаж шагов").font(DS.Font.manrope(13, .heavy, relativeTo: .callout)).foregroundStyle(.dsText)
                Text("Шагов: \(count)").font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute)
            }
            Button("Отмена", action: cancel).buttonStyle(.graphite(.ghost, size: .compact))
            Button("Ещё шаг", action: next).buttonStyle(.graphite(.secondary, size: .compact)).help("⌘⇧X")
            Button("Готово", action: finish).buttonStyle(.graphite(.primary, size: .compact))
        }
        .floating(.panel)
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
