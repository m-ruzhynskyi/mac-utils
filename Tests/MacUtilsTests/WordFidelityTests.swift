import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import MacUtils

/// «Документ» против эталона Word. Эталон — PDF, которые сделал сам Word из копий форм (`pdf/fNNN.pdf` к `rtf/fNNN.rtf`).
/// Наша сторона раскладывается тем же путём, что в приложении (вкладка в «Документе», `DocPageView`, колонтитулы),
/// страницы рисуются в PDF офскрин; строки и линии извлекаются из обоих PDF одинаково (`WordFidelity`).
///   MU_WORD_REF_DIR=~/Projects/Cowork/Form/LAB-word-ref [MU_WORD_REF_SUBSET_DIR=~/Projects/Cowork/Form/LAB]
///   [MU_WORD_REF_ONLY=f001,f002] [MU_WORD_FIDELITY_OUT=…/word-fidelity.md] [MU_WORD_FIDELITY_STRICT=1]
///   swift test --filter WordFidelityTests
/// Подмножество — копии, побайтно совпадающие с файлами из MU_WORD_REF_SUBSET_DIR: отдельная сводка.
/// Гейт (`WordGate`, обычно через `scripts/word-gate.sh`): MU_WORD_FIDELITY_GATE=1 — падение, если форма хуже базы
/// (MU_WORD_FIDELITY_BASELINE, по умолчанию `<MU_WORD_REF_DIR>/baseline.tsv`); MU_WORD_FIDELITY_WRITE_BASELINE=1 —
/// записать прогон как базу; MU_WORD_FIDELITY_TSV — числа прогона в файл; MU_WORD_REF_SHARD=i/n — доля форм для
/// параллельного прогона; MU_WORD_GATE_OUT — сводка «было/стало».
/// В отчёт — только числа, номера fNNN и управляющие слова RTF; текст документов никуда не попадает.
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
        XCTAssertEqual(result.pitch[.body], [0], "сдвиг целиком — шаг строк тот же")
        XCTAssertEqual(result.firstOffset?.y ?? 0, 3, accuracy: 0.001)

        var drifting = word
        drifting[1].rect.origin.y += 2
        XCTAssertEqual(WordFidelity.compare(word: word, ours: drifting, pagesWord: 2, pagesOurs: 2, category: { _ in .body }).pitch[.body], [2],
                       "строка ниже на 2 pt — шаг больше на 2")
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

    /// Повтор одной строки в другом месте не сбивает пары: якорь — уникальная строка, повторы — по месту.
    func testRepeatedLinesPairByPlace() {
        let word = [line(0, "Шапка", 72, 72), line(0, "____", 72, 100), line(0, "Середина", 72, 400), line(0, "____", 72, 430)]
        // У нас первая «____» потерялась: вторая не должна спариться с первой Word (300 pt выше).
        let ours = [line(0, "Шапка", 72, 72), line(0, "Середина", 72, 402), line(0, "____", 72, 432)]
        let pairs = WordFidelity.align(word, ours)
        XCTAssertEqual(pairs.map(\.0), [0, 2, 3])
        XCTAssertEqual(pairs.map(\.1), [0, 1, 2])
        // Порядок строк у нас другой (соседние ячейки), пары те же.
        let swapped = [ours[1], ours[2], ours[0]]
        XCTAssertEqual(WordFidelity.align(word, swapped).map(\.0), [0, 2, 3])
    }

    /// Базовая линия — по началам текста в рамке строки, если она у обеих строк; иначе — верх рамки.
    func testBaselineFromTextOrigins() {
        let rect = CGRect(x: 72, y: 100, width: 200, height: 14)
        let origins = [CGPoint(x: 72, y: 111), CGPoint(x: 150, y: 111), CGPoint(x: 200, y: 108), CGPoint(x: 72, y: 300)]
        XCTAssertEqual(WordFidelity.baseline(of: rect, among: origins), 111)
        XCTAssertNil(WordFidelity.baseline(of: rect, among: [CGPoint(x: 400, y: 111)]))
        var a = line(0, "x", 72, 100), b = line(0, "x", 72, 103)
        XCTAssertEqual(WordFidelity.top(a, b).1 - WordFidelity.top(a, b).0, 3)
        a.baseline = 111; b.baseline = 111.5
        XCTAssertEqual(WordFidelity.top(a, b).1 - WordFidelity.top(a, b).0, 0.5, accuracy: 0.001, "другой шрифт, та же базовая линия")
    }

    /// Растр своего же PDF против себя — 0 %; против пустого листа — доля закрашенного; старая база без колонок читается.
    func testVisualComparison() throws {
        var rtf = #"{\rtf1\ansi\deff0{\fonttbl{\f0\froman Times New Roman;}}{\colortbl;\red200\green0\blue0;}\paperw11906\paperh16838"#
        for number in 1...30 { rtf += #"\pard\plain\fs24 Line "# + "\(number)" + #" of demo text\par "# }
        rtf += #"\pard\plain\cf1\fs24 Red line\par}"#
        let pdf = try render(try open(Data(rtf.utf8), name: "visual.rtf"))
        let lines = WordFidelity.lines(pdf)
        let same = WordVisual.compare(word: pdf, ours: pdf, wordLines: lines, ourLines: lines, wordSegments: [], ourSegments: [])
        XCTAssertEqual(same.maxDifference, 0)
        XCTAssertTrue(same.identical)
        XCTAssertGreaterThan(same.inked[.text] ?? 0, 1000, "текст попал в область «текст»")
        XCTAssertEqual(same.color(.text), 0)

        let blank = WordVisual.compare(word: pdf, ours: PDFDocument(), wordLines: lines, ourLines: [], wordSegments: [], ourSegments: [])
        XCTAssertEqual(blank.pages.count, pdf.pageCount, "нет нашей страницы — против пустого листа")
        XCTAssertGreaterThan(blank.maxDifference, 0.005)
        XCTAssertFalse(blank.identical)

        // Тот же текст другим цветом: пикселей почти не меньше, а «цвет другой» в тексте — почти весь.
        let red = try render(try open(Data(rtf.replacingOccurrences(of: #"\cf1"#, with: "").replacingOccurrences(of: #"\fs24 Line"#, with: #"\cf1\fs24 Line"#).utf8), name: "red.rtf"))
        let colored = WordVisual.compare(word: pdf, ours: red, wordLines: lines, ourLines: WordFidelity.lines(red), wordSegments: [], ourSegments: [])
        XCTAssertGreaterThan(colored.color(.text), 0.5, "чёрный против красного")

        var row = WordGate.Row(name: "f001")
        row.add(same)
        XCTAssertEqual(WordGate.rows(WordGate.tsv([row])).first?.visualIdentical, true)
        let old = WordGate.Row.header.prefix(WordGate.Row.headerWithoutVisual).joined(separator: "\t") + "\n"
            + WordGate.Row(name: "f002").fields.prefix(WordGate.Row.headerWithoutVisual).joined(separator: "\t")
        XCTAssertEqual(WordGate.rows(old).first.map { ($0.name, $0.hasVisual) }?.1, false)
        var worse = row
        worse.visualMax = 0.01
        XCTAssertEqual(WordGate.worse(worse, than: row), ["пиксели 0,00 % → 1,00 %"])
    }

    func testGateRulesAndTSV() {
        var base = WordGate.Row(name: "f001")
        base.pagesWord = 2; base.pagesOurs = 3; base.breaks = 0.9; base.shiftP95 = 4; base.cellWraps = 2; base.extraWords = 5
        XCTAssertEqual(WordGate.rows(WordGate.tsv([base])), [base], "TSV туда и обратно")
        XCTAssertTrue(WordGate.worse(base, than: base).isEmpty)

        var now = base
        now.shiftP95 = 4.4; now.breaks = 0.8996
        XCTAssertTrue(WordGate.worse(now, than: base).isEmpty, "в допусках")
        now.pagesOurs = 4; now.breaks = 0.85; now.shiftP95 = 4.6; now.cellWraps = 3; now.extraWords = 6
        XCTAssertEqual(WordGate.worse(now, than: base).count, 5)
        XCTAssertEqual(WordGate.worse(WordGate.Row(name: "f001", failed: true), than: base), ["не открылась"])

        var improved = base
        improved.pagesOurs = 2
        let comparison = WordGate.compare([improved, WordGate.Row(name: "f009")], base: [base, WordGate.Row(name: "f002")])
        XCTAssertTrue(comparison.passed)
        XCTAssertEqual(comparison.better.map(\.name), ["f001"])
        XCTAssertEqual(comparison.added, ["f009"])
        XCTAssertEqual(comparison.missing, ["f002"])
        XCTAssertTrue(WordGate.markdown(now: [now], base: [base]).contains("f001: страницы 2/3 → 2/4"))
    }

    func testStatsPercentiles() {
        let stats = WordFidelity.Stats((1...100).map { CGFloat($0) })
        XCTAssertEqual(stats.median, 51)
        XCTAssertEqual(stats.p95, 95)
        XCTAssertEqual(stats.max, 100)
        XCTAssertEqual(WordFidelity.Stats([-4, 2]).max, 4, "по модулю")
        XCTAssertEqual(WordFidelity.Stats([-4, 2, -1]).signedMedian, -1, "со знаком")
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
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MU_WORD_REF_DIR"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_WORD_REF_DIR=<папка с rtf/ и pdf/>")
        }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let manager = FileManager.default
        var names = try manager.contentsOfDirectory(atPath: base.appendingPathComponent("rtf").path)
            .filter { $0.hasSuffix(".rtf") && !$0.hasPrefix("~") }.map { ($0 as NSString).deletingPathExtension }.sorted()
        XCTAssertFalse(names.isEmpty, "нет fNNN.rtf")
        if let only = environment["MU_WORD_REF_ONLY"], !only.isEmpty {
            let wanted = Set(only.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            names = names.filter(wanted.contains)
        }
        if let shard = environment["MU_WORD_REF_SHARD"], !shard.isEmpty {
            let parts = shard.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 2, parts[1] > 0, (0..<parts[1]).contains(parts[0]) else { throw XCTSkip("MU_WORD_REF_SHARD=i/n") }
            names = names.enumerated().filter { $0.offset % parts[1] == parts[0] }.map(\.element)
        }
        // Уже сделанные и зависшие формы (сторож scripts/word-gate.sh перезапускает долю без них).
        let skipped = Set((environment["MU_WORD_REF_SKIP"] ?? "").split(separator: ",").map(String.init))
        names = names.filter { !skipped.contains($0) }
        var report = FidelityReport()
        var rows: [WordGate.Row] = []
        if let subset = environment["MU_WORD_REF_SUBSET_DIR"], !subset.isEmpty {
            let folder = URL(fileURLWithPath: (subset as NSString).expandingTildeInPath)
            report.subsetLabel = folder.lastPathComponent
            report.subset = Self.copies(of: folder, among: names.map { base.appendingPathComponent("rtf/\($0).rtf") })
        }
        for name in names {
            let rtf = base.appendingPathComponent("rtf/\(name).rtf"), wordURL = base.appendingPathComponent("pdf/\(name).pdf")
            guard manager.fileExists(atPath: wordURL.path) else {
                report.noReference.append(name)
                continue
            }
            guard let data = try? Data(contentsOf: rtf), let wordPDF = PDFDocument(url: wordURL) else {
                report.failed.append(name)
                rows.append(WordGate.Row(name: name, failed: true))
                Self.append(rows[rows.count - 1])
                continue
            }
            let started = Date()
            // Сторож скрипта смотрит на эти строки: нет новой дольше таймаута — форма зависла (раскладка не кончается).
            Self.progress("word-fidelity start \(name)")
            autoreleasepool {
                do {
                    let document = try open(data, name: "\(name).rtf")
                    let ours = try render(document)
                    let geometry = PageGeometry(document)
                    let ourLines = WordFidelity.lines(ours), wordLines = WordFidelity.lines(wordPDF)
                    let wordSegments = WordFidelity.segments(wordPDF), ourSegments = WordFidelity.segments(ours)
                    var result = WordFidelity.compare(word: wordLines, ours: ourLines,
                                                      pagesWord: wordPDF.pageCount, pagesOurs: ours.pageCount,
                                                      category: geometry.category, wordSegments: wordSegments, ourSegments: ourSegments)
                    let sizes = zip(WordFidelity.pageSizes(wordPDF), WordFidelity.pageSizes(ours))
                    result.sizeMismatch = sizes.contains { abs($0.width - $1.width) > 1 || abs($0.height - $1.height) > 1 }
                    report.add(name, result, lines: ourLines, category: geometry.category, constructs: geometry.constructs)
                    var row = WordGate.Row(name: name, result)
                    // Растры только в памяти (реальные формы): ни файлов, ни снимков. MU_WORD_VISUAL=0 — без них.
                    if environment["MU_WORD_VISUAL"] != "0" {
                        // Строка на каждую страницу — сторож скрипта видит, что длинная форма не зависла.
                        row.add(WordVisual.compare(word: wordPDF, ours: ours, wordLines: wordLines, ourLines: ourLines,
                                                   wordSegments: wordSegments, ourSegments: ourSegments) { Self.progress("word-fidelity \(name) пиксели, стр. \($0 + 1)") })
                    }
                    rows.append(row)
                } catch {
                    report.failed.append(name)
                    rows.append(WordGate.Row(name: name, failed: true))
                }
                if let row = rows.last, row.name == name { Self.append(row) }
                for window in windows { window.contentView = nil; window.close() }
                windows = []
            }
            Self.progress("word-fidelity \(name): \(String(format: "%.1f", Date().timeIntervalSince(started))) с")
        }
        let text = report.markdown()
        print(text)
        if let out = environment["MU_WORD_FIDELITY_OUT"], !out.isEmpty {
            try text.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        }
        if environment["MU_WORD_FIDELITY_STRICT"] == "1" {
            XCTAssertEqual(report.identical, report.files.count, "идентично Word: \(report.identical) из \(report.files.count)")
        }
        let baseline = Self.baselinePath(base)
        if environment["MU_WORD_FIDELITY_GATE"] == "1" { try gate(rows, baseline: baseline) }
        if environment["MU_WORD_FIDELITY_WRITE_BASELINE"] == "1" {
            try WordGate.tsv(rows).write(toFile: baseline, atomically: true, encoding: .utf8)
            print("word-gate: база записана, форм \(rows.count)")
        }
    }

    /// Строка прогресса сразу в вывод (без буфера: по ней сторож ловит зависание).
    private static func progress(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// Числа формы — сразу в MU_WORD_FIDELITY_TSV (дописываем): если процесс снимут, готовое не теряется.
    private static func append(_ row: WordGate.Row) {
        guard let out = ProcessInfo.processInfo.environment["MU_WORD_FIDELITY_TSV"], !out.isEmpty else { return }
        let path = (out as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data((WordGate.Row.header.joined(separator: "\t") + "\n").utf8))
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((row.fields.joined(separator: "\t") + "\n").utf8))
        handle.closeFile()
    }

    /// Гейт по готовым числам прогона (склейка TSV шардов из `scripts/word-gate.sh`): раскладки здесь нет.
    func testGateFromResults() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let results = environment["MU_WORD_FIDELITY_RESULTS"], !results.isEmpty else {
            throw XCTSkip("Задайте MU_WORD_FIDELITY_RESULTS=<TSV прогона> (scripts/word-gate.sh)")
        }
        let rows = WordGate.rows(try String(contentsOfFile: (results as NSString).expandingTildeInPath, encoding: .utf8))
        XCTAssertFalse(rows.isEmpty, "в TSV прогона нет форм")
        let base = URL(fileURLWithPath: ((environment["MU_WORD_REF_DIR"] ?? "") as NSString).expandingTildeInPath)
        try gate(rows, baseline: Self.baselinePath(base))
    }

    private static func baselinePath(_ reference: URL) -> String {
        let custom = ProcessInfo.processInfo.environment["MU_WORD_FIDELITY_BASELINE"] ?? ""
        return custom.isEmpty ? reference.appendingPathComponent("baseline.tsv").path : (custom as NSString).expandingTildeInPath
    }

    /// Сравнить с базой: сводка «было/стало» (MU_WORD_GATE_OUT), падение по каждой форме хуже базы.
    private func gate(_ rows: [WordGate.Row], baseline: String) throws {
        guard let text = try? String(contentsOfFile: baseline, encoding: .utf8) else {
            XCTFail("Нет базы гейта; создайте её: scripts/word-gate.sh --update (или MU_WORD_FIDELITY_WRITE_BASELINE=1)")
            return
        }
        let base = WordGate.rows(text)
        let seconds = Double(ProcessInfo.processInfo.environment["MU_WORD_GATE_SECONDS"] ?? "")
        let summary = WordGate.markdown(now: rows, base: base, seconds: seconds)
        print(summary)
        if let out = ProcessInfo.processInfo.environment["MU_WORD_GATE_OUT"], !out.isEmpty {
            try summary.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        }
        for item in WordGate.compare(rows, base: base).worse {
            XCTFail("\(item.name) хуже базы: \(item.what.joined(separator: "; "))")
        }
    }

    /// Какие копии побайтно совпадают с файлами папки — подмножество без списка имён (map.tsv не нужен).
    private static func copies(of folder: URL, among copies: [URL]) -> Set<String> {
        let originals = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL } ?? [])
        var bySize: [Int: [URL]] = [:]
        for url in originals {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { bySize[size, default: []].append(url) }
        }
        var found: Set<String> = []
        for copy in copies {
            guard let size = try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize, let candidates = bySize[size],
                  let data = try? Data(contentsOf: copy) else { continue }
            if candidates.contains(where: { (try? Data(contentsOf: $0)) == data }) {
                found.insert(copy.deletingPathExtension().lastPathComponent)
            }
        }
        return found
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

/// Сводка прогона: общая и по подмножеству, по файлам и топ причин. Только числа, fNNN и управляющие слова.
private struct FidelityReport {
    struct File {
        let name: String
        let result: WordFidelity.Result
        /// (вид расхождения · категория) → управляющее слово → число строк.
        let causes: [String: [String: Int]]
        /// Все наши строки: категория → управляющее слово → число строк (база для «подъёма» причины).
        let base: [WordFidelity.Category: [String: Int]]
        let lines: [WordFidelity.Category: Int]
    }

    var files: [File] = []
    var failed: [String] = []
    /// Word не сделал PDF (ошибка Word или ещё не готово).
    var noReference: [String] = []
    var subset: Set<String> = []
    var subsetLabel = ""

    var identical: Int { files.filter(\.result.identical).count }

    mutating func add(_ name: String, _ result: WordFidelity.Result, lines: [WordFidelity.Line],
                      category: (WordFidelity.Line) -> WordFidelity.Category, constructs: (WordFidelity.Line) -> [String]) {
        func words(_ line: WordFidelity.Line) -> [String] {
            let found = constructs(line)
            return found.isEmpty ? ["(без особых свойств)"] : found
        }
        var causes: [String: [String: Int]] = [:]
        for discrepancy in result.discrepancies {
            let key = "\(discrepancy.kind.rawValue) · \(discrepancy.category.rawValue)"
            for word in words(discrepancy.ours) { causes[key, default: [:]][word, default: 0] += 1 }
        }
        var base: [WordFidelity.Category: [String: Int]] = [:], counts: [WordFidelity.Category: Int] = [:]
        for line in lines {
            let kind = category(line)
            counts[kind, default: 0] += 1
            for word in words(line) { base[kind, default: [:]][word, default: 0] += 1 }
        }
        files.append(File(name: name, result: result, causes: causes, base: base, lines: counts))
    }

    private static func pt(_ value: CGFloat) -> String { String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",") }
    private static func signed(_ value: CGFloat) -> String { (value > 0.05 ? "+" : "") + pt(value) }
    private static func percent(_ value: Double) -> String { String(format: "%.0f %%", value * 100) }
    private static func list(_ names: [String]) -> String { names.isEmpty ? "" : " (\(names.joined(separator: ", ")))" }

    func markdown() -> String {
        var lines: [String] = ["# «Документ» против Word: сравнение по PDF", ""]
        lines.append("Порог «идентично»: число страниц совпадает, разрывы строк 100 %, сдвиг строк ≤ 1 pt, слова на месте.")
        lines.append("Без PDF Word: \(noReference.count)\(Self.list(noReference)). Не открылись: \(failed.count)\(Self.list(failed)).")
        if !subsetLabel.isEmpty {
            lines += summary(files.filter { subset.contains($0.name) }, title: "Сводка: подмножество \(subsetLabel)")
        }
        lines += summary(files, title: "Сводка: все формы")
        lines.append("")
        lines.append("## По файлам")
        lines.append("Сдвиги — |наш − Word| в pt: медиана / p95 / max; по X и по Y.\(subsetLabel.isEmpty ? "" : " «\(subsetLabel)» — файл из подмножества.")")
        lines.append("")
        lines.append("| Файл | Стр. Word / наши | Разрывы строк | Тело X | Тело Y | Таблицы X | Таблицы Y | Колонтитулы X | Колонтитулы Y | Лишние переносы в ячейках | На другой стр. | Нет слов / лишние | Линии: найдено / сдвиг max | Первая строка X / Y |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        func stats(_ s: WordFidelity.Stats?) -> String {
            guard let s, s.count > 0 else { return "—" }
            return "\(Self.pt(s.median)) / \(Self.pt(s.p95)) / \(Self.pt(s.max))"
        }
        for file in files {
            let r = file.result
            let segments = r.segmentsWord == 0 ? "—" : "\(r.segmentsMatched) из \(r.segmentsWord) / \(Self.pt(r.segmentOffset.max))"
            let first = r.firstOffset.map { "\(Self.signed($0.x)) / \(Self.signed($0.y))" } ?? "—"
            let mark = (subset.contains(file.name) ? " \(subsetLabel)" : "") + (r.identical ? " ✓" : "")
            lines.append("| \(file.name)\(mark) | \(r.pagesWord) / \(r.pagesOurs) | \(Self.percent(r.sameBreaks)) | "
                + "\(stats(r.dx[.body])) | \(stats(r.dy[.body])) | \(stats(r.dx[.table])) | \(stats(r.dy[.table])) | "
                + "\(stats(r.dx[.margins])) | \(stats(r.dy[.margins])) | \(r.extraCellWraps) | \(r.otherPage) | \(r.missingWords) / \(r.extraWords) | \(segments) | \(first) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Итоги по группе файлов и топ-10 причин по каждому виду расхождений.
    private func summary(_ group: [File], title: String) -> [String] {
        var lines = ["", "## \(title)", ""]
        guard !group.isEmpty else { return lines + ["Нет файлов с эталоном."] }
        let identical = group.filter(\.result.identical).count
        let pagesOK = group.filter { $0.result.pagesWord == $0.result.pagesOurs }.count
        let breaks = group.map(\.result.sameBreaks)
        let fullBreaks = group.filter { $0.result.sameBreaks >= 1 }.count
        lines.append("- Идентично Word: **\(identical) из \(group.count)**.")
        lines.append("- Число страниц совпадает: \(pagesOK) из \(group.count); больше, чем у Word: \(group.filter { $0.result.pagesOurs > $0.result.pagesWord }.count), меньше: \(group.filter { $0.result.pagesOurs < $0.result.pagesWord }.count).")
        let first = group.compactMap(\.result.firstOffset)
        lines.append("- Размер страниц отличается от Word: \(group.filter(\.result.sizeMismatch).count) из \(group.count).")
        lines.append("- Первая строка (до накопления сдвигов), наш − Word со знаком: медиана X \(Self.pt(CGFloat(median(first.map { Double($0.x) })))) / Y \(Self.pt(CGFloat(median(first.map { Double($0.y) })))) pt; |Y| ≤ 1 pt в \(first.filter { abs($0.y) <= 1 }.count) из \(first.count).")
        lines.append("- Разрывы строк 100 %: \(fullBreaks) из \(group.count); медиана по файлам \(Self.percent(median(breaks))), худший \(Self.percent(breaks.min() ?? 1)).")
        for category in [WordFidelity.Category.body, .table, .margins] {
            let x = group.compactMap { $0.result.dx[category] }.filter { $0.count > 0 }
            let y = group.compactMap { $0.result.dy[category] }.filter { $0.count > 0 }
            guard !x.isEmpty || !y.isEmpty else { continue }
            let within = group.filter { ($0.result.dx[category]?.count ?? 0) > 0 && max($0.result.dx[category]?.max ?? 0, $0.result.dy[category]?.max ?? 0) <= 1 }.count
            let pitch = group.flatMap { $0.result.pitch[category] ?? [] }
            let pitchText = pitch.isEmpty ? "" : "; шаг строк наш − Word: медиана \(Self.signed(CGFloat(median(pitch.map(Double.init))))) pt, |Δ| ≤ 0,5 pt у \(Self.percent(Double(pitch.filter { abs($0) <= 0.5 }.count) / Double(pitch.count))) пар, больше +0,5 у \(Self.percent(Double(pitch.filter { $0 > 0.5 }.count) / Double(pitch.count))), меньше −0,5 у \(Self.percent(Double(pitch.filter { $0 < -0.5 }.count) / Double(pitch.count)))"
            let signedX = Self.signed(CGFloat(median(x.map { Double($0.signedMedian) })))
            let signedY = Self.signed(CGFloat(median(y.map { Double($0.signedMedian) })))
            lines.append("- \(category.rawValue.capitalized): файлов \(x.count), сдвиг ≤ 1 pt в \(within); со знаком (наш − Word, + — правее/ниже) X \(signedX) / Y \(signedY) pt; медиана модулей X \(Self.pt(CGFloat(median(x.map { Double($0.median) })))) / Y \(Self.pt(CGFloat(median(y.map { Double($0.median) })))) pt, max X \(Self.pt(x.map(\.max).max() ?? 0)) / Y \(Self.pt(y.map(\.max).max() ?? 0)) pt\(pitchText).")
        }
        lines.append("- Лишние переносы в ячейках: \(group.map(\.result.extraCellWraps).reduce(0, +)) строк в \(group.filter { $0.result.extraCellWraps > 0 }.count) файлах; строк на другой странице: \(group.map(\.result.otherPage).reduce(0, +)); слов нет / лишние: \(group.map(\.result.missingWords).reduce(0, +)) / \(group.map(\.result.extraWords).reduce(0, +)).")
        let worst = group.filter { !$0.result.identical }.sorted { $0.result.sameBreaks < $1.result.sameBreaks }.prefix(10).map(\.name)
        if !worst.isEmpty { lines.append("- Худшие по разрывам строк: \(worst.joined(separator: ", ")).") }

        var causes: [String: [String: (count: Int, files: Set<String>)]] = [:]
        var base: [String: [String: Int]] = [:], totals: [String: Int] = [:]
        for file in group {
            for (key, words) in file.causes {
                for (word, count) in words {
                    var entry = causes[key, default: [:]][word, default: (0, [])]
                    entry.count += count
                    entry.files.insert(file.name)
                    causes[key, default: [:]][word] = entry
                }
            }
            for (category, words) in file.base {
                totals[category.rawValue, default: 0] += file.lines[category] ?? 0
                for (word, count) in words { base[category.rawValue, default: [:]][word, default: 0] += count }
            }
        }
        lines.append("")
        lines.append("### Топ-10 причин")
        lines.append("Управляющие слова абзаца нашей строки, где расхождение. «Подъём» — во сколько раз слово чаще среди строк с этим расхождением, "
            + "чем среди всех наших строк той же категории (> 1 — связано с расхождением, ≈ 1 — просто встречается везде). "
            + "Порядок — по подъёму среди слов с ≥ 20 строками в ≥ 3 файлах, затем остальные по числу строк.")
        for key in causes.keys.sorted() {
            let category = String(key.split(separator: "·").last ?? "").trimmingCharacters(in: .whitespaces)
            let entries = causes[key]!
            let discrepant = discrepancyCount(group, key: key)
            func lift(_ word: String, _ count: Int) -> Double {
                let all = Double(base[category]?[word] ?? 0), total = Double(totals[category] ?? 0)
                guard all > 0, total > 0, discrepant > 0 else { return 0 }
                return (Double(count) / Double(discrepant)) / (all / total)
            }
            let strong = entries.filter { $0.value.count >= 20 && $0.value.files.count >= 3 }
                .sorted { lift($0.key, $0.value.count) > lift($1.key, $1.value.count) }
            let rest = entries.filter { !($0.value.count >= 20 && $0.value.files.count >= 3) }.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            lines.append("")
            lines.append("**\(key)** (строк с расхождением: \(discrepant))")
            lines.append("")
            for (word, entry) in (strong + rest).prefix(10) {
                lines.append("- `\(word)` — подъём \(String(format: "%.1f", lift(word, entry.count)).replacingOccurrences(of: ".", with: ",")); \(entry.count) строк в \(entry.files.count) файлах (\(entry.files.sorted().prefix(6).joined(separator: ", "))\(entry.files.count > 6 ? ", …" : ""))")
            }
        }
        return lines
    }

    /// Сколько строк с расхождением этого вида в группе (каждая строка — один раз).
    private func discrepancyCount(_ group: [File], key: String) -> Int {
        group.map { file in file.result.discrepancies.filter { "\($0.kind.rawValue) · \($0.category.rawValue)" == key }.count }.reduce(0, +)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 1 : sorted[sorted.count / 2]
    }
}
