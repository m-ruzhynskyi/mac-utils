import Foundation

// Протокол трансляции mu-share-2 (проверка устройств по ключу Ed25519), сторона Mac.
// Чистая логика отдельно от сети и окон — чтобы её можно было проверять тестами.
// Спецификация: .audit/auth-design.md, фактический протокол relay: .audit/dev-auth-b.md.

// MARK: - Возможности ретранслятора

/// Токен протокола в заголовке и проверка, понимает ли ретранслятор mu-share-2 (`GET /version`).
enum ShareRelay {
    static let legacyToken = "mu-share-1"
    static let keyedToken = "mu-share-2"

    enum Capability: Equatable { case keyed, legacy }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Capability] = [:]
        private var expiry: [String: Date] = [:]
        func get(_ key: String) -> Capability? {
            lock.lock(); defer { lock.unlock() }
            if let until = expiry[key], until < Date() {
                values[key] = nil
                expiry[key] = nil
            }
            return values[key]
        }
        /// `ttl` — запомнить ненадолго (ответ был неуверенный); nil — до сброса или перезапуска.
        func set(_ key: String, _ value: Capability, ttl: TimeInterval? = nil) {
            lock.lock(); defer { lock.unlock() }
            values[key] = value
            expiry[key] = ttl.map { Date().addingTimeInterval($0) }
        }
        func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; values[key] = nil; expiry[key] = nil }
        func clear() { lock.lock(); defer { lock.unlock() }; values = [:]; expiry = [:] }
    }
    private static let cache = Cache()

    /// Хост и порт сервера: ключ кэша; одинаково для `https://x`, `wss://x/` и адреса запроса.
    static func key(forServer server: String) -> String? {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        return key(for: URL(string: text))
    }

    static func key(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(host):\(url?.port ?? 0)"
    }

    /// Токен для адреса: mu-share-2 только если этот ретранслятор его объявил.
    static func token(for url: URL) -> String {
        key(for: url).flatMap(cache.get) == .keyed ? keyedToken : legacyToken
    }

    static func versionURL(server: String) -> URL? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        if !base.contains("://") { base = "https://" + base }
        return URL(string: base + "/version")
    }

    /// Ответ `/version`: `protocols` содержит mu-share-2 — ключи поддерживаются. nil — это не ответ ретранслятора.
    static func parseVersion(_ data: Data) -> Capability? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let protocols = json["protocols"] as? [String] else { return nil }
        return protocols.contains(keyedToken) ? .keyed : .legacy
    }

    /// nil — нет связи или временная ошибка сервера (не запоминаем, повторим при следующем подключении).
    static func capability(server: String) async -> Capability? {
        guard let key = key(forServer: server) else { return nil }
        if let known = cache.get(key) { return known }
        guard let url = versionURL(server: server) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200, let parsed = parseVersion(data) {
            cache.set(key, parsed)
            return parsed
        }
        guard status == 404 || status == 405 || status == 200 else { return nil }
        // Старый ретранслятор отдаёт страницу или 404. Но то же самое даёт страница входа в гостиничном Wi-Fi,
        // поэтому такой ответ помним недолго: на настоящем ретрансляторе проверка ключей скоро включится.
        cache.set(key, .legacy, ttl: unsureTTL)
        return .legacy
    }

    /// Сколько помним «старый ретранслятор» без внятного ответа `/version`.
    static let unsureTTL: TimeInterval = 300

    /// Ретранслятор отказал по токену (403/426) — прежнее знание о нём неверно (откат, смена сервера): спросим заново.
    static func invalidate(server: String) {
        if let key = key(forServer: server) { cache.remove(key) }
    }

    /// Для тестов.
    static func resetCache() { cache.clear() }
    static func cached(server: String) -> Capability? { key(forServer: server).flatMap(cache.get) }
    static func remember(_ capability: Capability, server: String) {
        if let key = key(forServer: server) { cache.set(key, capability) }
    }
}

