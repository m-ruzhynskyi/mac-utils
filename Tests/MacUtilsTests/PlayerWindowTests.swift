import AppKit
import Carbon.HIToolbox
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUAudio
@testable import MUScreenshot
@testable import MUVideoPlayer

/// Этап 3 плеера: окно с настоящей моделью (без звука, окно не показывается), события клавиш — как от системы.
@MainActor
final class PlayerWindowTests: XCTestCase {
    private var folder: URL?
    private var controller: PlayerWindowController?

    override func setUp() async throws {
        _ = NSApplication.shared
        Pref.register()
        folder = try DemoVideo.makeFolder()
        PlayerSystem.shared.integratesWithSystem = false
        PlayerWindowController.syncDock = { _ in }
    }

    override func tearDown() async throws {
        controller?.window.close()
        controller = nil
        DemoVideo.cleanup(folder)
        PlayerSystem.shared.integratesWithSystem = true
        PlayerWindowController.syncDock = { AppDelegate.syncDock(playerOpen: $0) }
    }

    private func makeController(duration: Double = 40) async throws -> PlayerWindowController {
        var options = DemoVideo.Options()
        options.duration = duration
        options.width = 160
        options.height = 90
        let url = try await DemoVideo.make(options, in: try XCTUnwrap(folder), name: "demo.mp4")
        let controller = PlayerWindowController(model: PlayerModel(silent: true, positions: PositionStore(file: nil)))
        self.controller = controller
        controller.model.open([url])
        try await waitUntil("ready") { controller.model.phase == .ready }
        controller.model.pause()
        try await waitUntil("пауза") { !controller.model.isPlaying }
        return controller
    }

    private func waitUntil(_ what: String, timeout: Double = 30, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("не дождались: \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func key(_ controller: PlayerWindowController, _ code: Int, _ type: NSEvent.EventType = .keyDown,
                     flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) -> Bool {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: controller.window.windowNumber, context: nil, characters: "",
                                     charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: UInt16(code))!
        return controller.handleKey(event)
    }

    func testFrameKeysStepExactFrames() async throws {
        let controller = try await makeController()
        let model = controller.model
        model.seek(to: 10, exact: true)
        try await waitUntil("10 с") { abs(model.currentTime - 10) < 0.01 }
        XCTAssertTrue(key(controller, kVK_ANSI_Period))
        try await waitUntil("кадр 241") { model.frameNumber == 241 }
        let output = try XCTUnwrap(model.videoOutput)
        let shown = await DemoVideo.shownFrame(output, player: model.player)
        XCTAssertEqual(shown, 241, "`.` — следующий кадр по номеру на нём")
        XCTAssertTrue(key(controller, kVK_ANSI_Comma))
        try await waitUntil("кадр 240") { model.frameNumber == 240 }
        try await waitUntil("подсказка кадра") {
            if case .frame(240, _) = controller.ui.hud { return true } else { return false }
        }
    }

    func testArrowTapSeeksOnReleaseAndHoldBoosts() async throws {
        let controller = try await makeController()
        let model = controller.model
        model.seek(to: 10, exact: true)
        try await waitUntil("10 с") { abs(model.currentTime - 10) < 0.01 }
        XCTAssertTrue(key(controller, kVK_RightArrow))
        XCTAssertEqual(model.currentTime, 10, accuracy: 0.01, "на нажатие → ничего не происходит")
        XCTAssertTrue(key(controller, kVK_RightArrow, .keyUp))
        try await waitUntil("+5 с на отпускание") { abs(model.currentTime - 15) < 0.2 }

        // Удержание: на паузе — играет 2×, отпустили — снова пауза и прежняя скорость.
        XCTAssertTrue(key(controller, kVK_RightArrow))
        try await waitUntil("2× пока держите") { model.boostRate == 2 }
        XCTAssertEqual(controller.ui.hud, .boost)
        XCTAssertTrue(key(controller, kVK_RightArrow, repeat: true), "повтор клавиши ничего не ломает")
        XCTAssertTrue(key(controller, kVK_RightArrow, .keyUp))
        XCTAssertNil(model.boostRate)
        XCTAssertEqual(model.rate, 1)
        try await waitUntil("снова пауза") { !model.isPlaying }
        XCTAssertNil(controller.ui.hud)
    }

