import CoreGraphics
import Foundation
@testable import MUHiddenScreen
import XCTest

/// Только чистая логика: ни дисплеев, ни окон, ни событий, ни системного буфера.
final class HiddenScreenGeometryTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let right = CGRect(x: 1512, y: -200, width: 2560, height: 1440)

    func testHiddenDisplaySharesShortEdgeWithoutOverlap() {
        for displays in [[main], [main, right], [right, main]] {
            let size = CGSize(width: 1440, height: 900)
            let origin = HiddenScreenGeometry.cornerOrigin(size: size, beside: displays)
            let hidden = CGRect(origin: origin, size: size)
            for display in displays { XCTAssertFalse(display.intersects(hidden), "\(display) ∩ \(hidden)") }
            // Связная раскладка: общий край с одним дисплеем ровно 40 pt (не только угол — 13.11 при угле окна не переносились).
            XCTAssertEqual(displays.map { HiddenScreenGeometry.sharedEdgeLength($0, hidden) }.max(), HiddenScreenGeometry.sharedEdge)
        }
        XCTAssertEqual(HiddenScreenGeometry.cornerOrigin(size: CGSize(width: 10, height: 10), beside: [main]), CGPoint(x: 1512, y: 942))
        // Как на Mac пользователя 13.11: основной 1710×1112.
        XCTAssertEqual(HiddenScreenGeometry.cornerOrigin(size: CGSize(width: 1440, height: 900), beside: [CGRect(x: 0, y: 0, width: 1710, height: 1112)]),
                       CGPoint(x: 1710, y: 1072))
    }

    func testCornerOriginSkipsDisplayBelowTheCorner() {
        let below = CGRect(x: 1512, y: 982, width: 800, height: 600)
        let origin = HiddenScreenGeometry.cornerOrigin(size: CGSize(width: 1440, height: 900), beside: [main, below])
        XCTAssertFalse(CGRect(origin: origin, size: CGSize(width: 1440, height: 900)).intersects(below))
    }

    func testSharedEdge() {
        XCTAssertEqual(HiddenScreenGeometry.sharedEdgeLength(main, right), 982 - 0)
        XCTAssertEqual(HiddenScreenGeometry.sharedEdgeLength(main, CGRect(x: 1512, y: 982, width: 10, height: 10)), 0)
        XCTAssertEqual(HiddenScreenGeometry.sharedEdgeLength(main, CGRect(x: 100, y: 982, width: 300, height: 10)), 300)
    }

    func testPullBackReturnsCursorToNearestPhysicalDisplay() {
        let hidden = CGRect(x: 1512, y: 982, width: 1440, height: 900)
        XCTAssertNil(HiddenScreenGeometry.pullBack(CGPoint(x: 10, y: 10), hidden: hidden, physical: [main]))
        XCTAssertEqual(HiddenScreenGeometry.pullBack(CGPoint(x: 1600, y: 1000), hidden: hidden, physical: [main]), CGPoint(x: 1511, y: 981))
    }

    func testMirrorMappingRoundTripAndLetterbox() {
        let target = CGRect(x: 1512, y: 982, width: 800, height: 600)
        let same = MirrorMapping(viewSize: CGSize(width: 800, height: 600), target: target)
        XCTAssertEqual(same.toTarget(CGPoint(x: 10, y: 20)), CGPoint(x: 1522, y: 1002))
        XCTAssertEqual(same.toView(CGPoint(x: 1522, y: 1002)), CGPoint(x: 10, y: 20))

        // Зеркало шире окна: картинка 400×300 по центру, поля по 100 pt слева и справа.
        let wide = MirrorMapping(viewSize: CGSize(width: 600, height: 300), target: target)
        XCTAssertEqual(wide.contentRect, CGRect(x: 100, y: 0, width: 400, height: 300))
        XCTAssertNil(wide.toTarget(CGPoint(x: 50, y: 150)), "щелчок по полю не уходит в программу")
        XCTAssertEqual(wide.toTarget(CGPoint(x: 300, y: 150)), CGPoint(x: 1912, y: 1282))
        XCTAssertEqual(wide.scale, 0.5)
    }

    func testTargetSizeIsClampedToHiddenDisplay() {
        let hidden = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(MirrorMapping.targetSize(forMirror: CGSize(width: 2000, height: 700), hidden: hidden), CGSize(width: 1440, height: 700))
    }
}

