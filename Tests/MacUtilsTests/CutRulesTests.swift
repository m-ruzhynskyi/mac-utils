import XCTest
@testable import MacUtils

final class CutRulesTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b"), c = URL(fileURLWithPath: "/tmp/c")

    func testAliveSplitKeepsOrder() {
        let split = CutRules.alive([a, b, c], exists: { $0 != self.b })
        XCTAssertEqual(split.alive, [a, c])
        XCTAssertEqual(split.gone, [b])
        let none = CutRules.alive([], exists: { _ in true })
        XCTAssertTrue(none.alive.isEmpty && none.gone.isEmpty)
    }

    func testNothingCutPassesThroughEvenIfClipboardChanged() {
        XCTAssertEqual(CutRules.pasteAction(items: [], changeCount: 7, cutChangeCount: 3, exists: { _ in true }), .passThrough)
    }

    func testClipboardChangeCancelsTheCutWithoutLookingAtFiles() {
        var looked = false
        let action = CutRules.pasteAction(items: [a], changeCount: 8, cutChangeCount: 7, exists: { _ in looked = true; return true })
        XCTAssertEqual(action, .cancelledByClipboard)
        XCTAssertFalse(looked, "файлы не опрашиваются, когда вырезание уже отменено")
    }

    func testAllFilesGone() {
        XCTAssertEqual(CutRules.pasteAction(items: [a, b], changeCount: 5, cutChangeCount: 5, exists: { _ in false }), .allGone)
    }

    func testSomeFilesGoneStillMovesTheRest() {
        let action = CutRules.pasteAction(items: [a, b, c], changeCount: 5, cutChangeCount: 5, exists: { $0 == self.b })
        XCTAssertEqual(action, .move(alive: [b], goneCount: 2))
    }

    func testAllAliveMovesEverything() {
        XCTAssertEqual(CutRules.pasteAction(items: [a, b], changeCount: 5, cutChangeCount: 5, exists: { _ in true }), .move(alive: [a, b], goneCount: 0))
    }

    func testMessages() {
        XCTAssertTrue(CutRules.goneMessage(1).contains("1 объект "), CutRules.goneMessage(1))
        XCTAssertTrue(CutRules.goneMessage(2).contains("2 объекта"), CutRules.goneMessage(2))
        XCTAssertTrue(CutRules.goneMessage(5).contains("5 объектов"), CutRules.goneMessage(5))
        XCTAssertTrue(CutRules.clipboardCancelMessage.contains("Вырезание отменено"))
    }

    func testRealExistenceRenamedDeletedAndDanglingLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CutRules-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt"), folder = root.appendingPathComponent("dir")
        try Data("x".utf8).write(to: file)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("broken")
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("нет"))
        XCTAssertTrue(CutRules.exists(file))
        XCTAssertTrue(CutRules.exists(folder))
        XCTAssertTrue(CutRules.exists(link), "битая ссылка — тоже объект, который можно перенести")
        try fm.moveItem(at: file, to: root.appendingPathComponent("renamed.txt"))
        XCTAssertFalse(CutRules.exists(file), "переименованный по старому пути не найден")
        try fm.removeItem(at: folder)
        XCTAssertFalse(CutRules.exists(folder))
    }
}
