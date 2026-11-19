import CoreGraphics
@testable import MUHiddenScreen
import XCTest

/// HSCR-44: правки ревью 1111 к #218/#220.
final class ReviewFixesTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    let hiddenUnderMain = CGRect(x: 0, y: 1112, width: 1710, height: 1112)

    // MARK: Средняя кнопка на пустом зеркале

    func testMiddleButtonReleaseIsSwallowedToo() {
        XCTAssertTrue(EmptyMirrorClick.presses.contains(.otherMouseDown))
        XCTAssertTrue(EmptyMirrorClick.releases.contains(.otherMouseUp), "иначе отпускание дойдёт до окна зеркала без нажатия")
        for release in EmptyMirrorClick.releases {
            XCTAssertTrue(EmptyMirrorClick.tapTypes.contains(release), "перехват должен слышать \(release.rawValue)")
        }
        for press in EmptyMirrorClick.presses {
            XCTAssertTrue(EmptyMirrorClick.tapTypes.contains(press))
        }
    }

    // MARK: Автовыбор зеркала

    func testLastChoiceBeatsLastShown() {
        // Показывался Claude, человек выбрал ChatGPT (окна ещё нет), окно Claude закрылось.
        let preferred = MirrorChoice.preferred(lastChoice: .chatGPT, shown: .claude)
        XCTAssertEqual(preferred, .chatGPT)
        XCTAssertEqual(MirrorChoice.app(selected: preferred, windows: [(.claude, 1), (.chatGPT, 1)]), .chatGPT,
                       "окно ChatGPT появилось — показываем выбранную")
        XCTAssertEqual(MirrorChoice.preferred(lastChoice: nil, shown: .claude), .claude)
    }

    func testRetryStopsAfterThreeAttemptsThenPauses() {
        var retry = MirrorRetry()
        XCTAssertEqual(retry.next(.claude, now: 0).allow, true)
        XCTAssertEqual(retry.next(.claude, now: 2).allow, true)
        XCTAssertEqual(retry.next(.claude, now: 4).allow, true)
        let fourth = retry.next(.claude, now: 6)
        XCTAssertFalse(fourth.allow)
        XCTAssertTrue(fourth.pauseStarted, "одна строка в журнал при начале паузы")
        let during = retry.next(.claude, now: 20)
        XCTAssertFalse(during.allow)
        XCTAssertFalse(during.pauseStarted, "во время паузы — без новых строк")
        XCTAssertTrue(retry.next(.claude, now: 6 + MirrorRetry.pause).allow, "после паузы — снова пробуем")
    }

    func testRetryResetsOnSuccessOrOtherApp() {
        var retry = MirrorRetry()
        for t in 0..<3 { _ = retry.next(.claude, now: Double(t)) }
        retry.reset()
        XCTAssertTrue(retry.next(.claude, now: 3).allow, "удачный показ — счёт заново")
        for t in 4..<6 { _ = retry.next(.claude, now: Double(t)) }
        XCTAssertTrue(retry.next(.chatGPT, now: 7).allow, "другая программа — свой счёт")
        XCTAssertEqual(retry.attempts, 1)
    }

    // MARK: Dock на других мониторах — теперь сторож края на всех мониторах (HSCR-45)

    func testEveryMonitorDockEdgeIsGuarded() {
        let right = CGRect(x: 1710, y: 0, width: 1920, height: 1080)
        let displays = [main, right]
        XCTAssertNotNil(DockEdgeGuard.clamp(CGPoint(x: 2500, y: 1079.5), edge: .bottom, displays: displays, neighbours: displays))
        XCTAssertNotNil(DockEdgeGuard.clamp(CGPoint(x: 900, y: 1111.5), edge: .bottom, displays: displays, neighbours: displays))
    }

    // MARK: Тёплый дисплей

    func testScreensChangeReactions() {
        let parked = [main, CGRect(x: 1710, y: 0, width: 1920, height: 1080)]
        XCTAssertEqual(WarmDisplayRules.onScreensChanged(physical: [main], parked: parked, sinceOwnChange: 0.5), .ignore,
                       "своя перестройка (раскладка, создание) — не смена мониторов")
        XCTAssertEqual(WarmDisplayRules.onScreensChanged(physical: [main], parked: parked, sinceOwnChange: 30), .release,
                       "монитор отключили — снять тёплый дисплей")
        XCTAssertEqual(WarmDisplayRules.onScreensChanged(physical: parked.reversed(), parked: parked, sinceOwnChange: 30), .checkWindows,
                       "мониторы те же (порядок не важен) — проверить окна")
        XCTAssertEqual(WarmDisplayRules.onScreensChanged(physical: parked + [CGRect(x: -1920, y: 0, width: 1920, height: 1080)],
                                                         parked: parked, sinceOwnChange: 30), .release, "монитор подключили")
    }

    func testStrayWindowsOnWarmDisplay() {
        let warm = CGRect(x: 1710, y: 1072, width: 1710, height: 1112)
        let windows = [
            HiddenWindowInfo(id: 1, pid: 10, bundleID: "com.anthropic.claudefordesktop", frame: CGRect(x: 1800, y: 1200, width: 800, height: 600), layer: 0),
            HiddenWindowInfo(id: 2, pid: 10, bundleID: "com.anthropic.claudefordesktop", frame: CGRect(x: 1900, y: 1300, width: 600, height: 80), layer: -1),
            HiddenWindowInfo(id: 3, pid: 20, bundleID: "com.apple.dock", frame: CGRect(x: 1710, y: 2100, width: 1710, height: 80), layer: 20),
            HiddenWindowInfo(id: 4, pid: 30, bundleID: nil, frame: CGRect(x: 1710, y: 1072, width: 1710, height: 24), layer: 24),
            HiddenWindowInfo(id: 5, pid: 99, bundleID: "mac.utils", frame: CGRect(x: 1800, y: 1200, width: 400, height: 300), layer: 0),
            HiddenWindowInfo(id: 6, pid: 40, bundleID: "com.apple.finder", frame: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 0),
            HiddenWindowInfo(id: 7, pid: 40, bundleID: "com.apple.finder", frame: CGRect(x: 1800, y: 1200, width: 800, height: 600), layer: 0, alpha: 0),
        ]
        let stray = WarmDisplayRules.strayWindows(windows, on: warm, selfPID: 99)
        XCTAssertEqual(stray.map(\.id), [1, 2], "окна программ (и быстрый чат −1); не Dock, не строка меню, не свои, не прозрачные, не на экране")
    }

    func testIdleLimit() {
        XCTAssertEqual(WarmDisplayRules.idleLimit, 600)
        XCTAssertFalse(WarmDisplayRules.idleExpired(parkedAt: 100, now: 699))
        XCTAssertTrue(WarmDisplayRules.idleExpired(parkedAt: 100, now: 700))
        XCTAssertEqual(WarmDisplayRules.launchChecks, [1, 3, 6])
    }
}
