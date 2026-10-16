import XCTest
@testable import MacUtils

/// Удаление программ, волна P2: подмена пути при переносе от root (N1), агенты в бандле программы (U3).
/// Скрипт root прогоняется через /bin/sh без прав во временной папке.
@MainActor
final class UninstallerHardeningTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("UninstallerHardening-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func run(_ script: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private var staging: URL { root.appendingPathComponent("staging") }

    private func script(_ urls: [URL], owner: String = NSUserName()) -> String {
        UninstallerModel.adminStagingScript(urls, staging: staging.path, owner: owner)
    }

    // MARK: - N1: обычные сценарии не ломаются

    func testOrdinaryMoveStillWorks() throws {
        let source = root.appendingPathComponent("Library/LaunchDaemons/com.x.helper")
        try write("helper", to: source.appendingPathComponent("bin"))
        XCTAssertEqual(try run(script([source])), 0)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(read(staging.appendingPathComponent("com.x.helper/bin")), "helper")
    }

    /// Symlink в пути, который был уже при построении скрипта (как /var → /private/var или перенесённая папка), — не атака.
    func testSymlinkThatExistedWhenScriptWasBuiltIsFine() throws {
        let real = root.appendingPathComponent("real")
        try write("data", to: real.appendingPathComponent("com.x.plist"))
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let source = link.appendingPathComponent("com.x.plist")
        XCTAssertEqual(try run(script([source])), 0)
        XCTAssertEqual(read(staging.appendingPathComponent("com.x.plist")), "data")
        XCTAssertFalse(fm.fileExists(atPath: real.appendingPathComponent("com.x.plist").path))
    }

    func testSourceThatIsASymlinkMovesOnlyTheLink() throws {
        let precious = root.appendingPathComponent("precious")
        try write("system", to: precious)
        let source = root.appendingPathComponent("dir/com.x.link")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: source, withDestinationURL: precious)
        XCTAssertEqual(try run(script([source])), 0)
        XCTAssertEqual(read(precious), "system", "файл, на который указывала ссылка, на месте")
        let moved = staging.appendingPathComponent("com.x.link")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: moved.path), precious.path)
    }

    /// Формат сверки в Swift совпадает с тем, что печатает `stat -f %d:%i` в скрипте.
    func testIdentityFormatMatchesStatTool() throws {
        let file = root.appendingPathComponent("dir/item")
        try write("x", to: file)
        let identity = try XCTUnwrap(AdminSourceIdentity.read(file))
        func statTool(_ path: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
            process.arguments = ["-f", "%d:%i", path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(identity.item, try statTool(file.path))
        XCTAssertEqual(identity.parent, try statTool(file.deletingLastPathComponent().path))
        XCTAssertNil(AdminSourceIdentity.read(root.appendingPathComponent("нет-такого")))
    }

    // MARK: - N1: подмена после построения скрипта

    /// Родитель подменён symlink'ом на каталог с одноимённым «системным» файлом: root не должен его трогать.
    func testParentSwappedForSymlinkIsRefused() throws {
        let parent = root.appendingPathComponent("Caches")
        let source = parent.appendingPathComponent("com.x.app")
        try write("app cache", to: source)
        let system = root.appendingPathComponent("etc")
        try write("secret", to: system.appendingPathComponent("com.x.app"))
        let built = script([source])
        // Атакующий с правами пользователя: убирает настоящий каталог и ставит на его место ссылку.
        try fm.moveItem(at: parent, to: root.appendingPathComponent("Caches-old"))
        try fm.createSymbolicLink(at: parent, withDestinationURL: system)
        XCTAssertNotEqual(try run(built), 0)
        XCTAssertEqual(read(system.appendingPathComponent("com.x.app")), "secret", "чужой файл не перенесён")
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: staging.path)) ?? [], [])
    }

    func testGrandparentSwappedForSymlinkIsRefused() throws {
        let source = root.appendingPathComponent("home/Library/com.x.app")
        try write("mine", to: source)
        let other = root.appendingPathComponent("other")
        try write("secret", to: other.appendingPathComponent("Library/com.x.app"))
        let built = script([source])
        try fm.moveItem(at: root.appendingPathComponent("home"), to: root.appendingPathComponent("home-old"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("home"), withDestinationURL: other)
        XCTAssertNotEqual(try run(built), 0)
        XCTAssertEqual(read(other.appendingPathComponent("Library/com.x.app")), "secret")
    }

    func testParentReplacedByAnotherRealDirectoryIsRefused() throws {
        let parent = root.appendingPathComponent("Support")
        let source = parent.appendingPathComponent("com.x.app")
        try write("mine", to: source)
        let built = script([source])
        try fm.moveItem(at: parent, to: root.appendingPathComponent("Support-old"))
        try write("other", to: parent.appendingPathComponent("com.x.app"))
        XCTAssertNotEqual(try run(built), 0)
        XCTAssertEqual(read(source), "other", "подложенный каталог не тронут")
    }

    func testItemReplacedInPlaceIsRefused() throws {
        let source = root.appendingPathComponent("Support/com.x.app")
        try write("mine", to: source)
        let built = script([source])
        try fm.removeItem(at: source)
        try write("swapped", to: source)
        XCTAssertNotEqual(try run(built), 0)
        XCTAssertEqual(read(source), "swapped")
    }

    func testMissingSourceFailsEvenIfSomethingAppearsLater() throws {
        let source = root.appendingPathComponent("Support/com.x.app")
        let built = script([source]) // при построении файла нет — сверять не с чем
        try write("late", to: source)
        XCTAssertNotEqual(try run(built), 0)
        XCTAssertEqual(read(source), "late")
    }

    func testRefusedItemStopsTheChainButStagingIsStillHandedOver() throws {
        let first = root.appendingPathComponent("a/one.plist"), second = root.appendingPathComponent("b/two.plist")
        try write("1", to: first)
        try write("2", to: second)
        let built = script([first, second])
        try fm.removeItem(at: first)
        try write("swapped", to: first)
        XCTAssertNotEqual(try run(built), 0)
        XCTAssertEqual(read(second), "2", "после отказа остальные файлы не трогаем")
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    // MARK: - N1: пользователю отдаются только каталоги

    func testOnlyDirectoriesAreHandedToUser() throws {
        let source = root.appendingPathComponent("Library/com.x.app")
        try write("f", to: source.appendingPathComponent("file"))
        try write("g", to: source.appendingPathComponent("sub/inner"))
        // Жёсткая ссылка на «системный» файл, подложенная в переносимую папку, не должна сменить владельца.
        let system = root.appendingPathComponent("system-file")
        try write("secret", to: system)
        try fm.linkItem(at: system, to: source.appendingPathComponent("hardlink"))
        let log = root.appendingPathComponent("chown.log")
        // `-execdir` передаёт только имя в текущем каталоге: пишем настоящий путь (каталог по `pwd -P` + имя).
        let built = try withFakeChown("""
            for p in "$@"; do (cd "$(dirname "$p")" && printf '%s\\n' "$(pwd -P)/$(basename "$p")") >> \(UninstallerModel.shellQuote(log.path)); done
            """, in: script([source], owner: "tester"))
        XCTAssertEqual(try run(built), 0)
        let moved = staging.appendingPathComponent("com.x.app")
        let changed = Set((read(log) ?? "").split(separator: "\n").map(String.init))
        XCTAssertEqual(changed, Set([moved.path, moved.appendingPathComponent("sub").path, staging.path].map(realPath)))
        XCTAssertEqual(read(system), "secret")
    }

    /// MAJOR-1 из review-p2-uninst: пока find обходит перенесённую папку, пользователь через заранее открытый
    /// дескриптор меняет `X/sub` на symlink к системному каталогу. chown не должен дойти до «жертвы».
    func testChownCannotBeRedirectedThroughIntermediateDirectory() throws {
        let source = root.appendingPathComponent("Library/com.x.app")
        try fm.createDirectory(at: source.appendingPathComponent("sub/PrivilegedHelperTools"), withIntermediateDirectories: true)
        let victimParent = root.appendingPathComponent("victim")
        let victim = victimParent.appendingPathComponent("PrivilegedHelperTools")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        let victimIDs = [try inode(victimParent), try inode(victim)]

        func attempt(_ script: String, tag: String) throws -> [String] {
            let log = root.appendingPathComponent("chown-\(tag).log"), mark = root.appendingPathComponent("swapped-\(tag)")
            let moved = staging.appendingPathComponent("com.x.app")
            let q = UninstallerModel.shellQuote
            // Первый вызов chown — подмена (как это сделал бы атакующий через дескриптор `X`), затем журнал inode аргументов.
            let built = try withFakeChown("""
                if [ ! -e \(q(mark.path)) ]; then : > \(q(mark.path)); /bin/mv \(q(moved.appendingPathComponent("sub").path)) \(q(moved.appendingPathComponent("sub.old").path)); /bin/ln -s \(q(victimParent.path)) \(q(moved.appendingPathComponent("sub").path)); fi
                for p in "$@"; do /usr/bin/stat -f %d:%i "$p" >> \(q(log.path)); done
                """, in: script)
            XCTAssertEqual(try run(built), 0, tag)
            return (read(log) ?? "").split(separator: "\n").map(String.init)
        }

        let script = script([source], owner: "tester")
        let seen = try attempt(script, tag: "execdir")
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(Set(seen).isDisjoint(with: victimIDs), "chown дошёл до системного каталога: \(seen)")

        // Контроль: прежний вариант с полными путями (`-exec`) эту подмену пропускает — значит, тест её действительно ловит.
        try fm.removeItem(at: staging)
        try fm.removeItem(at: source.deletingLastPathComponent())
        try fm.createDirectory(at: source.appendingPathComponent("sub/PrivilegedHelperTools"), withIntermediateDirectories: true)
        let fullPaths = self.script([source], owner: "tester")
            .replacingOccurrences(of: "find './com.x.app' -type d -execdir", with: "find \(UninstallerModel.shellQuote(staging.appendingPathComponent("com.x.app").path)) -type d -exec")
        XCTAssertNotEqual(fullPaths, self.script([source], owner: "tester"))
        XCTAssertFalse(Set(try attempt(fullPaths, tag: "exec")).isDisjoint(with: victimIDs))
    }

    private func withFakeChown(_ body: String, in script: String) throws -> String {
        let fake = root.appendingPathComponent("fake-chown-\(UUID().uuidString).sh")
        try "#!/bin/sh\nshift 2\n\(body)\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        return script.replacingOccurrences(of: "/usr/sbin/chown", with: UninstallerModel.shellQuote(fake.path))
    }

    private func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func inode(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return "\(info.st_dev):\(info.st_ino)"
    }

    func testRootScriptDoesNotChownRecursively() {
        let built = script([URL(fileURLWithPath: "/Library/LaunchDaemons/com.x.plist")], owner: "tester")
        XCTAssertFalse(built.contains("chown -hR"), built)
        XCTAssertTrue(built.contains("cd -P -- \(UninstallerModel.shellQuote(staging.path)) || exit 1; "
                                     + "/usr/bin/find './com.x.plist' -type d -execdir /usr/sbin/chown -h 'tester' {} +"),
                      "владелец меняется из staging по имени, без полных путей")
        XCTAssertFalse(built.contains(" -exec "), built)
        XCTAssertTrue(built.contains("cd -P -- '/Library/LaunchDaemons'"))
        XCTAssertTrue(built.contains("/bin/mv -n './com.x.plist'"), "перенос — относительно уже открытого каталога")
    }

    // MARK: - U3: агенты в бандле программы

    func testBundledAgentDomain() {
        let home = "/Users/tester"
        let agent = URL(fileURLWithPath: "/Applications/X.app/Contents/Library/LaunchAgents/com.x.agent.plist")
        XCTAssertEqual(LaunchUnload.domain(for: agent, uid: 501, home: home), .gui(501))
        XCTAssertEqual(LaunchUnload.bootoutArguments(for: agent, uid: 501, home: home), ["bootout", "gui/501", agent.path])
        for path in ["/Applications/X.app/Contents/Library/LaunchDaemons/com.x.d.plist",
                     "/Applications/X/Contents/Library/LaunchAgents/com.x.plist",
                     "/Applications/X.app/Contents/Library/LaunchAgents/sub/com.x.plist",
                     "/Applications/X.app/Contents/Library/LaunchAgents/com.x.agent"] {
            XCTAssertNil(LaunchUnload.domain(for: URL(fileURLWithPath: path), uid: 501, home: home), path)
        }
        XCTAssertEqual(LaunchUnload.rootCommands(for: [agent], quote: UninstallerModel.shellQuote), "", "агент — не для root")
    }

    func testBundledAgentsAreFound() throws {
        let app = root.appendingPathComponent("X.app")
        let agents = app.appendingPathComponent("Contents/Library/LaunchAgents")
        try write("<plist/>", to: agents.appendingPathComponent("com.x.b.plist"))
        try write("<plist/>", to: agents.appendingPathComponent("com.x.a.plist"))
        try write("x", to: agents.appendingPathComponent("README"))
        try write("<plist/>", to: app.appendingPathComponent("Contents/Library/LaunchDaemons/com.x.d.plist"))
        XCTAssertEqual(LaunchUnload.bundledAgents(in: app).map(\.lastPathComponent), ["com.x.a.plist", "com.x.b.plist"])
        XCTAssertEqual(LaunchUnload.bundledAgents(in: root.appendingPathComponent("Y.app")), [])
    }

    func testBundledAgentsAreStoppedInUserDomain() throws {
        let app = root.appendingPathComponent("X.app")
        let agent = app.appendingPathComponent("Contents/Library/LaunchAgents/com.x.a.plist")
        try write("<plist/>", to: agent)
        let log = root.appendingPathComponent("launchctl.log")
        let fake = root.appendingPathComponent("fake-launchctl.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(UninstallerModel.shellQuote(log.path))\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let codes = LaunchUnload.bootoutUserServices(LaunchUnload.bundledAgents(in: app), uid: 501, home: "/Users/tester", launchctl: fake.path)
        XCTAssertEqual(codes.count, 1)
        XCTAssertEqual(read(log), "bootout gui/501 \(agent.standardizedFileURL.path)\n")
    }
}
