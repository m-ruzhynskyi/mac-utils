import AppKit
import Carbon.HIToolbox
import CoreImage
import SwiftUI
import Vision

/// Создание и распознавание QR-кодов (без UI — для тестов).
enum QRTools {
    /// Можно ли брать выделение через ⌘C в этой программе (в Finder ⌘C копирует файлы, а не текст).
    static func copyFallbackAllowed(frontmost bundleID: String?) -> Bool {
        bundleID != "com.apple.finder"
    }

    /// Пробовать ли ⌘C, когда на экране QR не нашёлся. `selectionLength` — длина выделения по AX:
    /// 0 — выделения точно нет (⌘C скопировал бы строку или ячейку, а не выделенный текст); nil — AX не ответил.
    static func shouldTryCopy(frontmost bundleID: String?, selectionLength: Int?) -> Bool {
        copyFallbackAllowed(frontmost: bundleID) && selectionLength != 0
    }

    /// Длина выделения в поле в фокусе (`kAXSelectedTextRangeAttribute`); nil — программа не отдаёт его через AX.
    @MainActor
    static func focusedSelectionLength() -> Int? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.length
    }

    /// Белое поле вокруг кода в модулях: по стандарту не меньше 4, иначе на тёмном фоне телефон его не читает.
    static let quietZone = 4
    /// `CIQRCodeGenerator` уже оставляет поле в один модуль: добавляем недостающее.
    private static let generatorMargin = 1

    /// Один контекст на все вызовы: создавать его на каждую картинку дорого.
    private static let context = CIContext()

    /// QR-код как картинка: каждый модуль — `scale` пикселей (целое), без размытия, с белым полем `quietZone` модулей.
    static func make(_ text: String, scale: Int = 12) -> CGImage? {
        guard let code = modules(text) else { return nil }
        let border = CGFloat(quietZone - generatorMargin)
        let background = CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -border, dy: -border))
        let framed = code.composited(over: background)
            .transformed(by: CGAffineTransform(translationX: border, y: border))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(max(1, scale)), y: CGFloat(max(1, scale))))
        return context.createCGImage(framed, from: framed.extent.integral)
    }

    /// Код с полем генератора (1 модуль), один пиксель на модуль (nil — текст не помещается в QR).
    private static func modules(_ text: String) -> CIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, !output.extent.isEmpty else { return nil }
        return output
    }

    /// Сторона кода с полем в модулях.
    static func side(_ text: String) -> Int? {
        modules(text).map { Int($0.extent.width) + 2 * (quietZone - generatorMargin) }
    }

    /// Целое число точек на модуль, чтобы код (с полем) помещался в `maxPoints`: при дробном масштабе модули плотного
    /// кода выходят разной ширины. Не меньше 1.
    static func pointsPerModule(side: Int, maxPoints: CGFloat) -> Int {
        guard side > 0 else { return 1 }
        return max(1, Int((maxPoints / CGFloat(side)).rounded(.down)))
    }

    /// Wi-Fi QR: `WIFI:T:WPA;S:сеть;P:пароль;;`.
    static func isWiFi(_ payload: String) -> Bool { payload.uppercased().hasPrefix("WIFI:") }

    /// Текст для показа на экране: у Wi-Fi QR пароль (`P:…`, с экранированием `\;`) заменён точками.
    static func masked(_ payload: String) -> String {
        guard isWiFi(payload) else { return payload }
        var fields: [String] = []
        var current = ""
        var escaped = false
        for ch in payload.dropFirst(5) {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == ";" { fields.append(current); current = ""; continue }
            current.append(ch)
        }
        if !current.isEmpty { fields.append(current) }
        let hidden = fields.map { $0.uppercased().hasPrefix("P:") ? "P:••••" : $0 }
        return payload.prefix(5) + hidden.joined(separator: ";") + ";;"
    }

    /// Все QR (и другие 2D-коды) на картинке.
    static func detect(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .dataMatrix, .pdf417]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
    }
}

