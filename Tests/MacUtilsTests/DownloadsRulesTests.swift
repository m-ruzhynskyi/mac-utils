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

    func testFolderNameWithCustomRules() {
        let custom = ["mdz": "Lab", "pdf": "Papers"]
        XCTAssertEqual(DownloadsRules.folderName(for: URL(fileURLWithPath: "/d/x.MDZ"), custom: custom), "Lab")
        XCTAssertEqual(DownloadsRules.folderName(for: URL(fileURLWithPath: "/d/x.pdf"), custom: custom), "Papers", "правило важнее")
        XCTAssertEqual(DownloadsRules.folderName(for: URL(fileURLWithPath: "/d/x.png"), custom: custom), "Images")
        XCTAssertNil(DownloadsRules.folderName(for: URL(fileURLWithPath: "/d/x.qqq"), custom: custom))
        XCTAssertEqual(DownloadsRules.normalizedExtension(" .Sketch "), "sketch")
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
        try manager.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try Data("y".utf8).write(to: root.appendingPathComponent("Documents/report.pdf"))

        let result = DownloadsSorter.shared.run(in: root, trashDays: 0)
        XCTAssertEqual(result.moved, 2)
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("Images/photo.png").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("Documents/report (2).pdf").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("movie.mp4.crdownload").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("fresh.zip").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("README").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("My Folder").path))
    }

    func testCustomRulesAndLegacyFolders() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("DownloadsSorterTest2-\(UUID().uuidString)")
        try manager.createDirectory(at: root.appendingPathComponent("Изображения"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try Data("old".utf8).write(to: root.appendingPathComponent("Изображения/old.png"))
        let file = root.appendingPathComponent("lab.mdz")
        try Data("x".utf8).write(to: file)
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)

        let saved = UserDefaults.standard.dictionary(forKey: Pref.downloadsCustomRules)
        UserDefaults.standard.set(["mdz": "Lab"], forKey: Pref.downloadsCustomRules)
        defer { UserDefaults.standard.set(saved, forKey: Pref.downloadsCustomRules) }

        DownloadsSorter.shared.run(in: root, trashDays: 0)
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("Lab/lab.mdz").path), "своё правило")
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("Images/old.png").path), "русская папка переименована")
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("Изображения").path))
    }
}
