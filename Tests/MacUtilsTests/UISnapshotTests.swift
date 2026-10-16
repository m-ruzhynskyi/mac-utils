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
/// - окно настроек (стартовый раздел «Общие» и по одному разделу из каждой группы боковой панели — без пропущенных),
///   «Что нового», витрина компонентов дизайн-системы (`components-gallery-*`).
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
            // По частям: одно длинное выражение компилятор CI не успевает вывести.
            var lines: [String] = ["# Снято", ""]
            lines += taken.map { "- \($0)" }
            lines += ["", "# Пропущено / проблемы", ""]
            lines += Self.skippedSections.map { (key: SettingsSection, value: String) -> String in "- \(key.rawValue): \(value)" }
            lines.append("- share-request: queue.add выводит настоящую панель на экран")
            lines.append("- toast: ToastView private в Core/Toast.swift")
            lines.append("- first-run: у первого запуска нет отдельного представления (только план FirstRun.plan)")
            lines += failures.map { "- \($0)" }
            let text: String = lines.joined(separator: "\n")
            try? text.write(to: directory.appendingPathComponent("INDEX.md"), atomically: true, encoding: String.Encoding.utf8)
        }
    }

    // MARK: рендер

    private func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool, settle: TimeInterval = 0.3) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        // Окно снимка не становится ключевым: без `.key` контролы рисуются «не в фокусе».
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
        bothThemes("settings-window", size: DS.Size.settingsWindow, settle: 0.6) { SettingsView() }
    }

    /// Окно с выбранным разделом в каждой группе боковой панели (кроме «Основного» — оно в `settings-window`).
    /// Разделы — без сети и личных данных.
    func testSettingsWindowPerGroup() {
        let shown: [(SettingsGroup, SettingsSection)] = [(.capture, .qr), (.windowsInput, .switcher), (.filesSystem, .shelf), (.more, .wellbeing)]
        for (group, section) in shown {
            XCTAssertNil(Self.skippedSections[section], "\(section) пропускается — снимать нельзя")
            XCTAssertEqual(section.group, group)
            bothThemes("settings-window-\(group.rawValue)", size: DS.Size.settingsWindow, settle: 0.6) { SettingsView(selection: section) }
        }
    }

    /// Витрина компонентов Graphite: сверка с концептом (`.audit/concept/Settings*.dc.html`, `Popover*`, `Onboarding*`).
    func testComponentsGallery() {
        bothThemes("components-gallery-settings", size: NSSize(width: 790, height: 2100), settle: 0.8) { ComponentsGallery(part: .settings) }
        bothThemes("components-gallery-surfaces", size: NSSize(width: 1000, height: 1300), settle: 0.8) { ComponentsGallery(part: .surfaces) }
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

    /// Группа «Файлы и система»: страницы-инструменты на демонстрационных моделях (система и личные данные не читаются).
    func testFilesAndSystemToolsDemo() {
        let apps = ["Demo Browser", "Demo Editor", "Demo Notes", "Demo Player"].map {
            InstalledApp(demoName: $0, bundleID: "com.example.\($0.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
        let selected = apps[1]
        let base = URL(fileURLWithPath: "/demo/Library")
        let leftovers = [
            Leftover(url: selected.url, group: "Приложение", kind: .app, shared: false, needsAdmin: false, sizeUnknown: false),
            Leftover(url: base.appendingPathComponent("Application Support/Demo Editor"), group: "Данные", kind: .file, shared: false, needsAdmin: false, sizeUnknown: false),
            Leftover(url: base.appendingPathComponent("Caches/com.example.demo-editor"), group: "Данные", kind: .file, shared: false, needsAdmin: false, sizeUnknown: false),
            Leftover(url: base.appendingPathComponent("Preferences/com.example.demo-editor.plist"), group: "Настройки", kind: .file, shared: true, needsAdmin: false, sizeUnknown: false),
        ]
        let sizes = Dictionary(uniqueKeysWithValues: leftovers.enumerated().map { ($1.url, Int64(($0 + 1) * 40 << 20)) })
        let appSizes = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1.url, Int64(($0 + 2) * 90 << 20)) })
        let withDetails = UninstallerModel.demo(apps: apps, appSizes: appSizes, selected: selected, leftovers: leftovers, sizes: sizes)
        let listOnly = UninstallerModel.demo(apps: apps, appSizes: appSizes, selected: nil, leftovers: [], sizes: [:])
        bothThemes("files-uninstaller-demo", size: NSSize(width: 760, height: 620)) { UninstallerPage(compact: false, model: withDetails) }
        bothThemes("files-uninstaller-demo-empty", size: NSSize(width: 760, height: 620)) { UninstallerPage(compact: false, model: listOnly) }
        bothThemes("files-uninstaller-demo-panel", size: NSSize(width: 420, height: 520)) { UninstallerPage(compact: true, model: listOnly) }
        bothThemes("files-uninstaller-demo-panel-details", size: NSSize(width: 420, height: 520)) { UninstallerPage(compact: true, model: withDetails) }

        let cleanup = DiskCleanupModel.demo()
        bothThemes("files-cleanup-demo", size: NSSize(width: 760, height: 620)) { DiskCleanupView(model: cleanup) }
        bothThemes("files-cleanup-demo-panel", size: NSSize(width: 420, height: 520)) { DiskCleanupView(model: cleanup, compact: true) }

        let tasks = TaskManagerModel.demo()
        bothThemes("files-tasks-demo", size: NSSize(width: 760, height: 620)) { TaskManagerView(model: tasks) }
        bothThemes("files-tasks-demo-panel", size: NSSize(width: 420, height: 520)) { TaskManagerView(model: tasks, compact: true) }

        let monitor = SystemMonitorModel.demo()
        bothThemes("files-monitor-demo", size: NSSize(width: 760, height: 620)) { SystemMonitorView(model: monitor) }
        bothThemes("files-monitor-demo-panel", size: NSSize(width: 420, height: 520)) { SystemMonitorView(model: monitor, compact: true) }
    }

    func testWhatsNew() {
        bothThemes("whats-new", size: NSSize(width: 520, height: 560)) { WhatsNewView() }
    }
}
