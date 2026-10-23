import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDownloadsSorter
@testable import MUTextEditor

/// Первый запуск «Загрузок»: ничего не уходит в Корзину без согласия, разложенное в этом проходе не трогается,
/// опасные имена папок отвергаются.
@MainActor
final class DownloadsFirstRunTests: XCTestCase {
    private var folder: URL!
    private var savedDays: Any?
    private var savedConfirmed: Any?
    private var savedRules: Any?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-first-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        savedDays = defaults.object(forKey: Pref.downloadsTrashDays)
        savedConfirmed = defaults.object(forKey: DownloadsRules.trashConfirmedKey)
        savedRules = defaults.object(forKey: Pref.downloadsCustomRules)
        defaults.removeObject(forKey: Pref.downloadsTrashDays)
        defaults.removeObject(forKey: DownloadsRules.trashConfirmedKey)
        defaults.removeObject(forKey: Pref.downloadsCustomRules)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        let defaults = UserDefaults.standard
        for (key, value) in [(Pref.downloadsTrashDays, savedDays), (DownloadsRules.trashConfirmedKey, savedConfirmed),
                             (Pref.downloadsCustomRules, savedRules)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    /// Файл с датой изменения и открытия `daysAgo` дней назад (mtime и atime: просрочка считается по позднему из них).
    @discardableResult
    private func makeFile(_ relative: String, daysAgo: Double) throws -> URL {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        let stamp = Date().addingTimeInterval(-daysAgo * 86_400)
        var times = [timeval(tv_sec: Int(stamp.timeIntervalSince1970), tv_usec: 0),
                     timeval(tv_sec: Int(stamp.timeIntervalSince1970), tv_usec: 0)]
        XCTAssertEqual(utimes(url.path, &times), 0)
        setAdded(url, stamp)
        return url
    }

    /// Дата добавления в папку (`addedToDirectoryDate`) ставится системой при создании; для тестов состариваем её явно.
    private func setAdded(_ url: URL, _ date: Date) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        var stamp = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        XCTAssertEqual(setattrlist(url.path, &list, &stamp, MemoryLayout<timespec>.size, 0), 0, "не удалось поставить дату добавления")
    }

    // MARK: имена папок

    func testValidatedFolderRejectsDangerousNames() {
        for bad in ["", "   ", ".", "..", "...", "~", "~/", "/", "//", "/..", "/a/../b", "/a/./b", "/.", "\0"] {
            XCTAssertNil(DownloadsRules.validatedFolder(bad), "\(bad.debugDescription) принято")
        }
    }

    func testValidatedFolderAcceptsNormalNamesAndPaths() {
        XCTAssertEqual(DownloadsRules.validatedFolder("Work"), "Work")
        XCTAssertEqual(DownloadsRules.validatedFolder("  Lab  "), "Lab")
        XCTAssertEqual(DownloadsRules.validatedFolder("a/b"), "a-b", "«/» внутри относительного имени заменяется, как и раньше")
        XCTAssertEqual(DownloadsRules.validatedFolder(".hidden"), ".hidden")
        XCTAssertEqual(DownloadsRules.validatedFolder("/Users/me/Lab/"), "/Users/me/Lab")
        XCTAssertEqual(DownloadsRules.validatedFolder("~/Projects"), NSHomeDirectory() + "/Projects")
    }

    func testFolderNameIgnoresInvalidRuleAndFallsBackToCategory() {
        let pdf = URL(fileURLWithPath: "/tmp/a.pdf")
        XCTAssertEqual(DownloadsRules.folderName(for: pdf, custom: ["pdf": ".."]), "Documents")
        XCTAssertEqual(DownloadsRules.folderName(for: URL(fileURLWithPath: "/tmp/a.zzz"), custom: ["zzz": "~"]), nil)
        XCTAssertEqual(DownloadsRules.folderName(for: pdf, custom: ["pdf": "Work"]), "Work")
    }

    func testSetRuleRefusesDangerousFolder() {
        let sorter = DownloadsSorter.shared
        XCTAssertFalse(sorter.setRule(extension: "qqq", folder: ".."))
        XCTAssertFalse(sorter.setRule(extension: "qqq", folder: "/"))
        XCTAssertNil(DownloadsSorter.customRules["qqq"])
        XCTAssertTrue(sorter.setRule(extension: "qqq", folder: "Lab"))
        XCTAssertEqual(DownloadsSorter.customRules["qqq"], "Lab")
        XCTAssertTrue(sorter.setRule(extension: "qqq", folder: nil))
        XCTAssertNil(DownloadsSorter.customRules["qqq"])
    }

