import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import Vision

/// «Снимок»: собственная утилита скриншотов по мотивам macshot.
///   ⌘⇧X  — выделить область (или кликнуть по окну), разметить, скопировать / сохранить.
///   ⌘⇧⌥X — выделить область и сразу распознать в ней текст (OCR) в буфер обмена.
@MainActor
final class ScreenshotService: ObservableObject {
    static let shared = ScreenshotService()

    enum Mode { case edit, ocr }

    @Published private(set) var isRunning = false

    private var windows: [CaptureWindow] = []
    private var capturing = false
    /// Перехват клавиш на время снимка: оверлей фонового приложения не всегда
    /// становится ключевым окном, поэтому клавиши ловятся независимо от фокуса.
    private var keyTap: EventTap?

    private init() {}

    func sync() {
        let center = HotKeyCenter.shared
        if UserDefaults.standard.bool(forKey: Pref.screenshot) {
            if !center.isRegistered(id: HotKeyID.screenshot) {
                center.register(id: HotKeyID.screenshot, keyCode: kVK_ANSI_X,
                                modifiers: cmdKey | shiftKey) {
                    ScreenshotService.shared.start(.edit)
                }
            }
            if !center.isRegistered(id: HotKeyID.screenshotOCR) {
                center.register(id: HotKeyID.screenshotOCR, keyCode: kVK_ANSI_X,
                                modifiers: cmdKey | shiftKey | optionKey) {
                    ScreenshotService.shared.start(.ocr)
                }
            }
            isRunning = center.isRegistered(id: HotKeyID.screenshot)
        } else {
            center.unregister(id: HotKeyID.screenshot)
            center.unregister(id: HotKeyID.screenshotOCR)
            isRunning = false
        }
    }

    // MARK: - Захват

