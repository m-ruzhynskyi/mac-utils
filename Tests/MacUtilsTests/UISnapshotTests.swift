import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUCutPaste
@testable import MUAppSwitcher
@testable import MUUninstaller
@testable import MUWellbeing
@testable import MUMeetings
@testable import MUQR
@testable import MUAudio
@testable import MUDropShelf
@testable import MUCheatSheet

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

    /// 1.6.6: «Не засыпать» — выключено и включено (демо: осталось 2 ч 15 мин), в узкой и обычной ширине.
    func testKeepAwakeRow() {
        for width in [DS.Size.popover.width, 420] {
            bothThemes("keep-awake-\(Int(width))", size: NSSize(width: width, height: 260), settle: 0.4) {
                VStack(spacing: DS.Space.m) {
                    ListCard { KeepAwakeRow() }
                    ListCard { KeepAwakeRow(demoRemaining: 2 * 3_600 + 15 * 60) }
                    Text(KeepAwakeRow.note).font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.l)
                .frame(width: width, height: 260, alignment: .top)
                .background(Color.dsPanel)
            }
        }
    }

    /// Панель в строке меню (концепт `Popover*.dc.html`): вкладки разделов, размер — как у поповера.
    func testMenuBarPanelTabs() {
        let size = NSSize(width: DS.Size.popover.width, height: DS.Size.popover.height)
        let others = PanelTabs.sections(PanelTabs.defaultValue).filter { Self.skippedSections[$0] == nil }
        // Сохранённая «Главная» (1.6.6 её убрала) → первая вкладка; ряд показательный: разделы по умолчанию
        // в основном личные и в снимках пропускаются.
        suite.set("home", forKey: Pref.toolsTab)
        suite.set(PanelTabs.value([.screenshot, .shelf, .qr, .annotate, .wellbeing, .monitor]), forKey: Pref.toolsPanelTabs)
        bothThemes("panel-from-home", size: size, settle: 0.6) { ToolsView(inPopover: true).frame(width: size.width, height: size.height) }
        for section in PanelTabs.available where Self.skippedSections[section] == nil {
            suite.set(section.rawValue, forKey: Pref.toolsTab)
            suite.set(PanelTabs.value([section] + others.filter { $0 != section }), forKey: Pref.toolsPanelTabs)
            bothThemes("panel-\(section.rawValue)", size: size) {
                ToolsView(inPopover: true).frame(width: size.width, height: size.height)
            }
        }
    }

    /// 1.6.1: вкладка «Трансляция» в поповере (в том числе узком, 420) и в окне «Инструменты» — демо без сети и личного ID.
    func testShareTabDemo() {
        suite.set(SettingsSection.share.rawValue, forKey: Pref.toolsTab)
        suite.set(PanelTabs.value([.share, .screenshot, .monitor]), forKey: Pref.toolsPanelTabs)
        for width in [DS.Size.popover.width, 420] {
            let size = NSSize(width: width, height: DS.Size.popover.height)
            bothThemes("panel-share-demo-\(Int(width))", size: size, settle: 0.6) {
                ToolsView(inPopover: true).frame(width: size.width, height: size.height).environment(\.uiDemo, true)
            }
        }
        // Вся вкладка целиком в узкой панели: история, звук, ссылка для Windows, сервер.
        bothThemes("panel-share-demo-420-full", size: NSSize(width: 420, height: 1700), settle: 0.6) {
            ScreenSharePage(compact: true, demo: true).padding(.horizontal, 6)
        }
        bothThemes("tools-window-share-demo", size: NSSize(width: 1000, height: 660), settle: 0.6) {
            ToolsView().environment(\.uiDemo, true)
        }
    }

    /// 1.6.1: окно «Инструменты» — ряд вкладок без «Главной» и без кнопок шапки; сохранённая «Главная» → первая вкладка;
    /// минимальный размер окна — содержимое вписывается.
    func testToolsWindow() {
        suite.set(PanelTabs.value([.screenshot, .shelf, .qr, .wellbeing, .monitor]), forKey: Pref.toolsPanelTabs)
        suite.set("home", forKey: Pref.toolsTab)
        bothThemes("tools-window-from-home", size: NSSize(width: 1000, height: 660), settle: 0.6) { ToolsView() }
        for section in [SettingsSection.shelf, .qr, .wellbeing, .monitor] {
            suite.set(section.rawValue, forKey: Pref.toolsTab)
            bothThemes("tools-window-\(section.rawValue)", size: NSSize(width: 1000, height: 660), settle: 0.6) { ToolsView() }
        }
        suite.set(SettingsSection.screenshot.rawValue, forKey: Pref.toolsTab)
        bothThemes("tools-window-min-screenshot", size: NSSize(width: 760, height: 520), settle: 0.6) { ToolsView() }
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

    /// Волна 2, исполнитель Ж: Capture, Switcher, первый запуск, обновление и «Что нового», QR, полка, вырезание, шпаргалка.
    /// Только готовые значения (без моделей, без системы, без личных данных); окон на экране нет.
    func testCaptureSwitcherOnboardingUpdateOverlays() {
        // Capture: рамка выделения, плашка размера и панель инструментов поверх «снимка» (условный фон).
        bothThemes("capture-selection", size: NSSize(width: 1100, height: 560)) { CapturePreview() }

        // Switcher: четыре карточки, первая выбрана.
        let names = ["Safari", "Xcode", "Finder", "Telegram"]
        let symbols = ["safari", "hammer", "folder", "paperplane"]
        let items = names.enumerated().map { index, name in
            SwitcherItem(id: "demo-\(index)", app: NSRunningApplication.current, appName: name, title: name,
                         icon: NSImage(systemSymbolName: symbols[index], accessibilityDescription: name) ?? NSImage(),
                         windowID: CGWindowID(900 + index), axWindow: nil, isMinimized: false)
        }
        let previews = Dictionary(uniqueKeysWithValues: items.enumerated().map { index, item in
            (item.windowID!, Self.gradientImage(hue: CGFloat(index) / 5 + 0.55, size: NSSize(width: 260, height: 160)))
        })
        bothThemes("switcher-main", size: NSSize(width: 960, height: 280)) {
            SwitcherContent(items: items, selected: 0, previews: previews, showPreviews: true, maxWidth: 940)
        }
        bothThemes("switcher-icons", size: NSSize(width: 520, height: 180)) {
            SwitcherContent(items: items, selected: 1, previews: [:], showPreviews: false, maxWidth: 500)
        }

        // Первый запуск: три шага.
        bothThemes("onboarding-1-welcome", size: NSSize(width: 960, height: 600)) {
            OnboardingContent(step: .welcome, accessibility: .needed, screenRecording: .needed, microphone: .needed)
        }
        bothThemes("onboarding-2-permissions", size: NSSize(width: 960, height: 600)) {
            OnboardingContent(step: .permissions, accessibility: .granted, screenRecording: .needed, microphone: .needed)
        }
        bothThemes("onboarding-3-done", size: NSSize(width: 960, height: 600)) {
            OnboardingContent(step: .done, accessibility: .granted, screenRecording: .granted, microphone: .needed)
        }

        // Обновление и «Что нового».
        let releases = Array(Changelog.releases.prefix(2))
        let family = releases.first?.version ?? ""
        bothThemes("update-available", size: NSSize(width: 520, height: 640)) {
            WhatsNewContent(state: .available("9.9.9"), currentVersion: family, displayVersion: "9.9.0", releases: releases)
        }
        bothThemes("update-installing", size: NSSize(width: 520, height: 640)) {
            WhatsNewContent(state: .installing("9.9.9"), currentVersion: family, displayVersion: "9.9.0", releases: releases)
        }
        bothThemes("whats-new-list", size: NSSize(width: 520, height: 640)) {
            WhatsNewContent(state: .upToDate, currentVersion: family, displayVersion: "9.9.0", releases: releases)
        }

        // Плавающие панели.
        bothThemes("qr-panel", size: NSSize(width: 340, height: 420)) {
            QRPanelContent(image: Self.demoQR(), text: "https://example.com/demo-link")
        }
        let files = ["Отчёт.pdf", "Схема.png", "Заметки.txt", "Архив.zip"].map { URL(fileURLWithPath: "/demo/\($0)") }
        let shelf = DropShelf.demo(items: files)
        bothThemes("shelf-full", size: NSSize(width: 280, height: 340)) { DropShelfView(shelf: shelf) }
        let empty = DropShelf.demo(items: [])
        bothThemes("shelf-empty", size: NSSize(width: 280, height: 340)) { DropShelfView(shelf: empty) }
        bothThemes("cut-panel", size: NSSize(width: 340, height: 220)) { CutPanelContent(items: files) }
        let groups = [
            CheatGroup(title: "Файл", items: [CheatItem(title: "Новое окно", shortcut: "⌘N"), CheatItem(title: "Открыть…", shortcut: "⌘O"),
                                              CheatItem(title: "Закрыть окно", shortcut: "⌘W")]),
            CheatGroup(title: "Правка", items: [CheatItem(title: "Отменить", shortcut: "⌘Z"), CheatItem(title: "Повторить", shortcut: "⇧⌘Z"),
                                                CheatItem(title: "Найти…", shortcut: "⌘F")]),
            CheatGroup(title: "Mac Utils", items: [CheatItem(title: "Снимок экрана", shortcut: "⌃⌥⌘X"), CheatItem(title: "Полка", shortcut: "⌃⌥D")]),
        ]
        bothThemes("cheatsheet-overlay", size: NSSize(width: 820, height: 340)) {
            CheatSheetContent(appName: "Demo Editor", appIcon: nil, loading: false, groups: groups, sticky: false)
        }
    }

    private static func gradientImage(hue: CGFloat, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 0.55, alpha: 1),
                       ending: NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 0.25, alpha: 1))?
                .draw(in: rect, angle: 160)
            return true
        }
    }

    private static func demoQR() -> NSImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data("https://example.com/demo-link".utf8), forKey: "inputMessage")
        let ci = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: ci)
        let image = NSImage(size: NSSize(width: rep.size.width + 32, height: rep.size.height + 32), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            rep.draw(in: NSRect(x: 16, y: 16, width: rep.size.width, height: rep.size.height))
            return true
        }
        return image
    }

    func testWhatsNew() {
        bothThemes("whats-new", size: NSSize(width: 520, height: 560)) { WhatsNewView() }
    }

    // MARK: Волна 2, исполнитель Е: Toast, статусные HUD, запрос зрителя, ведущий и зритель трансляции
    // Все вью получают готовые значения (без живых моделей), окна не выводятся на экран, личных данных нет.

    /// Рабочий стол из `MacHost.dc.html` / `MacWatch.dc.html`: градиент и условные окна.
    private struct DesktopBackdrop: View {
        var body: some View {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.17, green: 0.19, blue: 0.25), Color(red: 0.09, green: 0.10, blue: 0.13),
                                        Color(red: 0.11, green: 0.16, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.34, green: 0.38, blue: 0.47)).frame(width: 360, height: 14).offset(x: 50, y: 70)
                RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.26, green: 0.29, blue: 0.38)).frame(width: 460, height: 10).offset(x: 50, y: 98)
                RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.17, green: 0.2, blue: 0.27)).frame(width: 420, height: 250).offset(x: 50, y: 130)
                Circle().fill(Color.dsAcc).frame(width: 14, height: 14)
                    .shadow(color: Color.dsAcc.opacity(0.5), radius: 8).offset(x: 230, y: 220)
            }
        }
    }

    func testToastsAndHUDs() {
        let notes = ["Нет разрешения «Запись экрана»"]
        bothThemes("toast-cards", size: NSSize(width: 560, height: 470)) {
            VStack(alignment: .leading, spacing: 8) {
                ToastCard(text: "Скопировано", symbol: "doc.on.doc.fill", tint: .green, actionTitle: "Показать в Finder", action: {})
                ToastCard(text: "Не удалось начать запись: нет разрешения «Запись экрана»", symbol: "exclamationmark.triangle.fill", tint: .orange)
                ToastCard(text: "Исправляю…", symbol: "sparkles", tint: .purple, actionTitle: "Отмена", action: {})
                ToastCard(text: "Создаю GIF… 42 %", symbol: "photo.stack", tint: .purple)
                ToastCard(text: "Запись отменена", symbol: "xmark.circle.fill", tint: .secondary)
                ToastCard(text: "Ошибка сохранения", symbol: "xmark.octagon.fill", tint: .red)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.dsBg)
        }
        bothThemes("share-request-cards", size: NSSize(width: 900, height: 700)) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    ShareRequestCard(name: "Марко", viewer: "7312048815", fingerprint: nil,
                                     prompt: .init(kind: .legacy, allowAlways: true, notes: []), moreCount: 0) { _ in }
                    ShareRequestCard(name: "Анна", viewer: "6031184472", fingerprint: "65b6-0673-d6ed-884b",
                                     prompt: .init(kind: .confirmKey, allowAlways: true, notes: []), moreCount: 2) { _ in }
                }
                VStack(spacing: 16) {
                    ShareRequestCard(name: "Олег", viewer: "2187650931", fingerprint: "a1b2-c3d4-e5f6-0718",
                                     prompt: .init(kind: .legacy, allowAlways: false,
                                                   notes: ["ID не подтверждён: этот ID принадлежит другому ключу."]), moreCount: 1) { _ in }
                    ShareRequestCard(name: "", viewer: "", fingerprint: nil,
                                     prompt: .init(kind: .legacy, allowAlways: false, notes: []), moreCount: 0) { _ in }
                }
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.dsBg)
            .accessibilityLabel(notes.joined())
        }
        bothThemes("hud-recording-meeting-steps", size: NSSize(width: 640, height: 420)) {
            VStack(alignment: .leading, spacing: 12) {
                RecordingHUDContent(elapsed: 83, cancel: {}, stop: {})
                MeetingHUDContent(since: Date().addingTimeInterval(-754), interruption: nil, stalled: false, stop: {})
                MeetingHUDContent(since: Date().addingTimeInterval(-754), interruption: nil, stalled: true, stop: {})
                MeetingHUDContent(since: nil, interruption: "Запись прервана: устройство звука отключено", stalled: false, stop: {})
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.dsBg)
        }
        bothThemes("hud-share-pill", size: NSSize(width: 520, height: 230)) {
            VStack(alignment: .trailing, spacing: 12) {
                ShareHUDPill(code: "4829173056", viewers: 0, requests: 0, reconnecting: false, expanded: false,
                             copy: {}, showRequests: {}, changeSource: {}, stop: {})
                ShareHUDPill(code: "4829173056", viewers: 2, requests: 0, reconnecting: false, expanded: false,
                             copy: {}, showRequests: {}, changeSource: {}, stop: {})
                ShareHUDPill(code: "4829173056", viewers: 2, requests: 1, reconnecting: false, expanded: false,
                             copy: {}, showRequests: {}, changeSource: {}, stop: {})
                ShareHUDPill(code: "4829173056", viewers: 2, requests: 0, reconnecting: true, expanded: false,
                             copy: {}, showRequests: {}, changeSource: {}, stop: {})
                ShareHUDPill(code: "4829173056", viewers: 2, requests: 1, reconnecting: false, expanded: true,
                             copy: {}, showRequests: {}, changeSource: {}, stop: {})
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).background(Color.dsBg)
        }
    }

    /// Демо-«окно приложения» для коллажа: нарисованные блоки и подписи, никаких снимков экрана.
    private static func demoShot(_ title: String, width: Int, height: Int, hue: CGFloat, unit: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor(white: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: CGFloat(height) - 44 * unit, width: CGFloat(width), height: 44 * unit).fill()
        NSColor(white: 0.88, alpha: 1).setFill()
        for row in 0..<6 {
            NSRect(x: 24 * unit, y: CGFloat(height) - (84 + CGFloat(row) * 30) * unit, width: CGFloat(width) * 0.6, height: 12 * unit).fill()
        }
        NSColor(hue: hue, saturation: 0.7, brightness: 0.75, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: CGFloat(width) - 150 * unit, y: 24 * unit, width: 126 * unit, height: 36 * unit),
                     xRadius: 8 * unit, yRadius: 8 * unit).fill()
        NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 18 * unit), .foregroundColor: NSColor.white])
            .draw(at: NSPoint(x: 18 * unit, y: CGFloat(height) - 33 * unit))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private static var demoSteps: [StepShot] {
        // Разные размеры и плотности: третий шаг снят на обычном (не Retina) экране.
        [StepShot(image: demoShot("Демо: открыть меню", width: 960, height: 640, hue: 0.58, unit: 2), unit: 2, rect: nil,
                  caption: "Откройте меню «Файл»"),
         StepShot(image: demoShot("Демо: настройки", width: 720, height: 760, hue: 0.33, unit: 2), unit: 2, rect: nil,
                  caption: "Включите «Автосохранение»"),
         StepShot(image: demoShot("Демо: готово", width: 420, height: 300, hue: 0.08, unit: 1), unit: 1, rect: nil, caption: "")]
    }

    func testStepsCollageScenes() {
        let steps = Self.demoSteps
        let items = steps.map { StepsPanelItem(id: $0.id, thumbnail: $0.thumbnail) }
        bothThemes("steps-panel", size: NSSize(width: 820, height: 420)) {
            VStack(alignment: .leading, spacing: 12) {
                StepsPanelContent(items: items)
                StepsPanelContent(items: Array(items.prefix(2)), canUndo: true)
                StepsPanelContent(items: items, confirmingCancel: true)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.dsBg)
        }
        suite.set(StepsLayout.auto.rawValue, forKey: Pref.screenshotStepsLayout)
        suite.set(true, forKey: Pref.screenshotStepsEqualSize)
        suite.set(true, forKey: Pref.screenshotStepsFrame)
        suite.set(true, forKey: Pref.screenshotStepsTitles)
        suite.set(true, forKey: Pref.screenshotStepsBadges)
        suite.set(true, forKey: Pref.screenshotStepsArrows)
        suite.set(ShotBackground.sky.rawValue, forKey: Pref.screenshotBackground)
        let model = StepsPreviewModel(defaults: suite, steps: { steps })
        bothThemes("steps-preview", size: NSSize(width: 1040, height: 680), settle: 0.5) {
            StepsPreviewView(model: model)
        }
        model.layout = .vertical
        model.windowFrame = false
        bothThemes("steps-preview-vertical", size: NSSize(width: 1040, height: 680), settle: 0.5) {
            StepsPreviewView(model: model)
        }
    }

    func testMacHostAndWatchScenes() {
        // Ведущий: капсула эфира в углу и запрос зрителя снизу (как в MacHost.dc.html).
        bothThemes("mac-host-scene", size: NSSize(width: 1000, height: 620), settle: 0.5) {
            ZStack(alignment: .topTrailing) {
                DesktopBackdrop()
                ShareHUDPill(code: "4829173056", viewers: 2, requests: 1, reconnecting: false, expanded: true,
                             copy: {}, showRequests: {}, changeSource: {}, stop: {}).padding(20)
                VStack {
                    Spacer()
                    ShareRequestCard(name: "Марко", viewer: "7312048815", fingerprint: nil,
                                     prompt: .init(kind: .legacy, allowAlways: true, notes: []), moreCount: 0) { _ in }
                        .padding(.bottom, 26)
                }
                .frame(maxWidth: .infinity)
            }
        }
        // Зритель: значок эфира, панель инструментов и состояния (как в MacWatch.dc.html).
        bothThemes("mac-watch-scene", size: NSSize(width: 1000, height: 620), settle: 0.5) {
            ZStack(alignment: .bottom) {
                DesktopBackdrop()
                ShareViewerBadge(height: 1080).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                ShareViewerToolbar(tool: .constant(.draw), color: .constant("green"), playGame: {}).padding(26)
            }
        }
        bothThemes("mac-watch-status", size: NSSize(width: 760, height: 760)) {
            ZStack {
                Color.black
                VStack(spacing: 16) {
                    ViewerStatusCard(.progress("Подключаюсь…"))
                    ViewerStatusCard(.progress("Ждём, пока 603 118 4472 разрешит подключение…"))
                    ViewerStatusCard(.notice("Ведущий переподключается…"))
                    ViewerStatusCard(.reconnecting("Переподключаюсь… попытка 2", disconnect: {}))
                    ViewerStatusCard(.ended("Трансляция завершена", warning: "Ключ этого компьютера изменился.",
                                            accept: {}, dismiss: {}))
                }
            }
        }
    }
}

