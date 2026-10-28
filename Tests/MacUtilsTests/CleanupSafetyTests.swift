import XCTest
@testable import MacUtils
@testable import MUUninstaller
@testable import MUAudio
@testable import MUTextEditor

/// Экранирование для sh/AppleScript в удалении с правами администратора, DiskCleanup и имена в Корзине.
/// Всё работает во временной папке: настоящие Корзина, home и UserDefaults не затрагиваются.
@MainActor
final class CleanupSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CleanupSafetyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let nasty = [
        "plain", "with space", "it's", "''", "a\"b", "back\\slash", "$HOME", "$(touch /tmp/pwn)", "`id`",
        "semi;colon && amp | pipe", "line1\nline2", "tab\there", "юникод Приложение ✓ 日本語", "*?[glob]", "-rf", "~", "!bang", "",
    ]

    private func runShell(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, script)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: shellQuote

    func testShellQuoteRoundTripsThroughRealShell() throws {
        for value in Self.nasty {
            let out = try runShell("printf %s \(UninstallerModel.shellQuote(value))")
            XCTAssertEqual(out, value, "shellQuote испортил \(value.debugDescription)")
        }
    }

    func testShellQuoteDoesNotExecuteInjection() throws {
        let marker = root.appendingPathComponent("pwned").path
        _ = try runShell("printf %s \(UninstallerModel.shellQuote("x'; touch '\(marker)'; echo '"))")
        _ = try runShell("printf %s \(UninstallerModel.shellQuote("$(touch '\(marker)')`touch '\(marker)'`"))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testShellQuoteShape() {
        XCTAssertEqual(UninstallerModel.shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(UninstallerModel.shellQuote(""), "''")
    }

    // MARK: appleScriptQuote

    func testAppleScriptQuoteEscapesQuotesAndBackslashes() {
        XCTAssertEqual(UninstallerModel.appleScriptQuote(#"a"b"#), #""a\"b""#)
        XCTAssertEqual(UninstallerModel.appleScriptQuote(#"a\b"#), #""a\\b""#)
        XCTAssertEqual(UninstallerModel.appleScriptQuote(#"\""#), #""\\\"""#)
    }

    func testAppleScriptQuoteRoundTripsThroughAppleScript() throws {
        for value in Self.nasty where !value.contains("\n") {
            var error: NSDictionary?
            let result = NSAppleScript(source: "return \(UninstallerModel.appleScriptQuote(value))")?
                .executeAndReturnError(&error)
            XCTAssertNil(error, "\(value.debugDescription): \(String(describing: error))")
            XCTAssertEqual(result?.stringValue, value, "appleScriptQuote испортил \(value.debugDescription)")
        }
    }

    func testAdminCommandSurvivesBothQuotingLayers() throws {
        // Тот же путь, что у «do shell script … with administrator privileges», но без прав и без Корзины.
        let dir = root.appendingPathComponent("it's \"a\" $HOME `x`\nдир")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("file's.txt")
        try "data".write(to: source, atomically: true, encoding: .utf8)
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let commands = UninstallerModel.adminTrashCommands([source], trash: trash.path, stamp: 42)
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \(UninstallerModel.appleScriptQuote(commands))")?.executeAndReturnError(&error)
        XCTAssertNil(error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("file's.txt 42").path))
    }

    // MARK: M4 — имена в Корзине

    func testAdminTrashTargetsAreUniqueForSameFileName() {
        // M4: /Library/LaunchAgents/x.plist и /Library/LaunchDaemons/x.plist при одном stamp дают один путь,
        // и `mv -f` затирает первый файл. Пока Разработчик/Ревьюер не поправят — тест красный.
        let urls = [URL(fileURLWithPath: "/Library/LaunchAgents/com.x.plist"),
                    URL(fileURLWithPath: "/Library/LaunchDaemons/com.x.plist")]
        let commands = UninstallerModel.adminTrashCommands(urls, trash: "/Users/u/.Trash", stamp: 1)
        let targets = commands.components(separatedBy: " && ").compactMap { $0.components(separatedBy: "' '").last }
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(Set(targets).count, 2, "оба файла переносятся в один и тот же путь: \(targets)")
    }

    func testAdminTrashCommandsUseNoClobberOrUniqueTargets() {
        let urls = [URL(fileURLWithPath: "/Library/LaunchAgents/a.plist")]
        let command = UninstallerModel.adminTrashCommands(urls, trash: "/t", stamp: 1)
        XCTAssertTrue(command.contains("mv -n") || !command.contains("mv -f"),
                      "mv -f перезаписывает существующий файл в Корзине: \(command)")
    }

    // MARK: Перенос от root: сбой должен быть виден (S1)

    /// Прогоняет команду через /bin/sh и возвращает код выхода (без root: владелец — текущий пользователь).
    private func exitStatus(_ script: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeSource(_ name: String, in folder: URL? = nil, text: String = "data") throws -> URL {
        let dir = folder ?? root.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeTrash() throws -> URL {
        let trash = root.appendingPathComponent("trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return trash
    }

    func testMoveSucceedsAndOwnerIsSet() throws {
        let source = try makeSource("com.x.plist"), trash = try makeTrash()
        let command = UninstallerModel.adminTrashCommands([source], trash: trash.path, stamp: 7, owner: NSUserName())
        XCTAssertEqual(try exitStatus(command), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let moved = trash.appendingPathComponent("com.x.plist 7")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "data")
        let owner = try FileManager.default.attributesOfItem(atPath: moved.path)[.ownerAccountName] as? String
        XCTAssertEqual(owner, NSUserName())
    }

    func testExistingTargetMakesCommandFailAndLeavesSourceInPlace() throws {
        let source = try makeSource("com.x.plist", text: "system"), trash = try makeTrash()
        let target = trash.appendingPathComponent("com.x.plist 7")
        try "чужое".write(to: target, atomically: true, encoding: .utf8)
        let command = UninstallerModel.adminTrashCommands([source], trash: trash.path, stamp: 7, owner: NSUserName())
        XCTAssertNotEqual(try exitStatus(command), 0, "`mv -n` сам вернул бы 0 — об успехе сообщать нельзя")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "system", "исходник на месте")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "чужое", "чужой файл не тронут")
    }

    func testSymlinkPlantedAtTargetIsNotFollowed() throws {
        let source = try makeSource("com.x.plist"), trash = try makeTrash()
        let elsewhere = root.appendingPathComponent("attacker-dir")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: trash.appendingPathComponent("com.x.plist 7"), withDestinationURL: elsewhere)
        let command = UninstallerModel.adminTrashCommands([source], trash: trash.path, stamp: 7, owner: NSUserName())
        XCTAssertNotEqual(try exitStatus(command), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty, "в каталог атакующего ничего не попало")
    }

    func testDanglingSymlinkAtTargetAlsoFails() throws {
        let source = try makeSource("a.plist"), trash = try makeTrash()
        try FileManager.default.createSymbolicLink(at: trash.appendingPathComponent("a.plist 1"),
                                                   withDestinationURL: root.appendingPathComponent("нет-такого"))
        let command = UninstallerModel.adminTrashCommands([source], trash: trash.path, stamp: 1, owner: NSUserName())
        XCTAssertNotEqual(try exitStatus(command), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testSourceThatCannotBeRemovedMakesCommandFail() throws {
        // mv не может убрать файл из каталога без права записи; код выхода mv игнорируется (`;`), поэтому
        // важна именно проверка «исходник исчез».
        let dir = root.appendingPathComponent("locked-src")
        let source = try makeSource("keep.plist", in: dir), trash = try makeTrash()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let command = UninstallerModel.adminTrashCommands([source], trash: trash.path, stamp: 1, owner: NSUserName())
        XCTAssertNotEqual(try exitStatus(command), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testFirstFailureStopsTheChainSoLaterFilesAreNotMoved() throws {
        let first = try makeSource("one.plist"), second = try makeSource("two.plist"), trash = try makeTrash()
        try "чужое".write(to: trash.appendingPathComponent("one.plist 1"), atomically: true, encoding: .utf8)
        let command = UninstallerModel.adminTrashCommands([first, second], trash: trash.path, stamp: 1, owner: NSUserName())
        XCTAssertNotEqual(try exitStatus(command), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "после сбоя остальные файлы не трогаем")
    }

    func testSameNamedSourcesGoToDifferentTargetsAndBothMove() throws {
        for stamp in [Optional(5), nil] {
            let t = try makeTrash()
            let aa = try makeSource("com.x.plist", text: "A"), bb = try makeSource("com.x.plist", text: "B")
            let command = UninstallerModel.adminTrashCommands([aa, bb], trash: t.path, stamp: stamp, owner: NSUserName())
            XCTAssertEqual(try exitStatus(command), 0, "stamp=\(String(describing: stamp))")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: t.path).count, 2)
        }
    }

    func testPathsWithQuotesAndCyrillicSurviveTheMove() throws {
        let dir = root.appendingPathComponent("it's \"x\" $HOME дир")
        let source = try makeSource("файл 'с' кавычками.plist", in: dir), trash = try makeTrash()
        let command = UninstallerModel.adminTrashCommands([source], trash: trash.path, stamp: 3, owner: NSUserName())
        XCTAssertEqual(try exitStatus(command), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("файл 'с' кавычками.plist 3").path))
    }

    // MARK: adminStagingScript

    func testStagingScriptCreatesPrivateDirectoryAndMoves() throws {
        let source = try makeSource("a.plist"), staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        let script = UninstallerModel.adminStagingScript([source], staging: staging.path, owner: NSUserName())
        XCTAssertEqual(try exitStatus(script), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("a.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let mode = try FileManager.default.attributesOfItem(atPath: staging.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o700)
    }

    func testStagingScriptFailsIfStagingAlreadyExists() throws {
        let source = try makeSource("a.plist"), staging = try makeTrash()
        XCTAssertNotEqual(try exitStatus(UninstallerModel.adminStagingScript([source], staging: staging.path, owner: NSUserName())), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "ничего не перенесено")
    }

    func testStagingScriptFailsIfStagingIsAPlantedSymlink() throws {
        let source = try makeSource("a.plist")
        let attacker = root.appendingPathComponent("attacker-dir")
        try FileManager.default.createDirectory(at: attacker, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("staging-link")
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: attacker)
        XCTAssertNotEqual(try exitStatus(UninstallerModel.adminStagingScript([source], staging: staging.path, owner: NSUserName())), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: attacker.path).isEmpty)
    }

    func testStagingScriptPropagatesMoveFailure() throws {
        let source = try makeSource("a.plist"), staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        // Цель внутри staging уже не может существовать, поэтому ломаем иначе: исходник — тот же путь дважды.
        let script = UninstallerModel.adminStagingScript([source, source], staging: staging.path, owner: NSUserName())
        XCTAssertNotEqual(try exitStatus(script), 0, "второй mv не находит файл — сбой должен быть виден")
    }

    func testStagingScriptStillHandsDirectoryToUserAfterPartialFailure() throws {
        // Второй исходник — тот же путь, что и первый: mv -n не находит файл, цепочка обрывается.
        let source = try makeSource("a.plist"), staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        let chownLog = root.appendingPathComponent("chown.log")
        // Подставной chown пишет свои аргументы в журнал вместо настоящей смены владельца.
        let fake = root.appendingPathComponent("fake-chown.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(UninstallerModel.shellQuote(chownLog.path))\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let script = UninstallerModel.adminStagingScript([source, source], staging: staging.path, owner: "tester")
            .replacingOccurrences(of: "/usr/sbin/chown", with: UninstallerModel.shellQuote(fake.path))
        XCTAssertNotEqual(try exitStatus(script), 0, "сбой переноса должен быть виден")
        let lines = ((try? String(contentsOf: chownLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        // Содержимое отдаётся пользователю по каталогам при переносе; в конце — сам staging (без -R: см. plan-p2-uninst N1).
        XCTAssertTrue(lines.contains("-h tester \(staging.path)"),
                      "итоговый chown каталога staging не выполнен после сбоя: \(lines)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("a.plist").path),
                      "первый файл уже перенесён")
    }

    func testFinishStagingFailsWhenDirectoryIsUnreadable() throws {
        try XCTSkipIf(getuid() == 0, "root читает любой каталог")
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "x".write(to: staging.appendingPathComponent("a.plist"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: staging.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path) }
        XCTAssertFalse(UninstallerModel.finishStaging(staging), "нечитаемый каталог — это неудача, а не успех")
    }

    func testFinishStagingIsTrueWhenDirectoryIsMissing() {
        XCTAssertTrue(UninstallerModel.finishStaging(root.appendingPathComponent("нет-такого")))
    }

    // MARK: DiskCleanup

    private func makeFile(_ name: String, in folder: URL, bytes: Int) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    func testPerformMovesToTrashFolderAndDeletesTrashCategoryForGood() throws {
        let cache = try makeFile("cache.bin", in: root.appendingPathComponent("Caches"), bytes: 100)
        let junk = try makeFile("junk.bin", in: root.appendingPathComponent("Trash"), bytes: 50)
        let fakeTrash = root.appendingPathComponent("FakeTrash")
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        var trashed: [URL] = [], removed: [URL] = []
        let result = DiskCleanupModel.perform(
            [CleanupItem(url: cache, category: .caches, size: 100), CleanupItem(url: junk, category: .trash, size: 50)],
            trash: { url in
                trashed.append(url)
                try FileManager.default.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent))
            },
            remove: { url in removed.append(url); try FileManager.default.removeItem(at: url) })
        XCTAssertEqual(result.freed, 150)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(trashed, [cache])
        XCTAssertEqual(removed, [junk])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fakeTrash.appendingPathComponent("cache.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: junk.path))
    }

    func testPerformCountsFailuresAndContinues() throws {
        let a = try makeFile("a.bin", in: root.appendingPathComponent("Logs"), bytes: 10)
        let b = try makeFile("b.bin", in: root.appendingPathComponent("Logs"), bytes: 20)
        struct Denied: Error {}
        let result = DiskCleanupModel.perform(
            [CleanupItem(url: a, category: .logs, size: 10), CleanupItem(url: b, category: .logs, size: 20)],
            trash: { url in if url == a { throw Denied() } },
            remove: { _ in })
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.freed, 20, "освобождённое считается только по успешным")
    }

    func testPerformNeverTouchesFilesOutsideGivenItems() throws {
        let keep = try makeFile("keep.bin", in: root.appendingPathComponent("Caches"), bytes: 10)
        let drop = try makeFile("drop.bin", in: root.appendingPathComponent("Caches"), bytes: 10)
        _ = DiskCleanupModel.perform([CleanupItem(url: drop, category: .caches, size: 10)],
                                     trash: { try FileManager.default.removeItem(at: $0) }, remove: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drop.path))
    }

    func testSymlinkInTrashCategoryDoesNotDeleteTarget() throws {
        let target = try makeFile("precious.bin", in: root.appendingPathComponent("Data"), bytes: 10)
        let folder = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = DiskCleanupModel.perform([CleanupItem(url: link, category: .trash, size: 1)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "removeItem не должен идти по symlink")
    }

    func testCategoriesAreInsideGivenHome() {
        let home = URL(fileURLWithPath: "/tmp/fake-home")
        for category in CleanupCategory.all(home: home) {
            for folder in category.folders {
                XCTAssertTrue(folder.path.hasPrefix(home.path + "/"), "\(folder.path) вне home")
            }
        }
    }
}
