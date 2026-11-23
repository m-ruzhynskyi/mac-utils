import Foundation
import Network

/// Сторона ПК по `docs/mu-link-protocol.md` без сети: сопряжение кодом, проверка подписи Mac, пульс и `status`.
/// Повторяет логику `windows/link/server.js`; используется двойником ПК в самопроверке и тестах.
package final class LinkPCCore: @unchecked Sendable {
    package let key: LinkSigner
    package var name: String
    package var version: String
    /// Связанные Mac: публичный ключ → имя.
    package private(set) var knownMacs: [String: String] = [:]
    private var pairingCode: String?
    private var pairingExpires = Date.distantPast
    private var attempts = 0
    private var blockedUntil = Date.distantPast
    private let lock = NSLock()

    package static let pairingLifetime: TimeInterval = 120
    package static let maxAttempts = 5
    package static let blockSeconds: TimeInterval = 300

    package init(key: LinkSigner, name: String, version: String) { self.key = key; self.name = name; self.version = version }

    /// «Связать с Mac»: новый код на 2 минуты. Во время блокировки — nil.
    package func openPairing(now: Date = Date(), code: String = LinkCrypto.newCode()) -> String? {
        lock.withLock {
            guard now >= blockedUntil else { return nil }
            pairingCode = code; pairingExpires = now.addingTimeInterval(Self.pairingLifetime); attempts = 0
            return code
        }
    }

    package func closePairing() { lock.withLock { pairingCode = nil } }
    package func forgetAll() { lock.withLock { knownMacs = [:] } }
    package func isKnown(_ pub: String) -> Bool { lock.withLock { knownMacs[pub] != nil } }

    package enum PairCheck: Equatable { case ok, closed, blocked(retryAfter: Int), badCode(attemptsLeft: Int) }

    /// Проверка доказательства кода. Пятая ошибка сжигает код и блокирует приём на 5 минут.
    package func checkPair(proof: String, message: String, now: Date = Date()) -> PairCheck {
        lock.withLock {
            if now < blockedUntil { return .blocked(retryAfter: Int(blockedUntil.timeIntervalSince(now).rounded(.up))) }
            guard let code = pairingCode, now < pairingExpires else { pairingCode = nil; return .closed }
            if LinkCrypto.proofMatches(proof, code: code, message: message) { return .ok }
            attempts += 1
            if attempts >= Self.maxAttempts {
                pairingCode = nil
                blockedUntil = now.addingTimeInterval(Self.blockSeconds)
                return .blocked(retryAfter: Int(Self.blockSeconds))
            }
            return .badCode(attemptsLeft: Self.maxAttempts - attempts)
        }
    }

    /// Сопряжение прошло: Mac запомнен, код больше не действует.
    package func completePairing(macPub: String, macName: String) -> String? {
        lock.withLock {
            guard let code = pairingCode else { return nil }
            knownMacs[macPub] = macName
            pairingCode = nil
            return code
        }
    }

    package func status(uptime: Int) -> LinkStatus {
        LinkStatus(name: name, os: "Windows (двойник)", uptime: uptime, app: "Mac Utils Share", version: version)
    }
}

/// Один вход на ПК: рукопожатие (§4), сопряжение (§5), `pong` и `status`.
package struct LinkPCSession {
    package enum Output: Equatable {
        case send(String)
        case close(UInt16)
        /// Рукопожатие закончено: Mac на связи (ключ, имя).
        case ready(macPub: String, macName: String)
    }

    private let core: LinkPCCore
    private let serverNonce = LinkCrypto.newNonce()
    private var macHello: LinkHello?
    private var code: String?
    package private(set) var isReady = false
    package var macPub: String? { macHello?.pub }
    private let uptime: () -> Int

    package init(core: LinkPCCore, uptime: @escaping () -> Int = { Int(ProcessInfo.processInfo.systemUptime) }) {
        self.core = core; self.uptime = uptime
    }

    private func fail(_ code: String, _ message: String, close: UInt16, extra: (Int?, Int?) = (nil, nil)) -> [Output] {
        [.send(LinkCodec.encode(.error(code: code, message: message, attemptsLeft: extra.0, retryAfter: extra.1))), .close(close)]
    }

    package mutating func handle(_ text: String, now: Date = Date()) -> [Output] {
        let frame: LinkFrame
        do { frame = try LinkCodec.decode(text) } catch {
            return fail("protocol", "Кадр не разобран", close: LinkWire.Close.protocolError)
        }
        switch frame.message {
        case .hello(let hello) where macHello == nil:
            guard hello.v >= 1 else { return fail("bad-version", "Версия протокола не поддерживается", close: LinkWire.Close.protocolError) }
            guard LinkCrypto.data(fromBase64url: hello.pub)?.count == 32, LinkCrypto.data(fromBase64url: hello.nonce) != nil else {
                return fail("protocol", "Нет ключа или nonce", close: LinkWire.Close.protocolError)
            }
            macHello = hello
            let message = LinkCrypto.message(.server, macPub: hello.pub, pcPub: core.key.publicKey, clientNonce: hello.nonce, serverNonce: serverNonce)
            let reply = LinkHello(role: "pc", app: "Mac Utils Share", version: core.version, name: core.name, pub: core.key.publicKey,
                                  nonce: serverNonce, paired: core.isKnown(hello.pub), sig: core.key.sign(link: message))
            return [.send(LinkCodec.encode(.hello(reply)))]

        case .auth(let sig):
            guard let mac = macHello, !isReady else { return fail("protocol", "auth до hello", close: LinkWire.Close.protocolError) }
            guard core.isKnown(mac.pub) else { return fail("unknown-key", "Этот Mac не связан с ПК", close: LinkWire.Close.auth) }
            guard LinkCrypto.verify(pub: mac.pub, sig: sig, message: clientMessage(mac)) else {
                return fail("bad-signature", "Подпись Mac не сходится", close: LinkWire.Close.auth)
            }
            return becomeReady(mac)

        case let .pair(proof, sig):
            guard let mac = macHello, !isReady else { return fail("protocol", "pair до hello", close: LinkWire.Close.protocolError) }
            let pairMessage = LinkCrypto.message(.pairMac, macPub: mac.pub, pcPub: core.key.publicKey, clientNonce: mac.nonce, serverNonce: serverNonce)
            switch core.checkPair(proof: proof, message: pairMessage, now: now) {
            case .closed: return fail("pairing-closed", "На ПК не открыто «Связать с Mac»", close: LinkWire.Close.pairing)
            case .blocked(let after): return fail("pairing-blocked", "Слишком много неверных кодов", close: LinkWire.Close.pairing, extra: (nil, after))
            case .badCode(let left): return fail("bad-code", "Неверный код", close: LinkWire.Close.pairing, extra: (left, nil))
            case .ok: break
            }
            guard LinkCrypto.verify(pub: mac.pub, sig: sig, message: clientMessage(mac)),
                  let code = core.completePairing(macPub: mac.pub, macName: mac.name) else {
                return fail("bad-signature", "Подпись Mac не сходится", close: LinkWire.Close.auth)
            }
            let pcMessage = LinkCrypto.message(.pairPC, macPub: mac.pub, pcPub: core.key.publicKey, clientNonce: mac.nonce, serverNonce: serverNonce)
            return [.send(LinkCodec.encode(.paired(proof: LinkCrypto.proof(code: code, message: pcMessage))))] + becomeReady(mac)

        case .ping(let t):
            return isReady ? [.send(LinkCodec.encode(.pong(t: t), id: frame.id))] : []

        default:
            // Незнакомые и прочие сообщения — без ответа и без разрыва.
            return []
        }
    }

    private func clientMessage(_ mac: LinkHello) -> String {
        LinkCrypto.message(.client, macPub: mac.pub, pcPub: core.key.publicKey, clientNonce: mac.nonce, serverNonce: serverNonce)
    }

    private mutating func becomeReady(_ mac: LinkHello) -> [Output] {
        isReady = true
        return [.send(LinkCodec.encode(.ready)), .send(LinkCodec.encode(.status(core.status(uptime: uptime())))),
                .ready(macPub: mac.pub, macName: mac.name)]
    }
}

