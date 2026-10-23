import AppKit
import SwiftUI
import MUCore
import MUDesign

/// Какие куски текста с момента открытия (или последнего сохранения) не тронуты и где они теперь. Пополняется каждой
/// правкой хранилища; по нему перед записью сверяются байты «вне правок».
struct DocSourceJournal: Equatable {
    struct Segment: Equatable {
        /// Начало в исходном тексте и в нынешнем, длина (UTF-16).
        var original: Int
        var current: Int
        var length: Int
    }

    private(set) var segments: [Segment]

    init(length: Int) {
        segments = length > 0 ? [Segment(original: 0, current: 0, length: length)] : []
    }

    /// Правка хранилища: `edited` — новый диапазон, `delta` — на сколько изменилась длина.
    mutating func record(edited: NSRange, delta: Int) {
        let start = edited.location
        let oldEnd = start + edited.length - delta
        var result: [Segment] = []
        result.reserveCapacity(segments.count + 1)
        for segment in segments {
            let end = segment.current + segment.length
            if end <= start {
                result.append(segment)
            } else if segment.current >= oldEnd {
                var moved = segment
                moved.current += delta
                result.append(moved)
            } else {
                if segment.current < start {
                    result.append(Segment(original: segment.original, current: segment.current, length: start - segment.current))
                }
                if end > oldEnd {
                    let cut = oldEnd - segment.current
                    result.append(Segment(original: segment.original + cut, current: oldEnd + delta, length: end - oldEnd))
                }
            }
        }
        segments = result
    }
}

/// Проверки перед записью файла, правленного в «Документе» (план, § 3.4). Не прошла хоть одна — файл не пишется.
enum DocSaveGuard {
    struct Report: Equatable {
        var bytesOutsideEdits = true
        var braces = true
        var readable = true
        var opens = true
        /// Что не так — для листа.
        var problem = ""
        /// Где в исходнике первое расхождение (для «Показать в коде»).
        var problemRange: NSRange?
        /// Байты, которые записались бы (для «Сохранить как копию…»).
        var data: Data?

        var passed: Bool { bytesOutsideEdits && braces && readable && opens }
    }

    static func check(document: EditorDocument, text: NSString, journal: DocSourceJournal) -> Report {
        var report = Report()
        let original = document.decodedText as NSString
        guard let data = try? document.data(for: text as String) else {
            report.bytesOutsideEdits = false
            report.problem = "Некоторых символов нет в \(document.encoding.title) — файл записался бы с заменой."
            return report
        }
        report.data = data
        // 1. Байты вне правок — те же, что в исходном файле.
        if let mismatch = firstMismatch(document: document, original: original, text: text, data: data, journal: journal) {
            report.bytesOutsideEdits = false
            report.problemRange = NSRange(location: mismatch, length: 0)
            let line = LineIndex(text).line(at: min(mismatch, text.length))
            report.problem = "Проверка перед записью нашла изменения вне ваших правок (строка \(line))."
        }
        // 2. Скобки: непарных не больше, чем было; начало `{\rtf`.
        let before = DollarMarks.unbalancedBraces(in: original), after = DollarMarks.unbalancedBraces(in: text)
        let wasRTF = DocumentController.canShow(original)
        if after > before || (wasRTF && !DocumentController.canShow(text)) {
            report.braces = false
            report.problemRange = report.problemRange ?? firstUnbalanced(text).map { NSRange(location: $0, length: 1) }
            let line = report.problemRange.map { LineIndex(text).line(at: $0.location) }
            report.problem = report.problem.isEmpty ? "Скобки { } в файле стали несбалансированными" + (line.map { " (строка \($0))" } ?? "") + "." : report.problem
        }
        // 3. Наш разбор читает файл.
        let model = RTFReader.read(text, fallback: document.encoding)
        if wasRTF, !model.isRTF {
            report.readable = false
            if report.problem.isEmpty { report.problem = "Файл перестал читаться как RTF." }
        }
        // 4. Cocoa открывает (если открывала исходный).
        let rtf: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
        if wasRTF, (try? NSAttributedString(data: document.original, options: rtf, documentAttributes: nil)) != nil,
           (try? NSAttributedString(data: data, options: rtf, documentAttributes: nil)) == nil {
            report.opens = false
            if report.problem.isEmpty { report.problem = "Файл перестал открываться другими программами." }
        }
        if !report.passed { report.problem += " Файл не записан — оригинал цел." }
        return report
    }

