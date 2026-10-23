import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore

/// Снимки демо-вариантов страниц волны 1 (исполнитель В): трансляция, ИИ, музыка, записи встреч — без сети,
/// личного ID, истории и записей этого Mac. Работает только с `MU_SNAPSHOTS=<папка>`.
@MainActor
final class UISnapshotsGraphiteW1VTests: XCTestCase {
    private var directory: URL!
    private var suite: UserDefaults!
    private let suiteName = "mac-utils.ui-snapshots-w1v"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_SNAPSHOTS"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_SNAPSHOTS=<папка>, чтобы снять интерфейс")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.set("https://relay.example", forKey: Pref.shareServer)
        _ = NSApplication.shared
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).defaultAppStorage(suite)
            .environment(\.controlActiveState, .key))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        let cache = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: cache)
        let final = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cache.pixelsWide, pixelsHigh: cache.pixelsHigh,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: final))
        let rect = NSRect(x: 0, y: 0, width: CGFloat(cache.pixelsWide), height: CGFloat(cache.pixelsHigh))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
        }
        cache.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(final.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 500)
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    private func both<V: View>(_ name: String, size: NSSize = NSSize(width: 760, height: 620), _ view: () -> V) throws {
        for dark in [false, true] { try render(view(), size: size, name: name, dark: dark) }
    }

    func testDemoPages() throws {
        try both("settings-share-demo", size: NSSize(width: 760, height: 1500)) { ScreenSharePage(demo: true) }
        try both("settings-ai-demo", size: NSSize(width: 760, height: 1000)) { AIPage(demo: true) }
        try both("settings-music-demo") { NowPlayingView(demo: true) }
        try both("settings-meetings-demo", size: NSSize(width: 760, height: 900)) { MeetingsPage(demo: true) }
    }

    /// Страницы целиком (высокий кадр), чтобы увидеть всю прокрутку.
    func testFullPages() throws {
        try both("settings-screenshot-full", size: NSSize(width: 760, height: 3600)) { SettingsSectionPage(section: .screenshot) }
        try both("settings-wellbeing-full", size: NSSize(width: 760, height: 1100)) { SettingsSectionPage(section: .wellbeing) }
    }

    func testCompactPanels() throws {
        try both("panel-share-demo", size: NSSize(width: 420, height: 900)) { ScreenSharePage(compact: true, demo: true) }
        try both("panel-music-demo", size: NSSize(width: 420, height: 520)) { NowPlayingView(compact: true, demo: true) }
    }
}
