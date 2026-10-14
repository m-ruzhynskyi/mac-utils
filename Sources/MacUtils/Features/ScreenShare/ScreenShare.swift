import AVFoundation
import AppKit
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// Ретранслятор пускает только приложения Mac Utils — по этому заголовку.
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("mu-share-1", forHTTPHeaderField: "X-MacUtils-Client")
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
            query += [URLQueryItem(name: "viewer", value: myID), URLQueryItem(name: "name", value: myName)]
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

    private var socket: URLSessionWebSocketTask?
    private var stream: SCStream?
    private var audioStream: SCStream?
    private var audioRefresh: Timer?
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
                let ownPID = ProcessInfo.processInfo.processIdentifier
                connect(filter: SCContentFilter(display: display,
                                                excludingApplications: content.applications.filter { $0.processID == ownPID },
                                                exceptingWindows: []))
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
            for _ in 0..<1 {
                let code = ShareCode.myID
                guard let url = ShareCode.url(server: Self.server, code: code, role: "host") else { break }
                let socket = URLSession.shared.webSocketTask(with: ShareCode.request(url))
                socket.maximumMessageSize = 4 << 20
                socket.resume()
                let status = await Self.handshake(socket)
                if status == 409 {
                    state = .failed("С вашим ID уже идёт трансляция (может, в другом окне)")
                    return
                }
                guard status == nil else {
                    state = .failed(status == 0 ? "Нет связи с сервером трансляции" : "Сервер ответил \(status!)")
                    return
                }
                self.socket = socket
                do {
                    try await beginCapture(filter: filter)
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    self.socket = nil
                    state = .failed("Не удалось начать захват экрана")
                    return
                }
                state = .live(code: code, viewers: 0)
                ShareMarksOverlay.shared.attach(to: filter)
                listen(socket)
                showHUD()
                return
            }
            state = .failed("Не удалось начать трансляцию")
        }
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
        let excluded = content.applications.filter { $0.processID == ownPID || muted.contains($0.bundleIdentifier) }
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
            config.minimumFrameInterval = CMTime(value: 1, timescale: 8)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.queueDepth = 3
            ShareMarksOverlay.shared.attach(to: filter)
            Task {
                try? await stream.updateContentFilter(filter)
                try? await stream.updateConfiguration(config)
            }
        }
    }

    private func beginCapture(filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()
        Self.configure(config, for: filter)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 8)
        config.pixelFormat = kCVPixelFormatType_32BGRA
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
                                self.request(viewer: json["viewer"] as? String ?? "", name: json["name"] as? String ?? "")
                            case "cancelled":
                                self.pendingRequests.remove(json["viewer"] as? String ?? "")
                            case "viewers":
                                let list = (json["list"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                                self.watchers = list
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
                    case .failure:
                        self.stop(reason: "Связь с сервером прервалась")
                    }
                }
            }
        }
    }

    /// Кто сейчас смотрит (имена компьютеров).
    @Published private(set) var watchers: [String] = []
    private var pendingRequests: Set<String> = []

    /// Зритель просится посмотреть: доверенных пускаем сразу, остальных — по вопросу.
    private func request(viewer: String, name: String) {
        if ShareHistory.shared.isTrusted(viewer) {
            answer(viewer: viewer, accept: true)
            return
        }
        guard !pendingRequests.contains(viewer) else { return }
        pendingRequests.insert(viewer)
        let alert = NSAlert()
        alert.messageText = "\(name) хочет посмотреть ваш экран"
        alert.informativeText = "ID \(ShareCode.display(viewer)). Зритель только смотрит и может ставить метки — управлять вашим Mac он не может."
        alert.addButton(withTitle: "Разрешить")
        alert.addButton(withTitle: "Всегда разрешать")
        alert.addButton(withTitle: "Отклонить")
        NSApp.activate()
        let response = alert.runModal()
        guard pendingRequests.remove(viewer) != nil, isLive else { return }
        switch response {
        case .alertFirstButtonReturn: answer(viewer: viewer, accept: true)
        case .alertSecondButtonReturn:
            ShareHistory.shared.trust(viewer, name: name)
            answer(viewer: viewer, accept: true)
        default: answer(viewer: viewer, accept: false)
        }
    }

    private func answer(viewer: String, accept: Bool) {
        let message = String(format: #"{"type":"%@","viewer":"%@","name":"%@"}"#,
                             accept ? "accept" : "decline", viewer, ShareCode.myName.replacingOccurrences(of: "\"", with: "'"))
        socket?.send(.string(message)) { _ in }
        if accept { sender?.resendLast() }
    }

    func stop(reason: String? = nil) {
        watchers = []
        pendingRequests = []
        Picker.shared.reset()
        ShareMarksOverlay.shared.detach()
        let stream = self.stream
        let audioStream = self.audioStream
        self.stream = nil
        self.audioStream = nil
        audioRefresh?.invalidate()
        audioRefresh = nil
        Task { try? await audioStream?.stopCapture() }
        sender = nil
        Task { try? await stream?.stopCapture() }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        hud?.orderOut(nil)
        hud = nil
        state = reason.map { .failed($0) } ?? .idle
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
    }
}

