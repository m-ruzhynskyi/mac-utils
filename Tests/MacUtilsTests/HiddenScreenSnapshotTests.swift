import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
import MUDesign
@testable import MUHiddenScreen

/// Снимки «Скрытого экрана» (страница, меню, полоска зеркала) с заглушкой вместо движка. Только с `MU_SNAPSHOTS=<папка>`.
@MainActor
final class HiddenScreenSnapshotTests: XCTestCase {
    private var directory: URL!
    private var suite: UserDefaults!
    private let suiteName = "mac-utils.ui-snapshots-hidden-screen"

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

    func testSnapshots() throws {
        let checks = PreCallRules.all(dockAutohide: true, notifications: .on(apps: ["Claude", "ChatGPT"]),
                                      output: .builtInSpeakers, mainDisplayName: "Встроенный дисплей")
        try both("hs-page", size: NSSize(width: 760, height: 980)) {
            HiddenScreenPage(controller: StubHiddenScreenController(.demo), checks: checks)
        }
        try both("hs-page-off", size: NSSize(width: 760, height: 980)) {
            HiddenScreenPage(controller: StubHiddenScreenController(HiddenScreenState(apps: HiddenScreenState.demo.apps.map { HiddenScreenApp(bundleID: $0.bundleID, name: $0.name) })),
                             checks: PreCallRules.all(dockAutohide: true, notifications: .off(apps: []), output: .external, mainDisplayName: "Встроенный дисплей"))
        }
        for (name, verified) in [("ok", true as Bool?), ("visible", false), ("unchecked", nil)] {
            var state = HiddenScreenState.demo
            state.hidingVerified = verified
            try both("hs-strip-\(name)", size: NSSize(width: 520, height: 30)) {
                MirrorStripView(store: HiddenScreenStore(StubHiddenScreenController(state)))
            }
        }
        try both("hs-menu", size: NSSize(width: 300, height: 250)) { MenuPreview(state: .demo) }
    }
}

/// Макет меню для снимка: те же записи, что собирает `HiddenScreenMenuBuilder` (сам NSMenu офскрин не рисуется).
private struct MenuPreview: View {
    let state: HiddenScreenState
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(HiddenScreenRules.menu(state, toggleKey: "⌥⇧H", windowKey: "⌥Space").enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .separator: Divider().padding(.vertical, 3)
                case .header(let t): Text(t.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                case .toggle(let t, let on, let key): line(t, check: on, key: key)
                case .showWindow(let t, let key, _): line(t, check: false, key: key)
                case .app(_, let name, let on): line(name, check: on, key: nil).padding(.leading, 12)
                case .addApp: line("Добавить программу…", check: false, key: nil).padding(.leading, 12)
                case .returnAll: line("Вернуть все окна на экран", check: false, key: nil)
                }
            }
        }
        .padding(10)
    }
    private func line(_ t: String, check: Bool, key: String?) -> some View {
        HStack { Text(check ? "✓" : " ").frame(width: 14); Text(t); Spacer(); if let key { Text(key).foregroundStyle(.secondary) } }
            .font(.system(size: 13))
    }
}
