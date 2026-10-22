import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import MacUtils

/// Цвета «Документа» против PDF Word: цвет текста (`\cf`), маркер и заливка знака (`\highlight`, `\cb`, `\chcbpat`),
/// заливка абзаца и ячейки (`\cbpat`, `\clcbpat`). Наша сторона — та же раскладка, что в приложении (офскрин),
/// панель «Знаки $» закрыта: страница должна выглядеть как у Word.
///   MU_WORD_REF_DIR=~/Projects/Cowork/Form/LAB-word-ref [MU_WORD_REF_ONLY=f001,f082] [MU_WORD_COLORS_OUT=…/colors.md]
///   [MU_WORD_COLORS_STRICT=1] — падение, если есть хоть одно расхождение.
/// В отчёт — только fNNN, цвета и числа.
@MainActor
final class WordColorTests: XCTestCase {
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

    // MARK: - Сам инструмент (без эталона)

    /// PDF с красным текстом, зелёной заливкой и тонкой линией — извлечение видит цвет текста и площадь заливки.
    private func samplePDF(textColor: NSColor, fill: NSColor?, fillSize: CGSize = CGSize(width: 100, height: 20)) -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if let fill {
            fill.setFill()
            NSRect(origin: CGPoint(x: 10, y: 10), size: fillSize).fill()
        }
        NSColor.black.setFill()
        NSRect(x: 10, y: 100, width: 200, height: 0.5).fill()
        ("Demo" as NSString).draw(at: CGPoint(x: 20, y: 50), withAttributes: [.font: NSFont(name: "Times New Roman", size: 12)!, .foregroundColor: textColor])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    func testExtractsTextColorAndFillArea() throws {
        let page = try XCTUnwrap(WordColors.pages(samplePDF(textColor: .red, fill: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))).first)
        let red = try XCTUnwrap(page.text.first { !$0.key.isBlack })
        XCTAssertTrue(red.key.near(WordColors.RGB(1, 0, 0), tolerance: 16), "\(red.key)")
        XCTAssertEqual(red.value, 4, "четыре знака")
        let green = try XCTUnwrap(page.fills.first)
        XCTAssertTrue(green.key.near(WordColors.RGB(0, 1, 0), tolerance: 16), "\(green.key)")
        XCTAssertEqual(green.value, 2000, accuracy: 1, "100 × 20 pt")
        XCTAssertEqual(page.fills.count, 1, "линия 0,5 pt — не заливка")
    }

    func testCompareFindsMissingAndExtraColors() {
        let word = WordColors.pages(samplePDF(textColor: .red, fill: nil))
        let same = WordColors.pages(samplePDF(textColor: .red, fill: nil))
        XCTAssertTrue(WordColors.compare(word: word, ours: same).isEmpty)
        let grey = WordColors.pages(samplePDF(textColor: NSColor(white: 0.5, alpha: 1), fill: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)))
        let found = WordColors.compare(word: word, ours: grey)
        XCTAssertTrue(found.contains { $0.kind == .text && $0.ours == 0 }, "красного у нас нет")
        XCTAssertTrue(found.contains { $0.kind == .fill && $0.word == 0 }, "лишняя заливка")
    }

    // MARK: - Демо-фикстуры: как Word показывает цвета

    private func rendered(_ rtf: String) throws -> PDFDocument {
        try render(open(Data(rtf.utf8), name: "colors.rtf"))
    }

    private static let header = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}{\colortbl;\red0\green0\blue0;\red0\green0\blue255;\red0\green255\blue255;\red0\green255\blue0;\red255\green0\blue255;\red255\green0\blue0;}"#

    /// Маркер только на знаке конца ячейки: у Word его не видно, у нас не должно быть зелёной полосы до края ячейки.
    func testHighlightOnCellMarkIsInvisible() throws {
        let rtf = Self.header + #"\trowd\trgaph108\cellx3000\cellx6000\pard\intbl\b Res{\highlight4\cell}\pard\intbl x\cell\row\pard\par}"#
        let fills = WordColors.pages(try rendered(rtf)).flatMap(\.fills)
        XCTAssertFalse(fills.contains { $0.key.near(WordColors.RGB(0, 1, 0), tolerance: 16) }, "ярко-зелёной заливки нет")
    }

    /// Маркер на тексте — виден (как у Word), `$` — в цвете документа (красный), без чужой подсветки.
    func testHighlightOnTextAndRedDollar() throws {
        let rtf = Self.header + #"\pard{\highlight4 mark}\par\pard{\cf6 $}value\par}"#
        let pages = WordColors.pages(try rendered(rtf))
        XCTAssertTrue(pages.flatMap(\.fills).contains { $0.key.near(WordColors.RGB(0, 1, 0), tolerance: 16) }, "маркер на тексте")
        let colors = pages.flatMap(\.text).filter { !$0.key.isBlack }.map(\.key)
        XCTAssertTrue(colors.contains { $0.near(WordColors.RGB(1, 0, 0), tolerance: 16) }, "$ красный: \(colors)")
        XCTAssertEqual(colors.filter { !$0.near(WordColors.RGB(1, 0, 0), tolerance: 16) }, [], "других цветов текста нет")
    }

    // MARK: - Прогон по эталону Word

    func testColorsAgainstWordReference() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MU_WORD_REF_DIR"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_WORD_REF_DIR=<папка с rtf/ и pdf/>")
        }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var names = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("rtf").path)
            .filter { $0.hasSuffix(".rtf") && !$0.hasPrefix("~") }.map { ($0 as NSString).deletingPathExtension }.sorted()
        if let only = environment["MU_WORD_REF_ONLY"], !only.isEmpty {
            let wanted = Set(only.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            names = names.filter(wanted.contains)
        }
        var lines: [String] = []
        var checked = 0, clean = 0, total = 0
        var byKind: [String: Int] = [:]
        for name in names {
            let wordURL = base.appendingPathComponent("pdf/\(name).pdf")
            guard let data = try? Data(contentsOf: base.appendingPathComponent("rtf/\(name).rtf")), let wordPDF = PDFDocument(url: wordURL) else { continue }
            autoreleasepool {
                guard let ours = try? render(open(data, name: "\(name).rtf")) else {
                    lines.append("- \(name): не открылся")
                    return
                }
                checked += 1
                let found = WordColors.compare(word: WordColors.pages(wordPDF), ours: WordColors.pages(ours))
                if found.isEmpty { clean += 1 } else {
                    total += found.count
                    for mismatch in found { byKind[mismatch.kind.rawValue + (mismatch.word == 0 ? " лишний" : mismatch.ours == 0 ? " нет" : " другой объём"), default: 0] += 1 }
                    lines.append("- \(name): " + found.map(\.description).joined(separator: "; "))
                }
                for window in windows { window.contentView = nil; window.close() }
                windows = []
            }
        }
        var report = "# Цвета «Документа» против PDF Word\n\nФорм: \(checked); без расхождений: \(clean); расхождений: \(total).\n"
        if !byKind.isEmpty { report += "По видам: " + byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ".\n" }
        if !lines.isEmpty { report += "\n" + lines.joined(separator: "\n") + "\n" }
        print(report)
        if let out = environment["MU_WORD_COLORS_OUT"], !out.isEmpty {
            try report.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        }
        if environment["MU_WORD_COLORS_STRICT"] == "1" { XCTAssertEqual(total, 0, report) }
    }

    // MARK: - Наша раскладка (как в WordFidelityTests)

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
