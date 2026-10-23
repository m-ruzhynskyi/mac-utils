import AppKit
import Carbon.HIToolbox
import XCTest
@testable import MacUtils

/// Этап 3 плеера: клавиши (§ 8.1), удержание →, клики по третям, точки входа.
final class PlayerShortcutsTests: XCTestCase {
    /// Таблица → обработчик: каждая клавиша таблицы разбирается в своё действие.
    func testEveryTableKeyResolvesToItsAction() {
        for shortcut in PlayerShortcuts.all {
            for key in shortcut.keys {
                XCTAssertEqual(PlayerShortcuts.action(keyCode: key.keyCode, modifiers: key.modifiers), shortcut.action, shortcut.title)
            }
        }
    }

    /// Обработчик → таблица: у каждого действия есть строка (её видит «Шпаргалка»), и клавиши не повторяются.
    func testEveryActionIsInTableOnceAndKeysAreUnique() {
        for action in PlayerAction.allCases {
            XCTAssertEqual(PlayerShortcuts.all.filter { $0.action == action }.count, 1, action.rawValue)
        }
        let keys = PlayerShortcuts.all.flatMap(\.keys)
        XCTAssertEqual(Set(keys).count, keys.count, "одна клавиша — одно действие")
        // Любое сочетание, которое разбирает обработчик, есть в таблице.
        let modifiers: [NSEvent.ModifierFlags] = [[], .shift, .option, .command, [.control, .command], [.option, .command]]
        for keyCode in 0..<128 {
            for flags in modifiers {
                guard let action = PlayerShortcuts.action(keyCode: keyCode, modifiers: flags) else { continue }
                XCTAssertTrue(PlayerShortcuts.shortcut(for: action)?.keys.contains(PlayerShortcut.Key(keyCode, flags)) ?? false)
            }
        }
    }

    func testDecisionsOfSection81() {
        func action(_ key: Int, _ flags: NSEvent.ModifierFlags = []) -> PlayerAction? { PlayerShortcuts.action(keyCode: key, modifiers: flags) }
        XCTAssertEqual(action(kVK_Space), .togglePlay)
        XCTAssertEqual(action(kVK_ANSI_K), .togglePlay, "K — пауза, как на YouTube")
        XCTAssertEqual(action(kVK_ANSI_J), .jumpBackward)
        XCTAssertEqual(action(kVK_ANSI_L), .jumpForward)
        XCTAssertEqual(action(kVK_ANSI_S), .skip, "S отдана «Пропустить»")
        XCTAssertEqual(action(kVK_Return), .skip)
        XCTAssertEqual(action(kVK_ANSI_S, .shift), .snapshot, "снимок кадра — ⇧S")
        XCTAssertEqual(action(kVK_LeftArrow, .shift), .seekBackwardMinute)
        XCTAssertEqual(action(kVK_ANSI_Comma), .frameBackward)
        XCTAssertEqual(action(kVK_ANSI_Period), .frameForward)
        XCTAssertEqual(action(kVK_ANSI_L, .command), .playlist)
        XCTAssertEqual(action(kVK_ANSI_T, [.control, .command]), .videoOnly)
        XCTAssertNil(action(kVK_ANSI_Q, .command), "⌘Q — не плеера")
        XCTAssertNil(action(kVK_ANSI_W, .command), "⌘W закрывает окно через меню")
        // Состояние Caps Lock и цифровой клавиатуры не мешает.
        XCTAssertEqual(PlayerShortcuts.action(keyCode: kVK_RightArrow, modifiers: [.numericPad, .function]), .seekForward)
        XCTAssertEqual(PlayerShortcuts.action(keyCode: kVK_ANSI_M, modifiers: .capsLock), .mute)
    }

    func testCheatSheetGroupComesFromTable() {
        let group = PlayerShortcuts.cheatGroup
        XCTAssertEqual(group.title, "Видеоплеер")
        XCTAssertEqual(group.items.count, PlayerShortcuts.all.count)
        XCTAssertTrue(group.items.contains { $0.shortcut == "⇧S" && $0.title.contains("Снимок") })
        XCTAssertEqual(PlayerShortcuts.label(.snapshot), "⇧S")
    }
}

final class HoldToFastForwardTests: XCTestCase {
    func testShortPressSeeksOnRelease() {
        var hold = HoldToFastForward()
        XCTAssertEqual(hold.keyDown(at: 10, isRepeat: false), .none, "на нажатие — ничего: ещё не ясно, удержание ли это")
        XCTAssertEqual(hold.tick(at: 10.2), .none)
        XCTAssertEqual(hold.keyUp(at: 10.25), .seekForward, "< 0,3 с — +5 с на отпускание")
    }

