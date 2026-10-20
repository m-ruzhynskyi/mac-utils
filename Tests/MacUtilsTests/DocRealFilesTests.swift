import AppKit
import XCTest
@testable import MacUtils

/// Режим «Документ» на настоящих .frm пользователя — только по `MU_REAL_FRM_DIR` (папка с КОПИЯМИ), без неё тест
/// пропускается. В журнал — только числа (правила — `.audit/real-frm-rules.md`).
final class DocRealFilesTests: XCTestCase {
    static func copies() throws -> [URL] {
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
}