    // MARK: Корзина

    func testSortedInThisPassIsNotTrashed() throws {
        let old = try makeFile("report.pdf", daysAgo: 400)
        let trashed = NSMutableArray()
        let result = DownloadsSorter.shared.run(in: folder, trashDays: 30) { url in trashed.add(url); return true }
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.trashed, 0, "файл только что разложен — в Корзину в этом же проходе не идёт")
        XCTAssertEqual(trashed.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Documents/report.pdf").path))
    }

    func testAlreadySortedOldFileIsTrashedWhenDaysGivenExplicitly() throws {
        let old = try makeFile("Documents/old.pdf", daysAgo: 400)
        let fresh = try makeFile("Documents/fresh.pdf", daysAgo: 1)
        var trashed: [String] = []
        let result = DownloadsSorter.shared.run(in: folder, trashDays: 30) { url in trashed.append(url.lastPathComponent); return true }
        XCTAssertEqual(trashed, ["old.pdf"])
        XCTAssertEqual(result.trashed, 1)
        _ = (old, fresh)
    }

    func testWithoutConfirmationNothingIsTrashedAndPreviewIsShown() throws {
        try makeFile("Documents/old1.pdf", daysAgo: 400)
        try makeFile("Images/old2.png", daysAgo: 400)
        UserDefaults.standard.set(30, forKey: Pref.downloadsTrashDays)
        var called = 0
        // trashDays не задан: срок из настроек, согласия на него ещё нет.
        let result = DownloadsSorter.shared.run(in: folder) { _ in called += 1; return true }
        XCTAssertEqual(called, 0)
        XCTAssertEqual(result.trashed, 0)
        XCTAssertEqual(Set(DownloadsSorter.shared.trashPreview.map(\.lastPathComponent)), ["old1.pdf", "old2.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Documents/old1.pdf").path))
    }

    func testConfirmationIsPerDaysValue() throws {
        try makeFile("Documents/old.pdf", daysAgo: 400)
        UserDefaults.standard.set(30, forKey: Pref.downloadsTrashDays)
        DownloadsRules.confirmTrash(days: 30)
        var trashed: [String] = []
        DownloadsSorter.shared.run(in: folder) { url in trashed.append(url.lastPathComponent); return true }
        XCTAssertEqual(trashed, ["old.pdf"], "срок подтверждён — старое уходит в Корзину")
        XCTAssertTrue(DownloadsSorter.shared.trashPreview.isEmpty)

        // Другой срок — подтверждение нужно заново.
        try makeFile("Documents/old2.pdf", daysAgo: 400)
        UserDefaults.standard.set(7, forKey: Pref.downloadsTrashDays)
        trashed = []
        DownloadsSorter.shared.run(in: folder) { url in trashed.append(url.lastPathComponent); return true }
        XCTAssertEqual(trashed, [])
        XCTAssertFalse(DownloadsRules.isTrashConfirmed(days: 7))
        XCTAssertFalse(DownloadsRules.isTrashConfirmed(days: 0))
    }

    func testCustomRuleFoldersAreNotAutoTrashed() throws {
        UserDefaults.standard.set(["zzz": "Work"], forKey: Pref.downloadsCustomRules)
        let mine = try makeFile("Work/keep.zzz", daysAgo: 400)
        let candidates = DownloadsRules.trashCandidates(in: folder, days: 30)
        XCTAssertTrue(candidates.isEmpty)
        var called = 0
        DownloadsSorter.shared.run(in: folder, trashDays: 30) { _ in called += 1; return true }
        XCTAssertEqual(called, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path))
    }

    func testTrashCandidatesRespectExclusionAndAge() throws {
        let old = try makeFile("Images/a.png", daysAgo: 100)
        try makeFile("Images/b.png", daysAgo: 5)
        XCTAssertEqual(DownloadsRules.trashCandidates(in: folder, days: 30).map(\.lastPathComponent), ["a.png"])
        XCTAssertTrue(DownloadsRules.trashCandidates(in: folder, days: 30, excluding: [old.standardizedFileURL]).isEmpty)
        XCTAssertTrue(DownloadsRules.trashCandidates(in: folder, days: 0).isEmpty)
        XCTAssertEqual(DownloadsRules.trashCandidates(in: folder, days: 30, now: Date().addingTimeInterval(86_400 * 60)).count, 2)
    }

    func testConfirmationStoreUsesGivenDefaults() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "dl-tests-\(UUID().uuidString)"))
        XCTAssertFalse(DownloadsRules.isTrashConfirmed(days: 30, defaults: suite))
        DownloadsRules.confirmTrash(days: 30, defaults: suite)
        XCTAssertTrue(DownloadsRules.isTrashConfirmed(days: 30, defaults: suite))
        XCTAssertFalse(DownloadsRules.isTrashConfirmed(days: 31, defaults: suite))
    }

    func testManyFilesWithSameNameGetUniqueNamesInOnePass() throws {
        for i in 0..<5 {
            try makeFile("bundle\(i)/a.pdf", daysAgo: 10)
            try FileManager.default.moveItem(at: folder.appendingPathComponent("bundle\(i)/a.pdf"), to: folder.appendingPathComponent("a\(i).pdf"))
        }
        try makeFile("Documents/a0.pdf", daysAgo: 10)
        DownloadsSorter.shared.run(in: folder, trashDays: 0)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Documents").path))
        XCTAssertEqual(names.count, 6)
        XCTAssertTrue(names.contains("a0 (2).pdf"))
    }

    // MARK: ревью пакета 1: MAJOR-2, N3

    func testAddedToDirectoryDateProtectsFileWithOldTimestamps() {
        let old = Date().addingTimeInterval(-800 * 86_400), now = Date()
        XCTAssertTrue(DownloadsRules.isExpired(modified: old, accessed: old, added: old, days: 30, now: now))
        XCTAssertFalse(DownloadsRules.isExpired(modified: old, accessed: old, added: now, days: 30, now: now),
                       "только что добавлен в папку — не просрочен при любых датах файла")
        XCTAssertTrue(DownloadsRules.isExpired(modified: old, accessed: old, added: nil, days: 30, now: now))
    }

    /// Файл из архива со старыми mtime/atime, разложенный предыдущим проходом, при следующем проходе не уходит в Корзину.
    func testFileSortedByEarlierPassIsNotTrashedByLaterPass() throws {
        try makeFile("report.pdf", daysAgo: 730)
        DownloadsSorter.shared.run(in: folder, trashDays: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Documents/report.pdf").path))
        var trashed: [String] = []
        DownloadsSorter.shared.run(in: folder, trashDays: 30) { url in trashed.append(url.lastPathComponent); return true }
        XCTAssertEqual(trashed, [], "дата добавления в папку свежая, хотя mtime/atime двухлетние")
    }

    func testConfirmTrashSendsOnlyWhatWasShown() throws {
        try makeFile("Documents/shown.pdf", daysAgo: 400)
        UserDefaults.standard.set(30, forKey: Pref.downloadsTrashDays)
        let sorter = DownloadsSorter.shared
        sorter.run(in: folder)
        let shown = Set(sorter.trashPreview.map(\.standardizedFileURL))
        XCTAssertEqual(shown.map(\.lastPathComponent), ["shown.pdf"])
        // Появился ещё один просроченный файл уже после предпросмотра.
        try makeFile("Documents/later.pdf", daysAgo: 500)
        var trashed: [String] = []
        sorter.run(in: folder, trashDays: 30, only: shown) { url in trashed.append(url.lastPathComponent); return true }
        XCTAssertEqual(trashed, ["shown.pdf"], "в Корзину — только показанное")
    }

    func testRuleToDownloadsFolderItselfIsRefused() {
        let downloads = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        XCTAssertNil(DownloadsRules.validatedFolder(downloads.path, downloads: downloads))
        XCTAssertNil(DownloadsRules.validatedFolder(NSHomeDirectory(), downloads: downloads), "родитель «Загрузок»")
        XCTAssertNotNil(DownloadsRules.validatedFolder(NSHomeDirectory() + "/Projects/Lab", downloads: downloads))
        XCTAssertNotNil(DownloadsRules.validatedFolder(downloads.path + "/Sub", downloads: downloads))
    }

    func testRuleTargetEqualToSourceFolderDoesNothing() throws {
        UserDefaults.standard.set(["zzz": folder.path], forKey: Pref.downloadsCustomRules)
        let file = try makeFile("a.zzz", daysAgo: 10)
        let result = DownloadsSorter.shared.run(in: folder, trashDays: 0)
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "имя не растёт: файл не переезжает сам в себя")
    }
}