    func testHoldBoostsAndReleaseRestores() {
        var hold = HoldToFastForward()
        _ = hold.keyDown(at: 0, isRepeat: false)
        XCTAssertEqual(hold.tick(at: 0.3), .beginHold)
        XCTAssertEqual(hold.tick(at: 0.5), .none, "один раз")
        XCTAssertEqual(hold.keyDown(at: 0.6, isRepeat: true), .none, "повторы клавиши не учитываются")
        XCTAssertEqual(hold.keyUp(at: 1.4), .endHold, "отпустили — прежняя скорость")
        XCTAssertNil(hold.pressedAt)
    }

    func testRepeatsDoNotRestartThePress() {
        var hold = HoldToFastForward()
        _ = hold.keyDown(at: 0, isRepeat: false)
        _ = hold.keyDown(at: 0.05, isRepeat: true)
        _ = hold.keyDown(at: 0.1, isRepeat: false)
        XCTAssertEqual(hold.pressedAt, 0, "время нажатия — первое")
    }

    func testCancelWhileHoldingRestores() {
        var hold = HoldToFastForward()
        _ = hold.keyDown(at: 0, isRepeat: false)
        _ = hold.tick(at: 0.31)
        XCTAssertEqual(hold.cancel(), .endHold, "окно потеряло фокус — скорость вернуть")
        XCTAssertEqual(hold.cancel(), .none)
    }

    func testBoostPlan() {
        XCTAssertTrue(HoldToFastForward.boost(rate: 1, playing: true) == (2, false))
        XCTAssertTrue(HoldToFastForward.boost(rate: 1, playing: false) == (2, true), "стояла пауза — играть, потом снова пауза")
        XCTAssertTrue(HoldToFastForward.boost(rate: 2, playing: true) == (nil, false), "уже ≥ 2× — скорость не меняется")
        XCTAssertTrue(HoldToFastForward.boost(rate: 3, playing: true) == (nil, false))
    }
}

final class ClickZoneTests: XCTestCase {
    func testThirds() {
        XCTAssertEqual(ClickZone.at(x: 10, width: 900), .left)
        XCTAssertEqual(ClickZone.at(x: 299, width: 900), .left)
        XCTAssertEqual(ClickZone.at(x: 450, width: 900), .middle)
        XCTAssertEqual(ClickZone.at(x: 601, width: 900), .right)
        XCTAssertEqual(ClickZone.at(x: 5, width: 0), .middle)
    }

    func testSeriesOnTheSides() {
        var series = ClickSeries()
        XCTAssertEqual(series.click(count: 1, zone: .right, playing: true), [.togglePlay], "одиночный — пауза сразу")
        XCTAssertEqual(series.click(count: 2, zone: .right, playing: false),
                       [.restore(playing: true), .seek(10), .hint(.right, seconds: 10)], "второй — пауза как было и +10 с")
        XCTAssertEqual(series.click(count: 3, zone: .right, playing: true), [.seek(10), .hint(.right, seconds: 20)])
        XCTAssertEqual(series.click(count: 4, zone: .right, playing: true), [.seek(10), .hint(.right, seconds: 30)])
        XCTAssertEqual(series.click(count: 1, zone: .left, playing: false), [.togglePlay])
        XCTAssertEqual(series.click(count: 2, zone: .left, playing: true),
                       [.restore(playing: false), .seek(-10), .hint(.left, seconds: 10)])
    }

    func testDoubleClickInTheMiddleIsFullScreen() {
        var series = ClickSeries()
        _ = series.click(count: 1, zone: .middle, playing: true)
        XCTAssertEqual(series.click(count: 2, zone: .middle, playing: false), [.restore(playing: true), .fullScreen])
        XCTAssertEqual(series.click(count: 3, zone: .middle, playing: true), [])
    }
}

