import AppKit
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

func isOnMainThread() -> Bool { pthread_main_np() != 0 }

/// S1 (уникальные имена), S2 (кодирование и буфер), S4 (склейка на отдельной очереди).
final class ScreenshotPipelineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShotPipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func solid(_ width: Int, _ height: Int, gray: CGFloat = 0.5) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: S1

    func testNumberedName() {
        XCTAssertEqual(ScreenshotEncoding.numberedName("Снимок экрана 2026-10-15 в 12.00.00.png", index: 1), "Снимок экрана 2026-10-15 в 12.00.00.png")
        XCTAssertEqual(ScreenshotEncoding.numberedName("a.png", index: 2), "a (2).png")
        XCTAssertEqual(ScreenshotEncoding.numberedName("a.png", index: 10), "a (10).png")
        XCTAssertEqual(ScreenshotEncoding.numberedName("noext", index: 3), "noext (3)")
        XCTAssertEqual(ScreenshotEncoding.numberedName("v1.2.png", index: 2), "v1.2 (2).png")
    }

    func testSecondShotInTheSameSecondDoesNotOverwriteTheFirst() throws {
        let url = root.appendingPathComponent("Снимок.png")
        let first = try ScreenshotEncoding.write(Data("первый".utf8), to: url)
        let second = try ScreenshotEncoding.write(Data("второй".utf8), to: url)
        let third = try ScreenshotEncoding.write(Data("третий".utf8), to: url)
        XCTAssertEqual([first.lastPathComponent, second.lastPathComponent, third.lastPathComponent],
                       ["Снимок.png", "Снимок (2).png", "Снимок (3).png"])
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "первый")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "второй")
    }

    func testExistingGapsAreSkippedNotOverwritten() throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("a.png"))
        try Data("y".utf8).write(to: root.appendingPathComponent("a (2).png"))
        let written = try ScreenshotEncoding.write(Data("new".utf8), to: root.appendingPathComponent("a.png"))
        XCTAssertEqual(written.lastPathComponent, "a (3).png")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a (2).png"), encoding: .utf8), "y")
    }

    func testConcurrentWritesToTheSameNameKeepEveryFile() throws {
        let url = root.appendingPathComponent("race.png")
        let count = 40
        let lock = NSLock()
        var results: [URL] = [], errors = 0
        DispatchQueue.concurrentPerform(iterations: count) { i in
            do {
                let written = try ScreenshotEncoding.write(Data("shot-\(i)".utf8), to: url)
                lock.lock(); results.append(written); lock.unlock()
            } catch { lock.lock(); errors += 1; lock.unlock() }
        }
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(Set(results.map(\.path)).count, count, "каждый снимок получил своё имя")
        let contents = try results.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(Set(contents).count, count, "ни один снимок не затёрт другим")
    }

    func testWriteToMissingFolderThrowsAndCreatesNothing() {
        let url = root.appendingPathComponent("нет-папки/a.png")
        XCTAssertThrowsError(try ScreenshotEncoding.write(Data("x".utf8), to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriteGivesUpAfterLimitInsteadOfOverwriting() throws {
        for name in ["a.png", "a (2).png", "a (3).png"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        XCTAssertThrowsError(try ScreenshotEncoding.write(Data("new".utf8), to: root.appendingPathComponent("a.png"), limit: 3))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.png"), encoding: .utf8), "a.png")
    }

    // MARK: S2

    func testPNGEncodesToDecodableImage() throws {
        let data = try XCTUnwrap(ScreenshotEncoding.png(solid(64, 32)))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "сигнатура PNG")
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual([image.pixelsWide, image.pixelsHigh], [64, 32])
    }

    func testEncodingWorksOffTheMainThread() async throws {
        let boxed = UncheckedSendable(solid(40, 40))
        let result = await Task.detached { () -> (Bool, Bool) in (isOnMainThread(), ScreenshotEncoding.png(boxed.value) != nil) }.value
        XCTAssertFalse(result.0)
        XCTAssertTrue(result.1)
    }

    func testTIFFIsProducedOnlyWhenRequested() throws {
        let provider = LazyTIFFProvider(solid(20, 10))
        let item = NSPasteboardItem()
        XCTAssertNil(item.data(forType: .tiff))
        provider.pasteboard(nil, item: item, provideDataForType: .tiff)
        let tiff = try XCTUnwrap(item.data(forType: .tiff))
        XCTAssertNotNil(NSBitmapImageRep(data: tiff))
        let other = NSPasteboardItem()
        provider.pasteboard(nil, item: other, provideDataForType: .string)
        XCTAssertNil(other.data(forType: .tiff), "чужой тип провайдер не обслуживает")
    }

    // MARK: S4

    private func page(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SeededGenerator(seed: 7)
        var y = 20
        while y < height - 40 {
            var x = 30
            while x < width - 60 {
                let w = Int.random(in: 8...60, using: &generator)
                context.setFillColor(CGColor(gray: 0.1, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: w, height: 14))
                x += w + 10
            }
            y += Int.random(in: 24...36, using: &generator)
        }
        return context.makeImage()!
    }

    func testWorkerGivesTheSameResultsAsSynchronousStitcher() async throws {
        let source = page(width: 600, height: 2400)
        var direct = Stitcher()
        let worker = StitchWorker()
        var offset = 0
        while offset + 700 <= source.height {
            let frame = source.cropping(to: CGRect(x: 0, y: offset, width: source.width, height: 700))!
            let expected = direct.add(frame)
            let (result, height, isFull) = await worker.add(frame)
            XCTAssertEqual(result, expected, "offset \(offset)")
            XCTAssertEqual(height, direct.height)
            XCTAssertEqual(isFull, direct.isFull)
            offset += 150
        }
        let made = await worker.makeImage()
        let image = try XCTUnwrap(made)
        XCTAssertEqual(image.height, direct.height)
        XCTAssertEqual(image.width, 600)
    }

    func testWorkerRunsOffTheMainThreadAndKeepsOrderUnderLoad() async throws {
        let source = page(width: 400, height: 1800)
        let worker = StitchWorker()
        // Кадры отправляются подряд, не дожидаясь друг друга: очередь обязана сохранить порядок.
        let frames = stride(from: 0, through: 1100, by: 100).map { source.cropping(to: CGRect(x: 0, y: $0, width: 400, height: 700))! }
        var heights: [Int] = []
        for frame in frames { heights.append(await worker.add(frame).1) }
        XCTAssertEqual(heights, heights.sorted(), "высота не убывает: кадры склеены по порядку")
        XCTAssertGreaterThan(heights.last ?? 0, 700)
        let onMain = await Task.detached { isOnMainThread() }.value
        XCTAssertFalse(onMain)
    }

    func testWorkerWithoutFramesHasNoImage() async {
        let image = await StitchWorker().makeImage()
        XCTAssertNil(image)
    }

    // MARK: MAJOR-1: порядок в буфере обмена

    func testOnlyTheLatestCopyMayWriteToClipboard() {
        var tickets = ClipboardTickets()
        let first = tickets.next(), second = tickets.next()
        XCTAssertFalse(tickets.isLatest(first), "более старое копирование результат в буфер не кладёт")
        XCTAssertTrue(tickets.isLatest(second))
        let third = tickets.next()
        XCTAssertFalse(tickets.isLatest(second))
        XCTAssertTrue(tickets.isLatest(third))
    }

    func testSlowFirstCopyDoesNotOverwriteFasterSecond() async {
        // Длинный снимок кодируется долго, обычный — быстро; в «буфере» должен остаться последний скопированный.
        var tickets = ClipboardTickets()
        var clipboard: String?
        let slow = tickets.next(), fast = tickets.next()
        let gate = tickets
        await withTaskGroup(of: (String, Int).self) { group in
            group.addTask { try? await Task.sleep(nanoseconds: 150_000_000); return ("длинный", slow) }
            group.addTask { try? await Task.sleep(nanoseconds: 10_000_000); return ("маленький", fast) }
            for await (name, ticket) in group where gate.isLatest(ticket) { clipboard = name }
        }
        XCTAssertEqual(clipboard, "маленький")
    }

    func testCopyThenSaveOnlyDoesNotInvalidateClipboardCopy() {
        // Сохранение в папку билет не берёт (ticket только у тех, кто пишет в буфер): иначе обычное «сохранить» отменяло бы копирование.
        var tickets = ClipboardTickets()
        let copy = tickets.next()
        XCTAssertTrue(tickets.isLatest(copy))
    }

    // MARK: N2: запись не оставляет обрезков

    func testWriteLeavesNoTemporaryFiles() throws {
        _ = try ScreenshotEncoding.write(Data("1".utf8), to: root.appendingPathComponent("s.png"))
        _ = try ScreenshotEncoding.write(Data("2".utf8), to: root.appendingPathComponent("s.png"))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(names, ["s (2).png", "s.png"], "временные файлы убраны")
    }

    func testWriteFailureKeepsFolderClean() {
        let folder = root.appendingPathComponent("нет")
        XCTAssertThrowsError(try ScreenshotEncoding.write(Data("x".utf8), to: folder.appendingPathComponent("a.png")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testWriteLimitLeavesNoTemporaryFile() throws {
        for name in ["a.png", "a (2).png"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        XCTAssertThrowsError(try ScreenshotEncoding.write(Data("n".utf8), to: root.appendingPathComponent("a.png"), limit: 2))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["a (2).png", "a.png"])
    }

    func testLazyTIFFProviderReportsWhenPasteboardIsDone() {
        let provider = LazyTIFFProvider(solid(8, 8))
        var finished = false
        provider.onFinish = { finished = true }
        provider.pasteboardFinishedWithDataProvider(NSPasteboard.withUniqueName())
        XCTAssertTrue(finished, "кадр можно освободить")
    }

    // MARK: MAJOR-A: тома без жёстких ссылок

    func testFallsBackToDirectWriteWhenLinksAreNotSupported() throws {
        for code in [ENOTSUP, EPERM, EXDEV, EMLINK, ENOSYS, EACCES] {
            let folder = root.appendingPathComponent("vol-\(code)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let written = try ScreenshotEncoding.write(Data("снимок".utf8), to: folder.appendingPathComponent("s.png"), linker: { _, _ in code })
            XCTAssertEqual(written.lastPathComponent, "s.png", "errno \(code)")
            XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "снимок")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["s.png"], "временный файл убран, errno \(code)")
        }
    }

    func testFallbackNeverOverwritesAndNumbersTheName() throws {
        let unsupported: ScreenshotEncoding.Linker = { _, _ in ENOTSUP }
        let url = root.appendingPathComponent("s.png")
        let first = try ScreenshotEncoding.write(Data("1".utf8), to: url, linker: unsupported)
        let second = try ScreenshotEncoding.write(Data("2".utf8), to: url, linker: unsupported)
        let third = try ScreenshotEncoding.write(Data("3".utf8), to: url, linker: unsupported)
        XCTAssertEqual([first, second, third].map(\.lastPathComponent), ["s.png", "s (2).png", "s (3).png"])
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["s (2).png", "s (3).png", "s.png"])
    }

    func testFallbackAfterSomeNamesAreTaken() throws {
        // Ссылка занята на первых именах (EEXIST), затем том оказывается без ссылок: продолжаем с того же номера.
        try Data("a".utf8).write(to: root.appendingPathComponent("s.png"))
        var calls = 0
        let linker: ScreenshotEncoding.Linker = { _, _ in calls += 1; return calls == 1 ? EEXIST : ENOTSUP }
        let written = try ScreenshotEncoding.write(Data("new".utf8), to: root.appendingPathComponent("s.png"), linker: linker)
        XCTAssertEqual(written.lastPathComponent, "s (2).png")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("s.png"), encoding: .utf8), "a")
    }

    func testFallbackSkipsExistingFilesLikeTheMainPath() throws {
        for name in ["s.png", "s (2).png"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let written = try ScreenshotEncoding.write(Data("n".utf8), to: root.appendingPathComponent("s.png"), linker: { _, _ in ENOTSUP })
        XCTAssertEqual(written.lastPathComponent, "s (3).png")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("s (2).png"), encoding: .utf8), "s (2).png")
    }

    func testFallbackGivesUpAtLimitWithoutOverwriting() throws {
        for name in ["s.png", "s (2).png"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        XCTAssertThrowsError(try ScreenshotEncoding.write(Data("n".utf8), to: root.appendingPathComponent("s.png"), limit: 2, linker: { _, _ in ENOTSUP }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["s (2).png", "s.png"])
    }

    func testOtherLinkErrorsStillFailInsteadOfSilentlyDegrading() {
        for code in [ENOSPC, EIO, ENOENT, EROFS] {
            XCTAssertThrowsError(try ScreenshotEncoding.write(Data("x".utf8), to: root.appendingPathComponent("e-\(code).png"), linker: { _, _ in code }), "errno \(code)") { error in
                XCTAssertEqual((error as NSError).code, Int(code))
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "временных файлов не осталось")
    }

    func testConcurrentFallbackWritesKeepEveryFile() throws {
        let url = root.appendingPathComponent("race.png")
        let lock = NSLock()
        var results: [URL] = [], errors = 0
        DispatchQueue.concurrentPerform(iterations: 30) { i in
            do {
                let written = try ScreenshotEncoding.write(Data("shot-\(i)".utf8), to: url, linker: { _, _ in ENOTSUP })
                lock.lock(); results.append(written); lock.unlock()
            } catch { lock.lock(); errors += 1; lock.unlock() }
        }
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(Set(results.map(\.path)).count, 30)
        XCTAssertEqual(Set(try results.map { try String(contentsOf: $0, encoding: .utf8) }).count, 30, "ни один снимок не затёрт")
    }
}
