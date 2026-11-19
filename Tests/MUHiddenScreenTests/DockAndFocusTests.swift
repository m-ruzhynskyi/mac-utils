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

    func testBackgroundClickNeverActivates() {
        var session = PointerSession()
        XCTAssertEqual(session.clickMode, .background)
        _ = session.down(.left, at: CGPoint(x: 100, y: 50), clicks: 1, flags: [], mapping: mapping, windowNumber: 7, cursor: cursor)
        let planned = session.up(mapping: mapping, windowNumber: 7)
        let target = CGPoint(x: 2200, y: 1100)
        let origin = CGPoint(x: 2000, y: 1000)
        let events: [PointerStep] = [
            .hideCursor, .warp(target),
            .postHID(SyntheticEvent(kind: .moved, location: target)), .wait(PointerSession.hoverSettle),
            .postToPid(SyntheticEvent(kind: .leftDown, location: target, clicks: 1, windowNumber: 7, windowOrigin: origin)),
            .postToPid(SyntheticEvent(kind: .leftUp, location: target, clicks: 1, windowNumber: 7, windowOrigin: origin)),
            .wait(PointerSession.backgroundSettle), .warp(cursor), .showCursor,
        ]
        XCTAssertEqual(planned, [.accessibilityClick(target, fallback: events)],
                       "обычный щелчок — сначала через AX (фокус в поле, «нажать»), события — запасной путь")
        let steps = events
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