    func start(_ mode: Mode) {
        // ⌘⇧X во время записи экрана — остановить её.
        if let recorder = ScreenRecorder.current {
            recorder.stop()
            return
        }
        guard windows.isEmpty, !capturing, ScrollCapture.current == nil else { return }
        guard Permissions.screenRecording else {
            Permissions.requestScreenRecording()
            Toast.show("Разрешите Mac Utils «Запись экрана» в настройках конфиденциальности",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        capturing = true
        // Запоминаем программу до того, как оверлей заберёт фокус.
        ScreenshotLibrary.shared.captureApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        StepsSession.hideHUD()
        let snapFrames = WindowSnap.visibleWindowFrames()
        Task { @MainActor in
            defer { self.capturing = false }
            do {
                let shots = try await ScreenGrabber.captureAllScreens()
                guard !shots.isEmpty else { return }
                self.present(shots: shots, snapFrames: snapFrames, mode: mode)
            } catch {
                StepsSession.showHUD()
                Toast.show("Не удалось сделать снимок: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    private func present(shots: [ScreenShot], snapFrames: [CGRect], mode: Mode) {
        let mouse = NSEvent.mouseLocation
        for shot in shots {
            let window = CaptureWindow.make(shot: shot, snapFrames: snapFrames, mode: mode)
            windows.append(window)
            window.orderFrontRegardless()
        }
        if !SettingsWindowController.shared.isVisible { FocusReturn.remember() }
        NSApp.activate()
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        let keyWindow = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
        startKeyTap()
    }

    private func startKeyTap() {
        if keyTap == nil {
            keyTap = EventTap(types: [.keyDown]) { [weak self] _, event in
                self?.routeKey(event) ?? true
            }
        }
        if keyTap?.start() != true {
            Log.capture.error("Не удалось создать перехват клавиш для снимка")
        }
    }

    /// Возвращает `false`, если клавиша обработана оверлеем и её нужно поглотить.
    private func routeKey(_ cgEvent: CGEvent) -> Bool {
        guard let view = activeView, !view.isEditingText,
              let event = NSEvent(cgEvent: cgEvent) else { return true }
        return !view.handleKey(event)
    }

    /// Оверлей, которому адресованы клавиши: ключевой, с выделением или под курсором.
    private var activeView: CaptureView? {
        let mouse = NSEvent.mouseLocation
        return (windows.first { $0.isKeyWindow }
            ?? windows.first { $0.captureView.hasSelection }
            ?? windows.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? windows.first)?.captureView
    }

    /// Новое выделение на одном экране сбрасывает выделение на остальных.
    func selectionBegan(in view: CaptureView) {
        for window in windows where window.captureView !== view {
            window.captureView.resetSelection()
        }
    }

    func close() {
        keyTap?.stop()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        NSCursor.arrow.set()
        StepsSession.showHUD()
        // Возвращаем фокус приложению, которое было активно до снимка.
        if !SettingsWindowController.shared.isVisible {
            FocusReturn.restore()
        }
    }

    // MARK: - Результат

    func copy(_ image: CGImage) {
        close()
        guard let png = Self.png(image) else { return }
        Self.putOnPasteboard(png, image)
        Toast.show("Снимок скопирован", symbol: "doc.on.clipboard.fill", tint: .accentColor)
    }

    func save(_ image: CGImage) {
        close()
        guard let png = Self.png(image) else { return }
        do {
            let url = try Self.writeToFolder(png, prefix: "Снимок экрана")
            Toast.show("Сохранено: \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill", tint: .green)
        } catch {
            Toast.show("Не удалось сохранить: \(error.localizedDescription)",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    /// Основное действие (Enter, двойной клик): куда — по настройке «Куда сохранять».
    func deliver(_ image: CGImage) {
        switch Pref.screenshotDestinationValue {
        case .clipboard:
            copy(image)
        case .folder:
            save(image)
        case .both:
            close()
            deliverBoth(image, prefix: "Снимок экрана", what: "Снимок")
        }
    }

    /// Запись экрана: оверлей закрывается, область снимается видео.
    func startRecording(rect: NSRect) {
        close()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            ScreenRecorder.start(rect: rect)
        }
    }

    /// Длинный снимок: закрываем оверлей, пользователь прокручивает, мы склеиваем кадры.
    func startScrollCapture(rect: NSRect) {
        close()
        Task { @MainActor in
            // Даём оверлею исчезнуть, а фокусу вернуться к прокручиваемому окну.
            try? await Task.sleep(nanoseconds: 250_000_000)
            ScrollCapture.start(rect: rect)
        }
    }

    /// Длинный снимок готов: туда же, куда и обычные снимки.
    func deliverLongImage(_ image: CGImage) {
        guard let png = Self.png(image) else { return }
        let size = "\(image.height) px"
        switch Pref.screenshotDestinationValue {
        case .clipboard:
            Self.putOnPasteboard(png, image)
            Toast.show("Длинный снимок скопирован (\(size))", symbol: "scroll.fill", tint: .green)
        case .folder:
            do {
                _ = try Self.writeToFolder(png, prefix: "Длинный снимок")
                Toast.show("Длинный снимок сохранён (\(size))", symbol: "scroll.fill", tint: .green)
            } catch {
                Toast.show("Не удалось сохранить: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        case .both:
            deliverBoth(image, prefix: "Длинный снимок", what: "Длинный снимок")
        }
    }

    private func deliverBoth(_ image: CGImage, prefix: String, what: String) {
        guard let png = Self.png(image) else { return }
        Self.putOnPasteboard(png, image)
        do {
            _ = try Self.writeToFolder(png, prefix: prefix)
            Toast.show("\(what) скопирован и сохранён", symbol: "checkmark.circle.fill", tint: .green)
        } catch {
            Toast.show("Скопировано, но не сохранено: \(error.localizedDescription)",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func putOnPasteboard(_ png: Data, _ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    private static func writeToFolder(_ png: Data, prefix: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let folder = Pref.screenshotDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Умная папка: «Снимки экрана/день/программа», текст распознаётся для поиска.
        let library = ScreenshotLibrary.shared
        let url = library.destination(fileName: "\(prefix) \(formatter.string(from: Date())).png", root: folder)
        try png.write(to: url)
        library.add(url, image: nil, app: library.captureApp)
        return url
    }

    func recognizeText(_ image: CGImage) {
        close()
        Task.detached(priority: .userInitiated) {
            let text = TextRecognizer.recognize(image)
            await MainActor.run {
                if text.isEmpty {
                    Toast.show("Текст не найден", symbol: "text.viewfinder", tint: .orange)
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    Toast.show("Текст скопирован", symbol: "text.viewfinder", tint: .green)
                }
            }
        }
    }
}

// MARK: - Снимок экранов

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
}

@MainActor
enum ScreenGrabber {
    static func captureAllScreens() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(ScreenShot(screen: screen, image: image))
        }
        return shots
    }
}

/// Рамки видимых окон (в координатах Cocoa) для «прилипания» выделения к окну.
@MainActor
enum WindowSnap {
    static func visibleWindowFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info -> CGRect? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 40, bounds.height > 40 else { return nil }
            // CG: начало координат сверху слева основного экрана; Cocoa — снизу слева.
            return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                          width: bounds.width, height: bounds.height)
        }
    }
}

// MARK: - OCR

enum TextRecognizer {
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["ru-RU", "uk-UA", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
