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

/// Идёт ли сейчас перетаскивание файлов (без системных вызовов — для тестов).
/// Пастборд `.drag` хранит данные **прошлого** перетаскивания: проверять только его типы нельзя — тогда любое «шарканье»
/// мышью с зажатой кнопкой после давнего перетаскивания файла открывает полку. Новое перетаскивание пишет пастборд заново,
/// поэтому его `changeCount` должен измениться после нажатия кнопки мыши.
enum DragSession {
    static func isFileDrag(changeCountAtMouseDown: Int?, changeCountNow: Int, hasFileURLs: Bool) -> Bool {
        guard let down = changeCountAtMouseDown else { return false }
        return hasFileURLs && changeCountNow != down
    }
}

/// Файлы полки: без дублей одного файла под разными путями и без исчезнувших (без UI — для тестов).
enum ShelfItems {
    /// `/var/…` и `/private/var/…`, «папка/» и «папка», `a/../b` — один и тот же файл.
    static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Добавить файлы к списку: в порядке появления, каждый один раз.
    static func adding(_ urls: [URL], to items: [URL]) -> [URL] {
        var result = items
        var seen = Set(items.map(normalized))
        for url in urls.map(normalized) where seen.insert(url).inserted { result.append(url) }
        return result
    }

    /// Убрать переименованные и удалённые файлы.
    static func existing(_ items: [URL], exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [URL] {
        items.filter(exists)
    }
}

/// «Полка»: временное место для файлов. Встряхните мышь, перетаскивая файлы
/// (или ⌃⌥D), бросьте их на полку, перейдите в нужное место и вытащите обратно.
@MainActor
final class DropShelf: ObservableObject {
    static let shared = DropShelf()

    /// Для снимков интерфейса: полка с готовыми файлами (список на экране не меняется).
    static func demo(items: [URL]) -> DropShelf {
        let shelf = DropShelf()
        shelf.items = items
        return shelf
    }

    @Published private(set) var items: [URL] = [] {
        didSet {
            // Новые файлы — обычный список; убранные — убираем и из групп.
            guard let current = groups else { return }
            let grouped = Set(current.flatMap(\.files))
            if items.contains(where: { !grouped.contains($0) }) {
                groups = nil
            } else {
                groups = current.compactMap { group in
                    var group = group
                    group.files.removeAll { !items.contains($0) }
                    return group.files.isEmpty ? nil : group
                }
            }
        }
    }
    /// Группы по смыслу от ИИ (nil — обычный список).
    @Published var groups: [ShelfGroup]?
    @Published private(set) var grouping = false

