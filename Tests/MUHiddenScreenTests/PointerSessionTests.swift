import CoreGraphics
import Foundation
@testable import MUHiddenScreen
import XCTest

/// Мышь из зеркала: план шагов без системы (ни курсора, ни событий).
final class PointerSessionTests: XCTestCase {
    /// Зеркало 400×300 показывает окно 800×600 на скрытом дисплее (масштаб 0,5).
    let mapping = MirrorMapping(viewSize: CGSize(width: 400, height: 300), target: CGRect(x: 2000, y: 1000, width: 800, height: 600))
    let cursor = CGPoint(x: 300, y: 200)

    func testLeftClickWarpsClicksAndReturnsInOnePass() {
        var session = PointerSession()
        XCTAssertEqual(session.down(.left, at: CGPoint(x: 100, y: 50), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor), [],
                       "по нажатию ничего: ещё не ясно, щелчок это или перетаскивание")
        let steps = session.up(mapping: mapping, windowNumber: 7)
        let target = CGPoint(x: 2200, y: 1100)
        XCTAssertEqual(steps, [
            .hideCursor, .activateTarget, .warp(target),
            .postHID(SyntheticEvent(kind: .leftDown, location: target, clicks: 1)),
            .postHID(SyntheticEvent(kind: .leftUp, location: target, clicks: 1)),
            .warp(cursor), .showCursor, .returnFocus,
        ])
        XCTAssertEqual(session.state, .idle)
    }

    func testDoubleClickKeepsClickCount() {
        var session = PointerSession()
        _ = session.down(.left, at: CGPoint(x: 10, y: 10), clicks: 2, flags: .maskShift, mapping: mapping, windowNumber: 7, cursor: cursor)
        let posts = session.up(mapping: mapping, windowNumber: 7).compactMap { step -> SyntheticEvent? in
            if case let .postHID(event) = step { return event }
            return nil
        }
        XCTAssertEqual(posts.map(\.clicks), [2, 2])
        XCTAssertEqual(posts.map(\.flags), [.maskShift, .maskShift])
        XCTAssertTrue(posts.allSatisfy { $0.windowNumber == 0 }, "HID: окно находит WindowServer")
    }

    func testClickOnLetterboxIsIgnored() {
        let wide = MirrorMapping(viewSize: CGSize(width: 600, height: 300), target: CGRect(x: 0, y: 0, width: 800, height: 600))
        var session = PointerSession()
        XCTAssertEqual(session.down(.left, at: CGPoint(x: 20, y: 100), clicks: 1, flags: [], mapping: wide, windowNumber: 1, cursor: cursor), [])
        XCTAssertEqual(session.up(mapping: wide, windowNumber: 1), [])
    }

    func testSmallMovementIsStillAClick() {
        var session = PointerSession()
        _ = session.down(.left, at: CGPoint(x: 100, y: 50), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor)
        XCTAssertEqual(session.dragged(to: CGPoint(x: 101, y: 51), mapping: mapping), [])
        XCTAssertEqual(session.up(mapping: mapping, windowNumber: 7).first, .hideCursor)
    }

    func testDragHandsTheCursorOverUntilButtonUp() {
        var session = PointerSession()
        _ = session.down(.left, at: CGPoint(x: 100, y: 50), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor)
        let steps = session.dragged(to: CGPoint(x: 110, y: 50), mapping: mapping)
        XCTAssertEqual(steps, [
            .activateTarget, .warp(CGPoint(x: 2200, y: 1100)),
            .postHID(SyntheticEvent(kind: .leftDown, location: CGPoint(x: 2200, y: 1100), clicks: 1)),
            .postHID(SyntheticEvent(kind: .leftDragged, location: CGPoint(x: 2220, y: 1100), clicks: 1)),
            .warp(CGPoint(x: 2220, y: 1100)), .beginHandoff(.drag),
        ], "нажатие — синтетическое в окне программы, курсор — туда, где уже протянули")
        XCTAssertEqual(session.handoff, .drag)
        // Пока курсор передан, зеркало ничего не шлёт.
        XCTAssertEqual(session.up(mapping: mapping, windowNumber: 7), [])
        XCTAssertEqual(session.scroll(dx: 0, dy: 3, precise: true, at: CGPoint(x: 5, y: 5), mapping: mapping, windowNumber: 7), [])

        let mirrorRect = CGRect(x: 100, y: 200, width: 400, height: 300)
        let end = session.endHandoff(cursorNow: CGPoint(x: 2400, y: 1300), mapping: mapping, mirrorRect: mirrorRect)
        XCTAssertEqual(end, [.warp(CGPoint(x: 300, y: 350)), .returnFocus, .endHandoff(.drag)])
        XCTAssertEqual(session.state, .idle)
    }

