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
    /// Попытки подключения: «Отмена», «Стоп» и таймаут делают запоздавший результат недействительным (SH3).
    private var attempts = ShareAttempts()

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
        let attempt = attempts.begin()
        if screen {
            Task {
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                      let display = content.displays.first(where: { $0.displayID == (NSScreen.withMouse ?? NSScreen.main)?.displayID })
                        ?? content.displays.first else {
                    if attempts.isCurrent(attempt) { state = .failed("Не удалось начать захват экрана") }
                    return
                }
                connect(filter: Self.displayFilter(display, content: content), attempt: attempt)
            }
            return
        }
        Picker.shared.choose { [weak self] filter in
            guard let self, self.attempts.isCurrent(attempt) else { return }
            guard let filter else {
                self.state = .idle
                return
            }
            self.connect(filter: filter, attempt: attempt)
        }
    }

    /// «Отмена» во время подключения: выбор экрана, рукопожатие и начало захвата прерываются, эфир не начнётся.
    func cancelConnecting() {
        guard state == .connecting else { return }
        stop()
    }

    private func connect(filter: SCContentFilter, attempt: Int) {
        guard attempts.isCurrent(attempt) else { return }
        armConnectTimeout(attempt)
        Task {
            // Комната — свой постоянный ID; занята — значит, трансляция с этим ID уже идёт.
            let code = ShareCode.myID
            needsNewID = false
            let opened = await openHostSocket()
            // Пока ждали сервер, подключение отменили или вышло время: свежий сокет закрываем, состояние не трогаем.
            guard attempts.isCurrent(attempt) else {
                if case .ok(let late, _) = opened { late.cancel(with: .goingAway, reason: nil) }
                return
            }
            switch opened {
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
                    // Звук мог уже пойти (он запускается раньше видео): останавливаем всё, что успело начаться (SH2).
                    teardownCapture()
                    socket.cancel(with: .goingAway, reason: nil)
                    self.socket = nil
                    if attempts.isCurrent(attempt) { state = .failed("Не удалось начать захват экрана") }
                    return
                }
                guard attempts.isCurrent(attempt) else {
                    // Отменили, пока начинался захват.
                    teardownCapture()
                    socket.cancel(with: .goingAway, reason: nil)
                    if self.socket === socket { self.socket = nil }
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

    /// Сервер не ответил вовремя (сокет висит до системного таймаута в 60 с): попытка прерывается с понятным текстом.
    private func armConnectTimeout(_ attempt: Int) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(ShareTimeouts.hostConnect * 1_000_000_000))
            guard attempts.isCurrent(attempt), state == .connecting else { return }
            Log.capture.error("Трансляция: сервер не ответил за \(Int(ShareTimeouts.hostConnect)) с")
            stop(reason: ShareTimeouts.hostConnectMessage)
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
        // «Отмена», «Стоп» и таймаут меняют попытку: и при первом подключении, и при переподключении в эфире.
        let attempt = attempts.current
        let keyedRelay = shouldUseKeys(await probeRelay())
        // Отменили, пока спрашивали `/version`: сокет не открываем.
        guard attempts.isCurrent(attempt) else { return .failed(status: 0) }
        let socket = URLSession.shared.webSocketTask(with: ShareCode.request(url, token: keyedRelay ? ShareRelay.keyedToken : ShareRelay.legacyToken))
        socket.maximumMessageSize = 4 << 20
        socket.resume()
        // Пока идёт рукопожатие, отмена закрывает сокет сразу: иначе он пройдёт `auth` позже новой попытки и relay
        // выбьет её (`replaced`), а в legacy новая попытка получит 409.
        attempts.track(socket) { socket.cancel(with: .goingAway, reason: nil) }
        defer { attempts.untrack(socket) }
        if keyedRelay {
            switch await ShareHandshake.authenticateHost(socket, roomId: code, identity: .shared) {
            case .authed where !attempts.isCurrent(attempt):
                socket.cancel(with: .goingAway, reason: nil)
                return .failed(status: 0)
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
        guard attempts.isCurrent(attempt) else {
            socket.cancel(with: .goingAway, reason: nil)
            return .failed(status: 0)
        }
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
        // До 1920 точек по длинной стороне (ShareVideo.streamSize) — мелкий текст читаем, сети по силам.
        let size = ShareVideo.streamSize(pixelWidth: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                                         pixelHeight: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.width = size.width
        config.height = size.height
    }

    /// Настройка видеопотока: размер по фильтру, 60 кадров/с (при перегрузке FrameSender снижает до 30), формат,
    /// который кодек берёт без пересчёта.
    private static func videoConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        configure(config, for: filter)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ShareVideo.frameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 5
        return config
    }

    /// Фильтр текущего видеопотока: размер транслируемого окна берётся из него при старте.
    private var videoFilter: SCContentFilter?

    /// Транслируемое окно изменило размер (рамку следит панель меток): поток — под новый размер. Иначе кадр остаётся
    /// прежнего размера, окно в нём обрезано или с полями, и точки зрителей у ведущего ложатся не туда.
    func sharedWindowResized(to points: CGSize) {
        guard let stream, let filter = videoFilter, filter.style == .window else { return }
        let scale = CGFloat(filter.pointPixelScale)
        let current = streamSizeOverride
            ?? ShareVideo.streamSize(pixelWidth: filter.contentRect.width * scale, pixelHeight: filter.contentRect.height * scale)
        guard let size = ShareVideo.resizedStreamSize(current: current, window: points, scale: scale) else { return }
        let config = Self.videoConfiguration(for: filter)
        config.width = size.width
        config.height = size.height
        streamSizeOverride = size
        Task { try? await stream.updateConfiguration(config) }
    }

    /// Размер потока после изменения окна (nil — ещё по фильтру).
    private var streamSizeOverride: (width: Int, height: Int)?

    /// Сменить, что показываем, не прерывая трансляцию.
    func changeSource() {
        guard isLive, let stream else { return }
        Picker.shared.choose(for: stream) { filter in
            guard let filter else { return }
            let config = Self.videoConfiguration(for: filter)
            self.videoFilter = filter
            self.streamSizeOverride = nil
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
        // H.264 (аппаратно): 60 кадров в секунду (при перегрузке FrameSender снижает до 30) и формат, который кодек берёт без пересчёта.
        let config = Self.videoConfiguration(for: filter)
        videoFilter = filter
        streamSizeOverride = nil
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
        self.sender = sender
        // Видео не пошло, а звук уже идёт — его останавливает teardownCapture в вызывающем (SH2).
        try await stream.startCapture()
        self.stream = stream
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
                            // Никто не смотрит — кодер на паузе; появился зритель — сразу ключевой кадр (SH4).
                            self.sender?.setViewers(count)
                            // Новый зритель сразу получает картинку, даже если экран не меняется.
                            if count > 0 { self.sender?.resendLast() }
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
        attempts.cancel()
        reconnecting = false
        watchers = []
        audience = []
        if ShareGame.shared.peer != "host" { ShareGame.shared.peerGone() }
        ShareRequestQueue.shared.removeAll()
        hostKeyed = false
        Picker.shared.reset()
        ShareMarksOverlay.shared.detach()
        teardownCapture()
        heartbeat?.invalidate()
        heartbeat = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        hud?.orderOut(nil)
        hud = nil
        state = reason.map { .failed($0) } ?? .idle
    }

    /// Остановить захват видео и звука и таймер фильтра звука (общая часть «Стоп» и сбоя старта — SH2).
    private func teardownCapture() {
        let stream = self.stream
        let audioStream = self.audioStream
        self.stream = nil
        self.audioStream = nil
        videoFilter = nil
        streamSizeOverride = nil
        audioRefresh?.invalidate()
        audioRefresh = nil
        sender = nil
        Task {
            try? await audioStream?.stopCapture()
            try? await stream?.stopCapture()
        }
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
        Group {
            if case .live(let code, let viewers) = share.state {
                ShareHUDPill(code: code, viewers: viewers, requests: queue.items.count, reconnecting: share.reconnecting,
                             expanded: expanded, copy: { share.copyCode() }, showRequests: { queue.show() },
                             changeSource: { share.changeSource() }, stop: { share.stop() })
            } else {
                ShareHUDPill(code: nil, viewers: 0, requests: 0, reconnecting: false, expanded: false,
                             copy: {}, showRequests: {}, changeSource: {}, stop: {})
            }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { expanded = inside } }
        .fixedSize()
        .frame(width: 330, height: 40, alignment: .trailing)
    }
}

/// Капсула эфира (вид из `MacHost.dc.html`): пульсирующая точка и «Эфир · N»; в развёрнутом виде — код, зрители,
/// счётчик запросов, «Другой экран», «Стоп». Значения готовые, без модели.
struct ShareHUDPill: View {
    let code: String?
    let viewers: Int
    let requests: Int
    let reconnecting: Bool
    let expanded: Bool
    let copy: () -> Void
    let showRequests: () -> Void
    let changeSource: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PulsingDot(color: .dsRec)
            if let code {
                if expanded {
                    Button(action: copy) {
                        Text(ShareCode.display(code)).font(DS.Font.mono(13, relativeTo: .caption)).foregroundStyle(.dsText)
                    }
                    .buttonStyle(.plain)
                    .help("Скопировать код")
                    Label("\(viewers)", systemImage: "eye").font(DS.Font.caption).foregroundStyle(.dsMute)
                    if requests > 0 { requestsButton }
                    HUDIconButton(symbol: "rectangle.on.rectangle", help: "Показать другой экран или окно", kind: .plain, action: changeSource)
                    HUDIconButton(symbol: "stop.fill", help: "Остановить трансляцию", kind: .stop, action: stop)
                } else if requests > 0 {
                    // Запросов ждут ответа: счётчик виден всегда и по клику открывает панель.
                    requestsButton
                } else {
                    Text(reconnecting ? "Переподключаюсь…" : viewers > 0 ? "Эфир · \(viewers)" : "Эфир")
                        .font(DS.Font.caption)
                        .foregroundStyle(reconnecting ? DS.Tone.warning.text : Color.dsText)
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 12)
        .padding(.trailing, expanded ? 6 : 12)
        .capsuleFill(Color.dsPanel, border: Color.dsLine)
        .opacity(expanded ? 1 : 0.8)
    }

    private var requestsButton: some View {
        Button(action: showRequests) {
            Text("Запросов: \(requests)").font(DS.Font.manrope(12, .bold, relativeTo: .caption))
                .foregroundStyle(DS.Tone.warning.text)
        }
        .buttonStyle(.plain)
        .help("Показать запросы на подключение")
    }
}

/// Квадратная кнопка-значок индикатора: 26×26, радиус 8; «Стоп» — красная.
struct HUDIconButton: View {
    enum Kind { case plain, stop }
    let symbol: String
    let help: String
    var kind: Kind = .plain
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind == .stop ? Color.dsRecInk : Color.dsText)
                .frame(width: 26, height: 26)
                .background(kind == .stop ? Color.dsRec : Color.dsField, in: shape)
                .overlay(shape.strokeBorder(kind == .stop ? .clear : Color.dsLine, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
        .accessibilityLabel(help)
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
            self.governor.warmUp(now: ProcessInfo.processInfo.systemUptime)
            self.encoder.setBitrate(ShareVideo.startBitrate)
            self.encoder.requestKeyFrame()
        }
    }

    // Скорость под сеть (ShareVideo.adaptedBitrate): очередь растёт — снижаем, свободно — поднимаем.
    private var lastAdapt = Date()

    /// Вызывается на queue.
    private func adaptBitrate() {
        let now = Date()
        guard let next = ShareVideo.adaptedBitrate(current: encoder.bitrate, pendingBytes: pendingBytes,
                                                   secondsSinceLast: now.timeIntervalSince(lastAdapt)) else { return }
        encoder.setBitrate(next)
        lastAdapt = now
    }

    /// 60 → 30 кадров/с при перегрузке и обратно после спокойного окна (ShareRateGovernor). Вызывается на queue.
    private var governor: ShareRateGovernor = {
        var governor = ShareRateGovernor()
        governor.warmUp(now: ProcessInfo.processInfo.systemUptime)
        return governor
    }()
    private func noteCongestion() {
        if governor.congested(now: ProcessInfo.processInfo.systemUptime) { rateChanged() }
    }
    private func noteCalm() {
        if governor.calm(now: ProcessInfo.processInfo.systemUptime) { rateChanged() }
    }
    private func rateChanged() {
        encoder.setFrameRate(governor.fps)
        Log.capture.info("Трансляция: \(self.governor.fps) кадров/с")
    }
    /// Сколько байт видео ушло в сокет и ещё не подтверждено: сеть не успевает — пропускаем кадры
    /// и потом начинаем с ключевого (иначе картинка рассыпается).
    private var pendingBytes = 0
    private var skipping = false
    /// Для зрителей старых версий: раз в ~0.25 с ещё и кадр JPEG.
    var legacyFrames = false
    private var lastLegacy = Date.distantPast
    private let context = CIContext()
    /// Никто не смотрит — не кодируем и не шлём видео и звук (SH4). До первого числа зрителей от сервера — не на паузе.
    private let pauseLock = NSLock()
    private var pausedValue = false
    var isPaused: Bool {
        pauseLock.lock(); defer { pauseLock.unlock() }
        return pausedValue
    }
    /// Последний полный кадр экрана (на queue): на статичном экране ScreenCaptureKit новых кадров не присылает,
    /// поэтому для нового зрителя и после паузы кодируем его заново — картинка появляется сразу.
    private var lastPixels: CVPixelBuffer?
    /// Метки времени кадров для кодера (на queue): строго растут, даже вперемешку с повтором последнего кадра.
    private var clock = ShareFrameClock()
    private lazy var encoder: H264Encoder = {
        let encoder = H264Encoder { [weak self] data, key in
            self?.queue.async { self?.sendVideo(data, key: key) }
        }
        // Новая сессия (старт, смена размера) — прогрев; частота — текущая, а не всегда 60.
        encoder.setFrameRate(governor.fps)
        encoder.onSession = { [weak self] in self?.governor.warmUp(now: ProcessInfo.processInfo.systemUptime) }
        return encoder
    }()

    init(socket: URLSessionWebSocketTask) {
        currentSocket = socket
    }

    let audioQueue = DispatchQueue(label: "macutils.share.audio")

    /// Число зрителей пришло от сервера: 0 — пауза, иначе работаем.
    func setViewers(_ count: Int) {
        let pause = ShareEncoderGate.shouldPause(viewers: count)
        pauseLock.lock()
        let changed = pausedValue != pause
        pausedValue = pause
        pauseLock.unlock()
        if changed { Log.capture.info("Трансляция: кодирование \(pause ? "на паузе (нет зрителей)" : "возобновлено", privacy: .public)") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if !isPaused, let packet = ShareProtocol.audioPacket(sampleBuffer) {
                socket.send(.data(packet)) { _ in }
            }
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPixels = pixels
        guard !isPaused else { return }
        if governor.shouldEncode(at: sampleBuffer.presentationTimeStamp.seconds) {
            if !encoder.encode(pixels, at: clock.next(sampleBuffer.presentationTimeStamp)) { noteCongestion() }
        }
        sendLegacyFrame(pixels, force: false)
    }

    /// Вызывается на queue. Кадр JPEG для старых зрителей (раз в ~0.25 с или сразу — для нового зрителя).
    private func sendLegacyFrame(_ pixels: CVPixelBuffer, force: Bool) {
        guard legacyFrames, force || Date().timeIntervalSince(lastLegacy) > 0.25, pendingBytes < 1_500_000,
              let image = context.createCGImage(CIImage(cvPixelBuffer: pixels),
                                                from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))),
              let jpeg = Self.jpeg(image) else { return }
        lastLegacy = Date()
        let packet = ShareProtocol.framePacket(jpeg)
        pendingBytes += packet.count
        let size = packet.count
        socket.send(.data(packet)) { _ in self.queue.async { self.pendingBytes = max(0, self.pendingBytes - size) } }
    }

    /// Новый зритель, конец паузы или переподключение: ключевой кадр сразу, из последнего кадра экрана
    /// (статичный экран новых кадров не даёт), дальше — обычный поток.
    func resendLast() {
        queue.async {
            self.encoder.requestKeyFrame()
            guard !self.isPaused, let pixels = self.lastPixels else { return }
            self.encoder.encode(pixels, at: self.clock.next(CMClockGetTime(CMClockGetHostTimeClock())))
            self.sendLegacyFrame(pixels, force: true)
        }
    }

    /// Вызывается на queue.
    private func sendVideo(_ data: Data, key: Bool) {
        adaptBitrate()
        // Больше ~1 с в очереди — старые кадры уже не нужны: пропускаем до ключевого, чтобы не копить задержку.
        if pendingBytes > max(400_000, encoder.bitrate / 8) {
            skipping = true
            encoder.requestKeyFrame()
            noteCongestion()
            return
        }
        if governor.bitrateSample(encoder.bitrate, now: ProcessInfo.processInfo.systemUptime) { rateChanged() }
        if pendingBytes < max(60_000, encoder.bitrate / 64) { noteCalm() }
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
        /// Связь оборвалась во время просмотра: переподключаемся сами (SH5).
        case reconnecting(attempt: Int)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var frame: NSImage?
    /// Кадров JPEG с начала просмотра (для журнала, когда картинки нет).
    private var jpegFrames = 0
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
    /// Сколько попыток переподключения сделано подряд (0 — просмотр идёт или ещё не начинался).
    private var reconnectsMade = 0
    /// Когда от сервера последний раз что-то пришло, и сторож молчащего соединения.
    private var lastMessage = Date()
    private var silenceWatch: Timer?
    /// Сервер этого соединения шлёт heartbeat: только тогда тишина что-то значит (старый ретранслятор мог не слать).
    private var sawHeartbeat = false

    /// Проигрыватель видео показывает пакеты только текущего соединения (пакеты оборванного отбрасываются).
    private var socket: URLSessionWebSocketTask? { didSet { video.attach(socket) } }
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
        frame = nil
        jpegFrames = 0
        video.reset()
        state = .connecting
        showWindow()
        generation += 1
        open(url, generation: generation)
    }

    /// Новое соединение с тем же ID (первое и при переподключении): протокол и проверка ключа ведущего — заново.
    private func open(_ url: URL, generation mine: Int) {
        rid = nil
        hostKey = nil
        Task {
            // mu-share-2 — только если ретранслятор его объявил; иначе по-старому.
            let keyed = ScreenShare.shared.shouldUseKeys(await ScreenShare.shared.probeRelay())
            guard generation == mine else { return }
            switch state {
            case .connecting, .reconnecting: break
            default: return
            }
            let socket = URLSession.shared.webSocketTask(with: ShareCode.request(url, token: keyed ? ShareRelay.keyedToken : ShareRelay.legacyToken))
            socket.maximumMessageSize = 4 << 20
            self.socket = socket
            socket.resume()
            lastMessage = Date()
            sawHeartbeat = false
            startSilenceWatch()
            // Сразу читаем: пока не забираем входящие кадры, ответ на ping может не прийти.
            receive(socket)
            if case .reconnecting = state { armAttemptTimeout(socket, generation: mine) }
        }
    }

    /// Попытка переподключения не дошла до сервера за `attemptTimeout`: закрываем сокет — сработает обычный обрыв
    /// и следующая попытка (без этого одна попытка висит до системных 60 с).
    private func armAttemptTimeout(_ socket: URLSessionWebSocketTask, generation mine: Int) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(ShareViewerReconnect.attemptTimeout * 1_000_000_000))
            guard generation == mine, self.socket === socket, ShareViewerReconnect.shouldAbortAttempt(state: state) else { return }
            Log.capture.info("Просмотр: попытка переподключения не ответила за \(Int(ShareViewerReconnect.attemptTimeout)) с")
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    /// Раз в 15 с: если сервер молчит дольше `silenceLimit`, закрываем сокет — сработает обычное переподключение.
    private func startSilenceWatch() {
        silenceWatch?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                let viewer = ShareViewer.shared
                guard viewer.sawHeartbeat, viewer.state == .watching || viewer.state == .waiting,
                      ShareViewerReconnect.isSilent(lastMessage: viewer.lastMessage, now: Date()) else { return }
                Log.capture.info("Просмотр: сервер молчит дольше \(Int(ShareViewerReconnect.silenceLimit)) с — переподключаюсь")
                viewer.socket?.cancel(with: .goingAway, reason: nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceWatch = timer
    }

    /// Соединение оборвалось. Во время просмотра — переподключаемся сами с паузами (последний кадр остаётся на экране);
    /// попытки кончились — честное сообщение. Возвращает false, если это не обрыв просмотра.
    private func dropped(status: Int?) -> Bool {
        guard let decision = ShareViewerReconnect.onDrop(wasWatching: state == .watching, attemptsMade: reconnectsMade,
                                                         status: status) else { return false }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        player.stop()
        if ShareGame.shared.peer == "host" { ShareGame.shared.peerGone("host") }
        switch decision {
        case .end(let message):
            state = .ended(message)
            disconnect()
        case .reconnect(let attempt, let delay):
            reconnectsMade = attempt
            hostReconnecting = false
            state = .reconnecting(attempt: attempt)
            Log.capture.info("Просмотр: связь потеряна, попытка \(attempt) через \(delay) с")
            generation += 1
            let mine = generation
            Task {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard generation == mine, case .reconnecting = state,
                      let url = ShareCode.url(server: ScreenShare.server, code: code, role: "viewer") else { return }
                open(url, generation: mine)
            }
        }
        return true
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
        Self.listen(socket, video: video)
    }

    /// Чтение сокета. Видео H.264 уходит в проигрыватель прямо из колбэка, и следующее чтение взводится сразу:
    /// занятый главный поток не тормозит картинку. На главный — только учёт и остальные сообщения.
    nonisolated private static func listen(_ socket: URLSessionWebSocketTask, video: H264Player) {
        socket.receive { result in
            if case .success(.data(let data)) = result, data.first == H264Packet.type {
                video.play(data.dropFirst(), from: socket)
                listen(socket, video: video)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let viewer = ShareViewer.shared
                        guard viewer.socket === socket else { return }
                        viewer.lastMessage = Date()
                        if viewer.state != .watching { viewer.state = .watching }
                        viewer.reconnectsMade = 0
                    }
                }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let viewer = ShareViewer.shared
                    guard viewer.socket === socket else { return }
                    if case .success = result { viewer.lastMessage = Date() }
                    switch result {
                    case .success(.data(let data)):
                        if viewer.state != .watching { viewer.state = .watching }
                        viewer.reconnectsMade = 0
                        switch data.first {
                        case ShareProtocol.frame:
                            viewer.jpegFrames += 1
                            if let image = NSImage(data: data.dropFirst()) { viewer.frame = image }
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
                            viewer.sawHeartbeat = true
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
                            viewer.reconnectsMade = 0
                            viewer.watchForPicture(socket)
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
                        // 403/426: ретранслятор не принял токен (откат, смена сервера) — при следующей попытке спросим `/version` заново.
                        if status == 403 || status == 426 { ShareRelay.invalidate(server: ScreenShare.server) }
                        // Обрыв во время просмотра (Wi-Fi, сон, смена сети) — переподключаемся сами.
                        if viewer.dropped(status: status) { return }
                        switch viewer.state {
                        case .connecting, .waiting:
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

    /// Ведущий принял, а картинки нет через `pictureWait`: в журнал — что пришло (только числа). Так видно, где поток
    /// теряется: пакетов нет совсем (ведущий не кодирует) или ключевые кадры без SPS/PPS (декодер не настроить).
    static let pictureWait: TimeInterval = 10

    private func watchForPicture(_ socket: URLSessionWebSocketTask) {
        Log.capture.info("Просмотр: ведущий принял, жду картинку")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pictureWait) {
            MainActor.assumeIsolated {
                let viewer = ShareViewer.shared
                guard viewer.socket === socket, viewer.state == .watching, viewer.frame == nil, viewer.video.size == nil else { return }
                let jpeg = viewer.jpegFrames
                viewer.video.received { counts in
                    Log.capture.info("Просмотр: нет картинки \(Int(Self.pictureWait)) с: H.264 пакетов \(counts.packets), ключевых \(counts.keys), с SPS/PPS \(counts.withParameterSets), JPEG \(jpeg)")
                }
            }
        }
    }

    /// Пользователь прервал переподключение.
    func endManually() { state = .ended("Отключено") }

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

    /// Закончить просмотр (окно закрыли, «Отключиться», конец трансляции): и переподключение тоже прекращается.
    func disconnect() {
        generation += 1
        reconnectsMade = 0
        silenceWatch?.invalidate()
        silenceWatch = nil
        if ShareGame.shared.peer == "host" { ShareGame.shared.peerGone("host") }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        player.stop()
    }

    /// Остановить просмотр при выходе: подключение закрывается, состояние уходит из «идёт» (окно остаётся до закрытия).
    func stopWatching() {
        if BusyRegistry.viewerIsConnected(state) { state = .ended("Просмотр остановлен") }
        disconnect()
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
                    Path { $0.addLines(stroke.map { ShareMarkGeometry.point($0, in: rect) }) }
                        .stroke(ShareMark.color(named: viewer.color), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                status
            }
            .contentShape(Rectangle())
            .gesture(drawGesture(rect: rect))
            .overlay(alignment: .topTrailing) { badge }
            .overlay(alignment: .bottom) { toolbar.padding(14) }
        }
        .frame(minWidth: 480, minHeight: 300)
    }

    /// Где картинка внутри окна (вписана с сохранением пропорций).
    private func imageRect(in size: CGSize) -> CGRect { ShareMarkGeometry.imageRect(frame: frameSize, in: size) }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint? { ShareMarkGeometry.normalized(point, in: rect) }

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
            ViewerStatusCard(.progress("Подключаюсь…"))
        case .watching where viewer.frame == nil && video.size == nil:
            ViewerStatusCard(.progress("Жду картинку…"))
        case .watching where viewer.hostReconnecting:
            ViewerStatusCard(.notice("Ведущий переподключается…"))
        case .waiting:
            ViewerStatusCard(.progress("Ждём, пока \(ShareCode.display(viewer.code)) разрешит подключение…"))
        case .reconnecting(let attempt):
            ViewerStatusCard(.reconnecting(ShareViewerReconnect.status(attempt: attempt)) {
                viewer.disconnect()
                viewer.endManually()
            })
        case .ended(let message):
            // Кнопки и в окне просмотра: из поповера или по macutils://watch страницы настроек перед глазами нет.
            ViewerStatusCard(.ended(message, warning: viewer.keyChange?.warning,
                                    accept: viewer.keyChange == nil ? nil : { viewer.acceptKeyChange() },
                                    dismiss: viewer.keyChange == nil ? nil : { viewer.dismissKeyChange() }))
        default:
            EmptyView()
        }
    }

    /// Метка в углу: идёт трансляция и качество картинки.
    @ViewBuilder private var badge: some View {
        if viewer.state == .watching, frameSize != nil || viewer.frame != nil {
            ShareViewerBadge(height: frameSize.map { Int($0.height) })
                .padding(12)
        }
    }

    /// Метка (клик), рисование (вести мышью), цвет.
    @ViewBuilder private var toolbar: some View {
        if viewer.state == .watching {
            ShareViewerToolbar(tool: $viewer.tool, color: $viewer.color) { viewer.playGame() }
        }
    }
}

/// Что показать поверх картинки у зрителя (подключение, ожидание, переподключение, конец).
enum ViewerStatusContent {
    case progress(String)
    case notice(String)
    case reconnecting(String, disconnect: () -> Void)
    case ended(String, warning: String?, accept: (() -> Void)?, dismiss: (() -> Void)?)
}

/// Карточка состояния по центру окна зрителя: `panel`, обводка `line`, радиус 20 (раньше — белый текст на чёрном).
struct ViewerStatusCard: View {
    let content: ViewerStatusContent

    init(_ content: ViewerStatusContent) { self.content = content }

    var body: some View {
        card.accessibilityElement(children: .contain)
    }

    @ViewBuilder private var card: some View {
        switch content {
        case .progress(let text):
            VStack(spacing: DS.Space.m) {
                ProgressView().controlSize(.regular)
                Text(text).font(DS.Font.bodyStrong).foregroundStyle(.dsText).multilineTextAlignment(.center)
            }
            .padding(DS.Space.xl).floating(.panel)
        case .notice(let text):
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text(text).font(DS.Font.bodyStrong).foregroundStyle(.dsText)
            }
            .floating(.pill)
        case .reconnecting(let text, let disconnect):
            VStack(spacing: DS.Space.m) {
                ProgressView()
                Text(text).font(DS.Font.bodyStrong).foregroundStyle(.dsText).multilineTextAlignment(.center)
                Button("Отключиться", action: disconnect).buttonStyle(.graphite(.secondary, size: .compact))
            }
            .padding(DS.Space.l).floating(.panel)
        case .ended(let message, let warning, let accept, let dismiss):
            VStack(spacing: DS.Space.m) {
                Text(message).font(DS.Font.dialogTitle).foregroundStyle(.dsText).multilineTextAlignment(.center)
                if let warning {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: DS.Tone.warning.symbol).accessibilityHidden(true)
                        Text(warning).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(DS.Font.caption).foregroundStyle(DS.Tone.warning.text)
                }
                if accept != nil || dismiss != nil {
                    HStack(spacing: DS.Space.s) {
                        if let accept { Button("Подключиться и запомнить", action: accept).buttonStyle(.graphite(.primary, size: .compact)) }
                        if let dismiss { Button("Отмена", action: dismiss).buttonStyle(.graphite(.secondary, size: .compact)) }
                    }
                }
            }
            .frame(maxWidth: 420)
            .padding(DS.Space.xl).floating(.panel)
        }
    }
}