    func groupWithAI() {
        guard !grouping, items.count >= 2 else { return }
        grouping = true
        let files = items
        Task {
            defer { grouping = false }
            do {
                groups = try await ShelfGrouper.group(files)
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }
    @Published private(set) var isRunning = false

    private var panel: NSPanel?
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var downMonitor: Any?
    private var localDownMonitor: Any?
    private var shake = ShakeDetector()
    /// `changeCount` пастборда перетаскивания в момент нажатия кнопки мыши (см. `DragSession`).
    private var dragChangeAtMouseDown: Int?

    func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.dropShelf)
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.dropShelf)
        for monitor in [dragMonitor, upMonitor, downMonitor, localDownMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        dragMonitor = nil
        upMonitor = nil
        downMonitor = nil
        localDownMonitor = nil
        dragChangeAtMouseDown = nil
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
            MainActor.assumeIsolated {
                DropShelf.shared.shake.reset()
                DropShelf.shared.dragChangeAtMouseDown = nil
            }
        }
        // Запоминаем пастборд перетаскивания при нажатии: в чужих приложениях (глобально) и в своих окнах (локально).
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            MainActor.assumeIsolated { DropShelf.shared.mouseWentDown() }
        }
        localDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { DropShelf.shared.mouseWentDown() }
            return event
        }
        isRunning = true
    }

    private func mouseWentDown() {
        dragChangeAtMouseDown = NSPasteboard(name: .drag).changeCount
        shake.reset()
    }

    private func dragged(_ event: NSEvent) {
        guard panel?.isVisible != true else { return }
        let location = NSEvent.mouseLocation
        guard shake.add(x: location.x, time: event.timestamp) else { return }
        // Показываем полку, только если сейчас тащат файлы — именно в этом перетаскивании, а не в прошлом.
        let pasteboard = NSPasteboard(name: .drag)
        guard DragSession.isFileDrag(changeCountAtMouseDown: dragChangeAtMouseDown, changeCountNow: pasteboard.changeCount,
                                     hasFileURLs: pasteboard.types?.contains(.fileURL) == true) else { return }
        show(near: location)
    }

    // MARK: - Полка

    func toggle() {
        if panel?.isVisible == true { hide() } else { show(near: NSEvent.mouseLocation) }
    }

    func show(near point: NSPoint) {
        pruneMissing()
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
        let updated = ShelfItems.adding(urls, to: items)
        if updated != items { items = updated }
    }

    /// Переименованные и удалённые файлы убираются: иначе строка остаётся, а перетаскивание тихо ничего не делает.
    func pruneMissing() {
        let alive = ShelfItems.existing(items)
        if alive != items { items = alive }
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

    /// Перетаскивание полки за заголовок (и за пустую полку): SwiftUI сам окно не двигает.
    private var moveMonitor: Any?

    private func installMoveMonitor() {
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { incoming in
            let box = UncheckedSendable(incoming)
            let result: UncheckedSendable<NSEvent?> = MainActor.assumeIsolated {
                let event = box.value
                let shelf = DropShelf.shared
                guard let panel = shelf.panel, event.window === panel else { return UncheckedSendable(event) }
                let point = event.locationInWindow
                let height = panel.frame.height
                // Заголовок — верхние 34 pt без кнопок справа; пустая полка — вся, кроме кнопок.
                let inHeader = point.y > height - 34 && point.x < panel.frame.width - 90
                let inEmpty = shelf.items.isEmpty && point.y < height - 34
                guard inHeader || inEmpty else { return UncheckedSendable(event) }
                panel.performDrag(with: event)
                return UncheckedSendable(nil)
            }
            return result.value
        }
    }

    private func make() -> NSPanel {
        installMoveMonitor()
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

struct DropShelfView: View {
    @ObservedObject var shelf: DropShelf
    @State private var targeted = false

    var body: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full").font(.system(size: 14, weight: .medium)).foregroundStyle(.dsAccText)
                    .accessibilityHidden(true)
                Text("Полка").font(DS.Font.rowTitle).foregroundStyle(.dsText)
                if !shelf.items.isEmpty {
                    Text("\(shelf.items.count)").font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute)
                }
                Spacer()
                if Ollama.isOn(Pref.aiShelf), shelf.items.count >= 2 {
                    if shelf.grouping {
                        ProgressView().controlSize(.small)
                    } else {
                        ShelfIconButton(symbol: shelf.groups == nil ? "sparkles" : "list.bullet",
                                        help: shelf.groups == nil ? "Сгруппировать по смыслу (ИИ)" : "Обычный список") {
                            shelf.groups == nil ? shelf.groupWithAI() : (shelf.groups = nil)
                        }
                    }
                }
                if !shelf.items.isEmpty {
                    ShelfIconButton(symbol: "trash", help: "Очистить полку") { shelf.clear() }
                }
                ShelfIconButton(symbol: "xmark", help: "Скрыть полку (файлы останутся)") { shelf.hide() }
            }
            .help("Потяните за заголовок, чтобы передвинуть полку")

            if shelf.items.isEmpty {
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 20, weight: .medium)).foregroundStyle(.dsText)
                        .frame(width: DS.Size.headerTile, height: DS.Size.headerTile)
                        .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Перетащите сюда файлы").font(DS.Font.manrope(13, .semibold, relativeTo: .callout)).foregroundStyle(.dsMute)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // «Все» — перетащить сразу все файлы.
                DragOutHandle(urls: shelf.items) { shelf.draggedOut($0) } label: {
                    Label("Перетащить все (\(shelf.items.count))", systemImage: "square.stack.3d.up")
                        .font(DS.Font.manrope(13, .heavy, relativeTo: .callout))
                        .foregroundStyle(.dsAccInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.dsAcc, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                }
                .frame(height: 32)
                ScrollView {
                    VStack(spacing: 4) {
                        if let groups = shelf.groups {
                            ForEach(groups) { group in
                                DragOutHandle(urls: group.files) { shelf.draggedOut($0) } label: {
                                    HStack {
                                        Text(group.title).font(DS.Font.groupLabel).foregroundStyle(.dsMute).lineLimit(1)
                                        Spacer()
                                        Text("\(group.files.count)").font(DS.Font.mono(11, relativeTo: .caption2)).foregroundStyle(.dsMute)
                                    }
                                    .padding(.horizontal, 4)
                                }
                                .frame(height: 22)
                                .help("Перетащите подпись — заберёте всю группу")
                                ForEach(group.files, id: \.self) { url in
                                    DragOutHandle(urls: [url]) { shelf.draggedOut($0) } label: {
                                        ShelfRow(url: url) { shelf.remove(url) }
                                    }
                                    .frame(height: 34)
                                }
                            }
                        } else {
                            ForEach(shelf.items, id: \.self) { url in
                                DragOutHandle(urls: [url]) { shelf.draggedOut($0) } label: {
                                    ShelfRow(url: url) { shelf.remove(url) }
                                }
                                .frame(height: 34)
                            }
                        }
                    }
                }
            }
        }
        .padding(DS.Space.m)
        .frame(width: 240, height: 300)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous)
            .strokeBorder(targeted ? Color.dsAccLine : Color.dsLine, lineWidth: targeted ? 2 : 1))
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

/// Кнопка-значок в шапке полки: 28×28, `mute`, при наведении — фон `field`.
private struct ShelfIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered ? Color.dsText : .dsMute)
                .frame(width: 28, height: 28)
                .background(hovered ? Color.dsField : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ShelfRow: View {
    let url: URL
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
            Text(url.lastPathComponent).font(DS.Font.manrope(12, .semibold, relativeTo: .caption)).foregroundStyle(.dsText)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.dsMute) }
                .buttonStyle(.plain)
                .help("Убрать с полки")
                .accessibilityLabel("Убрать с полки")
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .help(url.path)
    }
}

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
        // Файл могли переименовать или удалить, пока он лежал на полке: тащим только существующие.
        let alive = ShelfItems.existing(urls)
        DropShelf.shared.pruneMissing()
        guard !alive.isEmpty else {
            NSSound.beep()
            return
        }
        let items = alive.enumerated().map { index, url -> NSDraggingItem in
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

