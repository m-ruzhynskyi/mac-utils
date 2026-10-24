import XCTest
@testable import MacUtils
@testable import MUCutPaste
@testable import MUAudio
@testable import MUScreenshot

/// `FileMover` (⌘X/⌘V в Finder): всё на временных папках, без прав доступа и без UserDefaults.
final class FileMoverTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var cleanups: [() -> Void] = []

    override func setUpWithError() throws {
        // Каталог в /private/tmp-подобном месте: realpath, чтобы пути не зависели от /var → /private/var.
        let base = fm.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("FileMoverTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for cleanup in cleanups.reversed() { cleanup() }
        cleanups = []
        // Вернуть права, чтобы удаление не споткнулось о закрытые папки.
        if let items = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in items { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        try? fm.removeItem(at: root)
    }

    // MARK: - Помощники

    @discardableResult
    private func dir(_ name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func file(_ name: String, in parent: URL, text: String? = nil) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try Data((text ?? name).utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }
    private func names(_ url: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

    // MARK: - Обычное перемещение

    func testMovesFilesAndFolders() throws {
        let source = try dir("src"), target = try dir("dst")
        let a = try file("a.txt", in: source)
        let sub = try dir("Папка", in: source)
        try file("inside.txt", in: sub)
        let outcome = FileMover.move([a, sub], into: target)
        XCTAssertEqual(outcome.moved, 2)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(names(source), [])
        XCTAssertEqual(names(target), ["a.txt", "Папка"])
        XCTAssertEqual(read(target.appendingPathComponent("Папка/inside.txt")), "inside.txt")
    }

    func testEmptyListIsNoOp() throws {
        let outcome = FileMover.move([], into: try dir("dst"))
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertNil(outcome.error)
    }

    func testUnicodeAndSpacesInNames() throws {
        let source = try dir("src"), target = try dir("dst")
        let names = ["Отчёт 2024 (финал).pdf", "日本語 ファイル.txt", "emoji 😀.md", "e\u{301}.txt"]
        let urls = try names.map { try file($0, in: source) }
        let outcome = FileMover.move(urls, into: target)
        XCTAssertEqual(outcome.moved, names.count)
        XCTAssertEqual(self.names(source), [])
        XCTAssertEqual(self.names(target).count, names.count)
    }

    // MARK: - Коллизии имён

    func testFileCollisionGetsNumberedName() throws {
        let source = try dir("src"), target = try dir("dst")
        try file("Файл.txt", in: target, text: "старый")
        let moved = try file("Файл.txt", in: source, text: "новый")
        let outcome = FileMover.move([moved], into: target)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(read(target.appendingPathComponent("Файл.txt")), "старый", "существующий файл не тронут")
        XCTAssertEqual(read(target.appendingPathComponent("Файл 2.txt")), "новый")
    }

    func testFolderCollisionGetsNumberedNameAndContentsAreNotMerged() throws {
        let source = try dir("src"), target = try dir("dst")
        let existing = try dir("Docs", in: target)
        try file("keep.txt", in: existing)
        let incoming = try dir("Docs", in: source)
        try file("new.txt", in: incoming)
        let outcome = FileMover.move([incoming], into: target)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(names(existing), ["keep.txt"], "содержимое существующей папки не изменилось")
        XCTAssertEqual(names(target.appendingPathComponent("Docs 2")), ["new.txt"])
    }

    func testFileCollidesWithFolderOfTheSameName() throws {
        let source = try dir("src"), target = try dir("dst")
        try dir("Data.d", in: target)
        let moved = try file("Data.d", in: source, text: "файл")
        let outcome = FileMover.move([moved], into: target)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(names(target).count, 2)
        XCTAssertEqual(outcome.failed.count, 0)
    }

    func testSeveralCollisionsInARowFindFirstFreeNumber() throws {
        let source = try dir("src"), target = try dir("dst")
        for name in ["a.txt", "a 2.txt", "a 3.txt", "a 5.txt"] { try file(name, in: target) }
        let moved = try file("a.txt", in: source, text: "новый")
        let outcome = FileMover.move([moved], into: target)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(read(target.appendingPathComponent("a 4.txt")), "новый", "первый свободный номер, дыры заполняются")
        XCTAssertEqual(names(target), ["a 2.txt", "a 3.txt", "a 4.txt", "a 5.txt", "a.txt"])
    }

    func testSameNameFromDifferentSourcesInOneBatch() throws {
        let one = try dir("one"), two = try dir("two"), three = try dir("three"), target = try dir("dst")
        let urls = [try file("x.txt", in: one, text: "1"), try file("x.txt", in: two, text: "2"), try file("x.txt", in: three, text: "3")]
        let outcome = FileMover.move(urls, into: target)
        XCTAssertEqual(outcome.moved, 3)
        XCTAssertEqual(names(target), ["x 2.txt", "x 3.txt", "x.txt"])
        XCTAssertEqual(read(target.appendingPathComponent("x.txt")), "1")
        XCTAssertEqual(read(target.appendingPathComponent("x 2.txt")), "2")
        XCTAssertEqual(read(target.appendingPathComponent("x 3.txt")), "3")
    }

    func testNameWithoutExtension() throws {
        let source = try dir("src"), target = try dir("dst")
        try file("README", in: target)
        let moved = try file("README", in: source)
        _ = FileMover.move([moved], into: target)
        XCTAssertEqual(names(target), ["README", "README 2"])
    }

    func testDotfileKeepsLeadingDot() throws {
        let source = try dir("src"), target = try dir("dst")
        try file(".env", in: target)
        let moved = try file(".env", in: source)
        _ = FileMover.move([moved], into: target)
        XCTAssertEqual(names(target), [".env", ".env 2"])
    }

    func testDotsInNameKeepOnlyLastExtension() throws {
        let source = try dir("src"), target = try dir("dst")
        try file("report.final.v2.pdf", in: target)
        let moved = try file("report.final.v2.pdf", in: source)
        _ = FileMover.move([moved], into: target)
        XCTAssertEqual(names(target), ["report.final.v2 2.pdf", "report.final.v2.pdf"])
    }

    func testDoubleExtensionCurrentNaming() throws {
        let source = try dir("src"), target = try dir("dst")
        try file("archive.tar.gz", in: target)
        let moved = try file("archive.tar.gz", in: source)
        _ = FileMover.move([moved], into: target)
        // Текущее поведение: номер вставляется перед последним расширением («archive.tar 2.gz»).
        XCTAssertEqual(names(target), ["archive.tar 2.gz", "archive.tar.gz"])
    }

    func testFolderWithDotInNameIsNotSplitAsExtension() throws {
        let source = try dir("src"), target = try dir("dst")
        try dir("Проект v1.2", in: target)
        let moved = try dir("Проект v1.2", in: source)
        _ = FileMover.move([moved], into: target)
        XCTAssertEqual(names(target).sorted(), ["Проект v1.2", "Проект v1.2 2"])
    }

    func testDanglingSymlinkAtDestinationNameIsNotOverwritten() throws {
        let source = try dir("src"), target = try dir("dst")
        try fm.createSymbolicLink(at: target.appendingPathComponent("a.txt"), withDestinationURL: root.appendingPathComponent("нет-такого"))
        let moved = try file("a.txt", in: source, text: "данные")
        let outcome = FileMover.move([moved], into: target)
        // fileExists идёт по ссылке и для «висячей» возвращает false: перенос не должен ни затереть ссылку, ни потерять файл.
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("a.txt").path), "висячая ссылка не затёрта")
        XCTAssertEqual(outcome.moved + outcome.failed.count, 1)
        let landed = names(target).filter { $0 != "a.txt" }
        XCTAssertTrue(exists(moved) || !landed.isEmpty, "файл не потерян (остался или лежит под новым именем)")
    }

    // MARK: - Папка в саму себя и в потомка

    func testFolderIntoItselfIsRejectedAndNothingMoves() throws {
        let folder = try dir("Self")
        try file("a.txt", in: folder)
        let outcome = FileMover.move([folder], into: folder)
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, [folder])
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(names(folder), ["a.txt"])
    }

    func testFolderIntoItsDescendantIsRejected() throws {
        let top = try dir("Top")
        let deep = try dir("a/b/c", in: top)
        try file("keep.txt", in: top)
        let outcome = FileMover.move([top], into: deep)
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, [top])
        XCTAssertTrue(exists(top.appendingPathComponent("keep.txt")))
        XCTAssertEqual(names(deep), [], "в потомка ничего не попало")
    }

    func testSiblingWithCommonPrefixIsNotMistakenForDescendant() throws {
        let foo = try dir("Foo")
        try file("x.txt", in: foo)
        let fooBar = try dir("Foo Bar")
        let outcome = FileMover.move([foo], into: fooBar)
        XCTAssertEqual(outcome.moved, 1, "«Foo Bar» — не потомок «Foo»")
        XCTAssertTrue(exists(fooBar.appendingPathComponent("Foo/x.txt")))
    }

    func testFolderIntoDescendantWithTrailingSlashAndDotDot() throws {
        let top = try dir("Top")
        let deep = try dir("child", in: top)
        let tricky = URL(fileURLWithPath: deep.path + "/../child/", isDirectory: true)
        let outcome = FileMover.move([top], into: tricky)
        XCTAssertEqual(outcome.failed, [top], "«..» в пути не обходит проверку")
        XCTAssertEqual(names(top), ["child"])
    }

    func testFolderIntoDescendantThroughSymlinkLeavesEverythingIntact() throws {
        let top = try dir("Top")
        try file("keep.txt", in: top)
        let deep = try dir("deep", in: top)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: deep)
        let outcome = FileMover.move([top], into: link)
        // Путь через ссылку проверка по префиксу не видит; система обязана отказать сама, ничего не потеряв.
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, [top])
        XCTAssertTrue(exists(top.appendingPathComponent("keep.txt")))
        XCTAssertEqual(names(top).sorted(), ["deep", "keep.txt"])
    }

    func testCaseOnlyDifferenceDoesNotLoseData() throws {
        let top = try dir("Top")
        try file("keep.txt", in: top)
        let deep = try dir("deep", in: top)
        let upper = URL(fileURLWithPath: root.path + "/TOP/deep", isDirectory: true)
        let outcome = FileMover.move([top], into: upper)
        // На регистронезависимом томе «TOP/deep» — это «Top/deep»; важно только, что данные целы.
        XCTAssertTrue(exists(top.appendingPathComponent("keep.txt")))
        XCTAssertEqual(outcome.moved + outcome.failed.count, 1)
        _ = deep
    }

    // MARK: - Уже в этой папке

    func testFileAlreadyInTargetFolderIsLeftAlone() throws {
        let folder = try dir("here")
        let a = try file("a.txt", in: folder)
        let outcome = FileMover.move([a], into: folder)
        XCTAssertEqual(outcome.moved, 1, "уже на месте считается выполненным")
        XCTAssertEqual(names(folder), ["a.txt"], "файл не переименован в «a 2.txt»")
    }

    func testAlreadyInTargetThroughSymlinkedFolderIsNotRenamed() throws {
        let folder = try dir("here")
        let a = try file("a.txt", in: folder)
        let link = root.appendingPathComponent("here-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: folder)
        let outcome = FileMover.move([a], into: link)
        XCTAssertEqual(outcome.moved, 1)
        // Тот же каталог, но путь записан через ссылку: файл не переименовывается в «a 2.txt».
        XCTAssertEqual(names(folder), ["a.txt"])
    }

    func testTrailingSlashAndDotComponentsOfTargetAreNormalized() throws {
        let folder = try dir("here")
        let a = try file("a.txt", in: folder)
        let odd = URL(fileURLWithPath: folder.path + "/./", isDirectory: true)
        let outcome = FileMover.move([a], into: odd)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(names(folder), ["a.txt"])
    }

    // MARK: - Частичный провал

    func testOneLockedSourceFailsOthersMove() throws {
        let open = try dir("open"), locked = try dir("locked"), target = try dir("dst")
        let a = try file("a.txt", in: open), b = try file("b.txt", in: locked), c = try file("c.txt", in: open)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path) // из закрытой папки файл не вынуть
        let outcome = FileMover.move([a, b, c], into: target)
        XCTAssertEqual(outcome.moved, 2)
        XCTAssertEqual(outcome.failed, [b])
        XCTAssertNotNil(outcome.error, "причина видна")
        XCTAssertFalse(outcome.error?.isEmpty ?? true)
        XCTAssertEqual(names(target), ["a.txt", "c.txt"])
        XCTAssertEqual(read(b), "b.txt", "недоступный файл остался на месте целым")
    }

    func testReadOnlyTargetFailsEverythingAndLosesNothing() throws {
        let source = try dir("src"), target = try dir("dst")
        let urls = try ["a.txt", "b.txt", "c.txt"].map { try file($0, in: source) }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        let outcome = FileMover.move(urls, into: target)
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, urls, "порядок и состав сохранены для повторной попытки")
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(names(source), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(names(target), [])
    }

    func testMissingTargetFolderFailsWithoutLoss() throws {
        let source = try dir("src")
        let a = try file("a.txt", in: source)
        let outcome = FileMover.move([a], into: root.appendingPathComponent("не-существует"))
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, [a])
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(read(a), "a.txt")
    }

    func testTargetIsAFileFailsWithoutLoss() throws {
        let source = try dir("src")
        let a = try file("a.txt", in: source)
        let notFolder = try file("plain", in: root)
        let outcome = FileMover.move([a], into: notFolder)
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, [a])
        XCTAssertEqual(read(a), "a.txt")
        XCTAssertEqual(read(notFolder), "plain")
    }

    func testFailureDoesNotStopTheBatch() throws {
        let source = try dir("src"), target = try dir("dst")
        let gone = source.appendingPathComponent("нет.txt")
        let a = try file("a.txt", in: source), z = try file("z.txt", in: source)
        let outcome = FileMover.move([a, gone, z], into: target)
        XCTAssertEqual(outcome.moved, 2)
        XCTAssertEqual(outcome.failed, [gone])
        XCTAssertEqual(names(target), ["a.txt", "z.txt"])
    }

    // MARK: - Исходник исчез между ⌘X и ⌘V

    func testSourceDeletedBetweenCutAndPaste() throws {
        let source = try dir("src"), target = try dir("dst")
        let a = try file("a.txt", in: source), b = try file("b.txt", in: source)
        try fm.removeItem(at: a)
        let outcome = FileMover.move([a, b], into: target)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(outcome.failed, [a], "исчезнувший файл возвращается в failed, а не пропадает молча")
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(names(target), ["b.txt"])
    }

    func testSourceRenamedBetweenCutAndPaste() throws {
        let source = try dir("src"), target = try dir("dst")
        let a = try file("a.txt", in: source)
        try fm.moveItem(at: a, to: source.appendingPathComponent("renamed.txt"))
        let outcome = FileMover.move([a], into: target)
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, [a])
        XCTAssertEqual(names(source), ["renamed.txt"], "переименованный файл не тронут")
        XCTAssertEqual(names(target), [])
    }

    func testSourceFolderReplacedByFileOfTheSameName() throws {
        let source = try dir("src"), target = try dir("dst")
        let folder = try dir("thing", in: source)
        try fm.removeItem(at: folder)
        try file("thing", in: source, text: "теперь файл")
        let outcome = FileMover.move([folder], into: target)
        XCTAssertEqual(outcome.moved, 1, "переносится то, что сейчас лежит по этому пути")
        XCTAssertEqual(read(target.appendingPathComponent("thing")), "теперь файл")
    }

    func testAllSourcesGone() throws {
        let target = try dir("dst")
        let urls = [root.appendingPathComponent("1"), root.appendingPathComponent("2")]
        let outcome = FileMover.move(urls, into: target)
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, urls)
        XCTAssertEqual(names(target), [])
    }

    // MARK: - Символические ссылки

    func testSymlinkIsMovedNotItsTarget() throws {
        let source = try dir("src"), target = try dir("dst"), elsewhere = try dir("real")
        let real = try file("real.txt", in: elsewhere, text: "цель")
        let link = source.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let outcome = FileMover.move([link], into: target)
        XCTAssertEqual(outcome.moved, 1)
        let moved = target.appendingPathComponent("link.txt")
        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: moved.path), real.path, "в папке лежит ссылка с тем же адресом")
        XCTAssertEqual(read(real), "цель", "цель на месте")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: link.path), "старая ссылка исчезла")
    }

    func testSymlinkToFolderIsMovedAsLinkAndFolderContentsStay() throws {
        let source = try dir("src"), target = try dir("dst"), real = try dir("realdir")
        try file("inside.txt", in: real)
        let link = source.appendingPathComponent("dirlink")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let outcome = FileMover.move([link], into: target)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("dirlink").path), real.path)
        XCTAssertEqual(names(real), ["inside.txt"])
    }

    func testDanglingSymlinkIsMoved() throws {
        let source = try dir("src"), target = try dir("dst")
        let link = source.appendingPathComponent("broken")
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("нигде"))
        let outcome = FileMover.move([link], into: target)
        XCTAssertEqual(outcome.moved, 1, "битая ссылка — тоже объект, а не «исходник исчез»")
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("broken").path))
    }

    func testSymlinkCollisionKeepsExistingFile() throws {
        let source = try dir("src"), target = try dir("dst")
        try file("l", in: target, text: "обычный файл")
        let real = try file("real", in: root)
        let link = source.appendingPathComponent("l")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let outcome = FileMover.move([link], into: target)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(read(target.appendingPathComponent("l")), "обычный файл")
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("l 2").path))
    }

    func testFolderContainingSymlinkToItsParentMovesWithoutFollowing() throws {
        let source = try dir("src"), target = try dir("dst")
        let folder = try dir("loop", in: source)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("up"), withDestinationURL: source)
        let outcome = FileMover.move([folder], into: target)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("loop/up").path), source.path)
        XCTAssertEqual(names(source), [])
    }

    // MARK: - Другой том

    /// Маленький образ диска в роли второго тома. Нужны hdiutil и право монтировать собственный образ — иначе тест пропускается.
    private func mountSmallVolume(megabytes: Int) throws -> URL {
        let image = root.appendingPathComponent("vol.dmg")
        let mountPoint = root.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        func run(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        guard try run(["create", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname", "MUTest", "-quiet", image.path]) == 0 else {
            throw XCTSkip("hdiutil create недоступен")
        }
        guard try run(["attach", image.path, "-nobrowse", "-noverify", "-mountpoint", mountPoint.path, "-quiet"]) == 0 else {
            throw XCTSkip("не удалось подключить тестовый образ")
        }
        cleanups.append { _ = try? run(["detach", mountPoint.path, "-force", "-quiet"]) }
        return mountPoint
    }

    func testMoveToAnotherVolumeCopiesAndRemovesSource() throws {
        let volume = try mountSmallVolume(megabytes: 8)
        let source = try dir("src")
        let a = try file("a.txt", in: source, text: "через тома")
        let folder = try dir("Папка", in: source)
        try file("in.txt", in: folder, text: "внутри")
        let outcome = FileMover.move([a, folder], into: volume)
        XCTAssertEqual(outcome.moved, 2)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(read(volume.appendingPathComponent("a.txt")), "через тома")
        XCTAssertEqual(read(volume.appendingPathComponent("Папка/in.txt")), "внутри")
        XCTAssertEqual(names(source), [], "после успешного копирования исходники удалены")
    }

    func testMoveToAnotherVolumeCollisionKeepsExisting() throws {
        let volume = try mountSmallVolume(megabytes: 8)
        let source = try dir("src")
        try file("a.txt", in: volume, text: "на томе")
        let moved = try file("a.txt", in: source, text: "с диска")
        let outcome = FileMover.move([moved], into: volume)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(read(volume.appendingPathComponent("a.txt")), "на томе")
        XCTAssertEqual(read(volume.appendingPathComponent("a 2.txt")), "с диска")
    }

    func testCopyFailureOnAnotherVolumeKeepsSourceIntact() throws {
        let volume = try mountSmallVolume(megabytes: 4)
        let source = try dir("src")
        let small = try file("small.txt", in: source, text: "маленький")
        // Файл заведомо больше свободного места на томе: копирование оборвётся.
        let big = source.appendingPathComponent("big.bin")
        var payload = Data(count: 6 * 1024 * 1024)
        payload.withUnsafeMutableBytes { buffer in
            for i in stride(from: 0, to: buffer.count, by: 4096) { buffer[i] = UInt8(truncatingIfNeeded: i / 4096) }
        }
        try payload.write(to: big)
        let outcome = FileMover.move([big, small], into: volume)
        XCTAssertEqual(outcome.failed, [big], "не поместившийся файл — в failed")
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(try? Data(contentsOf: big), payload, "исходник цел и не изменён")
        XCTAssertEqual(outcome.moved, 1, "остальные файлы переносятся")
        XCTAssertEqual(read(volume.appendingPathComponent("small.txt")), "маленький")
        XCTAssertFalse(exists(small), "перенесённый файл с исходного тома удалён")
        XCTAssertFalse(names(volume).contains { $0.hasPrefix("big") }, "обрывок большого файла не остался на томе")
    }

    // MARK: - Пакет 2: исправления найденных ошибок

    func testPackageKeepsExtensionWhenNumbered() throws {
        let source = try dir("src"), target = try dir("dst")
        try dir("Утилита.app", in: target)
        let moved = try dir("Утилита.app", in: source)
        _ = FileMover.move([moved], into: target)
        XCTAssertEqual(names(target), ["Утилита 2.app", "Утилита.app"], "у пакета расширение настоящее")
    }

    func testPlainFolderWithSeveralDotsAndRepeatedCollisions() throws {
        let one = try dir("one"), two = try dir("two"), target = try dir("dst")
        try dir("v1.2.3", in: target)
        let a = try dir("v1.2.3", in: one), b = try dir("v1.2.3", in: two)
        _ = FileMover.move([a, b], into: target)
        XCTAssertEqual(names(target), ["v1.2.3", "v1.2.3 2", "v1.2.3 3"])
    }

    func testSourceParentThroughSymlinkIsStillRecognizedAsSameFolder() throws {
        let folder = try dir("here")
        let a = try file("a.txt", in: folder)
        let link = root.appendingPathComponent("link-to-here")
        try fm.createSymbolicLink(at: link, withDestinationURL: folder)
        // Файл указан через ссылку на родителя, папка назначения — настоящая.
        let outcome = FileMover.move([link.appendingPathComponent("a.txt")], into: folder)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(names(folder), ["a.txt"])
        XCTAssertEqual(read(a), "a.txt")
    }

    func testDescendantThroughSymlinkIsRejectedByCheckNotByLuck() throws {
        let top = try dir("Top")
        let deep = try dir("deep", in: top)
        let link = root.appendingPathComponent("alias-to-deep")
        try fm.createSymbolicLink(at: link, withDestinationURL: deep)
        let outcome = FileMover.move([top], into: link)
        XCTAssertEqual(outcome.failed, [top])
        XCTAssertEqual(outcome.error, "Нельзя переместить папку в саму себя.", "проверка видит потомка через ссылку, ответ понятный")
    }

    func testMovingTheSymlinkItselfIsNotConfusedWithItsTarget() throws {
        let source = try dir("src"), target = try dir("dst")
        let real = try dir("realfolder")
        let link = source.appendingPathComponent("realfolder")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        // Ссылка на папку лежит в src, а переносим мы её в папку, которая и есть цель ссылки: это не «в саму себя».
        let outcome = FileMover.move([link], into: real)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: real.appendingPathComponent("realfolder").path))
        _ = target
    }

    // MARK: - N6: тот же каталог по идентификатору файловой системы

    func testSameFolderSpelledWithDifferentCaseIsNotRenamed() throws {
        let folder = try dir("HereCase")
        let a = try file("a.txt", in: folder)
        let lowercase = root.appendingPathComponent("herecase", isDirectory: true)
        try XCTSkipUnless(fm.fileExists(atPath: lowercase.path), "том регистрозависимый: «herecase» — другой каталог")
        let outcome = FileMover.move([a], into: lowercase)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(names(folder), ["a.txt"], "файл не «переехал» сам в себя под именем «a 2.txt»")
    }

    func testDifferentFoldersAreNotConfusedByIdentifierCheck() throws {
        let one = try dir("one"), two = try dir("two")
        let a = try file("a.txt", in: one)
        let outcome = FileMover.move([a], into: two)
        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(names(two), ["a.txt"])
        XCTAssertEqual(names(one), [])
    }
}
