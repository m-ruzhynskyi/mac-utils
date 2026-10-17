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

    /// false — захват не начался (идёт запись или длинный снимок, нет разрешения, уже открыт).
    @discardableResult
    func start(_ mode: Mode) -> Bool {
        // ⌘⇧X во время записи экрана — остановить её.
        if let recorder = ScreenRecorder.current {
            recorder.stop()
            return false
        }
        guard windows.isEmpty, !capturing, ScrollCapture.current == nil else { return false }
        guard Permissions.screenRecording else {
            Permissions.requestScreenRecording()
            Toast.show("Разрешите Mac Utils «Запись экрана» в настройках конфиденциальности",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
            return false
        }
        capturing = true
        // Запоминаем программу до того, как оверлей заберёт фокус.
        ScreenshotLibrary.shared.captureApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        // Панель шагов и предпросмотр коллажа прячутся и исключаются из кадра.
        let hidden = StepsSession.prepareForCapture()
        let snapFrames = WindowSnap.visibleWindowFrames()
        Task { @MainActor in
            defer { self.capturing = false }
            do {
                let shots = try await ScreenGrabber.captureAllScreens(excluding: hidden)
                guard !shots.isEmpty else {
                    StepsSession.captureClosed()
                    return
                }
                self.present(shots: shots, snapFrames: snapFrames, mode: mode)
            } catch {
                StepsSession.captureClosed()
                Toast.show("Не удалось сделать снимок: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
        return true
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
        var keyWindow = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        // Следующий шаг коллажа: область прошлого шага (или переснимаемого) уже выделена — Enter снимает её.
        if mode == .edit, let proposed = StepsSession.proposedRect,
           let window = windows.first(where: { $0.frame.contains(CGPoint(x: proposed.midX, y: proposed.midY)) }) {
            let local = proposed.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY).intersection(window.captureView.bounds)
            if local.width >= 4, local.height >= 4 {
                window.captureView.preselect(local)
                keyWindow = window
            }
        }
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

    /// Перерисовать оверлеи всех экранов (сменился режим выбора окна).
    func redrawAll() {
        for window in windows { window.captureView.needsDisplay = true }
    }

        /// Новое выделение на одном экране сбрасывает выделение на остальных.
    func selectionBegan(in view: CaptureView) {
        for window in windows where window.captureView !== view {
            window.captureView.resetSelection()
        }
    }

    /// `resumeSteps` — вернуть панель шагов или предпросмотр коллажа; не нужно, когда захват уступает место
    /// записи экрана или длинному снимку (тогда они вернутся сами, когда те закончатся).
    func close(resumeSteps: Bool = true) {
        keyTap?.stop()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        NSCursor.arrow.set()
        // Если вернулся предпросмотр коллажа, фокус остаётся у него: иначе он ушёл бы за окно прошлого приложения.
        let previewShown = StepsSession.captureClosed(resume: resumeSteps)
        if previewShown {
            FocusReturn.forget()
        } else if !SettingsWindowController.shared.isVisible {
            // Возвращаем фокус приложению, которое было активно до снимка.
            FocusReturn.restore()
        }
    }

    // MARK: - Результат

    func copy(_ image: CGImage) {
        close()
        complete(image, prefix: "Снимок экрана", clipboard: true, folder: false) { _, copied in
            if copied { Toast.show("Снимок скопирован", symbol: "doc.on.clipboard.fill", tint: .accentColor) }
        }
    }

    func save(_ image: CGImage) {
        close()
        complete(image, prefix: "Снимок экрана", clipboard: false, folder: true) { saved, _ in
            switch saved {
            case .success(let url)?:
                Toast.show("Сохранено: \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill", tint: .green)
            case .failure(let error)?:
                Toast.show("Не удалось сохранить: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            case nil:
                break
            }
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

    // MARK: - Коллаж шагов

    /// Сохранить коллаж в папку снимков. Захват не закрывается (его нет), тостов нет: результат — в `done`,
    /// и коллаж решает сам — закрыть шаги или оставить их и положить картинку в буфер.
    func saveCollage(_ image: CGImage, done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        complete(image, prefix: "Коллаж шагов", clipboard: false, folder: true,
                 encodeFailed: { done(.failure(CollageEncodingError())) }) { saved, _ in
            done(saved ?? .failure(CollageEncodingError()))
        }
    }

    /// Скопировать коллаж в буфер обмена. `done(false)` — не получилось (не закодировался, или за это время
    /// в буфер скопировали что-то новее).
    func copyCollage(_ image: CGImage, done: @escaping @MainActor (Bool) -> Void) {
        complete(image, prefix: "Коллаж шагов", clipboard: true, folder: false,
                 encodeFailed: { done(false) }) { _, copied in done(copied) }
    }

    /// Запись экрана: оверлей закрывается, область снимается видео.
    func startRecording(rect: NSRect) {
        close(resumeSteps: false)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            ScreenRecorder.start(rect: rect)
        }
    }

    /// Длинный снимок: закрываем оверлей, пользователь прокручивает, мы склеиваем кадры.
    func startScrollCapture(rect: NSRect) {
        close(resumeSteps: false)
        Task { @MainActor in
            // Даём оверлею исчезнуть, а фокусу вернуться к прокручиваемому окну.
            try? await Task.sleep(nanoseconds: 250_000_000)
            ScrollCapture.start(rect: rect)
        }
    }

    /// Длинный снимок готов: туда же, куда и обычные снимки.
    func deliverLongImage(_ image: CGImage) {
        let size = "\(image.height) px"
        switch Pref.screenshotDestinationValue {
        case .clipboard:
            complete(image, prefix: "Длинный снимок", clipboard: true, folder: false) { _, copied in
                if copied { Toast.show("Длинный снимок скопирован (\(size))", symbol: "scroll.fill", tint: .green) }
            }
        case .folder:
            complete(image, prefix: "Длинный снимок", clipboard: false, folder: true) { saved, _ in
                switch saved {
                case .success?:
                    Toast.show("Длинный снимок сохранён (\(size))", symbol: "scroll.fill", tint: .green)
                case .failure(let error)?:
                    Toast.show("Не удалось сохранить: \(error.localizedDescription)",
                               symbol: "exclamationmark.triangle.fill", tint: .orange)
                case nil:
                    break
                }
            }
        case .both:
            deliverBoth(image, prefix: "Длинный снимок", what: "Длинный снимок")
        }
    }

    private func deliverBoth(_ image: CGImage, prefix: String, what: String) {
        complete(image, prefix: prefix, clipboard: true, folder: true) { saved, copied in
            switch saved {
            case .success? where copied:
                Toast.show("\(what) скопирован и сохранён", symbol: "checkmark.circle.fill", tint: .green)
            case .success?:
                // Пока кодировался этот снимок, в буфер скопировали более новый: этот только сохранён.
                Toast.show("\(what) сохранён", symbol: "checkmark.circle.fill", tint: .green)
            case .failure(let error)?:
                Toast.show("Скопировано, но не сохранено: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            case nil:
                break
            }
        }
    }

    /// Общий путь доставки. Кодирование PNG и запись файла идут вне главного потока; в буфер обмена кладётся PNG,
    /// а TIFF кодируется лениво, только если приложение его запросит. Занятое имя файла не перезаписывается.
    /// `done(saved, copied)`: `saved` — результат записи (nil, если в папку не писали); `copied` — снимок лежит в буфере
    /// (false, если за время кодирования пользователь скопировал более новый: в буфере остаётся последний, а не самый медленный).
    /// `encodeFailed` — вместо общего тоста, когда PNG не получился (вызывающий сам решает, что делать).
    private func complete(_ image: CGImage, prefix: String, clipboard: Bool, folder: Bool,
                          encodeFailed: (@MainActor () -> Void)? = nil,
                          done: @escaping @MainActor (Result<URL, Error>?, Bool) -> Void) {
        let library = ScreenshotLibrary.shared
        // Скопированное только в буфер тоже может попасть в умную папку и в «Мои снимки».
        let keepsCopy = clipboard && !folder && library.enabled && UserDefaults.standard.bool(forKey: Pref.screenshotLibraryClipboard)
        var target: (url: URL, app: String)?
        var reserveError: Error?
        if folder || keepsCopy {
            do { target = (try Self.destinationURL(prefix: prefix), library.captureApp) } catch { reserveError = error }
        }
        let boxed = UncheckedSendable(image)
        // Выход или автообновление в эти секунды не должны терять снимок (кодирование длинного — секунды).
        BusyRegistry.shared.begin(.screenshotSaving)
        let ticket = clipboard ? Self.clipboardTickets.next() : 0
        Task { @MainActor in
            defer { BusyRegistry.shared.end(.screenshotSaving) }
            let png = await Task.detached(priority: .userInitiated) { ScreenshotEncoding.png(boxed.value) }.value
            guard let png else {
                if let encodeFailed {
                    encodeFailed()
                } else {
                    Toast.show("Не удалось закодировать снимок", symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
                return
            }
            let copied = clipboard && Self.clipboardTickets.isLatest(ticket)
            if copied { Self.putOnPasteboard(png, boxed.value) }
            guard let target else {
                done(folder ? reserveError.map { .failure($0) } : nil, copied)
                return
            }
            let written = await Task.detached(priority: .userInitiated) {
                Result { try ScreenshotEncoding.write(png, to: target.url) }
            }.value
            if case .success(let url) = written { library.add(url, image: nil, app: target.app) }
            done(folder ? written : nil, copied)
        }
    }

    private static var lazyTIFF: LazyTIFFProvider?
    private static var clipboardTickets = ClipboardTickets()

    private static func putOnPasteboard(_ png: Data, _ image: CGImage) {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let provider = LazyTIFFProvider(image)
        lazyTIFF = provider   // провайдер должен жить, пока кто-то может запросить TIFF
        provider.onFinish = { [weak provider] in
            // Буфер занят другим содержимым: кадр (десятки МБ для 5K) больше не нужен.
            DispatchQueue.main.async { MainActor.assumeIsolated { if lazyTIFF === provider { lazyTIFF = nil } } }
        }
        item.setDataProvider(provider, forTypes: [.tiff])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Путь для нового снимка (умная папка: день и программа). Имя с точностью до секунды, уникальность — при записи.
    private static func destinationURL(prefix: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let folder = Pref.screenshotDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ScreenshotLibrary.shared.destination(fileName: "\(prefix) \(formatter.string(from: Date())).png", root: folder)
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

struct CollageEncodingError: LocalizedError {
    var errorDescription: String? { "не удалось закодировать картинку" }
}

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
}

@MainActor
enum ScreenGrabber {
    /// `excluding` — номера своих окон, которых не должно быть в кадре (панель шагов, предпросмотр коллажа).
    static func captureAllScreens(excluding hidden: [CGWindowID] = []) async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = content.windows.filter { hidden.contains($0.windowID) }
        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
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