    func testRightClickOpensMenuAndWaits() {
        var session = PointerSession()
        let steps = session.down(.right, at: CGPoint(x: 200, y: 150), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor)
        XCTAssertEqual(steps.first, .activateTarget)
        XCTAssertEqual(steps.last, .beginHandoff(.menu))
        XCTAssertTrue(steps.contains(.postHID(SyntheticEvent(kind: .rightDown, location: CGPoint(x: 2400, y: 1300), clicks: 1))))
        XCTAssertFalse(steps.contains(.returnFocus), "меню закроется, если вернуть активность Mac Utils сразу")
    }

    func testScrollHandoffDoesNotActivate() {
        var session = PointerSession()
        let steps = session.scroll(dx: 0, dy: -4, precise: true, at: CGPoint(x: 10, y: 10), mapping: mapping, windowNumber: 7)
        XCTAssertEqual(steps, [.warp(CGPoint(x: 2020, y: 1020)),
                               .postHID(SyntheticEvent(kind: .scroll(dx: 0, dy: -8, pixels: true), location: CGPoint(x: 2020, y: 1020))),
                               .beginHandoff(.scroll)])
        let end = session.endHandoff(cursorNow: CGPoint(x: 2020, y: 1020), mapping: mapping, mirrorRect: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(end, [.warp(CGPoint(x: 10, y: 10)), .endHandoff(.scroll)], "активность не менялась — и возвращать нечего")
    }

    func testPidModesPostToProcess() {
        var session = PointerSession(clickMode: .pid, scrollMode: .pid)
        _ = session.down(.left, at: CGPoint(x: 100, y: 50), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor)
        XCTAssertEqual(session.dragged(to: CGPoint(x: 150, y: 50), mapping: mapping), [], "перетаскивание через postToPid не поддерживается")
        XCTAssertEqual(session.up(mapping: mapping, windowNumber: 7).map { step -> Bool in
            if case let .postToPid(event) = step { return event.windowNumber == 7 }
            return false
        }, [true, true])
        let scroll = session.scroll(dx: 0, dy: 1, precise: true, at: CGPoint(x: 1, y: 1), mapping: mapping, windowNumber: 7)
        XCTAssertEqual(scroll.count, 1)
        if case .postToPid = scroll[0] {} else { XCTFail("прокрутка в процесс") }
    }

    func testReturnPointIsClampedToMirror() {
        let point = PointerSession.returnPoint(CGPoint(x: 5000, y: -10), mapping: mapping, mirrorRect: CGRect(x: 100, y: 100, width: 400, height: 300))
        XCTAssertEqual(point, CGPoint(x: 499, y: 100))
    }
}

final class HandoffWatchTests: XCTestCase {
    func testDragEndsOnButtonUpOrSafetyLimit() {
        var watch = HandoffWatch(kind: .drag, at: 100)
        XCTAssertFalse(watch.shouldEnd(at: 105))
        watch.noteButtonUp()
        XCTAssertTrue(watch.shouldEnd(at: 105))
        XCTAssertTrue(HandoffWatch(kind: .drag, at: 0).shouldEnd(at: 121))
    }

    func testScrollEndsAfterIdle() {
        var watch = HandoffWatch(kind: .scroll, at: 0)
        watch.noteActivity(at: 0.3)
        XCTAssertFalse(watch.shouldEnd(at: 0.6))
        XCTAssertTrue(watch.shouldEnd(at: 0.66))
    }

