import AppKit
import PDFKit
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// Счётчик слов строки состояния «Документа» против слов в PDF, сделанном самим Word (копии форм из `MU_WORD_REF_DIR`).
@MainActor
final class DocWordCountTests: XCTestCase {
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
            // Эталон из PDF: слова тела. Колонтитулы, заходящие в область тела, и точки табуляции (их у Word в счёте слов нет) вычитаем.
            var headerBag: [String: Int] = [:]
            for header in model.sections.flatMap({ Array($0.headers.values) }) {
                for run in header.story.paragraphs.flatMap(\.runs) where !run.props.hidden {
                    for w in run.text.split(whereSeparator: \.isWhitespace) { headerBag[String(w), default: 0] += 1 }
                }
            }
            var ourTokens: [String: Int] = [:]
            for run in model.body.paragraphs.flatMap(\.runs) where !run.props.hidden && run.kind == .text {
                for w in run.text.split(whereSeparator: \.isWhitespace) { ourTokens[String(w), default: 0] += 1 }
            }
            var pdfWords = 0
            for page in 0..<pdf.pageCount {
                var remaining = headerBag
                for line in bodyLines where line.page == page {
                    // Строка целиком из слов колонтитула (его текст заходит в область тела) — не тело.
                    if !line.words.isEmpty, line.words.allSatisfy({ (remaining[$0] ?? 0) > 0 }), line.words.allSatisfy({ (ourTokens[$0] ?? 0) == 0 }) {
                        for w in line.words { remaining[w, default: 0] -= 1 }
                        continue
                    }
                    for w in line.words {
                        if w.allSatisfy({ ".…_-–—·".contains($0) }), w.count >= 3, (ourTokens[w] ?? 0) == 0 { continue }
                        pdfWords += 1
                    }
                }
            }
            let word = pdfWords
            if ProcessInfo.processInfo.environment["MU_WC_DEBUG"] == name {
                print("WCDEBUG top=\(top) bottom=\(bottom) lines: " + bodyLines.map { "(\(Int($0.rect.minY)),\($0.words.count))" }.joined(separator: " "))
                var kinds: [String: Int] = [:]
                for run in model.body.paragraphs.flatMap(\.runs) { kinds["\(run.kind)\(run.props.hidden ? "-hidden" : "")", default: 0] += run.text.split(whereSeparator: \.isWhitespace).count }
                print("WCDEBUG kinds " + kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + " tables=\(model.body.tables.count) paras=\(model.body.paragraphs.count)")
                print("WCDEBUG header stories: " + model.sections.flatMap { $0.headers.map { "\($0.key.rawValue)=\($0.value.story.paragraphs.map { $0.plainText.split(separator: " ").count })" } }.joined(separator: " "))
            }
            let ours = DocumentController.words(model.body)
            guard word > 0 else { continue }
            checked += 1
            let delta = abs(Double(ours - word)) / Double(word)
            if delta <= 0.01 || abs(ours - word) <= 1 { within += 1 }
            let headerWords = model.sections.flatMap { $0.headers.values }.reduce(0) { $0 + DocumentController.words($1.story) }
            if ours != word {
                report.append("  \(name) слов в колонтитулах модели: \(headerWords), страниц Word: \(pdf.pageCount)")
                // Чего не хватает: слова PDF, которых нет в нашем тексте (мультимножество), по виду — только числа.
                var bag: [String: Int] = [:]
                for run in model.body.paragraphs.flatMap(\.runs) where !run.props.hidden { for w in run.text.split(whereSeparator: \.isWhitespace) { bag[String(w), default: 0] += 1 } }
                var missing: [String] = []
                for line in WordFidelity.lines(pdf).filter({ $0.rect.midY >= top - 1 && $0.rect.midY <= bottom + 1 }) {
                    for w in line.words { if let c = bag[w], c > 0 { bag[w] = c - 1 } else { missing.append(w) } }
                }
                let numeric = missing.filter { $0.allSatisfy { $0.isNumber || ".,)(-:;/".contains($0) } }.count
                let punct = missing.filter { $0.allSatisfy { !$0.isLetter && !$0.isNumber } }.count
                report.append("  \(name) в PDF нет у нас: \(missing.count) (числа/метки \(numeric), знаки \(punct)); у нас нет в PDF: \(bag.values.reduce(0, +))")
            }
            report.append("\(name): ours=\(ours) word=\(word) Δ=\(String(format: "%.1f", delta * 100)) %")
        }
        print("WORDCOUNT checked=\(checked) within1pct=\(within)\n" + report.joined(separator: "\n"))
        XCTAssertGreaterThan(checked, 10)
    }
}