/// Двойник ПК на 127.0.0.1 (самопроверка и тесты): WebSocket-сервер Network.framework только на петле — снаружи к нему
/// не подключиться, брандмауэр macOS петлю не фильтрует. Порт — свободный, выбирает система.
package final class LinkTwinServer: @unchecked Sendable {
    package let core: LinkPCCore
    private let queue = DispatchQueue(label: "com.mruzhynskyi.macutils.link.twin")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: (LinkConnection, LinkPCSession)] = [:]
    /// Тесты: отвечать на `ping` (false — ПК «завис», Mac должен заметить тишину).
    package var answersPing = true
    package private(set) var port: UInt16 = 0
    /// Сколько раз Mac дошёл до `ready` (каждое переподключение +1).
    package private(set) var readyCount = 0
    package var onReady: ((String) -> Void)?

    package init(core: LinkPCCore) { self.core = core }

    /// Поднять на 127.0.0.1. `port` 0 — любой свободный; после `stop()` можно поднять на том же порту.
    package func start(port wanted: UInt16 = 0) throws {
        let parameters = LinkConnection.websocketParameters()
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        // Только петля: локальный адрес задаётся явно, а не «все интерфейсы».
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: wanted) ?? .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failure: NWError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { listener.cancel(); throw NWError.posix(.ETIMEDOUT) }
        if let failure { listener.cancel(); throw failure }
        self.listener = listener
        port = listener.port?.rawValue ?? 0
    }

    /// Остановить: слушатель и все соединения (как выключенный ПК).
    package func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            for (c, _) in sessions.values { c.cancel() }
            sessions = [:]
        }
    }

    /// Оборвать соединения без кадра close, слушатель оставить (как обрыв сети).
    package func dropConnections() {
        queue.sync {
            for (c, _) in sessions.values { c.cancel() }
            sessions = [:]
        }
    }

    package var connectionCount: Int { queue.sync { sessions.count } }

    private func accept(_ nw: NWConnection) {
        // Только петля: всё остальное — сразу закрыть.
        if case let .hostPort(host, _) = nw.endpoint, !"\(host)".hasPrefix("127.0.0.1"), !"\(host)".hasPrefix("::1") {
            nw.cancel(); return
        }
        let connection = LinkConnection(nw, queue: queue)
        let id = ObjectIdentifier(connection)
        sessions[id] = (connection, LinkPCSession(core: core))
        connection.onText = { [weak self] text in self?.handle(text, id: id) }
        connection.onClose = { [weak self] _, _ in self?.sessions[id] = nil }
        connection.start()
    }

    private func handle(_ text: String, id: ObjectIdentifier) {
        guard var (connection, session) = sessions[id] else { return }
        if !answersPing, case .ping? = (try? LinkCodec.decode(text))?.message { return }
        let outputs = session.handle(text)
        sessions[id] = (connection, session)
        for output in outputs {
            switch output {
            case .send(let s): connection.send(s)
            case .close(let code): connection.close(code: code)
            case .ready(let pub, _):
                readyCount += 1
                // Новое подключение того же Mac заменяет старое.
                for (other, (c, s)) in sessions where other != id && s.isReady && s.macPub == pub {
                    c.close(code: LinkWire.Close.replaced)
                }
                onReady?(pub)
            }
        }
    }
}
