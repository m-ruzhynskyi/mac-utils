import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// «Окна»: раскладка окон как в Windows. Окно, перетащенное к краю экрана,
/// встаёт на половину, к углу — на четверть, к верхнему краю — на весь экран.
/// То же — горячими клавишами (по умолчанию ⌃⌥ + стрелки / U I J K / Enter / C / ⌫).
@MainActor
final class WindowTiler: ObservableObject {
    static let shared = WindowTiler()

    @Published private(set) var isRunning = false
    /// Сочетания, которые не удалось зарегистрировать (заняты).
    @Published private(set) var failedHotKeys: [String] = []

    enum Target: Equatable {
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
        case maximize, center
    }

    private var tap: EventTap?
    /// Сочетания ловим своим перехватом клавиш: в новых macOS Carbon перестал отдавать ⌃⌥ + стрелки.
    private var keyTap: EventTap?
    private let preview = SnapPreview()
    /// Прежние рамки окон (в координатах AX) для «вернуть размер».
    private var restoreFrames: [CGWindowID: CGRect] = [:]

    // Перетаскивание.
    private var dragWindow: AXUIElement?
    private var dragStartFrame: CGRect?
    private var dragMoving = false
    private var dragTarget: Target?
    private var dragScreen: NSScreen?
    private var lastProbe: TimeInterval = 0

    private init() {}

    // MARK: - Включение

