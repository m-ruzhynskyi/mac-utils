import AppKit
import MUCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Окно-зеркало (отладочное; окно интерфейса со строкой программ делает UI и кладёт в него тот же `MirrorView`).
/// `sharingType = .none`: на macOS 27.2 окно не попадает в `SCScreenshotManager` всего дисплея (проверено менеджером 13.11).
public final class MirrorWindow: NSWindow {
    public let mirrorView: MirrorView
    /// Окно сдвинули или изменили размер — интерфейс переставляет полоску (`mirrorFrame`).
    public var onMoveOrResize: (() -> Void)?

    /// `titleBar` — обычный заголовок (отладочный запуск); без него окно без рамки, а двигает его полоска интерфейса.
    public init(title: String, size: CGSize, titleBar: Bool = true, view: MirrorView? = nil) {
        mirrorView = view ?? MirrorView(frame: CGRect(origin: .zero, size: size))
        mirrorView.frame = CGRect(origin: .zero, size: size)
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: titleBar ? [.titled, .closable, .resizable, .miniaturizable] : [.borderless, .resizable],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        animationBehavior = .none
        hasShadow = true
        minSize = CGSize(width: 320, height: 240)
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        contentView = mirrorView
        MirrorView.protect(self)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSWindow.didResizeNotification, object: self)
    }

    @objc private func changed() { onMoveOrResize?() }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }
}

/// Картинка окна ИИ и весь ввод. Координаты — от левого верхнего угла (как у `MirrorMapping`).
public final class MirrorView: NSView, NSDraggingSource {
    /// Мышь, прокрутка, клавиши.
    public var onInput: ((MirrorInput) -> Void)?
    /// Брошенное в зеркало: маршрут и буфер перетаскивания. true — принято.
    public var onDrop: ((DropRoute, NSPasteboard) -> Bool)?
    /// Размер вида изменился (пользователь тянет окно) — движок меняет размер настоящего окна.
    public var onResize: ((CGSize) -> Void)?
    /// Что тянуть наружу при перетаскивании с ⌥ (содержимое буфера после «Скопировать» в меню программы).
    public var exportItems: (() -> [NSDraggingItem])?

    private let cursorLayer = CALayer()
    private var exportStart: CGPoint?

