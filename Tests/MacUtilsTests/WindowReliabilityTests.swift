import CoreGraphics
import XCTest
@testable import MacUtils

/// Чистая логика пакета 6: переключатель окон, перетаскивание к краю, «Поверх всех», «Фокус», служебные события tap.
@MainActor
final class WindowReliabilityTests: XCTestCase {
    // MARK: EventTap

    func testDisableEventsAreRecognised() {
        XCTAssertTrue(EventTap.isDisableEvent(.tapDisabledByTimeout))
        XCTAssertTrue(EventTap.isDisableEvent(.tapDisabledByUserInput))
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .scrollWheel] {
            XCTAssertFalse(EventTap.isDisableEvent(type), "\(type.rawValue)")
        }
    }

    func testTapCanBeCreatedAsListenOnlyWithResetHandler() {
        var resets = 0
        let tap = EventTap(types: [.leftMouseDown], listenOnly: true) { _, _ in true }
        tap.onDisabled = { resets += 1 }
        XCTAssertFalse(tap.isRunning, "tap не стартует сам")
        tap.onDisabled?()
        XCTAssertEqual(resets, 1)
    }

    // MARK: AppSwitcher

    func testSelectionStaysOnSameWindowAfterRefresh() {
        XCTAssertEqual(SwitcherSelection.index(keeping: "w2", in: ["w9", "w1", "w2"], fallback: 1), 2, "окно сдвинулось — выбор следует за ним")
        XCTAssertEqual(SwitcherSelection.index(keeping: "w2", in: ["w2", "w1"], fallback: 1), 0)
    }

    func testSelectionFallsBackAndStaysInBounds() {
        XCTAssertEqual(SwitcherSelection.index(keeping: "gone", in: ["a", "b", "c"], fallback: 5), 2, "окно закрылось — индекс зажимается")
        XCTAssertEqual(SwitcherSelection.index(keeping: nil, in: ["a", "b"], fallback: 1), 1)
        XCTAssertEqual(SwitcherSelection.index(keeping: "a", in: [], fallback: 3), 0)
        XCTAssertEqual(SwitcherSelection.index(keeping: nil, in: ["a"], fallback: -4), 0)
    }

    /// Быстрый черновик без Accessibility не должен ходить в AX и зависать (бюджет 0).
    func testQuickListDoesNotWaitForAccessibility() {
        let started = Date()
        _ = WindowList.collect(recent: [], apps: WindowList.snapshotApps(), axBudget: 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(WindowList.axBudget, 1.0)
    }

    // MARK: Перетаскивание к краю (W1)

    func testTitleBarPoint() {
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        XCTAssertTrue(WindowDragRules.isTitleBarPoint(CGPoint(x: 300, y: 210), in: frame))
        XCTAssertTrue(WindowDragRules.isTitleBarPoint(CGPoint(x: 300, y: 239), in: frame))
        XCTAssertTrue(WindowDragRules.isTitleBarPoint(CGPoint(x: 300, y: 295), in: frame))
        XCTAssertFalse(WindowDragRules.isTitleBarPoint(CGPoint(x: 300, y: 296), in: frame))
        XCTAssertFalse(WindowDragRules.isTitleBarPoint(CGPoint(x: 300, y: 500), in: frame))
    }

    /// Высокие панели macOS 27 (замер стенда): нажатие в нижней части панели — тоже заголовок. В 1.6.8 (40 pt) нет.
    func testTallToolbarsOfMacOS27CountAsTitleBar() {
        let frame = CGRect(x: 0, y: 100, width: 900, height: 700)
        for bar: CGFloat in [32, 40, 52, 66, 83, 88] {
            XCTAssertTrue(WindowDragRules.isTitleBarPoint(CGPoint(x: 450, y: 100 + bar - 6), in: frame), "панель \(bar) pt")
        }
    }

    func testMoveSourceFallsBackToWindowServer() {
        let start = CGRect(x: 100, y: 100, width: 500, height: 400)
        let moved = CGRect(x: 180, y: 140, width: 500, height: 400)
        XCTAssertEqual(WindowDragRules.moveSource(start: start, now: moved, startBounds: start, nowBounds: moved), .ax)
        XCTAssertEqual(WindowDragRules.moveSource(start: start, now: start, startBounds: start, nowBounds: moved), .windowServer,
                       "программа ещё не знает нового места, WindowServer окно уже двигает")
        XCTAssertNil(WindowDragRules.moveSource(start: start, now: start, startBounds: start, nowBounds: start))
        XCTAssertNil(WindowDragRules.moveSource(start: start, now: nil, startBounds: nil, nowBounds: nil))
        XCTAssertNil(WindowDragRules.moveSource(start: start, now: CGRect(x: 90, y: 100, width: 510, height: 400),
                                                startBounds: start, nowBounds: CGRect(x: 90, y: 100, width: 510, height: 400)),
                     "тянут за левый край — меняют размер")
    }

    /// Курсор, прижатый к верхнему краю основного экрана: в Cocoa y == maxY — экран находится, зона «весь экран».
    func testCursorPinnedToTopEdgeFindsScreen() {
        let primary = NSRect(x: 0, y: 0, width: 1710, height: 1112)
        let second = NSRect(x: 1710, y: -34, width: 1135, height: 789)
        XCTAssertEqual(WindowDragRules.screenIndex(containing: NSPoint(x: 800, y: primary.maxY), frames: [primary, second]), 0)
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 800, y: primary.maxY), in: primary, screens: [primary, second]), .maximize)
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 0, y: primary.maxY), in: primary, screens: [primary, second]), .topLeft)
        XCTAssertEqual(WindowDragRules.screenIndex(containing: NSPoint(x: 2000, y: 400), frames: [primary, second]), 1)
        XCTAssertEqual(WindowDragRules.screenIndex(containing: NSPoint(x: 2844, y: 755), frames: [primary, second]), 1, "правый верх второго")
        XCTAssertNil(WindowDragRules.screenIndex(containing: NSPoint(x: 2000, y: 900), frames: [primary, second]))
    }

    /// Два монитора (раскладка стенда): общий край — не край прилипания, свободные края второго монитора — края.
    func testSharedEdgeBetweenMonitorsIsNotASnapEdge() {
        let primary = NSRect(x: 0, y: 0, width: 1710, height: 1112)
        let second = NSRect(x: 1710, y: -34, width: 1135, height: 789)
        let screens = [primary, second]
        XCTAssertNil(WindowTiler.zone(for: NSPoint(x: 1709, y: 500), in: primary, screens: screens), "курсор уходит на второй монитор")
        XCTAssertNil(WindowTiler.zone(for: NSPoint(x: 1710, y: 400), in: second, screens: screens))
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 1709, y: 1000), in: primary, screens: screens), .right,
                       "выше второго монитора правый край основного свободен")
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 2844, y: 400), in: second, screens: screens), .right)
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 2844, y: 754), in: second, screens: screens), .topRight)
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 2000, y: 755), in: second, screens: screens), .maximize)
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 1710, y: -30), in: second, screens: screens), .bottomLeft,
                       "ниже основного левый край второго свободен")
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 0, y: 500), in: primary, screens: screens), .left)
        // Монитор сверху: верх основного — общий край.
        let above = NSRect(x: 200, y: 1112, width: 1920, height: 1080)
        XCTAssertNil(WindowTiler.zone(for: NSPoint(x: 800, y: 1111), in: primary, screens: [primary, above]))
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 40, y: 1111), in: primary, screens: [primary, above]), .topLeft,
                       "левее верхнего монитора верх свободен")
        let s = WindowDragRules.sharedEdges(of: primary, at: NSPoint(x: 1709, y: 500), screens: screens)
        XCTAssertTrue(s.right)
        XCTAssertFalse(s.left || s.top || s.bottom)
    }

    func testCocoaAndAXPointsRoundTrip() {
        let p = CGPoint(x: 123, y: 45)
        XCTAssertEqual(WindowTiler.axPoint(fromCocoa: WindowTiler.cocoaPoint(fromAX: p)), p)
    }

    func testMoveDragNeedsMovedOriginAndSameSize() {
        let start = CGRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertTrue(WindowDragRules.isMoveDrag(start: start, now: CGRect(x: 150, y: 120, width: 500, height: 400)))
        XCTAssertFalse(WindowDragRules.isMoveDrag(start: start, now: start), "не двигалось")
        XCTAssertFalse(WindowDragRules.isMoveDrag(start: start, now: CGRect(x: 100, y: 100, width: 520, height: 400)), "тянут за край: размер изменился")
        XCTAssertFalse(WindowDragRules.isMoveDrag(start: start, now: CGRect(x: 90, y: 100, width: 520, height: 400)))
        XCTAssertTrue(WindowDragRules.isMoveDrag(start: start, now: CGRect(x: 101, y: 100, width: 500.5, height: 399.5)), "дробные доли размера не мешают")
    }

    func testEdgeZones() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 0, y: 400), in: screen), .left)
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 999, y: 400), in: screen), .right)
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 500, y: 799), in: screen), .maximize)
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 0, y: 790), in: screen), .topLeft)
        XCTAssertEqual(WindowTiler.zone(for: NSPoint(x: 999, y: 5), in: screen), .bottomRight)
        XCTAssertNil(WindowTiler.zone(for: NSPoint(x: 500, y: 400), in: screen))
    }

    // MARK: «Поверх всех» (W3, W4)

    func testPinFrameRateDropsWhileHidden() {
        XCTAssertEqual(PinFrameRate.fps(hidden: false), 30)
        XCTAssertEqual(PinFrameRate.fps(hidden: true), 1)
        XCTAssertLessThan(PinFrameRate.hiddenFPS, PinFrameRate.visibleFPS)
    }

    /// W3: закрепление, снятое до конца запуска, не должно оставлять копию.
    func testStoppedPinIsMarkedSoStartCanBail() {
        let pin = PinnedWindow(windowID: 1, element: AXUIElementCreateSystemWide(), app: NSRunningApplication.current)
        XCTAssertFalse(pin.isStopped)
        pin.stop()
        XCTAssertTrue(pin.isStopped)
    }

    // MARK: Фокус

    private func window(_ number: Int, pid: pid_t, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer]
    }

    func testLowestFrontWindowTakesChainOfTargetWindowsOnTop() {
        let list = [window(1, pid: 10), window(2, pid: 10), window(3, pid: 20), window(4, pid: 10)]
        XCTAssertEqual(FocusWindows.lowestFront(in: list, pid: 10, ownPID: 99), 2, "цепочка прерывается чужим окном")
    }

    func testLowestFrontWindowSkipsOwnAndNonZeroLayers() {
        let list = [window(1, pid: 99), window(2, pid: 20, layer: 25), window(3, pid: 10), window(4, pid: 99), window(5, pid: 10)]
        XCTAssertEqual(FocusWindows.lowestFront(in: list, pid: 10, ownPID: 99), 5, "свои окна и панели не разрывают цепочку")
    }

    func testLowestFrontWindowNilWhenTargetHasNoOrdinaryWindow() {
        XCTAssertNil(FocusWindows.lowestFront(in: [], pid: 10, ownPID: 99))
        // Чужое окно впереди цепочку не обрывает (она ещё не началась): активность программы проверяется отдельно, как и раньше.
        XCTAssertEqual(FocusWindows.lowestFront(in: [window(1, pid: 20), window(2, pid: 10)], pid: 10, ownPID: 99), 2)
        XCTAssertNil(FocusWindows.lowestFront(in: [window(1, pid: 10, layer: 3)], pid: 10, ownPID: 99))
        XCTAssertEqual(FocusWindows.lowestFront(in: [window(7, pid: 10)], pid: 10, ownPID: 99), 7)
    }

    func testFocusPollingOnlyWhileTargetIsFront() {
        XCTAssertNil(FocusPolling.interval(targetIsFront: false, hasWindow: true), "работаете в другой программе — опроса нет")
        XCTAssertNil(FocusPolling.interval(targetIsFront: false, hasWindow: false))
        XCTAssertEqual(FocusPolling.interval(targetIsFront: true, hasWindow: true), 0.5)
        XCTAssertEqual(FocusPolling.interval(targetIsFront: true, hasWindow: false), 1)
        XCTAssertGreaterThan(FocusPolling.activeInterval, 0.25, "реже прежних четырёх раз в секунду")
    }

    // MARK: ⌥Tab по свежему порядку окон (ревью пакета 6, MAJOR-1)

    private struct W: Equatable {
        let id: String
        var background = false
    }

    private func merge(draft: [W], cached: [W], seen: Set<String>) -> [W] {
        SwitcherMerge.merge(draft: draft, cached: cached, seen: seen, id: \.id, isBackground: \.background)
    }

    /// Кэш [A, B], но пользователь кликом перешёл в B: CG говорит [B, A]. ⌥Tab должен вести к A, а не обратно в B.
    func testClickBetweenWindowsReordersStaleCache() {
        let a = W(id: "wA"), b = W(id: "wB")
        let merged = merge(draft: [b, a], cached: [a, b], seen: ["wA", "wB"])
        XCTAssertEqual(merged, [b, a])
        // Стартовый индекс при открытии — второй пункт (как системный ⌘Tab): это A.
        XCTAssertEqual(merged[1], a)
    }

    func testCachedDetailsAreKeptForKnownWindows() {
        var richer = W(id: "wA")
        richer.background = false
        let merged = SwitcherMerge.merge(draft: ["wA"], cached: ["wA-cached-marker"], seen: ["wA"], id: { $0.hasPrefix("wA") ? "wA" : $0 },
                                         isBackground: { _ in false })
        XCTAssertEqual(merged, ["wA-cached-marker"], "для известного окна берётся запись из кэша (заголовок, AX-окно)")
        _ = richer
    }

    func testNewWindowIsAddedButRejectedOnesAreNot() {
        let a = W(id: "wA"), fresh = W(id: "wNew"), palette = W(id: "wPalette")
        // wPalette CG видел при прошлом сборе, а в кэше его нет: Accessibility отсеял.
        let merged = merge(draft: [fresh, palette, a], cached: [a], seen: ["wA", "wPalette"])
        XCTAssertEqual(merged, [fresh, a])
    }

    func testClosedVisibleWindowIsDroppedButMinimizedAndHiddenStay() {
        let open = W(id: "wOpen"), closed = W(id: "wClosed")
        let minimized = W(id: "wMin", background: true)
        let merged = merge(draft: [open], cached: [closed, minimized, open], seen: ["wOpen", "wClosed"])
        XCTAssertEqual(merged, [open, minimized], "закрытое пропало, свёрнутое осталось после видимых")
    }

    func testBackgroundWindowAlreadyInDraftIsNotDuplicated() {
        let a = W(id: "wA", background: true)
        XCTAssertEqual(merge(draft: [W(id: "wA")], cached: [a], seen: ["wA"]), [a])
    }

    func testEmptyDraftKeepsOnlyBackgroundWindows() {
        let visible = W(id: "wV"), minimized = W(id: "wM", background: true)
        XCTAssertEqual(merge(draft: [], cached: [visible, minimized], seen: ["wV"]), [minimized])
        XCTAssertEqual(merge(draft: [], cached: [], seen: []), [])
    }

    // MARK: - Чьё окно под курсором (сбой 1.5.0: AX-запрос в свой процесс из фона)

    private typealias SW = WindowDragRules.ScreenWindow
    private let me: pid_t = 100

    func testClickOnOwnWindowIsSkipped() {
        let windows = [SW(number: 1, pid: me, layer: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 300)),
                       SW(number: 2, pid: 200, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertNil(WindowDragRules.ownerUnder(CGPoint(x: 10, y: 10), windows: windows, ownPID: me, ownWindows: [1]),
                     "клик по нашим настройкам — без AX-запроса к своему процессу")
    }

    func testOwnPopoverAboveMenuBarIsSkipped() {
        let windows = [SW(number: 5, pid: me, layer: 101, bounds: CGRect(x: 1000, y: 30, width: 446, height: 546)),
                       SW(number: 2, pid: 200, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1800, height: 1000))]
        XCTAssertNil(WindowDragRules.ownerUnder(CGPoint(x: 1100, y: 40), windows: windows, ownPID: me, ownWindows: [5]))
    }

    func testOwnPassThroughOverlayIsLookedUnder() {
        let windows = [SW(number: 9, pid: me, layer: 1000, bounds: CGRect(x: 0, y: 0, width: 1800, height: 1000)),
                       SW(number: 2, pid: 200, layer: 0, bounds: CGRect(x: 100, y: 100, width: 800, height: 600))]
        XCTAssertEqual(WindowDragRules.ownerUnder(CGPoint(x: 150, y: 110), windows: windows, ownPID: me, ownWindows: []), 200,
                       "тёплый экран или рисование сквозь клики не мешают раскладке окон")
    }

    func testTransparentForeignWindowIsLookedUnder() {
        let windows = [SW(number: 3, pid: 300, layer: 0, alpha: 0, bounds: CGRect(x: 0, y: 0, width: 1800, height: 1000)),
                       SW(number: 2, pid: 200, layer: 0, bounds: CGRect(x: 100, y: 100, width: 800, height: 600))]
        XCTAssertEqual(WindowDragRules.ownerUnder(CGPoint(x: 150, y: 110), windows: windows, ownPID: me, ownWindows: []), 200)
    }

    func testMenusAndPanelsOfOtherAppsAreSkipped() {
        let windows = [SW(number: 4, pid: 300, layer: 25, bounds: CGRect(x: 100, y: 100, width: 200, height: 200)),
                       SW(number: 2, pid: 200, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertNil(WindowDragRules.ownerUnder(CGPoint(x: 150, y: 150), windows: windows, ownPID: me, ownWindows: []))
    }

    func testFloatingWindowOfOtherAppIsDraggable() {
        let windows = [SW(number: 8, pid: 300, layer: 3, bounds: CGRect(x: 100, y: 100, width: 200, height: 200))]
        XCTAssertEqual(WindowDragRules.ownerUnder(CGPoint(x: 150, y: 110), windows: windows, ownPID: me, ownWindows: []), 300)
    }

    func testFrontmostForeignWindowWins() {
        let windows = [SW(number: 7, pid: 300, layer: 0, bounds: CGRect(x: 100, y: 100, width: 200, height: 200)),
                       SW(number: 2, pid: 200, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertEqual(WindowDragRules.ownerUnder(CGPoint(x: 150, y: 150), windows: windows, ownPID: me, ownWindows: []), 300)
        XCTAssertEqual(WindowDragRules.ownerUnder(CGPoint(x: 500, y: 500), windows: windows, ownPID: me, ownWindows: []), 200)
        XCTAssertNil(WindowDragRules.ownerUnder(CGPoint(x: 900, y: 900), windows: windows, ownPID: me, ownWindows: []))
    }

    func testScreenWindowParsesWindowServerInfo() {
        let info: [String: Any] = [kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 7, kCGWindowLayer as String: 0,
                                   kCGWindowAlpha as String: 1.0,
                                   kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 3, height: 4).dictionaryRepresentation]
        XCTAssertEqual(SW(info), SW(number: 42, pid: 7, layer: 0, alpha: 1, bounds: CGRect(x: 1, y: 2, width: 3, height: 4)))
        XCTAssertNil(SW([:]))
    }
}