/// Условный экран с выделением, плашкой размера и панелью инструментов (как `Capture.dc.html`): рисуется кодом приложения.
private struct CapturePreview: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CapturePreviewView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

private final class CapturePreviewView: NSView {
    private let toolbar = CaptureToolbar()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        toolbar.setFrameOrigin(NSPoint(x: 40, y: 40))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.19, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)])?
            .draw(in: bounds, angle: -45)
        let selection = NSRect(x: 60, y: 180, width: 560, height: 330)
        NSColor(srgbRed: 0.22, green: 0.26, blue: 0.34, alpha: 1).setFill()
        selection.fill()
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: selection))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        let border = NSBezierPath(roundedRect: selection.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2)
        border.lineWidth = 2
        DS.Palette.acc.setStroke()
        border.stroke()
        for corner in [NSPoint(x: selection.minX, y: selection.minY), NSPoint(x: selection.maxX, y: selection.minY),
                       NSPoint(x: selection.minX, y: selection.maxY), NSPoint(x: selection.maxX, y: selection.maxY)] {
            let square = NSBezierPath(roundedRect: NSRect(x: corner.x - 4.5, y: corner.y - 4.5, width: 9, height: 9), xRadius: 3, yRadius: 3)
            DS.Palette.acc.setFill()
            square.fill()
        }
        CaptureView.drawSizeBadge(width: 1120, height: 660, selection: selection, canvas: bounds)
    }
}
