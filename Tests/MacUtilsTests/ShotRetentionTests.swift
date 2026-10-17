import XCTest
@testable import MacUtils

/// Срок хранения умной папки: Корзина, пустые папки, пропавшие файлы. Всё — во временной папке:
/// настоящие папки снимков, индекс и Корзина пользователя не трогаются.
@MainActor
final class ShotRetentionTests: XCTestCase {
    private var temp: URL!
    private var base: URL!
    private var root: URL { ShotLibraryRules.smartRoot(in: base) }
    private var trashFolder: URL!
    private let manager = FileManager.default
    /// «Сейчас» для тестов: 17 октября 2026, полдень.
    private let now: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 17; components.hour = 12
        return Calendar.current.date(from: components)!
    }()

    override func setUpWithError() throws {
        temp = manager.temporaryDirectory.appendingPathComponent("ShotRetentionTests-\(UUID().uuidString)", isDirectory: true)
        base = temp.appendingPathComponent("Screens", isDirectory: true)
        trashFolder = temp.appendingPathComponent("Trash", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: temp)
    }

    // MARK: - Помощники

    private func days(_ value: Double) -> TimeInterval { value * 86_400 }

    @discardableResult
    private func folder(_ path: String, dsStore: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        if dsStore { try Data([0]).write(to: url.appendingPathComponent(".DS_Store")) }
        return url
    }

    /// Демо-снимок в «Снимки экрана/дата/программа» и запись о нём.
    private func shot(age: TimeInterval, app: String = "Safari", name: String = "Снимок.png") throws -> ShotRecord {
        let date = now.addingTimeInterval(-age)
        let folder = ShotLibraryRules.folder(root: base, date: date, app: app)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("png".utf8).write(to: url)
        try Data([0]).write(to: folder.appendingPathComponent(".DS_Store"))
        return ShotRecord(path: url.path, date: date, app: app, text: "")
    }

    /// Корзина для тестов: файл переносится во временную папку.
    private var movingTrash: (URL) throws -> Void {
        let target = trashFolder!
        return { url in
            try FileManager.default.moveItem(at: url, to: target.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
    }

    private func library(_ records: [ShotRecord], trash: ((URL) throws -> Void)? = nil, indexFile: URL? = nil) -> ScreenshotLibrary {
        ScreenshotLibrary(records: records, indexFile: indexFile, folderRoots: [root], trash: trash ?? movingTrash)
    }

    private func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }

    // MARK: - Пустые папки

    func testRemovesEmptyDayAndAppFoldersButKeepsRootAndContent() throws {
        try folder("2026-09-30/Safari", dsStore: true)
        try folder("2026-09-30", dsStore: true)
        try folder("2026-10-02/Finder")
        try folder("2026-10-07/Telegram")
        try Data("png".utf8).write(to: root.appendingPathComponent("2026-10-07/Telegram/keep.png"))
        try folder("2026-10-08/Xcode", dsStore: true)
        try folder("2026-10-08/Notes")
        try Data("png".utf8).write(to: root.appendingPathComponent("2026-10-08/Notes/keep.png"))
        try Data([0]).write(to: root.appendingPathComponent(".DS_Store"))

        let removed = ShotFolderCleanup.removeEmptyFolders(in: root, now: now)

        XCTAssertEqual(removed, 5, "09-30/Safari, 09-30, 10-02/Finder, 10-02, 10-08/Xcode")
        XCTAssertFalse(exists(root.appendingPathComponent("2026-09-30")))
        XCTAssertFalse(exists(root.appendingPathComponent("2026-10-02")))
        XCTAssertFalse(exists(root.appendingPathComponent("2026-10-08/Xcode")))
        XCTAssertTrue(exists(root.appendingPathComponent("2026-10-07/Telegram/keep.png")))
        XCTAssertTrue(exists(root.appendingPathComponent("2026-10-08/Notes/keep.png")))
        XCTAssertTrue(exists(root), "корень умной папки остаётся")
        XCTAssertTrue(exists(root.appendingPathComponent(".DS_Store")), ".DS_Store корня не трогаем")
    }

    func testRootStaysEvenWhenEmpty() throws {
        try Data([0]).write(to: root.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(ShotFolderCleanup.removeEmptyFolders(in: root, now: now), 0)
        XCTAssertTrue(exists(root))
    }

    func testOnlyInsideSmartRoot() throws {
        // Папка снимков сама по себе (не «Снимки экрана») — ничего не удаляется, даже пустые папки с датой.
        let outside = base.appendingPathComponent("2026-09-01/Safari", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertEqual(ShotFolderCleanup.removeEmptyFolders(in: base, now: now), 0)
        XCTAssertTrue(exists(outside))
        // Ссылка на чужую папку внутри корня — не идём по ней и не удаляем.
        let foreign = temp.appendingPathComponent("Foreign/Empty", isDirectory: true)
        try manager.createDirectory(at: foreign, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: root.appendingPathComponent("2026-09-02"), withDestinationURL: foreign.deletingLastPathComponent())
        XCTAssertEqual(ShotFolderCleanup.removeEmptyFolders(in: root, now: now), 0)
        XCTAssertTrue(exists(foreign))
        XCTAssertNotNil(try? manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("2026-09-02").path))
    }

    func testOnlyDayFoldersAndTheirApps() throws {
        try folder("Мои заметки")
        try folder("2026-10-01/Safari/Черновики")
        XCTAssertEqual(ShotFolderCleanup.removeEmptyFolders(in: root, now: now), 0,
                       "папку не с датой и вложенные глубже программы не трогаем")
        XCTAssertTrue(exists(root.appendingPathComponent("Мои заметки")))
        XCTAssertTrue(exists(root.appendingPathComponent("2026-10-01/Safari/Черновики")))
    }

    func testOtherHiddenFilesKeepFolder() throws {
        let folder = try folder("2026-10-01/Safari", dsStore: true)
        try Data([0]).write(to: folder.appendingPathComponent(".hidden"))
        XCTAssertEqual(ShotFolderCleanup.removeEmptyFolders(in: root, now: now), 0, "пустая — только с .DS_Store")
        XCTAssertTrue(exists(folder.appendingPathComponent(".hidden")))
    }

    func testTodayAndYesterdayFoldersStay() throws {
        // Снимок получает папку раньше, чем файл записан: сегодняшнюю и вчерашнюю пустые папки не трогаем.
        let today = ShotLibraryRules.dayName(now), yesterday = ShotLibraryRules.dayName(now.addingTimeInterval(-days(1)))
        try folder("\(today)/Safari")
        try folder("\(yesterday)/Safari")
        try folder("2026-10-10/Safari")
        XCTAssertEqual(ShotFolderCleanup.removeEmptyFolders(in: root, now: now), 2)
        XCTAssertTrue(exists(root.appendingPathComponent("\(today)/Safari")))
        XCTAssertTrue(exists(root.appendingPathComponent("\(yesterday)/Safari")))
        XCTAssertFalse(exists(root.appendingPathComponent("2026-10-10")))
    }

    // MARK: - Срок

    func testExpiredGoToTrashAndEmptyFoldersGo() throws {
        let old = try shot(age: days(8))
        let fresh = try shot(age: days(2), app: "Telegram")
        let index = temp.appendingPathComponent("screenshots.json")
        let library = library([fresh, old], indexFile: index)

        XCTAssertEqual(library.removeExpired(now: now, days: 7), 1)

        XCTAssertEqual(library.records.map(\.path), [fresh.path])
        XCTAssertFalse(exists(old.url))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: trashFolder.path).count, 1, "в Корзину, не безвозвратно")
        XCTAssertFalse(exists(old.url.deletingLastPathComponent().deletingLastPathComponent()), "папка дня ушла вместе с программой")
        XCTAssertTrue(exists(fresh.url))
        XCTAssertTrue(exists(root))
        let saved = try JSONDecoder().decode([ShotRecord].self, from: Data(contentsOf: index))
        XCTAssertEqual(saved.map(\.path), [fresh.path])
    }

    func testSevenDayBoundary() throws {
        let exactly = try shot(age: days(7), name: "ровно.png")
        let older = try shot(age: days(7) + 1, name: "старше.png")
        let library = library([exactly, older])
        XCTAssertEqual(library.removeExpired(now: now, days: 7), 1)
        XCTAssertEqual(library.records.map(\.path), [exactly.path], "ровно 7 дней ещё хранится, на секунду старше — нет")
        XCTAssertEqual(library.removeExpired(now: now.addingTimeInterval(1), days: 7), 1)
        XCTAssertTrue(library.records.isEmpty)
    }

    func testFailedTrashKeepsRecordForRetry() throws {
        let old = try shot(age: days(10))
        var attempts = 0
        let failing = ScreenshotLibrary(records: [old], folderRoots: [root]) { _ in
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        XCTAssertEqual(failing.removeExpired(now: now, days: 7), 0)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(failing.records.map(\.path), [old.path], "запись остаётся для повторной попытки")
        XCTAssertTrue(exists(old.url))
        XCTAssertTrue(exists(old.url.deletingLastPathComponent()), "папка с файлом не удаляется")
        // Следующая проверка — снова попытка.
        XCTAssertEqual(failing.removeExpired(now: now, days: 7), 0)
        XCTAssertEqual(attempts, 2)

        let working = library(failing.records)
        XCTAssertEqual(working.removeExpired(now: now, days: 7), 1)
        XCTAssertTrue(working.records.isEmpty)
    }

    func testManuallyDeletedFilesLeaveIndex() throws {
        let deleted = try shot(age: days(1), app: "Notes")
        let kept = try shot(age: days(1), app: "Safari")
        // Пользователь удалил файл руками (через Finder), папка осталась пустой. Папка — вчерашняя, её не трогаем,
        // поэтому для проверки папок берём снимок постарше.
        let deletedOld = try shot(age: days(3), app: "Mail")
        try manager.removeItem(at: deleted.url)
        try manager.removeItem(at: deletedOld.url)
        let library = library([deleted, kept, deletedOld])

        XCTAssertEqual(library.removeExpired(now: now, days: 0), 0, "срок 0 — ничего не удаляется")
        XCTAssertEqual(library.records.map(\.path), [kept.path])
        XCTAssertFalse(exists(deletedOld.url.deletingLastPathComponent()), "пустая папка старого дня ушла")
        XCTAssertTrue(exists(kept.url))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: trashFolder.path).count, 0)
    }

    func testRemoveFromLibrary() throws {
        let shotURL = try shot(age: days(4))
        let failing = ScreenshotLibrary(records: [shotURL], folderRoots: [root]) { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertFalse(failing.remove(shotURL))
        XCTAssertEqual(failing.records.count, 1, "не ушёл в Корзину — остаётся в списке")
        XCTAssertTrue(exists(shotURL.url))

        let library = library([shotURL])
        XCTAssertTrue(library.remove(shotURL))
        XCTAssertTrue(library.records.isEmpty)
        XCTAssertFalse(exists(shotURL.url.deletingLastPathComponent().deletingLastPathComponent()), "папка дня убрана")
        XCTAssertTrue(exists(root))
    }

    func testSmartRootOfRecord() {
        let record = ShotRecord(path: "/x/Screens/Снимки экрана/2026-10-07/Safari/a.png", date: now, app: "Safari", text: "")
        XCTAssertEqual(ShotLibraryRules.smartRoot(of: record)?.path, "/x/Screens/Снимки экрана")
        let loose = ShotRecord(path: "/x/Screens/a.png", date: now, app: "", text: "")
        XCTAssertNil(ShotLibraryRules.smartRoot(of: loose))
        XCTAssertTrue(ShotLibraryRules.isDayName("2026-10-07"))
        XCTAssertFalse(ShotLibraryRules.isDayName("Мои"))
    }
}
