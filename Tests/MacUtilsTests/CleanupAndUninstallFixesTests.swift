import XCTest
@testable import MacUtils
@testable import MUUninstaller
@testable import MUAudio
@testable import MUTextEditor

/// T2–T5 (очистка диска) и U2–U3 (удаление программ).
@MainActor
final class CleanupAndUninstallFixesTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("CleanupFixes-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let items = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in items { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        try? fm.removeItem(at: root)
    }

    private var downloads: CleanupCategory { CleanupCategory.all(home: root).first { $0.kind == .downloads }! }
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

    // MARK: T3 — дата добавления

    func testRecentlyAddedFileWithOldMtimeIsNotOld() {
        XCTAssertFalse(downloads.includes(name: "из-архива.zip", modified: days(400), added: days(1), now: now),
                       "mtime сохранён из архива, но скачано вчера")
    }

    func testOldOnlyWhenBothDatesAreOld() {
        XCTAssertTrue(downloads.includes(name: "a.zip", modified: days(90), added: days(60), now: now))
        XCTAssertFalse(downloads.includes(name: "b.zip", modified: days(2), added: days(60), now: now), "недавно изменённый не трогаем")
        XCTAssertFalse(downloads.includes(name: "c.zip", modified: days(60), added: days(29), now: now))
        XCTAssertTrue(downloads.includes(name: "d.zip", modified: days(31), added: days(31.5), now: now))
    }

    func testMissingDatesFallBack() {
        XCTAssertTrue(downloads.includes(name: "a.zip", modified: days(60), added: nil, now: now), "нет даты добавления — по mtime")
        XCTAssertTrue(downloads.includes(name: "b.zip", modified: nil, added: days(60), now: now), "нет mtime — по дате добавления")
        XCTAssertFalse(downloads.includes(name: "c.zip", modified: nil, added: nil, now: now), "без дат не удаляем")
    }

    func testOldSignatureStillWorks() {
        XCTAssertTrue(downloads.includes(name: "a.zip", modified: days(60), now: now))
        XCTAssertFalse(downloads.includes(name: ".DS_Store", modified: days(600), added: days(600), now: now))
        let cache = CleanupCategory.all(home: root).first { $0.kind == .caches }!
        XCTAssertTrue(cache.includes(name: "x", modified: nil, added: nil, now: now), "для кэша даты не важны")
    }

    func testRealFileAddedDateIsReadable() throws {
        let file = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: days(400)], ofItemAtPath: file.path)
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey])
        XCTAssertFalse(downloads.includes(name: "a.txt", modified: values.contentModificationDate, added: values.addedToDirectoryDate),
                       "только что созданный файл с древним mtime не «старая загрузка»")
    }

    // MARK: T4 — отказ в доступе

    func testAccessDeniedErrors() {
        XCTAssertTrue(CleanupCategory.isAccessDenied(CocoaError(.fileReadNoPermission)))
        XCTAssertTrue(CleanupCategory.isAccessDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertTrue(CleanupCategory.isAccessDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertTrue(CleanupCategory.isAccessDenied(wrapped), "причина во вложенной ошибке")
        XCTAssertFalse(CleanupCategory.isAccessDenied(CocoaError(.fileReadNoSuchFile)), "нет папки — не отказ в доступе")
        XCTAssertFalse(CleanupCategory.isAccessDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    }

    func testUnreadableFolderIsReportedAsDeniedAndMissingOneIsNot() throws {
        try XCTSkipIf(getuid() == 0, "root читает любой каталог")
        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        do { _ = try fm.contentsOfDirectory(at: locked, includingPropertiesForKeys: nil); XCTFail("должно не читаться") }
        catch { XCTAssertTrue(CleanupCategory.isAccessDenied(error), "\(error)") }
        do { _ = try fm.contentsOfDirectory(at: root.appendingPathComponent("нет"), includingPropertiesForKeys: nil); XCTFail() }
        catch { XCTAssertFalse(CleanupCategory.isAccessDenied(error), "\(error)") }
    }

    // MARK: T2/T5 — очистка и тексты

    private func item(_ name: String, _ kind: CleanupCategory.Kind, _ size: Int64) -> CleanupItem {
        CleanupItem(url: root.appendingPathComponent(name), category: kind, size: size)
    }

    func testPerformDetailedSeparatesTrashedFromDeleted() {
        var trashed: [String] = [], removed: [String] = []
        let items = [item("c1", .caches, 100), item("t1", .trash, 400), item("d1", .downloads, 50), item("bad", .logs, 10)]
        let outcome = DiskCleanupModel.performDetailed(items, trash: { url in
            if url.lastPathComponent == "bad" { throw CocoaError(.fileWriteNoPermission) }
            trashed.append(url.lastPathComponent)
        }, remove: { removed.append($0.lastPathComponent) })
        XCTAssertEqual(outcome, DiskCleanupModel.Outcome(trashed: 150, deleted: 400, failed: 1))
        XCTAssertEqual(trashed, ["c1", "d1"])
        XCTAssertEqual(removed, ["t1"])
    }

    func testResultTextDoesNotClaimFreedSpaceForTrashedFiles() {
        let onlyTrashed = DiskCleanupModel.resultText(.init(trashed: 5_000_000, deleted: 0, failed: 0))
        XCTAssertTrue(onlyTrashed.hasPrefix("Перенесено в Корзину"), onlyTrashed)
        XCTAssertFalse(onlyTrashed.contains("Освобождено"))
        XCTAssertTrue(onlyTrashed.contains("после её очистки"))
        let deleted = DiskCleanupModel.resultText(.init(trashed: 0, deleted: 5_000_000, failed: 0))
        XCTAssertTrue(deleted.hasPrefix("Удалено насовсем"), deleted)
        XCTAssertFalse(deleted.contains("Корзину"))
        let mixed = DiskCleanupModel.resultText(.init(trashed: 1_000_000, deleted: 2_000_000, failed: 2))
        XCTAssertTrue(mixed.contains("Удалено насовсем") && mixed.contains("перенесено в Корзину") && mixed.contains("Не удалось: 2"), mixed)
        XCTAssertEqual(DiskCleanupModel.resultText(.init()), "Ничего не убрано")
    }

    func testPerformStillWorksForOldCallers() {
        let result = DiskCleanupModel.perform([item("a", .caches, 7), item("b", .trash, 3)], trash: { _ in }, remove: { _ in })
        XCTAssertEqual(result.freed, 10)
        XCTAssertEqual(result.failed, 0)
    }

    func testCleaningHappensOffTheMainThread() async {
        let items = (0..<5).map { item("f\($0)", .caches, 1) }
        let seen = await Task.detached { () -> [Bool] in
            var threads: [Bool] = []
            _ = DiskCleanupModel.performDetailed(items, trash: { _ in threads.append(isOnMainThread()) }, remove: { _ in })
            return threads
        }.value
        XCTAssertEqual(seen, Array(repeating: false, count: 5))
    }

    // MARK: U3 — launchctl

    private let home = "/Users/tester"

    func testServiceDomainsByLocation() {
        XCTAssertEqual(LaunchUnload.domain(for: URL(fileURLWithPath: "\(home)/Library/LaunchAgents/com.x.plist"), uid: 501, home: home), .gui(501))
        XCTAssertEqual(LaunchUnload.domain(for: URL(fileURLWithPath: "/Library/LaunchAgents/com.x.plist"), uid: 501, home: home), .gui(501))
        XCTAssertEqual(LaunchUnload.domain(for: URL(fileURLWithPath: "/Library/LaunchDaemons/com.x.plist"), uid: 501, home: home), .system)
    }

    func testNonServicePathsAreIgnored() {
        for path in ["\(home)/Library/Preferences/com.x.plist", "/Library/LaunchDaemons/helper", "/Library/LaunchDaemons-old/com.x.plist",
                     "/Library/LaunchDaemons/sub/com.x.plist", "/tmp/Library/LaunchAgents/com.x.plist", "/Library/PrivilegedHelperTools/com.x"] {
            XCTAssertNil(LaunchUnload.domain(for: URL(fileURLWithPath: path), uid: 501, home: home), path)
            XCTAssertNil(LaunchUnload.bootoutArguments(for: URL(fileURLWithPath: path), uid: 501, home: home), path)
        }
    }

    func testTraversalCannotChangeTheDomain() {
        let url = URL(fileURLWithPath: "/Library/LaunchAgents/../LaunchDaemons/com.x.plist")
        XCTAssertEqual(LaunchUnload.domain(for: url, uid: 501, home: home), .system, "путь приводится к настоящему перед выбором домена")
        XCTAssertEqual(LaunchUnload.bootoutArguments(for: url, uid: 501, home: home)?.last, "/Library/LaunchDaemons/com.x.plist")
    }

    func testBootoutArguments() {
        let url = URL(fileURLWithPath: "\(home)/Library/LaunchAgents/com.x.plist")
        XCTAssertEqual(LaunchUnload.bootoutArguments(for: url, uid: 501, home: home), ["bootout", "gui/501", url.path])
        let daemon = URL(fileURLWithPath: "/Library/LaunchDaemons/com.x.plist")
        XCTAssertEqual(LaunchUnload.bootoutArguments(for: daemon, uid: 501, home: home), ["bootout", "system", daemon.path])
    }

    func testRootScriptStopsOnlyDaemonsAndQuotes() {
        let urls = [URL(fileURLWithPath: "/Library/LaunchDaemons/com.x.plist"), URL(fileURLWithPath: "/Library/LaunchAgents/com.y.plist"),
                    URL(fileURLWithPath: "/Library/LaunchDaemons/it's.plist")]
        let script = LaunchUnload.rootCommands(for: urls, quote: UninstallerModel.shellQuote)
        XCTAssertTrue(script.contains("/bin/launchctl bootout system '/Library/LaunchDaemons/com.x.plist'"))
        XCTAssertTrue(script.contains(#"'/Library/LaunchDaemons/it'\''s.plist'"#))
        XCTAssertFalse(script.contains("com.y.plist"), "пользовательские агенты в скрипте root не нужны")
        XCTAssertEqual(LaunchUnload.rootCommands(for: [], quote: UninstallerModel.shellQuote), "")
    }

    func testStagingScriptStopsDaemonBeforeMovingAndKeepsExitCodeOfMove() throws {
        let daemon = URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.nothing.plist")
        let script = UninstallerModel.adminStagingScript([daemon], staging: root.appendingPathComponent("s").path, owner: "tester")
        let stop = try XCTUnwrap(script.range(of: "bootout system"))
        let move = try XCTUnwrap(script.range(of: "/bin/mv -n"))
        XCTAssertLessThan(stop.lowerBound, move.lowerBound, "служба останавливается до переноса")
        XCTAssertTrue(script.contains("|| :"), "сбой остановки (служба не загружена) не отменяет перенос")
        let noDaemon = UninstallerModel.adminStagingScript([URL(fileURLWithPath: "/Library/PrivilegedHelperTools/x")], staging: "/tmp/s", owner: "tester")
        XCTAssertFalse(noDaemon.contains("launchctl"))
    }

    private func fakeLaunchctl(exitCode: Int32) throws -> (path: String, log: URL) {
        let log = root.appendingPathComponent("launchctl.log")
        let script = root.appendingPathComponent("fake-launchctl-\(exitCode).sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(UninstallerModel.shellQuote(log.path))\nexit \(exitCode)\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, log)
    }

    func testUserServicesAreStoppedThroughLaunchctl() throws {
        let (path, log) = try fakeLaunchctl(exitCode: 0)
        let agent = URL(fileURLWithPath: "\(home)/Library/LaunchAgents/com.x.plist")
        let systemAgent = URL(fileURLWithPath: "/Library/LaunchAgents/com.y.plist")
        let daemon = URL(fileURLWithPath: "/Library/LaunchDaemons/com.z.plist")
        let other = URL(fileURLWithPath: "\(home)/Library/Caches/x")
        let codes = LaunchUnload.bootoutUserServices([agent, systemAgent, daemon, other], uid: 501, home: home, launchctl: path)
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["bootout gui/501 \(agent.path)", "bootout gui/501 /Library/LaunchAgents/com.y.plist"],
                       "демон (нужен root) и не-службы пропущены")
        XCTAssertEqual(codes[agent], 0)
        XCTAssertNil(codes[daemon])
        XCTAssertNil(codes[other])
    }

    func testFailedStopIsReportedButDoesNotThrow() throws {
        let (path, _) = try fakeLaunchctl(exitCode: 3)
        let agent = URL(fileURLWithPath: "\(home)/Library/LaunchAgents/com.x.plist")
        XCTAssertEqual(LaunchUnload.bootoutUserServices([agent], uid: 501, home: home, launchctl: path)[agent], 3)
        XCTAssertEqual(LaunchUnload.bootoutUserServices([agent], uid: 501, home: home, launchctl: "/нет/такого")[agent], -1)
    }

    // MARK: U2 — ожидание закрытия программы

    func testWaitReturnsAsSoonAsAppIsGone() async {
        var polls = 0, sleeps = 0
        let closed = await LaunchUnload.waitForExit(attempts: 100, isTerminated: { polls += 1; return polls > 3 }, sleep: { sleeps += 1 })
        XCTAssertTrue(closed)
        XCTAssertEqual(sleeps, 3)
    }

    func testWaitGivesUpWithoutKilling() async {
        var sleeps = 0
        let closed = await LaunchUnload.waitForExit(attempts: 5, isTerminated: { false }, sleep: { sleeps += 1 })
        XCTAssertFalse(closed, "не закрылось — решает пользователь, а не принудительное завершение")
        XCTAssertEqual(sleeps, 5)
    }

    func testWaitNoSleepWhenAlreadyClosed() async {
        var sleeps = 0
        let closed = await LaunchUnload.waitForExit(attempts: 5, isTerminated: { true }, sleep: { sleeps += 1 })
        XCTAssertTrue(closed)
        XCTAssertEqual(sleeps, 0)
    }

    func testClosingJustAtTheLastCheckCounts() async {
        var polls = 0
        let closed = await LaunchUnload.waitForExit(attempts: 2, isTerminated: { polls += 1; return polls >= 3 }, sleep: {})
        XCTAssertTrue(closed, "последняя проверка после ожидания тоже учитывается")
    }

    // MARK: rel-4fix

    func testHangingLaunchctlIsTerminatedAfterTimeout() throws {
        let script = root.appendingPathComponent("hang-launchctl.sh")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let agent = URL(fileURLWithPath: "\(home)/Library/LaunchAgents/com.x.plist")
        let started = Date()
        let codes = LaunchUnload.bootoutUserServices([agent], uid: 501, home: home, launchctl: script.path, timeout: 0.4)
        XCTAssertEqual(codes[agent], LaunchUnload.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "не ждём 30 секунд")
    }

    func testFastLaunchctlIsNotAffectedByTimeout() throws {
        let (path, _) = try fakeLaunchctl(exitCode: 0)
        let agent = URL(fileURLWithPath: "\(home)/Library/LaunchAgents/com.x.plist")
        XCTAssertEqual(LaunchUnload.bootoutUserServices([agent], uid: 501, home: home, launchctl: path, timeout: 5)[agent], 0)
    }

    func testDeletionResultAppliesOnlyToTheAppStillSelected() {
        let a = URL(fileURLWithPath: "/Applications/A.app"), b = URL(fileURLWithPath: "/Applications/B.app")
        XCTAssertTrue(UninstallerModel.isStillSelected(a, app: a))
        XCTAssertFalse(UninstallerModel.isStillSelected(b, app: a), "выбрали другую — её список не чистим")
        XCTAssertFalse(UninstallerModel.isStillSelected(nil, app: a))
    }
}
