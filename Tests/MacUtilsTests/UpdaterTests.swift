import XCTest
@testable import MacUtils

@MainActor
final class UpdaterTests: XCTestCase {
    func testNewerVersions() {
        XCTAssertTrue(Updater.isVersion("1.2.31", newerThan: "1.2.30"))
        XCTAssertTrue(Updater.isVersion("1.3.0", newerThan: "1.2.99"))
        XCTAssertTrue(Updater.isVersion("1.2.10", newerThan: "1.2.9"))
        XCTAssertTrue(Updater.isVersion("1.2.1", newerThan: "1.2"))
    }

    func testNotNewer() {
        XCTAssertFalse(Updater.isVersion("1.2.30", newerThan: "1.2.30"))
        XCTAssertFalse(Updater.isVersion("1.2.9", newerThan: "1.2.10"))
        XCTAssertFalse(Updater.isVersion("1.2", newerThan: "1.2.0"))
    }
}

// MARK: - parseRelease

@MainActor
final class UpdaterParseReleaseTests: XCTestCase {
    private func release(tag: String, draft: Bool = false, prerelease: Bool = false, assets: [String] = ["MacUtils.zip"]) -> [String: Any] {
        ["tag_name": tag, "draft": draft, "prerelease": prerelease,
         "assets": assets.map { ["name": $0, "browser_download_url": "https://github.com/o/r/releases/download/\(tag)/\($0)"] }]
    }

    private func parse(_ releases: [[String: Any]]) throws -> Updater.ReleaseInfo {
        try Updater.parseRelease(JSONSerialization.data(withJSONObject: releases))
    }

    func testValidReleaseGivesVersionWithoutVAndZipURL() throws {
        let info = try parse([release(tag: "v1.4.120")])
        XCTAssertEqual(info.version, "1.4.120")
        XCTAssertEqual(info.zipURL.absoluteString, "https://github.com/o/r/releases/download/v1.4.120/MacUtils.zip")
    }

    func testMissingMacUtilsZipAssetIsRejected() {
        XCTAssertThrowsError(try parse([release(tag: "v1.4.1", assets: ["MacUtils.dmg", "notes.txt"])]))
        XCTAssertThrowsError(try parse([release(tag: "v1.4.1", assets: [])]))
        XCTAssertThrowsError(try parse([release(tag: "v1.4.1", assets: ["macutils.zip"])]), "имя ассета чувствительно к регистру")
    }

    func testWindowsReleasesAreSkippedAndMacReleaseBehindThemIsFound() throws {
        let info = try parse([release(tag: "windows-latest", assets: ["MacUtilsShare-Setup.exe", "MacUtils.zip"]),
                              release(tag: "windows-v2.0.0", assets: ["MacUtils.zip"]),
                              release(tag: "v1.3.9")])
        XCTAssertEqual(info.version, "1.3.9")
    }

    func testOnlyWindowsReleasesMeansNotFound() {
        XCTAssertThrowsError(try parse([release(tag: "windows-latest", assets: ["MacUtilsShare-Setup.exe"])]))
    }

    func testDraftsAndPrereleasesAreSkipped() throws {
        let info = try parse([release(tag: "v9.9.9", draft: true), release(tag: "v9.9.8", prerelease: true), release(tag: "v1.0.1")])
        XCTAssertEqual(info.version, "1.0.1")
    }

    func testFirstSuitableReleaseWins() throws {
        XCTAssertEqual(try parse([release(tag: "v1.5.0"), release(tag: "v1.4.0")]).version, "1.5.0")
    }

    func testEmptyListAndBrokenJSONThrow() {
        XCTAssertThrowsError(try Updater.parseRelease(Data("[]".utf8)))
        XCTAssertThrowsError(try Updater.parseRelease(Data("не json".utf8)))
        XCTAssertThrowsError(try Updater.parseRelease(Data("{\"message\":\"Not Found\"}".utf8)))
        XCTAssertThrowsError(try Updater.parseRelease(Data("[{\"tag_name\":\"v1\"}]".utf8)), "нет обязательных полей")
        XCTAssertThrowsError(try Updater.parseRelease(Data()))
    }