    /// Защита окна от захвата экрана. Любое окно, показывающее зеркало, должно пройти через это.
    public static func protect(_ window: NSWindow) {
        window.sharingType = .none
    }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        cursorLayer.contents = NSCursor.arrow.image
        cursorLayer.bounds = CGRect(origin: .zero, size: NSCursor.arrow.image.size)
        cursorLayer.anchorPoint = CGPoint(x: NSCursor.arrow.hotSpot.x / max(NSCursor.arrow.image.size.width, 1),
                                          y: NSCursor.arrow.hotSpot.y / max(NSCursor.arrow.image.size.height, 1))
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        layer?.addSublayer(cursorLayer)
        registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Кадр ScreenCaptureKit (IOSurface) — прямо в слой, без копирования.
    public func show(surface: IOSurfaceRef) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
    }

    /// Курсор-подсказка, пока настоящий курсор на скрытом дисплее (перетаскивание, меню, прокрутка). nil — убрать.
    public func showHandoffCursor(at point: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let point {
            cursorLayer.position = point
            cursorLayer.isHidden = false
        } else {
            cursorLayer.isHidden = true
        }
        CATransaction.commit()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?(newSize) }
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    private func flags(_ event: NSEvent) -> CGEventFlags { CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)) }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option), exportItems != nil {
            exportStart = point(event)
            return
        }
        onInput?(.mouse(.down, .left, at: point(event), clicks: event.clickCount, flags: flags(event)))
    }

    override public func mouseDragged(with event: NSEvent) {
        if let start = exportStart {
            let now = point(event)
            guard hypot(now.x - start.x, now.y - start.y) >= 3, let items = exportItems?(), !items.isEmpty else { return }
            exportStart = nil
            beginDraggingSession(with: items, event: event, source: self)
            return
        }
        onInput?(.mouse(.dragged, .left, at: point(event), clicks: 1, flags: flags(event)))
    }

    override public func mouseUp(with event: NSEvent) {
        if exportStart != nil {
            exportStart = nil
            return
        }
        onInput?(.mouse(.up, .left, at: point(event), clicks: event.clickCount, flags: flags(event)))
    }

    override public func rightMouseDown(with event: NSEvent) {
        onInput?(.mouse(.down, .right, at: point(event), clicks: event.clickCount, flags: flags(event)))
    }
    override public func rightMouseUp(with event: NSEvent) {
        onInput?(.mouse(.up, .right, at: point(event), clicks: event.clickCount, flags: flags(event)))
    }
    override public func mouseMoved(with event: NSEvent) { onInput?(.moved(at: point(event))) }

    override public func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        onInput?(.scroll(dx: precise ? event.scrollingDeltaX : event.deltaX, dy: precise ? event.scrollingDeltaY : event.deltaY,
                         precise: precise, at: point(event)))
    }

    override public func keyDown(with event: NSEvent) {
        onInput?(.key(code: event.keyCode, down: true, flags: flags(event), characters: event.characters))
    }
    override public func keyUp(with event: NSEvent) {
        onInput?(.key(code: event.keyCode, down: false, flags: flags(event), characters: event.characters))
    }

    /// Сочетания с ⌘ сначала приходят сюда, раньше главного меню Mac Utils: иначе ⌘V/⌘C/⌘A съело бы меню «Правка».
    /// Ctrl+V из «Клавиш Windows» к этому моменту уже ⌘V.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Первым ответчиком зеркало может и не быть (нажатие мыши перехвачено до него) — достаточно, что окно ключевое.
        guard event.type == .keyDown, window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        let route = MirrorKeys.route(code: event.keyCode, flags: flags(event))
        Log.hiddenScreen.info("зеркало: сочетание код \(event.keyCode), флаги \(event.modifierFlags.rawValue), первый ответчик — \(self.window?.firstResponder === self ? "зеркало" : "другой", privacy: .public), маршрут \(String(describing: route), privacy: .public)")
        switch route {
        case .forward:
            onInput?(.key(code: event.keyCode, down: true, flags: flags(event), characters: event.charactersIgnoringModifiers))
            onInput?(.key(code: event.keyCode, down: false, flags: flags(event), characters: event.charactersIgnoringModifiers))
            return true
        case .drop:
            return true
        case .keepLocal:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: Перетаскивание в зеркало

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.route(sender.draggingPasteboard) == .unsupported ? [] : .copy
    }

    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        return onDrop?(Self.route(pasteboard), pasteboard) ?? false
    }

    static func route(_ pasteboard: NSPasteboard) -> DropRoute {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let types = pasteboard.types?.map(\.rawValue) ?? []
        return DropBridge.route(fileURLs: urls, types: types, text: pasteboard.string(forType: .string))
    }

    // MARK: Перетаскивание из зеркала (NSDraggingSource)

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Поток кадров одного окна (ScreenCaptureKit, разрешение «Запись экрана»). Курсор не рисуем — он свой у зеркала.
public final class WindowStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "macutils.hidden-screen.stream", qos: .userInteractive)
    private let onFrame: (IOSurfaceRef) -> Void
    public var onStop: ((Error?) -> Void)?
    public private(set) var windowID: CGWindowID = 0

    public init(onFrame: @escaping (IOSurfaceRef) -> Void) {
        self.onFrame = onFrame
    }

    public func start(windowID: CGWindowID, pixelSize: CGSize) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: Self.configuration(pixelSize), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.windowID = windowID
    }

    /// Новый размер окна → новый размер кадра (без перезапуска потока).
    public func resize(pixelSize: CGSize) async {
        try? await stream?.updateConfiguration(Self.configuration(pixelSize))
    }

    public func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    static func configuration(_ pixelSize: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(Int(pixelSize.width), 2)
        config.height = max(Int(pixelSize.height), 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 4
        return config
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        let onFrame = onFrame
        DispatchQueue.main.async { onFrame(surface) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let onStop = onStop
        DispatchQueue.main.async { onStop?(error) }
    }
}