    /// Тестер 2, дефект 3: отпустили → с зажатым ⇧ — 2× не залипает.
    func testHoldEndsWhenReleasedWithShift() async throws {
        let controller = try await makeController()
        let model = controller.model
        XCTAssertTrue(key(controller, kVK_RightArrow))
        try await waitUntil("2×") { model.boostRate == 2 }
        XCTAssertTrue(key(controller, kVK_RightArrow, .keyUp, flags: .shift))
        XCTAssertNil(model.boostRate)
        XCTAssertEqual(model.rate, 1)
        try await waitUntil("снова пауза") { !model.isPlaying }
    }

    func testSeekAndRateKeys() async throws {
        let controller = try await makeController()
        let model = controller.model
        model.seek(to: 20, exact: true)
        try await waitUntil("20 с") { abs(model.currentTime - 20) < 0.01 }
        _ = key(controller, kVK_ANSI_J)
        try await waitUntil("J −10") { abs(model.currentTime - 10) < 0.2 }
        _ = key(controller, kVK_ANSI_L)
        try await waitUntil("L +10") { abs(model.currentTime - 20) < 0.2 }
        _ = key(controller, kVK_LeftArrow, flags: .shift)
        try await waitUntil("⇧← — в начало, без ошибки") { model.currentTime < 0.2 }
        _ = key(controller, kVK_ANSI_RightBracket)
        XCTAssertEqual(model.rate, 1.25)
        _ = key(controller, kVK_ANSI_LeftBracket)
        _ = key(controller, kVK_ANSI_LeftBracket)
        XCTAssertEqual(model.rate, 0.75)
        _ = key(controller, kVK_ANSI_M)
        XCTAssertTrue(model.isMuted)
        _ = key(controller, kVK_ANSI_K)
        try await waitUntil("K — играть") { model.isPlaying }
        _ = key(controller, kVK_Space)
        try await waitUntil("пробел — пауза") { !model.isPlaying }
        XCTAssertFalse(key(controller, kVK_ANSI_Q, flags: .command), "чужие сочетания идут дальше")
        XCTAssertTrue(key(controller, kVK_ANSI_V))
        XCTAssertEqual(controller.ui.menu, .subtitles)
        XCTAssertTrue(key(controller, kVK_Escape))
        XCTAssertNil(controller.ui.menu, "Esc закрывает меню")
    }

    func testSkipKeyOutsideSegmentDoesNothing() async throws {
        let controller = try await makeController()
        let model = controller.model
        model.seek(to: 12, exact: true)
        try await waitUntil("12 с") { abs(model.currentTime - 12) < 0.01 }
        XCTAssertTrue(key(controller, kVK_ANSI_S))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.currentTime, 12, accuracy: 0.01, "вне отрезка S ничего не делает")
    }

    func testClosingWindowStopsEverything() async throws {
        let controller = try await makeController()
        let model = controller.model
        model.play()
        try await waitUntil("играет") { model.isPlaying }
        PlayerSystem.shared.update()
        XCTAssertTrue(PlayerWindowController.windows.contains { $0 === controller })
        XCTAssertGreaterThan(model.activeObserverCount, 0)
        controller.window.close()
        XCTAssertEqual(model.player.rate, 0, "звук стих сразу")
        XCTAssertEqual(model.activeObserverCount, 0)
        XCTAssertFalse(PlayerWindowController.windows.contains { $0 === controller })
        XCTAssertEqual(PlayerSystem.shared.lastPlan, .init(preventDisplaySleep: false, remoteCommands: false))
        self.controller = nil
    }
}
