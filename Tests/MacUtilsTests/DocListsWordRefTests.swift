import PDFKit
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// Номера списков против PDF, которые сделал сам Word (`pdf/fNNN.pdf` к `rtf/fNNN.rtf`). Только по `MU_WORD_REF_DIR`,
/// иначе пропускается. Для каждого пункта списка в тексте PDF ищется начало его текста, и перед ним должен стоять
/// наш номер. В журнал — только числа и fNNN (правила — `.audit/real-frm-rules.md`).
///   MU_WORD_REF_DIR=~/Projects/Cowork/Form/LAB-word-ref [MU_WORD_REF_ONLY=f001,f002] swift test --filter DocListsWordRefTests
final class DocListsWordRefTests: XCTestCase {
    struct Score {
        /// Пункты с номером (не маркером), найденные в PDF.
        var found = 0
        var matched = 0
        /// Готовый `\listtext` совпал (как показывали до E-2).
        var listTextMatched = 0
        /// Номер стоит в PDF слева на той же строке, что начало текста пункта (текст PDF кладёт номера столбца таблицы
        /// подряд, поэтому «перед текстом» в нём — не всегда номер этого пункта).
        var sameLine = 0
        var bullets = 0
        var notFound = 0
        /// Контроль: номер соседнего пункта (другой) на строке этого — должно быть мало.
        var control = 0
        /// Абзацы со старым номером `\pntext`/`\listtext` без списка: показан как есть — совпал ли с Word.
        var plainFound = 0
        var plainMatched = 0
    }

