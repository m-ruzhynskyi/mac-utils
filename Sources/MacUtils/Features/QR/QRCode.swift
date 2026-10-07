import AppKit
import Carbon.HIToolbox
import CoreImage
import SwiftUI
import Vision

/// Создание и распознавание QR-кодов (без UI — для тестов).
enum QRTools {
    /// QR-код как картинка: каждый модуль — `scale` пикселей, без размытия.
    static func make(_ text: String, scale: CGFloat = 12) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
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
        center.unregister(id: HotKeyID.qr)
        guard UserDefaults.standard.bool(forKey: Pref.qr) else {
            hide()
            return
        }
        center.register(id: HotKeyID.qr, keyCode: kVK_ANSI_Q, modifiers: controlKey | optionKey) {
            QRCodeService.shared.run()
        }
    }

    func run() {
        if let selected = LayoutFix.selectedTextViaAX()?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            show(selected)
        } else {
            scanScreen()
        }
    }

    // MARK: - Сканирование экрана

    func scanScreen() {
        guard Permissions.screenRecording else {
            Permissions.requestScreenRecording()
            Toast.show("Чтобы искать QR на экране, разрешите «Запись экрана»", symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        Task { @MainActor in
            let shots = (try? await ScreenGrabber.captureAllScreens()) ?? []
            let images = shots.map(\.image)
            let found = await Task.detached(priority: .userInitiated) {
                images.flatMap { QRTools.detect(in: $0) }
            }.value
            guard !found.isEmpty else {
                Toast.show("QR-код на экране не найден. Выделите текст, чтобы сделать QR из него.",
                           symbol: "qrcode.viewfinder", tint: .orange)
                return
            }
            let joined = found.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
            let first = found[0]
            let link = URL(string: first).flatMap { ["http", "https", "mailto", "tel"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            let preview = first.count > 60 ? String(first.prefix(57)) + "…" : first
            let title = found.count > 1 ? "QR (\(found.count)) скопированы: \(preview)" : "QR скопирован: \(preview)"
            Toast.show(title, symbol: "qrcode.viewfinder", tint: .green,
                       action: link.map { url in Toast.Action(title: "Открыть") { NSWorkspace.shared.open(url) } })
        }
    }

    // MARK: - QR из текста

    func show(_ text: String) {
        self.text = text
        image = QRTools.make(text).map { NSImage(cgImage: $0, size: NSSize(width: 220, height: 220)) }
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
        panel.orderFrontRegardless()
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
        VStack(spacing: 10) {
            if let image = service.image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            }
            Text(service.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            HStack {
                Button("Скопировать") { service.copyImage() }
                    .buttonStyle(.borderedProminent)
                Button("Сохранить") { service.saveImage() }
                Button("Закрыть") { service.hide() }
                    .help("Esc")
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(4)
    }
}
