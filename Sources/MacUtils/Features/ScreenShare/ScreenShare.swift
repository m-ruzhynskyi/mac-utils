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

    /// «123 456» → «123456»; nil — не 6 цифр.
    static func normalized(_ text: String) -> String? {
        let digits = text.filter(\.isNumber)
        return digits.count == 6 ? digits : nil
    }

    static func display(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    /// https://relay.example.dev → wss://relay.example.dev/room/123456?role=host
    static func url(server: String, code: String, role: String) -> URL? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("https://") { base = "wss://" + base.dropFirst(8) }
        if base.hasPrefix("http://") { base = "ws://" + base.dropFirst(7) }
        if !base.hasPrefix("ws://") && !base.hasPrefix("wss://") { base = "wss://" + base }
        return URL(string: "\(base)/room/\(code)?role=\(role)")
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
            // Код может быть занят — пробуем несколько.
            for _ in 0..<4 {
                let code = ShareCode.random()
                guard let url = ShareCode.url(server: Self.server, code: code, role: "host") else { break }
                let socket = URLSession.shared.webSocketTask(with: url)
                socket.maximumMessageSize = 4 << 20
                socket.resume()
                let status = await Self.handshake(socket)
                if status == 409 { continue }
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
                listen(socket)
                showHUD()
                return
            }
            state = .failed("Не удалось получить код — попробуйте ещё раз")
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

    func stop(reason: String? = nil) {
        Picker.shared.reset()
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
        case idle, connecting, watching, ended(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var frame: NSImage?
    @Published private(set) var code = ""

    private var socket: URLSessionWebSocketTask?
    private var window: NSWindow?
    fileprivate let player = SharePlayer()

    func watch(code input: String) {
        guard let code = ShareCode.normalized(input) else {
            state = .ended("Код — 6 цифр")
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
        let socket = URLSession.shared.webSocketTask(with: url)
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
                    if case .success = result, viewer.state == .connecting { viewer.state = .watching }
                    switch result {
                    case .success(.data(let data)):
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
                        if text.contains("\"ended\"") {
                            viewer.state = .ended("Трансляция завершена")
                            viewer.disconnect()
                        } else {
                            viewer.receive(socket)
                        }
                    case .failure:
                        let status = (socket.response as? HTTPURLResponse)?.statusCode
                        switch viewer.state {
                        case .connecting:
                            viewer.state = .ended(status == 404 ? "Трансляции с таким кодом нет"
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

    func showWindow() {
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
                }
            }
            self.window = window
            return window
        }()
        window.title = code.isEmpty ? "Трансляция экрана" : "Трансляция \(ShareCode.display(code))"
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ShareViewerView: View {
    @ObservedObject var viewer: ShareViewer

    var body: some View {
        ZStack {
            Color.black
            if let frame = viewer.frame {
                Image(nsImage: frame).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
            switch viewer.state {
            case .connecting:
                VStack(spacing: 8) { ProgressView(); Text("Подключаюсь…").foregroundStyle(.white) }
            case .watching where viewer.frame == nil:
                VStack(spacing: 8) { ProgressView(); Text("Жду картинку…").foregroundStyle(.white) }
            case .ended(let message):
                Text(message).font(.title3).foregroundStyle(.white)
                    .padding(14).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            default:
                EmptyView()
            }
        }
        .frame(minWidth: 480, minHeight: 300)
    }
}

// MARK: - Страница

struct ScreenSharePage: View {
    var compact = false
    @ObservedObject private var share = ScreenShare.shared
    @ObservedObject private var viewer = ShareViewer.shared
    @AppStorage(Pref.shareServer) private var server = ""
    @AppStorage(Pref.shareAudio) private var shareAudio = true
    @State private var code = ""

    var body: some View {
        Form {
            Section("Показать свой экран") {
                switch share.state {
                case .idle, .failed:
                    Button { share.start() } label: { Label("Начать трансляцию…", systemImage: "dot.radiowaves.left.and.right") }
                        .help("Откроется выбор: весь экран, окно или программа")
                        .buttonStyle(.borderedProminent)
                        .disabled(server.isEmpty)
                    if case .failed(let message) = share.state {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                case .connecting:
                    HStack { ProgressView().controlSize(.small); Text("Подключаюсь…") }
                case .live(let code, let viewers):
                    HStack {
                        Text(ShareCode.display(code)).font(.system(size: 28, weight: .bold).monospacedDigit())
                            .textSelection(.enabled)
                        Button { share.copyCode() } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Скопировать код")
                        Spacer()
                        Label("\(viewers)", systemImage: "eye").foregroundStyle(.secondary)
                        Button("Сменить экран…") { share.changeSource() }
                        Button("Стоп") { share.stop() }.tint(.red)
                    }
                    Text("Сообщите код тому, кто будет смотреть. Он видит только выбранный экран или окно, управлять не может.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Смотреть чужой экран") {
                HStack {
                    TextField("", text: $code, prompt: Text("Код из 6 цифр"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .frame(width: 140)
                        .onSubmit { viewer.watch(code: code) }
                    Button("Смотреть") { viewer.watch(code: code) }
                        .disabled(ShareCode.normalized(code) == nil || server.isEmpty)
                }
                if case .ended(let message) = viewer.state {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Звук") {
                Toggle("Передавать звук системы", isOn: $shareAudio)
                Text("Зрители слышат то, что играет на Mac (видео, музыку, звонок). Микрофон не передаётся.")
                    .font(.caption).foregroundStyle(.secondary)
                if shareAudio {
                    MutedAppsList()
                }
            }
            Section("Без Mac Utils") {
                Text("Смотреть или транслировать можно и из браузера — на Windows, Linux, любом компьютере:")
                    .font(.caption).foregroundStyle(.secondary)
                Link(server.isEmpty ? "—" : server, destination: URL(string: server.isEmpty ? "about:blank" : server)!)
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
