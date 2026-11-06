import Foundation

/// Выделение ячеек таблицы (TB2): какие ячейки входят в выделение протяжкой, щелчком у края ячейки, строки или столбца. Чистые функции
/// по модели: прямоугольник определяется по горизонтальным интервалам ячеек (твипы), поэтому работает и с таблицей, у которой границы
/// в строках не совпадают.
extension DocTableEdit {
    /// Ячейки строки `row`, чьи интервалы пересекаются с `left..<right` не меньше чем на 20 твипов.
    private static func cells(inRow row: Int, table: Int, left: Int, right: Int, story: RTFStory) -> [CellRef] {
        guard let r = story.tables[safe: table]?.rows[safe: row] else { return [] }
        return edges(r).enumerated().compactMap { index, edge in
            min(edge.right, right) - max(edge.left, left) > 20 ? CellRef(row: row, cell: index) : nil
        }
    }

    private static func interval(_ ref: CellRef, table: Int, story: RTFStory) -> (left: Int, right: Int)? {
        story.tables[safe: table]?.rows[safe: ref.row].flatMap { edges($0)[safe: ref.cell] }
    }

    /// Одна ячейка целиком.
    package static func selection(cell ref: CellRef, table: Int, story: RTFStory) -> Set<CellRef> {
        interval(ref, table: table, story: story) == nil ? [] : [ref]
    }

    /// Строка целиком.
    package static func selection(row: Int, table: Int, story: RTFStory) -> Set<CellRef> {
        Set(story.tables[safe: table]?.rows[safe: row].map { edges($0).indices.map { CellRef(row: row, cell: $0) } } ?? [])
    }

    /// Столбец под ячейкой `ref`: в каждой строке ячейки над тем же интервалом.
    package static func selection(columnOf ref: CellRef, table: Int, story: RTFStory) -> Set<CellRef> {
        guard let span = interval(ref, table: table, story: story), let rows = story.tables[safe: table]?.rows else { return [] }
        return Set(rows.indices.flatMap { cells(inRow: $0, table: table, left: span.left, right: span.right, story: story) })
    }

    /// Прямоугольник между двумя ячейками: строки между ними и ячейки над объединением их интервалов (протяжка мышью, ⇧+стрелки).
    package static func selection(from a: CellRef, to b: CellRef, table: Int, story: RTFStory) -> Set<CellRef> {
        guard let x = interval(a, table: table, story: story), let y = interval(b, table: table, story: story) else { return [] }
        let left = min(x.left, y.left), right = max(x.right, y.right)
        return Set((min(a.row, b.row)...max(a.row, b.row)).flatMap { cells(inRow: $0, table: table, left: left, right: right, story: story) })
    }

    /// Выделение — несколько ячеек (одна ячейка — обычный курсор в тексте).
    package static func isCellSelection(_ cells: Set<CellRef>) -> Bool { cells.count > 1 }
}