// MARK: - Запрос на подключение и решение хоста

/// Запрос зрителя, как его присылает ретранслятор. Без поля `auth` (старый ретранслятор или зритель)
/// запрос считается непроверенным.
struct ShareRequest: Equatable {
    enum Auth: Equatable { case key, none }

    var viewer: String
    var name: String
    var rid: String?
    var auth: Auth
    var pub: String?
    var fp: String?
    var idVerified: Bool
    var isSelf: Bool

    /// Один запрос = один ключ очереди (по rid; без него — по ID).
    var queueKey: String { rid ?? "id:" + viewer }

    @MainActor static func parse(_ json: [String: Any]) -> ShareRequest? {
        guard json["type"] as? String == "request" else { return nil }
        let name = String((json["name"] as? String ?? "").prefix(60))
        var auth = Auth.none
        var pub: String?
        if json["auth"] as? String == "key", let key = json["pub"] as? String, ShareHistory.isPublicKey(key) {
            auth = .key
            pub = key
        }
        let fp = pub.flatMap { ShareIdentity.fingerprint(ofBase64urlKey: $0) }
        return ShareRequest(viewer: json["viewer"] as? String ?? "", name: name, rid: json["rid"] as? String,
                            auth: auth, pub: pub, fp: fp,
                            idVerified: auth == .key && json["idVerified"] as? Bool == true,
                            // «Сам себе» верит только запросу с ключом: relay ставит self лишь после проверки подписи.
                            isSelf: auth == .key && json["self"] as? Bool == true)
    }
}

enum ShareAnswer: Equatable { case allowOnce, allowAlways, decline }

/// Что делать с запросом (раздел 4.2 дизайна): принять сразу или спросить.
enum ShareDecision: Equatable {
    case accept
    case ask(Prompt)

    enum Kind: Equatable {
        case normal      // обычный запрос
        case confirmKey  // ID в доверенных по-старому, ключ ещё не подтверждён
        case legacy      // у зрителя нет ключа: личность не проверена
    }

    struct Prompt: Equatable {
        var kind: Kind
        /// Показывать «Всегда разрешать» (для confirmKey — «Разрешить и запомнить ключ»).
        var allowAlways: Bool
        var notes: [String]
    }
}

/// Доверие, от которого зависит решение (в приложении — `ShareHistory.shared`).
struct ShareTrust {
    var isTrusted: (_ id: String, _ pub: String) -> Bool
    var needsKeyConfirmation: (_ id: String) -> Bool
    var canTrust: (_ id: String) -> Bool

    @MainActor static func live() -> ShareTrust {
        let history = ShareHistory.shared
        return ShareTrust(isTrusted: { history.isTrusted(id: $0, pub: $1) },
                          needsKeyConfirmation: { history.needsKeyConfirmation(id: $0) },
                          canTrust: { ShareHistory.canTrust($0) })
    }
}

enum ShareRules {
    static func decide(_ request: ShareRequest, trust: ShareTrust) -> ShareDecision {
        // 1. Своё же устройство: relay поставил self только после проверки подписи приватным ключом.
        if request.auth == .key, request.isSelf { return .accept }
        // 2. Доверие по ключу: один ID недостаточно, нужен и тот же ключ. И ID должен принадлежать этому ключу:
        //    при idVerified == false ID закреплён за другим устройством, а запись «доверен» могла появиться раньше.
        if request.auth == .key, request.idVerified, let pub = request.pub, trust.isTrusted(request.viewer, pub) { return .accept }
        // 3. Остальное — вопрос. Без ключа автоприёма и «Всегда разрешать» нет никогда.
        var notes: [String] = []
        let canTrust = trust.canTrust(request.viewer)
        let kind: ShareDecision.Kind
        switch request.auth {
        case .none:
            kind = .legacy
            notes.append("Старая версия или ретранслятор без проверки ключей: личность зрителя не подтверждена.")
        case .key:
            // Запомнить можно только ключ, который владеет этим ID: иначе чужой ключ получил бы доверие друга.
            if request.idVerified, trust.needsKeyConfirmation(request.viewer) {
                kind = .confirmKey
                notes.append("Этот ID был в доверенных. Mac Utils теперь проверяет ключ устройства: подтвердите один раз.")
            } else {
                kind = .normal
            }
            if !request.idVerified {
                notes.append("ID не подтверждён: он закреплён за другим устройством.")
            }
        }
        if !canTrust { notes.append("У запроса нет корректного ID, запоминать его нельзя.") }
        return .ask(.init(kind: kind, allowAlways: request.auth == .key && request.idVerified && canTrust, notes: notes))
    }

