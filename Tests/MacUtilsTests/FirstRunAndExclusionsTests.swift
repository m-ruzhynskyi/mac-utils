import AVFoundation
import XCTest
@testable import MacUtils
@testable import MUCore

/// Первый запуск, перенос в «Программы», уровни разрешений и общий список исключённых программ.
@MainActor
final class FirstRunAndExclusionsTests: XCTestCase {
    // MARK: Первый запуск (A5)

    func testFirstLaunchShowsOnlySettings() {
        let plan = FirstRun.plan(firstLaunch: true, accessibility: false, wantsMoveOffer: true)
        XCTAssertTrue(plan.showSettings)
        XCTAssertFalse(plan.offerMove, "на чистой установке окно «Перенести?» не поверх настроек")
        XCTAssertEqual(FirstRun.plan(firstLaunch: true, accessibility: true, wantsMoveOffer: true).offerMove, false)
    }

    func testLaterLaunchesAskAboutMoveOnlyWhenSettingsStayClosed() {
        XCTAssertEqual(FirstRun.plan(firstLaunch: false, accessibility: true, wantsMoveOffer: true), .init(showSettings: false, offerMove: true))
        XCTAssertEqual(FirstRun.plan(firstLaunch: false, accessibility: true, wantsMoveOffer: false), .init(showSettings: false, offerMove: false))
        XCTAssertEqual(FirstRun.plan(firstLaunch: false, accessibility: false, wantsMoveOffer: true), .init(showSettings: true, offerMove: false),
                       "нет «Универсального доступа»: окно настроек, вопрос позже")
    }

    private func suite() throws -> UserDefaults {
        let name = "firstrun-\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    func testCleanInstallSeedsChangelogButUpdateDoesNot() throws {
        let clean = try suite()
        FirstRun.seedChangelog(defaults: clean, current: "1.5", welcomeShown: false)
        XCTAssertEqual(clean.string(forKey: Pref.lastSeenChangelog), "1.5", "«Что нового» на чистой установке не показывается")

        let upgrade = try suite()
        FirstRun.seedChangelog(defaults: upgrade, current: "1.5", welcomeShown: true)
        XCTAssertNil(upgrade.string(forKey: Pref.lastSeenChangelog), "обновившийся увидит «Что нового»")

        let seen = try suite()
        seen.set("1.4", forKey: Pref.lastSeenChangelog)
        FirstRun.seedChangelog(defaults: seen, current: "1.5", welcomeShown: false)
        XCTAssertEqual(seen.string(forKey: Pref.lastSeenChangelog), "1.4", "уже сохранённое не затирается")
    }

    // MARK: «Больше не спрашивать» (A2)

    func testMoveOfferRules() {
        XCTAssertTrue(MoveToApplications.shouldOffer(isInApplications: false, suppressed: false, isDevChannel: false))
        XCTAssertFalse(MoveToApplications.shouldOffer(isInApplications: true, suppressed: false, isDevChannel: false))
        XCTAssertFalse(MoveToApplications.shouldOffer(isInApplications: false, suppressed: true, isDevChannel: false), "отказался навсегда")
        XCTAssertFalse(MoveToApplications.shouldOffer(isInApplications: false, suppressed: false, isDevChannel: true), "сборка для разработки")
    }

    // MARK: Разрешения (UI3)

    func testMicrophoneLevels() {
        XCTAssertEqual(Permissions.microphoneLevel(.authorized), .granted)
        XCTAssertEqual(Permissions.microphoneLevel(.notDetermined), .notAsked)
        XCTAssertEqual(Permissions.microphoneLevel(.denied), .denied)
        XCTAssertEqual(Permissions.microphoneLevel(.restricted), .denied)
        XCTAssertEqual(Permissions.Pane.microphone.rawValue, "Privacy_Microphone")
    }

    // MARK: Исключённые программы

    func testExactAndPrefixMatching() {
        let list = ["com.parallels.", "com.utmapp.UTM", "com.vmware.fusion"]
        XCTAssertTrue(AppExclusions.matches("com.parallels.desktop.console", in: list))
        XCTAssertTrue(AppExclusions.matches("com.parallels.winapp.abc", in: list))
        XCTAssertTrue(AppExclusions.matches("com.utmapp.UTM", in: list))
        XCTAssertTrue(AppExclusions.matches("COM.UTMAPP.utm", in: list), "регистр не важен")
        XCTAssertFalse(AppExclusions.matches("com.utmapp.UTMHelper", in: list), "без точки — точное совпадение")
        XCTAssertFalse(AppExclusions.matches("com.parallels", in: list), "префикс требует точки")
        XCTAssertFalse(AppExclusions.matches("com.apple.finder", in: list))
        XCTAssertFalse(AppExclusions.matches(nil, in: list))
        XCTAssertFalse(AppExclusions.matches("", in: list))
        XCTAssertFalse(AppExclusions.matches("com.x", in: ["", "  "]))
    }

