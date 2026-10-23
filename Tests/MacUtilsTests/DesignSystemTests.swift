import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign

/// Дизайн-система Graphite (волна 0 редизайна v2): группы боковой панели, контраст токенов в обеих темах, шрифты.
@MainActor
final class DesignSystemTests: XCTestCase {
    // MARK: - Группы и разделы

    func testEverySectionIsInExactlyOneGroup() {
        let all = SettingsGroup.allCases.flatMap(\.sections)
        XCTAssertEqual(all.count, Set(all).count, "раздел в двух группах")
        XCTAssertEqual(Set(all), Set(SettingsSection.allCases), "раздел без группы")
        for section in SettingsSection.allCases {
            XCTAssertTrue(section.group.sections.contains(section))
        }
    }

    /// Раздела «Команды и ссылки» больше нет: поиск «команды» ведёт на «Горячие клавиши».
    func testShortcutsSearchLandsOnHotKeys() {
        let hits = SettingsSection.allCases.filter { $0.searchText.lowercased().contains("команды") }
        XCTAssertTrue(hits.contains(.hotKeys))
    }

    /// Группы и порядок — как в концепте (`Settings.dc.html`).
    func testGroupsMatchConcept() {
        XCTAssertEqual(SettingsGroup.allCases.map(\.title), ["Основное", "Захват", "Окна и ввод", "Файлы и система", "Ещё"])
        XCTAssertEqual(SettingsGroup.general.sections.map(\.title),
                       ["Общие", "Горячие клавиши", "Исключённые программы", "Панель в строке меню"])
        XCTAssertEqual(SettingsGroup.capture.sections.map(\.title),
                       ["Снимки экрана", "Мои снимки", "Рисование на экране", "QR-коды", "Записи встреч"])
        XCTAssertEqual(SettingsGroup.windowsInput.sections.map(\.title),
                       ["Переключатель приложений", "Окна", "Громкость", "Раскладка", "Плавная прокрутка", "Вырезать и вставить", "Ввод текста"])
        XCTAssertEqual(SettingsGroup.filesSystem.sections.map(\.title),
                       ["Полка", "Загрузки", "Текстовый редактор", "Видеоплеер", "Шпаргалка", "Удаление программ", "Очистка диска", "Монитор системы", "Диспетчер задач"])
        XCTAssertEqual(SettingsGroup.more.sections.map(\.title),
                       ["Перерывы и тёплый экран", "Фокус", "Музыка", "Трансляция экрана", "ИИ (Ollama)"])
    }

