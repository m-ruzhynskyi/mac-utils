import AppKit
import XCTest
@testable import MacUtils

/// Режим «Документ» на настоящих .frm пользователя — только по `MU_REAL_FRM_DIR` (папка с КОПИЯМИ), без неё тест
/// пропускается. В журнал — только числа (правила — `.audit/real-frm-rules.md`).
@MainActor
final class DocRealFilesTests: XCTestCase {
    nonisolated static func copies() throws -> [URL] {
        guard let path = ProcessInfo.processInfo.environment["MU_REAL_FRM_DIR"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_REAL_FRM_DIR=<папка с копиями .frm>")
        }
        return try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: nil)
            .filter { ["frm", "rtf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
    }

    /// D-1: разбор без падений; абзацы, видимые символы, колонтитулы, рисунки, фигуры, время.
    func testReaderNumbers() throws {
        var rtf = 0, paragraphs = 0, visible = 0, withHeaders = 0, titlePage = 0, png = 0, wmf = 0, shapes = 0, tables = 0
        var slowest = 0.0, total = 0.0
        var rawPictures: [String: Int] = [:]
        for url in try Self.copies() {
            let document = EditorDocument(data: try Data(contentsOf: url))
            for format in ["pngblip", "jpegblip", "wmetafile", "emfblip"] {
                rawPictures[format, default: 0] += document.decodedText.components(separatedBy: "\\" + format).count - 1
            }
            var model = RTFDocumentModel()
            let time = TextEditorPerformanceTests.measure { model = RTFReader.read(document.decodedText as NSString, fallback: document.encoding) }
            guard model.isRTF else { continue }
            rtf += 1
            slowest = max(slowest, time)
            total += time
            paragraphs += model.body.paragraphs.count
            visible += DocReaderTests.visibleText(model.body).filter { !$0.isWhitespace }.count
            if model.sections.contains(where: { !$0.headers.isEmpty }) { withHeaders += 1 }
            if model.sections.contains(where: { $0.props.titlePage }) { titlePage += 1 }
            tables += model.body.tables.count
            let headerRuns = model.sections.flatMap { $0.headers.values.flatMap { $0.story.paragraphs.flatMap(\.runs) } }
            for run in model.body.paragraphs.flatMap(\.runs) + headerRuns {
                if run.picture?.format == .png { png += 1 }
                if case .placeholder(let placeholder) = run.kind {
                    if case .picture("WMF") = placeholder.kind { wmf += 1 }
                    if case .shape = placeholder.kind { shapes += 1 }
                }
            }
        }
        print("[real-frm] документ: RTF \(rtf), абзацев \(paragraphs), видимых знаков без пробелов \(visible), с колонтитулами \(withHeaders), "
              + "\\titlepg \(titlePage), таблиц \(tables), PNG \(png), WMF \(wmf), фигур \(shapes)")
        print("[real-frm] \\pict в исходнике: PNG \(rawPictures["pngblip"] ?? 0), JPEG \(rawPictures["jpegblip"] ?? 0), "
              + "WMF \(rawPictures["wmetafile"] ?? 0), EMF \(rawPictures["emfblip"] ?? 0)")
        print(String(format: "[real-frm] разбор: всего %.0f мс, самый долгий %.0f мс (%@)", total, slowest, TextEditorPerformanceTests.build))
        XCTAssertLessThan(slowest, TextEditorPerformanceTests.limit(150))
    }

    /// D-3: 100 случайных правок (семя) на каждой копии — проверки без потерь на каждом шаге; «Убрать значения» —
    /// RTF корректен; открыть → сохранить без правок — те же байты. Только числа.
    func testRandomEditsOnCopies() throws {
        var files = 0, edits = 0, refused = 0, removedValues = 0, removalOpens = 0, bytesSame = 0
        var random = SeededRandom(seed: 1_917)
        let failuresBefore = testRun?.failureCount ?? 0
        for url in try Self.copies() {
            let data = try Data(contentsOf: url)
            let document = EditorDocument(data: data)
            guard RTFReader.read(document.decodedText as NSString).isRTF else { continue }
            files += 1
            if try document.data(for: document.decodedText) == data { bytesSame += 1 }
            var harness = DocEditTests.Harness(source: document.decodedText)
            for _ in 0..<100 {
                let count = harness.display().1.count
                let location = random.next(count + 1)
                let length = random.next(3) == 0 ? random.next(min(10, max(0, count - location)) + 1) : 0
                let result = harness.edit(NSRange(location: location, length: length), ["а", "Ж", "x", " ", "\n", "", "5"][random.next(7)])
                if result.edits.isEmpty { refused += 1 } else { edits += 1 }
            }
            // «Убрать значения» по окончательному правилу — RTF открывается и после.
            let marks = DollarMarks.split(DollarMarks.scan(document.decodedText), skipFirst: 3).active
            removedValues += marks.filter { !$0.isEmpty }.count
            let stripped = DollarMarks.removingValues(of: marks, in: document.decodedText)
            let saved = try document.data(for: stripped, lossy: false)
            if RTFReader.read(stripped).isRTF,
               (try? NSAttributedString(data: saved, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)) != nil {
                removalOpens += 1
            }
        }
        let failures = (testRun?.failureCount ?? 0) - failuresBefore
        print("[real-frm] правка: файлов \(files), правок \(edits), отказов (ячейки, рисунки, разделы) \(refused), нарушений \(failures); "
              + "без правок — те же байты \(bytesSame); «Убрать значения» (пропуск 3): значений \(removedValues), открываются \(removalOpens) из \(files)")
    }

    /// D-2: самый большой файл — разбор, показ и первая страница; число страниц и колонтитулы. Только числа.
    func testFirstPageSpeed() throws {
        var slowest = 0.0, pages = 0, withHeaderPages = 0
        for url in try Self.copies() {
            let data = try Data(contentsOf: url)
            let workspace = EditorWorkspace()
            let tab = EditorTab(document: EditorDocument(data: data, url: url))
            workspace.add(tab)
            guard tab.canShowDocument else { continue }
            let time = TextEditorPerformanceTests.measure {
                tab.setMode(.document)
                if let document = tab.documentController, let first = document.layoutManager.textContainers.first {
                    document.layoutManager.ensureLayout(for: first)
                }
            }
            slowest = max(slowest, time)
            if let document = tab.documentController {
                document.layoutManager.ensureLayout(for: document.layoutManager.textContainers.last!)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                pages += document.pageCount
                withHeaderPages += document.pagesView.pages.filter { $0.header != nil || $0.footer != nil }.count
            }
        }
        print(String(format: "[real-frm] показ: самая долгая первая страница %.0f мс (%@), страниц всего %d, с колонтитулами %d",
                     slowest, TextEditorPerformanceTests.build, pages, withHeaderPages))
        XCTAssertLessThan(slowest, TextEditorPerformanceTests.limit(300))
    }
}
