import AVFoundation
import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Код комнаты и адрес (без сети — для тестов).
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

enum ShareCode {
    static func random() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// Постоянный 10-значный ID этого Mac (как в AnyDesk): по нему к вам подключаются.
    static var myID: String {
        if let saved = UserDefaults.standard.string(forKey: Pref.shareID), saved.count == 10 { return saved }
        let id = String(Int.random(in: 1...9)) + (0..<9).map { _ in String(Int.random(in: 0...9)) }.joined()
        UserDefaults.standard.set(id, forKey: Pref.shareID)
        return id
    }

    /// Имя компьютера — его видит ведущий в запросе на подключение.
    static var myName: String { Host.current().localizedName ?? "Mac" }

    /// «123 456 7890» → «1234567890»; nil — не 10 (или старые 6) цифр.
    static func normalized(_ text: String) -> String? {
        let digits = text.filter(\.isNumber)
        return digits.count == 10 || digits.count == 6 ? digits : nil
    }

    /// Ретранслятор пускает только приложения Mac Utils — по этому заголовку. Токен mu-share-2 ставится,
    /// только если ретранслятор сам объявил его в `/version`; иначе mu-share-1 (старый протокол).
    static func request(_ url: URL, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(token ?? ShareRelay.token(for: url), forHTTPHeaderField: "X-MacUtils-Client")
        return request
    }

    static func display(_ code: String) -> String {
        if code.count == 10 {
            let chars = Array(code)
            return "\(String(chars[0..<3])) \(String(chars[3..<6])) \(String(chars[6..<10]))"
        }
        return code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    /// https://relay.example.dev → wss://relay.example.dev/room/123456?role=host
    static func url(server: String, code: String, role: String) -> URL? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("https://") { base = "wss://" + base.dropFirst(8) }
        if base.hasPrefix("http://") { base = "ws://" + base.dropFirst(7) }
        if !base.hasPrefix("ws://") && !base.hasPrefix("wss://") { base = "wss://" + base }
        var components = URLComponents(string: "\(base)/room/\(code)")
        var query = [URLQueryItem(name: "role", value: role)]
        if role == "viewer" {
            query += [URLQueryItem(name: "viewer", value: myID), URLQueryItem(name: "name", value: myName),
                      URLQueryItem(name: "h264", value: "1")]
        }
        components?.queryItems = query
        return components?.url
    }

    /// https://relay… → https://relay…/status?ids=…
    static func statusURL(server: String, ids: [String]) -> URL? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        return URL(string: "\(base)/status?ids=\(ids.joined(separator: ","))")
    }
}

/// Трансляция экрана по коду: ведущий шлёт кадры через ретранслятор (relay/), зрители по коду смотрят.
/// Только просмотр, без управления.
@MainActor
final class ScreenShare: NSObject, ObservableObject {
    static let shared = ScreenShare()

    enum State: Equatable {
        case idle
        case connecting
        case live(code: String, viewers: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Ретранслятор не объявил mu-share-2: работаем по-старому, личность зрителей не проверяется.
    @Published private(set) var relayWithoutKeys = false
    /// Keychain недоступен: ключ не сохранить, трансляция и просмотр идут по mu-share-1 без проверки ключом.
    @Published private(set) var keychainUnavailable = false
    /// Отпечаток этого Mac, как его вернул ретранслятор при последней проверке.
    @Published private(set) var myFingerprint: String?
    /// Нужен новый ID: этот закреплён за другим устройством.
    @Published private(set) var needsNewID = false
    /// Меняется при смене ID — чтобы страница перечитала его.
    @Published private(set) var idVersion = 0
    /// Подключение к ведущему прошло проверку ключом (а не старым протоколом).
    private var hostKeyed = false

    private var socket: URLSessionWebSocketTask?
    private var stream: SCStream?
    private var audioStream: SCStream?
    private var audioRefresh: Timer?
    private var heartbeat: Timer?
    private var sender: FrameSender?
    private var hud: NSPanel?

    static var server: String { UserDefaults.standard.string(forKey: Pref.shareServer) ?? "" }

    var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    // MARK: - Ведущий

    /// screen — сразу весь экран под курсором, без окна выбора (для «Команд»: macutils://share?screen).
    func start(screen: Bool = false) {
        guard state == .idle || isFailed else { return }
        guard !Self.server.isEmpty else {
            state = .failed("Сервер трансляции не настроен")
            return
        }
        guard Permissions.screenRecording else {
            state = .failed("Нужно разрешение «Запись экрана»")
            return
        }
        // Сначала — что показывать: системное окно выбора (экран, окно или программа).
        state = .connecting
        if screen {
            Task {
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                      let display = content.displays.first(where: { $0.displayID == (NSScreen.withMouse ?? NSScreen.main)?.displayID })
                        ?? content.displays.first else {
                    state = .failed("Не удалось начать захват экрана")
                    return
                }
                connect(filter: Self.displayFilter(display, content: content))
            }
            return
        }
        Picker.shared.choose { [weak self] filter in
            guard let self else { return }
            guard let filter else {
                self.state = .idle
                return
            }
            self.connect(filter: filter)
        }
    }

    private func connect(filter: SCContentFilter) {
        Task {
            // Комната — свой постоянный ID; занята — значит, трансляция с этим ID уже идёт.
            let code = ShareCode.myID
            needsNewID = false
            switch await openHostSocket() {
            case .busy:
                state = .failed(ShareErrorText.busyMessage(keychainUnavailable: keychainUnavailable))
                return
            case .refused(let errorCode, let message):
                needsNewID = ShareErrorText.needsNewID(errorCode)
                state = .failed(ShareErrorText.hostRefusal(code: errorCode, message: message))
                return
            case .failed(let status):
                state = .failed(Self.connectionMessage(status))
                return
            case .ok(let socket, let keyed):
                self.socket = socket
                hostKeyed = keyed
                // Панель запросов создаём заранее: её окно должно быть в фильтре захвата до первого запроса.
                ShareRequestQueue.shared.prepare()
                do {
                    try await beginCapture(filter: filter)
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    self.socket = nil
                    state = .failed("Не удалось начать захват экрана")
                    return
                }
                startHeartbeat(socket)
                state = .live(code: code, viewers: 0)
                ShareMarksOverlay.shared.attach(to: filter)
                listen(socket)
                showHUD()
            }
        }
    }

    static func connectionMessage(_ status: Int) -> String {
        switch status {
        case 0: return "Нет связи с сервером трансляции"
        case 429: return ShareErrorText.message(code: "rate-limited")
        case 426: return ShareErrorText.message(code: "upgrade-required")
        default: return "Сервер ответил \(status)"
        }
    }

    /// Возможности ретранслятора (mu-share-2 или нет); nil — нет связи.
    func probeRelay() async -> ShareRelay.Capability? {
        let capability = await ShareRelay.capability(server: Self.server)
        if let capability { relayWithoutKeys = capability == .legacy }
        return capability
    }

    private enum HostOpen {
        case ok(URLSessionWebSocketTask, keyed: Bool)
        case busy
        case refused(code: String, message: String)
        case failed(status: Int)
    }

    /// Выбор протокола: mu-share-2 только если relay его объявил и ключ лежит в Keychain; иначе — как mu-share-1 с понятным сообщением.
    func shouldUseKeys(_ capability: ShareRelay.Capability?) -> Bool {
        let keyed = ShareHandshake.useKeys(capability: capability, identity: .shared)
        if capability == .keyed && !keyed {
            if !keychainUnavailable { Toast.show(ShareIdentity.keychainUnavailableMessage, symbol: "key.slash", tint: .orange) }
            keychainUnavailable = true
            myFingerprint = nil
        } else if keyed {
            keychainUnavailable = false
        }
        return keyed
    }

    /// Подключение ведущего: по mu-share-2 (challenge → auth → authed), если ретранслятор его объявил, иначе по-старому.
    private func openHostSocket(retried: Bool = false) async -> HostOpen {
        let code = ShareCode.myID
        guard let url = ShareCode.url(server: Self.server, code: code, role: "host") else { return .failed(status: 0) }
        let keyedRelay = shouldUseKeys(await probeRelay())
        let socket = URLSession.shared.webSocketTask(with: ShareCode.request(url, token: keyedRelay ? ShareRelay.keyedToken : ShareRelay.legacyToken))
        socket.maximumMessageSize = 4 << 20
        socket.resume()
        if keyedRelay {
            switch await ShareHandshake.authenticateHost(socket, roomId: code, identity: .shared) {
            case .authed(let fp, let keyed):
                // Ключ создан и привязан к ID: теперь можно подписывать запросы `/status`.
                if keyed { ShareHistory.statusIdentity = .shared }
                myFingerprint = keyed ? (fp ?? ShareIdentity.fingerprint) : nil
                return .ok(socket, keyed: keyed)
            case .refused(let errorCode, let message):
                socket.cancel(with: .goingAway, reason: nil)
                return .refused(code: errorCode, message: message)
            case .failed(let status):
                socket.cancel(with: .goingAway, reason: nil)
                // 403 — ретранслятор откатили на версию без mu-share-2: спросим его возможности заново.
                if !retried, status == 403 || status == 426 {
                    ShareRelay.invalidate(server: Self.server)
                    return await openHostSocket(retried: true)
                }
                return status == 409 ? .busy : .failed(status: status)
            }
        }
        let status = await Self.handshake(socket)
        // 426 по mu-share-1: relay требует ключи, а `/version` не ответил — проверяем заново и пробуем mu-share-2.
        if !retried, status == 403 || status == 426 {
            socket.cancel(with: .goingAway, reason: nil)
            ShareRelay.invalidate(server: Self.server)
            return await openHostSocket(retried: true)
        }
        if status == 409 { return .busy }
        guard status == nil else { return .failed(status: status!) }
        return .ok(socket, keyed: false)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// nil — подключились; иначе HTTP-код ответа (0 — нет связи).
    private static func handshake(_ socket: URLSessionWebSocketTask) async -> Int? {
        await withCheckedContinuation { continuation in
            socket.sendPing { error in
                if error == nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: (socket.response as? HTTPURLResponse)?.statusCode ?? 0)
                }
            }
        }
    }

