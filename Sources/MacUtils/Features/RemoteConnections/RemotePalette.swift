import AppKit
import MURemoteConnections
import SwiftUI

/// Палитра ⌥⌘A: как Spotlight — набрал, Enter. Плавающая панель по центру экрана с курсором,
/// не активирует Mac Utils (фокус возвращается в прежнюю программу), закрывается по Esc и при потере фокуса.
@MainActor
final class RemotePaletteController: NSObject, NSWindowDelegate {
    static let shared = RemotePaletteController()

    private var panel: PalettePanel?
    private var monitor: Any?
    private let model = RemoteListModel()
    static let width: CGFloat = 640
    /// Палитра показана снова — поле поиска забирает фокус.
    static let didShow = Notification.Name("MacUtils.remotePaletteDidShow")

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : show() }

    func show() {
        RemoteConnectionsCenter.shared.start()
        model.query = ""
        model.filter = .all
        model.selection = 0
        let panel = self.panel ?? make()
        if let screen = NSScreen.withMouse ?? NSScreen.main {
            let frame = screen.visibleFrame
            let height: CGFloat = 470
            panel.setFrame(NSRect(x: frame.midX - Self.width / 2 - 20, y: frame.maxY - height - frame.height * 0.16,
                                  width: Self.width + 40, height: height), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        installMonitor()
        NotificationCenter.default.post(name: Self.didShow, object: nil)
    }

    func close() {
        removeMonitor()
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func make() -> PalettePanel {
        let host = NSHostingView(rootView: RemotePaletteView(model: model, close: { [weak self] in self?.close() }))
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width + 40, height: 470),
                                 styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// Клавиши палитры ловим до поля ввода: стрелки, Enter, Tab и Esc поле съело бы само.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case 125: model.move(1); return true                                // ↓
        case 126: model.move(-1); return true                               // ↑
        case 36, 76:                                                        // ↩, ⌘↩ — без пароля
            // Сначала закрыть: палитра не должна держать фокус, когда программа выходит вперёд.
            let withPassword = !flags.contains(.command)
            guard model.selectedRow(in: model.listing) != nil else { return true }
            close()
            model.connectSelected(withPassword: withPassword)
            return true
        case 48: model.cycleFilter(); return true                           // ⇥
        case 53: close(); return true                                       // ⎋
        case 3 where flags == .command: model.toggleFavoriteSelected(); return true // ⌘F
        default: return false
        }
    }
}

/// Панель без заголовка, которая всё же принимает ввод с клавиатуры.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct RemotePaletteView: View {
    @ObservedObject var model: RemoteListModel
    @ObservedObject private var center: RemoteConnectionsCenter
    let close: () -> Void
    @FocusState private var focused: Bool

    init(model: RemoteListModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _center = ObservedObject(wrappedValue: model.center)
    }

    private func hint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 6) {
            Keycap(keys, compact: true, onPanel: true)
            Text(text).font(DS.Font.rowSub).foregroundStyle(.dsMute)
        }
    }

    private var programPill: String? {
        if case .program(let p) = model.filter { return p.title }
        return nil
    }

    var body: some View {
        let listing = model.listing
        VStack(spacing: DS.Space.s) {
            RemoteSearchField(text: $model.query, placeholder: "Подключиться к…", large: true, hint: listing.hint,
                              programPill: programPill, focused: $focused, trailingKeys: ["⎋"],
                              onClearProgram: { model.filter = .all })
            Group {
                if center.state != .ready {
                    RemoteFileStateView(center: center)
                } else if listing.isEmpty {
                    EmptyState("Ничего не найдено", systemImage: "magnifyingglass",
                               message: "Поиск идёт по названию, ID, группе, тегам и заметке. Проверьте написание — раскладка уже учтена.",
                               compact: true)
                } else {
                    RemoteSectionsList(model: model, center: center, listing: listing,
                                       showSectionLabels: listing.effectiveQuery.isEmpty)
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                hint(["↑", "↓"], "выбор")
                hint(["↩"], "подключиться")
                hint(["⌘", "↩"], "без пароля")
                hint(["⇥"], "программа")
                hint(["⌘", "F"], "избранное")
                Spacer()
            }
            .padding(.horizontal, 6)
        }
        .floating(.panel)
        .frame(width: RemotePaletteController.width)
        .padding(20)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: RemotePaletteController.didShow)) { _ in focused = true }
        .onChange(of: model.query) { _, _ in focused = true }
    }
}