    func testMenuEndsWhenMenuGoneOrNeverAppeared() {
        let watch = HandoffWatch(kind: .menu, at: 0)
        XCTAssertFalse(watch.shouldEnd(at: 0.5))
        XCTAssertTrue(watch.shouldEnd(at: 1.0), "меню не появилось — курсор назад")

        var open = HandoffWatch(kind: .menu, at: 0)
        open.noteMenu(visible: true, at: 0.1)
        XCTAssertFalse(open.shouldEnd(at: 5))
        open.noteMenu(visible: false, at: 5)
        XCTAssertFalse(open.shouldEnd(at: 5.1), "подменю перерисовывается — подождать")
        open.noteMenu(visible: true, at: 5.1)
        open.noteMenu(visible: false, at: 6)
        XCTAssertTrue(open.shouldEnd(at: 6.2))
        var stuck = HandoffWatch(kind: .menu, at: 0)
        stuck.noteMenu(visible: true, at: 0.1)
        XCTAssertTrue(stuck.shouldEnd(at: 61), "предохранитель")
    }
}

final class HiddenScreenOptionsTests: XCTestCase {
    func testAppsFromStoredIDsMergeKnownOnes() {
        XCTAssertEqual(HiddenScreenOptions.apps(fromBundleIDs: nil), [.claude, .chatGPT])
        let apps = HiddenScreenOptions.apps(fromBundleIDs: ["com.openai.chat", "com.openai.codex", "com.example.app", ""])
        XCTAssertEqual(apps, [.chatGPT, HiddenApp(name: "com.example.app", bundleIDs: ["com.example.app"])])
        XCTAssertEqual(HiddenScreenOptions.apps(fromBundleIDs: []), [], "пустой список — пользователь убрал всё")
    }

    func testDebugArguments() {
        XCTAssertNil(HiddenScreenOptions.debug(arguments: ["MacUtils"], storedBundleIDs: nil))
        let options = HiddenScreenOptions.debug(arguments: ["MacUtils", "--hidden-screen-debug", "--hs-apps=com.anthropic.claudefordesktop",
                                                            "--hs-click=pid", "--hs-scroll=pid", "--hs-size=1280x800", "--hs-unknown=1"],
                                                storedBundleIDs: ["com.openai.chat"])
        XCTAssertEqual(options, HiddenScreenOptions(apps: [.claude], clickMode: .pid, scrollMode: .pid, displaySize: CGSize(width: 1280, height: 800)))
        let defaults = HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-size=99x99", "--hs-click=nope"], storedBundleIDs: nil)
        XCTAssertEqual(defaults, HiddenScreenOptions())
        let modes = HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-keys=hid", "--hs-press=mirror", "--hs-helper=off"],
                                              storedBundleIDs: nil)
        XCTAssertEqual(modes?.keyMode, .hid)
        XCTAssertEqual(modes?.pressMode, .mirror)
        XCTAssertEqual(modes?.useHelper, false)
        XCTAssertEqual(defaults?.keyMode, .active)
        XCTAssertEqual(defaults?.pressMode, .tap)
        XCTAssertEqual(defaults?.useHelper, true)
    }

    func testClipboardExport() {
        let file = URL(fileURLWithPath: "/tmp/x/отчёт.pdf")
        XCTAssertEqual(ClipboardExport.route(fileURLs: [file], types: ["public.png"], text: nil), .files([file]))
        XCTAssertEqual(ClipboardExport.route(fileURLs: [], types: ["public.tiff"], text: "a"), .image(type: "public.tiff"))
        XCTAssertEqual(ClipboardExport.route(fileURLs: [], types: [], text: "ответ"), .text("ответ"))
        XCTAssertEqual(ClipboardExport.route(fileURLs: [], types: [], text: nil), .nothing)
        let date = Date(timeIntervalSince1970: 1_763_062_315) // 2025-11-13 19:31:55 UTC
        XCTAssertEqual(ClipboardExport.imageFileName(at: date, timeZone: TimeZone(identifier: "UTC")!), "Изображение 2025-11-13 в 19.31.55.png")
    }
}

final class HidingCheckTests: XCTestCase {
    func checker() -> [HidingCheck.RGB] {
        (0..<16).map { HidingCheck.expected(row: $0 / 4, column: $0 % 4) }
    }