    func sync() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Pref.windowSnap) && Permissions.accessibility
        let wantsDrag = enabled && defaults.bool(forKey: Pref.windowSnapDrag)

        if wantsDrag {
            if tap == nil {
                tap = EventTap(types: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] type, event in
                    self?.handleMouse(type: type, event: event)
                    return true
                }
            }
            if tap?.start() != true { Log.window.error("Окна: не удалось создать перехват мыши") }
        } else {
            tap?.stop()
            tap = nil
            endDrag()
        }

        registerHotKeys(enabled: enabled)
        isRunning = enabled && (!wantsDrag || tap?.isRunning == true)
    }

    private func registerHotKeys(enabled: Bool) {
        // Прежние регистрации Carbon (до этой версии) снимаем.
        for index in Self.bindings.indices {
            HotKeyCenter.shared.unregister(id: HotKeyID.windowSnapBase + UInt32(index))
        }
        guard enabled else {
            keyTap?.stop()
            keyTap = nil
            failedHotKeys = []
            return
        }
        if keyTap == nil {
            keyTap = EventTap(types: [.keyDown]) { _, event in
                WindowTiler.shared.handleKey(event)
            }
        }
        failedHotKeys = keyTap?.start() == true ? [] : Self.bindings.map { WindowSnapModifier.current.symbols + $0.label }
    }

    /// true — пропустить клавишу дальше, false — это наше сочетание, поглощаем.
    private func handleKey(_ event: CGEvent) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard event.flags.intersection(relevant) == WindowSnapModifier.current.flags else { return true }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard let binding = Self.bindings.first(where: { $0.keyCode == code }) else { return true }
        // Автоповтор при удержании не переносит окно по мониторам.
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { perform(binding.action) }
        return false
    }

    enum Action {
        case snap(Target)
        case restore
    }

    struct Binding {
        let keyCode: Int
        let label: String
        let title: String
        let action: Action
    }

    static let bindings: [Binding] = [
        Binding(keyCode: kVK_LeftArrow, label: "←", title: "Левая половина", action: .snap(.left)),
        Binding(keyCode: kVK_RightArrow, label: "→", title: "Правая половина", action: .snap(.right)),
        Binding(keyCode: kVK_UpArrow, label: "↑", title: "Верхняя половина", action: .snap(.top)),
        Binding(keyCode: kVK_DownArrow, label: "↓", title: "Нижняя половина", action: .snap(.bottom)),
        Binding(keyCode: kVK_ANSI_U, label: "U", title: "Левая верхняя четверть", action: .snap(.topLeft)),
        Binding(keyCode: kVK_ANSI_I, label: "I", title: "Правая верхняя четверть", action: .snap(.topRight)),
        Binding(keyCode: kVK_ANSI_J, label: "J", title: "Левая нижняя четверть", action: .snap(.bottomLeft)),
        Binding(keyCode: kVK_ANSI_K, label: "K", title: "Правая нижняя четверть", action: .snap(.bottomRight)),
        Binding(keyCode: kVK_Return, label: "↩", title: "На весь экран", action: .snap(.maximize)),
        Binding(keyCode: kVK_ANSI_C, label: "C", title: "По центру", action: .snap(.center)),
        Binding(keyCode: kVK_Delete, label: "⌫", title: "Вернуть прежний размер", action: .restore),
    ]

    // MARK: - Горячие клавиши

    func perform(_ action: Action) {
        guard let window = Self.focusedWindow(), let frame = Self.frame(of: window) else {
            Log.window.info("Окна: нет активного окна")
            return
        }
        switch action {
        case .restore:
            guard let id = AXWindowID.of(window), let previous = restoreFrames.removeValue(forKey: id) else { return }
            Self.setFrame(previous, of: window)
        case .snap(let target):
            var screen = Self.screen(containing: frame)
            var targetFrame = Self.frame(for: target, on: screen, window: frame)
            // Повтор той же половины — на следующий монитор.
            if target != .center, Self.isClose(frame, targetFrame), NSScreen.screens.count > 1,
               let index = NSScreen.screens.firstIndex(of: screen) {
                screen = NSScreen.screens[(index + 1) % NSScreen.screens.count]
                targetFrame = Self.frame(for: target, on: screen, window: frame)
            }
            remember(frame, of: window)
            Self.setFrame(targetFrame, of: window)
        }
    }

    private func remember(_ frame: CGRect, of window: AXUIElement) {
        guard let id = AXWindowID.of(window) else { return }
        // Помним размер «до раскладки», а не промежуточные половины.
        if restoreFrames[id] == nil || !Self.isSnapped(frame) { restoreFrames[id] = frame }
    }

    // MARK: - Перетаскивание

    private func handleMouse(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            endDrag()
            let point = event.location
            guard let window = Self.window(at: point), let frame = Self.frame(of: window) else { return }
            // Только за заголовок: верхняя полоса окна.
            guard point.y - frame.minY < 40 else { return }
            dragWindow = window
            dragStartFrame = frame

        case .leftMouseDragged:
            guard let window = dragWindow, let start = dragStartFrame else { return }
            if !dragMoving {
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastProbe > 0.05 else { return }
                lastProbe = now
                // Окно двигается, а размер прежний — значит, его тащат за заголовок.
                guard let frame = Self.frame(of: window), frame.origin != start.origin,
                      abs(frame.width - start.width) < 1, abs(frame.height - start.height) < 1 else { return }
                dragMoving = true
            }
            updateDragTarget()

        case .leftMouseUp:
            if dragMoving, let window = dragWindow, let target = dragTarget, let screen = dragScreen,
               let start = dragStartFrame {
                remember(start, of: window)
                let frame = Self.frame(for: target, on: screen, window: start)
                // Даём системе закончить перетаскивание, затем ставим рамку.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    Self.setFrame(frame, of: window)
                }
            }
            endDrag()

        default:
            break
        }
    }

    private func updateDragTarget() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        let target = Self.zone(for: mouse, in: screen.frame)
        guard target != dragTarget || screen != dragScreen else { return }
        dragTarget = target
        dragScreen = screen
        if let target, let start = dragStartFrame {
            preview.show(Self.cocoaRect(fromAX: Self.frame(for: target, on: screen, window: start)))
        } else {
            preview.hide()
        }
    }

    private func endDrag() {
        dragWindow = nil
        dragStartFrame = nil
        dragMoving = false
        dragTarget = nil
        dragScreen = nil
        preview.hide()
    }

    /// Зона у края экрана: углы — четверти, бока — половины, верх — весь экран.
    private static func zone(for p: NSPoint, in frame: NSRect) -> Target? {
        let edge: CGFloat = 6, corner: CGFloat = 60
        let left = p.x <= frame.minX + edge, right = p.x >= frame.maxX - edge - 1
        let top = p.y >= frame.maxY - edge - 1, bottom = p.y <= frame.minY + edge
        let nearLeft = p.x <= frame.minX + corner, nearRight = p.x >= frame.maxX - corner
        let nearTop = p.y >= frame.maxY - corner, nearBottom = p.y <= frame.minY + corner
        if (left && nearTop) || (top && nearLeft) { return .topLeft }
        if (right && nearTop) || (top && nearRight) { return .topRight }
        if (left && nearBottom) || (bottom && nearLeft) { return .bottomLeft }
        if (right && nearBottom) || (bottom && nearRight) { return .bottomRight }
        if left { return .left }
        if right { return .right }
        if top { return .maximize }
        return nil
    }

    // MARK: - Геометрия (координаты AX: от левого верхнего угла основного экрана)

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoaRect(fromAX r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func axRect(fromCocoa r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    private static func screen(containing frame: CGRect) -> NSScreen {
        let cocoa = cocoaRect(fromAX: frame)
        return NSScreen.screens.max {
            $0.frame.intersection(cocoa).width * $0.frame.intersection(cocoa).height
                < $1.frame.intersection(cocoa).width * $1.frame.intersection(cocoa).height
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Рамка цели в координатах AX с учётом отступа между окнами.
    static func frame(for target: Target, on screen: NSScreen, window: CGRect) -> CGRect {
        let gap = CGFloat(UserDefaults.standard.integer(forKey: Pref.windowSnapGap))
        let area = screen.visibleFrame.insetBy(dx: gap / 2, dy: gap / 2)
        let halfW = area.width / 2, halfH = area.height / 2
        var r: NSRect
        switch target {
        case .left: r = NSRect(x: area.minX, y: area.minY, width: halfW, height: area.height)
        case .right: r = NSRect(x: area.midX, y: area.minY, width: halfW, height: area.height)
        case .top: r = NSRect(x: area.minX, y: area.midY, width: area.width, height: halfH)
        case .bottom: r = NSRect(x: area.minX, y: area.minY, width: area.width, height: halfH)
        case .topLeft: r = NSRect(x: area.minX, y: area.midY, width: halfW, height: halfH)
        case .topRight: r = NSRect(x: area.midX, y: area.midY, width: halfW, height: halfH)
        case .bottomLeft: r = NSRect(x: area.minX, y: area.minY, width: halfW, height: halfH)
        case .bottomRight: r = NSRect(x: area.midX, y: area.minY, width: halfW, height: halfH)
        case .maximize: r = area
        case .center:
            let visible = screen.visibleFrame
            let w = min(window.width, visible.width), h = min(window.height, visible.height)
            return axRect(fromCocoa: NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h))
        }
        return axRect(fromCocoa: r.insetBy(dx: gap / 2, dy: gap / 2))
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 8 && abs(a.minY - b.minY) < 8 && abs(a.width - b.width) < 16 && abs(a.height - b.height) < 16
    }

    /// Окно уже стоит в одной из раскладок на своём экране.
    private static func isSnapped(_ frame: CGRect) -> Bool {
        let screen = screen(containing: frame)
        let targets: [Target] = [.left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight, .maximize]
        return targets.contains { isClose(frame, self.frame(for: $0, on: screen, window: frame)) }
    }

    // MARK: - Accessibility

    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Окно под точкой (координаты CG/AX), не наше и не рабочий стол.
    private static func window(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        if role(of: element) == kAXWindowRole as String { return standard(element) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return standard(value as! AXUIElement)
    }

    private static func standard(_ window: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value)
        return (value as? String) == kAXStandardWindowSubrole as String ? window : nil
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// Позиция, размер и ещё раз позиция: при переезде на другой монитор
    /// система может подрезать размер по старому экрану.
    static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var origin = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }
}

/// Модификатор для горячих клавиш окон.
enum WindowSnapModifier: String, CaseIterable, Identifiable {
    case controlOption, controlCommand, optionCommand

    var id: String { rawValue }

    var symbols: String {
        switch self {
        case .controlOption: return "⌃⌥"
        case .controlCommand: return "⌃⌘"
        case .optionCommand: return "⌥⌘"
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .controlOption: return [.maskControl, .maskAlternate]
        case .controlCommand: return [.maskControl, .maskCommand]
        case .optionCommand: return [.maskAlternate, .maskCommand]
        }
    }

    var carbon: Int {
        switch self {
        case .controlOption: return controlKey | optionKey
        case .controlCommand: return controlKey | cmdKey
        case .optionCommand: return optionKey | cmdKey
        }
    }

    static var current: WindowSnapModifier {
        WindowSnapModifier(rawValue: UserDefaults.standard.string(forKey: Pref.windowSnapModifier) ?? "") ?? .controlOption
    }
}

/// Полупрозрачная подсказка, куда встанет окно.
@MainActor
private final class SnapPreview {
    private var panel: NSPanel?

    func show(_ frame: NSRect) {
        let panel = self.panel ?? make()
        panel.setFrame(frame.insetBy(dx: 4, dy: 4), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)))
        self.panel = panel
        return panel
    }
}