/// «В ЭФИРЕ · 1080p» в углу окна зрителя (качество — в нижнем регистре, как принято).
struct ShareViewerBadge: View {
    var height: Int?

    var body: some View {
        HStack(spacing: 0) {
            Text("В ЭФИРЕ").tracking(DS.Font.tracking(0.06, size: 11))
            if let height { Text(" · \(height)p").monospacedDigit() }
        }
        .font(DS.Font.groupLabel)
        .foregroundStyle(Color.dsRecInk)
        .padding(.vertical, DS.Space.xs)
        .padding(.horizontal, 10)
        .background(Color.dsRec, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("В эфире")
    }
}

/// Панель инструментов зрителя (как в `MacWatch.dc.html`): метка, рисование, выкл — значками (активный — лайм), цвет,
/// «Сыграть». Подписи — во всплывающих подсказках. Цвета те же, что понимает ведущий (`ShareMark.palette`).
/// Толщины линии в протоколе нет — её в панели нет.
struct ShareViewerToolbar: View {
    @Binding var tool: ShareViewer.Tool
    @Binding var color: String
    let playGame: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            toolButton(.ping, symbol: "scope", title: "Метка")
            toolButton(.draw, symbol: "pencil", title: "Рисовать")
            toolButton(.off, symbol: "hand.raised.slash", title: "Выкл")
            separator
            ForEach(ShareMark.palette, id: \.name) { item in
                Button { color = item.name } label: {
                    Circle().fill(item.color).frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().strokeBorder(color == item.name ? Color.dsText : .clear, lineWidth: 2))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help(Self.colorTitle(item.name))
                .accessibilityLabel(Self.colorTitle(item.name))
                .accessibilityAddTraits(color == item.name ? .isSelected : [])
            }
            separator
            ViewerToolButton(symbol: "number", title: "Сыграть", selected: false, action: playGame)
                .help("Крестики-нолики с ведущим")
        }
        .padding(8)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .help("Клик — метка «сюда!» на экране ведущего; «Рисовать» — ведите мышью. Всё исчезает само через пару секунд.")
    }

    private var separator: some View {
        Rectangle().fill(Color.dsLine).frame(width: 1, height: 28).padding(.horizontal, 6).accessibilityHidden(true)
    }

    private func toolButton(_ value: ShareViewer.Tool, symbol: String, title: String) -> some View {
        ViewerToolButton(symbol: symbol, title: title, selected: tool == value) { tool = value }
    }

    static func colorTitle(_ name: String) -> String {
        switch name {
        case "red": return "Красный"
        case "yellow": return "Жёлтый"
        case "green": return "Зелёный"
        case "blue": return "Синий"
        case "white": return "Белый"
        default: return name
        }
    }
}

