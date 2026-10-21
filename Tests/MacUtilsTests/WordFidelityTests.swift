import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import MacUtils

/// «Документ» против эталона Word. Эталон — PDF, которые сделал сам Word из копий форм (`fNN.pdf` рядом с `fNN.rtf`).
/// Наша сторона раскладывается тем же путём, что в приложении (вкладка в «Документе», `DocPageView`, колонтитулы),
/// страницы рисуются в PDF офскрин; строки и линии извлекаются из обоих PDF одинаково (`WordFidelity`).
///   MU_WORD_REF_DIR=~/Projects/Cowork/Form/LAB-word-ref [MU_WORD_FIDELITY_OUT=…/word-fidelity.md] [MU_WORD_FIDELITY_STRICT=1]
///   swift test --filter WordFidelityTests
/// В отчёт — только числа, номера fNN и управляющие слова RTF; текст документов никуда не попадает.
@MainActor
final class WordFidelityTests: XCTestCase {
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

    private func line(_ page: Int, _ text: String, _ x: CGFloat, _ y: CGFloat) -> WordFidelity.Line {
        .init(page: page, text: text, rect: CGRect(x: x, y: y, width: 100, height: 12))
    }

    func testCompareIdenticalAndShifted() {
        let word = [line(0, "Первая строка", 72, 72), line(0, "Вторая  строка", 72, 86), line(1, "Третья", 72, 72)]
        let same = WordFidelity.compare(word: word, ours: word, pagesWord: 2, pagesOurs: 2, category: { _ in .body })
        XCTAssertTrue(same.identical)
        XCTAssertEqual(same.sameBreaks, 1)
        XCTAssertEqual(same.maxShift, 0)

        let shifted = word.map { var l = $0; l.rect.origin.x += 0.5; l.rect.origin.y += 3; return l }
        let result = WordFidelity.compare(word: word, ours: shifted, pagesWord: 2, pagesOurs: 2, category: { _ in .body })
        XCTAssertEqual(result.dx[.body]?.max ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.dy[.body]?.median ?? 0, 3, accuracy: 0.001)
        XCTAssertFalse(result.identical, "сдвиг 3 pt — не идентично")
        XCTAssertEqual(result.discrepancies.filter { $0.kind == .shiftY }.count, 3)
    }

    func testCellWrapMissingWordsAndPages() {
        let word = [line(0, "Номер счёта клиента", 300, 100), line(0, "Итого", 72, 120)]
        let ours = [line(0, "Номер счёта", 300, 100), line(0, "клиента", 300, 112), line(1, "Итого", 72, 72), line(1, "лишнее", 72, 90)]
        let result = WordFidelity.compare(word: word, ours: ours, pagesWord: 1, pagesOurs: 2,
                                          category: { $0.rect.minX >= 300 ? .table : .body })
        XCTAssertEqual(result.extraCellWraps, 1, "в ячейке перенос, которого у Word нет")
        XCTAssertEqual(result.sameBreaks, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.otherPage, 1, "«Итого» уехало на вторую страницу")
        XCTAssertEqual(result.extraWords, 1)
        XCTAssertEqual(result.missingWords, 0)
        XCTAssertFalse(result.identical)
    }

    func testStatsPercentiles() {
        let stats = WordFidelity.Stats((1...100).map { CGFloat($0) })
        XCTAssertEqual(stats.median, 51)
        XCTAssertEqual(stats.p95, 95)
        XCTAssertEqual(stats.max, 100)
        XCTAssertEqual(WordFidelity.Stats([-4, 2]).max, 4, "по модулю")
    }