    /// Первое место (в нынешнем тексте), где байты нетронутого куска отличаются от исходного файла; `nil` — все те же.
    static func firstMismatch(document: EditorDocument, original: NSString, text: NSString, data: Data, journal: DocSourceJournal) -> Int? {
        let encoding = document.encoding
        let source = document.original
        guard encoding == document.decodedEncoding else { return nil }   // «Преобразовать в…» — байты меняются все, по согласию
        let originalOffsets = ByteOffsets(text: original, encoding: encoding, data: source)
        let currentOffsets = ByteOffsets(text: text, encoding: encoding, data: data)
        for segment in journal.segments {
            guard NSMaxRange(NSRange(location: segment.original, length: segment.length)) <= original.length,
                  segment.current + segment.length <= text.length else { return segment.current }
            // Текст куска тот же?
            if original.substring(with: NSRange(location: segment.original, length: segment.length))
                != text.substring(with: NSRange(location: segment.current, length: segment.length)) {
                return segment.current
            }
            let a = originalOffsets.range(segment.original, segment.length)
            let b = currentOffsets.range(segment.current, segment.length)
            guard a.upperBound <= source.count, b.upperBound <= data.count, source[a] == data[b] else { return segment.current }
        }
        return nil
    }

    private static func firstUnbalanced(_ text: NSString) -> Int? {
        var stack: [Int] = []
        var index = 0
        while index < text.length {
            switch text.character(at: index) {
            case 0x5C: index += 1
            case 0x7B: stack.append(index)
            case 0x7D: if stack.isEmpty { return index } else { stack.removeLast() }
            default: break
            }
            index += 1
        }
        return stack.first
    }

    /// Смещения байтов для мест текста: однобайтовые кодировки — один к одному, UTF-8 — по длине символов, UTF-16 — вдвое.
    struct ByteOffsets {
        private let prefix: [Int]
        private let bom: Int
        private let scale: Int

        init(text: NSString, encoding: TextEncoding, data: Data) {
            switch encoding {
            case .utf8BOM: bom = data.starts(with: TextEncoding.bomUTF8) ? 3 : 0
            case .utf8: bom = data.starts(with: TextEncoding.bomUTF8) ? 3 : 0
            case .utf16LE: bom = data.starts(with: TextEncoding.bomUTF16LE) ? 2 : 0
            case .utf16BE: bom = data.starts(with: TextEncoding.bomUTF16BE) ? 2 : 0
            default: bom = 0
            }
            switch encoding {
            case .utf8, .utf8BOM:
                // Байт до каждой единицы UTF-16.
                var offsets = [Int](repeating: 0, count: text.length + 1)
                var total = 0
                for index in 0..<text.length {
                    offsets[index] = total
                    let unit = text.character(at: index)
                    switch unit {
                    case 0..<0x80: total += 1
                    case 0x80..<0x800: total += 2
                    case 0xD800...0xDBFF: total += 4
                    case 0xDC00...0xDFFF: break
                    default: total += 3
                    }
                }
                offsets[text.length] = total
                prefix = offsets
                scale = 1
            case .utf16LE, .utf16BE:
                prefix = []
                scale = 2
            default:
                prefix = []
                scale = 1
            }
        }

        func range(_ location: Int, _ length: Int) -> Range<Int> {
            if prefix.isEmpty { return (bom + location * scale)..<(bom + (location + length) * scale) }
            return (bom + prefix[location])..<(bom + prefix[location + length])
        }
    }
}

/// Лист «Не удалось сохранить без потерь» (`d10`).
struct DocSaveGuardSheet: View {
    let report: DocSaveGuard.Report
    let saveCopy: () -> Void
    let showInCode: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack(alignment: .top, spacing: DS.Space.l) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Color(nsColor: NSColor(srgbRed: 0.55, green: 0.33, blue: 0.0, alpha: 1)),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Не удалось сохранить без потерь").font(DS.Font.manrope(19, .heavy, relativeTo: .title3)).foregroundStyle(.dsText)
                        .accessibilityAddTraits(.isHeader)
                    Text(report.problem).font(DS.Font.body).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                check("Байты вне правок не изменились", report.bytesOutsideEdits)
                check("Скобки { } сбалансированы", report.braces)
                check("Документ открывается", report.readable && report.opens)
            }
            .padding(DS.Space.m)
            .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            Text("Ваши изменения не потеряны: их можно сохранить отдельным файлом и открыть рядом с оригиналом.")
                .font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                Button("Показать в коде", action: showInCode).buttonStyle(.graphite(.secondary))
                Spacer(minLength: 0)
                Button("Отмена", action: cancel).buttonStyle(.graphite(.secondary)).keyboardShortcut(.cancelAction)
                Button("Сохранить как копию…", action: saveCopy).buttonStyle(.graphite(.primary, fill: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(report.data == nil)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 520)
        .background(Color.dsPanel)
    }

    private func check(_ title: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? DS.Tone.success.line : DS.Tone.danger.line)
                .accessibilityLabel(ok ? "Да" : "Нет")
            Text(title).font(DS.Font.body).foregroundStyle(.dsText)
        }
    }
}
