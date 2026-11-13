import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCopilot
import MUCore
import MUDesign

/// Снимки подсказчика (страница и панель) на заглушке ИИ. Только с `MU_SNAPSHOTS=<папка>`.
@MainActor
final class CopilotSnapshotTests: XCTestCase {
    private var directory: URL!
    private var suite: UserDefaults!
    private let suiteName = "mac-utils.ui-snapshots-copilot"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_SNAPSHOTS"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_SNAPSHOTS=<папка>, чтобы снять интерфейс")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        _ = NSApplication.shared
    }

    override func tearDown() { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

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

    private func both<V: View>(_ name: String, size: NSSize, _ view: () -> V) throws {
        for dark in [false, true] { try render(view(), size: size, name: name, dark: dark) }
    }

    private struct DemoAI: CopilotAIClient {
        func stream(prompt: String, system: String, images: [Data]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { c in
                c.yield("Начну с плана запроса, потом индекс и предагрегация.\n- EXPLAIN ANALYZE: где полный проход по таблице\n- Составной индекс (created_at, status)\n- Ежедневная сводная таблица вместо подсчёта на лету")
                c.finish()
            }
        }
    }

    @MainActor private final class DemoListener: CopilotListening {
        var onFailure: (@MainActor (String) -> Void)?
        func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {}
        func stop() {}
    }

    func testSnapshots() async throws {
        let session = CopilotSession(ai: DemoAI(), listener: DemoListener(), settings: { CopilotSettings() }, log: { _ in })
        session.start()
        try both("copilot-strip", size: NSSize(width: 560, height: 40)) { CopilotPanelView(session: session, placement: .underCamera).padding(6) }
        session.feed(Utterance(.other, "У нас таблица заказов на 40 миллионов строк. Как бы вы ускорили этот отчёт?"))
        try await Task.sleep(nanoseconds: 300_000_000)
        try both("copilot-expanded", size: NSSize(width: 560, height: 170)) { CopilotPanelView(session: session, placement: .underCamera).padding(6) }
        try both("copilot-side", size: NSSize(width: 320, height: 240)) { CopilotPanelView(session: session, placement: .side).padding(6) }
        try both("copilot-page", size: NSSize(width: 760, height: 1300)) { CopilotPage() }
    }
}