    /// Наш PDF против нашего же: идентично, линии таблицы находятся — проверка извлечения на настоящей раскладке.
    func testOwnRenderingAgainstItself() throws {
        var rtf = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\froman Times New Roman;}}\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134"#
        rtf += #"\sectd{\header \pard\plain\fs20 Top\par}"#
        for number in 1...40 { rtf += #"\pard\plain\fs24 Paragraph "# + "\(number)" + #" with several words to fill the line\par "# }
        rtf += #"\trowd\trgaph108\trleft0\clbrdrt\brdrs\brdrw10\clbrdrb\brdrs\brdrw10 \cellx4000\clbrdrt\brdrs\brdrw10\clbrdrb\brdrs\brdrw10 \cellx8000 "#
        rtf += #"\pard\plain\intbl\fs20 Cell one\cell Cell two\cell\row\pard\plain\par}"#
        let document = try open(Data(rtf.utf8), name: "demo.rtf")
        let pdf = try render(document)
        let lines = WordFidelity.lines(pdf)
        XCTAssertGreaterThan(lines.count, 30)
        XCTAssertTrue(lines.contains { $0.text.contains("Cell two") })
        let segments = WordFidelity.segments(pdf)
        XCTAssertTrue(segments.contains { $0.horizontal }, "границы ячеек — отрезки")
        let result = WordFidelity.compare(word: lines, ours: lines, pagesWord: pdf.pageCount, pagesOurs: pdf.pageCount,
                                          category: { _ in .body }, wordSegments: segments, ourSegments: segments)
        XCTAssertTrue(result.identical)
        XCTAssertEqual(result.segmentsMatched, segments.count)
        let geometry = PageGeometry(document)
        XCTAssertTrue(lines.contains { geometry.category($0) == .table }, "строки ячеек — таблица")
        XCTAssertTrue(lines.contains { geometry.category($0) == .margins }, "колонтитул")
    }

    // MARK: - Прогон по эталону Word

    func testAgainstWordReference() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_WORD_REF_DIR=<папка с rtf/ и pdf/>")
        }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("pdf").path)
            .filter { $0.hasSuffix(".pdf") }.map { ($0 as NSString).deletingPathExtension }.sorted()
        XCTAssertFalse(names.isEmpty, "нет fNN.pdf")
        var report = FidelityReport()
        for name in names {
            let rtf = base.appendingPathComponent("rtf/\(name).rtf"), wordURL = base.appendingPathComponent("pdf/\(name).pdf")
            guard let data = try? Data(contentsOf: rtf), let wordPDF = PDFDocument(url: wordURL) else {
                report.failed.append(name)
                continue
            }
            autoreleasepool {
                do {
                    let document = try open(data, name: "\(name).rtf")
                    let ours = try render(document)
                    let geometry = PageGeometry(document)
                    let result = WordFidelity.compare(word: WordFidelity.lines(wordPDF), ours: WordFidelity.lines(ours),
                                                      pagesWord: wordPDF.pageCount, pagesOurs: ours.pageCount,
                                                      category: geometry.category, wordSegments: WordFidelity.segments(wordPDF),
                                                      ourSegments: WordFidelity.segments(ours))
                    report.add(name, result, constructs: geometry.constructs)
                } catch {
                    report.failed.append(name)
                }
                for window in windows { window.contentView = nil; window.close() }
                windows = []
            }
        }
        let text = report.markdown()
        print(text)
        if let out = ProcessInfo.processInfo.environment["MU_WORD_FIDELITY_OUT"], !out.isEmpty {
            try text.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        }
        if ProcessInfo.processInfo.environment["MU_WORD_FIDELITY_STRICT"] == "1" {
            XCTAssertEqual(report.identical, report.files.count, "идентично Word: \(report.identical) из \(report.files.count)")
        }
    }

    // MARK: - Наша раскладка

    /// Вкладка в «Документе» — как в приложении: окно офскрин, на экран не выводится (`ScreenOutput`).
    private func open(_ data: Data, name: String) throws -> DocumentController {
        let workspace = EditorWorkspace()
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

    /// Страницы «Документа» → один PDF (векторный текст и линии, как при печати).
    private func render(_ document: DocumentController) throws -> PDFDocument {
        let pages = document.pagesView.pages
        let result = PDFDocument()
        for (index, page) in pages.enumerated() {
            page.layoutSubtreeIfNeeded()
            let data = page.dataWithPDF(inside: page.bounds)
            guard let single = PDFDocument(data: data)?.page(at: 0) else { continue }
            result.insert(single, at: index)
        }
        XCTAssertEqual(result.pageCount, pages.count)
        return result
    }
}

/// Где на наших страницах тело, колонтитулы и ячейки таблиц, и какими свойствами RTF задана строка.
@MainActor
private struct PageGeometry {
    struct Page {
        var body: CGRect
        var tables: [CGRect]
        var header: NSAttributedString?
        var footer: NSAttributedString?
    }

