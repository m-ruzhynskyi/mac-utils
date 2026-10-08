import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// «Поверх всех» для любого окна (⌃⌥P): macOS не даёт поднять чужое окно над остальными,
/// поэтому поверх показывается живая копия окна (ScreenCaptureKit) — с настраиваемой прозрачностью.
/// Клик по копии переключает на настоящее окно.
@MainActor
final class WindowPin: ObservableObject {
    static let shared = WindowPin()

    @Published private(set) var pins: [PinnedWindow] = []

    func sync() {
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.windowPin)
        guard UserDefaults.standard.bool(forKey: Pref.windowPin) else {
            unpinAll()
            return
        }
        center.register(id: HotKeyID.windowPin, keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey) {
            WindowPin.shared.toggleFocused()
        }
    }

    func toggleFocused() {
        guard let window = WindowTiler.focusedWindow(), let id = AXWindowID.of(window) else {
            Toast.show("Нет активного окна", symbol: "pin.slash", tint: .orange)
            return
        }
        if let pin = pins.first(where: { $0.windowID == id }) {
            unpin(pin)
            return
        }
        guard Permissions.screenRecording else {
            Toast.show("Нужно разрешение «Запись экрана»", symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pin = PinnedWindow(windowID: id, element: window, app: app)
        pins.append(pin)
        Task {
            do {
                try await pin.start()
                Toast.show("«\(app.localizedName ?? "Окно")» поверх всех. Снять — ⌃⌥P", symbol: "pin.fill", tint: .blue)
            } catch {
                unpin(pin)
                Toast.show("Не удалось закрепить окно", symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    func unpin(_ pin: PinnedWindow) {
        pin.stop()
        pins.removeAll { $0 === pin }
    }

    func unpinAll() {
        for pin in pins { pin.stop() }
        pins.removeAll()
    }
}

/// Одна закреплённая копия окна.
@MainActor
final class PinnedWindow: NSObject, ObservableObject, Identifiable, SCStreamOutput, SCStreamDelegate {
    let windowID: CGWindowID
    let element: AXUIElement
    let app: NSRunningApplication
    let title: String

    @Published var opacity: Double {
        didSet { panel?.alphaValue = opacity }
    }

    private var stream: SCStream?
    private var panel: NSPanel?
    private let layer = CALayer()
    private var poll: Timer?
    private var lastFrame: CGRect = .zero
    private var observer: Any?
    private let queue = DispatchQueue(label: "macutils.pin")

    init(windowID: CGWindowID, element: AXUIElement, app: NSRunningApplication) {
        self.windowID = windowID
        self.element = element
        self.app = app
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        let name = (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        title = [app.localizedName, name].compactMap { $0 }.joined(separator: " — ")
        let saved = UserDefaults.standard.double(forKey: Pref.windowPinOpacity)
        opacity = saved > 0 ? saved : 1
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }),
              let frame = WindowTiler.frame(of: element) else { throw CocoaError(.featureUnsupported) }
        lastFrame = frame
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration(for: frame), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        makePanel(frame: frame)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll
        updateVisibility()
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        panel?.orderOut(nil)
        panel = nil
    }

    func setOpacity(_ value: Double) {
        opacity = value
        UserDefaults.standard.set(value, forKey: Pref.windowPinOpacity)
    }

    /// Когда программа активна, её настоящее окно и так сверху — копию прячем.
    private func updateVisibility() {
        guard let panel else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Окно двигают или меняют размер — копия следует за ним.
    private func follow() {
        guard app.isTerminated == false else {
            WindowPin.shared.unpin(self)
            return
        }
        guard let frame = WindowTiler.frame(of: element) else {
            WindowPin.shared.unpin(self)
            return
        }
        guard frame != lastFrame else { return }
        let resized = frame.size != lastFrame.size
        lastFrame = frame
        panel?.setFrame(Self.cocoaRect(frame), display: true)
        if resized, let stream {
            let config = configuration(for: frame)
            Task { try? await stream.updateConfiguration(config) }
        }
    }

    private func configuration(for frame: CGRect) -> SCStreamConfiguration {
        let scale = NSScreen.screens.first { $0.frame.intersects(Self.cocoaRect(frame)) }?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 4
        if #available(macOS 14.2, *) { config.ignoreShadowsSingleWindow = true }
        return config
    }

    private func makePanel(frame: CGRect) {
        let panel = PinPanel(contentRect: Self.cocoaRect(frame), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = opacity
        let view = PinView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(layer)
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.contentsGravity = .resize
        view.pin = self
        panel.contentView = view
        self.panel = panel
    }

    /// Клик по копии — к настоящему окну.
    func activateOriginal() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        app.activate()
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Прозрачность", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for value in [1.0, 0.85, 0.7, 0.5, 0.3] {
            let item = ClosureMenuItem(title: "\(Int(value * 100)) %") { [weak self] in self?.setOpacity(value) }
            item.state = abs(opacity - value) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Открепить") { [weak self] in
            guard let self else { return }
            WindowPin.shared.unpin(self)
        })
        return menu
    }

    /// AX-координаты (от верхнего левого угла главного экрана) → координаты Cocoa.
    static func cocoaRect(_ rect: CGRect) -> NSRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - SCStream

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        let box = SurfaceBox(surface: surface)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.layer.contents = box.surface
                CATransaction.commit()
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                WindowPin.shared.unpin(self)
            }
        }
    }
}

private struct SurfaceBox: @unchecked Sendable {
    let surface: IOSurface
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

@MainActor
private final class PinView: NSView {
    weak var pin: PinnedWindow?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pin?.activateOriginal()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = pin?.menu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Пункт меню с замыканием вместо target/action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