/// Маленький индикатор эфира в углу (в саму трансляцию не попадает): точка и «Эфир»;
/// при наведении — код, зрители и «Стоп».
private struct ShareHUD: View {
    @ObservedObject var share: ScreenShare
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
                    Button { share.changeSource() } label: { Image(systemName: "rectangle.on.rectangle").font(.caption2) }
                        .buttonStyle(.borderless).help("Показать другой экран или окно")
                    Button { share.stop() } label: { Image(systemName: "stop.fill").font(.caption2) }
                        .buttonStyle(.borderless).foregroundStyle(.red).help("Остановить трансляцию")
                } else {
                    Text(viewers > 0 ? "Эфир · \(viewers)" : "Эфир").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
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
}

/// Кадры ScreenCaptureKit → JPEG → отправка (пока предыдущий кадр не ушёл, новые пропускаем).
final class FrameSender: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "macutils.share")
    /// URLSessionWebSocketTask сохраняет порядок отправки — звук не перемешивается.
    private let socket: URLSessionWebSocketTask
    private let context = CIContext()
    private var inFlight = false
    private var last: Data?

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    let audioQueue = DispatchQueue(label: "macutils.share.audio")

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if let packet = ShareProtocol.audioPacket(sampleBuffer) {
                socket.send(.data(packet)) { _ in }
            }
            return
        }
        guard type == .screen, !inFlight, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = context.createCGImage(CIImage(cvPixelBuffer: pixels),
                                                from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels),
                                                             height: CVPixelBufferGetHeight(pixels))),
              let jpeg = Self.jpeg(image).map(ShareProtocol.framePacket) else { return }
        last = jpeg
        transmit(jpeg)
    }

    func resendLast() {
        queue.async {
            guard let last = self.last, !self.inFlight else { return }
            self.transmit(last)
        }
    }

    /// Вызывается на queue.
    private func transmit(_ data: Data) {
        inFlight = true
        socket.send(.data(data)) { error in
            self.queue.async { self.inFlight = false }
            if error != nil {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if ScreenShare.shared.isLive { ScreenShare.shared.stop(reason: "Связь с сервером прервалась") }
                    }
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

    private var socket: URLSessionWebSocketTask?
    private var window: NSWindow?
    fileprivate let player = SharePlayer()
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
        frame = nil
        state = .connecting
        showWindow()
        let socket = URLSession.shared.webSocketTask(with: ShareCode.request(url))
        socket.maximumMessageSize = 4 << 20
        self.socket = socket
        socket.resume()
        // Сразу читаем: пока не забираем входящие кадры, ответ на ping может не прийти.
        receive(socket)
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
                        } else if type == "waiting" {
                            viewer.state = .waiting
                            viewer.receive(socket)
                        } else if type == "accepted" {
                            viewer.state = .watching
                            ShareHistory.shared.visited(viewer.code, name: json?["name"] as? String ?? "")
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
                            viewer.state = .ended(status == 404 ? "Сейчас этот ID ничего не транслирует"
                                                  : status == 429 ? "Слишком много зрителей" : "Нет связи с сервером")
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

    func disconnect() {
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
    @State private var stroke: [CGPoint] = []

    var body: some View {
        GeometryReader { proxy in
            let rect = imageRect(in: proxy.size)
            ZStack {
                Color.black
                if let frame = viewer.frame {
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
        guard let frame = viewer.frame, frame.size.width > 0, frame.size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / frame.size.width, size.height / frame.size.height)
        let fitted = CGSize(width: frame.size.width * scale, height: frame.size.height * scale)
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
        case .watching where viewer.frame == nil:
            VStack(spacing: 8) { ProgressView(); Text("Жду картинку…").foregroundStyle(.white) }
        case .waiting:
            VStack(spacing: 8) {
                ProgressView()
                Text("Ждём, пока \(ShareCode.display(viewer.code)) разрешит подключение…").foregroundStyle(.white)
            }
        case .ended(let message):
            Text(message).font(.title3).foregroundStyle(.white)
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
                    Text(ShareCode.display(ShareCode.myID)).font(.system(size: 26, weight: .bold).monospacedDigit())
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
                if case .live = share.state {
                    Text(share.watchers.isEmpty ? "Пока никто не смотрит." : "Смотрят: " + share.watchers.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Этот ID постоянный — по нему к вам подключаются. Каждого зрителя вы сначала разрешаете (или отмечаете «Всегда разрешать»). Управлять вашим Mac зритель не может.")
                    .font(.caption).foregroundStyle(.secondary)
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