    let pages: [Page]
    let storage: NSAttributedString

    init(_ document: DocumentController) {
        storage = NSAttributedString(attributedString: document.storage)
        let manager = document.layoutManager
        var tableRanges: [NSRange] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let style = value as? NSParagraphStyle, style.textBlocks.contains(where: { $0 is NSTextTableBlock }) { tableRanges.append(range) }
        }
        pages = document.pagesView.pages.map { page in
            let glyphs = manager.glyphRange(for: page.container)
            let origin = page.textView.frame.origin
            let tables: [CGRect] = tableRanges.compactMap { characters in
                let range = NSIntersectionRange(manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil), glyphs)
                guard range.length > 0 else { return nil }
                return manager.boundingRect(forGlyphRange: range, in: page.container).offsetBy(dx: origin.x, dy: origin.y)
            }
            return Page(body: page.bodyRect, tables: tables, header: page.header, footer: page.footer)
        }
    }

    func category(_ line: WordFidelity.Line) -> WordFidelity.Category {
        guard line.page < pages.count else { return .body }
        let page = pages[line.page]
        if line.rect.maxY <= page.body.minY + 1 || line.rect.minY >= page.body.maxY - 1 { return .margins }
        let center = CGPoint(x: line.rect.midX, y: line.rect.midY)
        return page.tables.contains { $0.insetBy(dx: -2, dy: -2).contains(center) } ? .table : .body
    }

    /// Управляющие слова RTF, которыми задан абзац строки (для топа причин; без текста).
    func constructs(_ line: WordFidelity.Line) -> [String] {
        let probe = String(line.key.prefix(40))
        var sources: [NSAttributedString] = [storage]
        if line.page < pages.count { sources += [pages[line.page].header, pages[line.page].footer].compactMap { $0 } }
        for source in sources {
            let text = source.string.split(whereSeparator: \.isWhitespace).joined(separator: " ") as NSString
            let found = text.range(of: probe)
            guard found.location != NSNotFound else { continue }
            // Позиция в сжатом по пробелам тексте ~ позиция в исходном: берём ближайший символ того же слова.
            let original = (source.string as NSString).range(of: String(probe.prefix(12)))
            let index = original.location != NSNotFound ? original.location : min(found.location, max(0, source.length - 1))
            return Self.words(source.attributes(at: min(index, max(0, source.length - 1)), effectiveRange: nil))
        }
        return ["(абзац не найден)"]
    }

    static func words(_ attributes: [NSAttributedString.Key: Any]) -> [String] {
        var words: [String] = []
        if let paragraph = (attributes[.docPara] as? DocParaInfo)?.props {
            if paragraph.inTable { words += ["\\cellx", "\\trgaph"] }
            if paragraph.left != 0 { words.append("\\li") }
            if paragraph.right != 0 { words.append("\\ri") }
            if paragraph.firstLine != 0 { words.append("\\fi") }
            if paragraph.spaceBefore != 0 { words.append("\\sb") }
            if paragraph.spaceAfter != 0 { words.append("\\sa") }
            if paragraph.lineSpacing != 0 { words.append(paragraph.lineMultiple ? "\\sl\\slmult1" : "\\sl") }
            for tab in paragraph.tabs {
                switch tab.kind {
                case .right: words.append("\\tqr")
                case .center: words.append("\\tqc")
                case .decimal: words.append("\\tqdec")
                case .bar: words.append("\\tb")
                case .left: words.append("\\tx")
                }
                if tab.leader { words.append("\\tl…") }
            }
            switch paragraph.alignment {
            case .center: words.append("\\qc")
            case .right: words.append("\\qr")
            case .justify: words.append("\\qj")
            default: break
            }
            if paragraph.hasBorders { words.append("\\brdr…") }
        }
        if let character = attributes[.docChar] as? DocCharInfo {
            if character.fontName != character.displayFont { words.append("шрифт: замена") }
            if character.props.halfPoints != 24 { words.append("\\fs") }
            if character.props.caps || character.props.smallCaps { words.append("\\caps/\\scaps") }
        }
        return Array(Set(words)).sorted()
    }
}

/// Сводка прогона: по файлам и топ причин по категориям. Только числа, fNN и управляющие слова.
private struct FidelityReport {
    struct File {
        let name: String
        let result: WordFidelity.Result
    }

