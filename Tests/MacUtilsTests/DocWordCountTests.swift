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
            let hasHeader = model.sections.contains { $0.headers.keys.contains { $0.rawValue.hasPrefix("header") } }
            let hasFooter = model.sections.contains { $0.headers.keys.contains { $0.rawValue.hasPrefix("footer") } }
            let headerZone = CGFloat(props.headerY) / 20 + 24, footerZone = pageHeight - CGFloat(props.footerY) / 20 - 24
            for line in bodyLines {
                // Колонтитул, заходящий в область тела (малые поля), в PDF стоит у края страницы: это не слова тела.
                if hasHeader, line.rect.minY < headerZone, line.rect.minY < top + 12, line.words.allSatisfy({ (headerBag[$0] ?? 0) > 0 || $0.allSatisfy(\.isNumber) }) { continue }
                if hasFooter, line.rect.maxY > footerZone, line.words.allSatisfy({ (headerBag[$0] ?? 0) > 0 || $0.allSatisfy(\.isNumber) }) { continue }
                for w in line.words {
                    if w.allSatisfy({ ".…_-–—·".contains($0) }), w.count >= 3, (ourTokens[w] ?? 0) == 0 { continue }
                    pdfWords += 1
                }
            }
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
        // Эталон — слова PDF Word, а не счётчик Word: колонтитулы в области тела и точки табуляции в нём шумят. Точно (±1 %) — не меньше 65 % форм (сейчас ≈ 71 %).
        XCTAssertGreaterThanOrEqual(Double(within) / Double(max(checked, 1)), 0.65)
    }
}
