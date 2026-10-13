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
    private var sender: FrameSender?
    private var hud: NSPanel?

    static var server: String { UserDefaults.standard.string(forKey: Pref.shareServer) ?? "" }

    var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    // MARK: - Ведущий

    func start() {
        guard state == .idle || isFailed else { return }
        guard !Self.server.isEmpty else {
            state = .failed("Сервер трансляции не настроен")
            return
        }
        guard Permissions.screenRecording else {
            state = .failed("Нужно разрешение «Запись экрана»")
            return
        }
        state = .connecting
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
                    try await beginCapture()
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

    private func beginCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouseScreen = NSScreen.withMouse ?? NSScreen.main
        guard let display = content.displays.first(where: { $0.displayID == mouseScreen?.displayID }) ?? content.displays.first
        else { throw CocoaError(.featureUnsupported) }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display,
                                     excludingApplications: content.applications.filter { $0.processID == ownPID },
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        // До 1600 точек по ширине и 8 кадров в секунду — читаемо и не тяжело для сети.
        let scale = min(1, 1600 / CGFloat(display.width))
        config.width = Int(CGFloat(display.width) * scale) / 2 * 2
        config.height = Int(CGFloat(display.height) * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 8)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3
        let sender = FrameSender { [weak self] data in
            await self?.send(data) ?? false
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: sender)
        try stream.addStreamOutput(sender, type: .screen, sampleHandlerQueue: sender.queue)
        try await stream.startCapture()
        self.stream = stream
        self.sender = sender
    }

    /// Отправка кадра; false — соединения больше нет.
    private func send(_ data: Data) async -> Bool {
        guard let socket else { return false }
        do {
            try await socket.send(.data(data))
            return true
        } catch {
            return false
        }
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
        let stream = self.stream
        self.stream = nil
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
        let panel = HUDPanel(contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2,
                                                 y: screen.visibleFrame.maxY - size.height - 10,
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

/// Индикатор «Идёт трансляция» поверх экрана (в саму трансляцию не попадает).
private struct ShareHUD: View {
    @ObservedObject var share: ScreenShare

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 9, height: 9)
            if case .live(let code, let viewers) = share.state {
                Text("Трансляция").font(.callout.weight(.semibold))
                Button { share.copyCode() } label: {
                    Text(ShareCode.display(code)).font(.callout.monospacedDigit().weight(.bold))
                }
                .buttonStyle(.borderless)
                .help("Скопировать код")
                Label("\(viewers)", systemImage: "eye").font(.callout).foregroundStyle(.secondary)
                    .help("Сколько человек смотрит")
            }
            Button { share.stop() } label: { Text("Стоп").font(.callout.weight(.semibold)) }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(2)
    }
}

/// Кадры ScreenCaptureKit → JPEG → отправка (пока предыдущий кадр не ушёл, новые пропускаем).
final class FrameSender: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "macutils.share")
    private let send: @Sendable (Data) async -> Bool
    private let context = CIContext()
    private var inFlight = false
    private var last: Data?

    init(send: @escaping @Sendable (Data) async -> Bool) {
        self.send = send
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !inFlight, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = context.createCGImage(CIImage(cvPixelBuffer: pixels),
                                                from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels),
                                                             height: CVPixelBufferGetHeight(pixels))),
              let jpeg = Self.jpeg(image) else { return }
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
        let send = self.send
        Task {
            let ok = await send(data)
            self.queue.async { self.inFlight = false }
            if !ok {
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
        socket.sendPing { error in
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let viewer = ShareViewer.shared
                    guard viewer.socket === socket else { return }
                    if error != nil {
                        viewer.state = .ended(status == 404 ? "Трансляции с таким кодом нет"
                                              : status == 429 ? "Слишком много зрителей" : "Нет связи с сервером")
                        viewer.disconnect()
                    } else {
                        viewer.state = .watching
                        viewer.receive(socket)
                    }
                }
            }
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let viewer = ShareViewer.shared
                    guard viewer.socket === socket else { return }
                    switch result {
                    case .success(.data(let data)):
                        if let image = NSImage(data: data) { viewer.frame = image }
                        viewer.receive(socket)
                    case .success(.string(let text)):
                        if text.contains("\"ended\"") {
                            viewer.state = .ended("Трансляция завершена")
                            viewer.disconnect()
                        } else {
                            viewer.receive(socket)
                        }
                    case .failure:
                        if viewer.state == .watching { viewer.state = .ended("Трансляция завершена") }
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
    @State private var code = ""

    var body: some View {
        Form {
            Section("Показать свой экран") {
                switch share.state {
                case .idle, .failed:
                    Button { share.start() } label: { Label("Начать трансляцию", systemImage: "dot.radiowaves.left.and.right") }
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
                        Button("Стоп") { share.stop() }.tint(.red)
                    }
                    Text("Сообщите код тому, кто будет смотреть. Он видит только экран, управлять не может.")
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
