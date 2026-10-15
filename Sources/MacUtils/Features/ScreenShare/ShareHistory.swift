import AppKit
import SwiftUI

/// История подключений (как в AnyDesk): к кому подключались, свои подписи, доверенные ID
/// и отметка «сейчас в эфире» (опрос ретранслятора раз в 10 секунд, пока список на экране).
@MainActor
final class ShareHistory: ObservableObject {
    static let shared = ShareHistory()

    struct Entry: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var label: String?
        var lastSeen: Date
        var trusted = false
        /// Только из «всегда разрешать» — не подключались сами.
        var incomingOnly = false

        var title: String { label?.isEmpty == false ? label! : (name.isEmpty ? ShareCode.display(id) : name) }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var live: Set<String> = []

    private var timer: Timer?
    private var users = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: Pref.shareHistory),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            // Свой и невалидный ID доверенными быть не могут (иначе «всегда разрешать» возвращает автопринятие).
            entries = saved.map { entry in
                var entry = entry
                if entry.trusted, !Self.canTrust(entry.id) { entry.trusted = false }
                return entry
            }
        }
    }

    /// Доверять можно только чужому ID из 10 ASCII-цифр (как принимает relay): свой и пустой/кривой ID подделывает любой зритель.
    static func canTrust(_ id: String, myID: String = ShareCode.myID) -> Bool {
        id != myID && id.utf8.count == 10 && id.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    var visitedEntries: [Entry] { entries.filter { !$0.incomingOnly }.sorted { $0.lastSeen > $1.lastSeen } }
    var trustedEntries: [Entry] { entries.filter(\.trusted) }

    func visited(_ id: String, name: String) {
        update(id) { entry in
            if !name.isEmpty { entry.name = name }
            entry.lastSeen = Date()
            entry.incomingOnly = false
        }
    }

    func trust(_ id: String, name: String) {
        guard Self.canTrust(id) else { return }
        update(id) { entry in
            entry.trusted = true
            if entry.name.isEmpty { entry.name = name }
        }
    }

    func untrust(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[index].incomingOnly { entries.remove(at: index) } else { entries[index].trusted = false }
        save()
    }

    func isTrusted(_ id: String) -> Bool { Self.canTrust(id) && entries.contains { $0.id == id && $0.trusted } }

    func label(for id: String) -> String? { entries.first { $0.id == id }.map(\.title) }

    func rename(_ id: String, to label: String) {
        update(id) { $0.label = label.trimmingCharacters(in: .whitespaces) }
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            change(&entries[index])
        } else {
            var entry = Entry(id: id, name: "", lastSeen: Date(), incomingOnly: true)
            change(&entry)
            entries.append(entry)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Pref.shareHistory) }
    }

    // MARK: - Кто сейчас в эфире

    func startPolling() {
        users += 1
        guard timer == nil else { return }
        refreshLive()
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { ShareHistory.shared.refreshLive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refreshLive() {
        let ids = visitedEntries.map(\.id)
        guard !ids.isEmpty, let url = ShareCode.statusURL(server: ScreenShare.server, ids: ids) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: ShareCode.request(url)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return }
            live = Set(json.filter(\.value).map(\.key))
        }
    }
}

/// Список истории: отметка эфира, подпись, «Смотреть», переименовать, удалить.
struct ShareHistoryList: View {
    @ObservedObject private var history = ShareHistory.shared
    @ObservedObject private var viewer = ShareViewer.shared
    @State private var renaming: ShareHistory.Entry?
    @State private var newLabel = ""

    var body: some View {
        Group {
            if history.visitedEntries.isEmpty {
                Text("Здесь появятся те, к кому вы подключались.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(history.visitedEntries) { entry in
                HStack(spacing: 8) {
                    Circle().fill(history.live.contains(entry.id) ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .help(history.live.contains(entry.id) ? "Сейчас в эфире" : "Сейчас не транслирует")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).lineLimit(1)
                        Text("\(ShareCode.display(entry.id)) · \(entry.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if history.live.contains(entry.id) {
                        Text("в эфире").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    }
                    Button("Смотреть") { viewer.watch(code: entry.id) }
                    Button { newLabel = entry.label ?? entry.name; renaming = entry } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("Переименовать")
                    Button { history.remove(entry.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Удалить из истории")
                }
            }
        }
        .onAppear { history.startPolling() }
        .onDisappear { history.stopPolling() }
        .alert("Подпись для \(renaming.map { ShareCode.display($0.id) } ?? "")", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Например, Саша — работа", text: $newLabel)
            Button("Сохранить") {
                if let entry = renaming { history.rename(entry.id, to: newLabel) }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        }
    }
}