    func testNoDowngrade() throws {
        let latest = try parse([release(tag: "v1.4.100")]).version
        XCTAssertFalse(Updater.isVersion(latest, newerThan: "1.4.101"))
        XCTAssertFalse(Updater.isVersion(latest, newerThan: "1.5.0"))
        XCTAssertFalse(Updater.isVersion(latest, newerThan: "1.4.100"))
        XCTAssertTrue(Updater.isVersion(latest, newerThan: "1.4.99"))
    }
}

// MARK: - installScript

final class UpdaterInstallScriptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdaterInstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var fm: FileManager { .default }

    private func makeApp(_ url: URL, marker: String) throws {
        try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try marker.write(to: url.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
    }

    private func marker(_ url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }

    /// Запускает настоящий скрипт, но `open` заменён на `true`: тест не должен запускать приложения.
    /// pid несуществующий, поэтому ожидание выхода процесса завершается сразу.
    @discardableResult
    private func runScript(target: URL, staged: URL, work: URL, pid: Int32 = 2_000_000) throws -> Int32 {
        let script = Updater.installScript(pid: pid, target: target, staged: staged, work: work)
        XCTAssertTrue(script.contains("/usr/bin/open"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script.replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/true")]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testSuccessfulReplacementRemovesOldAndWorkDirectory() throws {
        let target = root.appendingPathComponent("Mac Utils.app"), work = root.appendingPathComponent("work")
        let staged = work.appendingPathComponent("Mac Utils.app.new")
        try makeApp(target, marker: "old"); try makeApp(staged, marker: "new")
        try runScript(target: target, staged: staged, work: work)
        XCTAssertEqual(marker(target), "new")
        XCTAssertFalse(fm.fileExists(atPath: target.path + ".old"), ".old должен быть удалён")
        XCTAssertFalse(fm.fileExists(atPath: staged.path))
        XCTAssertFalse(fm.fileExists(atPath: work.path), "рабочая папка чистится")
    }

    func testMissingStagedRestoresOriginal() throws {
        let target = root.appendingPathComponent("Mac Utils.app"), work = root.appendingPathComponent("work")
        try makeApp(target, marker: "old")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try runScript(target: target, staged: work.appendingPathComponent("нет-такого.app"), work: work)
        XCTAssertEqual(marker(target), "old", "после сбоя второго mv оригинал на месте")
        XCTAssertFalse(fm.fileExists(atPath: target.path + ".old"))
    }

    func testSecondMoveFailureWithBlockedDestinationRestoresOriginal() throws {
        // staged существует, но лежит в закрытой папке: второй mv падает не из-за отсутствия файла.
        let target = root.appendingPathComponent("Mac Utils.app"), work = root.appendingPathComponent("work")
        let staged = work.appendingPathComponent("locked/App.new")
        try makeApp(target, marker: "old"); try makeApp(staged, marker: "new")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: work.appendingPathComponent("locked").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.appendingPathComponent("locked").path) }
        try runScript(target: target, staged: staged, work: work)
        XCTAssertEqual(marker(target), "old")
        XCTAssertFalse(fm.fileExists(atPath: target.path + ".old"))
    }

    func testStaleOldFromEarlierAttemptIsReplaced() throws {
        let target = root.appendingPathComponent("A.app"), work = root.appendingPathComponent("work")
        let staged = work.appendingPathComponent("A.app.new")
        try makeApp(target, marker: "old"); try makeApp(staged, marker: "new")
        try makeApp(URL(fileURLWithPath: target.path + ".old"), marker: "stale")
        try runScript(target: target, staged: staged, work: work)
        XCTAssertEqual(marker(target), "new")
        XCTAssertFalse(fm.fileExists(atPath: target.path + ".old"))
    }

    func testPathsWithSpacesQuotesAndCyrillic() throws {
        let dir = root.appendingPathComponent("Мои программы 'тест' \"кавычки\" $HOME `id`")
        let target = dir.appendingPathComponent("Mac Utils — it's.app"), work = dir.appendingPathComponent("раб папка")
        let staged = work.appendingPathComponent("Mac Utils — it's.app.new")
        try makeApp(target, marker: "old"); try makeApp(staged, marker: "new")
        try runScript(target: target, staged: staged, work: work)
        XCTAssertEqual(marker(target), "new")
        XCTAssertFalse(fm.fileExists(atPath: target.path + ".old"))
        XCTAssertFalse(fm.fileExists(atPath: work.path))
    }

    func testInjectionInPathIsNotExecuted() throws {
        let pwned = root.appendingPathComponent("pwned").path
        let target = root.appendingPathComponent("x'; touch '\(pwned)'; echo '.app"), work = root.appendingPathComponent("work")
        let staged = work.appendingPathComponent("s.app")
        try makeApp(target, marker: "old"); try makeApp(staged, marker: "new")
        try runScript(target: target, staged: staged, work: work)
        XCTAssertFalse(fm.fileExists(atPath: pwned))
        XCTAssertEqual(marker(target), "new")
    }

    func testScriptWaitsForRunningProcessToExit() throws {
        let target = root.appendingPathComponent("W.app"), work = root.appendingPathComponent("work")
        let staged = work.appendingPathComponent("W.app.new")
        try makeApp(target, marker: "old"); try makeApp(staged, marker: "new")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["1.5"]
        try sleeper.run()
        let started = Date()
        try runScript(target: target, staged: staged, work: work, pid: sleeper.processIdentifier)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.0, "скрипт должен дождаться завершения процесса")
        XCTAssertEqual(marker(target), "new")
        sleeper.waitUntilExit()
    }

    func testScriptGivesUpWaitingForLiveProcessAndLeavesAppUntouched() throws {
        let target = root.appendingPathComponent("G.app"), work = root.appendingPathComponent("work")
        let staged = work.appendingPathComponent("G.app.new")
        try makeApp(target, marker: "old"); try makeApp(staged, marker: "new")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        let script = Updater.installScript(pid: sleeper.processIdentifier, target: target, staged: staged, work: work, waitSeconds: 1)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script.replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/true")]
        let started = Date()
        try process.run(); process.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "скрипт не должен ждать вечно")
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(marker(target), "old", "приложение не тронуто")
        XCTAssertFalse(fm.fileExists(atPath: staged.path), "staged убран")
        XCTAssertFalse(fm.fileExists(atPath: target.path + ".old"))
    }

    func testQuote() {
        XCTAssertEqual(Updater.quote("a b"), "'a b'")
        XCTAssertEqual(Updater.quote("it's"), #"'it'\''s'"#)
    }
}