    /// Весь звук системы, кроме Mac Utils и программ, которые пользователь заглушил для трансляции.
    private static func audioFilter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let muted = Set(UserDefaults.standard.stringArray(forKey: Pref.shareMutedApps) ?? [])
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Звук часто играет не сама программа, а её помощник (Discord Helper, WebKit у Safari):
        // глушим и процессы с тем же началом bundle id, и те, за которые программа отвечает.
        let mutedPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { app in muted.contains { app.bundleIdentifier?.hasPrefix($0) == true } }
            .map(\.processIdentifier))
        let excluded = content.applications.filter { app in
            app.processID == ownPID
                || muted.contains { app.bundleIdentifier == $0 || app.bundleIdentifier.hasPrefix($0 + ".") }
                || mutedPIDs.contains(responsibility_get_pid_responsible_for_pid(app.processID))
        }
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    }

    private static func audioConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Картинка из этого потока не нужна — минимальный кадр раз в секунду.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        // 24 кГц моно — достаточно для речи и музыки фоном, ~48 КБ/с.
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 24_000
        config.channelCount = 1
        return config
    }

    /// Список заглушённых изменился или запустилась новая программа — обновляем фильтр звука.
    func refreshAudioFilter() {
        guard let audioStream else { return }
        Task {
            if let filter = try? await Self.audioFilter() { try? await audioStream.updateContentFilter(filter) }
        }
    }

    private func startAudioRefresh() {
        audioRefresh?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { ScreenShare.shared.refreshAudioFilter() }
        }
        RunLoop.main.add(timer, forMode: .common)
        audioRefresh = timer
    }

    private static func configure(_ config: SCStreamConfiguration, for filter: SCContentFilter) {
        // До 1600 точек по ширине — читаемо и не тяжело для сети.
        let pixels = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                            height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, 1600 / max(pixels.width, 1))
        config.width = max(2, Int(pixels.width * scale) / 2 * 2)
        config.height = max(2, Int(pixels.height * scale) / 2 * 2)
    }

    /// Сменить, что показываем, не прерывая трансляцию.
    func changeSource() {
        guard isLive, let stream else { return }
        Picker.shared.choose(for: stream) { filter in
            guard let filter else { return }
            let config = SCStreamConfiguration()
            Self.configure(config, for: filter)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = true
            config.queueDepth = 3
            ShareMarksOverlay.shared.attach(to: filter)
            Task {
                let filter = await self.prepared(filter)
                try? await stream.updateContentFilter(filter)
                try? await stream.updateConfiguration(config)
            }
        }
    }

    /// Весь экран: виден и интерфейс Mac Utils, кроме служебных окон эфира (метки зрителей, индикатор «Эфир»).
    static func displayFilter(_ display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let hidden = hiddenWindowNumbers
        return SCContentFilter(display: display, excludingWindows: content.windows.filter { hidden.contains(Int($0.windowID)) })
    }

    static var hiddenWindowNumbers: Set<Int> {
        Set([ShareMarksOverlay.shared.windowNumber, ScreenShare.shared.hud?.windowNumber, ShareRequestQueue.shared.windowNumber].compactMap { $0 })
    }

    /// Какой экран транслируем (nil — окно или программа).
    private var videoDisplayID: CGDirectDisplayID?

    /// Экран трансляции: на нём показываем панель запросов, чтобы ведущий её увидел.
    var broadcastScreen: NSScreen? {
        videoDisplayID.flatMap { id in NSScreen.screens.first { $0.displayID == id } }
    }

    /// Экран из системного окна выбора — пересобираем фильтр: окно выбора прячет Mac Utils целиком,
    /// а зрителю нужен и его интерфейс.
    private func prepared(_ filter: SCContentFilter) async -> SCContentFilter {
        videoDisplayID = nil
        guard filter.style == .display,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return filter }
        var display: SCDisplay?
        if #available(macOS 15.2, *) {
            display = filter.includedDisplays.first.flatMap { chosen in content.displays.first { $0.displayID == chosen.displayID } }
        }
        if display == nil {
            let size = filter.contentRect.size
            display = content.displays.first { abs(CGFloat($0.width) - size.width) < 2 && abs(CGFloat($0.height) - size.height) < 2 }
        }
        guard let display else { return filter }
        videoDisplayID = display.displayID
        return Self.displayFilter(display, content: content)
    }

    /// Появилось или пропало служебное окно — обновляем, что исключено из картинки.
    func refreshVideoFilter() {
        guard let id = videoDisplayID, let stream else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  let display = content.displays.first(where: { $0.displayID == id }) else { return }
            try? await stream.updateContentFilter(Self.displayFilter(display, content: content))
        }
    }

    private func beginCapture(filter: SCContentFilter) async throws {
        let filter = await prepared(filter)
        let config = SCStreamConfiguration()
        Self.configure(config, for: filter)
        // H.264 (аппаратно): 30 кадров в секунду и формат, который кодек берёт без пересчёта.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 3
        guard let socket else { throw CocoaError(.featureUnsupported) }
        let sender = FrameSender(socket: socket)
        let stream = SCStream(filter: filter, configuration: config, delegate: sender)
        try stream.addStreamOutput(sender, type: .screen, sampleHandlerQueue: sender.queue)
        // Звук — отдельным потоком: из него можно убрать выбранные программы (чтобы не дублировать лишнее).
        if UserDefaults.standard.bool(forKey: Pref.shareAudio) {
            let audioStream = SCStream(filter: try await Self.audioFilter(), configuration: Self.audioConfiguration(), delegate: sender)
            try audioStream.addStreamOutput(sender, type: .audio, sampleHandlerQueue: sender.audioQueue)
            try await audioStream.startCapture()
            self.audioStream = audioStream
            startAudioRefresh()
        }
        try await stream.startCapture()
        self.stream = stream
        self.sender = sender
    }


    private func startHeartbeat(_ socket: URLSessionWebSocketTask) {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            socket.send(.string(#"{"type":"heartbeat"}"#)) { error in
                guard let error else { return }
                Log.capture.error("Трансляция: heartbeat не ушёл: \(error.localizedDescription, privacy: .public) close=\(socket.closeCode.rawValue)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.connectionLost(socket)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func listen(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.socket === socket else { return }
                    switch result {
                    case .success(.string(let text)):
                        // Метка или рисунок зрителя — на экран ведущего.
                        if let mark = ShareMark.parse(text) { ShareMarksOverlay.shared.show(mark) }
                        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                            switch json["type"] as? String {
                            case "request":
                                if let request = ShareRequest.parse(json) { self.handle(request) }
                            case "cancelled":
                                let rid = json["rid"] as? String
                                ShareRequestQueue.shared.remove(key: rid ?? "id:" + (json["viewer"] as? String ?? ""))
                            case "error":
                                // Например replaced: этот ID занял другой экземпляр того же устройства.
                                let code = json["code"] as? String ?? "unknown"
                                self.stop(reason: ShareErrorText.message(code: code, relayMessage: json["message"] as? String))
                                return
                            case "game":
                                let viewer = json["from"] as? String ?? ""
                                ShareGame.shared.receive(json, peer: viewer, name: json["name"] as? String ?? "",
                                                         transport: self.gameTransport(to: viewer))
                            case "viewers":
                                let raw = json["list"] as? [[String: Any]] ?? []
                                self.watchers = raw.compactMap { $0["name"] as? String }
                                self.audience = raw.compactMap { item in
                                    guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                                    return Watcher(id: id, name: item["name"] as? String ?? "")
                                }
                                // Соперник по игре ушёл из трансляции — партия закончена.
                                let game = ShareGame.shared
                                if game.isActive, game.peer != "host", !self.audience.contains(where: { $0.id == game.peer }) {
                                    game.peerGone(game.peer)
                                }
                                // Смотрит старая версия (без H.264) — дополнительно шлём ей кадры JPEG.
                                self.sender?.legacyFrames = raw.contains { ($0["h264"] as? Bool) != true }
                            default:
                                break
                            }
                        }
                        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                           json["type"] as? String == "viewers", let count = json["count"] as? Int,
                           case .live(let code, _) = self.state {
                            self.state = .live(code: code, viewers: count)
                            // Новый зритель сразу получает картинку, даже если экран не меняется.
                            self.sender?.resendLast()
                        }
                        self.listen(socket)
                    case .success:
                        self.listen(socket)
                    case .failure(let error):
                        Log.capture.error("Трансляция: приём оборвался: \(error.localizedDescription, privacy: .public) close=\(socket.closeCode.rawValue) reason=\(String(data: socket.closeReason ?? Data(), encoding: .utf8) ?? "", privacy: .public)")
                        self.connectionLost(socket)
                    }
                }
            }
        }
    }

    /// Кто сейчас смотрит (имена компьютеров).
    @Published private(set) var watchers: [String] = []
    struct Watcher: Identifiable, Equatable { let id: String; let name: String }
    /// Зрители с ID — для приглашения в игру.
    @Published private(set) var audience: [Watcher] = []

    /// Сыграть в крестики-нолики с этим зрителем.
    func playGame(with watcher: Watcher) {
        ShareGame.shared.invite(peer: watcher.id, name: watcher.name, transport: gameTransport(to: watcher.id))
    }

    /// Сообщения игры ведущего — ретранслятор доставит только этому зрителю.
    func gameTransport(to viewer: String) -> ([String: Any]) -> Void {
        { [weak self] fields in
            var fields = fields
            fields["to"] = viewer
            fields["name"] = ShareCode.myName
            guard let text = ShareGame.text(fields) else { return }
            self?.socket?.send(.string(text)) { _ in }
        }
    }
    /// Зритель просится посмотреть: правило решения — в `ShareRules.decide`. Спрашиваем немодально, через очередь.
    private func handle(_ request: ShareRequest) {
        switch ShareRules.decide(request, trust: .live()) {
        case .accept:
            answer(request, accept: true)
        case .ask(let prompt):
            let item = ShareRequestQueue.Item(request: request, prompt: prompt) { [weak self] reply in
                guard let self, self.isLive else { return }
                let accept = ShareRules.apply(reply, to: request, prompt: prompt) { id, name, pub in
                    ShareHistory.shared.trust(id, name: name, pub: pub)
                }
                self.answer(request, accept: accept)
            }
            ShareRequestQueue.shared.add(item)
        }
    }

    private func answer(_ request: ShareRequest, accept: Bool) {
        let hostSig = accept && hostKeyed ? ShareRules.hostSignature(for: request, roomId: ShareCode.myID, identity: .shared) : nil
        if let message = Self.answerMessage(viewer: request.viewer, accept: accept, rid: request.rid, hostSig: hostSig) {
            socket?.send(.string(message)) { _ in }
        }
        if accept { sender?.resendLast() }
    }

    /// JSON ответа ведущего; значения экранирует JSONSerialization, а не подстановка в строку.
    static func answerMessage(viewer: String, accept: Bool, rid: String? = nil, hostSig: String? = nil) -> String? {
        var object: [String: Any] = ["type": accept ? "accept" : "decline", "viewer": viewer, "name": ShareCode.myName]
        if let rid { object["rid"] = rid }
        if let hostSig { object["hostSig"] = hostSig }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Идёт переподключение к серверу (трансляция не остановлена).
    @Published private(set) var reconnecting = false

    /// Связь оборвалась: захват не останавливаем, переподключаемся с тем же ID.
    /// Зрители остаются на месте — сервер ждёт ведущего до 45 секунд.
    func connectionLost(_ socket: URLSessionWebSocketTask) {
        guard isLive, self.socket === socket, !reconnecting else { return }
        reconnecting = true
        heartbeat?.invalidate()
        heartbeat = nil
        socket.cancel(with: .goingAway, reason: nil)
        self.socket = nil
        Log.capture.info("Трансляция: переподключаюсь")
        Task {
            for delay in [1, 2, 3, 5, 8, 10, 15] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard isLive, reconnecting else { return }
                switch await openHostSocket() {
                case .ok(let fresh, let keyed):
                    hostKeyed = keyed
                    self.socket = fresh
                    sender?.replace(fresh)
                    listen(fresh)
                    startHeartbeat(fresh)
                    sender?.resendLast()
                    reconnecting = false
                    Log.capture.info("Трансляция: переподключено")
                    return
                case .refused(let code, let message) where ShareErrorText.needsNewID(code):
                    // ID за это время закрепили за другим устройством: повторять бессмысленно.
                    reconnecting = false
                    needsNewID = true
                    stop(reason: message)
                    return
                case .busy, .refused, .failed:
                    continue
                }
            }
            reconnecting = false
            stop(reason: "Связь с сервером прервалась")
        }
    }

    /// Для проверки: оборвать связь, как при сбое сети (macutils://share-drop).
    func simulateDrop() {
        socket?.cancel(with: .goingAway, reason: nil)
    }

    func stop(reason: String? = nil) {
        reconnecting = false
        watchers = []
        audience = []
        if ShareGame.shared.peer != "host" { ShareGame.shared.peerGone() }
        ShareRequestQueue.shared.removeAll()
        hostKeyed = false
        Picker.shared.reset()
        ShareMarksOverlay.shared.detach()
        let stream = self.stream
        let audioStream = self.audioStream
        self.stream = nil
        self.audioStream = nil
        audioRefresh?.invalidate()
        audioRefresh = nil
        heartbeat?.invalidate()
        heartbeat = nil
        Task { try? await audioStream?.stopCapture() }
        sender = nil
        Task { try? await stream?.stopCapture() }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        hud?.orderOut(nil)
        hud = nil
        state = reason.map { .failed($0) } ?? .idle
    }

    /// «Получить новый ID»: освобождаем старый на сервере (если соединение с ключом), меняем ключ и ID.
    /// Старый ID перестаёт работать — друзьям нужно сообщить новый.
    func renewID() {
        let old = hostKeyed ? socket : nil
        Task {
            if let old {
                // Отвязать ID: relay сотрёт владельца и закроет соединение. Сокет отцепляем заранее, чтобы
                // обрыв не запустил переподключение.
                self.socket = nil
                try? await old.send(.string(ShareHandshake.releaseMessage))
                try? await Task.sleep(nanoseconds: 300_000_000)
                old.cancel(with: .normalClosure, reason: nil)
            }
            stop()
            ShareIdentity.reset()
            UserDefaults.standard.removeObject(forKey: Pref.shareID)
            _ = ShareCode.myID
            myFingerprint = nil
            needsNewID = false
            idVersion += 1
            Toast.show("Новый ID: \(ShareCode.display(ShareCode.myID))", symbol: "arrow.triangle.2.circlepath")
        }
    }

    /// Подтверждение перед сменой ID (действие необратимо).
    func confirmRenewID() {
        let alert = NSAlert()
        alert.messageText = "Получить новый ID?"
        alert.informativeText = "Трансляция остановится, ключ этого Mac и ID будут заменены. Старый ID перестанет работать: друзьям нужно сообщить новый."
        alert.addButton(withTitle: "Получить новый ID")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { renewID() }
    }

    func copyCode() {
        guard case .live(let code, _) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        Toast.show("Код \(ShareCode.display(code)) скопирован", symbol: "doc.on.doc.fill")
    }

    private func showHUD() {
        guard let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        let host = FirstMouseHostingView(rootView: ShareHUD(share: self))
        let size = host.fittingSize
        // Правый верхний угол, под строкой меню — не мешает.
        let panel = HUDPanel(contentRect: NSRect(x: screen.visibleFrame.maxX - size.width - 8,
                                                 y: screen.visibleFrame.maxY - size.height - 6,
                                                 width: size.width, height: size.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.orderFrontRegardless()
        hud = panel
        refreshVideoFilter()
    }
}

/// Маленький индикатор эфира в углу (в саму трансляцию не попадает): точка и «Эфир»;
/// при наведении — код, зрители и «Стоп».
private struct ShareHUD: View {
    @ObservedObject var share: ScreenShare
    @ObservedObject private var queue = ShareRequestQueue.shared
    @State private var expanded = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 6, height: 6)
            if case .live(let code, let viewers) = share.state {
                if expanded {
                    Button { share.copyCode() } label: {
                        Text(ShareCode.display(code)).font(.caption.monospacedDigit().weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Скопировать код")
                    Label("\(viewers)", systemImage: "eye").font(.caption2).foregroundStyle(.secondary)
                    if !queue.items.isEmpty { requestsButton }
                    Button { share.changeSource() } label: { Image(systemName: "rectangle.on.rectangle").font(.caption2) }
                        .buttonStyle(.borderless).help("Показать другой экран или окно")
                    Button { share.stop() } label: { Image(systemName: "stop.fill").font(.caption2) }
                        .buttonStyle(.borderless).foregroundStyle(.red).help("Остановить трансляцию")
                } else if !queue.items.isEmpty {
                    // Запросов ждут ответа: счётчик виден всегда и по клику открывает панель.
                    requestsButton
                } else {
                    Text(share.reconnecting ? "Переподключаюсь…" : viewers > 0 ? "Эфир · \(viewers)" : "Эфир")
                        .font(.caption2.weight(.medium)).foregroundStyle(share.reconnecting ? .orange : .secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .opacity(expanded ? 1 : 0.75)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { expanded = inside } }
        .fixedSize()
        .frame(width: 190, height: 26, alignment: .trailing)
    }

    private var requestsButton: some View {
        Button { queue.show() } label: {
            Text("Запросов: \(queue.items.count)").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        }
        .buttonStyle(.borderless)
        .help("Показать запросы на подключение")
    }
}

/// Кадры ScreenCaptureKit → JPEG → отправка (пока предыдущий кадр не ушёл, новые пропускаем).
final class FrameSender: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "macutils.share")
    /// URLSessionWebSocketTask сохраняет порядок отправки — звук не перемешивается.
    /// При переподключении сокет подменяется, захват экрана не прерывается.
    private var currentSocket: URLSessionWebSocketTask
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask {
        lock.lock(); defer { lock.unlock() }
        return currentSocket
    }

    func replace(_ socket: URLSessionWebSocketTask) {
        lock.lock()
        currentSocket = socket
        lock.unlock()
        queue.async {
            self.pendingBytes = 0
            self.encoder.setBitrate(Self.startBitrate)
            self.encoder.requestKeyFrame()
        }
    }

    // Скорость под сеть, как в Discord: очередь растёт — снижаем, свободно — поднимаем.
    static let minBitrate = 700_000, maxBitrate = 6_000_000, startBitrate = 3_000_000
    private var lastAdapt = Date()

    /// Вызывается на queue.
    private func adaptBitrate() {
        let now = Date()
        let current = encoder.bitrate
        if pendingBytes > 250_000, now.timeIntervalSince(lastAdapt) > 0.5 {
            encoder.setBitrate(max(Self.minBitrate, current * 7 / 10))
            lastAdapt = now
        } else if pendingBytes < 60_000, now.timeIntervalSince(lastAdapt) > 2, current < Self.maxBitrate {
            encoder.setBitrate(min(Self.maxBitrate, current * 23 / 20))
            lastAdapt = now
        }
    }
    /// Сколько байт видео ушло в сокет и ещё не подтверждено: сеть не успевает — пропускаем кадры
    /// и потом начинаем с ключевого (иначе картинка рассыпается).
    private var pendingBytes = 0
    private var skipping = false
    /// Для зрителей старых версий: раз в ~0.25 с ещё и кадр JPEG.
    var legacyFrames = false
    private var lastLegacy = Date.distantPast
    private let context = CIContext()
    private lazy var encoder = H264Encoder { [weak self] data, key in
        self?.queue.async { self?.sendVideo(data, key: key) }
    }

    init(socket: URLSessionWebSocketTask) {
        currentSocket = socket
    }

    let audioQueue = DispatchQueue(label: "macutils.share.audio")

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if let packet = ShareProtocol.audioPacket(sampleBuffer) {
                socket.send(.data(packet)) { _ in }
            }
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encoder.encode(pixels, at: sampleBuffer.presentationTimeStamp)
        if legacyFrames, Date().timeIntervalSince(lastLegacy) > 0.25, pendingBytes < 1_500_000,
           let image = context.createCGImage(CIImage(cvPixelBuffer: pixels),
                                             from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))),
           let jpeg = Self.jpeg(image) {
            lastLegacy = Date()
            let packet = ShareProtocol.framePacket(jpeg)
            pendingBytes += packet.count
            let size = packet.count
            socket.send(.data(packet)) { _ in self.queue.async { self.pendingBytes = max(0, self.pendingBytes - size) } }
        }
    }

    /// Новый зритель или переподключение — следующий кадр ключевой, чтобы картинка появилась сразу.
    func resendLast() {
        encoder.requestKeyFrame()
    }

    /// Вызывается на queue.
    private func sendVideo(_ data: Data, key: Bool) {
        adaptBitrate()
        // Больше ~1 с в очереди — старые кадры уже не нужны: пропускаем до ключевого, чтобы не копить задержку.
        if pendingBytes > max(400_000, encoder.bitrate / 8) {
            skipping = true
            encoder.requestKeyFrame()
            return
        }
        if skipping {
            guard key else { return }
            skipping = false
        }
        var packet = Data([H264Packet.type, key ? 1 : 0])
        packet.append(data)
        pendingBytes += packet.count
        let socket = self.socket
        let size = packet.count
        socket.send(.data(packet)) { error in
            self.queue.async { self.pendingBytes = max(0, self.pendingBytes - size) }
            if let error {
                Log.capture.error("Трансляция: кадр не ушёл (\(size) Б): \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { ScreenShare.shared.connectionLost(socket) }
                }
            }
        }
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { ScreenShare.shared.stop(reason: "Захват экрана остановлен") }
        }
    }
}