/// Кнопка-значок панели зрителя: 44×44, радиус 12; выбранная — лайм.
private struct ViewerToolButton: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? Color.dsAccInk : Color.dsText)
                .frame(width: 44, height: 44)
                .background(selected ? Color.dsAcc : (hovered ? Color.dsField : .clear), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Страница

struct ScreenSharePage: View {
    static let windowsLink = "https://github.com/m-ruzhynskyi/mac-utils/releases/download/windows-latest/MacUtilsShare-Setup.exe"

    var compact = false
    /// Демо для снимков интерфейса: без сети, личного ID и истории этого Mac.
    var demo = false
    @ObservedObject private var share = ScreenShare.shared
    @ObservedObject private var viewer = ShareViewer.shared
    @AppStorage(Pref.shareServer) private var server = ""
    @AppStorage(Pref.shareAudio) private var shareAudio = true
    @AppStorage(Pref.shareAllowMarks) private var allowMarks = true
    @State private var code = ""

    private var myID: String {
        demo ? "1234567890" : { _ = share.idVersion; return ShareCode.myID }()
    }

    private var fingerprint: String? { demo ? "65b6-0673-d6ed-884b" : share.myFingerprint }

    var body: some View {
        Group {
            if compact {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.section) { content }
                        .padding(DS.Space.m)
                }
            } else {
                SettingsPage(.share) { content }
            }
        }
        .task { if !demo { _ = await share.probeRelay() } }
    }

    @ViewBuilder private var content: some View {
        GroupLabel("Мой ID")
        idCard
        if let message = failureMessage {
            Banner(.warning, title: message)
        }
        if share.relayWithoutKeys {
            Banner(.warning, title: "Ретранслятор без проверки ключей",
                   message: "Личность зрителей не подтверждается, «Всегда разрешать» недоступно.")
        }
        if case .live = share.state {
            ListCard {
                Row(share.watchers.isEmpty ? "Пока никто не смотрит." : "Смотрят: " + share.watchers.joined(separator: ", "),
                    systemImage: "eye")
                ForEach(share.audience) { watcher in
                    Row(watcher.name.isEmpty ? ShareCode.display(watcher.id) : watcher.name, systemImage: "eye") {
                        Button("Сыграть в крестики-нолики") { share.playGame(with: watcher) }
                            .buttonStyle(.graphite(.secondary, size: .compact))
                    }
                }
            }
        }
        Footnote("Этот ID постоянный — по нему к вам подключаются. Каждого зрителя вы сначала разрешаете (или отмечаете «Всегда разрешать»). Управлять вашим Mac зритель не может.")

        GroupLabel("Подключиться")
        connectCard
        Footnote("Смотреть друг друга: оба начинают трансляцию и подключаются по ID друг к другу.")

        GroupLabel("История")
        ListCard {
            if demo {
                EmptyState("Здесь появятся те, к кому вы подключались.", systemImage: "clock.arrow.circlepath", compact: true)
            } else {
                ShareHistoryRows()
            }
        }
        if !compact && !demo { TrustedRows() }

        GroupLabel("Метки зрителей")
        ListCard {
            ToggleRow("Разрешить зрителям ставить метки и рисовать",
                      subtitle: "Зритель кликает или рисует по картинке — у вас на экране появляется метка «сюда!» или линия, и через пару секунд исчезает. Управлять вашим Mac зритель не может.",
                      systemImage: "scope", isOn: $allowMarks)
        }

        GroupLabel("Звук")
        ListCard {
            ToggleRow("Передавать звук системы",
                      subtitle: "Зрители слышат то, что играет на Mac (видео, музыку, звонок). Микрофон не передаётся.",
                      systemImage: "speaker.wave.2", isOn: $shareAudio)
        }
        if shareAudio { MutedAppsList(demo: demo) }

        GroupLabel("Для собеседника на Windows")
        ListCard {
            Row("На Windows смотрят и транслируют в приложении Mac Utils Share. Отправьте ссылку на него собеседнику.",
                systemImage: "link") {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.windowsLink, forType: .string)
                    Toast.show("Ссылка для Windows скопирована", symbol: "link")
                } label: { Label("Скопировать ссылку", systemImage: "link") }
                .buttonStyle(.graphite(.secondary, size: .compact))
            }
        }

        if !compact || server.isEmpty {
            GroupLabel("Сервер")
            // Подпись над полем: в узкой панели поле справа от подписи сжимало её до столбика.
            Card {
                Text("Адрес сервера").font(DS.Font.rowTitle).foregroundStyle(.dsText)
                TextField("", text: $server, prompt: Text("https://mac-utils-relay….workers.dev"))
                    .textFieldStyle(.graphiteMono)
                    .frame(maxWidth: 420, alignment: .leading)
                    .accessibilityLabel("Адрес сервера")
            }
            Footnote("Ретранслятор из папки relay/ проекта (Cloudflare Workers). Экран идёт через него в зашифрованном соединении и нигде не сохраняется.")
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = share.state { return message }
        return nil
    }

    /// Свой ID крупно, копирование и состояние трансляции.
    private var idCard: some View {
        Card {
            // Широко — ID и кнопки в одну строку; узко (поповер, ~420) — кнопки под ID на всю ширину. ID всегда в одну строку.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.m) {
                    idLine
                    Spacer(minLength: DS.Space.s)
                    stateControls(fill: false)
                }
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    idLine
                    stateControls(fill: true)
                }
            }
            if share.needsNewID {
                Button { share.confirmRenewID() } label: { Label("Получить новый ID…", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.graphite(.primary, size: .compact))
            }
            if let fp = fingerprint {
                // Широко — в одну строку; узко — отпечаток, а под ним «Получить новый ID…» (без обрезанной кнопки).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.m) {
                        fingerprintLine(fp)
                        Spacer(minLength: DS.Space.s)
                        renewIDButton
                    }
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        fingerprintLine(fp)
                        renewIDButton
                    }
                }
            }
        }
    }

    private func fingerprintLine(_ fp: String) -> some View {
        HStack(spacing: DS.Space.m) {
            Text("Отпечаток этого Mac").font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize()
            Text(fp).font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsText)
                .lineLimit(1).fixedSize().textSelection(.enabled)
        }
    }

    @ViewBuilder private var renewIDButton: some View {
        if !share.needsNewID {
            Button("Получить новый ID…") { share.confirmRenewID() }
                .buttonStyle(.graphite(.ghost, size: .compact))
                .fixedSize()
                .help("Заменить ключ и ID этого Mac")
        }
    }

    /// ID моноширинным в одну строку (при нехватке места шрифт уменьшается, а не переносится) и «Скопировать ID».
    private var idLine: some View {
        HStack(spacing: DS.Space.m) {
            Text(ShareCode.display(myID))
                .font(DS.Font.mono(26, relativeTo: .title))
                .foregroundStyle(.dsText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .layoutPriority(1)
            IconButton("Скопировать ID", systemImage: "doc.on.doc", compact: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(myID, forType: .string)
                Toast.show("ID скопирован", symbol: "doc.on.doc.fill")
            }
        }
    }

    /// Состояние трансляции и кнопки; `fill` — кнопки на всю ширину (под ID в узкой панели).
    @ViewBuilder private func stateControls(fill: Bool) -> some View {
        switch share.state {
        case .idle, .failed:
            Button { share.start() } label: { Label("Начать трансляцию…", systemImage: "dot.radiowaves.left.and.right") }
                .help("Откроется выбор: весь экран, окно или программа")
                .buttonStyle(.graphite(.primary, size: fill ? .regular : .compact, fill: fill))
                .disabled(server.isEmpty)
        case .connecting:
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text("Подключаюсь…").font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize()
                if fill { Spacer(minLength: 0) }
                Button("Отмена") { share.cancelConnecting() }.buttonStyle(.graphite(.secondary, size: .compact))
            }
        case .live:
            HStack(spacing: DS.Space.s) {
                Pill(.danger, "В эфире", caps: true)
                if fill { Spacer(minLength: 0) }
                Button("Сменить экран…") { share.changeSource() }.buttonStyle(.graphite(.secondary, size: .compact)).fixedSize()
                Button("Стоп") { share.stop() }.buttonStyle(.graphite(.danger, size: .compact)).fixedSize()
            }
        }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            // Поле на всю ширину и «Смотреть» в одну строку (без заголовка строки: его роль играет «Подключиться»).
            Card {
                HStack(spacing: DS.Space.s) {
                    TextField("", text: $code, prompt: Text("ID собеседника, 10 цифр"))
                        .textFieldStyle(.graphiteMono)
                        .frame(maxWidth: .infinity)
                        .onSubmit { viewer.watch(code: code) }
                        .accessibilityLabel("ID собеседника")
                    Button("Смотреть") { viewer.watch(code: code) }
                        .buttonStyle(.graphite(.primary))
                        .fixedSize()
                        .disabled(ShareCode.normalized(code) == nil || server.isEmpty)
                }
            }
            if case .ended(let message) = viewer.state {
                Footnote(message)
            }
            if let change = viewer.keyChange {
                Banner(.warning, title: change.warning) {
                    Button("Подключиться и запомнить") { viewer.acceptKeyChange() }.buttonStyle(.graphite(.primary, size: .compact))
                    Button("Отмена") { viewer.dismissKeyChange() }.buttonStyle(.graphite(.secondary, size: .compact))
                }
            }
        }
    }
}

