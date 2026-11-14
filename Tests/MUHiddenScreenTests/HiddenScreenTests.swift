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