    func testSymbolsExist() {
        for section in SettingsSection.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil), "нет символа \(section.symbol)")
        }
    }

    func testSubtitlesContainNoVersionNumbers() {
        SettingsSection.installAppSubtitles()
        let version = try! NSRegularExpression(pattern: #"\b\d+\.\d+(\.\d+)?\b"#)
        for section in SettingsSection.allCases {
            let text = section.subtitle
            XCTAssertNil(version.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), text)
        }
    }

    func testSearchCoversTitlesAndGroups() {
        for section in SettingsSection.allCases {
            XCTAssertTrue(section.searchText.contains(section.title))
            XCTAssertTrue(section.searchText.contains(section.panelTitle))
        }
        XCTAssertEqual(SettingsSearch.filter(SettingsSection.allCases, query: "файлы и система").filter { $0.group == .filesSystem }.count,
                       SettingsGroup.filesSystem.sections.count, "название группы тоже ищется")
        XCTAssertEqual(SettingsSearch.filter(SettingsSection.allCases, query: "ghbdtn"), [.layout])
    }

    func testDisplayOrderFollowsGroups() {
        XCTAssertEqual(SettingsSearch.displayOrder(SettingsSection.allCases), SettingsGroup.allCases.flatMap(\.sections))
        XCTAssertEqual(SettingsSearch.displayOrder([.ai, .general, .shots]), [.general, .shots, .ai])
    }

    // MARK: - Контраст (WCAG), обе темы

    private typealias P = DS.Palette

    private func ratio(_ a: NSColor, _ b: NSColor, dark: Bool) throws -> Double {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        return Self.contrast(Self.resolved(a, in: appearance), Self.resolved(b, in: appearance))
    }

    private func assertContrast(_ a: NSColor, on backgrounds: [NSColor], atLeast minimum: Double, _ what: String) throws {
        for dark in [false, true] {
            for (index, background) in backgrounds.enumerated() {
                let value = try ratio(a, background, dark: dark)
                XCTAssertGreaterThanOrEqual(value, minimum, "\(what), фон №\(index), \(dark ? "тёмная" : "светлая"): \(value)")
            }
        }
    }

    func testTextContrast() throws {
        try assertContrast(P.text, on: [P.bg, P.side, P.panel, P.field], atLeast: 7, "text")
        try assertContrast(P.mute, on: [P.bg, P.side, P.panel, P.field], atLeast: 4.5, "mute")
        try assertContrast(P.accText, on: [P.bg, P.side, P.panel, P.field], atLeast: 4.5, "accText")
    }

    func testInkOnFills() throws {
        try assertContrast(P.accInk, on: [P.acc], atLeast: 4.5, "accInk на acc")
        try assertContrast(P.recInk, on: [P.rec], atLeast: 4.5, "recInk на rec")
        try assertContrast(P.blueInk, on: [P.blue], atLeast: 4.5, "blueInk на blue")
        try assertContrast(P.warnInk, on: [P.warn], atLeast: 4.5, "warnInk на warn")
    }

    func testToneTextOnPanel() throws {
        for tone in DS.Tone.allCases {
            try assertContrast(tone.textColor, on: [P.panel], atLeast: 4.5, "текст тона \(tone)")
            try assertContrast(tone.inkColor, on: [tone.fillColor], atLeast: 4.5, "чернила тона \(tone)")
        }
    }

    /// Граница лаймовых элементов в светлой теме: `accLine` к белому ≥ 3:1 (WCAG 1.4.11); в тёмной лайм виден и сам.
    func testLimeBoundaries() throws {
        XCTAssertGreaterThanOrEqual(try ratio(P.accLine, P.panel, dark: false), 3)
        XCTAssertGreaterThanOrEqual(try ratio(P.accLine, P.bg, dark: false), 3)
        XCTAssertGreaterThanOrEqual(try ratio(P.acc, P.panel, dark: true), 3)
        XCTAssertLessThan(try ratio(P.acc, P.panel, dark: false), 3, "поэтому в светлой теме нужна обводка accLine")
        // Ручка выключенного переключателя различима на дорожке.
        try assertContrast(P.mute, on: [P.off], atLeast: 3, "ручка на off")
        try assertContrast(P.accInk, on: [P.acc], atLeast: 3, "ручка на acc")
    }

    func testThemesDiffer() throws {
        XCTAssertNotEqual(Self.luminance(Self.resolved(P.bg, in: try XCTUnwrap(NSAppearance(named: .aqua)))),
                          Self.luminance(Self.resolved(P.bg, in: try XCTUnwrap(NSAppearance(named: .darkAqua)))), accuracy: 0.2)
        XCTAssertTrue(DS.isDark(try XCTUnwrap(NSAppearance(named: .darkAqua))))
        XCTAssertFalse(DS.isDark(try XCTUnwrap(NSAppearance(named: .aqua))))
    }

    func testToneFromLegacyTint() {
        XCTAssertEqual(DS.Tone.from(tint: .green), .success)
        XCTAssertEqual(DS.Tone.from(tint: .orange), .warning)
        XCTAssertEqual(DS.Tone.from(tint: .red), .danger)
        XCTAssertEqual(DS.Tone.from(tint: .purple), .neutral)
    }

    // MARK: - Шрифты

    func testBundledFontsRegisterAndResolve() {
        DSFonts.registerAll()
        XCTAssertTrue(DSFonts.isAvailable(DSFonts.manrope), "Manrope не зарегистрирован")
        XCTAssertTrue(DSFonts.isAvailable(DSFonts.jetBrainsMono), "JetBrains Mono не зарегистрирован")
        for weight in [Font.Weight.regular, .medium, .semibold, .bold, .heavy] {
            XCTAssertNotNil(NSFont(name: DSFonts.manropeName(weight), size: 13), DSFonts.manropeName(weight))
        }
        XCTAssertNotNil(NSFont(name: "JetBrainsMonoRoman-Medium", size: 13))
        XCTAssertTrue(DSFonts.registerAll().isEmpty, "повторная регистрация ничего не делает")
    }

    func testFontFilesAndLicensesAreInResources() {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Fonts")
        for name in DSFonts.files + ["OFL-Manrope.txt", "OFL-JetBrainsMono.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), name)
        }
        let build = (try? String(contentsOf: folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build.sh"),
                                 encoding: .utf8)) ?? ""
        XCTAssertTrue(build.contains("Resources/Fonts"), "build.sh не копирует шрифты в приложение")
    }

    // MARK: - Форматы и VoiceOver

    func testBytesNeverSayZero() {
        XCTAssertFalse(DS.Format.bytes(0).lowercased().contains("zero"))
        XCTAssertTrue(DS.Format.rate(0).hasSuffix("/с"))
        XCTAssertTrue(DS.Format.rate(-5).hasSuffix("/с"))
    }

    func testKeycapIsSpokenAsWords() {
        XCTAssertEqual(Keycap.spoken(["⌃", "⌥", "M"]), "Control Option M")
        XCTAssertEqual(Keycap.spoken(["⌃⌥", "←"]), "Control Option Left Arrow")
        XCTAssertEqual(Keycap.spoken(["⇧", "⌘", "X"]), "Shift Command X")
        XCTAssertEqual(Keycap.spoken(["Esc"]), "Esc")
    }

    // MARK: - WCAG

    private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
        return result
    }

    private static func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    private static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
