import AVFoundation
import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import MUCore
import MUDesign

/// Код комнаты и адрес (без сети — для тестов).
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
    /// Звук через Core Audio process tap (`ShareAudioTap`, macOS 14.2+); иначе — `audioStream` ScreenCaptureKit.
    private var audioTap: AnyObject?
    private var audioWatcher: ShareAudioWatcher?
    /// Пока перехват ни разу не дал звука: проверка раз в секунду — только запись в журнал, без отката на SCK.
    private var audioCheck: Timer?
    private var audioPermission = PermissionWatch()
    /// Откат на ScreenCaptureKit уже показан в этой трансляции (Toast — один раз).
    private var audioFallbackShown = false
    /// «Нет звука из перехвата» уже показано в этой трансляции.
    private var audioSilenceShown = false
    /// Повтор перехвата после ошибки — один раз на новую обстановку (выход, набор программ), а не на каждую пересборку.
    private var tapRetry = ShareTapRetry()
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
                ShareMarksOverlay.shared.attach(to: videoFilter ?? filter, display: videoDisplayID)
                listen(socket)
                showHUD()
                watchDisplays()
                announceDisplays()
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

    /// Весь звук системы, кроме Mac Utils и программ, которые пользователь заглушил для трансляции (запасной путь —
    /// ScreenCaptureKit, до macOS 14.2 или без разрешения на перехват). Окна — все, а не только видимые: программа,
    /// свёрнутая или на другом рабочем столе, иначе не попадает в список и её звук идёт зрителям.
    private static func audioFilter() async throws -> (SCContentFilter, [ShareAudioProcess]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let processes = content.applications.map {
            ShareAudioProcess(object: 0, pid: $0.processID, bundleID: $0.bundleIdentifier,
                              ownerBundleID: ShareAudioExclusion.ownerBundleID(of: $0.processID))
        }
        let excluded = ShareAudioExclusion.excluded(processes, muted: ShareAudioExclusion.currentMuted,
                                                    ownPID: ProcessInfo.processInfo.processIdentifier)
        let pids = Set(excluded.map(\.pid))
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { pids.contains($0.processID) },
                                     exceptingWindows: [])
        return (filter, excluded)
    }

    /// Исключаемые объекты Core Audio для перехвата.
    private static func tapExclusion() -> [ShareAudioProcess] {
        ShareAudioExclusion.excluded(ShareAudioExclusion.audioProcesses(), muted: ShareAudioExclusion.currentMuted,
                                     ownPID: ProcessInfo.processInfo.processIdentifier)
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

    /// Список заглушённых изменился, программа запустилась или закрылась, процесс открыл звук (начался звонок) —
    /// пересобираем список исключённых.
    func refreshAudioFilter() {
        // Откатились на SCK из-за ошибки перехвата — пробуем перехват снова, когда сменился выход или набор программ.
        if #available(macOS 14.2, *), audioTap == nil, let stream = audioStream, let sender,
           tapRetry.shouldTry(ShareTapRetry.situation()), retryTap(sender: sender) {
            audioStream = nil
            Task { try? await stream.stopCapture() }
        }
        if #available(macOS 14.2, *), let tap = audioTap as? ShareAudioTap {
            // Выход сменился (отключили наушники): перехват собран при прежнем выходе — собираем заново.
            // …или у того же выхода сменилась частота (AirPods + звонок → HFP): конвертер устарел.
            if tap.outputDevice != CoreAudioHelper.defaultOutputDevice || tap.formatChanged {
                do {
                    try tap.restart()
                    Log.capture.info("Звук трансляции: выход или частота сменились, перехват пересобран")
                    watchTapStart(tap)
                } catch {
                    Log.capture.error("Звук трансляции: перехват не пересобран — \(error.localizedDescription, privacy: .public); переходим на ScreenCaptureKit")
                    fallBackToStream()
                    return
                }
            }
            let excluded = Self.tapExclusion()
            let objects = excluded.map(\.object).sorted()
            guard objects != tap.excluded else { return }
            do {
                let result = try tap.update(excluding: objects)
                Log.capture.info("Звук трансляции: исключено \(ShareAudioExclusion.summary(excluded), privacy: .public)\(result == .deferred ? " (после первых колбэков)" : "", privacy: .public)")
                if result == .applied { watchTapAfterUpdate(tap) }
                if result == .rebuilt { watchTapStart(tap) }
            } catch {
                Log.capture.error("Звук трансляции: список исключённых не обновлён — \(error.localizedDescription, privacy: .public)")
                // Пересборка с новым списком не удалась — перехват остановлен: запасной способ, а не тишина.
                if !tap.isRunning {
                    tapRetry.failed(in: ShareTapRetry.situation())
                    fallBackToStream()
                }
            }
            return
        }
        guard let audioStream else { return }
        Task {
            guard let (filter, excluded) = try? await Self.audioFilter() else { return }
            try? await audioStream.updateContentFilter(filter)
            Log.capture.info("Звук трансляции (SCK): исключено \(ShareAudioExclusion.summary(excluded), privacy: .public)")
        }
    }

    /// Звук трансляции: перехват Core Audio (исключает и помощников программ), без него — ScreenCaptureKit.
    private func startAudio(sender: FrameSender) async throws {
        audioFallbackShown = false
        audioSilenceShown = false
        tapRetry = ShareTapRetry()
        if #available(macOS 14.2, *), !retryTap(sender: sender) { showAudioFallback() }
        if audioTap == nil { audioStream = try await makeAudioStream(sender: sender) }
        audioWatcher = ShareAudioWatcher { ScreenShare.shared.refreshAudioFilter() }
        // Свой процесс появляется в Core Audio только с началом перехвата — сразу и его в исключённые.
        refreshAudioFilter()
    }

    /// Запустить перехват; false — явная ошибка Core Audio (создание перехвата или агрегата, запуск).
    @available(macOS 14.2, *)
    private func retryTap(sender: FrameSender) -> Bool {
        let excluded = Self.tapExclusion()
        do {
            audioTap = try ShareAudioTap(excluding: excluded.map(\.object).sorted()) { [weak sender] samples in
                sender?.sendAudio(samples)
            }
        } catch {
            Log.capture.error("Звук трансляции: перехват не запустился — \(error.localizedDescription, privacy: .public)")
            tapRetry.failed(in: ShareTapRetry.situation())
            return false
        }
        tapRetry = ShareTapRetry()
        Log.capture.info("Звук трансляции: перехват, исключено \(ShareAudioExclusion.summary(excluded), privacy: .public)")
        // Частота сменилась посреди трансляции — та же пересборка, что при смене выхода.
        (audioTap as? ShareAudioTap)?.onFormatChange = { ScreenShare.shared.refreshAudioFilter() }
        if let tap = audioTap as? ShareAudioTap { watchTapStart(tap) }
        audioPermission = PermissionWatch()
        startAudioCheck()
        return true
    }

    /// Сторож запуска перехвата (`ShareTapWatchdog`): через 3 с после запуска — ни одного колбэка IOProc или ни одного
    /// буфера перехвата с данными — это ошибка Core Audio, звук через ScreenCaptureKit (с Toast), перехват — снова при
    /// новой обстановке (`tapRetry`). Тишина при идущих колбэках не откатывает (там помощники Discord не исключаются).
    @available(macOS 14.2, *)
    private func watchTapStart(_ tap: ShareAudioTap) {
        let generation = tap.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + ShareTapWatchdog.window) {
            MainActor.assumeIsolated {
                let share = ScreenShare.shared
                guard let current = share.audioTap as? ShareAudioTap, current === tap, tap.generation == generation else { return }
                let report = tap.watchdogReport()
                Log.capture.info("Звук трансляции: \(report.summary, privacy: .public)")
                guard report.verdict != .ok else {
                    // Колбэки идут — теперь применить отложенный список исключённых (свой процесс, поздние помощники).
                    do {
                        switch try tap.confirmIO() {
                        case .applied: share.watchTapAfterUpdate(tap)
                        case .rebuilt: share.watchTapStart(tap)
                        default: break
                        }
                    } catch {
                        Log.capture.error("Звук трансляции: отложенный список исключённых не применён — \(error.localizedDescription, privacy: .public)")
                        if !tap.isRunning {
                            share.tapRetry.failed(in: ShareTapRetry.situation())
                            share.fallBackToStream()
                        }
                    }
                    return
                }
                // Часы агрегата не пошли — ещё раз на встроенном выходе, потом уже запасной способ.
                if report.verdict == .noCallbacks, (try? tap.retryWithBuiltInClock()) == true {
                    Log.capture.error("Звук трансляции: нет колбэков — перехват пересобран на встроенном выходе")
                    share.watchTapStart(tap)
                    return
                }
                Log.capture.error("Звук трансляции: перехват не работает (\(report.verdict == .noCallbacks ? "нет колбэков" : "нет данных", privacy: .public)) — переходим на ScreenCaptureKit")
                share.tapRetry.failed(in: ShareTapRetry.situation())
                share.fallBackToStream()
            }
        }
    }

    /// После смены описания перехвата на ходу: колбэки за 1,5 с не прибавились — смена их остановила. Пересобираем перехват
    /// с новым списком, дальше список меняется только пересборкой.
    @available(macOS 14.2, *)
    private func watchTapAfterUpdate(_ tap: ShareAudioTap) {
        let generation = tap.generation, before = tap.callbackCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                let share = ScreenShare.shared
                guard let current = share.audioTap as? ShareAudioTap, current === tap, tap.generation == generation else { return }
                let after = tap.callbackCount
                guard after == before else { return }
                Log.capture.error("Звук трансляции: после смены списка исключённых колбэков нет (\(before, privacy: .public) → \(after, privacy: .public)) — пересобираю перехват")
                do {
                    try tap.rebuildAfterStalledUpdate()
                    share.watchTapStart(tap)
                } catch {
                    share.tapRetry.failed(in: ShareTapRetry.situation())
                    share.fallBackToStream()
                }
            }
        }
    }

    /// Звук пошёл через ScreenCaptureKit: помощники заглушённых программ (Discord) там не исключаются — говорим об этом.
    private func showAudioFallback() {
        guard !audioFallbackShown else { return }
        audioFallbackShown = true
        Toast.show(ShareAudioFallback.message(muteCalls: UserDefaults.standard.bool(forKey: Pref.shareMuteCalls),
                                              mutedApps: (UserDefaults.standard.stringArray(forKey: Pref.shareMutedApps) ?? []).count),
                   symbol: "exclamationmark.triangle.fill", tint: .orange)
    }

    private func makeAudioStream(sender: FrameSender) async throws -> SCStream {
        let (filter, excluded) = try await Self.audioFilter()
        let audioStream = SCStream(filter: filter, configuration: Self.audioConfiguration(), delegate: sender)
        try audioStream.addStreamOutput(sender, type: .audio, sampleHandlerQueue: sender.audioQueue)
        try await audioStream.startCapture()
        Log.capture.info("Звук трансляции (SCK): исключено \(ShareAudioExclusion.summary(excluded), privacy: .public)")
        return audioStream
    }

    /// Перехват не годится — звук через ScreenCaptureKit. Трансляцию могли остановить, пока поток запускался:
    /// тогда сразу гасим его, а не оставляем захват звука после «Стоп».
    private func fallBackToStream() {
        if #available(macOS 14.2, *) { (audioTap as? ShareAudioTap)?.stop() }
        audioTap = nil
        audioCheck?.invalidate()
        audioCheck = nil
        guard let sender else { return }
        showAudioFallback()
        Task {
            guard let stream = try? await makeAudioStream(sender: sender) else { return }
            // Остановили трансляцию или перехват уже снова заработал (пересборка) — этот поток не нужен.
            guard self.sender === sender, audioTap == nil else {
                try? await stream.stopCapture()
                return
            }
            audioStream = stream
        }
    }

    /// Без разрешения Core Audio молча отдаёт тишину, но тишину шлют и программы, которые просто держат вывод открытым.
    /// Поэтому на SCK не откатываемся (там помощники Discord не исключаются — вернулось бы эхо): пока звук ни разу не
    /// пришёл, раз в секунду смотрим, играет ли что-то, и после 10 с тишины пишем в журнал. Решение принято — таймер стоп.
    private func startAudioCheck() {
        audioCheck?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ScreenShare.shared.checkAudioPermission() }
        }
        RunLoop.main.add(timer, forMode: .common)
        audioCheck = timer
    }

    private func checkAudioPermission() {
        guard #available(macOS 14.2, *), let tap = audioTap as? ShareAudioTap else {
            audioCheck?.invalidate()
            audioCheck = nil
            return
        }
        let excluded = Set(tap.excluded)
        let playing = CoreAudioHelper.readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).contains {
            !excluded.contains($0) && CoreAudioHelper.read($0, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
        }
        let tripped = audioPermission.record(anyPlaying: playing, anySound: tap.takePeak() > 0.0001)
        guard audioPermission.proven || tripped else { return }
        audioCheck?.invalidate()
        audioCheck = nil
        guard tripped else { return }
        Log.capture.error("Звук трансляции: перехват молчит 10 с, хотя программы держат вывод — возможно, нет разрешения на запись звука")
        // Подсказка ведущему, как в «Громкости приложений»: иначе зрители молча остаются без звука.
        guard !audioSilenceShown else { return }
        audioSilenceShown = true
        // Без разрешения «Запись системного звука» Core Audio отдаёт тишину: кнопка ведёт в настройки, сам запрос не делаем.
        Toast.show("Нет звука из перехвата — если зрители не слышат звук, разрешите Mac Utils «Только системный звук» в «Запись экрана и системного звука»",
                   symbol: "exclamationmark.triangle.fill", tint: .orange,
                   action: Toast.Action(title: "Открыть настройки") { Permissions.open(.screenRecording) })
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
            // Пока источник меняется, запросы зрителей получают busy: иначе их переключение могло лечь поверх выбора ведущего.
            self.switchingDisplay = true
            Task {
                let filter = await self.prepared(filter)
                try? await stream.updateContentFilter(filter)
                try? await stream.updateConfiguration(config)
                self.switchingDisplay = false
                // Экран или окно — зрители видят или теряют мониторы; метки — на новом экране.
                ShareMarksOverlay.shared.attach(to: filter, display: self.videoDisplayID)
                ShareRequestQueue.shared.screenChanged()
                self.announceDisplays()
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

    // MARK: - Мониторы: зрители переключают сами (SHARE-PROTOCOL §4.1)

    /// Объявленные зрителям мониторы и их экраны (CGDirectDisplayID — только внутри процесса, зрителям не уходит).
    private var hostDisplays: [(display: ShareDisplay, id: CGDirectDisplayID)] = []
    private var displaysRevision = ShareDisplays.Revision()
    private var switchingDisplay = false
    private var lastDisplaySwitch: Date?
    private var lastDisplaysAnnounce: Date?
    private var screensObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var recoveringCapture = false

    /// Номер транслируемого монитора (nil — окно или программа).
    private var currentDisplayNumber: Int? {
        videoDisplayID.flatMap { id in hostDisplays.first { $0.id == id }?.display.n }
    }

    /// Мониторы — всем зрителям. Переключение выключено или показывается окно — пустой список: кнопки у зрителей нет.
    func announceDisplays() {
        guard isLive, let socket else { return }
        hostDisplays = ShareDisplays.list(ShareDisplays.screens())
        let list = hostDisplays.map(\.display)
        let message = ShareDisplays.message(rev: displaysRevision.update(list), list: list, current: currentDisplayNumber,
                                            allowed: UserDefaults.standard.bool(forKey: Pref.shareAllowMonitorSwitch),
                                            video: sender?.videoMode)
        socket.send(.string(message)) { _ in }
        lastDisplaysAnnounce = Date()
    }

    /// Подключили, отключили монитор, сменили масштаб или раскладку — список заново.
    private func watchDisplays() {
        guard screensObserver == nil else { return }
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenShare.shared.announceDisplays() }
        }
        // После сна захват часто молча замирает: пересоздаём его (зрители видят последний кадр, потом картинка идёт).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                         object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenShare.shared.checkCaptureAfterWake() }
        }
    }

    /// После пробуждения поток обычно жив: пересоздаём, только если экран молчит (даже «пустых» кадров нет) дольше 3 с.
    func checkCaptureAfterWake() {
        guard isLive, let sender else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.isLive, self.sender === sender else { return }
            if sender.secondsSinceScreenSample > 3 { self.recoverCapture(afterSleep: true) }
        }
    }

    /// Захват экрана остановился (сон, выдернули монитор): для экрана пробуем собрать поток заново, для окна и программы
    /// такого экрана нет — эфир заканчивается с понятной причиной.
    func captureStopped(_ stopped: SCStream) {
        // Остановился не текущий поток (старый, уже заменённый) или пересборка уже идёт — ничего не делаем.
        guard isLive, !recoveringCapture, stream == nil || stream === stopped else { return }
        guard videoDisplayID != nil else { return stop(reason: "Захват остановлен: окно закрыто или недоступно") }
        recoverCapture(afterSleep: false)
    }

    /// Пересоздать поток экрана: тот же монитор, если он есть, иначе основной. Попытки с паузой 1, 2, 4, 8, 15 с;
    /// звук, сокет и кодер остаются, ключевой кадр уходит сразу после запуска.
    func recoverCapture(afterSleep: Bool) {
        guard isLive, let sender, videoDisplayID != nil, !recoveringCapture else { return }
        recoveringCapture = true
        let old = stream
        stream = nil
        Log.capture.info("Трансляция: захват пересоздаётся (сон \(afterSleep ? 1 : 0))")
        let oldAudio = audioStream
        Task { [weak self] in
            try? await old?.stopCapture()
            // Запасной звук ScreenCaptureKit (без tap) живёт на том же делегате: после сна пересоздаём и его.
            if let oldAudio {
                try? await oldAudio.stopCapture()
                if let self, self.isLive, self.sender === sender { self.audioStream = nil; try? await self.startAudio(sender: sender) }
            }
            for delay in [1.0, 2, 4, 8, 15] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.isLive, self.sender === sender else { return }
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                      let display = content.displays.first(where: { $0.displayID == self.videoDisplayID })
                        ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { continue }
                let filter = Self.displayFilter(display, content: content)
                let fresh = SCStream(filter: filter, configuration: Self.videoConfiguration(for: filter), delegate: sender)
                do {
                    try fresh.addStreamOutput(sender, type: .screen, sampleHandlerQueue: sender.queue)
                    try await fresh.startCapture()
                } catch {
                    Log.capture.error("Трансляция: захват не пересоздан, код \((error as NSError).code)")
                    continue
                }
                // Эфир могли остановить (или начать новый) за время запуска — тогда новый поток никому не нужен.
                guard self.isLive, self.sender === sender else {
                    try? await fresh.stopCapture()
                    self.recoveringCapture = false
                    return
                }
                self.stream = fresh
                self.videoFilter = filter
                self.streamSizeOverride = nil
                self.videoDisplayID = display.displayID
                ShareMarksOverlay.shared.attach(to: filter, display: display.displayID)
                sender.requestKeyFrame()
                self.recoveringCapture = false
                self.announceDisplays()
                return
            }
            guard let self else { return }
            self.recoveringCapture = false
            if self.isLive { self.stop(reason: "Захват экрана остановлен") }
        }
    }

    private func stopWatchingDisplays() {
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        screensObserver = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        recoveringCapture = false
        hostDisplays = []
        switchingDisplay = false
        lastDisplaySwitch = nil
        lastDisplaysAnnounce = nil
    }

    /// Зритель просит другой монитор: вопроса нет, решает настройка (`ShareMonitorSwitch.decide`).
    private func handleSwitch(_ request: ShareMonitorSwitch.Request) {
        let state = ShareMonitorSwitch.HostState(allowed: UserDefaults.standard.bool(forKey: Pref.shareAllowMonitorSwitch),
                                                 screen: currentDisplayNumber != nil, rev: displaysRevision.value,
                                                 list: hostDisplays.map(\.display), current: currentDisplayNumber,
                                                 switching: switchingDisplay, lastSwitchAt: lastDisplaySwitch)
        let decision = ShareMonitorSwitch.decide(state, display: request.display, rev: request.rev, now: Date())
        guard decision == .change, let target = hostDisplays.first(where: { $0.display.n == request.display }) else {
            reply(to: request, decision.rawValue)
            // Свежий список — не чаще раза в секунду: поток устаревших запросов не опрашивает мониторы и не рассылает его всем.
            if decision == .off || decision == .stale,
               ShareMonitorSwitch.shouldReannounce(last: lastDisplaysAnnounce, now: Date()) { announceDisplays() }
            return
        }
        switchingDisplay = true
        Task {
            let noticeHidden = await switchDisplay(to: target.id)
            switchingDisplay = false
            guard isLive else { return }
            let allowed = UserDefaults.standard.bool(forKey: Pref.shareAllowMonitorSwitch)
            let result = ShareMonitorSwitch.result(switched: noticeHidden != nil, allowed: allowed)
            if noticeHidden != nil { lastDisplaySwitch = Date() }
            reply(to: request, result)
            guard let noticeHidden else { return }
            announceDisplays()
            // Уведомление — в окне меток на новом мониторе, только если оно точно исключено из захвата.
            if noticeHidden {
                ShareMarksOverlay.shared.notice(name: request.name, monitor: request.display, displays: hostDisplays.map(\.display))
            }
        }
    }

    private func reply(to request: ShareMonitorSwitch.Request, _ result: String) {
        guard !request.from.isEmpty,
              let message = ShareMonitorSwitch.resultMessage(to: request.from, display: request.display, result: result) else { return }
        socket?.send(.string(message)) { _ in }
    }

    /// Другой монитор в тот же поток, без переподключения (как «Сменить источник»): фильтр, размер, окно меток.
    /// Кодер H.264 пересоздаётся сам по размеру кадра, и первым идёт ключевой. nil — не переключилось; иначе — попало ли
    /// окно меток (а с ним уведомление) в исключения нового фильтра.
    private func switchDisplay(to id: CGDirectDisplayID) async -> Bool? {
        guard let stream,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let filter = Self.displayFilter(display, content: content)
        let noticeHidden = ShareMonitorSwitch.windowExcluded(ShareMarksOverlay.shared.windowNumber,
                                                            from: content.windows.map { Int($0.windowID) })
        do {
            try await stream.updateContentFilter(filter)
        } catch {
            Log.capture.error("Трансляция: монитор не переключился, код \((error as NSError).code)")
            return nil
        }
        // Фильтр уже новый: размер не встал — картинка всё равно с нового монитора, только пока в старом размере.
        do { try await stream.updateConfiguration(Self.videoConfiguration(for: filter)) }
        catch { Log.capture.error("Трансляция: размер потока не сменился, код \((error as NSError).code)") }
        guard self.stream === stream else { return nil }
        videoFilter = filter
        streamSizeOverride = nil
        videoDisplayID = id
        // Метки относились к прежнему монитору; окно меток и панель запросов — на новый.
        ShareMarksOverlay.shared.store.clear()
        ShareMarksOverlay.shared.attach(to: filter, display: id)
        ShareRequestQueue.shared.screenChanged()
        return noticeHidden
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
        if UserDefaults.standard.bool(forKey: Pref.shareAudio) { try await startAudio(sender: sender) }
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
        timer.tolerance = 2
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
                            case "switch-request":
                                if let request = ShareMonitorSwitch.parseRequest(json) { self.handleSwitch(request) }
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
                                // Новый зритель (или тот же после переподключения) получает мониторы без хранения на relay.
                                self.announceDisplays()
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
            for delay in ShareHostReconnect.delays {
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
                    announceDisplays()
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
        stopWatchingDisplays()
        teardownCapture()
        heartbeat?.invalidate()
        heartbeat = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        hud?.orderOut(nil)
        hud = nil
        state = reason.map { .failed($0) } ?? .idle
    }

    /// Остановить захват видео и звука и слежение за программами (общая часть «Стоп» и сбоя старта — SH2).
    private func teardownCapture() {
        let stream = self.stream
        let audioStream = self.audioStream
        self.stream = nil
        self.audioStream = nil
        videoFilter = nil
        streamSizeOverride = nil
        if #available(macOS 14.2, *) { (audioTap as? ShareAudioTap)?.stop() }
        audioTap = nil
        audioWatcher?.stop()
        audioWatcher = nil
        audioCheck?.invalidate()
        audioCheck = nil
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
        ScreenOutput.activateApp()
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
        panel.orderFrontRegardlessOnScreen()
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

/// Отправка звука с пределом очереди: считает байты, отданные сокету и ещё не подтверждённые. Больше предела —
/// новый пакет отбрасывается (короткий провал в звуке лучше, чем очередь, которая растёт, пока не кончится память).
final class ShareAudioSender: @unchecked Sendable {
    /// ≈ 2 с звука трансляции (24 кГц, моно, Int16 — 48 000 байт в секунду).
    static let defaultLimit = 96_000

    private let lock = NSLock()
    private let limit: Int
    private let transport: (Data, @escaping () -> Void) -> Void
    private var pendingBytes = 0
    private(set) var dropped = 0

    /// `transport(данные, готово)` — отправить и вызвать `готово`, когда сокет закончил с пакетом (успешно или нет).
    init(limit: Int = ShareAudioSender.defaultLimit, send transport: @escaping (Data, @escaping () -> Void) -> Void) {
        self.limit = limit
        self.transport = transport
    }

    var pending: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingBytes
    }

    func send(_ packet: Data) {
        let size = packet.count
        lock.lock()
        guard pendingBytes + size <= limit else {
            dropped += 1
            lock.unlock()
            return
        }
        pendingBytes += size
        lock.unlock()
        transport(packet) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingBytes = max(0, self.pendingBytes - size)
            self.lock.unlock()
        }
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

    private var lastSampleAt = ProcessInfo.processInfo.systemUptime
    private func noteScreenSample() { lock.lock(); lastSampleAt = ProcessInfo.processInfo.systemUptime; lock.unlock() }
    /// Сколько секунд от экрана не было ни одного кадра (в том числе «без изменений»).
    var secondsSinceScreenSample: Double { lock.lock(); defer { lock.unlock() }; return ProcessInfo.processInfo.systemUptime - lastSampleAt }

    /// Захват пересоздан: ключевой кадр сразу, чтобы зрители не ждали следующего.
    func requestKeyFrame() { queue.async { self.encoder.requestKeyFrame() } }

    func replace(_ socket: URLSessionWebSocketTask) {
        lock.lock()
        currentSocket = socket
        // Новый сокет — свой счёт неотправленного звука: хвост старого больше не держит очередь.
        audio = Self.audioSender(socket)
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
        encoder.onSession = { [weak self, weak encoder] in
            self?.governor.warmUp(now: ProcessInfo.processInfo.systemUptime)
            self?.noteVideoMode(encoder?.usesHardware)
        }
        return encoder
    }()

    /// Как кодируется видео — зрителям в `displays` (`video`): hw — видеокарта, sw — программно.
    private let modeLock = NSLock()
    private var mode: String?
    var videoMode: String? { modeLock.lock(); defer { modeLock.unlock() }; return mode }
    private func noteVideoMode(_ hardware: Bool?) {
        let next = hardware.map { $0 ? "hw" : "sw" }
        modeLock.lock()
        let changed = next != mode
        mode = next
        modeLock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { ScreenShare.shared.announceDisplays() } }
    }

    init(socket: URLSessionWebSocketTask) {
        currentSocket = socket
        audio = Self.audioSender(socket)
    }

    /// Звук — со своим пределом очереди: на медленной сети пакеты, которые не успевают уйти, отбрасываются,
    /// а не копятся в `URLSessionWebSocketTask` (≈ 170 МБ в час без предела).
    private var audio: ShareAudioSender
    private static func audioSender(_ socket: URLSessionWebSocketTask) -> ShareAudioSender {
        ShareAudioSender { data, done in socket.send(.data(data)) { _ in done() } }
    }
    private var currentAudio: ShareAudioSender {
        lock.lock(); defer { lock.unlock() }
        return audio
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

    /// Звук перехвата Core Audio (24 кГц моно) — тем же пакетом и через ту же очередь с пределом, что и от ScreenCaptureKit.
    func sendAudio(_ samples: [Float]) {
        guard !isPaused, !samples.isEmpty else { return }
        currentAudio.send(ShareProtocol.audioPacket(samples))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if !isPaused, let packet = ShareProtocol.audioPacket(sampleBuffer) {
                currentAudio.send(packet)
            }
            return
        }
        if type == .screen { noteScreenSample() }
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
            MainActor.assumeIsolated { ScreenShare.shared.captureStopped(stream) }
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
    /// Что приходит: true — картинки JPEG, false — видео H.264, nil — кадров ещё нет. Показывается то, что пришло последним:
    /// ведущий Windows на время пересоздания кодера шлёт картинки, и застывший кадр видео их бы закрывал.
    @Published private(set) var pictures: Bool?
    /// Как кодирует ведущий (`video` из displays: hw / sw / jpeg); nil — не сообщил (старая версия).
    @Published private(set) var hostVideo: String?
    /// Когда пришёл последний кадр H.264 (главный поток): по нему отличаем мост картинками от кадров для старых зрителей.
    private var lastVideoAt: Date?
    /// Подпись «Видео · видеокарта / без видеокарты / Картинки».
    var videoModeLabel: String? { ShareVideoMode.label(pictures: pictures, host: hostVideo) }
    /// Метки зрителей (свои и чужие) поверх картинки.
    let marks = ShareMarkStore()

    enum Tool: String { case ping, draw, off }
    @Published var tool: Tool = .ping
    @Published var color = "red"

    /// Своя метка: показываем сразу и отправляем ведущему и остальным зрителям.
    func sendPing(_ point: CGPoint) {
        guard let mark = ShareMark.parse(ShareMark.message(ping: point, color: color)) else { return }
        marks.add(mark, local: true)
        socket?.send(.string(ShareMark.message(ping: point, color: color))) { _ in }
    }

    func sendStroke(_ points: [CGPoint]) {
        let message = ShareMark.message(stroke: points, color: color)
        guard let mark = ShareMark.parse(message) else { return }
        marks.add(mark, local: true)
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
        pictures = nil
        hostVideo = nil
        marks.inVideo = false
        lastVideoAt = nil
        video.reset()
        resetMonitors()
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
            player.attach(socket)
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
        timer.tolerance = 3
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
        Self.listen(socket, video: video, acks: acks, player: player)
    }

    /// Счёт видеопакетов для подтверждения relay (`ack`): по нему relay не копит очередь на медленном зрителе.
    let acks = ShareVideoAck()

    /// Чтение сокета. Видео H.264 уходит в проигрыватель прямо из колбэка, и следующее чтение взводится сразу:
    /// занятый главный поток не тормозит картинку. На главный — только учёт и остальные сообщения.
    nonisolated private static func listen(_ socket: URLSessionWebSocketTask, video: H264Player, acks: ShareVideoAck, player: SharePlayer) {
        socket.receive { result in
            if case .success(.data(let data)) = result, data.first == H264Packet.type {
                video.play(data.dropFirst(), from: socket)
                if let n = acks.received(on: socket) { socket.send(.string(ShareVideoAck.message(n))) { _ in } }
                listen(socket, video: video, acks: acks, player: player)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let viewer = ShareViewer.shared
                        guard viewer.socket === socket else { return }
                        viewer.lastMessage = Date()
                        if viewer.state != .watching { viewer.state = .watching }
                        viewer.reconnectsMade = 0
                        viewer.lastVideoAt = Date()
                        if viewer.pictures != false { viewer.pictures = false }
                    }
                }
                return
            }
            // Звук и картинки JPEG — тоже вне главного потока: занятый Mac не прерывает звук и не откладывает следующее чтение.
            if case .success(.data(let data)) = result, data.first == ShareProtocol.audio {
                player.play(data.dropFirst(), from: socket)
                listen(socket, video: video, acks: acks, player: player)
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
            if case .success(.data(let data)) = result, data.first == ShareProtocol.frame {
                if let n = acks.received(on: socket) { socket.send(.string(ShareVideoAck.message(n))) { _ in } }
                let image = ShareJPEG.decode(data.dropFirst())
                listen(socket, video: video, acks: acks, player: player)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let viewer = ShareViewer.shared
                        guard viewer.socket === socket else { return }
                        viewer.lastMessage = Date()
                        if viewer.state != .watching { viewer.state = .watching }
                        viewer.reconnectsMade = 0
                        viewer.jpegFrames += 1
                        if ShareVideoMode.jpegIsBridge(now: Date(), lastVideo: viewer.lastVideoAt), let image {
                            viewer.frame = image
                            if viewer.pictures != true { viewer.pictures = true }
                        }
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
                    case .success(.data):
                        if viewer.state != .watching { viewer.state = .watching }
                        viewer.reconnectsMade = 0
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
                        } else if type == "displays" {
                            viewer.received(displays: json ?? [:])
                            viewer.receive(socket)
                        } else if type == "switch-result" {
                            viewer.received(switchResult: json ?? [:])
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

    // MARK: Мониторы ведущего (SHARE-PROTOCOL §4.1)

    /// Мониторы ведущего и запрос в пути; пусто — ведущий их не объявил (старая версия, выключено, показывает окно).
    @Published private(set) var monitors = ShareMonitorPicker()
    /// Плашка сверху окна: идёт переключение или короткое сообщение (3–4 с).
    @Published private(set) var monitorNotice: MonitorNotice?
    enum MonitorNotice: Equatable { case switching(Int), info(String) }
    private var monitorNoticeTask: Task<Void, Never>?
    private var monitorWaitTask: Task<Void, Never>?
    private var keyMonitor: Any?

    private var hostLabel: String { hostName.isEmpty ? ShareCode.display(code) : hostName }

    /// Клик по плитке или клавиша 1…9: переключить монитор ведущего (сразу, без вопроса — если ведущий разрешил).
    func requestDisplay(_ n: Int) {
        guard state == .watching, let socket, let message = monitors.request(n, now: Date()) else { return }
        socket.send(.string(message)) { _ in }
        showMonitorNotice(.switching(n), seconds: nil)
        monitorWaitTask?.cancel()
        monitorWaitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ShareMonitorSwitch.wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.monitors.expired(now: Date()) else { return }
            self.showMonitorNotice(.info("Монитор не переключился — попробуйте ещё раз"), seconds: 4)
        }
    }

    fileprivate func received(displays json: [String: Any]) {
        if hostVideo != ShareVideoMode.host(from: json) { hostVideo = ShareVideoMode.host(from: json) }
        marks.inVideo = ShareVideoMode.marksInVideo(from: json)
        guard let parsed = ShareDisplays.parse(json) else { return }
        let change = monitors.apply(parsed)
        if change.done { monitorWaitTask?.cancel() }
        if change.switched, let current = monitors.current {
            // Доли меток относились к прежнему монитору.
            marks.clear()
            showMonitorNotice(.info("\(hostLabel) показывает монитор \(current)"), seconds: 3)
        } else if change.done, case .switching = monitorNotice {
            showMonitorNotice(nil, seconds: nil)
        }
        if change.gone { showMonitorNotice(.info("\(hostLabel): переключение мониторов выключено"), seconds: 4) }
    }

    fileprivate func received(switchResult json: [String: Any]) {
        guard let display = ShareDisplays.integer(json["display"]), let result = json["result"] as? String else { return }
        let notice = monitors.result(display: display, result: result)
        if monitors.pending == nil { monitorWaitTask?.cancel() }
        switch notice {
        case .off: showMonitorNotice(.info("\(hostLabel): переключение мониторов выключено"), seconds: 4)
        case .busy: showMonitorNotice(.info("Только что переключили — попробуйте через пару секунд"), seconds: 4)
        case .failed: showMonitorNotice(.info("Не получилось переключить монитор"), seconds: 4)
        case nil:
            if monitors.pending == nil, case .switching = monitorNotice { showMonitorNotice(nil, seconds: nil) }
        }
    }

    private func showMonitorNotice(_ notice: MonitorNotice?, seconds: TimeInterval?) {
        monitorNoticeTask?.cancel()
        monitorNotice = notice
        guard let seconds else { return }
        monitorNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.monitorNotice == notice else { return }
            self.monitorNotice = nil
        }
    }

    private func resetMonitors() {
        monitorWaitTask?.cancel()
        monitorNoticeTask?.cancel()
        monitors = ShareMonitorPicker()
        monitorNotice = nil
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
        resetMonitors()
    }

    /// Остановить просмотр при выходе: подключение закрывается, состояние уходит из «идёт» (окно остаётся до закрытия).
    func stopWatching() {
        if BusyRegistry.viewerIsConnected(state) { state = .ended("Просмотр остановлен") }
        disconnect()
    }

    /// Окно просмотра открыто — Mac Utils виден в Dock и в ⌘Tab.
    private(set) var isWindowOpen = false

    /// Окно просмотра закрыли: просмотр закончен, клавиши 1…9 больше не перехватываются (закрыто — не работает).
    func windowClosed() {
        disconnect()
        state = .idle
        isWindowOpen = false
        removeMonitorKeys()
    }

    /// Клавиши 1…9 в окне просмотра — монитор ведущего с этим номером. Только пока окно открыто.
    func installMonitorKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let number = event.windowNumber, key = event.charactersIgnoringModifiers ?? ""
            let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty && !event.isARepeat
            let handled = MainActor.assumeIsolated { () -> Bool in
                let viewer = ShareViewer.shared
                guard plain, number == viewer.window?.windowNumber, viewer.state == .watching,
                      let n = viewer.monitors.monitor(forKey: key) else { return false }
                viewer.requestDisplay(n)
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeMonitorKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Перехват клавиш 1…9 стоит (для проверки «закрыто — не работает»).
    var monitorKeysInstalled: Bool { keyMonitor != nil }

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
                    ShareViewer.shared.windowClosed()
                    AppDelegate.syncDock()
                }
            }
            self.window = window
            return window
        }()
        installMonitorKeys()
        let label = ShareHistory.shared.label(for: code)
        window.title = code.isEmpty ? "Трансляция экрана" : "Трансляция · \(label ?? ShareCode.display(code))"
        ScreenOutput.activateApp()
        window.makeKeyAndOrderFrontOnScreen()
    }
}

