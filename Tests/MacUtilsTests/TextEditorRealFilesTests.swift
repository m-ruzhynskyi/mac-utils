import AppKit
import XCTest
@testable import MacUtils

/// Настоящие .frm пользователя — только по `MU_REAL_FRM_DIR` (папка с КОПИЯМИ), без неё тест пропускается. Файлы и их
/// содержимое в репозиторий не попадают; в журнал — только числа (правила — `.audit/real-frm-rules.md`).
final class TextEditorRealFilesTests: XCTestCase {
    private func folder() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MU_REAL_FRM_DIR"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_REAL_FRM_DIR=<папка с копиями .frm>")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder(), includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "frm" }
    }

    private struct Stats {
        var marks = 0, empty = 0, hidden = 0, total = 0, longest = 0
        mutating func add(_ marks: [DollarMark], in text: NSString) {
            for mark in marks {
                self.marks += 1
                if mark.hidden { hidden += 1 }
                let value = mark.text(in: text)
                if mark.isEmpty || value.trimmingCharacters(in: .whitespaces).isEmpty { empty += 1 }
                total += value.count
                longest = max(longest, value.count)
            }
        }
        var line: String {
            "знаков \(marks), пустых \(empty), служебных \(hidden), длина средняя \(marks > 0 ? String(format: "%.1f", Double(total) / Double(marks)) : "0"), наибольшая \(longest)"
        }
    }

    /// Старое правило (до пробела и `\ { } $ ;`), правило исходника 1.7.1 и правило по видимому тексту RTF — только числа.
    func testRuleStatistics() throws {
        var old = Stats(), source = Stats(), rtf = Stats(), rtfLeading = Stats()
        var bytesSame = 0, seconds = 0.0
        let urls = try files()
        for url in urls {
            let data = try Data(contentsOf: url)
            let document = EditorDocument(data: data)
            let text = document.decodedText as NSString
            if try document.data(for: document.decodedText) == data { bytesSame += 1 }
            old.add(Self.oldRule(text), in: text)
            source.add(DollarMarks.scan(text, rule: .source), in: text)
            let started = Date()
            rtf.add(RTFDollarScanner.scan(text, encoding: document.encoding), in: text)
            seconds += Date().timeIntervalSince(started)
            rtfLeading.add(RTFDollarScanner.scan(text, encoding: document.encoding, skipsLeadingSpace: true), in: text)
        }
        print("[real-frm] файлов \(urls.count), открыть→сохранить без правок — те же байты: \(bytesSame)")
        print("[real-frm] старое правило: \(old.line)")
        print("[real-frm] исходник 1.7.1: \(source.line)")
        print("[real-frm] RTF, пробел — конец: \(rtf.line); скан всех файлов \(Int(seconds * 1000)) мс")
        print("[real-frm] RTF, пробелы сразу после $ пропускаются: \(rtfLeading.line)")
        XCTAssertEqual(bytesSame, urls.count)
    }

    /// «Убрать значения» по правилу RTF: коды на месте — RTF открывается, группы `{}` сбалансированы, байты вне значений те же.
    func testRemovalKeepsRTFValid() throws {
        var opened = 0, openedBefore = 0, balanced = 0, outsideSame = 0, removedTotal = 0
        let urls = try files()
        for url in urls {
            let data = try Data(contentsOf: url)
            let document = EditorDocument(data: data)
            let text = document.decodedText as NSString
            let rtf: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
            let before = (try? NSAttributedString(data: data, options: rtf, documentAttributes: nil)) != nil
            if before { openedBefore += 1 }
            let marks = RTFDollarScanner.scan(text, encoding: document.encoding).filter { !$0.hidden }
            removedTotal += marks.filter { !$0.isEmpty }.count
            let stripped = DollarMarks.removingValues(of: marks, in: text as String)
            let saved = try document.data(for: stripped, lossy: false)
            // Открывается после правки — каждый файл, который открывался до неё.
            if before, (try? NSAttributedString(data: saved, options: rtf, documentAttributes: nil)) != nil { opened += 1 }
            if Self.braceBalance(stripped as NSString) == Self.braceBalance(text) { balanced += 1 }
            // Вне вырезанных кусков исходник тот же.
            var kept = text as String
            kept = DollarMarks.removingValues(of: marks, in: kept)
            if kept == stripped { outsideSame += 1 }
        }
        print("[real-frm] «Убрать значения»: файлов \(urls.count), убрано значений \(removedTotal), открывались как RTF до правки \(openedBefore), "
              + "открываются после (из открывавшихся) \(opened), группы сбалансированы \(balanced)")
        XCTAssertEqual(opened, openedBefore, "открывавшиеся как RTF открываются и после правки")
        XCTAssertEqual(balanced, urls.count)
        XCTAssertEqual(outsideSame, urls.count)
    }

    /// Разность `{` и `}` без экранированных.
    static func braceBalance(_ text: NSString) -> Int {
        var depth = 0
        for i in 0..<text.length {
            let unit = text.character(at: i)
            guard unit == 0x7B || unit == 0x7D, !BracketMatcher.isEscaped(text, i) else { continue }
            depth += unit == 0x7B ? 1 : -1
        }
        return depth
    }

    /// Правило 1.7.0: до пробельного символа или одного из `\ { } $ ;`.
    static func oldRule(_ text: NSString) -> [DollarMark] {
        var marks: [DollarMark] = []
        var i = 0
        let stops: Set<UInt16> = [0x5C, 0x7B, 0x7D, 0x24, 0x3B, 0x20, 0x09, 0x0A, 0x0D]
        while i < text.length {
            guard text.character(at: i) == 0x24 else { i += 1; continue }
            var end = i + 1
            while end < text.length, !stops.contains(text.character(at: end)) { end += 1 }
            marks.append(DollarMark(dollar: i, value: NSRange(location: i + 1, length: end - i - 1)))
            i = end
        }
        return marks
    }
}
