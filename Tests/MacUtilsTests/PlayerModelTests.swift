import AVFoundation
import XCTest
@testable import MacUtils
@testable import MUCore

/// Этап 2 плеера: модель на демо-видео. Звука нет (`silent`), позиции — в памяти.
@MainActor
final class PlayerModelTests: XCTestCase {
    private var folder: URL?
    private var model: PlayerModel?

    override func setUp() async throws {
        folder = try DemoVideo.makeFolder()
        UserDefaults.standard.set(true, forKey: Pref.playerRememberPosition)
    }

    override func tearDown() async throws {
        model?.shutdown()
        model = nil
        DemoVideo.cleanup(folder)
    }

    private func makeModel() -> PlayerModel {
        let model = PlayerModel(silent: true, positions: PositionStore(file: nil))
        self.model = model
        return model
    }

    private func demo(_ name: String = "demo.mp4", duration: Double = 4) async throws -> URL {
        var options = DemoVideo.Options()
        options.duration = duration
        return try await DemoVideo.make(options, in: try XCTUnwrap(folder), name: name)
    }

    /// Ждать условия, давая поработать главному циклу (наблюдатели AVPlayer приходят на главную очередь).
    private func waitUntil(_ what: String, timeout: Double = 30, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                let player = model?.player
                return XCTFail("не дождались: \(what) · \(String(describing: model?.phase)) статус \(player?.timeControlStatus.rawValue ?? -1) "
                    + "ждёт \(player?.reasonForWaitingToPlay?.rawValue ?? "-") скорость \(player?.rate ?? -1) время \(player?.currentTime().seconds ?? -1)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Номер кадра, который сейчас показан.
    private func shownFrame(_ model: PlayerModel) async throws -> Int? {
        await DemoVideo.shownFrame(try XCTUnwrap(model.videoOutput), player: model.player)
    }

    func testOpensDemoAndDescribesIt() async throws {
        let model = makeModel()
        model.open([try await demo()])
        try await waitUntil("ready") { model.phase == .ready }
        XCTAssertEqual(model.duration, 4, accuracy: 0.1)
        XCTAssertEqual(model.info.title, "demo.mp4")
        XCTAssertTrue(model.info.hasVideo)
        XCTAssertEqual(model.info.size, CGSize(width: 640, height: 360))
        XCTAssertEqual(model.info.fps, 24, accuracy: 0.01)
        XCTAssertTrue(model.info.codecs.hasPrefix("H.264 · 640 × 360 · 24 к/с · AAC"), model.info.codecs)
        try await waitUntil("играет") { model.isPlaying }
        try await waitUntil("время идёт") { model.clock.time > 0.2 }
        model.pause()
        try await waitUntil("пауза") { !model.isPlaying }
    }

    func testMovPlaysToo() async throws {
        let model = makeModel()
        model.open([try await demo("demo.mov")])
        try await waitUntil("ready") { model.phase == .ready }
        XCTAssertEqual(model.player.currentItem?.status, .readyToPlay)
    }

    func testSeekClampsAndRateSteps() async throws {
        let model = makeModel()
        model.open([try await demo()])
        try await waitUntil("ready") { model.phase == .ready }
        model.pause()
        model.seek(to: 2, exact: true)
        try await waitUntil("перемотка") { abs(model.currentTime - 2) < 0.05 }
        model.seek(by: -60)
        try await waitUntil("упор в начало") { model.currentTime < 0.05 }
        model.seek(by: 600)
        try await waitUntil("упор в конец") { model.currentTime > 3.8 }
        XCTAssertLessThanOrEqual(model.currentTime, model.duration)

        model.setRate(1)
        model.stepRate(1)
        XCTAssertEqual(model.rate, 1.25)
        for _ in 0..<20 { model.stepRate(1) }
        XCTAssertEqual(model.rate, 4)
        model.setRate(0.1)
        XCTAssertEqual(model.rate, 0.25)
        model.setRate(1)
        model.setBoost(2)
        XCTAssertEqual(model.effectiveRate, 2)
        XCTAssertEqual(model.rate, 1, "временная скорость не меняет выбранную")
        model.setBoost(nil)
        XCTAssertEqual(model.effectiveRate, 1)
    }

    func testFrameStepShowsNeighbourFrames() async throws {
        let model = makeModel()
        model.open([try await demo()])
        try await waitUntil("ready") { model.phase == .ready }
        model.pause()
        model.seek(to: 48.0 / 24, exact: true)
        try await waitUntil("на кадре 48") { abs(model.currentTime - 2) < 0.01 }
        let start = try await shownFrame(model)
        XCTAssertEqual(start, 48)
        model.stepFrame(forward: true)
        try await waitUntil("шаг вперёд") { model.frameNumber == 49 }
        let forward = try await shownFrame(model)
        XCTAssertEqual(forward, 49, "`.` — кадр N+1")
        model.stepFrame(forward: false)
        model.stepFrame(forward: false)
        try await waitUntil("два шага назад") { model.frameNumber == 47 }
        let back = try await shownFrame(model)
        XCTAssertEqual(back, 47, "`,` — кадр N−1")
        XCTAssertFalse(model.isPlaying, "шаг — на паузе")
    }

    func testEndAdvancesPlaylistOrStops() async throws {
        let model = makeModel()
        let a = try await demo("a.mp4", duration: 1)
        let b = try await demo("b.mp4", duration: 1)
        model.open([a, b])
        try await waitUntil("ready") { model.phase == .ready }
        XCTAssertEqual(model.playlist.current?.url.lastPathComponent, "a.mp4")
        model.seek(to: 0.8, exact: true)
        model.play()
        try await waitUntil("перешли ко второму") { model.playlist.current?.url.lastPathComponent == "b.mp4" && model.phase == .ready }
        model.seek(to: 0.8, exact: true)
        model.play()
        try await waitUntil("конец списка") { model.reachedEnd }
        XCTAssertFalse(model.isPlaying)
        model.play()
        try await waitUntil("пробел в конце — сначала") { model.isPlaying }
        XCTAssertLessThan(model.currentTime, 0.9)
    }

    func testUnsupportedContainerShowsScreenWithoutLoading() async throws {
        let model = makeModel()
        let url = try XCTUnwrap(folder).appendingPathComponent("fake.mkv")
        try Data("не видео".utf8).write(to: url)
        model.open([url])
        XCTAssertEqual(model.phase, .unsupported(url))
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.activeObserverCount, 0)
    }

    func testTruncatedFileFailsGracefully() async throws {
        let model = makeModel()
        let good = try await demo()
        let data = try Data(contentsOf: good)
        let broken = try XCTUnwrap(folder).appendingPathComponent("broken.mp4")
        try data.prefix(data.count / 3).write(to: broken)
        model.open([broken])
        try await waitUntil("ошибка") { if case .failed = model.phase { return true } else { return false } }
        if case .failed(let message) = model.phase { XCTAssertFalse(message.isEmpty) }
        // Приложение живо: следующий файл открывается как обычно.
        model.open([good])
        try await waitUntil("следующий открылся") { model.phase == .ready }
    }

    func testResumesFromRememberedPlace() async throws {
        var options = DemoVideo.Options()
        options.duration = 40
        options.width = 160
        options.height = 90
        options.subtitles = []
        let url = try await DemoVideo.make(options, in: try XCTUnwrap(folder), name: "long.mp4")
        let positions = PositionStore(file: nil)
        let key = try XCTUnwrap(PositionStore.key(for: url))
        positions.record(key: key, path: url.path, position: 33, duration: 40)
        let model = PlayerModel(silent: true, positions: positions)
        self.model = model
        model.open([url])
        try await waitUntil("ready") { model.phase == .ready }
        XCTAssertEqual(model.resumedFrom ?? 0, 33, accuracy: 0.01, "тост «Продолжаем с 0:33»")
        try await waitUntil("на месте") { abs(model.currentTime - 33) < 0.6 }
        model.restartFromBeginning()
        XCTAssertNil(model.resumedFrom)
        try await waitUntil("с начала") { model.currentTime < 0.6 }
        model.pause()
        model.seek(to: 34, exact: true)
        try await waitUntil("перемотка") { abs(model.currentTime - 34) < 0.05 }
        model.savePosition()
        XCTAssertEqual(positions.resumePosition(for: key) ?? 0, 34, accuracy: 0.05, "пауза и закрытие запоминают место")
        UserDefaults.standard.set(false, forKey: Pref.playerRememberPosition)
        defer { UserDefaults.standard.set(true, forKey: Pref.playerRememberPosition) }
        model.seek(to: 36, exact: true)
        try await waitUntil("перемотка") { abs(model.currentTime - 36) < 0.05 }
        model.savePosition()
        XCTAssertEqual(positions.resumePosition(for: key) ?? 0, 34, accuracy: 0.05, "«Запоминать место» выкл. — не пишем")
    }

    func testShutdownRemovesEveryObserverAndSilences() async throws {
        let model = makeModel()
        model.open([try await demo()])
        try await waitUntil("ready") { model.phase == .ready }
        try await waitUntil("играет") { model.isPlaying }
        XCTAssertGreaterThan(model.activeObserverCount, 0)
        model.shutdown()
        XCTAssertEqual(model.activeObserverCount, 0, "окно закрыто — ни одного наблюдателя")
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertEqual(model.phase, .empty)
        XCTAssertTrue(model.playlist.isEmpty)
    }

    func testReopeningSameFileDoesNotDuplicate() async throws {
        let model = makeModel()
        let a = try await demo("a.mp4", duration: 1)
        let b = try await demo("b.mp4", duration: 1)
        model.open([a, b])
        model.open([a])
        XCTAssertEqual(model.playlist.count, 2)
        XCTAssertEqual(model.playlist.current?.url.lastPathComponent, "a.mp4")
    }
}