// MARK: - run(timeout:)

final class UpdaterRunTests: XCTestCase {
    func testTimeoutKillsSlowToolQuickly() {
        let started = Date()
        XCTAssertThrowsError(try Updater.run("/bin/sleep", ["5"], timeout: 1)) { error in
            XCTAssertTrue((error as? UpdateError)?.message.contains("не ответил") == true, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "таймаут 1 с, а не 5 с работы sleep")
    }

    func testSuccessAndFailureStatuses() {
        XCTAssertNoThrow(try Updater.run("/usr/bin/true", []))
        XCTAssertThrowsError(try Updater.run("/usr/bin/false", [])) { error in
            XCTAssertTrue((error as? UpdateError)?.message.contains("ошибкой 1") == true, "\(error)")
        }
        XCTAssertThrowsError(try Updater.run("/nonexistent/tool", []))
    }
}

// MARK: - verifySignature

final class UpdaterVerifySignatureTests: XCTestCase {
    private var root: URL!
    private var keychain: URL!
    private let keychainPassword = "pw"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdaterSig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let keychain { _ = try? sh("/usr/bin/security", ["delete-keychain", keychain.path]) }
        try? FileManager.default.removeItem(at: root)
    }

    /// Локально недоступная подпись — пропуск теста; в CI (GitHub ставит CI=true) — провал, иначе все проверки H4
    /// молча пропустятся при сломанном `security`/`codesign` на раннере, а job останется зелёным.
    private func setupUnavailable(_ message: String) -> Error {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            XCTFail("Тест подписи нельзя выполнить в CI: \(message)")
            return SignatureSetupError(message: message)
        }
        return XCTSkip(message)
    }

    @discardableResult
    private func sh(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Минимальный .app: копия системного бинарника + Info.plist с общим bundle id.
    private func makeApp(_ name: String, binary: String = "/usr/bin/true") throws -> URL {
        let app = root.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: binary, toPath: macOS.appendingPathComponent("Tool").path)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.test.updater", "CFBundleExecutable": "Tool",
                                    "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    private func sign(_ app: URL, identity: String = "-") throws {
        var args = ["--force", "--sign", identity]
        if identity != "-" { args += ["--keychain", keychain.path] }
        let result = try sh("/usr/bin/codesign", args + [app.path])
        guard result.status == 0 else { throw setupUnavailable("codesign не смог подписать: \(result.output)") }
    }

    /// Самоподписанный сертификат во временной связке ключей (в связку пользователя ничего не попадает).
    private func makeIdentity(_ name: String) throws {
        if keychain == nil {
            keychain = root.appendingPathComponent("test.keychain-db")
            guard try sh("/usr/bin/security", ["create-keychain", "-p", keychainPassword, keychain.path]).status == 0,
                  try sh("/usr/bin/security", ["unlock-keychain", "-p", keychainPassword, keychain.path]).status == 0 else {
                throw setupUnavailable("не удалось создать временную связку ключей")
            }
        }
        let cnf = root.appendingPathComponent("\(name).cnf")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = \(name)
        [ext]
        basicConstraints = critical, CA:false
        keyUsage = critical, digitalSignature
        extendedKeyUsage = critical, codeSigning
        """.write(to: cnf, atomically: true, encoding: .utf8)
        let key = root.appendingPathComponent("\(name).key"), cert = root.appendingPathComponent("\(name).pem")
        let p12 = root.appendingPathComponent("\(name).p12")
        let steps: [[String]] = [
            ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-keyout", key.path, "-out", cert.path, "-config", cnf.path],
            ["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-name", name, "-out", p12.path, "-passout", "pass:\(keychainPassword)"],
        ]
        for step in steps where try sh("/usr/bin/openssl", step).status != 0 { throw setupUnavailable("openssl не создал сертификат") }
        guard try sh("/usr/bin/security", ["import", p12.path, "-k", keychain.path, "-P", keychainPassword, "-T", "/usr/bin/codesign"]).status == 0 else {
            throw setupUnavailable("не удалось импортировать сертификат во временную связку")
        }
        _ = try sh("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychainPassword, keychain.path])
    }

    // --- без сертификата: ad-hoc ---

    func testAdHocCurrentBuildRefusesAnyUpdate() throws {
        let current = try makeApp("Current"), update = try makeApp("Update", binary: "/bin/echo")
        try sign(current); try sign(update)
        XCTAssertThrowsError(try Updater.verifySignature(of: update, matchingBundleAt: current)) { error in
            XCTAssertTrue((error as? UpdateError)?.message.contains("ad-hoc") == true, "\(error)")
        }
    }

    func testAdHocCurrentRefusesEvenIdenticalBuild() throws {
        let current = try makeApp("Current"), same = try makeApp("Same")
        try sign(current); try sign(same)
        XCTAssertThrowsError(try Updater.verifySignature(of: same, matchingBundleAt: current),
                             "для ad-hoc издателя проверить нельзя, поэтому отказ даже для той же сборки")
    }

    func testUnsignedCurrentBuildThrows() throws {
        let current = try makeApp("Current"), update = try makeApp("Update")
        try sign(update)
        XCTAssertThrowsError(try Updater.verifySignature(of: update, matchingBundleAt: current))
    }

    // --- с временным самоподписанным сертификатом ---

    func testSameCertificateIsAcceptedEvenWithDifferentContent() throws {
        try makeIdentity("MU Test A")
        let current = try makeApp("Current"), update = try makeApp("Update", binary: "/bin/echo")
        try sign(current, identity: "MU Test A"); try sign(update, identity: "MU Test A")
        XCTAssertNoThrow(try Updater.verifySignature(of: update, matchingBundleAt: current))
    }

    func testOtherCertificateIsRejected() throws {
        try makeIdentity("MU Test A"); try makeIdentity("MU Test B")
        let current = try makeApp("Current"), update = try makeApp("Update")
        try sign(current, identity: "MU Test A"); try sign(update, identity: "MU Test B")
        XCTAssertThrowsError(try Updater.verifySignature(of: update, matchingBundleAt: current)) { error in
            XCTAssertTrue((error as? UpdateError)?.message.contains("другим издателем") == true, "\(error)")
        }
    }

    func testAdHocUpdateIsRejectedWhenCurrentIsCertSigned() throws {
        try makeIdentity("MU Test A")
        let current = try makeApp("Current"), update = try makeApp("Update", binary: "/bin/echo")
        try sign(current, identity: "MU Test A"); try sign(update)
        XCTAssertThrowsError(try Updater.verifySignature(of: update, matchingBundleAt: current))
    }

    func testUnsignedUpdateIsRejected() throws {
        try makeIdentity("MU Test A")
        let current = try makeApp("Current"), update = try makeApp("Update")
        try sign(current, identity: "MU Test A")
        XCTAssertThrowsError(try Updater.verifySignature(of: update, matchingBundleAt: current))
    }

    func testTamperedAfterSigningIsRejected() throws {
        try makeIdentity("MU Test A")
        let current = try makeApp("Current"), update = try makeApp("Update")
        try sign(current, identity: "MU Test A"); try sign(update, identity: "MU Test A")
        let binary = update.appendingPathComponent("Contents/MacOS/Tool")
        let handle = try FileHandle(forWritingTo: binary)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0, 1, 2, 3])); try handle.close()
        XCTAssertThrowsError(try Updater.verifySignature(of: update, matchingBundleAt: current))
    }

    func testResourceAddedAfterSigningIsRejected() throws {
        try makeIdentity("MU Test A")
        let current = try makeApp("Current"), update = try makeApp("Update")
        try sign(current, identity: "MU Test A"); try sign(update, identity: "MU Test A")
        let resources = update.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: resources.appendingPathComponent("extra.txt"))
        XCTAssertThrowsError(try Updater.verifySignature(of: update, matchingBundleAt: current))
    }

    func testMissingUpdateBundleThrows() throws {
        try makeIdentity("MU Test A")
        let current = try makeApp("Current")
        try sign(current, identity: "MU Test A")
        XCTAssertThrowsError(try Updater.verifySignature(of: root.appendingPathComponent("нет.app"), matchingBundleAt: current))
    }

    func testSymlinkPointingOutsideBundleIsRejected() throws {
        try makeIdentity("MU Test A")
        let current = try makeApp("Current"), update = try makeApp("Update")
        let resources = update.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("escape"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc"))
        try sign(current, identity: "MU Test A")
        // Подписать такой бандл codesign может; важно, что verifySignature его не принимает.
        let signed = try sh("/usr/bin/codesign", ["--force", "--sign", "MU Test A", "--keychain", keychain.path, update.path])
        // Именно XCTSkip, в том числе в CI: если codesign сам отказывается подписывать бандл с symlink наружу, это его
        // поведение, а не сломанная среда (среду проверяют предыдущие шаги через setupUnavailable). Тогда такой бандл
        // и не может попасть в обновление подписанным.
        if signed.status != 0 { throw XCTSkip("codesign отказался подписывать бандл с symlink: \(signed.output)") }
        XCTAssertThrowsError(try Updater.verifySignature(of: update, matchingBundleAt: current))
    }
}

// MARK: - checkVersions (S1: защита от отката на старую подписанную версию)

@MainActor
final class UpdaterCheckVersionsTests: XCTestCase {
    private func check(short: String? = "1.4.50", build: String? = "120", release: String = "1.4.50",
                       current: String = "1.4.40", currentBuild: String? = "100") throws {
        try Updater.checkVersions(bundleShort: short, bundleBuild: build, release: release,
                                  currentShort: current, currentBuild: currentBuild)
    }

    func testNewerMatchingBundleIsAccepted() {
        XCTAssertNoThrow(try check())
    }

    func testOldSignedBundleRelabelledAsNewReleaseIsRejected() {
        // Архив старой версии 1.3.9 под тегом v1.4.50: версия внутри не совпадает с релизом.
        XCTAssertThrowsError(try check(short: "1.3.9", build: "50"))
    }

    func testBundleVersionMustEqualRelease() {
        XCTAssertThrowsError(try check(short: "1.4.51"))
        XCTAssertThrowsError(try check(short: nil))
    }

    func testReleaseMustBeNewerThanInstalled() {
        XCTAssertThrowsError(try check(release: "1.4.50", current: "1.4.50"))
        XCTAssertThrowsError(try check(short: "1.4.30", release: "1.4.30", current: "1.4.40"))
    }

    func testBuildNumberMustBeGreaterThanCurrent() {
        XCTAssertThrowsError(try check(build: "100", currentBuild: "100"))
        XCTAssertThrowsError(try check(build: "99", currentBuild: "100"))
        XCTAssertThrowsError(try check(build: nil))
        XCTAssertNoThrow(try check(build: "101", currentBuild: "100"))
    }

    func testMissingCurrentBuildDoesNotBlockUpdate() {
        XCTAssertNoThrow(try check(currentBuild: nil))
    }

    func testBuildNumbersCompareNumericallyNotAsStrings() {
        XCTAssertNoThrow(try check(build: "1000", currentBuild: "999"))
        XCTAssertThrowsError(try check(build: "99", currentBuild: "1000"))
    }
}

private struct SignatureSetupError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - Версии (docs/VERSIONING.md)

/// ДОСЛОВНАЯ копия компаратора, которым пользуется весь установленный парк (≤ 1.3.100):
/// `git show origin/main:Sources/MacUtils/Features/Update/Updater.swift`, функция `isVersion`.
/// Не «улучшать»: тест нужен, чтобы схема версий оставалась безопасной именно для старого кода.
private func legacyIsVersion(_ candidate: String, newerThan current: String) -> Bool {
    let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
    let b = current.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

@MainActor
final class VersionSchemeTests: XCTestCase {
    private static let sequence: [String] = (0...999).map { "1.4.\($0)" } + ["1.5.0", "2.0.0"]

    func testLegacyComparatorMatchesItsKnownBehaviour() {
        XCTAssertTrue(legacyIsVersion("1.4.0", newerThan: "1.3.100"))
        XCTAssertTrue(legacyIsVersion("1.3.101", newerThan: "1.3.100"))
        XCTAssertFalse(legacyIsVersion("1.3.100", newerThan: "1.3.100"))
        // Причина запрета суффиксов: для старого кода «1.4.0-beta.1» — это [1,4,0,1], то есть НОВЕЕ 1.4.0.
        XCTAssertTrue(legacyIsVersion("1.4.0-beta.1", newerThan: "1.4.0"))
    }

    func testSequenceIsStrictlyMonotonicForLegacyAndNewComparators() {
        for (older, newer) in zip(Self.sequence, Self.sequence.dropFirst()) {
            XCTAssertTrue(legacyIsVersion(newer, newerThan: older), "legacy: \(newer) должна быть новее \(older)")
            XCTAssertFalse(legacyIsVersion(older, newerThan: newer), "legacy: \(older) не новее \(newer)")
            XCTAssertTrue(Updater.isVersion(newer, newerThan: older), "новый: \(newer) должна быть новее \(older)")
            XCTAssertFalse(Updater.isVersion(older, newerThan: newer), "новый: \(older) не новее \(newer)")
        }
    }

    func testEverySchemeVersionIsNewerThanLastOldRelease() {
        for version in Self.sequence {
            XCTAssertTrue(legacyIsVersion(version, newerThan: "1.3.100"), version)
            XCTAssertTrue(Updater.isVersion(version, newerThan: "1.3.100"), version)
        }
    }

    func testLegacyAndNewComparatorsAgreeOnPlainVersions() {
        let samples = ["1.3.100", "1.3.101", "1.4", "1.4.0", "1.4.1", "1.4.10", "1.4.9", "1.10.0", "1.9.99", "2.0.0", "0.9.9"]
        for a in samples { for b in samples {
            XCTAssertEqual(legacyIsVersion(a, newerThan: b), Updater.isVersion(a, newerThan: b), "\(a) vs \(b)")
        } }
    }

    func testBuildNumberFormulaIsMonotonicAndAboveLegacyBuilds() {
        func build(_ v: String) -> Int {
            let p = v.split(separator: ".").map { Int($0)! }
            return p[0] * 1_000_000 + p[1] * 1_000 + p[2]
        }
        for (older, newer) in zip(Self.sequence, Self.sequence.dropFirst()) {
            XCTAssertLessThan(build(older), build(newer), "\(older) → \(newer)")
        }
        XCTAssertEqual(build("1.4.3"), 1_004_003)
        XCTAssertGreaterThan(build("1.4.0"), 221, "у v1.3.100 CFBundleVersion был 221")
    }
}

@MainActor
final class UpdaterTagSelectionTests: XCTestCase {
    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, assets: [String] = ["MacUtils.zip"]) -> [String: Any] {
        ["tag_name": tag, "draft": draft, "prerelease": prerelease,
         "assets": assets.map { ["name": $0, "browser_download_url": "https://example.com/\(tag)/\($0)"] }]
    }

    private func version(of releases: [[String: Any]]) throws -> String {
        try Updater.parseRelease(JSONSerialization.data(withJSONObject: releases)).version
    }

    func testWindowsLatestIsSkippedEvenWithMacAsset() throws {
        XCTAssertEqual(try version(of: [release("windows-latest", prerelease: true), release("v1.4.0")]), "1.4.0")
        XCTAssertEqual(try version(of: [release("windows-latest"), release("v1.4.0")]), "1.4.0", "и без флага pre-release тег без v не подходит")
    }

    func testPrereleaseIsSkipped() throws {
        XCTAssertEqual(try version(of: [release("v1.5.0", prerelease: true), release("v1.4.2")]), "1.4.2")
    }

    func testTagsWithSuffixAreSkippedEvenIfNotMarkedPrerelease() throws {
        // Старый код считает «1.4.0-beta.1» новее 1.4.0, поэтому такие теги нельзя принимать никогда.
        for tag in ["v1.4.0-beta.1", "v1.4.1-rc1", "v1.4.1+abc", "v1.4", "v1.4.0.1", "V1.4.5", "v1.4.x", "v1.4.3 "] {
            XCTAssertEqual(try version(of: [release(tag), release("v1.4.0")]), "1.4.0", "\(tag) должен быть пропущен")
        }
    }

    func testOnlyUnsuitableReleasesMeansNotFound() {
        XCTAssertThrowsError(try version(of: [release("v1.4.0-beta.1"), release("windows-latest", prerelease: true)]))
    }

    func testPicksHighestVersionRegardlessOfOrderAndNumerically() throws {
        XCTAssertEqual(try version(of: [release("v1.4.2"), release("v1.4.10"), release("v1.4.3"), release("v1.3.100")]), "1.4.10")
        XCTAssertEqual(try version(of: [release("v1.3.100"), release("v1.4.0"), release("v1.5.0"), release("v1.4.9")]), "1.5.0")
        XCTAssertEqual(try version(of: [release("v1.9.99"), release("v1.10.0")]), "1.10.0", "1.10 > 1.9, не лексикографически")
    }

    func testHighestVersionWithoutAssetIsSkippedForNextOne() throws {
        XCTAssertEqual(try version(of: [release("v1.4.9", assets: ["notes.txt"]), release("v1.4.8")]), "1.4.8")
    }

    func testDraftsAreSkippedWhenChoosingHighest() throws {
        XCTAssertEqual(try version(of: [release("v1.4.9", draft: true), release("v1.4.8")]), "1.4.8")
    }
}

final class UpdaterChannelTests: XCTestCase {
    func testChannelFromInfoValue() {
        XCTAssertEqual(Updater.Channel(infoValue: "release"), .release)
        XCTAssertEqual(Updater.Channel(infoValue: nil), .dev)
        XCTAssertEqual(Updater.Channel(infoValue: "dev"), .dev)
        XCTAssertEqual(Updater.Channel(infoValue: 1), .dev)
        XCTAssertEqual(Updater.Channel(infoValue: "Release"), .dev)
        XCTAssertEqual(Updater.Channel(infoValue: ""), .dev)
    }

    func testOnlyReleaseInstallsAutomatically() {
        XCTAssertTrue(Updater.Channel.release.installsAutomatically)
        XCTAssertFalse(Updater.Channel.dev.installsAutomatically)
    }

    func testDisplayVersion() {
        typealias U = Updater
        XCTAssertEqual(U.displayVersion(short: "1.4.3", channel: .release, commit: "abc1234", since: "12"), "1.4.3")
        XCTAssertEqual(U.displayVersion(short: "1.4.3", channel: .dev, commit: "abc1234", since: "12"), "1.4.3 · dev abc1234+12")
        XCTAssertEqual(U.displayVersion(short: "1.4.3", channel: .dev, commit: "abc1234-dirty", since: "0"), "1.4.3 · dev abc1234-dirty+0")
        XCTAssertEqual(U.displayVersion(short: "1.4.3", channel: .dev, commit: "abc1234", since: "?"), "1.4.3 · dev abc1234")
        XCTAssertEqual(U.displayVersion(short: "1.4.3", channel: .dev, commit: "abc1234", since: ""), "1.4.3 · dev abc1234")
        XCTAssertEqual(U.displayVersion(short: "1.4.3", channel: .dev, commit: "abc1234", since: nil), "1.4.3 · dev abc1234")
        XCTAssertEqual(U.displayVersion(short: "1.4.3", channel: .dev, commit: "unknown", since: "5"), "1.4.3 · dev")
        XCTAssertEqual(U.displayVersion(short: "1.4.3", channel: .dev, commit: "", since: "5"), "1.4.3 · dev")
        XCTAssertEqual(U.displayVersion(short: "1.4.3", channel: .dev, commit: nil, since: nil), "1.4.3 · dev")
    }

    func testStrictVersion() {
        XCTAssertEqual(Updater.strictVersion(tag: "v1.4.3"), [1, 4, 3])
        XCTAssertEqual(Updater.strictVersion(tag: "v1.3.100"), [1, 3, 100])
        XCTAssertEqual(Updater.strictVersion(tag: "v0.0.0"), [0, 0, 0])
        for bad in ["1.4.3", "windows-latest", "v1.4", "v1.4.0.1", "v1.4.0-beta.1", "v1.4.x", "v1..3", "v1.4.", "v", "", "V1.4.3", "v1.4.3 ", "v+1.4.3", "v1.-4.3", "v١.٤.٣"] {
            XCTAssertNil(Updater.strictVersion(tag: bad), bad)
        }
    }
}
