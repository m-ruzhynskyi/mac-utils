import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUScreenShare
@testable import MUScreenshot

/// 30.10: ⌘⇧X перестал работать. «Обновить и перезапустить» во время эфира вызвал `NSApp.terminate` прямо из задачи
/// главного актора; ответ `.terminateLater` закрутил вложенный цикл, который главную очередь не разбирает, — задачи
/// завершения, снимки, тосты и переподключение трансляции встали навсегда.
@MainActor
final class ShotStuckTests: XCTestCase {
    // MARK: - Причина и починка выхода

    /// Причина: вложенный цикл событий внутри блока главной очереди её не разбирает (так висел `.terminateLater`).
    func testNestedRunLoopInsideMainQueueBlockStarvesMainQueue() {
        let done = expectation(description: "блок главной очереди")
        var drained = false
        DispatchQueue.main.async {
            DispatchQueue.main.async { drained = true }
            Self.spin(until: { drained }, seconds: 0.3)
            XCTAssertFalse(drained, "главная очередь не разбирается, пока выполняется её же блок")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    /// Починка: выход откладывается в блок цикла событий — там вложенный цикл главную очередь разбирает.
    func testRunLoopBlockLetsNestedLoopDrainMainQueue() {
        let done = expectation(description: "блок цикла событий")
        var drained = false
        DispatchQueue.main.async {
            AppTermination.onMainRunLoop {
                DispatchQueue.main.async { drained = true }
                Self.spin(until: { drained }, seconds: 2)
                XCTAssertTrue(drained, "задачи главного актора выполняются во время ожидания выхода")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
    }

    /// То же для задачи главного актора — именно так вызывался выход из `Updater.install`.
    func testRunLoopBlockFromMainActorTaskDrainsMainQueue() {
        let done = expectation(description: "задача главного актора")
        var drained = false
        Task { @MainActor in
            AppTermination.onMainRunLoop {
                Task { @MainActor in drained = true }
                Self.spin(until: { drained }, seconds: 2)
                XCTAssertTrue(drained)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
    }

    /// Выход из кода — только через `AppTermination`: прямой `NSApp.terminate` из задачи или блока главной очереди
    /// снова повесил бы приложение «на выходе». Кнопки «Выйти» вызывают его из события — это безопасно.
    func testTerminateGoesThroughAppTermination() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var found: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "AppTermination.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                guard code.contains("NSApp.terminate(") || code.contains("NSApplication.shared.terminate(") else { continue }
                if code.contains("Button(") { continue }
                found.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertEqual(found, [], "NSApp.terminate мимо AppTermination.terminate()")
    }

    private static func spin(until condition: () -> Bool, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    func testWindDownLimitCoversEveryWait() {
        XCTAssertEqual(BusyRegistry.windDownLimit([], silent: true), 10)
        // Тихо: 20 × 0,25 с на причину.
        XCTAssertEqual(BusyRegistry.windDownLimit([.broadcast], silent: true), 15)
        XCTAssertEqual(BusyRegistry.windDownLimit([.broadcast, .screenRecording], silent: true), 20)
        // С вопросом: запись экрана до 150 с, встреча ещё 2,5 с на закрытие файла.
        XCTAssertEqual(BusyRegistry.windDownLimit([.screenRecording], silent: false), 160)
        XCTAssertEqual(BusyRegistry.windDownLimit([.meetingRecording], silent: false), 32.5)
        // Причины, которые не останавливаются, не ждутся.
        XCTAssertEqual(BusyRegistry.windDownLimit([.uninstalling, .meetingProcessing], silent: false), 10)
        XCTAssertLessThan(BusyRegistry.windDownStartGrace, BusyRegistry.windDownLimit([], silent: true))
    }

    // MARK: - Предел захвата

    func testTimeLimitAbandonsHungOperation() async {
        let started = Date()
        do {
            _ = try await TimeLimit.run(seconds: 0.2) { () async throws -> Int in
                // Как зависший ScreenCaptureKit: отмену не замечает.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }
            XCTFail("должен сработать предел")
        } catch {
            XCTAssertEqual(error as? TimeLimitExceeded, TimeLimitExceeded(seconds: 0.2))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "не ждём зависшую операцию")
    }

    func testTimeLimitPassesResultAndError() async throws {
        let value = try await TimeLimit.run(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
        struct Boom: Error {}
        do {
            _ = try await TimeLimit.run(seconds: 5) { () async throws -> Int in throw Boom() }
            XCTFail("ошибка операции должна дойти до вызывающего")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testTimeLimitIgnoresLateResult() async throws {
        do {
            _ = try await TimeLimit.run(seconds: 0.1) { () async throws -> Int in
                try? await Task.sleep(nanoseconds: 400_000_000)
                return 7
            }
            XCTFail("должен сработать предел")
        } catch {
            XCTAssertTrue(error is TimeLimitExceeded)
        }
        // Запоздавший результат не возобновляет продолжение второй раз (иначе — падение CheckedContinuation).
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - ⌘⇧X не теряется молча

    func testShotGateProceedsWhenIdle() {
        XCTAssertEqual(ShotGate.decide(capturingFor: nil, overlays: 0, visibleOverlays: 0, scroll: nil), .proceed(reset: []))
    }

    func testShotGateReportsLiveStates() {
        XCTAssertEqual(ShotGate.decide(capturingFor: 1, overlays: 0, visibleOverlays: 0, scroll: nil), .busy(.capturing))
        XCTAssertEqual(ShotGate.decide(capturingFor: nil, overlays: 2, visibleOverlays: 1, scroll: nil), .busy(.overlayOpen))
        XCTAssertEqual(ShotGate.decide(capturingFor: nil, overlays: 0, visibleOverlays: 0,
                                       scroll: .init(showing: true, age: 600)), .busy(.scrollCapture))
        // Длинный снимок только что начат и ещё ждёт ответа системы: панелей нет, но он не завис.
        XCTAssertEqual(ShotGate.decide(capturingFor: nil, overlays: 0, visibleOverlays: 0,
                                       scroll: .init(showing: false, age: 1)), .busy(.scrollCapture))
        XCTAssertNotNil(ShotGate.message(.capturing))
        XCTAssertNotNil(ShotGate.message(.scrollCapture))
        XCTAssertNil(ShotGate.message(.overlayOpen), "открытый оверлей поднимается — это и есть ответ на нажатие")
    }

    func testShotGateResetsStaleStates() {
        XCTAssertEqual(ShotGate.decide(capturingFor: ShotGate.staleCapture + 1, overlays: 0, visibleOverlays: 0, scroll: nil),
                       .proceed(reset: [.capture]))
        XCTAssertEqual(ShotGate.decide(capturingFor: nil, overlays: 1, visibleOverlays: 0, scroll: nil),
                       .proceed(reset: [.overlays]))
        XCTAssertEqual(ShotGate.decide(capturingFor: nil, overlays: 0, visibleOverlays: 0,
                                       scroll: .init(showing: false, age: ShotGate.staleScroll + 1)),
                       .proceed(reset: [.scroll]))
        XCTAssertEqual(ShotGate.decide(capturingFor: 60, overlays: 3, visibleOverlays: 0,
                                       scroll: .init(showing: false, age: 60)),
                       .proceed(reset: [.capture, .overlays, .scroll]))
    }

    func testShotGateLimitsAreOrdered() {
        XCTAssertGreaterThan(ShotGate.staleCapture, ShotGate.captureTimeout, "сброс — только после собственного предела захвата")
        XCTAssertGreaterThan(ShotGate.staleScroll, 8, "у длинного снимка свой предел ответа системы — 8 с")
    }

    // MARK: - Трансляция: мёртвый сокет ведущего

    func testHeartbeatSendsWhileSocketAlive() {
        var watch = ShareHeartbeatWatch()
        for _ in 0..<10 { XCTAssertEqual(watch.tick(socketAlive: true), .send) }
        XCTAssertEqual(watch.failures, 0)
    }

    func testDeadSocketReconnectsThenEnds() {
        var watch = ShareHeartbeatWatch()
        XCTAssertEqual(watch.tick(socketAlive: false), .reconnect)
        XCTAssertEqual(watch.tick(socketAlive: false), .reconnect)
        XCTAssertEqual(watch.tick(socketAlive: false), .end, "не крутится вечно: эфир завершается")
    }

    func testFailedSendCountsEvenIfStateLooksAlive() {
        var watch = ShareHeartbeatWatch()
        XCTAssertEqual(watch.tick(socketAlive: true), .send)
        watch.sendFailed()
        XCTAssertEqual(watch.tick(socketAlive: true), .reconnect)
    }

    func testReconnectWatchdogOutlastsAllAttempts() {
        let pauses = TimeInterval(ShareHostReconnect.delays.reduce(0, +))
        let attempts = TimeInterval(ShareHostReconnect.delays.count) * TimeInterval(ShareHostReconnect.attemptAllowance)
        XCTAssertGreaterThan(ShareHostReconnect.watchdogLimit, pauses + attempts)
        XCTAssertLessThan(ShareHostReconnect.watchdogLimit, 2 * 3600, "и всё же конечен")
    }
}
