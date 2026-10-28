import AppKit
import SwiftUI
import MUCore

/// Короткое всплывающее уведомление вверху экрана.
@MainActor
package enum Toast {
    private static var panel: NSPanel?
    private static var generation = 0
    private static var model: ToastModel?

    /// Убрать уведомление. Без `token` — какое висит сейчас (как раньше); с `token` (его вернул `show`) — только своё:
    /// если его уже заменили другим, чужое уведомление остаётся.
    package static func dismiss(token: Int? = nil) {
        if let token, token != generation { return }
        generation += 1
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    /// Сменить текст висящего уведомления (прогресс «Создаю GIF… 40 %»), не пересоздавая панель.
    /// Действует только на уведомление с этим `token`: если его заменили другим или убрали — ничего не делает.
    package static func updateText(_ text: String, token: Int) {
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
    package static func text(of token: Int) -> String? { token == generation ? model?.text : nil }
    package static func panelWidth(of token: Int) -> CGFloat? { token == generation ? panel?.frame.width : nil }
    package static func fittingWidth(of token: Int) -> CGFloat? { token == generation ? panel?.contentView?.fittingSize.width : nil }

    /// Кнопка в уведомлении, например «Показать в Finder».
    package struct Action {
        package let title: String
        package let handler: @MainActor () -> Void

        package init(title: String, handler: @escaping @MainActor () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    /// `sticky` — уведомление висит, пока его не заменят или не вызовут `dismiss()` (долгая операция с кнопкой «Отмена»).
    /// Возвращает номер уведомления: по нему можно обновить или убрать именно его.
    @discardableResult
    package static func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: Color = .green,
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
        panel.orderFrontRegardlessOnScreen()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel
        // VoiceOver: уведомление объявляется, а не просто появляется.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
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
    @Published package var text: String
    package init(text: String) { self.text = text }
}

private struct ToastView: View {
    @ObservedObject package var model: ToastModel
    package let symbol: String
    package let tint: Color
    package let action: Toast.Action?

    package var body: some View {
        ToastCard(text: model.text, symbol: symbol, tint: tint, actionTitle: action?.title, action: action?.handler)
    }
}

/// Карточка уведомления Graphite (как «Скопировано» в `Capture.dc.html`): плитка со значком тона, текст 13/700,
/// при наличии — кнопка. Внутренняя, без модели: так её можно снять для проверки вида.
package struct ToastCard: View {
    package let text: String
    package let symbol: String
    package let tint: Color
    package var actionTitle: String?
    package var action: (@MainActor () -> Void)?

    /// Лайм для ИИ-уведомлений (фиолетовый в Graphite не используется), остальное — по цвету вызова.
    private var tone: DS.Tone { tint == .purple ? .success : DS.Tone.from(tint: tint) }

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        HStack(spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.ink)
                .frame(width: 30, height: 30)
                .background(tone.fill, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.manrope(13, .bold, relativeTo: .callout))
                .foregroundStyle(.dsText)
                .monospacedDigit()
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle) { action() }.buttonStyle(.graphite(.primary, size: .compact))
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, actionTitle == nil ? 16 : 10)
        .background(Color.dsPanel, in: shape)
        .overlay(shape.strokeBorder(Color.dsLine, lineWidth: 1))
        .padding(4)
        .accessibilityElement(children: .contain)
    }
}

@MainActor
extension NSScreen {
    /// Экран, на котором сейчас курсор.
    package static var withMouse: NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