// MARK: - Зритель

@MainActor
final class ShareViewer: ObservableObject {
    static let shared = ShareViewer()

    enum State: Equatable {
        case idle, connecting, waiting, watching, ended(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var frame: NSImage?
    @Published private(set) var code = ""
    /// Ключ ведущего не совпал с запомненным: ждём решения пользователя (раздел 4.3 дизайна).
    @Published private(set) var keyChange: KeyChange?

    struct KeyChange: Equatable {
        let code: String
        let oldFingerprint: String
        let newFingerprint: String
        let newKey: String?

        /// Ведущий больше не подтверждает ключ (ID освобождён или на нём ведущий без проверки ключей).
        var keyRemoved: Bool { newKey == nil }

        var warning: String {
            keyRemoved
                ? "Ведущий больше не подтверждает ключ (раньше был \(oldFingerprint)): его ID освобождён или на нём теперь старая версия. Если вы не ждали этого, это может быть подмена."
                : "Ключ этого компьютера изменился (был \(oldFingerprint), стал \(newFingerprint)). Если ведущий не менял ID вручную, это может быть подмена."
        }
    }

    /// Параметры проверки текущего подключения (mu-share-2).
    private var rid: String?
    private var hostKey: String?
    private var generation = 0

    private var socket: URLSessionWebSocketTask?
    private var window: NSWindow?
    fileprivate let player = SharePlayer()
    /// Видео H.264 (новые версии) — аппаратное декодирование.
    let video = H264Player()
    /// Ведущий потерял связь и переподключается — показываем последний кадр с подписью.
    @Published var hostReconnecting = false
    /// Метки зрителей (свои и чужие) поверх картинки.
    let marks = ShareMarkStore()

    enum Tool: String { case ping, draw, off }
    @Published var tool: Tool = .ping
    @Published var color = "red"

    /// Своя метка: показываем сразу и отправляем ведущему и остальным зрителям.
    func sendPing(_ point: CGPoint) {
        guard let mark = ShareMark.parse(ShareMark.message(ping: point, color: color)) else { return }
        marks.add(mark)
        socket?.send(.string(ShareMark.message(ping: point, color: color))) { _ in }
    }

    func sendStroke(_ points: [CGPoint]) {
        let message = ShareMark.message(stroke: points, color: color)
        guard let mark = ShareMark.parse(message) else { return }
        marks.add(mark)
        socket?.send(.string(message)) { _ in }
    }

    func watch(code input: String) {
        guard let code = ShareCode.normalized(input) else {
            state = .ended("ID — 10 цифр")
            return
        }
        guard !ScreenShare.server.isEmpty,
              let url = ShareCode.url(server: ScreenShare.server, code: code, role: "viewer") else {
            state = .ended("Сервер трансляции не настроен")
            return
        }
        disconnect()
        self.code = code
        keyChange = nil
        rid = nil
        hostKey = nil
        frame = nil
        video.reset()
        state = .connecting
        showWindow()
        generation += 1
        let mine = generation
        Task {
            // mu-share-2 — только если ретранслятор его объявил; иначе по-старому.
            let keyed = ScreenShare.shared.shouldUseKeys(await ScreenShare.shared.probeRelay())
            guard generation == mine, state == .connecting else { return }
            let socket = URLSession.shared.webSocketTask(with: ShareCode.request(url, token: keyed ? ShareRelay.keyedToken : ShareRelay.legacyToken))
            socket.maximumMessageSize = 4 << 20
            self.socket = socket
            socket.resume()
            // Сразу читаем: пока не забираем входящие кадры, ответ на ping может не прийти.
            receive(socket)
        }
    }

    /// Ключ ведущего изменился — пользователь подтвердил: запоминаем новый и подключаемся заново.
    func acceptKeyChange() {
        guard let change = keyChange else { return }
        keyChange = nil
        // Ведущий больше не подтверждает ключ (newKey == nil): забываем старый, иначе подключиться к этому ID не получится.
        if let key = change.newKey { ShareHistory.shared.pinHost(id: change.code, key: key) }
        else { ShareHistory.shared.unpinHost(id: change.code) }
        watch(code: change.code)
    }

    func dismissKeyChange() { keyChange = nil }

    /// Ответ на challenge: сверяем ключ ведущего с запомненным и подписываем (комната и свой ID — наши, не из сообщения).
    private func handle(challenge json: [String: Any], on socket: URLSessionWebSocketTask) {
        guard let nonce = json["nonce"] as? String, let rid = json["rid"] as? String else {
            state = .ended("Сервер прислал неверный запрос проверки")
            disconnect()
            return
        }
        // Ключ в Keychain недоступен: на challenge не отвечаем (relay не должен узнать временный ключ).
        guard ShareIdentity.shared.isPersistent else {
            state = .ended(ShareIdentity.keychainUnavailableMessage)
            disconnect()
            return
        }
        let announced = json["hostKey"] as? String
        if let pinned = ShareHistory.shared.hostKey(for: code), pinned != announced {
            keyChange = KeyChange(code: code,
                                  oldFingerprint: ShareIdentity.fingerprint(ofBase64urlKey: pinned) ?? "—",
                                  newFingerprint: announced.flatMap { ShareIdentity.fingerprint(ofBase64urlKey: $0) } ?? "неизвестен",
                                  newKey: announced.flatMap { ShareHistory.isPublicKey($0) ? $0 : nil })
            state = .ended(announced == nil ? "Ведущий больше не подтверждает ключ: проверьте и подтвердите подключение"
                                            : "Ключ этого компьютера изменился: проверьте и подтвердите подключение")
            disconnect()
            return
        }
        guard let reply = ShareHandshake.viewerAuthMessage(identity: .shared, roomId: code, viewerId: ShareCode.myID, rid: rid, nonce: nonce) else { return }
        self.rid = rid
        hostKey = announced.flatMap { ShareHistory.isPublicKey($0) ? $0 : nil }
        ShareHistory.statusIdentity = .shared
        socket.send(.string(reply)) { _ in }
    }

    /// `accepted`: если ведущий подписал принятие, подпись должна сойтись с его ключом из challenge.
    private func hostSignatureIsValid(_ sig: String?) -> Bool {
        guard let sig else { return true }  // старый ведущий не подписывает
        guard let hostKey, let rid else { return false }
        return ShareIdentity.verify(pub: hostKey, sig: sig,
                                    message: ShareIdentity.acceptMessage(roomId: code, viewerPub: ShareIdentity.publicKey, rid: rid))
    }

    private func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let viewer = ShareViewer.shared
                    guard viewer.socket === socket else { return }
                    switch result {
                    case .success(.data(let data)):
                        if viewer.state != .watching { viewer.state = .watching }
                        switch data.first {
                        case ShareProtocol.frame:
                            if let image = NSImage(data: data.dropFirst()) { viewer.frame = image }
                        case H264Packet.type:
                            viewer.video.play(data.dropFirst())
                        case ShareProtocol.audio:
                            viewer.player.play(data.dropFirst())
                        default:
                            break
                        }
                        viewer.receive(socket)
                    case .success(.string(let text)):
                        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                        let type = json?["type"] as? String
                        if let mark = ShareMark.parse(text) {
                            viewer.marks.add(mark)
                            viewer.receive(socket)
                        } else if type == "heartbeat" {
                            socket.send(.string(#"{"type":"heartbeat"}"#)) { _ in }
                            viewer.receive(socket)
                        } else if type == "reconnecting" {
                            viewer.hostReconnecting = true
                            viewer.receive(socket)
                        } else if type == "resumed" {
                            viewer.hostReconnecting = false
                            viewer.receive(socket)
                        } else if type == "waiting" {
                            viewer.state = .waiting
                            viewer.receive(socket)
                        } else if type == "game" {
                            ShareGame.shared.receive(json ?? [:], peer: "host", name: viewer.hostName,
                                                     transport: viewer.gameTransport)
                            viewer.receive(socket)
                        } else if type == "challenge" {
                            viewer.handle(challenge: json ?? [:], on: socket)
                            viewer.receive(socket)
                        } else if type == "error" {
                            let code = json?["code"] as? String ?? "unknown"
                            viewer.state = .ended(ShareErrorText.message(code: code, relayMessage: json?["message"] as? String))
                            viewer.disconnect()
                        } else if type == "accepted" {
                            guard viewer.hostSignatureIsValid(json?["hostSig"] as? String) else {
                                viewer.state = .ended("Подпись ведущего не сошлась: подключение отменено")
                                viewer.disconnect()
                                return
                            }
                            viewer.state = .watching
                            viewer.hostName = json?["name"] as? String ?? ""
                            ShareHistory.shared.visited(viewer.code, name: json?["name"] as? String ?? "")
                            if let key = viewer.hostKey { ShareHistory.shared.pinHost(id: viewer.code, key: key) }
                            viewer.receive(socket)
                        } else if type == "declined" {
                            viewer.state = .ended("Вам не разрешили подключиться")
                            viewer.disconnect()
                        } else if type == "ended" {
                            viewer.state = .ended("Трансляция завершена")
                            viewer.disconnect()
                        } else {
                            viewer.receive(socket)
                        }
                    case .failure:
                        let status = (socket.response as? HTTPURLResponse)?.statusCode
                        switch viewer.state {
                        case .connecting, .waiting:
                            // 403/426: ретранслятор не принял токен (откат, смена сервера) — при следующей попытке спросим `/version` заново.
                            if status == 403 || status == 426 { ShareRelay.invalidate(server: ScreenShare.server) }
                            viewer.state = .ended(status == 404 ? "Сейчас этот ID ничего не транслирует"
                                                  : status == 429 ? "Слишком много зрителей"
                                                  : status == 403 || status == 426 ? "Сервер не принял подключение — попробуйте ещё раз" : "Нет связи с сервером")
                        case .watching:
                            viewer.state = .ended("Трансляция завершена")
                        default:
                            break
                        }
                        viewer.disconnect()
                    @unknown default:
                        viewer.receive(socket)
                    }
                }
            }
        }
    }

