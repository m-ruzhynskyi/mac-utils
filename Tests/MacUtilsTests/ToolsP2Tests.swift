import XCTest
@testable import MacUtils
@testable import MUAudio

final class ProcessIdentityTests: XCTestCase {
    private func id(_ bundle: String?, _ start: TimeInterval?) -> ProcessIdentity {
        ProcessIdentity(bundleID: bundle, startTime: start)
    }

    func testSameProcessMatches() {
        XCTAssertTrue(ProcessIdentity.isSame(expected: id("com.a", 1000), actual: id("com.a", 1000.4)))
    }

    func testGoneProcessDoesNotMatch() {
        XCTAssertFalse(ProcessIdentity.isSame(expected: id("com.a", 1000), actual: nil))
    }

    func testReusedPIDWithOtherBundleDoesNotMatch() {
        XCTAssertFalse(ProcessIdentity.isSame(expected: id("com.a", 1000), actual: id("com.b", 1000)))
        XCTAssertFalse(ProcessIdentity.isSame(expected: id("com.a", 1000), actual: id(nil, 1000)))
    }

    func testReusedPIDWithLaterStartDoesNotMatch() {
        XCTAssertFalse(ProcessIdentity.isSame(expected: id(nil, 1000), actual: id(nil, 5000)))
    }

    func testUnknownStartTimeFallsBackToBundle() {
        XCTAssertTrue(ProcessIdentity.isSame(expected: id("com.a", nil), actual: id("com.a", 77)))
    }

    @MainActor
    func testQuitRefusesRowWithForeignIdentity() throws {
        let model = TaskManagerModel.shared
        // Собственный безобидный процесс: при сломанной проверке отпечатка убьётся он, а не раннер тестов.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        let pid = sleeper.processIdentifier
        let row = ProcessRow(pid: pid, name: "sleep", isApp: false, user: "", cpu: 0, memory: 0,
                             identity: ProcessIdentity(bundleID: "com.example.never", startTime: 1))
        model.quit(row, force: true)
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(kill(pid, 0), 0, "процесс с чужим отпечатком должен остаться жив")
    }

    @MainActor
    func testIdentityAvailableForSystemProcess() throws {
        let launchd = try XCTUnwrap(TaskManagerModel.identity(of: 1, app: nil), "launchd (root) должен иметь отпечаток")
        XCTAssertNotNil(launchd.startTime)
        XCTAssertNil(TaskManagerModel.identity(of: 999_999, app: nil))
    }

    @MainActor
    func testOwnProcessIdentityMatchesItself() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = TaskManagerModel.identity(of: pid, app: nil)
        XCTAssertTrue(ProcessIdentity.isSame(expected: try XCTUnwrap(first), actual: TaskManagerModel.identity(of: pid, app: nil)))
    }

    @MainActor
    func testQuitSystemProcessReportsNoRightsNotStalePID() throws {
        guard geteuid() != 0 else { throw XCTSkip("под root завершение сработало бы") }
        let model = TaskManagerModel.shared
        model.sample()
        // Процесс другого пользователя: kill(pid, 0) отвечает EPERM.
        let target = model.rows.first { $0.pid > 1 && kill($0.pid, 0) == -1 && errno == EPERM }
        let row = try XCTUnwrap(target, "нужен хотя бы один чужой процесс")
        XCTAssertNotNil(row.identity.startTime)
        model.quit(row, force: false)
        let message = try XCTUnwrap(model.lastError)
        XCTAssertTrue(message.hasPrefix("Нет прав"), message)
    }
}

final class ToolsP2Tests: XCTestCase {
    func testOptionClickOpensWindow() {
        XCTAssertTrue(AppStatusItem.opensWindow(modifiers: [.option]))
        XCTAssertTrue(AppStatusItem.opensWindow(modifiers: [.option, .shift]))
        XCTAssertFalse(AppStatusItem.opensWindow(modifiers: []))
        XCTAssertFalse(AppStatusItem.opensWindow(modifiers: [.command]))
    }

    func testDownloadsUseAddedDateWhenModifiedIsOld() {
        let downloads = CleanupCategory.all().first { $0.kind == .downloads }!
        let now = Date()
        let old = now.addingTimeInterval(-90 * 86_400)
        let yesterday = now.addingTimeInterval(-86_400)
        XCTAssertFalse(downloads.includes(name: "a.zip", modified: old, added: yesterday, now: now))
        XCTAssertTrue(downloads.includes(name: "a.zip", modified: old, added: old, now: now))
        XCTAssertTrue(downloads.includes(name: "a.zip", modified: old, added: nil, now: now))
        XCTAssertFalse(downloads.includes(name: "a.zip", modified: nil, added: nil, now: now))
    }

    func testAccessDeniedDetection() {
        XCTAssertTrue(CleanupCategory.isAccessDenied(CocoaError(.fileReadNoPermission)))
        XCTAssertTrue(CleanupCategory.isAccessDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertFalse(CleanupCategory.isAccessDenied(CocoaError(.fileReadNoSuchFile)))
    }

    func testResultTextIsHonestAboutTrash() {
        let text = DiskCleanupModel.resultText(.init(trashed: 5_000_000, deleted: 0, failed: 0))
        XCTAssertTrue(text.hasPrefix("Перенесено в Корзину"))
        XCTAssertFalse(text.contains("Освобождено"))
        let mixed = DiskCleanupModel.resultText(.init(trashed: 1, deleted: 2_000_000, failed: 1))
        XCTAssertTrue(mixed.contains("Удалено насовсем"))
        XCTAssertTrue(mixed.contains("Не удалось: 1"))
    }

    func testCleanupRunsOffMainThread() {
        let item = CleanupItem(url: URL(fileURLWithPath: "/x"), category: .caches, size: 1)
        let done = expectation(description: "done")
        Task.detached {
            let outcome = DiskCleanupModel.performDetailed([item], trash: { _ in
                XCTAssertFalse(Thread.isMainThread)
            })
            XCTAssertEqual(outcome.trashed, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
