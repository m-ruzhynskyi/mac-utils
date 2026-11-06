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

    func testToggleLinksAskOnlyWhenTheyStart() throws {
        defer { AppAction.sharingNow = { ScreenShare.shared.isLive }; AppAction.recordingNow = { false } }
        AppAction.sharingNow = { true }
        for text in ["macutils://share", "macutils://share-start"] {
            let result = try link(text, allow: false)
            XCTAssertTrue(result.asked.isEmpty, "трансляция идёт — \(text) без вопроса")
            XCTAssertEqual(result.ran.count, 1, text)
        }
        AppAction.sharingNow = { false }
        XCTAssertEqual(try link("macutils://share", allow: false).asked.count, 1)
        AppAction.recordingNow = { true }
        let stop = try link("macutils://meeting", allow: false)
        XCTAssertTrue(stop.asked.isEmpty)
        XCTAssertEqual(stop.ran, [.meeting(.toggle)])
        AppAction.recordingNow = { false }
        XCTAssertEqual(try link("macutils://meeting", allow: false).asked.count, 1)
        XCTAssertEqual(try link("macutils://meeting-start", allow: false).asked.count, 1)
    }

    func testShareDropLinkExistsOnlyInDebugBuilds() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacUtils/App/AppDelegate.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let drop = try XCTUnwrap(source.range(of: "case \"share-drop\""))
        let before = source[..<drop.lowerBound]
        let opened = try XCTUnwrap(before.range(of: "#if DEBUG", options: .backwards))
        XCTAssertNil(source[opened.upperBound..<drop.lowerBound].range(of: "#endif"), "share-drop внутри #if DEBUG")
    }

    func testStopsAndOtherLinksNeedNoQuestion() throws {
        for text in ["macutils://share-stop", "macutils://meeting-stop", "macutils://settings", "macutils://tools"] {
            let result = try link(text, allow: false)
            XCTAssertTrue(result.asked.isEmpty, text)
            XCTAssertEqual(result.ran.count, 1, text)
        }
    }

    // MARK: M5

    func testDocumentsAreParsedOnlyWithExplicitTypes() throws {
        let html = directory.appendingPathComponent("a.html")
        try Data("<html><body><img src='http://127.0.0.1:9/x.png'>Привет и ещё слова для длины</body></html>".utf8).write(to: html)
        let pages = directory.appendingPathComponent("a.pages"), doc = directory.appendingPathComponent("a.doc")
        for url in [pages, doc] { try Data("PK text".utf8).write(to: url) }
        for url in [html, pages, doc] {
            XCTAssertNil(DocumentTagger.attributedText(url), url.lastPathComponent)
            XCTAssertEqual(DocumentTagger.extractText(url, limit: 100), "", url.lastPathComponent)
        }
        XCTAssertFalse(DocumentTagger.textExtensions.contains("html"))
        XCTAssertEqual(DocumentTagger.documentTypes["docx"], .officeOpenXML)
        XCTAssertEqual(DocumentTagger.documentTypes["odt"], .openDocument)
        // docx и odt — настоящие файлы, собранные системой: читаются с явным типом.
        let sample = NSAttributedString(string: "Hello document text for the tagger")
        for (ext, type) in [("docx", NSAttributedString.DocumentType.officeOpenXML), ("odt", .openDocument)] {
            let data = try sample.data(from: NSRange(location: 0, length: sample.length), documentAttributes: [.documentType: type])
            let url = directory.appendingPathComponent("a.\(ext)")
            try data.write(to: url)
            XCTAssertEqual(DocumentTagger.extractText(url, limit: 100), "Hello document text for the tagger", ext)
        }
        // docx, на самом деле html: с явным типом он не разбирается как html.
        let fake = directory.appendingPathComponent("fake.docx")
        try Data("<html><body><img src='http://127.0.0.1:9/x.png'>text</body></html>".utf8).write(to: fake)
        XCTAssertEqual(DocumentTagger.extractText(fake, limit: 100), "")
        let plain = directory.appendingPathComponent("a.txt")
        try Data("Hello   plain\ntext".utf8).write(to: plain)
        XCTAssertEqual(DocumentTagger.extractText(plain, limit: 100), "Hello plain text")
        let rtf = directory.appendingPathComponent("a.rtf")
        try Data(#"{\rtf1\ansi Hello rich}"#.utf8).write(to: rtf)
        XCTAssertEqual(DocumentTagger.extractText(rtf, limit: 100), "Hello rich")
    }

    func testPlainTextInOtherEncodings() throws {
        let russian = "Договор поставки между сторонами"
        let cp1251 = directory.appendingPathComponent("win.txt")
        try XCTUnwrap(russian.data(using: .windowsCP1251)).write(to: cp1251)
        XCTAssertEqual(DocumentTagger.extractText(cp1251, limit: 100), russian)
        let utf16 = directory.appendingPathComponent("u16.txt")
        try XCTUnwrap(russian.data(using: .utf16)).write(to: utf16)
        XCTAssertEqual(DocumentTagger.extractText(utf16, limit: 100), russian)
        // UTF-8, обрезанный на середине знака (читаем только начало файла).
        var cut = Data(russian.utf8)
        cut.removeLast()
        XCTAssertEqual(DocumentTagger.decodePlain(cut), String(russian.dropLast()))
        XCTAssertEqual(DocumentTagger.decodePlain(Data("plain ascii".utf8)), "plain ascii")
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

    func testShareNameSettingHasAFieldAndALimit() throws {
        XCTAssertEqual(ShareCode.maxNameLength, 60)
        XCTAssertEqual(Pref.shareName, "shareName")
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MUScreenShare/ScreenShare.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("@AppStorage(Pref.shareName)"))
        XCTAssertTrue(source.contains("Как вас видят зрители и ведущий"))
    }

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
