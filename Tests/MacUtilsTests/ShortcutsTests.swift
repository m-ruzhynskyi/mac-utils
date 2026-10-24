import AppIntents
import CryptoKit
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Mac Utils в «Командах» и ссылках `macutils://`: каждое действие зовёт ту же функцию, что горячая клавиша и панель
/// (`AppAction.run`); действия с файлами — без окна, с теми же гарантиями байтов, что «Убрать значения» в редакторе.
@MainActor
final class ShortcutsTests: XCTestCase {
    private var ran: [AppAction] = []

    override func setUp() {
        super.setUp()
        ran = []
        AppAction.interceptor = { [weak self] in self?.ran.append($0) }
    }

    override func tearDown() {
        AppAction.interceptor = nil
        super.tearDown()
    }

    // MARK: - Ссылки

    /// Прежние ссылки (их уже вставили в «Команды») делают то же, что раньше.
    func testLegacyLinksKeepTheirMeaning() throws {
        let cases: [(String, AppAction)] = [
            ("macutils://tools", .tools),
            ("macutils://editor", .editor(path: nil)),
            ("macutils://editor?path=/tmp/a.frm", .editor(path: "/tmp/a.frm")),
            ("macutils://snap?left", .snap(.left)), ("macutils://snap?bottomRight", .snap(.bottomRight)),
            ("macutils://snap?maximize", .snap(.maximize)), ("macutils://snap?restore", .snap(.restore)),
            ("macutils://share", .shareToggle(screen: false)), ("macutils://share?screen", .shareToggle(screen: true)),
            ("macutils://watch?1234567890", .watch(code: "1234567890")),
            ("macutils://annotate", .annotate), ("macutils://pin", .pinWindow), ("macutils://fix-text", .fixText),
            ("macutils://meeting", .meeting(.toggle)), ("macutils://break", .breakNow), ("macutils://warm", .warmPreview),
            ("macutils://warm-toggle", .warmToggle), ("macutils://keep-awake", .keepAwake(.toggle)), ("macutils://focus", .focus),
        ]
        for (link, action) in cases {
            XCTAssertEqual(AppAction(url: try XCTUnwrap(URL(string: link))), action, link)
        }
        // Служебные — не действия, их по-прежнему разбирает AppDelegate.
        for link in ["macutils://share-drop", "macutils://meeting-report?x", "macutils://meeting-process?x", "macutils://snap?nowhere",
                     "macutils://watch", "macutils://viewer-monitor?0", "https://example.com/tools"] {
            XCTAssertNil(AppAction(url: try XCTUnwrap(URL(string: link))), link)
        }
    }

    func testNewLinksWithParameters() throws {
        let cases: [(String, AppAction)] = [
            ("macutils://keep-awake?1h", .keepAwake(.hour1)), ("macutils://keep-awake?off", .keepAwake(.off)),
            ("macutils://meeting-start", .meeting(.start)), ("macutils://meeting-stop", .meeting(.stop)),
            ("macutils://share-start?screen", .shareStart(screen: true)), ("macutils://share-stop", .shareStop),
            ("macutils://viewer-monitor?3", .viewerMonitor(3)),
            ("macutils://player", .player), ("macutils://player-open?path=/tmp/v.mp4", .playerOpen(path: "/tmp/v.mp4")),
            ("macutils://player-pause", .playerTogglePlay), ("macutils://player-continue", .playerContinue),
            ("macutils://dollars-remove?path=/tmp/a.frm&skip=5", .dollarsRemove(path: "/tmp/a.frm", skipFirst: 5)),
            ("macutils://dollars-remove?path=/tmp/a.frm&skip=off", .dollarsRemove(path: "/tmp/a.frm", skipFirst: nil)),
            ("macutils://dollars-find?path=/tmp/a.frm", .dollarsFind(path: "/tmp/a.frm")),
            ("macutils://encoding?path=/tmp/a.txt&to=windows1251", .convertEncoding(path: "/tmp/a.txt", .windows1251, from: nil)),
            ("macutils://encoding?path=/tmp/a.txt&to=utf8&from=windows1251", .convertEncoding(path: "/tmp/a.txt", .utf8, from: .windows1251)),
            ("macutils://line-endings?path=/tmp/a.txt&to=lf", .convertLineEndings(path: "/tmp/a.txt", .lf)),
        ]
        for (link, action) in cases {
            XCTAssertEqual(AppAction(url: try XCTUnwrap(URL(string: link))), action, link)
        }
        XCTAssertNil(AppAction(url: try XCTUnwrap(URL(string: "macutils://encoding?path=/tmp/a&to=ebcdic"))))
        XCTAssertNil(AppAction(url: try XCTUnwrap(URL(string: "macutils://encoding?path=/tmp/a&to=utf8&from=ebcdic"))))
        XCTAssertNil(AppAction(url: try XCTUnwrap(URL(string: "macutils://dollars-remove"))), "без файла")
    }

