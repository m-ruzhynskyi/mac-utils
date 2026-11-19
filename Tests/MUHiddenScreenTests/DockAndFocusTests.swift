import AppKit
import CoreGraphics
@testable import MUHiddenScreen
import XCTest

/// HSCR-43: Dock не выезжает в звонке, дисплей не пересоздаётся, зеркало — обычное окно, щелчок без смены активной.
final class DockAwayTests: XCTestCase {
    /// Основной экран 1710×1112 (как на Mac пользователя).
    let main = CGRect(x: 0, y: 0, width: 1710, height: 1112)

    func testEdgeFromOrientation() {
        XCTAssertEqual(DockEdge(orientation: nil), .bottom)
        XCTAssertEqual(DockEdge(orientation: "left"), .left)
        XCTAssertEqual(DockEdge(orientation: "right"), .right)
        XCTAssertEqual(DockEdge(orientation: "weird"), .bottom)
    }

    func testDisplayIsAtLeastMainScreen() {
        XCTAssertEqual(DockAway.displaySize(base: CGSize(width: 1440, height: 900), main: main), CGSize(width: 1710, height: 1112))
        XCTAssertEqual(DockAway.displaySize(base: CGSize(width: 2560, height: 1440), main: main), CGSize(width: 2560, height: 1440))
        XCTAssertEqual(DockAway.displaySize(base: CGSize(width: 1440, height: 900), main: .null), CGSize(width: 1440, height: 900))
    }

    func testBottomDockGoesUnderMainScreen() {
        let size = CGSize(width: 1710, height: 1112)
        let plan = DockAway.plan(edge: .bottom, spansDisplays: false, main: main, others: [], size: size)
        XCTAssertEqual(plan, .place(CGPoint(x: 0, y: 1112)))
        XCTAssertTrue(DockAway.covers(edge: .bottom, hidden: CGRect(origin: CGPoint(x: 0, y: 1112), size: size), main: main))
        // Дисплей уже: край закрыт не весь — Dock мог бы выехать в незакрытой части.
        XCTAssertEqual(DockAway.plan(edge: .bottom, spansDisplays: false, main: main, others: [], size: CGSize(width: 1440, height: 1112)),
                       .unavailable(DockAway.tooSmallReason))
        XCTAssertFalse(DockAway.covers(edge: .bottom, hidden: CGRect(x: 100, y: 1112, width: 1710, height: 900), main: main))
        XCTAssertFalse(DockAway.covers(edge: .bottom, hidden: CGRect(x: 1710, y: 1072, width: 1710, height: 1112), main: main),
                       "за углом край Dock свободен")
    }

    func testSideDocks() {
        let size = CGSize(width: 1710, height: 1112)
        XCTAssertEqual(DockAway.plan(edge: .left, spansDisplays: false, main: main, others: [], size: size), .place(CGPoint(x: -1710, y: 0)))
        XCTAssertEqual(DockAway.plan(edge: .right, spansDisplays: false, main: main, others: [], size: size), .place(CGPoint(x: 1710, y: 0)))
        XCTAssertTrue(DockAway.covers(edge: .right, hidden: CGRect(x: 1710, y: 0, width: 1710, height: 1112), main: main))
        XCTAssertTrue(DockAway.covers(edge: .left, hidden: CGRect(x: -1710, y: -10, width: 1710, height: 1200), main: main))
    }

    func testUnavailableCasesAreHonest() {
        let size = CGSize(width: 1710, height: 1112)
        XCTAssertEqual(DockAway.plan(edge: .bottom, spansDisplays: true, main: main, others: [], size: size),
                       .unavailable(DockAway.spansDisplaysReason), "одно пространство на все дисплеи: Dock всегда на основном")
        let below = CGRect(x: 200, y: 1112, width: 1920, height: 1080)
        XCTAssertEqual(DockAway.plan(edge: .bottom, spansDisplays: false, main: main, others: [below], size: size),
                       .unavailable(DockAway.occupiedReason))
        // Монитор справа не мешает нижнему краю.
        let right = CGRect(x: 1710, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(DockAway.plan(edge: .bottom, spansDisplays: false, main: main, others: [right], size: size),
                       .place(CGPoint(x: 0, y: 1112)))
        XCTAssertEqual(DockAway.plan(edge: .right, spansDisplays: false, main: main, others: [right], size: size),
                       .unavailable(DockAway.occupiedReason))
    }

    func testDockOnHiddenDisplay() {
        let hidden = CGRect(x: 1710, y: 1072, width: 1710, height: 1112)
        XCTAssertTrue(DockAway.dockOn(hidden, dockFrames: [CGRect(x: 2000, y: 2100, width: 900, height: 80)]))
        XCTAssertFalse(DockAway.dockOn(hidden, dockFrames: [CGRect(x: 400, y: 1030, width: 900, height: 80)]))
        XCTAssertFalse(DockAway.dockOn(hidden, dockFrames: []), "Dock спрятан — не знаем, дисплей не трогаем")
    }

    func testOptionsFlags() {
        let defaults = HiddenScreenOptions()
        XCTAssertTrue(defaults.dockAway)
        XCTAssertTrue(defaults.keepWarm)
        XCTAssertEqual(defaults.clickMode, .background, "по умолчанию щелчок без активации")
        let options = HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-dock=keep", "--hs-warm=off", "--hs-click=warp"],
                                                storedBundleIDs: nil)
        XCTAssertEqual(options?.dockAway, false)
        XCTAssertEqual(options?.keepWarm, false)
        XCTAssertEqual(options?.clickMode, .warp)
        let back = HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-dock=away", "--hs-warm=on", "--hs-click=background"],
                                             storedBundleIDs: nil)
        XCTAssertEqual(back?.dockAway, true)
        XCTAssertEqual(back?.keepWarm, true)
        XCTAssertEqual(back?.clickMode, .background)
    }
}