/// История: отметка эфира, подпись, «Смотреть», переименовать, удалить (строки карточки).
private struct ShareHistoryRows: View {
    @ObservedObject private var history = ShareHistory.shared
    @ObservedObject private var viewer = ShareViewer.shared
    @State private var renaming: ShareHistory.Entry?
    @State private var newLabel = ""

    var body: some View {
        Group {
            if history.visitedEntries.isEmpty {
                EmptyState("Здесь появятся те, к кому вы подключались.", systemImage: "clock.arrow.circlepath", compact: true)
            }
            ForEach(history.visitedEntries) { entry in
                let live = history.live.contains(entry.id)
                Row(entry.title, subtitle: "\(ShareCode.display(entry.id)) · \(entry.lastSeen.formatted(date: .abbreviated, time: .shortened))",
                    systemImage: "person.crop.circle", tile: live ? .accent : .neutral) {
                    HStack(spacing: DS.Space.s) {
                        if live { Pill(.success, "В эфире") }
                        Button("Смотреть") { viewer.watch(code: entry.id) }.buttonStyle(.graphite(.secondary, size: .compact)).fixedSize()
                        // Переименовать и удалить — в меню: в узкой панели четыре кнопки сжимали подпись строки.
                        Menu {
                            Button("Переименовать") { newLabel = entry.label ?? entry.name; renaming = entry }
                            Button("Удалить из истории", role: .destructive) { history.remove(entry.id) }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: DS.Size.rowTile, height: DS.Size.rowTile)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Переименовать или удалить")
                        .accessibilityLabel("Ещё")
                    }
                }
                .help(live ? "Сейчас в эфире" : "Сейчас не транслирует")
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

/// Доверенные — их пускаем без вопроса.
private struct TrustedRows: View {
    @ObservedObject private var history = ShareHistory.shared

    var body: some View {
        if !history.trustedEntries.isEmpty {
            GroupLabel("Пускать без вопроса")
            ListCard {
                ForEach(history.trustedEntries) { entry in
                    Row(entry.title, subtitle: ShareCode.display(entry.id), systemImage: "checkmark.shield") {
                        Button("Убрать") { history.untrust(entry.id) }.buttonStyle(.graphite(.secondary, size: .compact))
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
/// Заглушённая программа — красный чип (как в окне зрителя и на Windows).
private struct MutedAppsList: View {
    var demo = false
    @State private var muted: Set<String> = []
    @State private var apps: [(id: String, name: String, icon: NSImage)] = []

    var body: some View {
        Card {
            Text("Не передавать звук программ:").font(DS.Font.rowTitle).foregroundStyle(.dsText)
            FlowLayout(spacing: DS.Space.s, lineSpacing: DS.Space.s) {
                ForEach(apps, id: \.id) { app in
                    let on = muted.contains(app.id)
                    Button {
                        if on { muted.remove(app.id) } else { muted.insert(app.id) }
                        UserDefaults.standard.set(Array(muted).sorted(), forKey: Pref.shareMutedApps)
                        ScreenShare.shared.refreshAudioFilter()
                    } label: {
                        HStack(spacing: 6) {
                            Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                            Text(app.name).font(DS.Font.chip).lineLimit(1)
                        }
                        .foregroundStyle(on ? Color.dsRecInk : Color.dsText)
                        .padding(.vertical, 6)
                        .padding(.leading, 8)
                        .padding(.trailing, 12)
                        .background(on ? Color.dsRec : Color.dsField, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? .clear : Color.dsLine, lineWidth: 1))
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(app.name)
                    .accessibilityValue(on ? "Звук не передаётся" : "Звук передаётся")
                    .accessibilityAddTraits(.isButton)
                }
            }
            Text("Заглушённые программы зрители не слышат; у вас звук остаётся. Меняется и во время трансляции.")
                .font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: load)
    }

    private func load() {
        if demo {
            let icon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
            apps = ["Discord", "Spotify", "Zoom", "Chrome", "Telegram"].map { (id: "demo.\($0)", name: $0, icon: icon) }
            muted = ["demo.Discord", "demo.Spotify"]
            return
        }
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