private struct ShareViewerView: View {
    @ObservedObject var viewer: ShareViewer
    @ObservedObject private var video = ShareViewer.shared.video
    @State private var stroke: [CGPoint] = []

    /// Показываются картинки JPEG: их шлют старые ведущие и ведущий Windows, пока пересоздаёт кодер.
    private var showsPictures: Bool { viewer.frame != nil && (video.size == nil || viewer.pictures == true) }
    /// Размер кадра: видео H.264 или картинка.
    private var frameSize: CGSize? { showsPictures ? viewer.frame?.size : video.size ?? viewer.frame?.size }

    var body: some View {
        GeometryReader { proxy in
            let rect = imageRect(in: proxy.size)
            ZStack {
                Color.black
                Group {
                    H264View(player: video)
                        .opacity(video.size == nil || showsPictures ? 0 : 1)
                    if showsPictures, let frame = viewer.frame {
                        Image(nsImage: frame).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    }
                }
                // Идёт переключение монитора — картинка притушена до нового кадра.
                .opacity(viewer.monitors.pending == nil ? 1 : 0.55)
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
            .overlay(alignment: .top) { monitorNotice.padding(.top, 54) }
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

    /// Плашка о мониторах ведущего: идёт переключение, показывается другой монитор, переключение выключено.
    @ViewBuilder private var monitorNotice: some View {
        if viewer.state == .watching, let notice = viewer.monitorNotice {
            Group {
                switch notice {
                case .switching(let n):
                    ViewerStatusCard(.notice("Переключаю на монитор \(n)…"))
                case .info(let text):
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "display.2").foregroundStyle(.dsMute).accessibilityHidden(true)
                        Text(text).font(DS.Font.bodyStrong).foregroundStyle(.dsText)
                    }
                    .floating(.pill)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// Метка в углу: идёт трансляция и качество картинки.
    @ViewBuilder private var badge: some View {
        if viewer.state == .watching, frameSize != nil || viewer.frame != nil {
            ShareViewerBadge(height: frameSize.map { Int($0.height) }, mode: viewer.videoModeLabel)
                .padding(12)
        }
    }

    /// Метка (клик), рисование (вести мышью), цвет.
    @ViewBuilder private var toolbar: some View {
        if viewer.state == .watching {
            ShareViewerToolbar(tool: $viewer.tool, color: $viewer.color, monitors: viewer.monitors,
                               requestDisplay: { viewer.requestDisplay($0) }) { viewer.playGame() }
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
    /// «Видео · видеокарта», «Видео · без видеокарты», «Картинки» (`ShareVideoMode`); nil — не показываем.
    var mode: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: DS.Space.xs) {
            HStack(spacing: 0) {
                Text("В ЭФИРЕ").tracking(DS.Font.tracking(0.06, size: 11))
                if let height { Text(" · \(height)p").monospacedDigit() }
            }
            .font(DS.Font.groupLabel)
            .foregroundStyle(Color.dsRecInk)
            .padding(.vertical, DS.Space.xs)
            .padding(.horizontal, 10)
            .background(Color.dsRec, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("В эфире")
            if let mode {
                Text(mode)
                    .font(DS.Font.caption)
                    .foregroundStyle(.dsText)
                    .padding(.vertical, DS.Space.xs)
                    .padding(.horizontal, 10)
                    .background(.regularMaterial, in: Capsule())
                    .help("Как идёт трансляция: видео через видеокарту ведущего, видео без неё (программно) или картинками")
            }
        }
        .fixedSize()
    }
}

/// Панель инструментов зрителя (как в `MacWatch.dc.html`): метка, рисование, выкл — значками (активный — лайм), цвет,
/// «Сыграть». Подписи — во всплывающих подсказках. Цвета те же, что понимает ведущий (`ShareMark.palette`).
/// Толщины линии в протоколе нет — её в панели нет.
struct ShareViewerToolbar: View {
    @Binding var tool: ShareViewer.Tool
    @Binding var color: String
    /// Мониторы ведущего: раздел есть, только если ведущий их объявил.
    let monitors: ShareMonitorPicker
    let requestDisplay: (Int) -> Void
    let playGame: () -> Void

    init(tool: Binding<ShareViewer.Tool>, color: Binding<String>, monitors: ShareMonitorPicker = ShareMonitorPicker(),
         requestDisplay: @escaping (Int) -> Void = { _ in }, playGame: @escaping () -> Void) {
        _tool = tool
        _color = color
        self.monitors = monitors
        self.requestDisplay = requestDisplay
        self.playGame = playGame
    }

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
            if !monitors.list.isEmpty {
                separator
                MonitorSwitcher(picker: monitors, request: requestDisplay)
            }
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
    @AppStorage(Pref.shareMuteCalls) private var muteCalls = false
    @AppStorage(Pref.shareAllowMarks) private var allowMarks = true
    @AppStorage(Pref.shareAllowMonitorSwitch) private var allowMonitorSwitch = false
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

        GroupLabel("Что могут зрители")
        ListCard {
            ToggleRow("Разрешить зрителям ставить метки и рисовать",
                      subtitle: "Зритель кликает или рисует по картинке — у вас на экране появляется метка «сюда!» или линия, и через пару секунд исчезает. Управлять вашим Mac зритель не может.",
                      systemImage: "scope", isOn: $allowMarks)
            ToggleRow("Зрители могут переключать мои мониторы",
                      subtitle: "По умолчанию выключено. Включите — и зритель сам выберет, какой из ваших мониторов смотреть, без вопроса. Картинка сменится у всех зрителей, а у вас мелькнёт уведомление. Когда показываете окно или программу, мониторы зрителям не видны.",
                      systemImage: "display.2", isOn: $allowMonitorSwitch)
        }
        // В эфире — сразу: у зрителей кнопка пропадает или появляется.
        .onChange(of: allowMonitorSwitch) { share.announceDisplays() }

        GroupLabel("Звук")
        ListCard {
            ToggleRow("Передавать звук системы",
                      subtitle: "Зрители слышат то, что играет на Mac (видео, музыку, звонок). Микрофон не передаётся.",
                      systemImage: "speaker.wave.2", isOn: $shareAudio)
            if shareAudio {
                ToggleRow("Не передавать звонки",
                          subtitle: "Звук звонков (Discord, Telegram, Zoom, FaceTime…) рекомендуется заглушить: иначе собеседник, который смотрит трансляцию, слышит сам себя.",
                          systemImage: "phone.down", isOn: $muteCalls)
            }
        }
        .onChange(of: muteCalls) { share.refreshAudioFilter() }
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
        .onScreen { $0 ? history.startPolling() : history.stopPolling() }
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

/// Подтверждение приёма видео: каждые `every` пакетов (H.264 и картинки) зритель сообщает relay, сколько получил за
/// соединение. Старый relay сообщение игнорирует.
final class ShareVideoAck: @unchecked Sendable {
    static let every = 10
    private let lock = NSLock()
    private var owner: ObjectIdentifier?
    private var count = 0

    /// Пакет пришёл по `socket`; число, если пора подтверждать. Новый сокет — счёт заново (как у relay).
    func received(on socket: AnyObject) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let id = ObjectIdentifier(socket)
        if owner != id { owner = id; count = 0 }
        count += 1
        return count % Self.every == 0 ? count : nil
    }

    static func message(_ n: Int) -> String { "{\"type\":\"ack\",\"n\":\(n)}" }
}

/// Картинка JPEG → NSImage сразу полностью (не отложенно при первой отрисовке), чтобы разбор шёл не на главном потоке.
enum ShareJPEG {
    static func decode(_ data: Data) -> NSImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Паузы между попытками ведущего вернуться на сервер: 44 с частых попыток (relay ждёт ведущего 45 с, потом зрителей
/// отключает), затем раз в 30 с ещё 10 минут — захват не останавливается, после возврата эфир идёт под тем же ID.
enum ShareHostReconnect {
    static let quick: [UInt64] = [1, 2, 3, 5, 8, 10, 15]
    static let slow: [UInt64] = Array(repeating: 30, count: 20)
    static var delays: [UInt64] { quick + slow }
}

/// Проигрывание звука трансляции у зрителя.
final class SharePlayer: @unchecked Sendable {
    let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: ShareProtocol.sampleRate, channels: 1)!
    private var started = false
    /// Запланировано и ещё не проиграно, в сэмплах. Больше `limit` — новые пакеты отбрасываются: если движок встал
    /// (система остановила его при смене устройства вывода) или звук пришёл пачкой после паузы сети, очередь
    /// не растёт, пока не кончится память (≈ 345 МБ в час без предела), и задержка звука не копится.
    private let lock = NSLock()
    private var queuedFrames = 0
    /// Поколение очереди: пакеты, запланированные до смены выхода, не должны вычитаться из новой очереди.
    private var generation = 0
    /// Движок и узел трогает один поток за раз: play() с сокета и перезапуск по уведомлению системы.
    private let engineLock = NSLock()
    private let limit: Int
    /// Очередь длиннее — сбрасываем (звук догоняет картинку).
    private let catchUp: Int
    private(set) var dropped = 0
    private(set) var catchUps = 0
    private(set) var restarts = 0
    private var observer: NSObjectProtocol?
    /// Сокет, чей звук сейчас играет: после `stop()` (выход, переподключение) пакеты старого сокета ничего не запускают.
    private var owner: ObjectIdentifier?
    private let center: NotificationCenter
    /// Перезапуск — на своей очереди: обработчик уведомления не ждёт замок на внутренней очереди AVAudioEngine
    /// (иначе взаимная блокировка с play(), который держит замок и запускает движок).
    private let restartQueue = DispatchQueue(label: "macutils.share.player.restart")

    /// ≈ 1 с звука трансляции.
    static let defaultLimit = Int(ShareProtocol.sampleRate)
    /// ≈ 0,5 с: больше звук заметно отстаёт от картинки.
    static let defaultCatchUp = Int(ShareProtocol.sampleRate / 2)

    /// `silent` — для тестов и стендов: движок рендерит вручную, в динамики ничего не идёт и ничего не потребляется
    /// (как остановленный системой движок).
    /// `center` — откуда приходит `.AVAudioEngineConfigurationChange` (в тестах свой центр уведомлений).
    init(silent: Bool = false, limit: Int = SharePlayer.defaultLimit, catchUp: Int = SharePlayer.defaultCatchUp, center: NotificationCenter = .default) {
        self.limit = limit
        self.catchUp = catchUp
        self.center = center
        if silent {
            try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
        observer = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartQueue.async { self?.outputChanged() }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    /// Сменилось устройство вывода (наушники, AirPods, HDMI): система останавливает движок, и без перезапуска звук
    /// пропадает. Старую очередь бросаем — в ней звук на секунду позади — и продолжаем со свежих пакетов.
    /// Для тестов: дождаться перезапуска, поставленного уведомлением.
    func waitForRestart() { restartQueue.sync {} }

    func outputChanged() {
        engineLock.lock(); defer { engineLock.unlock() }
        guard started else { return }
        node.stop()
        lock.lock()
        queuedFrames = 0
        generation += 1
        lock.unlock()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        restarts += 1
        let running = (try? engine.start()) != nil
        if running { node.play() }
        Log.capture.info("звук зрителя: смена выхода, перезапуск \(self.restarts) (запущен \(running ? 1 : 0))")
    }

    /// Сколько секунд звука ждёт проигрывания.
    var queuedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(queuedFrames) / ShareProtocol.sampleRate
    }

    /// Новый сокет просмотра — его звук разрешён, прежнего — нет.
    func attach(_ socket: AnyObject) {
        engineLock.lock(); defer { engineLock.unlock() }
        owner = ObjectIdentifier(socket)
    }

    /// `socket` — откуда пакет (nil — без проверки, для тестов и стендов).
    func play(_ payload: Data, from socket: AnyObject? = nil) {
        let count = payload.count / 2
        guard count > 0 else { return }
        let samples = ShareProtocol.samples(payload)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        engineLock.lock(); defer { engineLock.unlock() }
        if let socket, owner != ObjectIdentifier(socket) { return }
        // Движок — до проверки очереди: остановленный движок очередь не разбирает, и при полной очереди звук не вернулся бы.
        if !started {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            guard (try? engine.start()) != nil else { return }
            node.play()
            started = true
        } else if !engine.isRunning {
            // Запасной путь, если уведомление не дошло: запускаем движок снова.
            guard (try? engine.start()) != nil else { return }
            node.play()
        }
        lock.lock()
        if queuedFrames > catchUp {
            // Рывок сети: звук пришёл пачкой и отстал от картинки. Очередь сбрасываем — дальше звук идёт со свежих пакетов,
            // вместо того чтобы отставать до конца просмотра.
            queuedFrames = 0
            generation += 1
            catchUps += 1
            lock.unlock()
            node.stop(); node.play()
            lock.lock()
        }
        let full = queuedFrames + count > limit
        if full { dropped += 1 }
        guard !full else { lock.unlock(); return }
        queuedFrames += count
        let scheduled = generation
        lock.unlock()
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.generation == scheduled { self.queuedFrames = max(0, self.queuedFrames - count) }
            self.lock.unlock()
        }
    }

    func stop() {
        engineLock.lock(); defer { engineLock.unlock() }
        owner = nil
        guard started else { return }
        node.stop()
        engine.stop()
        engine.detach(node)
        started = false
        lock.lock()
        queuedFrames = 0
        generation += 1
        lock.unlock()
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
