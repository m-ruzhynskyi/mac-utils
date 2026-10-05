// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ScreenCaptureKit
import SwiftUI

/// Длинный снимок с прокруткой: выделенная область снимается несколько раз
/// в секунду, пока пользователь прокручивает содержимое вниз, а новые строки
/// приклеиваются снизу.
@MainActor
final class ScrollCapture: NSObject, ObservableObject {
    private(set) static var current: ScrollCapture?

    @Published private(set) var capturedHeight = 0
    @Published private(set) var lostTrack = false

    private let rect: NSRect
    private let screen: NSScreen
    private let filter: SCContentFilter
    private var stitcher = Stitcher()
    private var timer: Timer?
    private var busy = false
    private var borderPanel: NSPanel?
    private var hudPanel: NSPanel?
    /// Esc — отмена, Enter — готово; работает без фокуса на панели.
    private var keyTap: EventTap?

    private init(rect: NSRect, screen: NSScreen, filter: SCContentFilter) {
        self.rect = rect
        self.screen = screen
        self.filter = filter
        super.init()
    }

    static func start(rect: NSRect) {
        Log.capture.info("Длинный снимок: старт, область \(NSStringFromRect(rect), privacy: .public)")
        guard current == nil else {
            Log.capture.error("Длинный снимок уже идёт")
            return
        }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.displayID else {
            Log.capture.error("Длинный снимок: экран не найден")
            return
        }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    Log.capture.error("Длинный снимок: дисплей \(displayID) не найден в SCShareableContent")
                    return
                }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let own = content.applications.filter { $0.processID == ownPID }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let capture = ScrollCapture(rect: rect.intersection(screen.frame), screen: screen, filter: filter)
                current = capture
                capture.begin()
            } catch {
                Log.capture.error("Длинный снимок: SCShareableContent: \(error.localizedDescription, privacy: .public)")
                Toast.show("Не удалось начать длинный снимок: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    // MARK: - Жизненный цикл

    private func begin() {
        showPanels()
        startKeyTap()
        tick()
        let timer = Timer(timeInterval: 0.15, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func finish() {
        stop()
        Log.capture.info("Длинный снимок: готово, \(self.stitcher.height) px")
        guard let image = stitcher.makeImage() else {
            Toast.show("Длинный снимок пуст: кадры не сняты", symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        ScreenshotService.shared.deliverLongImage(image)
    }

    func cancel() {
        stop()
        Toast.show("Длинный снимок отменён", symbol: "xmark.circle.fill", tint: .secondary)
    }

    private func stop() {
        keyTap?.stop()
        keyTap = nil
        timer?.invalidate()
        timer = nil
        borderPanel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        borderPanel = nil
        hudPanel = nil
        Self.current = nil
    }

    // MARK: - Кадры

    @objc private func tick() {
        guard !busy, timer != nil || stitcher.height == 0 else { return }
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            let frame: CGImage
            do {
                frame = try await self.grab()
            } catch {
                Log.capture.error("Длинный снимок: кадр не снят: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard Self.current === self else { return }
            let before = self.stitcher.height
            let result = self.stitcher.add(frame)
            Log.capture.debug("Кадр \(frame.width)×\(frame.height): \(String(describing: result), privacy: .public), +\(self.stitcher.height - before) px")
            switch result {
            case .appended, .first:
                self.lostTrack = false
            case .unchanged:
                break
            case .lost:
                self.lostTrack = true
            }
            self.capturedHeight = self.stitcher.height
            if self.stitcher.isFull { self.finish() }
        }
    }

    private func grab() async throws -> CGImage {
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        // sourceRect — в точках дисплея, начало координат сверху слева.
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX,
                                   y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Клавиши

    private func startKeyTap() {
        let tap = EventTap(types: [.keyDown]) { [weak self] _, event in
            guard let self else { return true }
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 53: self.cancel()          // Esc
            case 36, 76: self.finish()      // Return / Enter
            default: return true
            }
            return false
        }
        if !tap.start() { Log.capture.error("Длинный снимок: нет перехвата клавиш") }
        keyTap = tap
    }

    // MARK: - Панели

    private func showPanels() {
        let border = NSPanel(contentRect: rect.insetBy(dx: -3, dy: -3),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.ignoresMouseEvents = true
        border.hasShadow = false
        border.level = .statusBar
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(Color.red))
        border.orderFrontRegardless()
        borderPanel = border

        let host = FirstMouseHostingView(rootView: ScrollCaptureHUD(capture: self))
        let size = host.fittingSize
        let hud = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.level = .statusBar
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = host
        let visible = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < visible.minY + 8 { origin.y = rect.maxY + 12 }
        if origin.y + size.height > visible.maxY { origin.y = rect.minY + 12 }
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        hud.setFrameOrigin(origin)
        hud.orderFrontRegardless()
        hudPanel = hud
    }
}

/// Кнопки HUD должны нажиматься с первого клика: панель не активирует приложение.
/// Курсор над HUD — обычная стрелка, даже когда приложение неактивно.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["cursor"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["cursor": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        NSCursor.arrow.set()
    }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ScrollCaptureHUD: View {
    @ObservedObject var capture: ScrollCapture

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: capture.lostTrack ? "exclamationmark.triangle.fill" : "scroll")
                .foregroundStyle(capture.lostTrack ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.lostTrack ? "Слишком быстро: прокрутите чуть назад" : "Медленно прокручивайте вниз")
                    .font(.system(size: 12, weight: .semibold))
                Text("Снято: \(capture.capturedHeight) px")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Отмена") { capture.cancel() }
                .help("Esc")
            Button("Готово") { capture.finish() }
                .help("Enter")
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(4)
    }
}

// MARK: - Склейка

/// Склеивает кадры одной области по вертикали. Каждый кадр сжимается до
/// 64 колонок в оттенках серого; полоса строк нового кадра ищется в прошлом
/// кадре, и найденный сдвиг — это сколько новых строк появилось снизу.
struct Stitcher {
    enum Result { case first, appended, unchanged, lost }

    private static let columns = 64
    private static let maxHeight = 40_000

    private(set) var height = 0
    private var chunks: [CGImage] = []
    private var previous: [UInt8]?
    private var rows = 0

    var isFull: Bool { height >= Self.maxHeight }

    mutating func add(_ frame: CGImage) -> Result {
        guard let signature = Self.signature(frame) else { return .unchanged }
        guard let previous, frame.height == rows else {
            if chunks.isEmpty {
                chunks = [frame]
                height = frame.height
            }
            self.previous = signature
            rows = frame.height
            return .first
        }
        guard let shift = Self.shift(previous: previous, current: signature, rows: rows) else { return .lost }
        // Прокрутка вверх или без движения — ждём, пока снова пойдут новые строки.
        guard shift > 0 else { return .unchanged }
        let piece = min(shift, Self.maxHeight - height)
        guard piece > 0,
              let cropped = frame.cropping(to: CGRect(x: 0, y: frame.height - piece,
                                                      width: frame.width, height: piece)) else { return .unchanged }
        chunks.append(cropped)
        height += piece
        self.previous = signature
        return .appended
    }

    func makeImage() -> CGImage? {
        guard let first = chunks.first, height > 0 else { return nil }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = first.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: sRGB, bitmapInfo: info) else { return nil }
        var top = 0
        for chunk in chunks {
            context.draw(chunk, in: CGRect(x: 0, y: height - top - chunk.height,
                                           width: chunk.width, height: chunk.height))
            top += chunk.height
        }
        return context.makeImage()
    }

    /// Кадр, сжатый до 64 колонок (строки сохранены), в оттенках серого.
    /// Первая строка буфера — верх изображения.
    private static func signature(_ image: CGImage) -> [UInt8]? {
        let width = columns, height = image.height
        guard height > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: width * height)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    /// На сколько строк содержимое уехало вверх (> 0 — прокрутка вниз).
    /// nil — совпадение не найдено (слишком быстрая прокрутка или пустая полоса).
    private static func shift(previous: [UInt8], current: [UInt8], rows h: Int) -> Int? {
        let w = columns
        let band = min(48, h / 4)
        guard band >= 8 else { return nil }

        // Полоса с текстурой, ближе к верху (так ловятся большие сдвиги),
        // но ниже возможной закреплённой шапки.
        var start: Int?
        for fraction in [0.15, 0.3, 0.45] {
            let a = min(max(0, Int(Double(h) * fraction)), h - band)
            if variance(current, from: a * w, count: band * w) > 25 {
                start = a
                break
            }
        }
        guard let a = start else { return nil }

        let count = band * w
        var bestOffset: Int?
        var bestDiff = Int.max
        var d = 0
        while d <= h {
            let candidates = d == 0 ? [a] : [a + d, a - d]
            for m in candidates where m >= 0 && m <= h - band {
                // Дальний сдвиг выигрывает, только если заметно лучше ближнего.
                let limit = bestDiff == Int.max ? Int.max : bestDiff * 9 / 10
                var diff = 0
                var k = 0
                let base = m * w, ours = a * w
                while k < count {
                    diff += abs(Int(previous[base + k]) - Int(current[ours + k]))
                    if diff >= limit { break }
                    k += 1
                }
                if diff < limit {
                    bestDiff = diff
                    bestOffset = m
                }
            }
            if a - d < 0 && a + d > h - band { break }
            d += 1
        }
        guard let m = bestOffset, bestDiff <= count * 6 else { return nil }
        return m - a
    }

    private static func variance(_ data: [UInt8], from start: Int, count: Int) -> Double {
        guard count > 0, start + count <= data.count else { return 0 }
        var sum = 0.0, sumSquares = 0.0
        for i in start..<(start + count) {
            let v = Double(data[i])
            sum += v
            sumSquares += v * v
        }
        let mean = sum / Double(count)
        return sumSquares / Double(count) - mean * mean
    }
}