/// «QR»: ⌃⌥Q. Выделен текст — сделать из него QR. Нет — найти QR-коды на экране
/// и скопировать их содержимое (ссылку можно сразу открыть).
@MainActor
final class QRCodeService: ObservableObject {
    static let shared = QRCodeService()

    @Published private(set) var text = ""
    @Published private(set) var image: NSImage?

    private var panel: NSPanel?
    private var outsideMonitor: Any?
    private var keyTap: EventTap?

    func sync() {
        let center = HotKeyCenter.shared
        guard UserDefaults.standard.bool(forKey: Pref.qr) else {
            center.unregister(id: HotKeyID.qr)
            hide()
            return
        }
        center.register(id: HotKeyID.qr, keyCode: kVK_ANSI_Q, modifiers: controlKey | optionKey) {
            AppAction(hotKey: .qr).run()
        }
    }

    func run() {
        if let selected = LayoutFix.selectedTextViaAX()?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            show(selected)
            return
        }
        // Выделения через AX нет. Сначала ищем QR на экране: ⌘C без выделения в части программ копирует сам
        // (VS Code и JetBrains — текущую строку, таблицы — ячейку), и вместо поиска получился бы QR из этого.
        // ⌘C — только если на экране QR нет и выделение не известно как пустое (Chrome, Electron, Терминал не отдают его через AX).
        let tryCopy = QRTools.shouldTryCopy(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                            selectionLength: QRTools.focusedSelectionLength())
        Task { @MainActor in
            let canScan = Permissions.screenRecording
            if canScan {
                let found = await self.detectOnScreen()
                if !found.isEmpty {
                    self.deliverFound(found)
                    return
                }
            }
            if tryCopy, let copied = await LayoutFix.selectedTextViaCopy()?.trimmingCharacters(in: .whitespacesAndNewlines),
               !copied.isEmpty {
                self.show(copied)
                return
            }
            if canScan { self.reportNotFound() } else { self.askForScreenRecording() }
        }
    }

    // MARK: - Сканирование экрана

    func scanScreen() {
        guard Permissions.screenRecording else {
            askForScreenRecording()
            return
        }
        Task { @MainActor in
            let found = await self.detectOnScreen()
            if found.isEmpty { self.reportNotFound() } else { self.deliverFound(found) }
        }
    }

    private func askForScreenRecording() {
        hide()
        Permissions.requestScreenRecording()
        Toast.show("Чтобы искать QR на экране, разрешите «Запись экрана»", symbol: "exclamationmark.triangle.fill", tint: .orange)
    }

    private func reportNotFound() {
        Toast.show("QR-код на экране не найден. Выделите текст, чтобы сделать QR из него.",
                   symbol: "qrcode.viewfinder", tint: .orange)
    }

    /// QR-коды на всех экранах (пусто — не нашлось или не удалось снять экран).
    private func detectOnScreen() async -> [String] {
        // Открытая панель с QR нашла бы сама себя.
        hide()
        let shots = (try? await ScreenGrabber.captureAllScreens()) ?? []
        let images = shots.map(\.image)
        return await Task.detached(priority: .userInitiated) {
            images.flatMap { QRTools.detect(in: $0) }
        }.value
    }

    /// Найденные коды — в буфер обмена, первый показываем в уведомлении (ссылку можно открыть).
    private func deliverFound(_ found: [String]) {
        guard let first = found.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(found.joined(separator: "\n"), forType: .string)
        // Пароль Wi-Fi: менеджеры буфера обмена такое не запоминают.
        if found.contains(where: QRTools.isWiFi) {
            NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        let link = URL(string: first).flatMap { ["http", "https", "mailto", "tel"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let shown = QRTools.masked(first)
        let preview = shown.count > 60 ? String(shown.prefix(57)) + "…" : shown
        let title = found.count > 1 ? "QR (\(found.count)) скопированы: \(preview)" : "QR скопирован: \(preview)"
        Toast.show(title, symbol: "qrcode.viewfinder", tint: .green,
                   action: link.map { url in Toast.Action(title: "Открыть") { NSWorkspace.shared.open(url) } })
    }

    // MARK: - QR из текста

    func show(_ text: String) {
        // Панель неактивирующая: ⌃⌥Q можно нажать при открытой — прежние монитор мыши и tap клавиш надо снять.
        hide()
        self.text = text
        // Целое число точек на модуль (на Retina — вдвое больше пикселей): модули одинаковой ширины.
        if let side = QRTools.side(text) {
            let points = QRTools.pointsPerModule(side: side, maxPoints: 240)
            let pixelScale = points * Int((NSScreen.withMouse ?? NSScreen.main)?.backingScaleFactor ?? 2)
            image = QRTools.make(text, scale: pixelScale).map {
                NSImage(cgImage: $0, size: NSSize(width: side * points, height: side * points))
            }
        } else {
            image = nil
        }
        guard image != nil else {
            Toast.show("Текст слишком длинный для QR", symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        let panel = self.panel ?? makePanel()
        if let screen = NSScreen.withMouse ?? NSScreen.main {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                         y: screen.visibleFrame.midY - size.height / 2))
        }
        panel.orderFrontRegardlessOnScreen()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { QRCodeService.shared.hide() }
        }
        let tap = EventTap(types: [.keyDown]) { _, event in
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return true }
            QRCodeService.shared.hide()
            return false
        }
        tap.start()
        keyTap = tap
    }

    func hide() {
        panel?.orderOut(nil)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        keyTap?.stop()
        keyTap = nil
    }

    func copyImage() {
        guard let cg = QRTools.make(text, scale: 16) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        NSPasteboard.general.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) { NSPasteboard.general.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { NSPasteboard.general.setData(tiff, forType: .tiff) }
        hide()
        Toast.show("QR-код скопирован", symbol: "qrcode", tint: .green)
    }

    func saveImage() {
        guard let cg = QRTools.make(text, scale: 16),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let url = Pref.screenshotDirectory.appendingPathComponent("QR \(formatter.string(from: Date())).png")
        do {
            try png.write(to: url)
            hide()
            Toast.show("QR сохранён: \(url.lastPathComponent)", symbol: "qrcode", tint: .green,
                       action: Toast.Action(title: "Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        } catch {
            Toast.show("Не удалось сохранить: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func makePanel() -> NSPanel {
        let host = FirstMouseHostingView(rootView: QRPanelView(service: self))
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

private struct QRPanelView: View {
    @ObservedObject var service: QRCodeService

    var body: some View {
        QRPanelContent(image: service.image, text: service.text,
                       copy: { service.copyImage() }, save: { service.saveImage() }, close: { service.hide() })
    }
}

/// Панель с QR-кодом (Graphite: `panel`, обводка `line`, радиус 20). Без модели — для снимков интерфейса.
struct QRPanelContent: View {
    let image: NSImage?
    let text: String
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: DS.Space.m) {
            if let image {
                // Белое поле уже в картинке (тихая зона): без растяжения и отступов.
                Image(nsImage: image)
                    .interpolation(.none)
                    .frame(width: image.size.width, height: image.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            }
            Text(text)
                .font(DS.Font.mono(12, relativeTo: .caption))
                .foregroundStyle(.dsMute)
                .lineLimit(3)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            HStack(spacing: DS.Space.s) {
                Button("Скопировать", action: copy).buttonStyle(.graphite(.primary, size: .compact))
                Button("Сохранить", action: save).buttonStyle(.graphite(.secondary, size: .compact))
                Button("Закрыть", action: close).buttonStyle(.graphite(.ghost, size: .compact)).help("Esc")
            }
        }
        .padding(DS.Space.l)
        .frame(width: 300)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .padding(4)
    }
}
