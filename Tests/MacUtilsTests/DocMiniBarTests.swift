import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Логика мини-панели над выделением (T2): место, видимость, действия. Вид плитки — отдельно.
@MainActor
final class DocMiniBarTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let bar = CGSize(width: 240, height: 36)

    private func place(_ selection: CGRect) -> DocMiniBar.Placement? { DocMiniBar.placement(selection: selection, bar: bar, bounds: bounds) }

    func testAboveCenteredWhenThereIsRoom() throws {
        let selection = CGRect(x: 300, y: 200, width: 100, height: 18)
        let placement = try XCTUnwrap(place(selection))
        XCTAssertEqual(placement.side, .above)
        XCTAssertEqual(placement.frame.midX, selection.midX, accuracy: 0.5, "по центру выделения")
        XCTAssertEqual(placement.frame.maxY, selection.minY - 8, accuracy: 0.5)
        XCTAssertFalse(placement.frame.intersects(selection))
    }

    func testBelowWhenTopEdgeIsTooClose() throws {
        let selection = CGRect(x: 300, y: 20, width: 100, height: 18)
        let placement = try XCTUnwrap(place(selection))
        XCTAssertEqual(placement.side, .below, "сверху места нет — под выделением")
        XCTAssertEqual(placement.frame.minY, selection.maxY + 8, accuracy: 0.5)
    }

    func testClampedHorizontallyAtPageAndWindowEdges() throws {
        let left = try XCTUnwrap(place(CGRect(x: 0, y: 200, width: 30, height: 18)))
        XCTAssertEqual(left.frame.minX, 8, accuracy: 0.5, "у левого края — с отступом")
        let right = try XCTUnwrap(place(CGRect(x: 790, y: 200, width: 10, height: 18)))
        XCTAssertEqual(right.frame.maxX, 792, accuracy: 0.5, "у правого — с отступом")
        XCTAssertTrue(bounds.contains(left.frame) && bounds.contains(right.frame))
    }

    func testNeverCoversSelectionAndHidesWhenNoRoom() throws {
        // Выделение во всю высоту: ни сверху, ни снизу — сбоку.
        let tall = CGRect(x: 300, y: 0, width: 100, height: 600)
        let side = try XCTUnwrap(place(tall))
        XCTAssertTrue(side.side == .right || side.side == .left)
        XCTAssertFalse(side.frame.intersects(tall))
        // Выделение во всю область: места нет — панели нет, выделение цело.
        XCTAssertNil(place(bounds))
        // Тесная область: плитка не помещается вовсе.
        XCTAssertNil(DocMiniBar.placement(selection: CGRect(x: 10, y: 10, width: 5, height: 5), bar: bar, bounds: CGRect(x: 0, y: 0, width: 200, height: 100)))
        // Сотни случайных выделений: плитка всегда внутри области и не перекрывает выделение.
        var random = SeededRandom(seed: 41)
        for _ in 0..<500 {
            let selection = CGRect(x: CGFloat(random.next(780)), y: CGFloat(random.next(580)), width: CGFloat(1 + random.next(400)), height: CGFloat(1 + random.next(300)))
                .intersection(bounds)
            guard let result = place(selection) else { continue }
            XCTAssertTrue(bounds.contains(result.frame), "\(selection)")
            XCTAssertFalse(result.frame.intersects(selection), "\(selection)")
        }
    }

    func testVisibilityDisappearsWhileTyping() {
        let visible = { (length: Int, composing: Bool, mouse: Bool, since: TimeInterval) in
            DocMiniBar.isVisible(selectionLength: length, composing: composing, mouseDown: mouse, secondsSinceEdit: since)
        }
        XCTAssertTrue(visible(5, false, false, 10))
        XCTAssertFalse(visible(0, false, false, 10), "нет выделения")
        XCTAssertFalse(visible(5, true, false, 10), "идёт набор методом ввода")
        XCTAssertFalse(visible(5, false, true, 10), "мышь ещё выделяет")
        XCTAssertFalse(visible(5, false, false, 0.1), "только что печатали — исчезает")
        XCTAssertTrue(visible(5, false, false, DocMiniBar.typingQuiet))
        XCTAssertLessThanOrEqual(DocMiniBar.showDelay, 0.15, "появляется быстрее 150 мс")
    }

    func testActionsGiveSameBytesAsShortcuts() throws {
        func run(_ body: (DocFormatter, DocumentController) -> Void) throws -> String {
            let (workspace, tab) = DocDemo.tab()
            tab.restoreMode(nil)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
            window.orderBack(nil)
            defer { window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let document = try XCTUnwrap(tab.documentController)
            let range = (document.storage.string as NSString).range(of: "Демоград")
            document.textViews.first?.setSelectedRange(range)
            document.updateStatus()
            let formatter = DocFormatter.of(document)
            body(formatter, document)
            return tab.text as String
        }
        let bold = try run { f, _ in f.toggleBold() }
        XCTAssertEqual(try run { f, _ in DocMiniBar.perform(.bold, formatter: f) }, bold)
        let italic = try run { f, _ in f.toggleItalic() }
        XCTAssertEqual(try run { f, _ in DocMiniBar.perform(.italic, formatter: f) }, italic)
        let red = RTFColor(red: 192, green: 0, blue: 0)
        let colored = try run { f, _ in f.setColor(red) }
        XCTAssertEqual(try run { f, _ in DocMiniBar.perform(.color, color: red, formatter: f) }, colored)
        XCTAssertNotEqual(bold, italic)
        // Недоступные действия: ничего не меняют, а говорят почему.
        var notice: String?
        let untouched = try run { f, d in
            DocMiniBar.perform(.bullet, formatter: f)
            notice = d.notice
        }
        XCTAssertEqual(untouched, DocDemo.expertReport)
        XCTAssertNotNil(notice)
        XCTAssertEqual(DocMiniBar.Action.allCases.filter { !DocMiniBar.availability($0).enabled }.count, 3)
    }

    func testActiveStateFollowsFormatting() {
        var state = DocFormatState()
        XCTAssertFalse(DocMiniBar.isActive(.bold, state: state))
        state.bold = true
        XCTAssertTrue(DocMiniBar.isActive(.bold, state: state))
        XCTAssertFalse(DocMiniBar.isActive(.italic, state: state))
    }
}
