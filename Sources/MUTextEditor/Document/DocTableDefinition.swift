import Foundation

/// Определение строки таблицы в исходнике: `\trowd`, свойства строки, затем ячейки — слова `\cl…` и `\cellx`.
/// Word пишет его дважды (перед ячейками и в конце строки, `{… \trowd … \row}`) — правка ячейки меняет все копии.
/// Ячейка переписывается целиком (от её первого слова до конца `\cellx`), поэтому правки ширины, объединения,
/// границ и заливки одной ячейки не пересекаются.
package struct RTFRowDefinition {
    /// Слово определения ячейки с тем, что за ним до следующего слова (разделитель, переводы строк). Слова
    /// `\brdr…` после `\clbrdrX` входят в его элемент.
    package struct Item: Equatable {
        package var name: String
        package var number: Int?
        package var text: String

        package init(name: String, number: Int? = nil, text: String? = nil) {
            self.name = name
            self.number = number
            self.text = text ?? "\\" + name + (number.map(String.init) ?? "")
        }
    }

    package struct Cell {
        /// От первого слова ячейки до конца `\cellx` (с разделителем).
        package var range: NSRange
        package var items: [Item]

        package var right: Int { items.last { $0.name == "cellx" }?.number ?? 0 }
        package var text: String { items.map(\.text).joined() }
    }

    package var cells: [Cell] = []

    /// Все определения в куске исходника (кусок строки — `DocTableEdit.rowSpan`).
    package static func all(in span: NSRange, source: NSString) -> [RTFRowDefinition] {
        var result: [RTFRowDefinition] = []
        var current: RTFRowDefinition?
        var cell: (start: Int, items: [Item])?
        var inRow = false
        func finish() {
            if let definition = current, !definition.cells.isEmpty { result.append(definition) }
            current = nil
            cell = nil
            inRow = false
        }
        for token in RTFLexer.tokens(source, in: span) {
            let text = source.substring(with: token.range)
            if token.kind == .word, token.name == "trowd" {
                finish()
                current = RTFRowDefinition()
                inRow = true
                continue
            }
            guard current != nil else { continue }
            let filler = token.kind == .newline || (token.kind == .text && text == " ")
            if var open = cell {
                if filler, var last = open.items.popLast() {
                    last.text += text
                    open.items.append(last)
                    cell = open
                    continue
                }
                guard token.kind == .word, token.name.hasPrefix("cl") || token.name == "cellx" || token.name.hasPrefix("brdr") else {
                    finish()
                    continue
                }
                if token.name.hasPrefix("brdr"), var last = open.items.popLast(), last.name.hasPrefix("clbrdr") {
                    last.text += text
                    open.items.append(last)
                } else {
                    open.items.append(Item(name: token.name, number: token.number, text: text))
                }
                if token.name == "cellx" {
                    current?.cells.append(Cell(range: NSRange(location: open.start, length: NSMaxRange(token.range) - open.start), items: open.items))
                    cell = nil
                    inRow = false
                } else {
                    cell = open
                }
                continue
            }
            if token.kind == .word, token.name.hasPrefix("cl") || token.name == "cellx" {
                // Новая ячейка: слово сразу становится первым элементом (обработать как внутри ячейки).
                cell = (token.range.location, [])
                if token.name == "cellx" {
                    current?.cells.append(Cell(range: token.range, items: [Item(name: token.name, number: token.number, text: text)]))
                    cell = nil
                } else {
                    cell?.items.append(Item(name: token.name, number: token.number, text: text))
                }
                inRow = false
                continue
            }
            if filler {
                // Переводы строк и пробел после `\cellx` — к последней ячейке (её кусок непрерывен со следующей).
                if var definition = current, var last = definition.cells.popLast(), NSMaxRange(last.range) == token.range.location {
                    last.range.length += token.range.length
                    last.items[last.items.count - 1].text += text
                    definition.cells.append(last)
                    current = definition
                }
                continue
            }
            if inRow, token.kind == .word, rowWord(token.name) { continue }
            finish()
        }
        finish()
        return result
    }

    /// Слова свойств строки (между `\trowd` и первой ячейкой).
    private static func rowWord(_ name: String) -> Bool {
        ["tr", "tbl", "tp", "tdfrm", "tabsnoovrlp", "irow", "brdr", "ts", "lastrow", "ltrrow", "rtlrow", "taprtl"].contains { name.hasPrefix($0) }
    }
}

extension RTFRowDefinition.Cell {
    /// Без слов `\clvmgf`/`\clvmrg`; с флагом `flag` — первым словом.
    package mutating func setMerge(_ flag: String?) {
        items.removeAll { $0.name == "clvmgf" || $0.name == "clvmrg" }
        if let flag { items.insert(.init(name: flag), at: 0) }
    }

    /// Правая граница; предпочтительная ширина `\clwWidth` (в твипах, `\clftsWidth3`) — следом.
    package mutating func setRight(_ right: Int, width: Int?) {
        if let index = items.lastIndex(where: { $0.name == "cellx" }) {
            items[index] = Self.renumbered(items[index], right)
        }
        if let width, items.contains(where: { $0.name == "clftsWidth" && $0.number == 3 }),
           let index = items.firstIndex(where: { $0.name == "clwWidth" }) {
            items[index] = Self.renumbered(items[index], max(0, width))
        }
    }

    /// Границы: `sides` — какие стороны (`t`, `l`, `b`, `r`) задать, `visible` — линия или явное «нет» (`\brdrnone`).
    package mutating func setBorders(_ sides: [Character], visible: Bool) {
        let names = sides.map { "clbrdr" + String($0) }
        items.removeAll { names.contains($0.name) }
        let added = names.map { name in
            RTFRowDefinition.Item(name: name, text: "\\" + name + (visible ? "\\brdrs\\brdrw10 " : "\\brdrnone "))
        }
        let at = items.lastIndex { $0.name.hasPrefix("clvm") || $0.name.hasPrefix("clvertal") }.map { $0 + 1 } ?? 0
        items.insert(contentsOf: added, at: at)
    }

    /// Заливка: цвет `\clcbpatN` (`nil` — без заливки).
    package mutating func setShading(_ color: Int?) {
        items.removeAll { ["clcbpat", "clcfpat", "clshdng", "clshdrawnil"].contains($0.name) }
        let at = items.lastIndex { $0.name != "cellx" }.map { $0 + 1 } ?? 0
        items.insert(color.map { .init(name: "clcbpat", number: $0) } ?? .init(name: "clshdrawnil"), at: min(at, items.count - 1))
    }

    /// Слово с новым числом, разделитель и переводы строк за ним — прежние.
    private static func renumbered(_ item: RTFRowDefinition.Item, _ number: Int) -> RTFRowDefinition.Item {
        let old = "\\" + item.name + (item.number.map(String.init) ?? "")
        let tail = item.text.hasPrefix(old) ? String(item.text.dropFirst(old.count)) : ""
        return .init(name: item.name, number: number, text: "\\" + item.name + String(number) + tail)
    }
}
