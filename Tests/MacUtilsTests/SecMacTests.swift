import CryptoKit
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUCutPaste
@testable import MUDownloadsSorter
@testable import MUMeetings
@testable import MUScreenShare
@testable import MUUpdate

/// Безопасность Mac-приложения (аудит 28.10): ссылки macutils://, разбор документов, пути встреч, список Finder, архив обновления, имя, модели.
@MainActor
final class SecMacTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecMac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        AppAction.interceptor = nil
        AppAction.linkConfirmer = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: M2 + L14

    private func link(_ text: String, allow: Bool) throws -> (ran: [AppAction], asked: [String]) {
        var ran: [AppAction] = [], asked: [String] = []
        AppAction.interceptor = { ran.append($0) }
        AppAction.linkConfirmer = { title, _ in asked.append(title); return allow }
        try XCTUnwrap(AppAction(url: try XCTUnwrap(URL(string: text)))).runFromLink()
        return (ran, asked)
    }

    func testLinksThatStartThingsAskFirstAndDoNothingOnCancel() throws {
        for text in ["macutils://share-start?screen", "macutils://share", "macutils://share?screen", "macutils://meeting-start",
                     "macutils://meeting", "macutils://watch?1234567890", "macutils://player-open?path=/tmp/a.mp4"] {
            let denied = try link(text, allow: false)
            XCTAssertEqual(denied.asked.count, 1, text)
            XCTAssertTrue(denied.ran.isEmpty, "без подтверждения ничего не стартует: \(text)")
            let allowed = try link(text, allow: true)
            XCTAssertEqual(allowed.ran.count, 1, text)
        }
    }

    func testScreenFlagFromLinkDoesNotSkipThePicker() throws {
        XCTAssertEqual(try link("macutils://share-start?screen", allow: true).ran, [.shareStart(screen: false)])
        XCTAssertEqual(try link("macutils://share?screen", allow: true).ran, [.shareToggle(screen: false)])
        // Вызов не из ссылки (меню, «Команды») — как раньше.
        var ran: [AppAction] = []
        AppAction.interceptor = { ran.append($0) }
        AppAction.shareStart(screen: true).run()
        XCTAssertEqual(ran, [.shareStart(screen: true)])
    }

    func testStopsAndOtherLinksNeedNoQuestion() throws {
        for text in ["macutils://share-stop", "macutils://meeting-stop", "macutils://settings", "macutils://tools"] {
            let result = try link(text, allow: false)
            XCTAssertTrue(result.asked.isEmpty, text)
            XCTAssertEqual(result.ran.count, 1, text)
        }
    }

    // MARK: M5

    func testOnlyPlainAndRichTextAreParsed() throws {
        let html = directory.appendingPathComponent("a.html")
        try Data("<html><body><img src='http://127.0.0.1:9/x.png'>Привет и ещё слова для длины</body></html>".utf8).write(to: html)
        let docx = directory.appendingPathComponent("a.docx"), odt = directory.appendingPathComponent("a.odt")
        let pages = directory.appendingPathComponent("a.pages"), doc = directory.appendingPathComponent("a.doc")
        for url in [docx, odt, pages, doc] { try Data("PK text".utf8).write(to: url) }
        for url in [html, docx, odt, pages, doc] {
            XCTAssertNil(DocumentTagger.attributedText(url), url.lastPathComponent)
            XCTAssertEqual(DocumentTagger.extractText(url, limit: 100), "", url.lastPathComponent)
        }
        let plain = directory.appendingPathComponent("a.txt")
        try Data("Hello   plain\ntext".utf8).write(to: plain)
        XCTAssertEqual(DocumentTagger.extractText(plain, limit: 100), "Hello plain text")
        let rtf = directory.appendingPathComponent("a.rtf")
        try Data(#"{\rtf1\ansi Hello rich}"#.utf8).write(to: rtf)
        XCTAssertEqual(DocumentTagger.extractText(rtf, limit: 100), "Hello rich")
        XCTAssertFalse(DocumentTagger.textExtensions.contains("html"))
        XCTAssertFalse(DocumentTagger.textExtensions.contains("docx"))
    }

    // MARK: L9

    func testMeetingFolderNames() throws {
        let root = directory.appendingPathComponent("Встречи")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(MeetingRecorder.folder(named: "2026-10-07 20.30", root: root)?.lastPathComponent, "2026-10-07 20.30")
        for bad in ["", ".", "..", "../x", "a/b", "../../etc", "x/../..", "/etc"] {
            XCTAssertNil(MeetingRecorder.folder(named: bad, root: root), bad)
        }
        // Символическая ссылка внутри корня на чужую папку.
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertNil(MeetingRecorder.folder(named: "link", root: root))
    }

    // MARK: L12

    func testFinderListKeepsNewlineNamesInOnePath() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(string: "/tmp/a\nb.txt"), at: 1)
        list.insert(NSAppleEventDescriptor(string: "/tmp/c.txt"), at: 2)
        XCTAssertEqual(FinderScript.paths(from: list).map(\.path), ["/tmp/a\nb.txt", "/tmp/c.txt"])
        XCTAssertEqual(FinderScript.paths(from: NSAppleEventDescriptor.list()), [])
    }

    // MARK: L10

    func testUpdateArchiveLimits() throws {
        let listing = """
        Archive:  update.zip
          Length      Date    Time    Name
        ---------  ---------- -----   ----
              100  10-28-2026 10:00   Mac Utils.app/a
        ---------                     -------
             5000                     12 files
        """
        XCTAssertEqual(Updater.unpackedTotal(fromListing: listing), 5000)
        XCTAssertNoThrow(try Updater.checkArchive(zipBytes: 100_000_000, listing: listing))
        XCTAssertThrowsError(try Updater.checkArchive(zipBytes: Updater.maxZipBytes + 1, listing: listing))
        XCTAssertThrowsError(try Updater.checkArchive(zipBytes: 1, listing: listing.replacingOccurrences(of: "5000", with: "9000000000")))
        XCTAssertThrowsError(try Updater.checkArchive(zipBytes: 1, listing: nil))
    }

    // MARK: L8

    func testShareNameIsNotTheComputerName() {
        XCTAssertEqual(ShareCode.displayName(setting: nil), "Mac")
        XCTAssertEqual(ShareCode.displayName(setting: "  "), "Mac")
        XCTAssertEqual(ShareCode.displayName(setting: " Анна "), "Анна")
        XCTAssertEqual(ShareCode.displayName(setting: String(repeating: "я", count: 100)).count, 60)
    }

    // MARK: L13

    func testWhisperModelsArePinnedAndChecksumIsStreamed() throws {
        XCTAssertFalse(Whisper.modelURL.absoluteString.contains("/main/"))
        XCTAssertTrue(Whisper.modelURL.absoluteString.contains(Whisper.modelRevision))
        XCTAssertTrue(Whisper.vadURL.absoluteString.contains(Whisper.vadRevision))
        XCTAssertEqual(Whisper.modelSHA256.count, 64)
        XCTAssertEqual(Whisper.vadSHA256.count, 64)
        let file = directory.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try Whisper.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