    /// Все ссылки страницы «Команды и ссылки» — настоящие действия, без повторов.
    func testCatalogLinksAreActions() throws {
        for item in AppAction.catalog {
            XCTAssertNotNil(AppAction(url: try XCTUnwrap(URL(string: item.link))), item.link)
        }
        XCTAssertEqual(Set(AppAction.catalog.map(\.link)).count, AppAction.catalog.count)
    }

    // MARK: - Та же функция, что горячая клавиша

    /// Регистрация каждой горячей клавиши зовёт `AppAction(hotKey:)` (функции — через `AppRouter`) — то же, что ссылка и «Команды».
    func testEveryHotKeyRunsTheSameAction() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var text = ""
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            where url.pathExtension == "swift" { text += try String(contentsOf: url, encoding: .utf8) }
        for action in HotKeyAction.allCases {
            XCTAssertTrue(text.contains("AppAction(hotKey: .\(action.rawValue)).run()")
                          || text.contains("AppRouter.shared.runHotKey(HotKeyID.\(action.rawValue))"), "горячая клавиша \(action.rawValue)")
        }
        XCTAssertEqual(AppAction(hotKey: .screenshot), .screenshot)
        XCTAssertEqual(AppAction(hotKey: .meeting), .meeting(.toggle))
        XCTAssertEqual(AppAction(hotKey: .textEditor), .editor(path: nil))
    }

    func testIntentsRunTheSameActions() async throws {
        let cases: [(any AppIntent, AppAction)] = [
            (OpenSettingsIntent(), .settings), (OpenToolsIntent(), .tools),
            (PinWindowIntent(), .pinWindow), (FocusIntent(), .focus), (ScreenshotIntent(), .screenshot),
            (RecognizeTextIntent(), .recognizeText), (OpenScreenshotsFolderIntent(), .screenshotsFolder), (QRIntent(), .qr),
            (ReadQRFromScreenIntent(), .qrScreen), (AnnotateIntent(), .annotate), (StopShareIntent(), .shareStop),
            (FixSelectedTextIntent(), .fixText), (LayoutFixIntent(), .layoutFix), (BreakIntent(), .breakNow),
            (ShelfIntent(), .shelf), (AppVolumeIntent(), .appVolume), (OpenDownloadsIntent(), .openDownloads),
            (SortDownloadsIntent(), .sortDownloads), (OpenEditorIntent(), .editor(path: nil)),
            (OpenPlayerIntent(), .player), (PlayerTogglePlayIntent(), .playerTogglePlay), (ContinueWatchingIntent(), .playerContinue),
        ]
        for (intent, action) in cases {
            ran = []
            _ = try await intent.perform()
            XCTAssertEqual(ran, [action], "\(type(of: intent))")
        }

        var snap = SnapWindowIntent(); snap.placement = .topRight
        var share = StartShareIntent(); share.source = .choose
        var watch = WatchShareIntent(); watch.code = "123 456 7890"
        var monitor = ViewerMonitorIntent(); monitor.number = 3
        var meeting = MeetingIntent(); meeting.command = .stop
        var warm = WarmScreenIntent(); warm.command = .preview
        var awake = KeepAwakeIntent(); awake.choice = .hours3
        let parameterized: [(any AppIntent, AppAction)] = [
            (snap, .snap(.topRight)), (share, .shareStart(screen: false)), (watch, .watch(code: "123 456 7890")),
            (monitor, .viewerMonitor(3)), (meeting, .meeting(.stop)), (warm, .warmPreview), (awake, .keepAwake(.hours3)),
        ]
        for (intent, action) in parameterized {
            ran = []
            _ = try await intent.perform()
            XCTAssertEqual(ran, [action], "\(type(of: intent))")
        }

        var badWatch = WatchShareIntent(); badWatch.code = "12"
        do { _ = try await badWatch.perform(); XCTFail("ID не из 10 цифр") } catch is ShortcutError {}
    }

    // MARK: - «Убрать значения $» и «Найти значения $» без окна — на фикстурах тестировщика

    private struct Expected: Decodable {
        let files: [String: Fixture]
        let skip_default_n: Int
    }

    private struct Fixture: Decodable {
        let bytes_sha256: String
        let occurrences: [Occurrence]
        let strip_skip3_bytes_sha256: String
        let strip_all_bytes_sha256: String
        let strip_skip3_text: String
        let strip_all_text: String
    }

    private struct Occurrence: Decodable { let value: String; let line: Int }

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func copyFixture(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: TextEditorAcceptanceTests.folder.appendingPathComponent(name), to: target)
        return target
    }

    func testRemoveDollarValuesInFileMatchesEditorBytes() throws {
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: TextEditorAcceptanceTests.folder.appendingPathComponent("expected.json")))
        let skip = expected.skip_default_n
        XCTAssertGreaterThan(expected.files.count, 10)
        for (name, fixture) in expected.files.sorted(by: { $0.key < $1.key }) {
            for (mode, skipFirst, text, sha) in [("пропуск \(skip)", Optional(skip), fixture.strip_skip3_text, fixture.strip_skip3_bytes_sha256),
                                                ("без пропуска", nil, fixture.strip_all_text, fixture.strip_all_bytes_sha256)] {
                let url = try copyFixture(name)
                let original = try Data(contentsOf: url)
                XCTAssertEqual(Self.sha256(original), fixture.bytes_sha256, name)
                let wasBalanced = DollarMarks.unbalancedBraces(in: try XCTUnwrap(EditorDocument(data: original).decodedText) as NSString) == 0
                let breaks = wasBalanced && DollarMarks.unbalancedBraces(in: text as NSString) > 0
                do {
                    let removed = try FileTools.removeDollarValues(in: url, skipFirst: skipFirst)
                    XCTAssertFalse(breaks, "\(name), \(mode): баланс {} ломается — запись должна быть отклонена")
                    XCTAssertEqual(Self.sha256(try Data(contentsOf: url)), sha, "\(name), \(mode): байты как у «Убрать значения» в редакторе")
                    let values = fixture.occurrences.dropFirst(skipFirst ?? 0).filter { !$0.value.isEmpty }
                    XCTAssertEqual(removed, values.count, "\(name), \(mode): сколько убрано")
                } catch FileTools.Failure.brokenBraces {
                    XCTAssertTrue(breaks, "\(name), \(mode): отказ только при поломке баланса")
                    XCTAssertEqual(try Data(contentsOf: url), original, "\(name), \(mode): при отказе файл не меняется")
                }
            }
        }
    }

    func testFindDollarValuesInFile() throws {
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: TextEditorAcceptanceTests.folder.appendingPathComponent("expected.json")))
        for (name, fixture) in expected.files {
            let found = try FileTools.findDollarValues(in: try copyFixture(name), skipFirst: 3)
            XCTAssertEqual(found.map(\.line), fixture.occurrences.map(\.line), name)
            XCTAssertEqual(found.map(\.value), fixture.occurrences.map { $0.value.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }, name)
            XCTAssertEqual(found.map(\.skipped), fixture.occurrences.indices.map { $0 < 3 }, name)
        }
    }

    /// Баланс `{}` был, а после удаления пропал бы — файл не меняется (в редакторе это видно и отменяется, здесь — нет).
    func testRemovalRefusedWhenBracesWouldBreak() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("braces.frm")
        // Баланс есть; значение — до конца строки, вместе с «}» — после удаления «{» осталась бы без пары.
        let original = Data("{\\rtf1 Name: $A}\r\n".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try FileTools.removeDollarValues(in: url, skipFirst: nil)) { error in
            XCTAssertEqual(error as? FileTools.Failure, .brokenBraces(1))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testRemoveIntentReturnsCountAndKeepsBytesOutsideValues() async throws {
        let url = try copyFixture("02-four-dollars.frm")
        var intent = RemoveDollarValuesIntent()
        intent.file = IntentFile(fileURL: url, filename: url.lastPathComponent)
        intent.skip = true
        intent.skipCount = 3
        let result = try await intent.perform()
        XCTAssertEqual(result.value, 1)
        XCTAssertEqual(ran, [], "действие с файлом — без окна и без AppAction")
    }

    // MARK: - Кодировка и переводы строк

    func testConvertEncodingAndLineEndings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.txt")
        try Data("Привет\r\nмир\r\n".utf8).write(to: url)
        XCTAssertTrue(try FileTools.convertEncoding(of: url, to: .windows1251))
        XCTAssertEqual(try Data(contentsOf: url), TextEncoding.windows1251.encode("Привет\r\nмир\r\n"))
        // Windows-1251 без \ansicpg автоопределение читает как Windows-1252 — кодировку файла можно указать.
        XCTAssertFalse(try FileTools.convertEncoding(of: url, to: .windows1251, from: .windows1251), "уже в этой кодировке")
        XCTAssertTrue(try FileTools.convertLineEndings(of: url, to: .lf))
        XCTAssertEqual(try Data(contentsOf: url), TextEncoding.windows1251.encode("Привет\nмир\n"), "байты кириллицы не тронуты")
        XCTAssertFalse(try FileTools.convertLineEndings(of: url, to: .lf))
        // Символов нет в кодировке — ошибка, файл прежний.
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try FileTools.convertEncoding(of: url, to: .iso8859_1, from: .windows1251))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try FileTools.convertEncoding(of: url, to: .utf8, from: .windows1251))
        XCTAssertEqual(try Data(contentsOf: url), Data("Привет\nмир\n".utf8))
    }
}