final class HiddenWindowRulesTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let hidden = CGRect(x: 1512, y: 982, width: 1440, height: 900)

    func window(_ id: CGWindowID, _ bundle: String?, _ frame: CGRect, layer: Int = 0, pid: pid_t = 10) -> HiddenWindowInfo {
        HiddenWindowInfo(id: id, pid: pid, bundleID: bundle, frame: frame, layer: layer)
    }

    func testBundleIDs() {
        XCTAssertTrue(HiddenApp.chatGPT.matches(bundleID: "com.openai.codex"))
        XCTAssertTrue(HiddenApp.chatGPT.matches(bundleID: "com.openai.chat"))
        XCTAssertTrue(HiddenApp.claude.matches(bundleID: "com.anthropic.claudefordesktop"))
        XCTAssertFalse(HiddenApp.claude.matches(bundleID: nil))
    }

    func testPlanMovesNormalWindowsAndReportsOverlays() {
        let windows = [
            window(1, "com.anthropic.claudefordesktop", CGRect(x: 100, y: 50, width: 900, height: 700)),
            window(2, "com.anthropic.claudefordesktop", CGRect(x: 200, y: 300, width: 220, height: 160), layer: 101), // меню
            window(3, "com.openai.codex", CGRect(x: 1600, y: 1000, width: 700, height: 600)),                       // уже скрыто
            window(4, "us.zoom.xos", CGRect(x: 0, y: 0, width: 800, height: 600)),                                 // чужое
            window(5, "com.anthropic.claudefordesktop", CGRect(x: 0, y: 0, width: 1, height: 1)),                  // служебное
            window(6, "com.openai.codex", CGRect(x: 1400, y: 900, width: 400, height: 300)),                       // на стыке
        ]
        let plan = HiddenWindowRules.plan(windows: windows, apps: [.claude, .chatGPT], hidden: hidden, physical: [main])
        XCTAssertEqual(plan, [
            .move(1, to: CGPoint(x: 1612, y: 1032)),
            .leak(2, layer: 101),
            .move(6, to: CGPoint(x: 2552, y: 1582)),
        ])
    }

    func testPlacementKeepsWindowInsideHiddenDisplay() {
        let big = CGRect(x: -50, y: 10, width: 2000, height: 1200)
        XCTAssertEqual(HiddenWindowRules.placement(of: big, from: main, into: hidden), hidden.origin)
    }

    func testWindowIDMatchesAXFrameOnlyWhenUnambiguous() {
        let frame = CGRect(x: 1612, y: 1032, width: 900, height: 700)
        let list = [
            window(7, "com.anthropic.claudefordesktop", frame.offsetBy(dx: 0.5, dy: -0.5)),
            window(8, "com.anthropic.claudefordesktop", frame, layer: 101),
            window(9, "com.anthropic.claudefordesktop", frame, pid: 11),
        ]
        XCTAssertEqual(HiddenWindowRules.windowID(forAXFrame: frame, pid: 10, in: list), 7)
        XCTAssertNil(HiddenWindowRules.windowID(forAXFrame: frame, pid: 10, in: list + [window(10, nil, frame)]), "два одинаковых окна — не угадываем")
    }

    func testMirrorCandidateIsLargestHiddenWindow() {
        let list = [
            window(1, "com.openai.codex", CGRect(x: 1600, y: 1000, width: 400, height: 300)),
            window(2, "com.openai.codex", CGRect(x: 1700, y: 1100, width: 900, height: 700)),
            window(3, "com.openai.codex", CGRect(x: 10, y: 10, width: 1200, height: 900)),
        ]
        XCTAssertEqual(HiddenWindowRules.mirrorCandidate(windows: list, app: .chatGPT, hidden: hidden)?.id, 2)
    }
}

final class MirrorInputTests: XCTestCase {
    let translator = MirrorInputTranslator(
        mapping: MirrorMapping(viewSize: CGSize(width: 400, height: 300), target: CGRect(x: 2000, y: 1000, width: 800, height: 600)),
        windowNumber: 42)

    func testClickMapsToHiddenDisplayAndCarriesWindowNumber() {
        let events = translator.translate(.mouse(.down, .left, at: CGPoint(x: 100, y: 50), clicks: 2, flags: []))
        XCTAssertEqual(events, [SyntheticEvent(kind: .leftDown, location: CGPoint(x: 2200, y: 1100), clicks: 2, windowNumber: 42)])
        XCTAssertEqual(translator.translate(.mouse(.down, .left, at: CGPoint(x: 500, y: 50), clicks: 1, flags: [])), [], "вне картинки")
    }