    func testVerdictIsUnambiguousForProbe() {
        XCTAssertEqual(HidingCheck.verdict(cells: checker()), false, "шахматка на снимке — окна с .none видно")
        XCTAssertEqual(HidingCheck.verdict(cells: Array(repeating: HidingCheck.RGB(240, 240, 240), count: 16)), true, "под пробой белый фон")
        XCTAssertEqual(HidingCheck.verdict(cells: Array(repeating: HidingCheck.RGB(250, 10, 250), count: 16)), true,
                       "сплошной пурпурный фон совпадает только с половиной клеток — не шахматка")
        // Цветовой профиль дисплея сдвигает насыщенные цвета, но клетки узнаются.
        let shifted = checker().map { HidingCheck.RGB($0.r == 255 ? 235 : 40, $0.g == 255 ? 228 : 60, $0.b == 255 ? 232 : 50) }
        XCTAssertEqual(HidingCheck.verdict(cells: shifted), false)
        var partly = checker()
        for i in 0..<8 { partly[i] = HidingCheck.RGB(255, 255, 255) }
        XCTAssertNil(HidingCheck.verdict(cells: partly), "половина пробы — не понять")
        XCTAssertNil(HidingCheck.verdict(cells: []))
    }

    func testProbeImageRoundTrip() throws {
        let image = try XCTUnwrap(HidingCheck.probeImage(scale: 2))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(HidingCheck.cellColors(image), checker(), "клетки читаются в том же порядке, в каком нарисованы")
        XCTAssertEqual(HidingCheck.verdict(cells: HidingCheck.cellColors(image)), false)
    }

    func testCropRect() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(HidingCheck.cropRect(CGRect(x: 100, y: 50, width: 32, height: 32), display: display, scale: 2),
                       CGRect(x: 200, y: 100, width: 64, height: 64))
        XCTAssertNil(HidingCheck.cropRect(CGRect(x: 1500, y: 0, width: 32, height: 32), display: display, scale: 2), "проба частично за краем")
    }
}

final class ShortcutTests: XCTestCase {
    let paste = PasteKeystroke.events()

    func testActiveModeActivatesWaitsAndReturns() {
        let steps = PointerSession().shortcut(paste, mode: .active)
        XCTAssertEqual(steps, [.activateTarget, .postToPid(paste[0]), .postToPid(paste[1]), .wait(PointerSession.shortcutSettle), .returnFocus])
    }