    /// Имя компьютера ведущего (для игры).
    var hostName = ""

    /// Сыграть с ведущим в крестики-нолики.
    func playGame() {
        ShareGame.shared.invite(peer: "host", name: hostName.isEmpty ? ShareCode.display(code) : hostName, transport: gameTransport)
    }

    var gameTransport: ([String: Any]) -> Void {
        { [weak self] fields in
            guard let text = ShareGame.text(fields) else { return }
            self?.socket?.send(.string(text)) { _ in }
        }
    }

    func disconnect() {
        if ShareGame.shared.peer == "host" { ShareGame.shared.peerGone("host") }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        player.stop()
    }

    /// Окно просмотра открыто — Mac Utils виден в Dock и в ⌘Tab.
    private(set) var isWindowOpen = false

    func showWindow() {
        isWindowOpen = true
        AppDelegate.syncDock()
        let window = self.window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(rootView: ShareViewerView(viewer: self))
            window.setContentSize(NSSize(width: 960, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    ShareViewer.shared.disconnect()
                    ShareViewer.shared.state = .idle
                    ShareViewer.shared.isWindowOpen = false
                    AppDelegate.syncDock()
                }
            }
            self.window = window
            return window
        }()
        let label = ShareHistory.shared.label(for: code)
        window.title = code.isEmpty ? "Трансляция экрана" : "Трансляция · \(label ?? ShareCode.display(code))"
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ShareViewerView: View {
    @ObservedObject var viewer: ShareViewer
    @ObservedObject private var video = ShareViewer.shared.video
    @State private var stroke: [CGPoint] = []

    /// Размер кадра: видео H.264 или картинка (старые версии ведущего).
    private var frameSize: CGSize? { video.size ?? viewer.frame?.size }

    var body: some View {
        GeometryReader { proxy in
            let rect = imageRect(in: proxy.size)
            ZStack {
                Color.black
                H264View(player: video)
                    .opacity(video.size == nil ? 0 : 1)
                if video.size == nil, let frame = viewer.frame {
                    Image(nsImage: frame).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
                ShareMarksLayer(store: viewer.marks, rect: rect)
                // Свой рисунок, пока ведёте мышью.
                if stroke.count > 1 {
                    Path { $0.addLines(stroke.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }) }
                        .stroke(ShareMark.color(named: viewer.color), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                status
            }
            .contentShape(Rectangle())
            .gesture(drawGesture(rect: rect))
            .overlay(alignment: .bottom) { toolbar.padding(10) }
        }
        .frame(minWidth: 480, minHeight: 300)
    }

    /// Где картинка внутри окна (вписана с сохранением пропорций).
    private func imageRect(in size: CGSize) -> CGRect {
        guard let frame = frameSize, frame.width > 0, frame.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / frame.width, size.height / frame.height)
        let fitted = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    private func drawGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard viewer.tool == .draw, viewer.state == .watching,
                      let point = normalized(value.location, in: rect) else { return }
                stroke.append(point)
            }
            .onEnded { value in
                guard viewer.state == .watching else { return }
                switch viewer.tool {
                case .ping:
                    if let point = normalized(value.location, in: rect) { viewer.sendPing(point) }
                case .draw:
                    // Длинную линию упрощаем: не больше ~300 точек.
                    let step = max(1, stroke.count / 300)
                    let points = stride(from: 0, to: stroke.count, by: step).map { stroke[$0] }
                    if points.count > 1 { viewer.sendStroke(points) }
                    stroke = []
                case .off:
                    break
                }
            }
    }

    @ViewBuilder private var status: some View {
        switch viewer.state {
        case .connecting:
            VStack(spacing: 8) { ProgressView(); Text("Подключаюсь…").foregroundStyle(.white) }
        case .watching where viewer.frame == nil && video.size == nil:
            VStack(spacing: 8) { ProgressView(); Text("Жду картинку…").foregroundStyle(.white) }
        case .watching where viewer.hostReconnecting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Ведущий переподключается…").foregroundStyle(.white) }
                .padding(10).background(.black.opacity(0.6), in: Capsule())
        case .waiting:
            VStack(spacing: 8) {
                ProgressView()
                Text("Ждём, пока \(ShareCode.display(viewer.code)) разрешит подключение…").foregroundStyle(.white)
            }
        case .ended(let message):
            VStack(spacing: 10) {
                Text(message).font(.title3).foregroundStyle(.white)
                if let change = viewer.keyChange {
                    // Кнопки и в окне просмотра: из поповера или по macutils://watch страницы настроек перед глазами нет.
                    Text(change.warning).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    HStack {
                        Button("Подключиться и запомнить") { viewer.acceptKeyChange() }
                        Button("Отмена") { viewer.dismissKeyChange() }
                    }
                }
            }
            .padding(14).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        default:
            EmptyView()
        }
    }

    /// Метка (клик), рисование (вести мышью), цвет.
    @ViewBuilder private var toolbar: some View {
        if viewer.state == .watching {
            HStack(spacing: 10) {
                SwiftUI.Picker("", selection: $viewer.tool) {
                    Label("Метка", systemImage: "scope").tag(ShareViewer.Tool.ping)
                    Label("Рисовать", systemImage: "pencil.tip").tag(ShareViewer.Tool.draw)
                    Label("Выкл", systemImage: "hand.raised.slash").tag(ShareViewer.Tool.off)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                ForEach(ShareMark.palette, id: \.name) { item in
                    Button { viewer.color = item.name } label: {
                        Circle().fill(item.color).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(.white, lineWidth: viewer.color == item.name ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 16)
                Button { viewer.playGame() } label: { Label("Сыграть", systemImage: "number") }
                    .buttonStyle(.plain)
                    .help("Крестики-нолики с ведущим")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .help("Клик — метка «сюда!» на экране ведущего; «Рисовать» — ведите мышью. Всё исчезает само через пару секунд.")
        }
    }
}

// MARK: - Страница

struct ScreenSharePage: View {
    static let windowsLink = "https://github.com/m-ruzhynskyi/mac-utils/releases/download/windows-latest/MacUtilsShare-Setup.exe"

    var compact = false
    @ObservedObject private var share = ScreenShare.shared
    @ObservedObject private var viewer = ShareViewer.shared
    @AppStorage(Pref.shareServer) private var server = ""
    @AppStorage(Pref.shareAudio) private var shareAudio = true
    @AppStorage(Pref.shareAllowMarks) private var allowMarks = true
    @State private var code = ""

    var body: some View {
        Form {
            Section("Мой ID") {
                HStack {
                    Text(ShareCode.display({ _ = share.idVersion; return ShareCode.myID }())).font(.system(size: 26, weight: .bold).monospacedDigit())
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ShareCode.myID, forType: .string)
                        Toast.show("ID скопирован", symbol: "doc.on.doc.fill")
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Скопировать ID")
                    Spacer()
                    switch share.state {
                    case .idle, .failed:
                        Button { share.start() } label: { Label("Начать трансляцию…", systemImage: "dot.radiowaves.left.and.right") }
                            .help("Откроется выбор: весь экран, окно или программа")
                            .buttonStyle(.borderedProminent)
                            .disabled(server.isEmpty)
                    case .connecting:
                        ProgressView().controlSize(.small)
                    case .live:
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("В эфире").foregroundStyle(.red)
                        Button("Сменить экран…") { share.changeSource() }
                        Button("Стоп") { share.stop() }.tint(.red)
                    }
                }
                if case .failed(let message) = share.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if share.needsNewID {
                    Button { share.confirmRenewID() } label: { Label("Получить новый ID…", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.borderedProminent)
                }
                if share.relayWithoutKeys {
                    Label("Ретранслятор без проверки ключей: личность зрителей не подтверждается, «Всегда разрешать» недоступно.",
                          systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                }
                if case .live = share.state {
                    Text(share.watchers.isEmpty ? "Пока никто не смотрит." : "Смотрят: " + share.watchers.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(share.audience) { watcher in
                        HStack {
                            Label(watcher.name.isEmpty ? ShareCode.display(watcher.id) : watcher.name, systemImage: "eye")
                            Spacer()
                            Button("Сыграть в крестики-нолики") { share.playGame(with: watcher) }
                        }
                    }
                }
                Text("Этот ID постоянный — по нему к вам подключаются. Каждого зрителя вы сначала разрешаете (или отмечаете «Всегда разрешать»). Управлять вашим Mac зритель не может.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let fp = share.myFingerprint {
                        Text("Отпечаток этого Mac: \(fp)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if !share.needsNewID {
                        Button("Получить новый ID…") { share.confirmRenewID() }.controlSize(.small)
                            .help("Заменить ключ и ID этого Mac")
                    }
                }
            }
            Section("Подключиться") {
                HStack {
                    TextField("", text: $code, prompt: Text("ID собеседника, 10 цифр"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .frame(width: 200)
                        .onSubmit { viewer.watch(code: code) }
                    Button("Смотреть") { viewer.watch(code: code) }
                        .disabled(ShareCode.normalized(code) == nil || server.isEmpty)
                }
                if case .ended(let message) = viewer.state {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let change = viewer.keyChange {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(change.warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        HStack {
                            Button("Подключиться и запомнить") { viewer.acceptKeyChange() }
                            Button("Отмена") { viewer.dismissKeyChange() }
                        }
                    }
                }
                Text("Смотреть друг друга: оба начинают трансляцию и подключаются по ID друг к другу.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("История") {
                ShareHistoryList()
            }
            if !compact {
                TrustedList()
            }
            Section("Метки зрителей") {
                Toggle("Разрешить зрителям ставить метки и рисовать", isOn: $allowMarks)
                Text("Зритель кликает или рисует по картинке — у вас на экране появляется метка «сюда!» или линия, и через пару секунд исчезает. Управлять вашим Mac зритель не может.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Звук") {
                Toggle("Передавать звук системы", isOn: $shareAudio)
                Text("Зрители слышат то, что играет на Mac (видео, музыку, звонок). Микрофон не передаётся.")
                    .font(.caption).foregroundStyle(.secondary)
                if shareAudio {
                    MutedAppsList()
                }
            }
            Section("Для собеседника на Windows") {
                HStack {
                    Text("На Windows смотрят и транслируют в приложении Mac Utils Share. Отправьте ссылку на него собеседнику.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.windowsLink, forType: .string)
                        Toast.show("Ссылка для Windows скопирована", symbol: "link")
                    } label: { Label("Скопировать ссылку", systemImage: "link") }
                }
            }
            if !compact || server.isEmpty {
                Section("Сервер") {
                    TextField("Адрес сервера", text: $server, prompt: Text("https://mac-utils-relay….workers.dev"))
                    Text("Ретранслятор из папки relay/ проекта (Cloudflare Workers). Экран идёт через него в зашифрованном соединении и нигде не сохраняется.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Трансляция экрана")
        .task { _ = await share.probeRelay() }
    }
}

/// Доверенные — их пускаем без вопроса.
private struct TrustedList: View {
    @ObservedObject private var history = ShareHistory.shared

    var body: some View {
        if !history.trustedEntries.isEmpty {
            Section("Пускать без вопроса") {
                ForEach(history.trustedEntries) { entry in
                    HStack {
                        Image(systemName: "checkmark.shield").foregroundStyle(.green)
                        Text(entry.title)
                        Text(ShareCode.display(entry.id)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Убрать") { history.untrust(entry.id) }
                    }
                }
            }
        }
    }
}

// MARK: - Протокол и звук

/// Двоичные сообщения: первый байт — тип. 1 — кадр JPEG, 2 — звук PCM Int16, 24 кГц, моно.
enum ShareProtocol {
    static let frame: UInt8 = 1
    static let audio: UInt8 = 2
    static let sampleRate = 24_000.0

    static func framePacket(_ jpeg: Data) -> Data {
        var packet = Data([frame])
        packet.append(jpeg)
        return packet
    }

    static func audioPacket(_ samples: [Float]) -> Data {
        var packet = Data([audio])
        packet.reserveCapacity(1 + samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            withUnsafeBytes(of: &value) { packet.append(contentsOf: $0) }
        }
        return packet
    }

    static func samples(_ payload: Data) -> [Float] {
        let count = payload.count / 2
        var result = [Float](repeating: 0, count: count)
        payload.withUnsafeBytes { raw in
            for index in 0..<count {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                result[index] = Float(value) / 32768
            }
        }
        return result
    }

    /// Звук ScreenCaptureKit (Float32) → пакет.
    static func audioPacket(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                          into: buffer.mutableAudioBufferList) == noErr,
              let channel = buffer.floatChannelData?[0] else { return nil }
        return audioPacket(Array(UnsafeBufferPointer(start: channel, count: Int(frames))))
    }
}

/// Проигрывание звука трансляции у зрителя.
final class SharePlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: ShareProtocol.sampleRate, channels: 1)!
    private var started = false

    func play(_ payload: Data) {
        let samples = ShareProtocol.samples(payload)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if !started {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            guard (try? engine.start()) != nil else { return }
            node.play()
            started = true
        }
        node.scheduleBuffer(buffer)
    }

    func stop() {
        guard started else { return }
        node.stop()
        engine.stop()
        engine.detach(node)
        started = false
    }
}

// MARK: - Выбор, что показывать

/// Системное окно выбора ScreenCaptureKit: экран, окно или программа.
@MainActor
private final class Picker: NSObject, SCContentSharingPickerObserver {
    static let shared = Picker()
    private var completion: ((SCContentFilter?) -> Void)?
    private var observing = false

    func choose(for stream: SCStream? = nil, completion: @escaping (SCContentFilter?) -> Void) {
        let picker = SCContentSharingPicker.shared
        if !observing {
            picker.add(self)
            observing = true
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? ""]
        picker.defaultConfiguration = configuration
        picker.isActive = true
        self.completion = completion
        if let stream { picker.present(for: stream) } else { picker.present() }
    }

    func reset() {
        completion = nil
        SCContentSharingPicker.shared.isActive = false
    }

    private func finish(_ filter: SCContentFilter?) {
        let completion = self.completion
        self.completion = nil
        completion?(filter)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { Picker.shared.finish(filter) } }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { Picker.shared.finish(nil) } }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { MainActor.assumeIsolated { Picker.shared.finish(nil) } }
    }
}

/// «Не передавать звук этих программ» — например, созвон, чтобы собеседники не слышали себя дважды.
private struct MutedAppsList: View {
    @State private var muted: Set<String> = []
    @State private var apps: [(id: String, name: String, icon: NSImage)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Не передавать звук программ:").font(.callout)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(apps, id: \.id) { app in
                    Toggle(isOn: Binding(get: { muted.contains(app.id) }, set: { on in
                        if on { muted.insert(app.id) } else { muted.remove(app.id) }
                        UserDefaults.standard.set(Array(muted).sorted(), forKey: Pref.shareMutedApps)
                        ScreenShare.shared.refreshAudioFilter()
                    })) {
                        HStack(spacing: 4) {
                            Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                            Text(app.name).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Text("Заглушённые программы зрители не слышат; у вас звук остаётся. Меняется и во время трансляции.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: load)
    }

    private func load() {
        muted = Set(UserDefaults.standard.stringArray(forKey: Pref.shareMutedApps) ?? [])
        var seen = Set<String>()
        var list: [(id: String, name: String, icon: NSImage)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            list.append((id, app.localizedName ?? id, app.icon ?? NSImage()))
        }
        // Заглушённые, но сейчас не запущенные — тоже в списке, чтобы можно было снять галочку.
        for id in muted where !seen.contains(id) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                list.append((id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                             NSWorkspace.shared.icon(forFile: url.path)))
            }
        }
        apps = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
