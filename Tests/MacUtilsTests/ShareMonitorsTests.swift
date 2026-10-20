import XCTest
@testable import MacUtils

/// Мониторы ведущего (SHARE-PROTOCOL §4.1): список с этого Mac, правило ведущего, зритель — запрос, ответ, таймаут.
/// Формат сообщений сверяется с relay и страницей в ShareCompatTests (displays.json).
final class ShareMonitorsTests: XCTestCase {
    /// Встроенный Retina (основной) и внешний 4K слева выше; рамки Cocoa — y вверх от низа основного.
    private let screens = [
        ShareDisplays.Screen(id: 11, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), pixels: CGSize(width: 3024, height: 1964), scale: 2, primary: true),
        ShareDisplays.Screen(id: 22, frame: CGRect(x: -2560, y: 200, width: 2560, height: 1440), pixels: CGSize(width: 5120, height: 2880), scale: 2, primary: false),
    ]

    private var kate: [ShareDisplay] {
        [ShareDisplay(n: 1, primary: false, width: 1920, height: 1080, scale: 1, at: CGRect(x: -1920, y: 154, width: 1920, height: 1080)),
         ShareDisplay(n: 2, primary: true, width: 3840, height: 2160, scale: 1.75, at: CGRect(x: 0, y: 0, width: 2194, height: 1234)),
         ShareDisplay(n: 3, primary: false, width: 1920, height: 1080, scale: 1, at: CGRect(x: 2194, y: 154, width: 1920, height: 1080))]
    }

    func testListNumbersLeftToRightWithYDownPixelsAndScale() {
        let list = ShareDisplays.list(screens)
        XCTAssertEqual(list.map(\.id), [22, 11])
        XCTAssertEqual(list[0].display, ShareDisplay(n: 1, primary: false, width: 5120, height: 2880, scale: 2,
                                                      at: CGRect(x: -2560, y: 982 - 1640, width: 2560, height: 1440)))
        XCTAssertEqual(list[1].display.n, 2)
        XCTAssertTrue(list[1].display.primary)
        XCTAssertEqual(list[1].display.at, CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    func testListKeepsEightAndClampsValues() {
        var many: [ShareDisplays.Screen] = []
        for i in 0..<10 {
            let x = CGFloat(i) * 100
            let frame = CGRect(x: x, y: 0, width: 100, height: 100)
            let pixels = CGSize(width: 40000, height: 0)
            many.append(ShareDisplays.Screen(id: CGDirectDisplayID(i + 1), frame: frame, pixels: pixels, scale: 9, primary: i == 0))
        }
        let list = ShareDisplays.list(many)
        XCTAssertEqual(list.count, ShareDisplays.maxCount)
        XCTAssertEqual(list[0].display.width, 32768)
        XCTAssertEqual(list[0].display.height, 1)
        XCTAssertEqual(list[0].display.scale, 4)
    }

    func testMessageHasNoDeviceNamesOrIDs() throws {
        let text = ShareDisplays.message(rev: 3, list: ShareDisplays.list(screens).map(\.display), current: 2, allowed: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(json["current"] as? Int, 2)
        let item = try XCTUnwrap((json["list"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["n", "primary", "w", "h", "scale", "at"])
        XCTAssertFalse(text.contains("22") && text.contains("\"id\""))
        // Окно или программа (current нет) — пустой список.
        let window = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ShareDisplays.message(rev: 3, list: kate, current: nil, allowed: true).utf8)) as? [String: Any])
        XCTAssertEqual((window["list"] as? [Any])?.count, 0)
        XCTAssertNil(window["current"])
    }

    func testRevisionChangesOnlyWithTheList() {
        var revision = ShareDisplays.Revision()
        let first = revision.update(kate)
        XCTAssertEqual(revision.update(kate), first)
        var scaled = kate
        scaled[0] = ShareDisplay(n: 1, primary: false, width: 1920, height: 1080, scale: 1.25, at: scaled[0].at)
        XCTAssertEqual(revision.update(scaled), first + 1)
        XCTAssertEqual(revision.update(Array(kate.prefix(2))), first + 2)
    }

    // MARK: - Правило ведущего

    private func host(_ change: (inout ShareMonitorSwitch.HostState) -> Void = { _ in }) -> ShareMonitorSwitch.HostState {
        var state = ShareMonitorSwitch.HostState(allowed: true, screen: true, rev: 7, list: kate, current: 2, switching: false, lastSwitchAt: nil)
        change(&state)
        return state
    }

    func testDecideAllOutcomes() {
        let now = Date()
        XCTAssertEqual(ShareMonitorSwitch.decide(host { $0.allowed = false }, display: 3, rev: 7, now: now), .off)
        XCTAssertEqual(ShareMonitorSwitch.decide(host { $0.screen = false }, display: 3, rev: 7, now: now), .off)
        XCTAssertEqual(ShareMonitorSwitch.decide(host { $0.list = [] }, display: 3, rev: 7, now: now), .off)
        XCTAssertEqual(ShareMonitorSwitch.decide(host(), display: 3, rev: 6, now: now), .stale)
        XCTAssertEqual(ShareMonitorSwitch.decide(host(), display: 4, rev: 7, now: now), .stale)
        XCTAssertEqual(ShareMonitorSwitch.decide(host(), display: 2, rev: 7, now: now), .ok)
        XCTAssertEqual(ShareMonitorSwitch.decide(host { $0.switching = true }, display: 3, rev: 7, now: now), .busy)
        XCTAssertEqual(ShareMonitorSwitch.decide(host(), display: 3, rev: 7, now: now), .change)
    }

    func testDecideKeepsTwoSecondsBetweenSwitches() {
        let at = Date()
        let state = host { $0.lastSwitchAt = at }
        XCTAssertEqual(ShareMonitorSwitch.decide(state, display: 1, rev: 7, now: at.addingTimeInterval(1.99)), .busy)
        XCTAssertEqual(ShareMonitorSwitch.decide(state, display: 2, rev: 7, now: at.addingTimeInterval(0.1)), .ok)
        XCTAssertEqual(ShareMonitorSwitch.decide(state, display: 1, rev: 7, now: at.addingTimeInterval(2)), .change)
    }

    func testSwitchResultTurnsOffWhenSettingWasDisabledMeanwhile() {
        XCTAssertEqual(ShareMonitorSwitch.result(switched: true, allowed: true), "ok")
        XCTAssertEqual(ShareMonitorSwitch.result(switched: true, allowed: false), "off", "выключили во время переключения")
        XCTAssertEqual(ShareMonitorSwitch.result(switched: false, allowed: true), "failed")
        XCTAssertEqual(ShareMonitorSwitch.result(switched: false, allowed: false), "failed")
    }

    func testStaleAndOffReannounceAtMostOncePerSecond() {
        let at = Date()
        XCTAssertTrue(ShareMonitorSwitch.shouldReannounce(last: nil, now: at))
        XCTAssertFalse(ShareMonitorSwitch.shouldReannounce(last: at, now: at.addingTimeInterval(0.5)))
        XCTAssertTrue(ShareMonitorSwitch.shouldReannounce(last: at, now: at.addingTimeInterval(1)))
    }

    func testNoticeOnlyWhenMarksWindowIsExcludedFromCapture() {
        XCTAssertTrue(ShareMonitorSwitch.windowExcluded(42, from: [7, 42]))
        XCTAssertFalse(ShareMonitorSwitch.windowExcluded(42, from: [7]), "окна нет в списке — исключение не встанет")
        XCTAssertFalse(ShareMonitorSwitch.windowExcluded(nil, from: [7, 42]), "окна меток ещё нет")
    }

    /// Приватность: без явного включения ведущим зрители другие мониторы не видят.
    func testMonitorSwitchIsOffByDefault() {
        Pref.register()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(registered[Pref.shareAllowMonitorSwitch] as? Bool, false)
    }

    /// Закрыли окно просмотра — клавиши 1…9 больше не перехватываются ни в каком окне Mac Utils.
    @MainActor func testViewerKeysAreRemovedWhenWindowCloses() {
        let viewer = ShareViewer.shared
        viewer.installMonitorKeys()
        XCTAssertTrue(viewer.monitorKeysInstalled)
        viewer.installMonitorKeys()
        viewer.windowClosed()
        XCTAssertFalse(viewer.monitorKeysInstalled)
        XCTAssertFalse(viewer.isWindowOpen)
        XCTAssertEqual(viewer.state, .idle)
    }

    // MARK: - Зритель

    private func parsed(current: Int?, rev: Int = 7, list: [ShareDisplay]? = nil) -> ShareDisplays.Parsed {
        ShareDisplays.Parsed(rev: rev, current: current, list: current == nil ? [] : (list ?? kate))
    }

    func testViewerRequestOkThenDisplaysFinishes() {
        var picker = ShareMonitorPicker()
        XCTAssertTrue(picker.list.isEmpty, "старый ведущий: displays нет — раздела нет")
        XCTAssertEqual(picker.apply(parsed(current: 2)), .init(), "первый список без плашки")
        XCTAssertNil(picker.request(2, now: Date()), "уже показывается")
        XCTAssertNil(picker.request(5, now: Date()), "нет такого")
        XCTAssertEqual(picker.request(3, now: Date()), #"{"type":"switch-request","display":3,"rev":7}"#)
        XCTAssertNil(picker.request(1, now: Date()), "запрос уже в пути")
        XCTAssertNil(picker.result(display: 3, result: "ok"))
        XCTAssertEqual(picker.pending, 3, "ok ждёт displays")
        XCTAssertEqual(picker.apply(parsed(current: 3)), .init(switched: true, gone: false, done: true))
        XCTAssertNil(picker.pending)
        XCTAssertEqual(picker.apply(parsed(current: 3)), .init(), "повтор того же списка ничего не меняет")
        XCTAssertEqual(picker.apply(parsed(current: 1)).switched, true, "переключил другой зритель")
    }

    func testViewerResultsAndTimeout() {
        for (result, notice) in [("busy", ShareMonitorPicker.Notice.busy), ("failed", .failed), ("off", .off)] {
            var picker = ShareMonitorPicker()
            _ = picker.apply(parsed(current: 2))
            _ = picker.request(3, now: Date())
            XCTAssertEqual(picker.result(display: 3, result: result), notice)
            XCTAssertNil(picker.pending)
        }
        var picker = ShareMonitorPicker()
        _ = picker.apply(parsed(current: 2))
        let at = Date()
        _ = picker.request(3, now: at)
        XCTAssertNil(picker.result(display: 1, result: "busy"), "ответ не на этот запрос")
        XCTAssertFalse(picker.expired(now: at.addingTimeInterval(7.9)))
        XCTAssertTrue(picker.expired(now: at.addingTimeInterval(8)))
        XCTAssertNil(picker.pending)
        _ = picker.request(1, now: at)
        XCTAssertNil(picker.result(display: 1, result: "stale"))
        XCTAssertNil(picker.pending, "stale — молча, свежий список уже в пути")
    }

    func testViewerOffHidesSectionAndIgnoresUnknownVersion() {
        var picker = ShareMonitorPicker()
        _ = picker.apply(parsed(current: 2))
        _ = picker.request(3, now: Date())
        XCTAssertEqual(picker.apply(parsed(current: nil, rev: 8)), .init(switched: false, gone: true, done: true))
        XCTAssertTrue(picker.list.isEmpty)
        XCTAssertNil(picker.request(3, now: Date()))
        XCTAssertNil(ShareDisplays.parse(["type": "displays", "v": 2, "rev": 1, "list": []]))
        XCTAssertNil(ShareDisplays.parse(["type": "displays", "v": 1, "rev": "1", "list": []]))
        XCTAssertNil(ShareDisplays.parse(["type": "displays", "v": true, "rev": 1, "list": []]))
    }

    func testViewerKeys() {
        var picker = ShareMonitorPicker()
        _ = picker.apply(parsed(current: 2))
        XCTAssertEqual(picker.monitor(forKey: "3"), 3)
        XCTAssertNil(picker.monitor(forKey: "4"))
        XCTAssertNil(picker.monitor(forKey: "0"))
        XCTAssertNil(picker.monitor(forKey: "a"))
        XCTAssertNil(picker.monitor(forKey: "12"))
    }

    func testAccessibilityLabelAndTitle() {
        XCTAssertEqual(kate[1].accessibilityLabel(current: 2), "Монитор 2, основной, 3840 на 2160, 175 %, показывается сейчас")
        XCTAssertEqual(kate[0].accessibilityLabel(current: 2), "Монитор 1, 1920 на 1080, 100 %")
        XCTAssertEqual(kate[2].title, "Монитор 3 · 1920×1080 · 100 %")
    }
}