@MainActor
final class PlayerEntryPointTests: XCTestCase {
    func testHotKeyIsFreeAndRemappable() {
        let defaults = UserDefaults(suiteName: "PlayerEntryPointTests-\(UUID().uuidString)")!
        let combo = HotKeyRegistry.combo(for: .videoPlayer, defaults: defaults)
        XCTAssertEqual(combo, LayoutHotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey | optionKey | controlKey))
        XCTAssertNotEqual(combo, HotKeyAction.windowPin.defaultCombo, "⌃⌥P — закрепление окна, другое сочетание")
        for modifier in [WindowSnapModifier.controlOption, .controlCommand, .optionCommand] {
            let entries = HotKeyRegistry.entries(defaults: defaults, windowSnap: modifier)
            XCTAssertTrue(HotKeyConflicts.duplicates(of: combo, excluding: .action(.videoPlayer), in: entries).isEmpty,
                          "⌃⌥⌘P ни с чем не совпадает")
        }
        XCTAssertNil(HotKeyConflicts.system(combo))
        XCTAssertEqual(HotKeyAction.videoPlayer.section, .videoPlayer)
        XCTAssertEqual(HotKeyAction.action(forHotKeyID: HotKeyID.videoPlayer), .videoPlayer)
    }

    func testFilesFromFinderAreRouted() {
        let urls = ["a.mp4", "b.mov", "c.m4a", "d.mp3", "e.mkv", "f.srt", "g.txt", "h.frm"].map { URL(fileURLWithPath: "/x/\($0)") }
        let closed = FileRoute.split(urls, playerOpen: false)
        XCTAssertEqual(closed.player.map(\.lastPathComponent), ["a.mp4", "b.mov", "c.m4a", "d.mp3", "e.mkv"])
        XCTAssertEqual(closed.editor.map(\.lastPathComponent), ["f.srt", "g.txt", "h.frm"], "субтитры без плеера — текст")
        let open = FileRoute.split(urls, playerOpen: true)
        XCTAssertTrue(open.player.map(\.lastPathComponent).contains("f.srt"), "открыт плеер — субтитры к видео")
    }

    func testDocumentTypesAreAlternateViewersWithoutMKV() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let media = types.filter { ["Видео", "Звук"].contains($0["CFBundleTypeName"] as? String) }
        XCTAssertEqual(media.count, 2)
        for type in media {
            XCTAssertEqual(type["LSHandlerRank"] as? String, "Alternate", "QuickTime остаётся по умолчанию")
            XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Viewer")
        }
        let utis = media.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(utis.contains("public.mpeg-4"))
        XCTAssertFalse(utis.contains { $0.contains("matroska") || $0.contains("webm") || $0 == "public.avi" }, "MKV/WebM/AVI — во второй версии")
    }

    /// Видеоплеер выходит в 1.9 (вместе с режимом «Документ»): пункты — в записи «1.9», без номеров версий в тексте.
    func testWhatsNewEntry() {
        let release = Changelog.releases.first { $0.version == "1.9" }
        XCTAssertTrue(release?.items.contains { $0.hasPrefix("Видеоплеер") } ?? false)
        let numbered = try! NSRegularExpression(pattern: #"\b\d+\.\d+(\.\d+)?\b"#)
        for item in release?.items ?? [] where item.contains("плеер") || item.contains("Пропустить") {
            XCTAssertNil(numbered.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)), item)
        }
    }

    func testPanelTabIsOffByDefaultButSectionExists() {
        XCTAssertFalse(PanelTabs.defaultValue.split(separator: ",").contains("videoPlayer"), "вкладка «Плеер» в панели по умолчанию выключена")
        XCTAssertTrue(PanelTabs.available.contains(.videoPlayer))
        XCTAssertEqual(SettingsSection.videoPlayer.group, .filesSystem)
        // Новые разделы — в конце, по порядку появления (плеер): прежние не сдвигаются.
        let all = SettingsSection.allCases.map(\.rawValue)
        let videoIndex = all.firstIndex(of: "videoPlayer")
        XCTAssertNotNil(videoIndex)
        XCTAssertEqual(videoIndex.map { all[..<$0].suffix(1) }, ["textEditor"], "плеер — сразу после прежних разделов")
        // После плеера — только разделы, появившиеся позже («Удалённые подключения»).
        XCTAssertEqual(videoIndex.map { Array(all[($0 + 1)...]) }, ["remote"])
        // Сохранённые вкладки панели — по именам разделов, а не по номерам: порядок allCases их не сдвигает.
        XCTAssertEqual(PanelTabs.sections("videoPlayer,textEditor"), [.videoPlayer, .textEditor])
    }
}

/// Тестер 2, дефект 1: номер серии в плейлисте и заголовке не сокращается.
final class EpisodeNameTests: XCTestCase {
    func testMarkers() {
        let table: [(String, String?)] = [
            ("harbor_s01e03_demo.mp4", "s01e03"), ("Harbor.S01E03.1080p.WEB.mp4", "S01E03"), ("Harbor S01 E03.mp4", "S01 E03"),
            ("Harbor 1x03 Пилот.mp4", "1x03"), ("Гавань — Серия 12.mp4", "Серия 12"), ("Гавань, 3 серия.mp4", "3 серия"),
            ("Show Episode 5.mov", "Episode 5"), ("show_ep05.m4v", "ep05"), ("Anime - E07.mp4", "E07"),
            ("lecture_demo_part1.mp4", nil), ("2026-10-20 запись экрана.mp4", nil), ("1920x1080 demo.mp4", nil), ("Sample.mp4", nil),
        ]
        for (name, marker) in table {
            XCTAssertEqual(EpisodeName.split(name)?.marker, marker, name)
        }
        let parts = EpisodeName.split("Очень длинное название сериала про гавань s01e03_demo.mp4")
        XCTAssertEqual(parts?.before, "Очень длинное название сериала про гавань ")
        XCTAssertEqual(parts?.after, "_demo.mp4")
    }
}
