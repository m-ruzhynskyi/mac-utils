import Foundation
import MUCore

/// Тексты фигур (`\shptxt`, у старых рисунков — `\dptxbxtext`) без места в потоке документа: для счёта слов, раскладку не меняют.
/// Фигура `\shp` (и группа `\shpgrp`) даёт свой `\shptxt` и тексты вложенных фигур; если их нет — текст из её `\shprslt`
/// (запасной вид той же фигуры для старых программ), иначе один и тот же текст считался бы дважды. Рисунок `\do` вне фигуры
/// даёт свой `\dptxbxtext`.
package enum RTFShapeTexts {
    /// Абзацы текстов фигур в порядке исходника.
    package static func extract(_ units: UnsafeBufferPointer<UInt16>, model: RTFDocumentModel) -> [String] {
        // Без текстовых групп фигур второй проход не нужен.
        guard contains(units, "\\shptxt") || contains(units, "\\dptxbxtext") else { return [] }
        var scanner = Scanner(units: units, model: model)
        scanner.run()
        return scanner.paragraphs
    }

    private static func contains(_ units: UnsafeBufferPointer<UInt16>, _ word: String) -> Bool {
        let pattern = Array(word.utf16)
        guard units.count >= pattern.count else { return false }
        var index = 0
        while index <= units.count - pattern.count {
            if units[index] == pattern[0] {
                var offset = 1
                while offset < pattern.count, units[index + offset] == pattern[offset] { offset += 1 }
                if offset == pattern.count { return true }
            }
            index += 1
        }
        return false
    }

    private struct Group {
        var kind = Kind.other
        var unicodeSkip = 1
        var font: Int?
        /// Текст этой группы и её вложенных не нужен (`\*`-группы, `\fldinst`, картинки).
        var skip = false
    }

    private enum Kind { case other, shape, shapeText, shapeResult, drawing, drawingText }

    private struct Scanner {
        let units: UnsafeBufferPointer<UInt16>
        let model: RTFDocumentModel
        var paragraphs: [String] = []
        var stack: [Group] = [Group()]
        var index = 0
        /// Открытые фигуры, внешняя первой: текст из `\shptxt` (и вложенных фигур) и из `\shprslt` — что взять, решается на `}`.
        var shapes: [(own: [String], result: [String])] = []
        var current = ""
        var collecting = false
        var pendingSkip = 0
        var tables: [TextEncoding: [UInt16]] = [:]

        init(units: UnsafeBufferPointer<UInt16>, model: RTFDocumentModel) {
            self.units = units
            self.model = model
        }

        private var top: Group {
            get { stack[stack.count - 1] }
            set { stack[stack.count - 1] = newValue }
        }

        /// Куда идёт текст сейчас: внутри `\shptxt` или `\dptxbxtext`, не в пропускаемой группе.
        private var target: Kind? {
            guard !stack.contains(where: \.skip) else { return nil }
            for group in stack.reversed() {
                switch group.kind {
                case .shapeText: return .shapeText
                case .drawingText: return .drawingText
                default: continue
                }
            }
            return nil
        }

        mutating func run() {
            while index < units.count {
                let unit = units[index]
                switch unit {
                case 0x7B: // {
                    var group = top
                    group.kind = .other
                    stack.append(group)
                    index += 1
                case 0x7D: // }
                    close()
                    index += 1
                case 0x5C: // \
                    controlWord()
                case 0x0A, 0x0D:
                    index += 1
                default:
                    append(unit)
                    index += 1
                }
            }
        }

        private mutating func close() {
            guard stack.count > 1 else { return }
            let group = stack.removeLast()
            switch group.kind {
            case .shapeText, .drawingText:
                finishParagraph()
            case .shape:
                // `\shptxt` фигуры, если он был; иначе — текст её запасного вида.
                guard let shape = shapes.popLast() else { break }
                store(shape.own.isEmpty ? shape.result : shape.own)
            default: break
            }
        }

        private mutating func finishParagraph() {
            let line = current.trimmingCharacters(in: .whitespaces)
            current = ""
            guard !line.isEmpty else { return }
            store([line])
        }

        /// Абзацы — в ближайшую открытую фигуру (в её запасной вид, если они внутри её `\shprslt`), вне фигур — в итог.
        private mutating func store(_ lines: [String]) {
            guard !lines.isEmpty else { return }
            guard !shapes.isEmpty, let start = stack.lastIndex(where: { $0.kind == .shape }) else { paragraphs.append(contentsOf: lines); return }
            if stack[start...].contains(where: { $0.kind == .shapeResult }) {
                shapes[shapes.count - 1].result += lines
            } else {
                shapes[shapes.count - 1].own += lines
            }
        }

        private mutating func append(_ unit: UInt16) {
            if pendingSkip > 0 { pendingSkip -= 1; return }
            guard target != nil else { return }
            current.append(UnicodeScalar(unit).map { Character($0) } ?? " ")
        }

        private mutating func controlWord() {
            index += 1
            guard index < units.count else { return }
            let first = units[index]
            // Знак-символ: `\'hh`, `\*`, `\\`, `\{`, `\}`, `\~`.
            if !Self.isLetter(first) {
                index += 1
                switch first {
                case 0x27: // '
                    guard index + 1 < units.count, let byte = Int(String(utf16CodeUnits: [units[index], units[index + 1]], count: 2), radix: 16) else { return }
                    index += 2
                    if pendingSkip > 0 { pendingSkip -= 1; return }
                    if target != nil { current.append(UnicodeScalar(decode(byte)).map { Character($0) } ?? " ") }
                case 0x2A: top.skip = true // `\*`: неизвестная группа — не текст; свои (`\shpinst`, `\shptxt`…) снимают это ниже
                case 0x5C, 0x7B, 0x7D: append(first)
                case 0x7E: append(0x20)
                default: break
                }
                return
            }
            var name = ""
            while index < units.count, Self.isLetter(units[index]) { name.append(Character(UnicodeScalar(units[index])!)); index += 1 }
            var digits = ""
            if index < units.count, units[index] == 0x2D { digits = "-"; index += 1 }
            while index < units.count, units[index] >= 0x30, units[index] <= 0x39 { digits.append(Character(UnicodeScalar(units[index])!)); index += 1 }
            if index < units.count, units[index] == 0x20 { index += 1 }
            let number = Int(digits)
            switch name {
            case "shp", "shpgrp":
                guard top.kind != .shape else { break }
                top.kind = .shape
                top.skip = false
                shapes.append(([], []))
            case "shptxt": top.kind = .shapeText; top.skip = false
            case "shprslt": top.kind = .shapeResult; top.skip = false
            case "do": if top.kind == .other { top.kind = .drawing; top.skip = false }
            case "dptxbxtext": top.kind = .drawingText; top.skip = false
            case "shpinst", "dptxbx": top.skip = false
            case "par", "line", "sect", "cell", "row", "nestcell", "nestrow":
                if target != nil { finishParagraph() }
            case "tab": if target != nil { current.append("\t") }
            case "u":
                guard let number else { return }
                if target != nil { current.append(Character(UnicodeScalar(UInt32(number < 0 ? number + 65_536 : number)) ?? " ")) }
                pendingSkip = top.unicodeSkip
            case "uc": top.unicodeSkip = max(0, number ?? 1)
            case "bin": index = min(units.count, index + max(0, number ?? 0)) // двоичные данные — не RTF
            case "f": top.font = number
            case "fldinst", "pict", "fonttbl", "colortbl", "stylesheet", "info", "sp", "sn", "sv", "shppict", "nonshppict", "object", "bkmkstart", "bkmkend":
                top.skip = true
            case "emdash": if target != nil { current.append("—") }
            case "endash": if target != nil { current.append("–") }
            case "lquote", "rquote": if target != nil { current.append("’") }
            case "ldblquote": if target != nil { current.append("“") }
            case "rdblquote": if target != nil { current.append("”") }
            case "bullet": if target != nil { current.append("•") }
            default: break
            }
        }

        private mutating func decode(_ byte: Int) -> UInt16 {
            var encoding = model.codePage
            if let number = top.font ?? model.defaultFont, let font = model.fonts[number] {
                encoding = RTFReader.encoding(charset: font.charset, codePage: font.codePage, document: model.codePage)
            }
            if tables[encoding] == nil { tables[encoding] = SingleByteTable.table(for: encoding)?.decodeTable ?? [] }
            let table = tables[encoding]!
            return byte < table.count ? table[byte] : UInt16(byte)
        }

        private static func isLetter(_ unit: UInt16) -> Bool { (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) }
    }
}
