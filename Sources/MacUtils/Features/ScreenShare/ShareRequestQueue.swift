import AppKit
import Combine
import SwiftUI
import MUCore
import MUDesign

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

    /// Сколько запрос ждёт ответа: потом отклоняется сам, иначе зритель и место на ретрансляторе заняты бесконечно.
    static let defaultTimeout: TimeInterval = 180

    @Published private(set) var items: [Item] = []
    var timeout: TimeInterval = ShareRequestQueue.defaultTimeout
    /// Сработало автоотклонение (имя зрителя) — для пометки и тестов.
    var onTimeout: (Item) -> Void = { item in
        Toast.show("Запрос от \(item.request.name.isEmpty ? "зрителя" : item.request.name) отклонён: нет ответа 3 минуты",
                   symbol: "clock.badge.xmark", tint: .orange)
    }
    private var timers: [String: Task<Void, Never>] = [:]
    var playsSound = true
    private var panel: NSPanel?
    private var host: FirstMouseHostingView<ShareRequestQueueView>?
    private var cancellable: AnyCancellable?

    var windowNumber: Int? { panel?.windowNumber }

    /// false — такой запрос уже в очереди.
    @discardableResult
    func add(_ item: Item) -> Bool {
        guard !items.contains(where: { $0.id == item.id }) else { return false }
        let wasEmpty = items.isEmpty
        items.append(item)
        startTimer(for: item)
        present()
        // Панель не забирает фокус: о первом запросе сообщаем звуком (остальные видны в счётчике «Запросов: N»).
        if wasEmpty, playsSound { Feedback.play("Ping") }
        return true
    }

    private func startTimer(for item: Item) {
        timers[item.id]?.cancel()
        let id = item.id, delay = timeout
        timers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expire(id)
        }
    }

    private func expire(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        timers[id] = nil
        refreshPanel()
        item.answer(.decline)
        onTimeout(item)
    }

    private func cancelTimer(_ id: String) {
        timers[id]?.cancel()
        timers[id] = nil
    }

    /// Показать панель (клик по счётчику в «Эфир»).
    func show() {
        guard !items.isEmpty else { return }
        present()
    }

    /// Создать панель заранее и скрытой: её номер окна нужен фильтру захвата ещё до первого запроса,
    /// иначе первые кадры с именем и отпечатком просителя уйдут зрителям.
    func prepare() {
        guard panel == nil else { return }
        makePanel()
        guard let panel else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardlessOnScreen()
        panel.orderOut(nil)
    }

    func contains(key: String) -> Bool { items.contains { $0.id == key } }

    /// Зритель отозвал запрос (или ушёл): убираем без ответа.
    func remove(key: String) {
        cancelTimer(key)
        items.removeAll { $0.id == key }
        refreshPanel()
    }

    func removeAll() {
        for id in timers.keys { timers[id]?.cancel() }
        timers = [:]
        items = []
        refreshPanel()
    }

    func answer(_ item: Item, _ answer: ShareAnswer) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        cancelTimer(item.id)
        items.removeAll { $0.id == item.id }
        refreshPanel()
        item.answer(answer)
    }

    private func makePanel() {
        guard panel == nil else { return }
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
        // @Published сообщает до изменения: размер считаем на следующем проходе, когда SwiftUI уже перестроил содержимое,
        // иначе новый запрос (с предупреждениями) оказывался выше панели и обрезался сверху.
        cancellable = $items.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.layout() } }
        }
    }

    private func present() {
        makePanel()
        panel?.alphaValue = 1
        layout(force: true)
        panel?.orderFrontRegardlessOnScreen()
        NSApp.requestUserAttention(.informationalRequest)
        // Окно запроса не должно попасть в картинку для зрителей.
        ScreenShare.shared.refreshVideoFilter()
    }

    private func layout(force: Bool = false) {
        // Экран, который транслируется (иначе ведущий на втором мониторе запрос не увидит), или главный.
        guard let panel, let host, let screen = ScreenShare.shared.broadcastScreen ?? NSScreen.main else { return }
        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let width = max(size.width, ShareRequestQueueView.width)
        if force || !panel.isVisible || panel.frame.size != NSSize(width: width, height: size.height) {
            // Правый верхний угол, под индикатором «Эфир».
            panel.setFrame(NSRect(x: screen.visibleFrame.maxX - width - 8,
                                  y: screen.visibleFrame.maxY - size.height - 44,
                                  width: width, height: size.height), display: true)
        }
    }

    /// Транслируется другой экран (зритель переключил монитор, «Сменить источник»): видимая панель — туда же.
    func screenChanged() {
        guard let panel, panel.isVisible else { return }
        layout(force: true)
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
    static let width: CGFloat = 380
    @ObservedObject var queue: ShareRequestQueue

    var body: some View {
        if let item = queue.items.first {
            ShareRequestCard(name: item.request.name, viewer: item.request.viewer, fingerprint: item.request.fp,
                             prompt: item.prompt, moreCount: queue.items.count - 1) { queue.answer(item, $0) }
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

/// Запрос зрителя (по `MacHost.dc.html`): аватар-инициал, имя, ID, предупреждения; «Отклонить / Всегда / Разрешить»
/// в ряд, а если ряд не помещается (длинные подписи, узкая панель) — столбиком, главное действие сверху.
/// Все значения готовые, без очереди: так карточку можно снять для проверки вида.
struct ShareRequestCard: View {
    let name: String
    let viewer: String
    var fingerprint: String?
    let prompt: ShareDecision.Prompt
    var moreCount = 0
    let answer: (ShareAnswer) -> Void

    private var title: String { name.isEmpty ? "Зритель" : name }
    private var confirmKey: Bool { prompt.kind == .confirmKey }
    private var allowTitle: String { confirmKey ? "Разрешить один раз" : "Разрешить" }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                Text(String(title.prefix(1)).uppercased())
                    .font(DS.Font.manrope(16, .heavy, relativeTo: .headline))
                    .foregroundStyle(.dsText)
                    .frame(width: 38, height: 38)
                    .background(Color.dsField, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(title) хочет посмотреть ваш экран")
                        .font(DS.Font.manrope(14, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
                        .fixedSize(horizontal: false, vertical: true)
                    if !viewer.isEmpty {
                        Text("ID \(ShareCode.display(viewer))").font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute)
                    }
                    if let fingerprint {
                        Text("Отпечаток \(fingerprint)").font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute)
                    }
                }
            }
            ForEach(prompt.notes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: DS.Tone.warning.symbol).foregroundStyle(DS.Tone.warning.text).accessibilityHidden(true)
                    Text(note).foregroundStyle(DS.Tone.warning.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(DS.Font.caption)
            }
            Text("Зритель только смотрит и может ставить метки — управлять вашим Mac он не может.")
                .font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
            buttons
            if moreCount > 0 {
                Text("Ещё \(moreCount) \(ShareRequestQueueView.requests(moreCount)) в очереди")
                    .font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
        }
        .padding(14)
        .frame(width: ShareRequestQueueView.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func decline() -> some View {
        Button { answer(.decline) } label: { Text("Отклонить").lineLimit(1) }
            .buttonStyle(.graphite(.secondary, fill: true))
    }

    private func allow() -> some View {
        Button { answer(.allowOnce) } label: { Text(allowTitle).lineLimit(1) }
            .buttonStyle(.graphite(.primary, fill: true))
    }

    private func always() -> some View {
        Button { answer(.allowAlways) } label: { Text(confirmKey ? "Разрешить и запомнить ключ" : "Всегда").lineLimit(1) }
            .buttonStyle(.graphite(.secondary, fill: true))
            .help(confirmKey ? "Разрешить и запомнить ключ устройства" : "Всегда разрешать этому зрителю")
            .accessibilityLabel(confirmKey ? "Разрешить и запомнить ключ" : "Всегда разрешать")
    }

    @ViewBuilder private var buttons: some View {
        if prompt.allowAlways {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s) { decline(); always(); allow() }
                VStack(spacing: DS.Space.s) { allow(); always(); decline() }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s) { decline(); allow() }
                VStack(spacing: DS.Space.s) { allow(); decline() }
            }
        }
    }
}
