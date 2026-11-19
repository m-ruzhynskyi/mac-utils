import CoreGraphics
@testable import MUHiddenScreen
import XCTest

/// HSCR-44, дополнение менеджера: раскладка с отказом 1006 и самопроверка `--hs-selftest`.
final class LayoutAttemptTests: XCTestCase {
    func testFirstTryIsWithoutFadeAndSystemFadeIsLast() {
        XCTAssertEqual(LayoutAttempt.order.first, LayoutAttempt(.none))
        XCTAssertEqual(LayoutAttempt.order.last, LayoutAttempt(.system), "затемнение системы (мигание) — последний способ")
    }

    func testRefusalOnCompleteTriesNextWay() {
        // 19.11: «без затемнения» → CGCompleteDisplayConfiguration 1006.
        let failure = LayoutFailure(step: .complete, code: 1006)
        var tried = [LayoutAttempt(.none)]
        var chain: [LayoutAttempt] = []
        while let next = LayoutAttempt.next(after: failure, tried: tried, preferred: nil) {
            chain.append(next)
            tried.append(next)
        }
        XCTAssertEqual(chain, [LayoutAttempt(.short), LayoutAttempt(.none, .app), LayoutAttempt(.system)])
    }

    func testRefusalOnOriginStops() {
        XCTAssertNil(LayoutAttempt.next(after: LayoutFailure(step: .origin, code: 1001), tried: [LayoutAttempt(.none)], preferred: nil),
                     "отказ на самой точке от затемнения не зависит")
        XCTAssertNil(LayoutAttempt.next(after: LayoutFailure(step: .begin, code: 1000), tried: [LayoutAttempt(.none)], preferred: nil))
        XCTAssertEqual(LayoutAttempt.next(after: LayoutFailure(step: .fade, code: 1006), tried: [LayoutAttempt(.none)], preferred: nil),
                       LayoutAttempt(.short))
    }

    func testWorkingWayGoesFirst() {
        let preferred = LayoutAttempt(.system)
        XCTAssertEqual(LayoutAttempt.order(preferred: preferred).first, preferred)
        XCTAssertEqual(LayoutAttempt.order(preferred: preferred).count, LayoutAttempt.order.count)
        XCTAssertEqual(LayoutAttempt.next(after: LayoutFailure(step: .complete, code: 1006), tried: [preferred], preferred: preferred),
                       LayoutAttempt(.none))
    }

    func testFailureText() {
        XCTAssertEqual(LayoutFailure(step: .complete, code: 1006).description, "CGCompleteDisplayConfiguration: 1006")
        XCTAssertEqual(LayoutAttempt(.none, .app).description, "без затемнения, пока жива Mac Utils")
    }

    @MainActor
    func testPreCallIsHonestWhenMacOSRefused() {
        defer { DockAway.runtimeFailure = nil }
        DockAway.runtimeFailure = "macOS не дала поставить скрытый экран к краю Dock (CGCompleteDisplayConfiguration: 1006)"
        XCTAssertEqual(DockAway.readiness(enabled: true), .unavailable(DockAway.runtimeFailure!))
        XCTAssertEqual(DockAway.readiness(enabled: false), .disabled)
    }
}

final class SelfTestTests: XCTestCase {
    func testFlagOnlyWithDebug() {
        XCTAssertNil(HiddenScreenOptions.debug(arguments: ["--hs-selftest"], storedBundleIDs: nil), "без отладочного запуска — ничего")
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-selftest"], storedBundleIDs: nil)?.selfTest, true)
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug"], storedBundleIDs: nil)?.selfTest, false)
        XCTAssertFalse(HiddenScreenOptions().selfTest)
    }

    func testDisplayChangeFlags() {
        XCTAssertEqual(DisplayChange.describe(1), "начало")
        XCTAssertEqual(DisplayChange.describe(2 | 4096), "перемещён, форма рабочего стола")
        XCTAssertEqual(DisplayChange.describe(0), "—")
        XCTAssertFalse(DisplayChange.isRebuild(1 | 2 | 4096), "раскладка — не перестройка")
        XCTAssertTrue(DisplayChange.isRebuild(8), "смена режима — мигание")
        XCTAssertTrue(DisplayChange.isRebuild(16))
    }

    func testFlickerVerdict() {
        XCTAssertEqual(DisplayChange.verdict(physical: []), "физические дисплеи перестраивались: нет (событий нет)")
        XCTAssertEqual(DisplayChange.verdict(physical: [(1, 4096)]), "физические дисплеи перестраивались: нет (только раскладка: 1 форма рабочего стола)")
        XCTAssertEqual(DisplayChange.verdict(physical: [(1, 4096), (1, 8)]), "физические дисплеи перестраивались: да (1 режим)")
    }

    func testFocusLine() {
        let frame = CGRect(x: 1800, y: 900, width: 700, height: 60)
        XCTAssertEqual(SelfTestText.focus(app: "Claude", before: false, after: true, role: "AXTextArea", frame: frame),
                       "самопроверка щелчка: Claude фокус в поле да (до щелчка: нет; поле AXTextArea (1800,900 700×60))")
        XCTAssertTrue(SelfTestText.focus(app: "ChatGPT", before: true, after: true, role: "AXTextArea", frame: frame).contains("не доказательна"))
    }
}
