import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// Линии таблиц «Документа» как у Word (по его PDF): толщина и края — на сетке 1/300 дюйма (0,24 pt) от угла листа,
/// вертикальная линия — серединой на точном краю `\cellx`, горизонтальная прибавляется к высоте строки.
/// Демо-фикстуры — выдуманный текст.
@MainActor
final class DocBordersTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        super.tearDown()
    }

    private static let header = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}{\colortbl;\red0\green0\blue0;}"#
        + #"\paperw11906\paperh16838\margl1440\margr1440\margt1440\margb1440"#

    private static func row(_ text: String, borders: Bool) -> String {
        let cell = borders ? #"\clbrdrt\brdrs\brdrw10\clbrdrl\brdrs\brdrw10\clbrdrb\brdrs\brdrw10\clbrdrr\brdrs\brdrw10"# : ""
        return #"\trowd\trgaph108\trleft0"# + cell + #"\cellx1530"# + cell + #"\cellx4000"#
            + #"\pard\intbl\f0\fs24 "# + text + #"\cell\pard\intbl x\cell\row"#
    }

    /// Толщина `\brdrwN`: вниз до шага 0,24 pt, не тоньше шага — так в PDF Word (5 → 0,24; 10 → 0,48; 60 → 2,88).
    func testBorderWidthLikeWord() {
        let widths = [5, 10, 15, 20, 30, 45, 60].map { DocCellBlock.wordWidth($0) }
        for (width, expected) in zip(widths, [0.24, 0.48, 0.72, 0.96, 1.44, 2.16, 2.88]) {
            XCTAssertEqual(width, expected, accuracy: 0.0001)
        }
    }

    /// Вертикальные линии — серединой на точном краю `\cellx` (не на целом пункте рамки `NSTextTable`), начало — на узле
    /// сетки 0,24 pt.
    func testLinesOnCellEdges() throws {
        let rtf = Self.header + Self.row("Alpha", borders: false) + Self.row("Beta", borders: false) + Self.row("Gamma", borders: false)
            + #"\pard\par"# + Self.row("Delta", borders: true) + Self.row("Omega", borders: true) + Self.row("Sigma", borders: true) + #"\pard\par}"#
        let pdf = try render(open(Data(rtf.utf8), name: "borders.rtf"))
        // Тонкий залитый контур линии (`m l l l h f`, как у Word) `WordFidelity.segments` отдаёт краями без замыкающего `h`:
        // горизонтальную — двумя краями (середина — между ними), вертикальную — правым краем. Края листа — не линии.
        let half = DocCellBlock.wordWidth(10) / 2
        func centers(horizontal: Bool) -> [CGFloat] {
            let edges = WordFidelity.segments(pdf).filter { $0.page == 0 && $0.horizontal == horizontal && $0.position > 20 && $0.position < 580 }
                .map(\.position).sorted()
            var groups: [[CGFloat]] = []
            for edge in edges {
                if let last = groups.last?.last, edge - last <= 0.5 { groups[groups.count - 1].append(edge) } else { groups.append([edge]) }
            }
            return groups.map { ((horizontal ? ($0.min()! + $0.max()!) / 2 : $0.max()! - half) * 100).rounded() / 100 }
        }
        // Word: середина линии толщиной w на краю x, начало — к ближайшему узлу сетки.
        func word(_ twips: Int) -> CGFloat {
            let w = DocCellBlock.wordWidth(10)
            return ((CGFloat(twips) / 20 - w / 2) / DocCellBlock.grid).rounded() * DocCellBlock.grid + w / 2
        }
        let vertical = centers(horizontal: false)
        XCTAssertEqual(vertical.count, 3, "\(vertical)")
        for (position, edge) in zip(vertical, [1440, 1440 + 1530, 1440 + 4000]) {
            XCTAssertEqual(position, word(edge), accuracy: 0.01, "край \(edge) твипов")
        }
        let horizontal = centers(horizontal: true)
        XCTAssertEqual(horizontal.count, 4, "\(horizontal): по одной на стык строк")
    }

    // MARK: - Раскладка (как в WordFidelityTests)

    private func open(_ data: Data, name: String) throws -> DocumentController {
        let workspace = EditorWorkspace()
        workspace.dollarPanelVisible = false
        let tab = EditorTab(document: EditorDocument(data: data, url: URL(fileURLWithPath: "/tmp/\(name)")))
        tab.restoreMode(.document)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        windows.append(window)
        let document = try XCTUnwrap(tab.documentController, "\(name): «Документ» не открылся")
        for _ in 0..<5 {
            if let last = document.layoutManager.textContainers.last { document.layoutManager.ensureLayout(for: last) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        return document
    }

    private func render(_ document: DocumentController) throws -> PDFDocument {
        let result = PDFDocument()
        for (index, page) in document.pagesView.pages.enumerated() {
            page.layoutSubtreeIfNeeded()
            guard let single = PDFDocument(data: page.dataWithPDF(inside: page.bounds))?.page(at: 0) else { continue }
            result.insert(single, at: index)
        }
        return result
    }
}
