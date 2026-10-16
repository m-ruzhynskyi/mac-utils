import AppKit
import SwiftUI

/// Короткое всплывающее уведомление вверху экрана.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var generation = 0
    private static var model: ToastModel?

    /// Убрать уведомление. Без `token` — какое висит сейчас (как раньше); с `token` (его вернул `show`) — только своё:
    /// если его уже заменили другим, чужое уведомление остаётся.
    static func dismiss(token: Int? = nil) {
        if let token, token != generation { return }
        generation += 1
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    /// Сменить текст висящего уведомления (прогресс «Создаю GIF… 40 %»), не пересоздавая панель.
    /// Действует только на уведомление с этим `token`: если его заменили другим или убрали — ничего не делает.
    static func updateText(_ text: String, token: Int) {
        guard token == generation, let model else { return }
        model.text = text
        // SwiftUI пересчитывает вид на следующем проходе цикла: размер подгоняем после него, иначе панель отстаёт на шаг.
        DispatchQueue.main.async { fitPanel(token: token) }
    }

    private static func fitPanel(token: Int) {
        guard token == generation, let panel, let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let old = panel.frame
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height),
                       display: true)
    }

    /// Для тестов: текст и ширина панели уведомления с этим номером (nil — его уже нет).
    static func text(of token: Int) -> String? { token == generation ? model?.text : nil }
    static func panelWidth(of token: Int) -> CGFloat? { token == generation ? panel?.frame.width : nil }
    static func fittingWidth(of token: Int) -> CGFloat? { token == generation ? panel?.contentView?.fittingSize.width : nil }

    /// Кнопка в уведомлении, например «Показать в Finder».
    struct Action {
        let title: String
        let handler: @MainActor () -> Void
    }

    /// `sticky` — уведомление висит, пока его не заменят или не вызовут `dismiss()` (долгая операция с кнопкой «Отмена»).
    /// Возвращает номер уведомления: по нему можно обновить или убрать именно его.
    @discardableResult
    static func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: Color = .green,
                     action: Action? = nil, sticky: Bool = false) -> Int {
        generation += 1
        let token = generation
        panel?.orderOut(nil)

        // Кнопка сначала прячет уведомление (Toast.panel — не локальная панель ниже).
        let wrapped: Action? = action.map { action in
            Action(title: action.title) {
                if token == Toast.generation { Toast.panel?.orderOut(nil) }
                action.handler()
            }
        }
        let model = ToastModel(text: text)
        self.model = model
        let host = FirstMouseHostingView(rootView: ToastView(model: model, symbol: symbol, tint: tint, action: wrapped))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = action == nil
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host

        let screen = NSScreen.withMouse ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                         y: frame.maxY - size.height - 40))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel
        if sticky { return token }

        Task { @MainActor in
            // С кнопкой уведомление висит дольше: на неё нужно успеть нажать.
            try? await Task.sleep(nanoseconds: action == nil ? 1_800_000_000 : 5_000_000_000)
            guard token == generation else { return }
            // Без runAnimationGroup: в async-контексте Swift выбирает его async-перегрузку.
            panel.animator().alphaValue = 0
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard token == generation else { return }
            panel.orderOut(nil)
        }
        return token
    }
}

@MainActor
private final class ToastModel: ObservableObject {
    @Published var text: String
    init(text: String) { self.text = text }
}

private struct ToastView: View {
    @ObservedObject var model: ToastModel
    let symbol: String
    let tint: Color
    let action: Toast.Action?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(model.text).font(.system(size: 13, weight: .medium)).monospacedDigit()
            if let action {
                Button(action.title) { action.handler() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(4)
    }
}

@MainActor
extension NSScreen {
    /// Экран, на котором сейчас курсор.
    static var withMouse: NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