    /// Принять ли запрос по ответу. «Всегда разрешать» запоминает ключ только когда это разрешено правилом.
    static func apply(_ answer: ShareAnswer, to request: ShareRequest, prompt: ShareDecision.Prompt,
                      remember: (_ id: String, _ name: String, _ pub: String) -> Void) -> Bool {
        switch answer {
        case .decline: return false
        case .allowOnce: return true
        case .allowAlways:
            if prompt.allowAlways, request.auth == .key, let pub = request.pub {
                remember(request.viewer, request.name, pub)
            }
            return true
        }
    }

    /// Подпись принятия: ведущий подтверждает зрителю, что пустил его именно он (проверяется по hostKey).
    static func hostSignature(for request: ShareRequest, roomId: String, identity: ShareIdentity) -> String? {
        guard identity.isPersistent, request.auth == .key, let pub = request.pub, let rid = request.rid else { return nil }
        return identity.sign(accept: roomId, viewerPub: pub, rid: rid)
    }
}

// MARK: - Тексты ошибок

enum ShareErrorText {
    /// Понятное сообщение по коду ошибки ретранслятора; незнакомый код — текст самого ретранслятора.
    static func message(code: String, relayMessage: String? = nil) -> String {
        switch code {
        case "id-claimed": return "Этот ID занят другим устройством. Нажмите «Получить новый ID»."
        case "id-format": return "Этот ID не подходит для проверки устройства. Нажмите «Получить новый ID»."
        case "replaced": return "Трансляция с этим ID продолжена в другом окне."
        case "rate-limited": return "Слишком много попыток. Подождите минуту и повторите."
        case "auth-timeout": return "Сервер не дождался проверки устройства. Попробуйте ещё раз."
        case "bad-signature": return "Сервер не принял подпись устройства. Попробуйте ещё раз."
        case "upgrade-required": return "Сервер требует обновить Mac Utils."
        default:
            if let relayMessage, !relayMessage.isEmpty { return relayMessage }
            return "Ошибка проверки устройства (\(code))."
        }
    }

    /// Отказ при подключении ведущего: `rate-limited` здесь — лимит новых ID с этой сети, а не «подождите минуту».
    static func hostRefusal(code: String, message: String) -> String {
        code == "rate-limited"
            ? "Сервер временно ограничил новые ID с вашей сети. Попробуйте позже или из другой сети."
            : message
    }

    /// «Занято» (409) у ведущего: если ключ недоступен, а ID привязан к нему раньше, причина в Связке ключей, а не в другом окне.
    static func busyMessage(keychainUnavailable: Bool) -> String {
        keychainUnavailable
            ? "Нет доступа к ключу трансляции: этот ID привязан к нему, без него трансляция не начнётся. Если Mac Utils спрашивал пароль связки ключей, разрешите доступ и повторите."
            : "С вашим ID уже идёт трансляция (может, в другом окне)"
    }

    /// Ошибка, которую лечит только новый ID.
    static func needsNewID(_ code: String) -> Bool { code == "id-claimed" || code == "id-format" }
}

// MARK: - Рукопожатие (challenge → auth)

