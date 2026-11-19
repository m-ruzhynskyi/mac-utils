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

    func testReadinessNeedsAutohide() {
        XCTAssertEqual(DockAway.readiness(enabled: true, autohide: true), .ready)
        XCTAssertEqual(DockAway.readiness(enabled: true, autohide: false), .unavailable(DockAway.noAutohideReason),
                       "без автоскрытия Dock виден всегда — сторож края не поможет")
        XCTAssertEqual(DockAway.readiness(enabled: true, autohide: nil), .unavailable(DockAway.noAutohideReason))
        XCTAssertEqual(DockAway.readiness(enabled: false, autohide: true), .disabled)
    }

    func testCursorStaysOffBottomDockEdge() {
        // Основной экран и скрытый дисплей за углом (нижние 40 pt правого края).
        let hidden = CGRect(x: 1710, y: 1072, width: 1440, height: 900)
        let displays = [main]
        XCTAssertEqual(DockEdgeGuard.clamp(CGPoint(x: 800, y: 1111), edge: .bottom, displays: displays, neighbours: displays + [hidden]),
                       CGPoint(x: 800, y: 1112 - DockEdgeGuard.margin), "у нижнего края — назад на 3 pt: Dock не выезжает")
        XCTAssertNil(DockEdgeGuard.clamp(CGPoint(x: 800, y: 1000), edge: .bottom, displays: displays, neighbours: displays + [hidden]))
        XCTAssertNil(DockEdgeGuard.clamp(CGPoint(x: 800, y: 1109), edge: .bottom, displays: displays, neighbours: displays + [hidden]),
                     "уже в 3 pt от края — не трогаем")
    }

    func testSidesAndOtherMonitors() {
        let sidecar = CGRect(x: -1135, y: 106, width: 1135, height: 789)
        let displays = [main, sidecar]
        // Низ Sidecar тоже свободен — и там курсор не доходит до края (HSCR-44: «на других мониторах Dock выезжает»).
        XCTAssertEqual(DockEdgeGuard.clamp(CGPoint(x: -500, y: 894), edge: .bottom, displays: displays, neighbours: displays),
                       CGPoint(x: -500, y: 895 - DockEdgeGuard.margin))
        // Dock слева: левый край основного экрана граничит с Sidecar (106…895) — там курсор проходит на Sidecar.
        XCTAssertNil(DockEdgeGuard.clamp(CGPoint(x: 0.5, y: 500), edge: .left, displays: displays, neighbours: displays))
        XCTAssertEqual(DockEdgeGuard.clamp(CGPoint(x: 0.5, y: 1000), edge: .left, displays: displays, neighbours: displays),
                       CGPoint(x: DockEdgeGuard.margin, y: 1000), "ниже Sidecar край основного экрана свободен")
        XCTAssertEqual(DockEdgeGuard.clamp(CGPoint(x: 1709, y: 500), edge: .right, displays: [main], neighbours: [main]),
                       CGPoint(x: 1710 - DockEdgeGuard.margin, y: 500))
    }

    func testFreeSegments() {
        let below = CGRect(x: 200, y: 1112, width: 600, height: 400)
        XCTAssertEqual(DockEdgeGuard.freeSegments(main, edge: .bottom, neighbours: [main, below]), [0...200, 800...1710])
        XCTAssertEqual(DockEdgeGuard.freeSegments(main, edge: .bottom, neighbours: [CGRect(x: -100, y: 1112, width: 2000, height: 10)]), [],
                       "край целиком закрыт соседом — Dock там не выедет, курсор не держим")
        XCTAssertEqual(DockEdgeGuard.freeSegments(main, edge: .bottom, neighbours: []), [0...1710])
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

    func testBackgroundClickTriesAXThenWarp() {
        var session = PointerSession()
        XCTAssertEqual(session.clickMode, .background)
        _ = session.down(.left, at: CGPoint(x: 100, y: 50), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor)
        let planned = session.up(mapping: mapping, windowNumber: 7)
        let target = CGPoint(x: 2200, y: 1100)
        var warp = PointerSession(clickMode: .warp)
        _ = warp.down(.left, at: CGPoint(x: 100, y: 50), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor)
        let warpSteps = warp.up(mapping: mapping, windowNumber: 7)
        XCTAssertEqual(planned, [.accessibilityClick(target, fallback: warpSteps)],
                       "сначала через AX (без активации); не вышло — как в 1.11.0, путь warp (HSCR-46)")
        XCTAssertTrue(warpSteps.contains(.activateTarget), "запасной путь доходит наверняка — с активацией")
        XCTAssertEqual(session.state, .idle)
    }

    func testBackgroundDoubleClickGoesWarpWithCount() {
        var session = PointerSession()
        _ = session.down(.left, at: CGPoint(x: 10, y: 10), clicks: 2, flags: .maskShift, mapping: mapping, windowNumber: 9, cursor: cursor)
        let steps = session.up(mapping: mapping, windowNumber: 9)
        XCTAssertFalse(steps.contains { if case .accessibilityClick = $0 { return true }; return false })
        let posts = steps.compactMap { step -> SyntheticEvent? in
            if case let .postHID(event) = step, event.kind != .moved { return event }
            return nil
        }
        XCTAssertEqual(posts.map(\.clicks), [2, 2], "двойной щелчок (выделить слово) — событиями HID пути warp")
        XCTAssertEqual(posts.map(\.flags), [.maskShift, .maskShift])
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

final class AXClickTests: XCTestCase {
    func testOnlyPlainSingleClicks() {
        XCTAssertTrue(AXClickTarget.applies(clicks: 1, flags: []))
        XCTAssertTrue(AXClickTarget.applies(clicks: 1, flags: .maskNonCoalesced), "служебные флаги не мешают")
        XCTAssertFalse(AXClickTarget.applies(clicks: 2, flags: []), "двойной — выделить слово, событиями")
        XCTAssertFalse(AXClickTarget.applies(clicks: 1, flags: .maskCommand), "⌘-щелчок по ссылке — событиями")
    }

    func testDoubleClickSkipsAX() {
        let mapping = MirrorMapping(viewSize: CGSize(width: 400, height: 300), target: CGRect(x: 2000, y: 1000, width: 800, height: 600))
        var session = PointerSession()
        _ = session.down(.left, at: CGPoint(x: 10, y: 10), clicks: 2, flags: [], mapping: mapping, windowNumber: 7, cursor: .zero)
        XCTAssertFalse(session.up(mapping: mapping, windowNumber: 7).contains { if case .accessibilityClick = $0 { return true }; return false })
    }

    func testFocusesTextFieldUpTheChain() {
        // Claude: щелчок в абзац внутри поля ввода (contenteditable) → AXTextArea выше по цепочке.
        let chain = [AXClickTarget.Node(role: "AXStaticText"), AXClickTarget.Node(role: "AXGroup", actions: ["AXPress"]),
                     AXClickTarget.Node(role: "AXTextArea", focusSettable: true), AXClickTarget.Node(role: "AXWebArea")]
        XCTAssertEqual(AXClickTarget.choose(chain)?.index, 2)
        XCTAssertEqual(AXClickTarget.choose(chain)?.action, .focus)
    }

    func testPressesButtonsAndLinks() {
        let button = [AXClickTarget.Node(role: "AXImage"), AXClickTarget.Node(role: "AXButton", actions: ["AXPress", "AXShowMenu"])]
        XCTAssertEqual(AXClickTarget.choose(button)?.action, .press)
        XCTAssertEqual(AXClickTarget.choose([AXClickTarget.Node(role: "AXLink", actions: ["AXPress"])])?.action, .press)
        XCTAssertNil(AXClickTarget.choose([AXClickTarget.Node(role: "AXButton")]), "без AXPress не нажать")
    }

    func testPlainTextFallsBackToEvents() {
        // Щелчок по тексту ответа: до веб-страницы ничего управляемого — событиями (выделение, курсор в тексте).
        let chain = [AXClickTarget.Node(role: "AXStaticText"), AXClickTarget.Node(role: "AXGroup", actions: ["AXPress"]),
                     AXClickTarget.Node(role: "AXWebArea"), AXClickTarget.Node(role: "AXTextArea", focusSettable: true)]
        XCTAssertNil(AXClickTarget.choose(chain), "выше веб-страницы не поднимаемся")
        XCTAssertNil(AXClickTarget.choose([AXClickTarget.Node(role: "AXTextArea", focusSettable: false)]), "поле, которому нельзя дать фокус")
    }
}

final class AXFieldNearTests: XCTestCase {
    let field = CGRect(x: 2218, y: 1793, width: 375, height: 36)

    func testFieldUnderGroupIsFound() {
        // ChatGPT (test15): под точкой — AXGroup, поле — среди потомков, точка в его рамке.
        let point = CGPoint(x: field.midX, y: field.midY)
        let candidates: [(role: String, frame: CGRect, focusSettable: Bool)] = [
            ("AXTextArea", CGRect(x: 2218, y: 900, width: 375, height: 36), true),
            ("AXTextArea", field, true),
        ]
        XCTAssertEqual(AXClickTarget.nearestField(point, candidates: candidates), 1)
    }

    func testToleranceAndSmallerWins() {
        let near = CGPoint(x: field.midX, y: field.maxY + 8)
        XCTAssertEqual(AXClickTarget.nearestField(near, candidates: [("AXTextArea", field, true)]), 0, "в пределах 10 pt — годится")
        let far = CGPoint(x: field.midX, y: field.maxY + 30)
        XCTAssertNil(AXClickTarget.nearestField(far, candidates: [("AXTextArea", field, true)]))
        let big = CGRect(x: 2000, y: 1700, width: 900, height: 300)
        let point = CGPoint(x: field.midX, y: field.midY)
        XCTAssertEqual(AXClickTarget.nearestField(point, candidates: [("AXTextArea", big, true), ("AXTextField", field, true)]), 1,
                       "оба содержат точку — меньшее")
    }

    func testOnlyFocusableTextRoles() {
        let point = CGPoint(x: field.midX, y: field.midY)
        XCTAssertNil(AXClickTarget.nearestField(point, candidates: [("AXGroup", field, true), ("AXTextArea", field, false)]))
    }
}

/// HSCR-47: Dock по намеренному жесту, замер perf, режим дерева AX.
final class PerfAndDwellTests: XCTestCase {
    func testDockNeedsHalfSecondOfPushing() {
        var dwell = DockEdgeDwell()
        XCTAssertEqual(dwell.decide(atEdge: true, distance: 1, now: 10), .clamp, "случайное касание — Dock не выезжает")
        XCTAssertEqual(dwell.decide(atEdge: true, distance: 1, now: 10.2), .clamp)
        XCTAssertEqual(dwell.decide(atEdge: true, distance: 1, now: 10.4), .clamp)
        XCTAssertEqual(dwell.decide(atEdge: true, distance: 1, now: 10.55), .pass(justReleased: true), "полсекунды нажима — пропускаем")
        XCTAssertEqual(dwell.decide(atEdge: true, distance: 1, now: 10.6), .pass(justReleased: false))
        XCTAssertEqual(dwell.decide(atEdge: false, distance: 30, now: 11), .pass(justReleased: false), "у Dock (≤ 40 pt) — не мешаем")
        XCTAssertEqual(dwell.decide(atEdge: false, distance: 300, now: 12), .clamp, "ушёл от края — сторож снова держит")
        XCTAssertEqual(dwell.decide(atEdge: true, distance: 1, now: 13), .clamp)
    }

    func testPauseInPushingRestarts() {
        var dwell = DockEdgeDwell()
        _ = dwell.decide(atEdge: true, distance: 1, now: 0)
        _ = dwell.decide(atEdge: true, distance: 1, now: 0.2)
        XCTAssertEqual(dwell.decide(atEdge: true, distance: 1, now: 0.9), .clamp, "перерыв 0,7 с — отсчёт заново")
        XCTAssertEqual(dwell.decide(atEdge: true, distance: 1, now: 1.2), .clamp)
        XCTAssertEqual(dwell.decide(atEdge: true, distance: 1, now: 1.45), .pass(justReleased: true), "0,55 с от нового начала")
    }

    func testDistanceToDockEdge() {
        let main = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        XCTAssertEqual(DockEdgeGuard.distance(CGPoint(x: 10, y: 1100), edge: .bottom, displays: [main]), 12)
        XCTAssertEqual(DockEdgeGuard.distance(CGPoint(x: 10, y: 100), edge: .left, displays: [main]), 10)
        XCTAssertEqual(DockEdgeGuard.distance(CGPoint(x: -10, y: 100), edge: .left, displays: [main]), .greatestFiniteMagnitude)
    }

    func testPercentileAndLine() {
        XCTAssertNil(PerfSample.percentile([], 0.5))
        XCTAssertEqual(PerfSample.percentile([5, 1, 3, 2, 4], 0.5), 3)
        XCTAssertEqual(PerfSample.percentile(Array(1...100).map(Double.init), 0.95), 95)
        let sample = PerfSample(seconds: 10, streamFrames: 580, shownFrames: 575, frameAges: [10, 12, 14, 40], guardDurations: [3, 4, 5],
                                cpu: [("Mac Utils", 12.4), ("Claude", 40)], framePixels: CGSize(width: 1800, height: 1400),
                                displayPoints: CGSize(width: 1440, height: 900))
        XCTAssertEqual(sample.line(phase: "как есть"),
                       "perf как есть: поток 58 к/с, показано 58 к/с, возраст кадра p50 12 мс p95 40 мс, сторож 0 выз/с p50 4 мкс p95 5 мкс, CPU Mac Utils 12%, Claude 40%; кадр 1800×1400 px, дисплей 1440×900 pt")
    }

    func testAXTreeModeFlag() {
        XCTAssertEqual(HiddenScreenOptions().axTree, .click, "дерево страницы — только к щелчку, потом выключается")
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-ax=off"], storedBundleIDs: nil)?.axTree, .off)
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-ax=show"], storedBundleIDs: nil)?.axTree, .show)
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-ax=bad"], storedBundleIDs: nil)?.axTree, .click)
    }

    func testScrollLoadVerdict() {
        XCTAssertEqual(PerfLoad.scrollVerdict(framesDuringScroll: 3),
                       "прокрутке нечего двигать (кадров за прокрутку 3) — фаза недоказательна", "короткий чат — честно в журнал")
        XCTAssertNil(PerfLoad.scrollVerdict(framesDuringScroll: 450))
    }

    @MainActor
    func testScrollLoadShape() {
        XCTAssertEqual(PerfLoad.scrollSeconds, 5, "5 с вверх и 5 с вниз")
        XCTAssertEqual(PerfLoad.rate, 60, "~60 событий/с, как колесо трекпада")
        XCTAssertGreaterThan(PerfLoad.moveSeconds, 0, "и отдельно движение курсора — наведение и сторож")
    }

    func testProcessFamilyIncludesSelf() {
        XCTAssertEqual(PerfMeter.family(getpid()).first, getpid())
        XCTAssertNotNil(PerfMeter.cpuSeconds(getpid()))
    }
}