    func testHIDAndInactiveModes() {
        XCTAssertEqual(PointerSession().shortcut(paste, mode: .hid).filter { if case .postHID = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(PointerSession().shortcut(paste, mode: .inactive), [.postToPid(paste[0]), .postToPid(paste[1])])
        XCTAssertEqual(PointerSession().shortcut([], mode: .active), [])
    }

    func testDuringHandoffProgramIsAlreadyActive() {
        var session = PointerSession()
        let mapping = MirrorMapping(viewSize: CGSize(width: 400, height: 300), target: CGRect(x: 0, y: 0, width: 400, height: 300))
        _ = session.down(.right, at: CGPoint(x: 10, y: 10), clicks: 1, flags: [], mapping: mapping, windowNumber: 1, cursor: .zero)
        XCTAssertEqual(session.shortcut(paste, mode: .active), [.postToPid(paste[0]), .postToPid(paste[1])])
    }
}

final class HiddenWindowRulesExtraTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let hidden = CGRect(x: 1512, y: 982, width: 1440, height: 900)

    func window(_ id: CGWindowID, _ frame: CGRect, layer: Int = 0) -> HiddenWindowInfo {
        HiddenWindowInfo(id: id, pid: 10, bundleID: "com.anthropic.claudefordesktop", frame: frame, layer: layer)
    }

    func testFloatingPanelsMoveMenusLeak() {
        let plan = HiddenWindowRules.plan(windows: [window(1, CGRect(x: 600, y: 300, width: 500, height: 80), layer: 3),
                                                    window(2, CGRect(x: 600, y: 300, width: 200, height: 300), layer: 101)],
                                          apps: [.claude], hidden: hidden, physical: [main])
        XCTAssertEqual(plan, [.move(1, to: CGPoint(x: 2112, y: 1282)), .leak(2, layer: 101)])
    }

    func testMenuDetectionAndCounts() {
        let windows = [window(1, CGRect(x: 1600, y: 1000, width: 800, height: 600)),
                       window(2, CGRect(x: 1700, y: 1100, width: 200, height: 300), layer: 101),
                       window(3, CGRect(x: 10, y: 10, width: 500, height: 400))]
        XCTAssertTrue(HiddenWindowRules.hasMenu(windows: windows, pid: 10, hidden: hidden))
        XCTAssertFalse(HiddenWindowRules.hasMenu(windows: windows, pid: 11, hidden: hidden))
        XCTAssertEqual(HiddenWindowRules.hiddenWindowCount(windows: windows, app: .claude, hidden: hidden), 1)
    }

    func testRestoreOrigin() {
        let remembered = CGRect(x: 100, y: 80, width: 800, height: 600)
        XCTAssertEqual(HiddenWindowRules.restoreOrigin(remembered: remembered, current: .zero, hidden: hidden, physical: [main]), remembered.origin)
        // Дисплея, где окно было, больше нет — то же место относительно скрытого, на первом настоящем.
        let gone = CGRect(x: -2000, y: 0, width: 800, height: 600)
        XCTAssertEqual(HiddenWindowRules.restoreOrigin(remembered: gone, current: CGRect(x: 1612, y: 1082, width: 800, height: 600),
                                                       hidden: hidden, physical: [main]), CGPoint(x: 100, y: 100))
        XCTAssertNil(HiddenWindowRules.restoreOrigin(remembered: nil, current: .zero, hidden: hidden, physical: []))
    }

    /// Окна с Mac Utils 13.11: ChatGPT 20199 1280×820 @0,39 и Claude 20169 1217×724 @208,147.
    func testPickAXWindowFallbacks() {
        let claude = CGRect(x: 208, y: 147, width: 1217, height: 724)
        // Номер отдался — по номеру, даже если рамка у AX чуть другая.
        XCTAssertEqual(HiddenWindowRules.pickAXWindow(id: 20169, frame: claude, candidates: [(20000, claude), (20169, claude.offsetBy(dx: 0, dy: 3))]), 1)
        // Номера нет — по рамке.
        XCTAssertEqual(HiddenWindowRules.pickAXWindow(id: 20169, frame: claude, candidates: [(nil, CGRect(x: 0, y: 0, width: 300, height: 200)), (nil, claude)]), 1)
        // Рамка у AX сдвинута (тень, строка заголовка), но размер тот же и такое окно одно.
        XCTAssertEqual(HiddenWindowRules.pickAXWindow(id: 20169, frame: claude, candidates: [(nil, claude.offsetBy(dx: 0, dy: 28)), (nil, CGRect(x: 0, y: 0, width: 300, height: 200))]), 0)
        // Единственное окно программы без номера.
        XCTAssertEqual(HiddenWindowRules.pickAXWindow(id: 20199, frame: CGRect(x: 0, y: 39, width: 1280, height: 820), candidates: [(nil, CGRect(x: 0, y: 25, width: 1280, height: 834))]), 0)
        // У окна свой, другой номер — не подменяем чужим.
        XCTAssertNil(HiddenWindowRules.pickAXWindow(id: 20199, frame: claude, candidates: [(31, CGRect(x: 0, y: 0, width: 10, height: 10))]))
        XCTAssertNil(HiddenWindowRules.pickAXWindow(id: 1, frame: claude, candidates: []))
    }

    func testArrived() {
        XCTAssertTrue(HiddenWindowRules.arrived(CGRect(x: 1918, y: 1220, width: 10, height: 10), at: CGPoint(x: 1919, y: 1221)))
        XCTAssertFalse(HiddenWindowRules.arrived(CGRect(x: 208, y: 147, width: 10, height: 10), at: CGPoint(x: 1918, y: 1220)), "AX ответил «успех», а окно на месте")
        XCTAssertFalse(HiddenWindowRules.arrived(nil, at: .zero))
    }

    func testQuartzFromCocoa() {
        XCTAssertEqual(HiddenScreenGeometry.quartz(fromCocoa: CGRect(x: 100, y: 82, width: 400, height: 300), primaryHeight: 982),
                       CGRect(x: 100, y: 600, width: 400, height: 300))
    }
}
