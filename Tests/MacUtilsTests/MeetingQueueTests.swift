import XCTest
@testable import MacUtils
@testable import MUMeetings
@testable import MUAudio

/// Очередь расшифровки на диске (MAJOR-1): метка «В очереди», порядок, попытки, план восстановления при запуске.
final class MeetingQueueTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("meet-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func meeting(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testMarkerRoundTripAndRemoval() throws {
        let folder = try meeting("2026-10-16 10.00")
        XCTAssertNil(MeetingFiles.queueMarker(in: folder))
        MeetingFiles.writeQueueMarker(in: folder, reportOnly: false, now: Date(timeIntervalSince1970: 100))
        let marker = try XCTUnwrap(MeetingFiles.queueMarker(in: folder))
        XCTAssertEqual(marker.reportOnly, false)
        XCTAssertEqual(marker.queuedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(marker.attempts, 0)
        MeetingFiles.removeQueueMarker(in: folder)
        XCTAssertNil(MeetingFiles.queueMarker(in: folder))
        XCTAssertEqual(MeetingFiles.queued(in: root), [])
    }

    /// Повторная постановка не сбрасывает время и попытки; полная расшифровка важнее «только отчёта».
    func testRequeueKeepsOrderAndFullJobWins() throws {
        let folder = try meeting("A")
        MeetingFiles.writeQueueMarker(in: folder, reportOnly: true, now: Date(timeIntervalSince1970: 100))
        MeetingFiles.noteQueueAttempt(in: folder)
        MeetingFiles.writeQueueMarker(in: folder, reportOnly: false, now: Date(timeIntervalSince1970: 500))
        let marker = try XCTUnwrap(MeetingFiles.queueMarker(in: folder))
        XCTAssertEqual(marker.queuedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(marker.attempts, 1)
        XCTAssertFalse(marker.reportOnly)
        MeetingFiles.writeQueueMarker(in: folder, reportOnly: true)
        XCTAssertFalse(try XCTUnwrap(MeetingFiles.queueMarker(in: folder)).reportOnly, "«только отчёт» не перебивает полную")
    }

    func testQueuedComeBackInQueueOrder() throws {
        let late = try meeting("Б поздняя"), early = try meeting("В ранняя"), none = try meeting("А без метки")
        MeetingFiles.writeQueueMarker(in: late, reportOnly: false, now: Date(timeIntervalSince1970: 300))
        MeetingFiles.writeQueueMarker(in: early, reportOnly: true, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(MeetingFiles.queued(in: root).map(\.folder.lastPathComponent), [early, late].map(\.lastPathComponent))
        XCTAssertNil(MeetingFiles.queueMarker(in: none))
    }

    func testMarkerIsNotWrittenIntoMissingFolder() {
        let gone = root.appendingPathComponent("удалена")
        MeetingFiles.writeQueueMarker(in: gone, reportOnly: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), "удалённая встреча не воскресает пустой папкой")
    }

    func testBrokenMarkerReadsAsDefaults() throws {
        let folder = try meeting("Битая")
        try Data("{\"attempts\":\"много\"}".utf8).write(to: folder.appendingPathComponent(MeetingFiles.queueMarkerName))
        let marker = try XCTUnwrap(MeetingFiles.queueMarker(in: folder))
        XCTAssertEqual(marker.attempts, 0)
        XCTAssertFalse(marker.reportOnly)
        try Data("мусор".utf8).write(to: folder.appendingPathComponent(MeetingFiles.queueMarkerName))
        XCTAssertNil(MeetingFiles.queueMarker(in: folder))
    }

    // MARK: - План восстановления

    private func job(_ name: String, attempts: Int = 0, reportOnly: Bool = false) -> MeetingFiles.QueuedJob {
        MeetingFiles.QueuedJob(folder: root.appendingPathComponent(name), reportOnly: reportOnly,
                               queuedAt: Date(timeIntervalSince1970: 1), attempts: attempts)
    }

    func testQueuedJobsResumeWithoutButtonAndRestoredAreOffered() {
        let restored = [root.appendingPathComponent("Оборванная"), root.appendingPathComponent("В очереди")]
        let plan = MeetingRecovery.plan(restored: restored, queued: [job("В очереди"), job("Ещё одна", reportOnly: true)],
                                        hasTranscript: { _ in false })
        XCTAssertEqual(plan.resume.map(\.folder.lastPathComponent), ["В очереди", "Ещё одна"])
        XCTAssertEqual(plan.offer.map(\.lastPathComponent), ["Оборванная"], "стоящая в очереди не предлагается второй раз")
        let message = try? XCTUnwrap(plan.message)
        XCTAssertTrue(message?.contains("Восстановлено оборванных записей встреч: 2") == true)
        XCTAssertTrue(message?.contains("ожидавших в очереди: 2") == true)
    }

    /// Обработка обрывалась дважды (падение на этой встрече) — сама больше не запускается, только по кнопке.
    func testRepeatedlyCrashingJobIsNotResumedAutomatically() {
        let plan = MeetingRecovery.plan(restored: [], queued: [job("Падает", attempts: 2), job("Нормальная", attempts: 1)],
                                        hasTranscript: { _ in false })
        XCTAssertEqual(plan.resume.map(\.folder.lastPathComponent), ["Нормальная"])
        XCTAssertEqual(plan.offer.map(\.lastPathComponent), ["Падает"])
        XCTAssertTrue(plan.message?.contains("Не расшифровались автоматически") == true)
    }

    func testAlreadyTranscribedRestoredMeetingIsNotOffered() {
        let folder = root.appendingPathComponent("С расшифровкой")
        let plan = MeetingRecovery.plan(restored: [folder], queued: [], hasTranscript: { _ in true })
        XCTAssertEqual(plan.offer, [])
        XCTAssertEqual(plan.message, "Восстановлена оборванная запись встречи «С расшифровкой»")
    }

    func testNothingToReport() {
        XCTAssertEqual(MeetingRecovery.plan(restored: [], queued: [], hasTranscript: { _ in false }),
                       MeetingRecovery.Plan(resume: [], offer: [], message: nil))
    }

    // MARK: - Выравнивание дорожек (N1)

    func testPaddingToLongestTrack() {
        XCTAssertEqual(MeetingAlignment.padding(written: 9.5, longest: 10), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MeetingAlignment.padding(written: 10, longest: 10), 0)
        XCTAssertEqual(MeetingAlignment.padding(written: 9.97, longest: 10), 0, "меньше 50 мс — не дописываем")
    }
}
