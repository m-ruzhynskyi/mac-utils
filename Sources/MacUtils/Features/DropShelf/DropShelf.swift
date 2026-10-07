import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// Встряхивание мышью: несколько резких смен направления по горизонтали за короткое время.
struct ShakeDetector {
    var window: TimeInterval = 0.6
    var minimumStroke: CGFloat = 25
    var reversalsNeeded = 4

    private var lastX: CGFloat?
    private var direction = 0
    private var strokeStart: CGFloat = 0
    private var reversals: [TimeInterval] = []

    /// Новая точка; true — это встряхивание.
    mutating func add(x: CGFloat, time: TimeInterval) -> Bool {
        defer { lastX = x }
        guard let lastX else {
            strokeStart = x
            return false
        }
        let step = x - lastX
        guard abs(step) > 0.5 else { return false }
        let newDirection = step > 0 ? 1 : -1
        if newDirection != direction {
            // Засчитываем смену направления, только если прошлый «мах» был достаточно длинным.
            if direction != 0, abs(lastX - strokeStart) >= minimumStroke {
                reversals.append(time)
            }
            direction = newDirection
            strokeStart = lastX
        }
        reversals.removeAll { time - $0 > window }
        if reversals.count >= reversalsNeeded {
            reset()
            return true
        }
        return false
    }

    mutating func reset() {
        lastX = nil
        direction = 0
        reversals.removeAll()
    }
}

/// «Полка»: временное место для файлов. Встряхните мышь, перетаскивая файлы
/// (или ⌃⌥D), бросьте их на полку, перейдите в нужное место и вытащите обратно.
@MainActor
final class DropShelf: ObservableObject {
    static let shared = DropShelf()

    @Published private(set) var items: [URL] = []
    @Published private(set) var isRunning = false

    private var panel: NSPanel?
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var shake = ShakeDetector()

    func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.dropShelf)
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.dropShelf)
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        dragMonitor = nil
        upMonitor = nil
        guard enabled else {
            hide()
            isRunning = false
            return
        }
        center.register(id: HotKeyID.dropShelf, keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey) {
            DropShelf.shared.toggle()
        }
        // Перетаскивание файлов в чужих приложениях видно только глобальному монитору.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { event in
            MainActor.assumeIsolated { DropShelf.shared.dragged(event) }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            MainActor.assumeIsolated { DropShelf.shared.shake.reset() }
        }
        isRunning = true
    }

    private func dragged(_ event: NSEvent) {
        guard panel?.isVisible != true else { return }
        let location = NSEvent.mouseLocation
        guard shake.add(x: location.x, time: event.timestamp) else { return }
        // Показываем полку, только если сейчас тащат файлы.
        guard NSPasteboard(name: .drag).types?.contains(.fileURL) == true else { return }
        show(near: location)
    }

    // MARK: - Полка

    func toggle() {
        if panel?.isVisible == true { hide() } else { show(near: NSEvent.mouseLocation) }
    }

    func show(near point: NSPoint) {
        let panel = self.panel ?? make()
        let size = panel.frame.size
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: point.x + 24, y: point.y - size.height / 2)
        if let visible = screen?.visibleFrame {
            if origin.x + size.width > visible.maxX { origin.x = point.x - size.width - 24 }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) { items.append(url) }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
    }

    func clear() {
        items.removeAll()
    }

    /// Вытащили файлы с полки — убираем их (если не зажата ⌥: тогда оставить).
    func draggedOut(_ urls: [URL]) {
        guard !NSEvent.modifierFlags.contains(.option) else { return }
        items.removeAll { urls.contains($0) }
        if items.isEmpty { hide() }
    }

    private func make() -> NSPanel {
        let host = FirstMouseHostingView(rootView: DropShelfView(shelf: self))
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 300),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

// MARK: - Вид

private struct DropShelfView: View {
    @ObservedObject var shelf: DropShelf
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full").foregroundStyle(Color.accentColor)
                Text("Полка").font(.callout.weight(.semibold))
                if !shelf.items.isEmpty {
                    Text("\(shelf.items.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if !shelf.items.isEmpty {
                    Button { shelf.clear() } label: { Image(systemName: "trash") }
                        .help("Очистить полку")
                }
                Button { shelf.hide() } label: { Image(systemName: "xmark") }
                    .help("Скрыть полку (файлы останутся)")
            }
            .buttonStyle(.borderless)

            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Перетащите сюда файлы").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // «Все» — перетащить сразу все файлы.
                DragOutHandle(urls: shelf.items) { shelf.draggedOut($0) } label: {
                    Label("Перетащить все (\(shelf.items.count))", systemImage: "square.stack.3d.up")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                }
                .frame(height: 26)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(shelf.items, id: \.self) { url in
                            DragOutHandle(urls: [url]) { shelf.draggedOut($0) } label: {
                                ShelfRow(url: url) { shelf.remove(url) }
                            }
                            .frame(height: 30)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 240, height: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(targeted ? Color.accentColor : Color.clear, lineWidth: 2))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in DropShelf.shared.add([url]) }
                }
            }
            return true
        }
    }
}

private struct ShelfRow: View {
    let url: URL
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
            Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Убрать с полки")
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .help(url.path)
    }
}

/// Источник перетаскивания для одного или нескольких файлов (SwiftUI так не умеет).
private struct DragOutHandle<Label: View>: NSViewRepresentable {
    let urls: [URL]
    let ended: ([URL]) -> Void
    @ViewBuilder let label: () -> Label

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        let host = NSHostingView(rootView: label())
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        update(view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        (view.subviews.first as? NSHostingView<Label>)?.rootView = label()
        update(view)
    }

    private func update(_ view: DragSourceView) {
        view.urls = urls
        view.ended = ended
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var ended: (([URL]) -> Void)?
    private var downEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Клики по кнопкам внутри (крестик) работают, остальное — начало перетаскивания.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, hit !== self, hit is NSButton || hit.superview is NSButton { return hit }
        return frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downEvent, !urls.isEmpty else { return }
        self.downEvent = nil
        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(index) * 4
            item.setDraggingFrame(NSRect(x: offset, y: -offset, width: 32, height: 32), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: downEvent, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation != [] else { return }
        let urls = self.urls
        ended?(urls)
    }
}
