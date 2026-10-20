import AppKit
import AVFoundation
import CoreImage

/// Снимок кадра (⇧S): ровно показанный кадр, HDR сводится в SDR, сохраняется в «Мои снимки» (папка дня, как у
/// снимков экрана) и копируется в буфер. Отдельного диалога нет — тост v08c.
@MainActor
enum PlayerSnapshot {
    struct Result: Equatable {
        let url: URL
        let size: CGSize
        let time: Double
        let thumbnail: NSImage
    }

    static let app = "Видеоплеер"
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    static func take(from controller: PlayerWindowController) {
        let model = controller.model
        guard model.info.hasVideo else { return }
        Task { @MainActor in
            guard let image = await frame(of: model) else {
                controller.ui.flash(.message("Кадр не получился"), for: 2)
                return
            }
            let time = model.currentTime
            let name = fileName(video: model.info.title, time: time)
            let saved = await save(image, name: name)
            copyToPasteboard(image, file: saved)
            guard let saved else {
                controller.ui.flash(.message("Кадр скопирован в буфер, сохранить не удалось"), for: 3)
                return
            }
            let thumb = NSImage(cgImage: image, size: NSSize(width: 192, height: 192 * CGFloat(image.height) / CGFloat(max(image.width, 1))))
            controller.ui.showSnapshot(Result(url: saved, size: CGSize(width: image.width, height: image.height), time: time, thumbnail: thumb))
        }
    }

    /// Показанный кадр: из `AVPlayerItemVideoOutput`, если буфер именно этого времени уже готов (сразу после шага
    /// под нагрузкой там может быть ещё прежний кадр); иначе — точный кадр из файла на том же времени.
    static func frame(of model: PlayerModel) async -> CGImage? {
        guard let item = model.player.currentItem else { return nil }
        let time = item.currentTime()
        var display = CMTime.invalid
        if let output = model.videoOutput,
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &display),
           display.isValid, abs(display.seconds - time.seconds) < 0.001,
           let image = render(buffer, transform: model.info.transform) {
            return image
        }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if #available(macOS 15, *) { generator.dynamicRangePolicy = .forceSDR }
        return try? await generator.image(at: time).image
    }

    /// Пиксели кадра → картинка sRGB 8 бит; HDR (HLG, PQ) — с тональной компрессией, а не обрезкой.
    static func render(_ buffer: CVPixelBuffer, transform: CGAffineTransform = .identity) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer, options: [.toneMapHDRtoSDR: true])
        if transform != .identity {
            image = image.transformed(by: transform)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// «night_city_demo — кадр 0.23.10.png».
    static func fileName(video: String, time: Double) -> String {
        let base = (video as NSString).deletingPathExtension
        let stamp = PlayerFormat.time(time).replacingOccurrences(of: ":", with: ".")
        return "\(base.isEmpty ? "Кадр" : base) — кадр \(stamp).png"
    }

    /// В папку снимков: при включённых «Моих снимках» — в папку дня «Видеоплеер», и запись в библиотеку.
    private static func save(_ image: CGImage, name: String) async -> URL? {
        let root = Pref.screenshotDirectory
        let library = ScreenshotLibrary.shared
        let folder = library.enabled ? ShotLibraryRules.folder(root: root, date: Date(), app: app) : root
        let boxed = UncheckedSendable(image)
        let written = await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let png = ScreenshotEncoding.png(boxed.value) else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try? ScreenshotEncoding.write(png, to: folder.appendingPathComponent(name))
        }.value
        if let written { library.add(written, image: image, app: app) }
        return written
    }

    private static func copyToPasteboard(_ image: CGImage, file: URL?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))]
        if let file { objects.insert(file as NSURL, at: 0) }
        pasteboard.writeObjects(objects)
    }

    /// «Показать»: в «Моих снимках», а если они выключены — в Finder.
    static func reveal(_ url: URL) {
        if ScreenshotLibrary.shared.enabled {
            ToolsWindowController.shared.show(.shots)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