    func testDefaultsCoverVirtualMachinesAndRemoteDesktops() {
        let list = AppExclusions.defaultList
        for id in ["com.parallels.desktop.console", "com.vmware.fusion", "org.virtualbox.app.VirtualBoxVM", "com.utmapp.UTM",
                   "com.apple.ScreenSharing", "com.microsoft.rdc.macos", "com.teamviewer.TeamViewer", "com.anydesk.anydesk"] {
            XCTAssertTrue(AppExclusions.matches(id, in: list), id)
        }
        for id in ["com.apple.finder", "com.apple.Safari", "com.googlecode.iterm2", "com.apple.dt.Xcode"] {
            XCTAssertFalse(AppExclusions.matches(id, in: list), "обычная программа в списке по умолчанию: \(id)")
        }
    }

    func testAddingTrimsAndDeduplicates() {
        XCTAssertEqual(AppExclusions.adding("  com.a.b  ", to: []), ["com.a.b"])
        XCTAssertEqual(AppExclusions.adding("COM.A.B", to: ["com.a.b"]), ["com.a.b"])
        XCTAssertEqual(AppExclusions.adding("   ", to: ["x"]), ["x"])
        XCTAssertEqual(AppExclusions.adding("y", to: ["x"]), ["x", "y"])
    }

    func testLoadFallsBackToDefaultsAndRespectsEmptyList() throws {
        let defaults = try suite()
        XCTAssertEqual(AppExclusions.load(defaults: defaults), AppExclusions.defaultList)
        defaults.set([], forKey: AppExclusions.defaultsKey)
        XCTAssertEqual(AppExclusions.load(defaults: defaults), [], "пользователь очистил список — исключений нет")
        defaults.set(["com.mine.app"], forKey: AppExclusions.defaultsKey)
        XCTAssertEqual(AppExclusions.load(defaults: defaults), ["com.mine.app"])
    }

    // MARK: ревью пакета 7

    /// MAJOR-1: в режиме ⌘Tab системный переключатель выключен только вне исключённых программ.
    func testSystemSwitcherIsDisabledOnlyOutsideExcludedApps() {
        let f = AppSwitcher.shouldDisableSystemSwitcher
        XCTAssertTrue(f(true, true, false), "режим ⌘, программа обычная — наш переключатель заменяет системный")
        XCTAssertFalse(f(true, true, true), "в виртуальной машине или на удалённом столе системный ⌘Tab работает")
        XCTAssertFalse(f(true, false, false), "режим ⌥Tab: системный не трогаем")
        XCTAssertFalse(f(false, true, false), "переключатель не запущен")
        XCTAssertFalse(f(false, true, true))
    }

    func testExclusionChangeIsAnnounced() {
        XCTAssertEqual(AppExclusions.didChangeNotification.rawValue, "MacUtilsAppExclusionsDidChange")
    }

    func testParallelsToolboxIsNotExcludedButVirtualMachinesAre() {
        let list = AppExclusions.defaultList
        XCTAssertFalse(AppExclusions.matches("com.parallels.toolbox", in: list), "Toolbox — обычные утилиты Mac")
        XCTAssertTrue(AppExclusions.matches("com.parallels.desktop.console", in: list))
        XCTAssertTrue(AppExclusions.matches("com.parallels.winapp.excel", in: list))
        XCTAssertTrue(AppExclusions.matches("com.parallels.vm.windows11", in: list))
        XCTAssertTrue(AppExclusions.matches("com.p5sys.jump.mac.viewer", in: list))
        XCTAssertTrue(AppExclusions.matches("com.p5sys.jump.mac.viewer.web", in: list))
    }

    /// N4: апостроф украинской раскладки в любом виде переводится на клавишу ` (м'ясо, мʼясо, м’ясо).
    func testUkrainianApostropheVariantsConvertToEnglishKey() {
        for apostrophe in ["\u{2BC}", "'", "\u{2019}"] {
            XCTAssertEqual(LayoutMap.convert("м\(apostrophe)ясо", .toEnglish), "v`zcj", apostrophe.unicodeScalars.map { String($0.value, radix: 16) }.joined())
        }
        XCTAssertEqual(LayoutMap.convert("v`zcj", .toUkrainian), "мʼясо", "обратно — стандартный апостроф U+02BC")
    }
}
