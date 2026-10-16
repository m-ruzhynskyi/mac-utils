import AppKit
import SwiftUI
import XCTest
@testable import MacUtils

/// Снимки интерфейса в PNG, чтобы дизайн можно было посмотреть без запуска приложения.
/// Работает только с `MU_SNAPSHOTS=<папка>`; без неё тест пропускается.
///   MU_SNAPSHOTS=$PWD/.audit/snapshots/before swift test --filter UISnapshotTests
/// Окна создаются за пределами экрана, не активируются и не показываются на настоящем экране.
/// Настройки пользователя не пишутся: SwiftUI-представления получают отдельный UserDefaults suite (`defaultAppStorage`).
///
/// ЛИЧНЫЕ ДАННЫЕ. Страницы с моделью `.shared` читают данные этого Mac и рисовали бы их в PNG, поэтому такие разделы
/// пропущены (список и причины — `skippedSections`):
/// shots, cleanup, uninstaller, tasks, volume, meetings, windows — а также share, ai, music (сеть/внешние службы).
/// Снимается:
/// - все остальные разделы настроек и вкладки панели 🔧 (читают только настройки suite/раннера и состояние разрешений);
/// - «Мои снимки» (`shots-demo`) — на `ScreenshotLibrary(records:)` с демонстрационными записями, файлов пользователя нет;
/// - окно настроек (стартовый раздел «Общие»), «Что нового».
/// Не снимаются: очередь запросов share (`ShareRequestQueueView` рисуется только через `queue.add`, который выводит
/// настоящую панель на экран), Toast (private), первый запуск (нет представления).
@MainActor
final class UISnapshotTests: XCTestCase {
    private static let skippedSections: [SettingsSection: String] = [
        .share: "при появлении проверяет relay по сети (probeRelay)",
        .ai: "при появлении опрашивает локальную Ollama (HTTP)",
        .music: "подключается к системному плееру (MediaRemote)",
        .shots: "показывает личные снимки пользователя (ScreenshotLibrary.shared); вместо этого есть shots-demo",
        .cleanup: "сканирует ~/Downloads, ~/.Trash и кэши (возможен запрос TCC)",
        .uninstaller: "показывает установленные программы этого Mac (модель .shared не подменить без правки логики)",
        .tasks: "показывает процессы этого Mac",
        .volume: "показывает запущенные программы и системный звук",
        .meetings: "читает папку записей встреч и модели Whisper",
        .windows: "показывает сохранённые раскладки окон пользователя",
    ]

    private var directory: URL!
    private var suite: UserDefaults!
    private let suiteName = "mac-utils.ui-snapshots"
    private var taken: [String] = []
    private var failures: [String] = []

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

    override func tearDown() {
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        if directory != nil {
            let lines = ["# Снято", ""] + taken.map { "- \($0)" } + ["", "# Пропущено / проблемы", ""]
                + Self.skippedSections.map { "- \($0.key.rawValue): \($0.value)" }
                + ["- share-request: queue.add выводит настоящую панель на экран", "- toast: ToastView private в Core/Toast.swift", "- first-run: у первого запуска нет отдельного представления (только план FirstRun.plan)"]
                + failures.map { "- \($0)" }
            try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("INDEX.md"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: рендер

    private func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool, settle: TimeInterval = 0.3) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).defaultAppStorage(suite))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()

        defer {
            window.contentView = nil
            window.close()
        }
        guard let cache = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            failures.append("\(name): нет bitmap"); return
        }
        host.cacheDisplay(in: host.bounds, to: cache)

        // Прозрачные места SwiftUI заливаем фоном окна в нужной теме.
        guard let final = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cache.pixelsWide, pixelsHigh: cache.pixelsHigh,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: final) else {
            failures.append("\(name): нет контекста"); return
        }
        let rect = NSRect(x: 0, y: 0, width: CGFloat(cache.pixelsWide), height: CGFloat(cache.pixelsHigh))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
        }
        cache.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = final.representation(using: .png, properties: [:]), png.count > 500 else {
            failures.append("\(name): PNG пустой"); return
        }
        let file = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        do { try png.write(to: file) } catch { failures.append("\(name): \(error.localizedDescription)"); return }
        if Self.isUniform(final), settle < 1 {
            // Ленивые контейнеры (LazyVGrid) иногда не успевают построиться — повторяем с большей паузой.
            render(view, size: size, name: name, dark: dark, settle: 1.5)
            return
        }
        if Self.isUniform(final) { failures.append("\(name)-\(dark ? "dark" : "light"): все пиксели одного цвета") }
        taken.append(file.lastPathComponent)
    }

    private static func isUniform(_ rep: NSBitmapImageRep) -> Bool {
        guard let data = rep.bitmapData else { return true }
        let bytesPerPixel = rep.bitsPerPixel / 8
        let first = Array(UnsafeBufferPointer(start: data, count: bytesPerPixel))
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                let p = row + x * bytesPerPixel
                for i in 0..<bytesPerPixel where p[i] != first[i] { return false }
            }
        }
        return true
    }

    private func bothThemes<V: View>(_ name: String, size: NSSize, settle: TimeInterval = 0.3, _ view: () -> V) {
        for dark in [false, true] { render(view(), size: size, name: name, dark: dark, settle: settle) }
    }

    // MARK: снимки

    func testSettingsPages() {
        for section in SettingsSection.allCases where Self.skippedSections[section] == nil {
            bothThemes("settings-\(section.rawValue)", size: NSSize(width: 760, height: 620)) {
                SettingsSectionPage(section: section)
            }
        }
    }

    func testSettingsWindowWithSidebar() {
        // Окно настроек целиком — только стартовый раздел «Общие»: переключение разделов в боковой панели требует кликов.
        bothThemes("settings-window", size: NSSize(width: 980, height: 620), settle: 0.6) { SettingsView() }
    }

    func testMenuBarPanelTabs() {
        for section in PanelTabs.available where Self.skippedSections[section] == nil {
            suite.set(section.rawValue, forKey: Pref.toolsTab)
            suite.set(PanelTabs.value([section] + PanelTabs.sections(PanelTabs.defaultValue).filter { $0 != section && Self.skippedSections[$0] == nil }),
                      forKey: Pref.toolsPanelTabs)
            bothThemes("panel-\(section.rawValue)", size: NSSize(width: 420, height: 520)) {
                ToolsView(inPopover: true).frame(width: 420, height: 520)
            }
        }
    }

    func testShotsLibraryWithDemoRecords() {
        let now = Date()
        let demo = ["Safari", "Xcode", "Terminal", "Figma", "Notes", "Mail"].enumerated().map { index, app in
            ShotRecord(path: "/nonexistent/demo/Демо-снимок-\(index + 1).png",
                       date: now.addingTimeInterval(-Double(index) * 3_600), app: app, text: "Демонстрационная запись \(index + 1)")
        }
        let library = ScreenshotLibrary(records: demo)
        bothThemes("shots-demo", size: NSSize(width: 760, height: 620)) { ScreenshotLibraryView(library: library) }
        bothThemes("shots-demo-panel", size: NSSize(width: 420, height: 520)) { ScreenshotLibraryView(library: library, compact: true) }
    }

    func testWhatsNew() {
        bothThemes("whats-new", size: NSSize(width: 520, height: 560)) { WhatsNewView() }
    }
}
