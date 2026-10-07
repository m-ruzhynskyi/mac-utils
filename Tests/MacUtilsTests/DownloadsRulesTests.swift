import XCTest
@testable import MacUtils

final class DownloadsRulesTests: XCTestCase {
    func testCategories() {
        XCTAssertEqual(DownloadsRules.category(for: URL(fileURLWithPath: "/d/photo.JPG")), .images)
        XCTAssertEqual(DownloadsRules.category(for: URL(fileURLWithPath: "/d/report.pdf")), .documents)
        XCTAssertEqual(DownloadsRules.category(for: URL(fileURLWithPath: "/d/app.dmg")), .installers)
        XCTAssertEqual(DownloadsRules.category(for: URL(fileURLWithPath: "/d/a.tar.gz")), .archives)
        XCTAssertEqual(DownloadsRules.category(for: URL(fileURLWithPath: "/d/clip.mov")), .video)
        XCTAssertNil(DownloadsRules.category(for: URL(fileURLWithPath: "/d/README")))
        XCTAssertNil(DownloadsRules.category(for: URL(fileURLWithPath: "/d/thing.xyz")))
    }

    func testPartialDownloadsSkipped() {
        XCTAssertTrue(DownloadsRules.isPartial(URL(fileURLWithPath: "/d/movie.mp4.crdownload")))
        XCTAssertTrue(DownloadsRules.isPartial(URL(fileURLWithPath: "/d/file.download")))
        XCTAssertTrue(DownloadsRules.isPartial(URL(fileURLWithPath: "/d/.DS_Store")))
        XCTAssertFalse(DownloadsRules.isPartial(URL(fileURLWithPath: "/d/file.pdf")))
    }

    func testUniqueName() {
        XCTAssertEqual(DownloadsRules.uniqueName("a.pdf", existing: []), "a.pdf")
        XCTAssertEqual(DownloadsRules.uniqueName("a.pdf", existing: ["a.pdf"]), "a (2).pdf")
        XCTAssertEqual(DownloadsRules.uniqueName("a.pdf", existing: ["a.pdf", "a (2).pdf"]), "a (3).pdf")
        XCTAssertEqual(DownloadsRules.uniqueName("notes", existing: ["notes"]), "notes (2)")
    }

    func testExpiry() {
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        let recent = now.addingTimeInterval(-2 * 86_400)
        XCTAssertTrue(DownloadsRules.isExpired(modified: old, accessed: old, days: 30, now: now))
        XCTAssertFalse(DownloadsRules.isExpired(modified: old, accessed: recent, days: 30, now: now), "недавно открывали")
        XCTAssertFalse(DownloadsRules.isExpired(modified: old, accessed: old, days: 0, now: now), "0 — никогда")
    }
}

@MainActor
final class DownloadsSorterRunTests: XCTestCase {
    func testSortsIntoCategoryFoldersAndTrashesOld() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("DownloadsSorterTest-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let old = Date().addingTimeInterval(-3600)
        func make(_ name: String, modified: Date = old) throws {
            let url = root.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try manager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        try make("photo.png")
        try make("report.pdf")
        try make("movie.mp4.crdownload")   // недокачан
        try make("fresh.zip", modified: Date())  // ещё пишется
        try make("README")                 // без типа
        try manager.createDirectory(at: root.appendingPathComponent("My Folder"), withIntermediateDirectories: true)
        // Уже есть такой файл в категории — получит «(2)».
        try manager.createDirectory(at: root.appendingPathComponent("Документы"), withIntermediateDirectories: true)
        try Data("y".utf8).write(to: root.appendingPathComponent("Документы/report.pdf"))

        let result = DownloadsSorter.shared.run(in: root, trashDays: 0)
        XCTAssertEqual(result.moved, 2)
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("Изображения/photo.png").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("Документы/report (2).pdf").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("movie.mp4.crdownload").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("fresh.zip").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("README").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("My Folder").path))
    }
}