final class MirrorLevelAndClickTests: XCTestCase {
    let mapping = MirrorMapping(viewSize: CGSize(width: 400, height: 300), target: CGRect(x: 2000, y: 1000, width: 800, height: 600))
    let cursor = CGPoint(x: 300, y: 200)

    func testMirrorIsNormalWindowUnlessOnTop() {
        XCTAssertEqual(MirrorLevel.level(onTop: false), .normal)
        XCTAssertEqual(MirrorLevel.level(onTop: true), .floating)
        XCTAssertEqual(MirrorLevel.onTopKey, HiddenScreenEngine.alwaysOnTopKey)
        let key = MirrorLevel.onTopKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { saved.map { UserDefaults.standard.set($0, forKey: key) } ?? UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(MirrorLevel.onTop, "по умолчанию — обычное окно")
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(MirrorLevel.onTop)
    }

    func testBackgroundClickNeverActivates() {
        var session = PointerSession()
        XCTAssertEqual(session.clickMode, .background)
        _ = session.down(.left, at: CGPoint(x: 100, y: 50), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor)
        let steps = session.up(mapping: mapping, windowNumber: 7)
        let target = CGPoint(x: 2200, y: 1100)
        let origin = CGPoint(x: 2000, y: 1000)
        XCTAssertEqual(steps, [
            .hideCursor, .warp(target),
            .postHID(SyntheticEvent(kind: .moved, location: target)), .wait(PointerSession.hoverSettle),
            .postToPid(SyntheticEvent(kind: .leftDown, location: target, clicks: 1, windowNumber: 7, windowOrigin: origin)),
            .postToPid(SyntheticEvent(kind: .leftUp, location: target, clicks: 1, windowNumber: 7, windowOrigin: origin)),
            .wait(PointerSession.backgroundSettle), .warp(cursor), .showCursor,
        ])
        XCTAssertFalse(steps.contains(.activateTarget), "ИИ не активируется — программа пользователя не мигает")
        XCTAssertFalse(steps.contains(.returnFocus))
        XCTAssertFalse(steps.contains { if case let .postHID(event) = $0 { return event.kind == .leftDown || event.kind == .leftUp }; return false },
                       "нажатие через HID активировало бы программу (WindowServer)")
        XCTAssertEqual(session.state, .idle)
    }

    func testBackgroundDoubleClickKeepsCount() {
        var session = PointerSession()
        _ = session.down(.left, at: CGPoint(x: 10, y: 10), clicks: 2, flags: .maskShift, mapping: mapping, windowNumber: 9, cursor: cursor)
        let posts = session.up(mapping: mapping, windowNumber: 9).compactMap { step -> SyntheticEvent? in
            if case let .postToPid(event) = step { return event }
            return nil
        }
        XCTAssertEqual(posts.map(\.clicks), [2, 2])
        XCTAssertEqual(posts.map(\.flags), [.maskShift, .maskShift])
        XCTAssertTrue(posts.allSatisfy { $0.windowNumber == 9 && $0.windowOrigin != nil })
    }

    func testBackgroundDragAndMenuStillHandOff() {
        var session = PointerSession()
        _ = session.down(.left, at: CGPoint(x: 10, y: 10), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor)
        let drag = session.dragged(to: CGPoint(x: 60, y: 60), mapping: mapping)
        XCTAssertTrue(drag.contains(.beginHandoff(.drag)), "протягивание — прежней передачей курсора")
        var menu = PointerSession()
        let right = menu.down(.right, at: CGPoint(x: 10, y: 10), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor)
        XCTAssertTrue(right.contains(.beginHandoff(.menu)))
    }

    func testClickTraceWithoutChange() {
        let trace = ClickTrace(path: "background", before: "us.zoom.xos", started: 10)
        XCTAssertFalse(trace.blinked)
        XCTAssertEqual(trace.line(after: "us.zoom.xos"),
                       "щелчок: активная до us.zoom.xos, во время [—], после us.zoom.xos — без смены активной; путь background")
    }

    func testClickTraceShowsBlink() {
        var trace = ClickTrace(path: "warp", before: "com.apple.finder", started: 10)
        trace.note("com.anthropic.claudefordesktop", at: 10.012)
        trace.note("com.apple.finder", at: 10.096)
        trace.note("late", at: 12)
        XCTAssertTrue(trace.blinked)
        XCTAssertEqual(trace.changes.count, 2, "позже окна не считаем")
        XCTAssertEqual(trace.line(after: "com.apple.finder"),
                       "щелчок: активная до com.apple.finder, во время [+12 мс com.anthropic.claudefordesktop, +96 мс com.apple.finder], после com.apple.finder — мигание (смен 2); путь warp")
        let stuck = ClickTrace(path: "background", before: "com.apple.finder", started: 0)
        XCTAssertTrue(stuck.line(after: "com.anthropic.claudefordesktop").contains("мигание"), "активной осталась другая — тоже смена")
    }
}