    var files: [File] = []
    var failed: [String] = []
    /// (вид расхождения, категория) → управляющее слово → (число строк, файлы).
    private var causes: [String: [String: (count: Int, files: Set<String>)]] = [:]

    var identical: Int { files.filter(\.result.identical).count }

    mutating func add(_ name: String, _ result: WordFidelity.Result, constructs: (WordFidelity.Line) -> [String]) {
        files.append(File(name: name, result: result))
        for discrepancy in result.discrepancies {
            let key = "\(discrepancy.kind.rawValue) · \(discrepancy.category.rawValue)"
            let words = constructs(discrepancy.ours)
            for word in words.isEmpty ? ["(без особых свойств)"] : words {
                var entry = causes[key, default: [:]][word, default: (0, [])]
                entry.count += 1
                entry.files.insert(name)
                causes[key, default: [:]][word] = entry
            }
        }
    }

    private static func pt(_ value: CGFloat) -> String { String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",") }
    private static func percent(_ value: Double) -> String { String(format: "%.0f %%", value * 100) }

    func markdown() -> String {
        var lines: [String] = ["# «Документ» против Word: сравнение по PDF", ""]
        lines.append("Файлов: \(files.count), не открылись: \(failed.count)\(failed.isEmpty ? "" : " (\(failed.joined(separator: ", ")))").")
        lines.append("Идентично Word (страницы совпадают, разрывы строк 100 %, сдвиг ≤ 1 pt, слова на месте): **\(identical) из \(files.count)**.")
        let pagesOK = files.filter { $0.result.pagesWord == $0.result.pagesOurs }.count
        let breaks = files.map(\.result.sameBreaks)
        lines.append("Число страниц совпадает: \(pagesOK) из \(files.count). Разрывы строк — медиана по файлам \(Self.percent(median(breaks))), худший \(Self.percent(breaks.min() ?? 1)).")
        lines.append("")
        lines.append("## По файлам")
        lines.append("Сдвиги — |наш − Word| в pt: медиана / p95 / max; по X и по Y.")
        lines.append("")
        lines.append("| Файл | Стр. Word / наши | Разрывы строк | Тело X | Тело Y | Таблицы X | Таблицы Y | Колонтитулы X | Колонтитулы Y | Лишние переносы в ячейках | На другой стр. | Нет слов / лишние | Линии: найдено / сдвиг max |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        func stats(_ s: WordFidelity.Stats?) -> String {
            guard let s, s.count > 0 else { return "—" }
            return "\(Self.pt(s.median)) / \(Self.pt(s.p95)) / \(Self.pt(s.max))"
        }
        for file in files {
            let r = file.result
            let segments = r.segmentsWord == 0 ? "—" : "\(r.segmentsMatched) из \(r.segmentsWord) / \(Self.pt(r.segmentOffset.max))"
            lines.append("| \(file.name)\(r.identical ? " ✓" : "") | \(r.pagesWord) / \(r.pagesOurs) | \(Self.percent(r.sameBreaks)) | "
                + "\(stats(r.dx[.body])) | \(stats(r.dy[.body])) | \(stats(r.dx[.table])) | \(stats(r.dy[.table])) | "
                + "\(stats(r.dx[.margins])) | \(stats(r.dy[.margins])) | \(r.extraCellWraps) | \(r.otherPage) | \(r.missingWords) / \(r.extraWords) | \(segments) |")
        }
        lines.append("")
        lines.append("## Топ-10 причин по видам расхождений")
        lines.append("Управляющие слова абзаца нашей строки, где расхождение; число строк и файлов. Одна строка может дать несколько слов.")
        for key in causes.keys.sorted() {
            let top = causes[key]!.sorted { $0.value.count > $1.value.count }.prefix(10)
            let total = causes[key]!.values.map(\.count).max() ?? 0
            lines.append("")
            lines.append("**\(key)** (строк — до \(total))")
            lines.append("")
            for (word, entry) in top {
                lines.append("- `\(word)` — \(entry.count) строк в \(entry.files.count) файлах (\(entry.files.sorted().prefix(6).joined(separator: ", "))\(entry.files.count > 6 ? ", …" : ""))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 1 : sorted[sorted.count / 2]
    }
}
