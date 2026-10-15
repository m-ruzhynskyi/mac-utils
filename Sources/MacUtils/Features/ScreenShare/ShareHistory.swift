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
        // Протокол v2 (.audit/auth-design.md §3.1). Только опциональные: синтезированный Decodable
        // требует неопциональные ключи, и старая история (1.4.0) без них не прочиталась бы целиком.
        /// Публичный ключ зрителя, которому доверяем («Всегда разрешать» с ключом).
        var key: String?
        /// Публичный ключ ведущего, к которому подключались (pinning, §4.3).
        var hostKey: String?
        var keyConfirmedAt: Date?

        var title: String { label?.isEmpty == false ? label! : (name.isEmpty ? ShareCode.display(id) : name) }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var live: Set<String> = []

    private var timer: Timer?
    private var users = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: Pref.shareHistory) {
            entries = Self.decodeEntries(data)
        }
    }

    /// Элемент массива, который не прочитался, не должен обнулять всю историю: он пропускается, остальные сохраняются.
    private struct Lossy: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    /// История из сохранённых данных: поэлементно, с очисткой небезопасных полей. Не массив — пусто.
    static func decodeEntries(_ data: Data) -> [Entry] {
        guard let saved = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        // Свой и невалидный ID доверенными быть не могут (иначе «всегда разрешать» возвращает автопринятие).
        // Ключи не того формата отбрасываются: с ними не совпадёт ни один настоящий ключ.
        return saved.compactMap(\.entry).map { entry in
            var entry = entry
            if entry.trusted, !canTrust(entry.id) { entry.trusted = false }
            if let key = entry.key, !isPublicKey(key) { entry.key = nil; entry.keyConfirmedAt = nil }
            if let key = entry.hostKey, !isPublicKey(key) { entry.hostKey = nil }
            return entry
        }
    }

    /// Доверять можно только чужому ID из 10 ASCII-цифр (как принимает relay): свой и пустой/кривой ID подделывает любой зритель.
    static func canTrust(_ id: String, myID: String = ShareCode.myID) -> Bool {
        id != myID && isValidID(id)
    }

    /// 10 ASCII-цифр — как `^\d{10}$` в relay.
    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 10 && id.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// Публичный ключ Ed25519 в base64url без `=`: 43 символа, 32 байта.
    static func isPublicKey(_ pub: String) -> Bool {
        pub.utf8.count == 43 && ShareIdentity.data(fromBase64url: pub)?.count == 32
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

    /// Доверие по одному ID (протокол v1). Остаётся до перехода ScreenShare на `trust(_:name:pub:)` (M2).
    func trust(_ id: String, name: String) {
        guard Self.canTrust(id) else { return }
        update(id) { entry in
            entry.trusted = true
            if entry.name.isEmpty { entry.name = name }
        }
    }

    /// «Всегда разрешать» с ключом: доверие привязывается к паре ID + ключ, прежний ключ заменяется.
    func trust(_ id: String, name: String, pub: String) {
        guard Self.canTrust(id), Self.isPublicKey(pub) else { return }
        update(id) { entry in
            entry.trusted = true
            entry.key = pub
            entry.keyConfirmedAt = Date()
            if entry.name.isEmpty { entry.name = name }
        }
    }

    /// Снимает доверие вместе с ключом: следующее «Всегда разрешать» запомнит ключ заново.
    func untrust(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // Запись без визитов (создана только «Всегда разрешать») удаляется целиком, но не вместе с запомненным
        // ключом ведущего: иначе «Снять доверие» стирает pinning (§4.3), и смена ключа ведущего пройдёт незамеченной.
        if entries[index].incomingOnly && entries[index].hostKey == nil {
            entries.remove(at: index)
        } else {
            entries[index].trusted = false
            entries[index].key = nil
            entries[index].keyConfirmedAt = nil
        }
        save()
    }

    /// Доверие по одному ID (протокол v1). Остаётся до перехода ScreenShare на `isTrusted(id:pub:)` (M2).
    func isTrusted(_ id: String) -> Bool { Self.canTrust(id) && entries.contains { $0.id == id && $0.trusted } }

    /// v2: доверен этот ID **и** именно этот ключ. Совпадения одного ID недостаточно.
    func isTrusted(id: String, pub: String) -> Bool {
        Self.canTrust(id) && Self.isPublicKey(pub) && entries.contains { $0.id == id && $0.trusted && $0.key == pub }
    }

    /// Доверенный по старому ID без ключа: на первый v2-запрос — окно подтверждения, без автоприёма (§3.2).
    func needsKeyConfirmation(id: String) -> Bool {
        Self.canTrust(id) && entries.contains { $0.id == id && $0.trusted && $0.key == nil }
    }

    /// Запомнить ключ ведущего, к которому подключались (§4.3). Зритель вызывает `visited()` раньше: запись уже «посещённая».
    func pinHost(id: String, key: String) {
        guard Self.isValidID(id), Self.isPublicKey(key) else { return }
        update(id) { $0.hostKey = key }
    }

    func hostKey(for id: String) -> String? { entries.first { $0.id == id }?.hostKey }

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

    /// Ключ для подписанного `POST /status`. Пока nil — только прежний `GET`. Ставит ScreenShare (M2), когда ключ
    /// уже создан и relay понимает v2: сам опрос истории не должен создавать ключ и вызывать запрос Keychain.
    static var statusIdentity: ShareIdentity?
    /// Сервер, который не понял `POST /status` (старый или сторонний relay): до смены сервера только `GET`.
    private var signedStatusUnsupported: String?

    /// Что делать с ответом на подписанный `POST /status` (N3).
    enum SignedStatusAction: Equatable {
        /// 200 и ответ про все ID — берём его.
        case use
        /// Сервер не понял или не принял `POST` надолго (200 без карты, 403, 404, 405): дальше только `GET`.
        case rememberUnsupportedThenGet
        /// 429: лимит — не добавлять к нему ещё и `GET`, пропустить тик.
        case skipTick
        /// Разовая ошибка (подпись, 5xx, нет связи): один `GET` в этом тике.
        case getOnce
    }

    static func signedStatusAction(status: Int, parsed: Bool) -> SignedStatusAction {
        switch status {
        case 200: return parsed ? .use : .rememberUnsupportedThenGet
        case 403, 404, 405: return .rememberUnsupportedThenGet
        case 429: return .skipTick
        default: return .getOnce
        }
    }

    /// Признак «этот сервер для этого ID не понимает подписанный запрос»: смена сервера или ID (новый ключ) даёт новую попытку.
    static func signedStatusKey(server: String, myID: String) -> String { "\(server)|\(myID)" }

    /// Кого опрашивать: только 10-значные ID, не больше 20 самых свежих (лимит relay, §6).
    static func statusIDs(_ entries: [Entry]) -> [String] {
        Array(entries.sorted { $0.lastSeen > $1.lastSeen }.map(\.id).filter(isValidID).prefix(20))
    }

    /// Подписанный запрос «кто в эфире» (§6): тело `{v, id, pub, ts, ids, sig}`, подпись — `ShareIdentity.statusMessage`.
    static func statusRequest(server: String, myID: String, ids: [String], identity: ShareIdentity,
                              ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> URLRequest? {
        guard !ids.isEmpty, let url = ShareCode.statusURL(server: server, ids: []),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        guard let postURL = components.url else { return nil }
        let pub = identity.publicKey
        guard isPublicKey(pub) else { return nil }
        let body: [String: Any] = ["v": 2, "id": myID, "pub": pub, "ts": ts, "ids": ids,
                                   "sig": identity.sign(status: myID, ts: ts, ids: ids)]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        var request = ShareCode.request(postURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    /// Ответ `/status`: в эфире те из `ids`, что отмечены true. `complete` — ответ должен быть про все `ids`:
    /// старый relay на `POST` тело не читает и отвечает `{}`, это не «никого нет», а «не понял».
    static func parseLive(_ data: Data, ids: [String], complete: Bool = false) -> Set<String>? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool],
              !complete || ids.allSatisfy({ json[$0] != nil }) else { return nil }
        return Set(ids.filter { json[$0] == true })
    }

    func refreshLive() {
        let ids = Self.statusIDs(visitedEntries)
        let server = ScreenShare.server
        guard !ids.isEmpty, let url = ShareCode.statusURL(server: server, ids: ids) else { return }
        let memo = Self.signedStatusKey(server: server, myID: ShareCode.myID)
        var signed: URLRequest?
        if signedStatusUnsupported != memo, let identity = Self.statusIdentity, identity.isPersistent {
            signed = Self.statusRequest(server: server, myID: ShareCode.myID, ids: ids, identity: identity)
        }
        Task {
            if let signed, let (data, response) = try? await URLSession.shared.data(for: signed) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let parsed = status == 200 ? Self.parseLive(data, ids: ids, complete: true) : nil
                switch Self.signedStatusAction(status: status, parsed: parsed != nil) {
                case .use:
                    live = parsed ?? []
                    return
                case .skipTick:
                    return
                case .rememberUnsupportedThenGet:
                    signedStatusUnsupported = memo
                case .getOnce:
                    break
                }
            }
            guard let (data, _) = try? await URLSession.shared.data(for: ShareCode.request(url)),
                  let result = Self.parseLive(data, ids: ids) else { return }
            live = result
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