    func testScrollIsScaledToWindowPoints() {
        let events = translator.translate(.scroll(dx: 0, dy: -3, precise: true, at: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(events.first?.kind, .scroll(dx: 0, dy: -6, pixels: true))
        let lines = translator.translate(.scroll(dx: 0, dy: 1, precise: false, at: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(lines.first?.kind, .scroll(dx: 0, dy: 20, pixels: true))
    }

    func testCyrillicTextGoesAsUnicodeString() {
        let events = translator.translate(.key(code: 0, down: true, flags: [], characters: "ф"))
        XCTAssertEqual(events, [SyntheticEvent(kind: .keyDown, keyCode: 0, text: "ф")])
        XCTAssertEqual(translator.translate(.key(code: 0, down: true, flags: .maskShift, characters: "Ё")).first?.text, "Ё")
    }

    func testShortcutsAndSpecialKeysGoAsKeyCodes() {
        // ⌘V (в том числе Ctrl+V после «Клавиш Windows») — кодом и флагом, без строки.
        XCTAssertEqual(translator.translate(.key(code: MirrorKeys.v, down: true, flags: .maskCommand, characters: "v")),
                       [SyntheticEvent(kind: .keyDown, keyCode: MirrorKeys.v, flags: .maskCommand)])
        // Стрелка: символ из функциональной области AppKit не отправляется строкой.
        XCTAssertNil(translator.translate(.key(code: 123, down: true, flags: [], characters: "\u{F702}")).first?.text)
        XCTAssertNil(translator.translate(.key(code: MirrorKeys.return, down: true, flags: [], characters: "\r")).first?.text)
    }

    func testReservedShortcutsStayOutOfTheApp() {
        XCTAssertEqual(MirrorKeys.route(code: MirrorKeys.q, flags: .maskCommand), .drop)
        XCTAssertEqual(MirrorKeys.route(code: MirrorKeys.w, flags: .maskCommand), .drop, "закрыл бы окно Zoom или ИИ")
        XCTAssertEqual(MirrorKeys.route(code: MirrorKeys.h, flags: [.maskCommand, .maskAlternate]), .drop)
        XCTAssertEqual(MirrorKeys.route(code: MirrorKeys.tab, flags: .maskCommand), .keepLocal)
        XCTAssertEqual(MirrorKeys.route(code: MirrorKeys.v, flags: .maskCommand), .forward)
        XCTAssertEqual(translator.translate(.key(code: MirrorKeys.q, down: true, flags: .maskCommand, characters: "q")), [])
    }

    func testPasteKeystroke() {
        XCTAssertEqual(PasteKeystroke.events().map(\.kind), [.keyDown, .keyUp])
        XCTAssertTrue(PasteKeystroke.events().allSatisfy { $0.flags == .maskCommand && $0.keyCode == MirrorKeys.v })
    }
}

final class DropBridgeTests: XCTestCase {
    func testRoutes() {
        let photo = URL(fileURLWithPath: "/tmp/a/Фото.HEIC")
        let pdf = URL(fileURLWithPath: "/tmp/a/договор.pdf")
        XCTAssertEqual(DropBridge.route(fileURLs: [photo], types: ["public.file-url", "public.tiff"], text: nil), .imageFiles([photo]))
        XCTAssertEqual(DropBridge.route(fileURLs: [photo, pdf], types: [], text: nil), .files([photo, pdf]))
        XCTAssertEqual(DropBridge.route(fileURLs: [], types: ["public.tiff", "public.png"], text: "x"), .imageData(type: "public.png"))
        XCTAssertEqual(DropBridge.route(fileURLs: [URL(string: "https://example.com")!], types: [], text: "привет"), .text("привет"))
        XCTAssertEqual(DropBridge.route(fileURLs: [], types: [], text: ""), .unsupported)
    }

    final class FakePasteboard: PasteboardStore {
        var items: [[String: Data]] = [["public.utf8-plain-text": Data("моё".utf8)]]
        var changeCount = 1
        func snapshot() -> [[String: Data]] { items }
        func replace(with items: [[String: Data]]) -> Int {
            self.items = items
            changeCount += 1
            return changeCount
        }
    }

    func testSwapRestoresUserClipboardAndMarksTransient() {
        let board = FakePasteboard()
        let swap = ClipboardSwap(store: board)
        swap.begin(with: [["public.png": Data([1, 2])]])
        XCTAssertEqual(board.items.first?["public.png"], Data([1, 2]))
        XCTAssertNotNil(board.items.first?["org.nspasteboard.TransientType"], "менеджеры буфера не запишут в историю")
        XCTAssertTrue(swap.restore())
        XCTAssertEqual(board.items, [["public.utf8-plain-text": Data("моё".utf8)]])
        XCTAssertFalse(swap.isActive)
    }

    func testSwapDoesNotOverwriteWhatUserCopiedMeanwhile() {
        let board = FakePasteboard()
        let swap = ClipboardSwap(store: board)
        swap.begin(with: [["public.png": Data([1])]])
        _ = board.replace(with: [["public.utf8-plain-text": Data("новое".utf8)]])
        XCTAssertFalse(swap.restore())
        XCTAssertEqual(board.items, [["public.utf8-plain-text": Data("новое".utf8)]])
    }

    func testMarksCanBeTurnedOff() {
        let board = FakePasteboard()
        let swap = ClipboardSwap(store: board)
        swap.marksTransient = false
        swap.begin(with: [["public.png": Data([1])]])
        XCTAssertEqual(board.items, [["public.png": Data([1])]])
    }

    func testSecondBeginKeepsOriginalSnapshot() {
        let board = FakePasteboard()
        let swap = ClipboardSwap(store: board)
        swap.begin(with: [["public.png": Data([1])]])
        swap.begin(with: [["public.png": Data([2])]])
        XCTAssertTrue(swap.restore())
        XCTAssertEqual(board.items, [["public.utf8-plain-text": Data("моё".utf8)]])
    }
}

/// 643b753: на выходе ChatGPT остался на (1710, 1111) — окно спрятанной программы на снятом дисплее.
final class RestorePlanTests: XCTestCase {
    let hidden = CGRect(x: 1710, y: 1072, width: 1440, height: 900)
    let physical = [CGRect(x: 0, y: 0, width: 1710, height: 1112)]

    func testEveryWindowOnHiddenGoesBack() {
        let plan = HiddenWindowRules.restorePlan(
            windows: [(20469, CGRect(x: 1918, y: 1259, width: 900, height: 700)),
                      (20858, CGRect(x: 1710, y: 1111, width: 1280, height: 820)),
                      (nil, CGRect(x: 1800, y: 1100, width: 400, height: 300)),
                      (99, CGRect(x: 100, y: 100, width: 400, height: 300))],
            remembered: [20858: CGRect(x: 0, y: 39, width: 1280, height: 820)], hidden: hidden, physical: physical)
        XCTAssertEqual(plan.map(\.index), [0, 1, 2], "окно на настоящем экране не трогаем")
        XCTAssertEqual(plan[1].origin, CGPoint(x: 0, y: 39), "ChatGPT — туда, где был до переноса")
        XCTAssertEqual(plan[1].size, CGSize(width: 1280, height: 820), "и прежнего размера")
        XCTAssertEqual(plan[0].size, CGSize(width: 900, height: 700), "не запомнено — размер не трогаем")
        XCTAssertTrue(physical[0].contains(plan[0].origin), "не запомнено — на настоящий экран")
        XCTAssertTrue(physical[0].contains(plan[2].origin), "без номера — на настоящий экран")
    }

    func testNothingWithoutHiddenDisplay() {
        XCTAssertTrue(HiddenWindowRules.restorePlan(windows: [(1, CGRect(x: 0, y: 0, width: 10, height: 10))], remembered: [:],
                                                    hidden: .null, physical: physical).isEmpty)
    }
}

/// HSCR-39: быстрый чат Claude отказался стать 900×700 (остался 900×535) — низ зеркала чёрный, наведение и щелчок
/// в одну точку зеркала давали разные точки окна (разница 83 = (700 − 535) / 2).
final class MirrorFitTests: XCTestCase {
    let requested = CGSize(width: 900, height: 700)
    let refused = CGRect(x: 2165, y: 1437, width: 900, height: 535)
    let visible = CGRect(x: -1920, y: 0, width: 1920, height: 1050)

    func testRefusedResizeIsNoticed() {
        XCTAssertTrue(MirrorFit.differs(requested, refused.size), "поток был настроен на просьбу, а не на окно")
        XCTAssertFalse(MirrorFit.differs(CGSize(width: 900, height: 535), CGSize(width: 900.5, height: 534.6)), "доли точки — не повод")
        XCTAssertTrue(MirrorFit.differs(nil, refused.size))
    }

    func testMirrorFollowsActualWindowWithoutMargins() {
        let view = MirrorFit.viewSize(window: refused.size, available: CGSize(width: 1920, height: 1022))
        XCTAssertEqual(view, CGSize(width: 900, height: 535), "1:1 под фактическое окно — чёрного низа нет")
        let mapping = MirrorMapping(viewSize: view, target: refused)
        XCTAssertEqual(mapping.contentRect, CGRect(origin: .zero, size: view), "картинка во весь вид, без полей")
    }

    func testHoverAndClickUseTheSamePointOfTheWindow() {
        let mapping = MirrorMapping(viewSize: MirrorFit.viewSize(window: refused.size, available: visible.size), target: refused)
        let point = CGPoint(x: 450, y: 12)
        var session = PointerSession()
        guard case let .postToPid(moved) = session.hover(at: point, mapping: mapping, windowNumber: 8567).first else {
            return XCTFail("наведение")
        }
        _ = session.down(.left, at: point, clicks: 1, flags: [], mapping: mapping, windowNumber: 8567, cursor: .zero)
        let click = session.up(mapping: mapping, windowNumber: 8567).compactMap { step -> CGPoint? in
            if case let .postHID(event) = step, event.kind == .leftDown { return event.location }
            return nil
        }
        XCTAssertEqual(click, [moved.location!], "одна и та же рамка — одна и та же точка окна")
        XCTAssertEqual(moved.location, CGPoint(x: 2615, y: 1449))
        let mirrorRect = CGRect(x: -1018, y: 232, width: 900, height: 535)
        XCTAssertEqual(PointerSession.dragLocation(CGPoint(x: -568, y: 244), hidden: CGRect(x: 1710, y: 1072, width: 1440, height: 900),
                                                   mirrorRect: mirrorRect, mapping: mapping), moved.location, "и протягивание")
    }

    func testWindowLargerThanScreenIsScaledKeepingProportions() {
        let view = MirrorFit.viewSize(window: CGSize(width: 1440, height: 900), available: CGSize(width: 1200, height: 1000))
        XCTAssertEqual(view, CGSize(width: 1200, height: 750))
        XCTAssertEqual(MirrorFit.clamp(CGSize(width: 1600, height: 758), to: CGSize(width: 1440, height: 900)), CGSize(width: 1440, height: 758),
                       "окно больше скрытого дисплея — ужать")
    }

    func testMirrorFrameKeepsTopLeftAndStaysOnScreen() {
        let current = CGRect(x: -1018, y: 120, width: 900, height: 756)   // вид 900×728 + заголовок 28
        let frame = MirrorFit.mirrorFrame(current: current, chrome: CGSize(width: 0, height: 28),
                                          view: CGSize(width: 900, height: 535), visible: visible)
        XCTAssertEqual(frame, CGRect(x: -1018, y: 313, width: 900, height: 563), "левый верхний угол на месте")
        let edge = MirrorFit.mirrorFrame(current: CGRect(x: -100, y: 0, width: 400, height: 300), chrome: .zero,
                                         view: CGSize(width: 1135, height: 758), visible: visible)
        XCTAssertEqual(edge.maxX, visible.maxX, "не вылезает за экран")
        XCTAssertGreaterThanOrEqual(edge.minY, visible.minY)
    }
}

/// 928c284 (18.11): быстрый чат Claude после перезапуска — уровень −1. Перенесён, но «Claude: 0 окон», зеркало пустое.
final class WindowLayerTests: XCTestCase {
    let hidden = CGRect(x: 1710, y: 1072, width: 1440, height: 900)
    let physical = [CGRect(x: 0, y: 0, width: 1710, height: 1112)]

    func window(_ id: CGWindowID, _ frame: CGRect, layer: Int, bundle: String = "com.anthropic.claudefordesktop", alpha: CGFloat = 1) -> HiddenWindowInfo {
        HiddenWindowInfo(id: id, pid: 27390, bundleID: bundle, frame: frame, layer: layer, alpha: alpha)
    }

    func testAppWindowIsOneRuleForAllLayersBelowMenus() {
        XCTAssertTrue(HiddenWindowRules.isAppWindow(window(1, CGRect(x: 0, y: 0, width: 736, height: 447), layer: -1)))
        XCTAssertTrue(HiddenWindowRules.isAppWindow(window(2, CGRect(x: 0, y: 0, width: 736, height: 447), layer: 0)))
        XCTAssertTrue(HiddenWindowRules.isAppWindow(window(3, CGRect(x: 0, y: 0, width: 400, height: 80), layer: 3)), "плавающая панель")
        XCTAssertFalse(HiddenWindowRules.isAppWindow(window(4, CGRect(x: 0, y: 0, width: 200, height: 300), layer: HiddenWindowRules.popupLayer)), "меню")
        XCTAssertFalse(HiddenWindowRules.isAppWindow(window(5, CGRect(x: 0, y: 0, width: 736, height: 447), layer: 0, alpha: 0)))
        XCTAssertFalse(HiddenWindowRules.isAppWindow(window(6, CGRect(x: 0, y: 0, width: 1, height: 1), layer: 0)), "служебное 1×1")
    }

    func testEveryMovedWindowIsCountedAndMirrorable() {
        let onScreen = [window(15338, CGRect(x: 455, y: 365, width: 736, height: 447), layer: -1),
                        window(7, CGRect(x: 100, y: 100, width: 300, height: 60), layer: 3),
                        window(8, CGRect(x: 100, y: 100, width: 200, height: 300), layer: 101)]
        let plan = HiddenWindowRules.plan(windows: onScreen, apps: [.claude], hidden: hidden, physical: physical)
        var landed: [HiddenWindowInfo] = []
        for action in plan {
            guard case let .move(id, origin) = action, var moved = onScreen.first(where: { $0.id == id }) else { continue }
            moved.frame.origin = origin
            landed.append(moved)
        }
        XCTAssertEqual(landed.map(\.id), [15338, 7], "меню — утечка, остальное переносится")
        XCTAssertEqual(HiddenWindowRules.hiddenWindowCount(windows: landed, app: .claude, hidden: hidden), landed.count,
                       "сколько перенесено — столько и окон у программы")
        XCTAssertEqual(HiddenWindowRules.mirrorCandidate(windows: [landed[0]], app: .claude, hidden: hidden)?.id, 15338,
                       "окно уровня −1 — в зеркало")
        XCTAssertEqual(HiddenWindowRules.windowID(forAXFrame: landed[0].frame, pid: 27390, in: landed), 15338, "и AX находит его номер")
    }

    func testMirrorPrefersNormalWindowOverBiggerPanel() {
        let normal = window(1, CGRect(x: 1800, y: 1100, width: 600, height: 400), layer: 0)
        let panel = window(2, CGRect(x: 1800, y: 1100, width: 900, height: 700), layer: -1)
        XCTAssertEqual(HiddenWindowRules.mirrorCandidate(windows: [panel, normal], app: .claude, hidden: hidden)?.id, 1)
    }
}

final class MirrorChoiceTests: XCTestCase {
    func testSelectedWithoutWindowsSwitchesToAppWithWindows() {
        XCTAssertEqual(MirrorChoice.app(selected: .claude, windows: [(.claude, 0), (.chatGPT, 1)]), .chatGPT)
        XCTAssertEqual(MirrorChoice.app(selected: .claude, windows: [(.claude, 1), (.chatGPT, 1)]), .claude, "у выбранной есть окна — она")
        XCTAssertEqual(MirrorChoice.app(selected: nil, windows: [(.claude, 0), (.chatGPT, 2)]), .chatGPT)
        XCTAssertNil(MirrorChoice.app(selected: .claude, windows: [(.claude, 0), (.chatGPT, 0)]), "ни у кого — ждать")
    }

    func testRetryIsThrottled() {
        XCTAssertTrue(MirrorChoice.shouldTry(.chatGPT, last: nil, now: 0))
        XCTAssertFalse(MirrorChoice.shouldTry(.chatGPT, last: (.chatGPT, 10), now: 11))
        XCTAssertTrue(MirrorChoice.shouldTry(.chatGPT, last: (.chatGPT, 10), now: 12))
        XCTAssertTrue(MirrorChoice.shouldTry(.chatGPT, last: (.claude, 10), now: 10.1), "другая программа — сразу")
    }

    func testEmptyMirrorNeverActivatesMacUtils() {
        XCTAssertEqual(EmptyMirrorClick.policy(hasTitleBar: false), .passThrough, "интерфейс: щелчок проходит насквозь")
        XCTAssertEqual(EmptyMirrorClick.policy(hasTitleBar: true), .swallow, "отладка: по картинке поглощается, заголовок работает")
    }
}