enum ShareHandshake {
    enum Outcome: Equatable {
        /// `keyed` — устройство проверено ключом; false — relay в режиме off (проверки нет).
        case authed(fp: String?, keyed: Bool)
        case refused(code: String, message: String)
        /// HTTP-код отказа при подключении (0 — нет связи).
        case failed(status: Int)
    }

    /// Можно ли говорить с relay по mu-share-2: он объявил протокол, и ключ лежит в Keychain.
    /// Временный ключ relay не показываем никогда: он закрепил бы ID за ключом, которого после перезапуска не будет.
    static func useKeys(capability: ShareRelay.Capability?, identity: ShareIdentity) -> Bool {
        capability == .keyed && identity.isPersistent
    }

    static func hostAuthMessage(identity: ShareIdentity, roomId: String, nonce: String) -> String? {
        guard identity.isPersistent else { return nil }
        return json(["type": "auth", "v": 2, "alg": "ed25519", "pub": identity.publicKey,
              "sig": identity.sign(host: roomId, nonce: nonce)])
    }

    static func viewerAuthMessage(identity: ShareIdentity, roomId: String, viewerId: String, rid: String, nonce: String) -> String? {
        guard identity.isPersistent else { return nil }
        return json(["type": "auth", "v": 2, "alg": "ed25519", "pub": identity.publicKey,
              "sig": identity.sign(viewer: roomId, viewerId: viewerId, rid: rid, nonce: nonce)])
    }

    static let releaseMessage = #"{"type":"release"}"#

    private static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Разбор сообщений до `authed`: что ответить на очередное сообщение relay.
    enum Step: Equatable {
        case sendAuth(nonce: String)
        case done(Outcome)
        case ignore
    }

    static func step(_ json: [String: Any]) -> Step {
        switch json["type"] as? String {
        case "challenge":
            guard let nonce = json["nonce"] as? String else { return .done(.refused(code: "bad-signature", message: ShareErrorText.message(code: "bad-signature"))) }
            return .sendAuth(nonce: nonce)
        case "authed":
            // mode == "off": ретранслятор ключи не проверяет, но клиент v2 обязан это принять.
            return .done(.authed(fp: json["fp"] as? String, keyed: json["mode"] as? String != "off"))
        case "error":
            let code = json["code"] as? String ?? "unknown"
            return .done(.refused(code: code, message: ShareErrorText.message(code: code, relayMessage: json["message"] as? String)))
        default:
            return .ignore
        }
    }

    /// Ждём challenge, отвечаем подписью, ждём authed. Для хоста; зритель отвечает на challenge в своём цикле приёма.
    @MainActor
    static func authenticateHost(_ socket: URLSessionWebSocketTask, roomId: String, identity: ShareIdentity) async -> Outcome {
        for _ in 0..<6 {
            guard let message = await receiveOnce(socket, timeout: 12) else {
                return .failed(status: (socket.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            guard case .string(let text) = message,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            switch step(object) {
            case .sendAuth(let nonce):
                guard let reply = hostAuthMessage(identity: identity, roomId: roomId, nonce: nonce) else { return .failed(status: 0) }
                do { try await socket.send(.string(reply)) } catch { return .failed(status: 0) }
            case .done(let outcome):
                return outcome
            case .ignore:
                continue
            }
        }
        return .failed(status: 0)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }

    /// Одно входящее сообщение с таймаутом; по таймауту сокет закрывается. nil — ошибка или таймаут.
    static func receiveOnce(_ socket: URLSessionWebSocketTask, timeout: TimeInterval) async -> URLSessionWebSocketTask.Message? {
        await withCheckedContinuation { continuation in
            let once = Once()
            // Таймер не отменяем: сработав после ответа, он ничего не делает (Once), сокет остаётся открытым.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run {
                    socket.cancel(with: .goingAway, reason: nil)
                    continuation.resume(returning: nil)
                }
            }
            socket.receive { result in
                once.run {
                    if case .success(let message) = result { continuation.resume(returning: message) }
                    else { continuation.resume(returning: nil) }
                }
            }
        }
    }
}
