import Combine
import Foundation
import MUCore

/// Клиент MU Link на Mac: подключается к ПК (сам Mac ничего не слушает), сопряжение кодом, пульс, `status`, повторы.
/// Сеть и состояние — на своей очереди; `@Published` меняются на главной.
package final class LinkClient: ObservableObject, @unchecked Sendable {
    /// Почему нет связи.
    package enum Reason: Equatable, Sendable {
        /// ПК не отвечает (выключен, нет света, Share не запущен, Tailscale не подключён).
        case unreachable(String?)
        /// По адресу отвечает ПК с другим ключом.
        case otherPC
        /// ПК не знает этот Mac (там забыли пару или переустановили Share) — нужно связать заново.
        case forgotten
        /// Ошибка протокола или подписи.
        case protocolError(String)

        package var text: String {
            switch self {
            case .unreachable(let detail): return detail.map { "ПК не отвечает (\($0))" } ?? "ПК не отвечает"
            case .otherPC: return "По этому адресу другой ПК"
            case .forgotten: return "ПК не знает этот Mac — свяжите заново"
            case .protocolError(let message): return "Ошибка связи: \(message)"
            }
        }

        /// Повторять ли сами: «другой ПК» тоже повторяем (адрес мог временно занять другой узел), «забыли» — нет.
        var retries: Bool { if case .forgotten = self { return false }; return true }
    }

    package enum State: Equatable, Sendable {
        case notPaired
        case pairing
        case connecting(attempt: Int)
        /// На связи; отклик `ping → pong`, мс (nil — ещё не измерен).
        case online(pingMs: Int?)
        case offline(Reason, retryIn: TimeInterval?)

        package var text: String {
            switch self {
            case .notPaired: return "Нет пары"
            case .pairing: return "Связываю…"
            case .connecting: return "Подключаюсь…"
            case .online(let ms): return ms.map { "На связи · \($0) мс" } ?? "На связи"
            case .offline(let reason, _): return reason.text
            }
        }
    }

    /// Итог сопряжения для окна настроек.
    package enum PairOutcome: Equatable, Sendable {
        case paired(pcName: String)
        case badCode(attemptsLeft: Int?)
        case blocked(retryAfter: Int?)
        case closed
        case failed(Reason)

        package var text: String {
            switch self {
            case .paired(let name): return "Связано с «\(name)»"
            case .badCode(let left): return left.map { "Неверный код, осталось попыток: \($0)" } ?? "Неверный код"
            case .blocked(let after): return "Слишком много неверных кодов. Попробуйте через \(((after ?? 300) + 59) / 60) мин"
            case .closed: return "На ПК не открыто «Связать с Mac» или код истёк"
            case .failed(let reason): return reason.text
            }
        }
    }

    @Published package private(set) var state: State = .notPaired
    @Published package private(set) var status: LinkStatus?
    @Published package private(set) var pair: LinkPair?

    package let signer: LinkSigner
    package let appVersion: String
    package let macName: String
    private let storage: LinkPairStorage
    private let retryDelays: [TimeInterval]
    private let pingInterval: TimeInterval
    private let silenceTimeout: TimeInterval
    private let handshakeTimeout: TimeInterval
    /// Порт ПК (в самопроверке и тестах — порт двойника).
    private let port: UInt16
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "com.mruzhynskyi.macutils.link.client")

    // Всё ниже — только на `queue`.
    private var running = false
    private var connection: LinkConnection?
    private var generation = 0
    private var attempt = 0
    private var retryTimer: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private var handshakeTimer: DispatchWorkItem?
    private var lastSeen = Date()
    private var pings: [String: Date] = [:]
    private var pendingPair: (host: String, code: String, done: (PairOutcome) -> Void)?
    private var phase = Phase.idle
    private var lastError: LinkMessage?
    private var qState: State = .notPaired

    private enum Phase { case idle, waitHello(nonce: String), waitPaired(pc: LinkHello, nonce: String), waitReady(pc: LinkHello), ready }

    package init(signer: LinkSigner, storage: LinkPairStorage, appVersion: String, macName: String,
                 port: UInt16 = LinkWire.port, retryDelays: [TimeInterval] = LinkWire.retryDelays,
                 pingInterval: TimeInterval = LinkWire.pingInterval, silenceTimeout: TimeInterval = LinkWire.silenceTimeout,
                 handshakeTimeout: TimeInterval = LinkWire.handshakeTimeout, log: @escaping (String) -> Void = { Log.link.info("\($0, privacy: .public)") }) {
        self.signer = signer; self.storage = storage; self.appVersion = appVersion; self.macName = macName; self.port = port
        self.retryDelays = retryDelays.isEmpty ? LinkWire.retryDelays : retryDelays
        self.pingInterval = pingInterval; self.silenceTimeout = silenceTimeout; self.handshakeTimeout = handshakeTimeout; self.log = log
        let stored = storage.load()
        pair = stored
        state = stored == nil ? .notPaired : .connecting(attempt: 0)
        qState = state
    }

    // MARK: - Управление

    /// Начать держать связь с сохранённым ПК (если пара есть).
    package func start() {
        queue.async { [self] in
            running = true
            if storage.load() != nil, connection == nil, pendingPair == nil { connect() } else if storage.load() == nil { setState(.notPaired) }
        }
    }

    package func stop() {
        queue.sync { running = false; teardown(); retryTimer?.cancel(); retryTimer = nil }
    }

    /// Повторить сейчас (пробуждение Mac, смена сети, кнопка «Повторить»).
    package func retryNow() {
        queue.async { [self] in
            guard running, pendingPair == nil, storage.load() != nil else { return }
            if case .online = qState { return }
            retryTimer?.cancel(); retryTimer = nil
            teardown()
            connect()
        }
    }

    /// Забыть ПК: пара стирается, связь рвётся.
    package func forget() {
        queue.async { [self] in
            teardown(); retryTimer?.cancel(); retryTimer = nil
            try? storage.clear()
            publish { $0.pair = nil; $0.status = nil }
            setState(.notPaired)
            log("пара забыта")
        }
    }

    /// Сопряжение: адрес ПК и код с экрана ПК. Текущая связь (если была) рвётся; при неудаче старая пара остаётся.
    package func pair(host: String, code: String, completion: @escaping @Sendable (PairOutcome) -> Void) {
        queue.async { [self] in
            let digits = code.filter(\.isNumber)
            guard digits.count == 6, LinkWire.url(host: host, port: port) != nil else {
                DispatchQueue.main.async { completion(.failed(.protocolError(digits.count == 6 ? "неверный адрес" : "код — 6 цифр"))) }
                return
            }
            teardown(); retryTimer?.cancel(); retryTimer = nil
            pendingPair = (host.trimmingCharacters(in: .whitespacesAndNewlines), digits, { outcome in DispatchQueue.main.async { completion(outcome) } })
            setState(.pairing)
            open(host: host)
        }
    }

    package func pair(host: String, code: String) async -> PairOutcome {
        await withCheckedContinuation { c in pair(host: host, code: code) { c.resume(returning: $0) } }
    }

    // MARK: - Подключение

    private func connect() {
        guard let stored = storage.load() else { setState(.notPaired); return }
        attempt += 1
        setState(.connecting(attempt: attempt))
        open(host: stored.host)
    }

    private func open(host: String) {
        guard let url = LinkWire.url(host: host, port: port) else { fail(.protocolError("неверный адрес"), detail: nil); return }
        generation += 1
        let gen = generation
        let c = LinkConnection(url: url, queue: queue)
        connection = c
        lastError = nil
        c.onReady = { [weak self] in self?.opened(gen) }
        c.onText = { [weak self] text in self?.received(text, gen) }
        c.onClose = { [weak self] code, error in self?.closed(gen, code: code, error: error) }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen, !self.isReady else { return }
            self.log("рукопожатие не закончилось за \(Int(self.handshakeTimeout)) с")
            self.fail(.unreachable("нет ответа"), detail: nil)
        }
        handshakeTimer = timer
        queue.asyncAfter(deadline: .now() + handshakeTimeout, execute: timer)
        c.start()
    }

    private var isReady: Bool { if case .ready = phase { return true }; return false }

    private func opened(_ gen: Int) {
        guard gen == generation, let c = connection else { return }
        let nonce = LinkCrypto.newNonce()
        phase = .waitHello(nonce: nonce)
        lastSeen = Date()
        c.send(LinkCodec.encode(.hello(LinkHello(role: "mac", app: "Mac Utils", version: appVersion, name: macName,
                                                 pub: signer.publicKey, nonce: nonce))))
    }

    private func received(_ text: String, _ gen: Int) {
        guard gen == generation, let c = connection else { return }
        lastSeen = Date()
        let frame: LinkFrame
        do { frame = try LinkCodec.decode(text) } catch {
            log("кадр не разобран: \(error)")
            c.close(code: LinkWire.Close.protocolError)
            fail(.protocolError("кадр не разобран"), detail: nil)
            return
        }
        switch (phase, frame.message) {
        case let (.waitHello(nonce), .hello(pc)):
            guard pc.v >= 1, pc.role == "pc" else { return protocolFailure(c, "версия или роль ПК") }
            let serverMessage = LinkCrypto.message(.server, macPub: signer.publicKey, pcPub: pc.pub, clientNonce: nonce, serverNonce: pc.nonce)
            guard let sig = pc.sig, LinkCrypto.verify(pub: pc.pub, sig: sig, message: serverMessage) else {
                return protocolFailure(c, "подпись ПК не сходится", close: LinkWire.Close.auth)
            }
            let clientSig = signer.sign(link: LinkCrypto.message(.client, macPub: signer.publicKey, pcPub: pc.pub, clientNonce: nonce, serverNonce: pc.nonce))
            if let pending = pendingPair {
                let proof = LinkCrypto.proof(code: pending.code, message: LinkCrypto.message(.pairMac, macPub: signer.publicKey, pcPub: pc.pub,
                                                                                             clientNonce: nonce, serverNonce: pc.nonce))
                phase = .waitPaired(pc: pc, nonce: nonce)
                c.send(LinkCodec.encode(.pair(proof: proof, sig: clientSig)))
            } else {
                guard let stored = storage.load() else { return }
                guard pc.pub == stored.pcKey else {
                    c.close(code: LinkWire.Close.auth)
                    return fail(.otherPC, detail: "ключ \(LinkCrypto.fingerprint(pc.pub) ?? "?")")
                }
                guard pc.paired != false else {
                    c.close(code: LinkWire.Close.auth)
                    return fail(.forgotten, detail: nil)
                }
                phase = .waitReady(pc: pc)
                c.send(LinkCodec.encode(.auth(sig: clientSig)))
            }

        case let (.waitPaired(pc, nonce), .paired(proof)):
            guard let pending = pendingPair,
                  LinkCrypto.proofMatches(proof, code: pending.code, message: LinkCrypto.message(.pairPC, macPub: signer.publicKey, pcPub: pc.pub,
                                                                                               clientNonce: nonce, serverNonce: pc.nonce)) else {
                return protocolFailure(c, "ПК не подтвердил код", close: LinkWire.Close.pairing)
            }
            let newPair = LinkPair(host: pending.host, pcKey: pc.pub, pcName: pc.name)
            do { try storage.save(newPair) } catch {
                log("пару не сохранить: \(error)")
                return protocolFailure(c, "пару не сохранить")
            }
            pendingPair = nil
            publish { $0.pair = newPair }
            log("связано с «\(pc.name)», ключ \(LinkCrypto.fingerprint(pc.pub) ?? "?")")
            pending.done(.paired(pcName: pc.name))
            phase = .waitReady(pc: pc)

        case let (.waitReady(pc), .ready):
            phase = .ready
            handshakeTimer?.cancel(); handshakeTimer = nil
            attempt = 0
            if var stored = storage.load(), stored.pcName != pc.name, !pc.name.isEmpty {
                stored.pcName = pc.name
                try? storage.save(stored)
                publish { $0.pair = stored }
            }
            setState(.online(pingMs: nil))
            log("на связи с «\(pc.name)»")
            startPing()

        case (.ready, .ping(let t)):
            c.send(LinkCodec.encode(.pong(t: t), id: frame.id))

        case (.ready, .pong):
            guard let sent = pings.removeValue(forKey: frame.id) else { return }
            let ms = max(0, Int((Date().timeIntervalSince(sent) * 1000).rounded()))
            setState(.online(pingMs: ms))

        case (_, .status(let s)):
            publish { $0.status = s }

        case (_, .error(let code, let message, _, _)):
            lastError = frame.message
            log("ПК: ошибка \(code) — \(message)")

        default:
            // Незнакомые сообщения (новая версия ПК) и не к месту пришедшие — молча мимо.
            break
        }
    }

    private func protocolFailure(_ c: LinkConnection, _ message: String, close: UInt16 = LinkWire.Close.protocolError) {
        c.close(code: close)
        fail(.protocolError(message), detail: nil)
    }

    private func closed(_ gen: Int, code: UInt16?, error: String?) {
        guard gen == generation else { return }
        let wasReady = isReady
        connection = nil
        stopTimers()
        phase = .idle
        if let pending = pendingPair {
            pendingPair = nil
            let outcome: PairOutcome
            switch lastError {
            case let .error("bad-code", _, left, _)?: outcome = .badCode(attemptsLeft: left)
            case let .error("pairing-blocked", _, _, after)?: outcome = .blocked(retryAfter: after)
            case .error("pairing-closed", _, _, _)?: outcome = .closed
            case let .error(code, message, _, _)?: outcome = .failed(.protocolError(message.isEmpty ? code : message))
            default: outcome = .failed(.unreachable(error))
            }
            log("сопряжение не вышло: \(outcome.text)")
            pending.done(outcome)
            afterPairing()
            return
        }
        if case let .error(errCode, _, _, _)? = lastError, errCode == "unknown-key" {
            return fail(.forgotten, detail: nil)
        }
        let reason: Reason = code == LinkWire.Close.replaced ? .protocolError("подключился другой экземпляр") : .unreachable(error)
        log(wasReady ? "связь потеряна (код \(code.map(String.init) ?? "—"), \(error ?? "без ошибки сети"))" : "не подключиться: \(error ?? "закрыто")")
        fail(reason, detail: nil)
    }

    /// После неудачного сопряжения: вернуться к старой паре (если была).
    private func afterPairing() {
        if storage.load() != nil, running { scheduleRetry(.unreachable(nil), immediate: true) } else { setState(storage.load() == nil ? .notPaired : .offline(.unreachable(nil), retryIn: nil)) }
    }

    private func fail(_ reason: Reason, detail: String?) {
        if let detail { log("\(reason.text): \(detail)") }
        teardown()
        if let pending = pendingPair {
            pendingPair = nil
            pending.done(.failed(reason))
            afterPairing()
            return
        }
        scheduleRetry(reason, immediate: false)
    }

    private func scheduleRetry(_ reason: Reason, immediate: Bool) {
        guard running, reason.retries, storage.load() != nil else {
            setState(storage.load() == nil ? .notPaired : .offline(reason, retryIn: nil))
            return
        }
        let delay = immediate ? 0 : retryDelays[min(max(attempt - 1, 0), retryDelays.count - 1)]
        setState(.offline(reason, retryIn: delay))
        retryTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.connection == nil, self.pendingPair == nil else { return }
            self.retryTimer = nil
            self.connect()
        }
        retryTimer = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        let gen = generation
        timer.setEventHandler { [weak self] in
            guard let self, gen == self.generation, let c = self.connection else { return }
            if Date().timeIntervalSince(self.lastSeen) > self.silenceTimeout {
                self.log("тишина дольше \(Int(self.silenceTimeout)) с — переподключаюсь")
                c.close(code: LinkWire.Close.timeout)
                self.fail(.unreachable("нет пульса"), detail: nil)
                return
            }
            let id = LinkCodec.newID()
            self.pings = self.pings.filter { Date().timeIntervalSince($0.value) < self.silenceTimeout }
            self.pings[id] = Date()
            c.send(LinkCodec.encode(.ping(t: Int64(Date().timeIntervalSince1970 * 1000)), id: id))
        }
        pingTimer = timer
        timer.resume()
    }

    private func stopTimers() {
        pingTimer?.cancel(); pingTimer = nil
        handshakeTimer?.cancel(); handshakeTimer = nil
        pings = [:]
    }

    private func teardown() {
        generation += 1
        stopTimers()
        phase = .idle
        if let c = connection { connection = nil; c.close(code: LinkWire.Close.normal) }
    }

    private func setState(_ s: State) {
        guard s != qState else { return }
        qState = s
        publish { $0.state = s }
    }

    private func publish(_ change: @escaping (LinkClient) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { change(self) } }
    }
}
