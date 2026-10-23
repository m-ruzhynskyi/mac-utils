import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot

/// Настоящие виды плеера офскрин в PNG — сверка с макетами `v01`–`v15b` (кадр видео `cacheDisplay` не захватывает:
/// там чёрное поле, проверяются панель, меню, подсказки и тосты). Без переменной окружения тест пропускается.
///   MU_PLAYER_UI=/путь/к/папке swift test --filter PlayerUISnapshots
@MainActor
final class PlayerUISnapshots: XCTestCase {
    private var folder: URL?

    override func setUp() async throws {
        Pref.register()
        folder = try DemoVideo.makeFolder()
        PlayerSystem.shared.integratesWithSystem = false
        PlayerWindowController.syncDock = { _ in }
    }

    override func tearDown() async throws {
        for controller in PlayerWindowController.windows { controller.window.close() }
        DemoVideo.cleanup(folder)
        PlayerSystem.shared.integratesWithSystem = true
        PlayerWindowController.syncDock = { AppDelegate.syncDock(playerOpen: $0) }
    }

    private func directory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MU_PLAYER_UI"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_PLAYER_UI=<папка>, чтобы нарисовать окно плеера")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = NSApplication.shared
        return url
    }

    private func render<V: View>(_ name: String, in directory: URL, size: NSSize = NSSize(width: 800, height: 540), _ view: () -> V) throws {
        for dark in [false, true] {
            let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            let host = NSHostingView(rootView: view().frame(width: size.width, height: size.height).environment(\.controlActiveState, .key))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            window.contentView = nil
            window.close()
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func controller(chapters: Bool = false, files: Int = 3) async throws -> PlayerWindowController {
        let folder = try XCTUnwrap(folder)
        var urls: [URL] = []
        for index in 0..<files {
            var options = DemoVideo.Options()
            options.duration = 60
            options.width = 320
            options.height = 180
            if chapters {
                options.chapters = [.init(title: "Opening", start: 2), .init(title: "Episode", start: 12), .init(title: "Ending", start: 52)]
            }
            urls.append(try await DemoVideo.make(options, in: folder, name: "harbor_s01e0\(index + 1)_demo.mp4"))
        }
        try DemoSubtitles.write(DemoSubtitles.srt, .windows1251, to: folder.appendingPathComponent("harbor_s01e01_demo.ru.srt"))
        let controller = PlayerWindowController(model: PlayerModel(silent: true, positions: PositionStore(file: nil)))
        controller.model.open(urls)
        try await waitUntil { controller.model.phase == .ready && controller.model.duration > 0 }
        for url in urls { PlayerMediaInfoCache.shared.request(url) }
        try await waitUntil { urls.allSatisfy { PlayerMediaInfoCache.shared.thumbnail(of: $0) != nil } }
        XCTAssertTrue(urls.allSatisfy { PlayerMediaInfoCache.shared.thumbnail(of: $0) != nil }, "миниатюры плейлиста готовы")
        controller.model.pause()
        return controller
    }

    private func root(_ controller: PlayerWindowController) -> PlayerRootView {
        PlayerRootView(model: controller.model, clock: controller.model.clock, ui: controller.ui, controller: controller)
    }

    func testWindowStates() async throws {
        let directory = try directory()
        let empty = PlayerWindowController(model: PlayerModel(silent: true, positions: PositionStore(file: nil)))
        try render("p07-empty", in: directory) { root(empty) }

        let player = try await controller()
        let model = player.model
        model.seek(to: 1, exact: true)
        try await waitUntil { abs(model.currentTime - 1) < 0.05 }
        model.clock.time = 1
        try render("p01-playing", in: directory) { root(player) }
        player.ui.playlistVisible = true
        try render("p03-playlist", in: directory) { root(player) }
        player.ui.playlistVisible = false
        player.ui.menu = .subtitles
        try render("p04-subtitles-menu", in: directory) { root(player) }
        player.ui.menu = .speed
        try render("p05-speed-menu", in: directory) { root(player) }
        player.ui.menu = .audio
        try render("p05b-audio-menu", in: directory) { root(player) }
        player.ui.menu = nil
        player.ui.fullScreen = true
        try render("p06-fullscreen", in: directory, size: NSSize(width: 800, height: 450)) { root(player) }
        player.ui.fullScreen = false
        player.ui.flash(.frame(number: 24, timecode: "00:00:01:00"), for: 30)
        try render("p08b-frame-step", in: directory) { root(player) }
        player.ui.show(.boost)
        player.ui.hint(.left, seconds: 20)
        try render("p14b-gestures", in: directory) { root(player) }
        player.ui.clearHUD()
        model.resumedFrom = 754
        try render("p08a-resume", in: directory) { root(player) }
        model.resumedFrom = nil
    }

    func testSkipStates() async throws {
        let directory = try directory()
        let player = try await controller(chapters: true)
        let model = player.model
        try await waitUntil { !model.skip.segments.isEmpty }
        model.seek(to: 1.5, exact: true)
        try await waitUntil { abs(model.currentTime - 1.5) < 0.05 }
        model.play()
        try await waitUntil { if case .button = model.skip.decision { return true } else { return false } }
        model.pause()
        try render("p14-skip-intro", in: directory) { root(player) }
        model.seek(to: 51.5, exact: true)
        try await waitUntil { abs(model.currentTime - 51.5) < 0.05 }
        model.play()
        try await waitUntil { if case .countdown = model.skip.decision { return true } else { return false } }
        model.player.pause()
        try render("p15-next-episode", in: directory) { root(player) }
    }

    /// Длинные имена серий: номер серии виден, сокращается начало (дефект 1 Тестера 2).
    func testLongEpisodeNames() async throws {
        let directory = try directory()
        let folder = try XCTUnwrap(folder)
        var urls: [URL] = []
        for index in 1...3 {
            var options = DemoVideo.Options()
            options.duration = 2
            options.width = 160
            options.height = 90
            urls.append(try await DemoVideo.make(options, in: folder,
                                                 name: "Очень длинное название сериала про ночную гавань.S01E0\(index).1080p.WEB-DL.mp4"))
        }
        let player = PlayerWindowController(model: PlayerModel(silent: true, positions: PositionStore(file: nil)))
        player.model.open(urls)
        try await waitUntil { player.model.phase == .ready }
        player.model.pause()
        player.ui.playlistVisible = true
        try render("p03b-long-names", in: directory) { root(player) }
    }

    func testUnsupportedAndSettings() async throws {
        let directory = try directory()
        let fake = try XCTUnwrap(folder).appendingPathComponent("trailer_demo.mkv")
        try Data("x".utf8).write(to: fake)
        let player = PlayerWindowController(model: PlayerModel(silent: true, positions: PositionStore(file: nil)))
        player.model.open([fake])
        try render("p09-unsupported", in: directory) { root(player) }
        try render("p11-settings", in: directory, size: NSSize(width: 760, height: 1180)) {
            VideoPlayerPage().background(Color.dsBg)
        }
    }
}
