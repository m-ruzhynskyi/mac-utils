import AppKit
import SwiftUI

/// Короткое всплывающее уведомление вверху экрана.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var generation = 0

    /// Кнопка в уведомлении, например «Показать в Finder».
    struct Action {
        let title: String
        let handler: @MainActor () -> Void
    }

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: Color = .green,
                     action: Action? = nil) {
        generation += 1
        let token = generation
        panel?.orderOut(nil)

        // Кнопка сначала прячет уведомление (Toast.panel — не локальная панель ниже).
        let wrapped: Action? = action.map { action in
            Action(title: action.title) {
                Toast.panel?.orderOut(nil)
                action.handler()
            }
        }
        let host = FirstMouseHostingView(rootView: ToastView(text: text, symbol: symbol, tint: tint, action: wrapped))
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
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String
    let tint: Color
    let action: Toast.Action?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 13, weight: .medium))
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
