import AppKit
import PDFKit
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// Счётчик слов строки состояния «Документа» против слов в PDF, сделанном самим Word (копии форм из `MU_WORD_REF_DIR`).
@MainActor
final class DocWordCountTests: XCTestCase {
    private static func norm(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Слова тела по строкам PDF Word. PDF — шумный эталон, поэтому из него убираются три вещи, которых нет в счёте слов Word:
    /// (1) строки колонтитулов: большинство слов строки есть в тексте колонтитулов документа и не есть в теле (колонтитул при малых
    /// полях стоит в области тела, по геометрии его не отличить); (2) точки табуляции и линии из точек; (3) вторая половина слова,
    /// перенесённого по знакам в узкой ячейке («Фами» + «лия»): у PDF это две «строки», у Word — одно слово.
    static func bodyWordsInPDF(lines: [WordFidelity.Line], model: RTFDocumentModel) -> Int {
        var header: Set<String> = []
        for story in model.sections.flatMap({ Array($0.headers.values) }) {
            for run in story.story.paragraphs.flatMap(\.runs) where !run.props.hidden {
                for w in run.text.split(whereSeparator: \.isWhitespace) { header.insert(norm(String(w))) }
            }
        }
        header.remove("")
        var bodyNorm: [String: Int] = [:], bodyRaw: [String: Int] = [:]
        for run in model.body.paragraphs.flatMap(\.runs) where !run.props.hidden {
            for w in run.text.split(whereSeparator: \.isWhitespace) { bodyNorm[norm(String(w)), default: 0] += 1; bodyRaw[String(w), default: 0] += 1 }
        }
        let hasHeaders = model.sections.contains { !$0.headers.isEmpty }
        var count = 0
        for line in lines {
            let words = line.words
            if hasHeaders {
                let inHeader = words.filter { let n = norm($0); return !n.isEmpty && header.contains(n) }.count
                let inBody = words.filter { let n = norm($0); return !n.isEmpty && bodyNorm[n] != nil }.count
                if Double(inHeader) / Double(max(words.count, 1)) >= 0.5, inHeader > inBody { continue }
            }
            var skipFirst = false
            if let first = words.first, let above = lines.first(where: {
                $0.page == line.page && $0.rect != line.rect && abs($0.rect.minX - line.rect.minX) <= 3
                    && line.rect.minY - $0.rect.maxY >= -4 && line.rect.minY - $0.rect.maxY <= 6
            }), let last = above.words.last, bodyNorm[norm(last + first)] != nil, bodyNorm[norm(first)] == nil || bodyNorm[norm(last)] == nil {
                skipFirst = true
            }
            for (index, w) in words.enumerated() where !(skipFirst && index == 0) {
                if w.allSatisfy({ ".…_-–—·".contains($0) }), w.count >= 3, (bodyRaw[w] ?? 0) == 0 { continue }
                count += 1
            }
        }
        return count
    }

    func testWordCountAgainstWordPDF() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], !path.isEmpty else { throw XCTSkip("MU_WORD_REF_DIR") }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("rtf").path).filter { $0.hasSuffix(".rtf") }.sorted()
        let step = Int(ProcessInfo.processInfo.environment["MU_WORDCOUNT_STEP"] ?? "") ?? 8
        var checked = 0, within = 0
        var report: [String] = []
        for (index, file) in names.enumerated() where index % step == 0 {
            let name = String(file.dropLast(4))
            guard let data = try? Data(contentsOf: base.appendingPathComponent("rtf/\(file)")), data.count < 600_000,
                  let pdf = PDFDocument(url: base.appendingPathComponent("pdf/\(name).pdf")) else { continue }
            let model = RTFReader.read(EditorDocument(data: data).decodedText as NSString)
            guard let props = model.sections.first?.props else { continue }
            let pageHeight = CGFloat(props.landscape ? props.pageWidth : props.pageHeight) / 20
            let top = CGFloat(props.marginTop) / 20, bottom = pageHeight - CGFloat(props.marginBottom) / 20
            let bodyLines = WordFidelity.lines(pdf).filter { $0.rect.midY >= top - 1 && $0.rect.midY <= bottom + 1 }
            let pdfWords = Self.bodyWordsInPDF(lines: bodyLines, model: model)
            let word = pdfWords
            // В PDF есть готовые номера списков, в счётчике слов Word их нет: сравниваем с «нашими словами + номера».
            let labels = model.body.paragraphs.flatMap(\.runs).filter { $0.kind == .listText }.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            let ours = DocumentController.words(model.body) + labels
            guard word > 0 else { continue }
            checked += 1
            let delta = abs(Double(ours - word)) / Double(word)
            if delta <= 0.01 || abs(ours - word) <= 1 { within += 1 }
            report.append("\(name): ours=\(ours) word=\(word) Δ=\(String(format: "%.1f", delta * 100)) %")
        }
        print("WORDCOUNT checked=\(checked) within1pct=\(within)\n" + report.joined(separator: "\n"))
        XCTAssertGreaterThan(checked, 10)
        // Эталон — слова PDF Word, очищенные от колонтитулов, точек табуляции и переносов по знакам (`bodyWordsInPDF`), а не счётчик Word.
        // Выборка из ~20 форм (каждая 8-я): не меньше 90 % в ±1 % (сейчас 20 из 21). Полный проход (`MU_WORDCOUNT_STEP=1`): не меньше 80 % (сейчас 141 из 166).
        let share = Double(within) / Double(max(checked, 1))
        XCTAssertGreaterThanOrEqual(share, step == 1 ? 0.80 : 0.90)
    }
}
