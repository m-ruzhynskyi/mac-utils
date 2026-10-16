import XCTest
@testable import MacUtils

/// Полка: ложное открытие по устаревшему пастборду перетаскивания, дубли и исчезнувшие файлы.
final class DropShelfModelTests: XCTestCase {
    func testOnlyANewDragWithFilesOpensTheShelf() {
        // Пастборд с файлами от прошлого перетаскивания (не менялся после нажатия кнопки) — не открываем.
        XCTAssertFalse(DragSession.isFileDrag(changeCountAtMouseDown: 7, changeCountNow: 7, hasFileURLs: true))
        // Новое перетаскивание файлов.
        XCTAssertTrue(DragSession.isFileDrag(changeCountAtMouseDown: 7, changeCountNow: 8, hasFileURLs: true))
        // Новое перетаскивание, но не файлов (текст, картинка из браузера).
        XCTAssertFalse(DragSession.isFileDrag(changeCountAtMouseDown: 7, changeCountNow: 8, hasFileURLs: false))
        // Нажатие не видели (кнопку зажали до запуска) — не рискуем.
        XCTAssertFalse(DragSession.isFileDrag(changeCountAtMouseDown: nil, changeCountNow: 8, hasFileURLs: true))
    }

    func testSameFileUnderDifferentPathsIsAddedOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("отчёт.pdf")
        try Data("x".utf8).write(to: file)
        let resolved = file.resolvingSymlinksInPath().path
        // Временная папка лежит в /var/folders → /private/var/folders: оба пути — один файл.
        let viaVar = URL(fileURLWithPath: resolved.replacingOccurrences(of: "/private/var/", with: "/var/"))
        let viaPrivate = URL(fileURLWithPath: resolved)
        let viaDots = folder.appendingPathComponent("sub/../отчёт.pdf")
        let items = ShelfItems.adding([viaVar, viaPrivate, viaDots, file], to: [])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(ShelfItems.adding([file], to: items), items, "уже лежащий не добавляется второй раз")
    }

    func testOrderIsKeptAndNewFilesAppended() {
        let a = URL(fileURLWithPath: "/tmp/shelf-a"), b = URL(fileURLWithPath: "/tmp/shelf-b"), c = URL(fileURLWithPath: "/tmp/shelf-c")
        let items = ShelfItems.adding([a, b], to: [])
        XCTAssertEqual(ShelfItems.adding([c, a], to: items).map(\.lastPathComponent), ["shelf-a", "shelf-b", "shelf-c"])
    }

    func testMissingFilesArePruned() {
        let kept = URL(fileURLWithPath: "/tmp/есть"), gone = URL(fileURLWithPath: "/tmp/удалён")
        XCTAssertEqual(ShelfItems.existing([kept, gone], exists: { $0 == kept }), [kept])
        XCTAssertEqual(ShelfItems.existing([], exists: { _ in true }), [])
    }
}
