import AppKit
import Combine
import SwiftUI

/// Немодальная панель с очередью запросов на подключение: вместо NSAlert.runModal на каждый запрос.
/// Показывает первый запрос и «Ещё N»; панель не забирает фокус и не попадает в трансляцию.
@MainActor
final class ShareRequestQueue: ObservableObject {
    static let shared = ShareRequestQueue()

    struct Item: Identifiable {
        let request: ShareRequest
        let prompt: ShareDecision.Prompt
        let answer: (ShareAnswer) -> Void
        var id: String { request.queueKey }
    }

    @Published private(set) var items: [Item] = []
    private var panel: NSPanel?
    private var host: FirstMouseHostingView<ShareRequestQueueView>?
    private var cancellable: AnyCancellable?

    var windowNumber: Int? { panel?.windowNumber }

    /// false — такой запрос уже в очереди.
    @discardableResult
    func add(_ item: Item) -> Bool {
        guard !items.contains(where: { $0.id == item.id }) else { return false }
        items.append(item)
        present()
        return true
    }

    func contains(key: String) -> Bool { items.contains { $0.id == key } }

    /// Зритель отозвал запрос (или ушёл): убираем без ответа.
    func remove(key: String) {
        items.removeAll { $0.id == key }
        refreshPanel()
    }

    func removeAll() {
        items = []
        refreshPanel()
    }

    func answer(_ item: Item, _ answer: ShareAnswer) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        items.removeAll { $0.id == item.id }
        refreshPanel()
        item.answer(answer)
    }

    private func present() {
        if panel == nil {
            let host = FirstMouseHostingView(rootView: ShareRequestQueueView(queue: self))
            let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = host
            self.host = host
            self.panel = panel
            // Размер меняется вместе с содержимым (следующий запрос, «Ещё N»).
            cancellable = $items.receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            }
        }
        layout()
        panel?.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
        // Окно запроса не должно попасть в картинку для зрителей.
        ScreenShare.shared.refreshVideoFilter()
    }

    private func layout() {
        guard let panel, let host, let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        let size = host.fittingSize
        let width = max(size.width, 360)
        if !panel.isVisible || panel.frame.size != NSSize(width: width, height: size.height) {
            // Правый верхний угол, под индикатором «Эфир».
            panel.setFrame(NSRect(x: screen.visibleFrame.maxX - width - 8,
                                  y: screen.visibleFrame.maxY - size.height - 44,
                                  width: width, height: size.height), display: true)
        }
    }

    private func refreshPanel() {
        if items.isEmpty {
            panel?.orderOut(nil)
            ScreenShare.shared.refreshVideoFilter()
        } else {
            layout()
        }
    }
}

struct ShareRequestQueueView: View {
    @ObservedObject var queue: ShareRequestQueue

    var body: some View {
        if let item = queue.items.first {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(item.request.name.isEmpty ? "Зритель" : item.request.name) хочет посмотреть ваш экран")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    if !item.request.viewer.isEmpty {
                        Text("ID \(ShareCode.display(item.request.viewer))")
                    }
                    if let fp = item.request.fp {
                        Text("Отпечаток \(fp)").monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(item.prompt.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("Зритель только смотрит и может ставить метки — управлять вашим Mac он не может.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Отклонить") { queue.answer(item, .decline) }
                    Spacer()
                    if item.prompt.allowAlways {
                        Button(item.prompt.kind == .confirmKey ? "Разрешить и запомнить ключ" : "Всегда разрешать") {
                            queue.answer(item, .allowAlways)
                        }
                    }
                    Button(item.prompt.kind == .confirmKey ? "Разрешить один раз" : "Разрешить") { queue.answer(item, .allowOnce) }
                        .buttonStyle(.borderedProminent)
                }
                if queue.items.count > 1 {
                    Text("Ещё \(queue.items.count - 1) \(Self.requests(queue.items.count - 1)) в очереди")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(width: 360, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// «1 запрос», «2 запроса», «5 запросов».
    static func requests(_ n: Int) -> String {
        let last = n % 10, lastTwo = n % 100
        if last == 1 && lastTwo != 11 { return "запрос" }
        if (2...4).contains(last) && !(12...14).contains(lastTwo) { return "запроса" }
        return "запросов"
    }
}
