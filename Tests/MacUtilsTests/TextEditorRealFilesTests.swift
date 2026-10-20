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
        var marks = 0, empty = 0, total = 0, longest = 0
        mutating func add(_ marks: [DollarMark], in text: NSString) {
            for mark in marks {
                self.marks += 1
                let value = mark.text(in: text)
                if mark.isEmpty || value.trimmingCharacters(in: .whitespaces).isEmpty { empty += 1 }
                total += value.count
                longest = max(longest, value.count)
            }
        }
        var line: String {
            "знаков \(marks), пустых \(empty), длина средняя \(marks > 0 ? String(format: "%.1f", Double(total) / Double(marks)) : "0"), наибольшая \(longest)"
        }
    }

    /// Старое правило 1.7.0 и окончательное (до конца строки исходника) — только числа.
    func testRuleStatistics() throws {
        var old = Stats(), line = Stats()
        var bytesSame = 0
        let urls = try files()
        for url in urls {
            let data = try Data(contentsOf: url)
            let document = EditorDocument(data: data)
            let text = document.decodedText as NSString
            if try document.data(for: document.decodedText) == data { bytesSame += 1 }
            old.add(Self.oldRule(text), in: text)
            line.add(DollarMarks.scan(text), in: text)
        }
        print("[real-frm] файлов \(urls.count), открыть→сохранить без правок — те же байты: \(bytesSame)")
        print("[real-frm] старое правило: \(old.line)")
        print("[real-frm] до конца строки: \(line.line), непустых \(line.marks - line.empty)")
        XCTAssertEqual(bytesSame, urls.count)
    }

    /// «Убрать значения» (у всех и с пропуском первых 3): сколько файлов меняют баланс `{}`, открывается ли RTF.
    func testRemovalBraceBalance() throws {
        let urls = try files()
        for skip in [nil, 3] as [Int?] {
            var changed = 0, warned = 0, opened = 0, openedBefore = 0, removedTotal = 0, filesTouched = 0
            for url in urls {
                let data = try Data(contentsOf: url)
                let document = EditorDocument(data: data)
                let text = document.decodedText as NSString
                let rtf: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
                let before = (try? NSAttributedString(data: data, options: rtf, documentAttributes: nil)) != nil
                if before { openedBefore += 1 }
                let marks = DollarMarks.split(DollarMarks.scan(text), skipFirst: skip).active
                let removed = marks.filter { !$0.isEmpty }.count
                removedTotal += removed
                if removed > 0 { filesTouched += 1 }
                let stripped = DollarMarks.removingValues(of: marks, in: text as String) as NSString
                let saved = try document.data(for: stripped as String, lossy: false)
                if before, (try? NSAttributedString(data: saved, options: rtf, documentAttributes: nil)) != nil { opened += 1 }
                if Self.braceBalance(stripped) != Self.braceBalance(text) { changed += 1 }
                // Предупреждение панели: был баланс — стал нет.
                if DollarMarks.unbalancedBraces(in: text) == 0, DollarMarks.unbalancedBraces(in: stripped) > 0 { warned += 1 }
            }
            print("[real-frm] «Убрать значения» (пропуск \(skip.map(String.init) ?? "нет")): файлов \(urls.count), меняются \(filesTouched), "
                  + "убрано значений \(removedTotal), баланс {} меняется в \(changed), предупреждение в \(warned), "
                  + "открывались как RTF \(openedBefore), открываются после \(opened)")
        }
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