    func testNumbersMatchWordPDF() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_WORD_REF_DIR=<папка с rtf/ и pdf/>")
        }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let only = Set((ProcessInfo.processInfo.environment["MU_WORD_REF_ONLY"] ?? "").split(separator: ",").map(String.init))
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("rtf"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "rtf" }.sorted { $0.path < $1.path }
        var total = Score(), withLists = 0, perfect = 0
        var lines: [String] = []
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            if !only.isEmpty, !only.contains(name) { continue }
            let pdfURL = root.appendingPathComponent("pdf/\(name).pdf")
            guard let data = try? Data(contentsOf: url), let pdf = PDFDocument(url: pdfURL) else { continue }
            let document = EditorDocument(data: data)
            guard document.decodedText.range(of: "\\ls[0-9]", options: .regularExpression) != nil else { continue }
            let model = RTFReader.read(document.decodedText as NSString, fallback: document.encoding)
            let score = Self.score(model, pdf: pdf)
            guard score.found + score.bullets + score.notFound + score.plainFound > 0 else { continue }
            withLists += 1
            if score.sameLine == score.found { perfect += 1 }
            total.control += score.control
            total.plainFound += score.plainFound
            total.plainMatched += score.plainMatched
            total.found += score.found
            total.matched += score.matched
            total.listTextMatched += score.listTextMatched
            total.sameLine += score.sameLine
            total.bullets += score.bullets
            total.notFound += score.notFound
            lines.append("\(name)\t\(score.found)\t\(score.matched)\t\(score.sameLine)\t\(score.listTextMatched)\t\(score.bullets)\t\(score.notFound)")
        }
        let report = "[lists] файлов со списками \(withLists), все номера совпали в \(perfect); номеров найдено \(total.found), "
            + "совпало \(total.matched) (на той же строке \(total.sameLine)), готовый \\listtext совпал бы у \(total.listTextMatched); маркеров \(total.bullets), "
            + "не найдено в PDF \(total.notFound); контроль (чужой номер на строке) \(total.control); без списка с готовым номером "
            + "\(total.plainFound), совпал \(total.plainMatched)"
        print(report)
        if let out = ProcessInfo.processInfo.environment["MU_LISTS_OUT"] {
            try ([report, "файл\tнайдено\tсовпало\tстрока\tlisttext\tмаркеров\tне найдено"] + lines).joined(separator: "\n")
                .write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    /// Правка списков на копиях форм (`MU_REAL_FRM_DIR`): по 100 команд списка на каждой копии, где есть пункты, —
    /// ↩ в пункте и в пустом, Tab, ⇧Tab, ⌫ за номером. Каждая — `DocSaveGuard`, отмена байт в байт, готовые номера не
    /// расходятся больше, чем до правки. Только числа.
    @MainActor
    func testListEditsOnCopies() throws {
        let copies = try DocRealFilesTests.copies()
        var files = 0, commands = 0, applied = 0, violations = 0, slowest = 0.0
        var random = SeededRandom(seed: 4_242)
        for url in copies {
            let document = EditorDocument(data: try Data(contentsOf: url))
            var source = document.decodedText
            let start = RTFReader.read(source as NSString, fallback: document.encoding)
            guard !DocListNumbers.labels(start.body, lists: start.lists).isEmpty else { continue }
            files += 1
            let stale = DocListsTests.staleListTexts(source)
            for _ in 0..<100 {
                let model = RTFReader.read(source as NSString, fallback: document.encoding)
                let labels = DocListNumbers.labels(model.body, lists: model.lists)
                guard !labels.isEmpty else { break }
                let (rendering, _) = DocRenderer().render(model, previous: nil)
                let keys = labels.keys.sorted()
                let paragraph = keys[random.next(keys.count)]
                let content = DocListEdit.contentUnit(paragraph, rendering: rendering)
                let end = NSMaxRange(rendering.paragraphRanges[paragraph]) - 1
                let operation = random.next(5)
                let units: NSRange
                switch operation {
                case 0: units = NSRange(location: content + random.next(max(1, end - content + 1)), length: 0)
                case 4: units = NSRange(location: max(0, content - 1), length: 1)
                default: units = NSRange(location: content, length: 0)
                }
                commands += 1
                var outcome: DocListsTests.Outcome?
                let time = TextEditorPerformanceTests.measure {
                    outcome = DocListsTests.perform(source, units: units, text: ["\n", "\n", "\t", "", ""][operation], backtab: operation == 3,
                                                    encoding: document.encoding)
                }
                slowest = max(slowest, time)
                guard let outcome else { continue }
                applied += 1
                var problems = DocListsTests.violations(source, outcome, synced: false, document: EditorDocument(data: (try? document.data(for: source)) ?? Data()))
                if DocListsTests.staleListTexts(outcome.source) > stale { problems.append("готовые номера") }
                violations += problems.isEmpty ? 0 : 1
                source = outcome.source
            }
        }
        print(String(format: "[lists-real] копий со списками %d, команд %d, применено %d, нарушений %d, самая долгая %.0f мс", files, commands, applied,
                     violations, slowest))
        XCTAssertEqual(violations, 0)
    }

    static func flat(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 0xAD }.map(Character.init))
    }

    /// Слева от начала текста пункта на той же строке PDF кончается номер `number`.
    static func onSameLine(_ number: String, text: String, pdf: PDFDocument) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        var probe = ""
        for word in words {
            probe += (probe.isEmpty ? "" : " ") + word
            if probe.count >= 8 { break }
        }
        guard probe.count >= 3 else { return false }
        for selection in pdf.findString(probe, withOptions: .literal) {
            guard let page = selection.pages.first else { continue }
            let bounds = selection.bounds(for: page)
            let left = CGRect(x: 0, y: bounds.minY + bounds.height * 0.25, width: max(0, bounds.minX - 0.5), height: bounds.height * 0.5)
            let before = flat(page.selection(for: left)?.string ?? "")
            if before.hasSuffix(number) { return true }
        }
        return false
    }

    static func score(_ model: RTFDocumentModel, pdf: PDFDocument) -> Score {
        var score = Score()
        let labels = DocListNumbers.labels(model.body, lists: model.lists)
        var pages: [String] = []
        for index in 0..<pdf.pageCount { pages.append(pdf.page(at: index)?.string ?? "") }
        let text = flat(pages.joined()) as NSString
        var cursor = 0
        for (index, paragraph) in model.body.paragraphs.enumerated() where labels[index] == nil && paragraph.listTextGroup != nil {
            let number = flat(paragraph.runs.filter { $0.kind == .listText }.map(\.text).joined())
            let body = paragraph.runs.filter { $0.kind == .text && !$0.props.hidden }.map(\.text).joined()
            guard number.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }), flat(body).count >= 4 else { continue }
            score.plainFound += 1
            if onSameLine(number, text: body, pdf: pdf) { score.plainMatched += 1 }
        }
        let ordered = labels.keys.sorted()
        for (position, index) in ordered.enumerated() {
            guard let label = labels[index] else { continue }
            let paragraph = model.body.paragraphs[index]
            let body = flat(paragraph.runs.filter { $0.kind == .text && !$0.props.hidden }.map(\.text).joined())
            guard (body as NSString).length >= 4 else { continue }
            let probe = String(body.prefix(14))
            var found = text.range(of: probe, range: NSRange(location: cursor, length: text.length - cursor))
            if found.location == NSNotFound { found = text.range(of: probe) }
            guard found.location != NSNotFound else { score.notFound += 1; continue }
            cursor = NSMaxRange(found)
            let number = flat(label.number)
            if label.level.format == 23 || number.isEmpty || number.unicodeScalars.allSatisfy({ !CharacterSet.alphanumerics.contains($0) }) {
                score.bullets += 1
                if ProcessInfo.processInfo.environment["MU_LISTS_DEBUG"] != nil {
                    let run = paragraph.runs.first { $0.kind == .listText }
                    print("[lists-debug] маркер \(label.number.unicodeScalars.map { String($0.value, radix: 16) }) f \(label.props.font ?? -1) fs \(label.props.halfPoints); "
                          + "listtext \(run?.text.unicodeScalars.map { String($0.value, radix: 16) } ?? []) f \(run?.props.font ?? -1) fs \(run?.props.halfPoints ?? -1) "
                          + "ур.f \(label.level.char.font ?? -1) шрифт \(model.font(label.level.char.font).map { $0.name.hasPrefix("Sym") || $0.name.hasPrefix("Wing") || $0.name.hasPrefix("Cour") ? $0.name : "другой" } ?? "-")")
                }
                continue
            }
            let before = text.substring(to: found.location)
            score.found += 1
            if ProcessInfo.processInfo.environment["MU_LISTS_DEBUG"] != nil {
                let listText = paragraph.runs.filter { $0.kind == .listText }.map { $0.text.unicodeScalars.map { $0.value < 0x30 ? "\\u\($0.value)" : "c" }.joined() }
                print("[lists-debug] п.\(index) li \(paragraph.props.left) fi \(paragraph.props.firstLine) tabs \(paragraph.props.tabs.map(\.position)) "
                      + "ур.li \(label.level.left ?? -1) fi \(label.level.firstLine ?? -1) follow \(label.follow) listtext \(listText) cell \(paragraph.cell != nil) "
                      + "номер fs \(label.props.halfPoints) f \(label.props.font ?? -1) b \(label.props.bold); listtext fs \(paragraph.runs.first { $0.kind == .listText }?.props.halfPoints ?? -1) "
                      + "f \(paragraph.runs.first { $0.kind == .listText }?.props.font ?? -1); текст fs \(paragraph.runs.first { $0.kind == .text }?.props.halfPoints ?? -1) "
                      + "f \(paragraph.runs.first { $0.kind == .text }?.props.font ?? -1); ур.fs \(label.level.char.halfPoints ?? -1) ур.f \(label.level.char.font ?? -1)")
            }
            let line = onSameLine(number, text: paragraph.runs.filter { $0.kind == .text && !$0.props.hidden }.map(\.text).joined(), pdf: pdf)
            if line { score.sameLine += 1 }
            if let next = ordered[safe: position + 1].flatMap({ labels[$0] }), flat(next.number) != number, !flat(next.number).isEmpty,
               onSameLine(flat(next.number), text: paragraph.runs.filter { $0.kind == .text && !$0.props.hidden }.map(\.text).joined(), pdf: pdf) {
                score.control += 1
            }
            if before.hasSuffix(number) { score.matched += 1 }
            if !line, ProcessInfo.processInfo.environment["MU_LISTS_DEBUG"] != nil {
                // Только цифры и знаки номера — без текста документа.
                let tail = String(before.suffix(8).filter { $0.isNumber || ".)-(".contains($0) })
                print("[lists-debug] п.\(index) ур.\(label.levelIndex) ls\(label.list) наш «\(number)» listtext «\(flat(paragraph.runs.filter { $0.kind == .listText }.map(\.text).joined()))» в PDF перед текстом «\(tail)»")
            }
            let listText = flat(paragraph.runs.filter { $0.kind == .listText }.map(\.text).joined())
            if !listText.isEmpty, before.hasSuffix(listText) { score.listTextMatched += 1 }
        }
        return score
    }
}
