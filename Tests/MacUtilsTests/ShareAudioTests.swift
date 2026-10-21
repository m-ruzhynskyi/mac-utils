import AppKit
import CoreAudio
import XCTest
@testable import MacUtils

/// Что не передавать в трансляцию (эхо звонка): помощники программ, ответственный процесс, позднее появление,
/// пересборка по событиям. Без захвата: ни экрана, ни звука.
@MainActor
final class ShareAudioTests: XCTestCase {
    private let ownPID: pid_t = 100

    private func process(_ pid: pid_t, _ bundleID: String?, owner: String? = nil) -> ShareAudioProcess {
        ShareAudioProcess(object: AudioObjectID(pid + 1000), pid: pid, bundleID: bundleID, ownerBundleID: owner)
    }

    func testHelperMatchesItsAppButNotAnotherWithSamePrefix() {
        let muted: Set<String> = ["com.hnc.Discord"]
        XCTAssertTrue(ShareAudioExclusion.matches("com.hnc.Discord", muted))
        XCTAssertTrue(ShareAudioExclusion.matches("com.hnc.Discord.helper", muted))
        XCTAssertTrue(ShareAudioExclusion.matches("com.hnc.Discord.helper.Renderer", muted))
        XCTAssertFalse(ShareAudioExclusion.matches("com.hnc.DiscordPTB", muted), "другая программа")
        XCTAssertFalse(ShareAudioExclusion.matches(nil, muted))
        XCTAssertFalse(ShareAudioExclusion.matches("", muted))
    }

    /// Звук звонка Discord — из помощника без окон: исключается по своему bundle id или по ответственной программе.
    func testDiscordHelpersExcludedByBundleOrResponsibleApp() {
        let processes = [
            process(1, "com.hnc.Discord"),
            process(2, "com.hnc.Discord.helper"),
            process(3, "com.hnc.Discord.helper.Renderer"),
            process(4, nil, owner: "com.hnc.Discord"),
            process(5, "com.spotify.client"),
            process(6, "com.apple.WebKit.GPU", owner: "com.apple.Safari"),
        ]
        let excluded = ShareAudioExclusion.excluded(processes, muted: ["com.hnc.Discord"], ownPID: ownPID, ownBundleID: "own.app")
        XCTAssertEqual(excluded.map(\.pid), [1, 2, 3, 4])
    }

    /// Mac Utils (в том числе как зритель чужой трансляции) — всегда исключён: по pid и по своему bundle id.
    func testOwnProcessAlwaysExcluded() {
        let processes = [process(ownPID, nil), process(7, "own.app.helper"), process(8, "com.other")]
        let excluded = ShareAudioExclusion.excluded(processes, muted: [], ownPID: ownPID, ownBundleID: "own.app")
        XCTAssertEqual(excluded.map(\.pid), [ownPID, 7])
    }

    /// Голосовой процесс появился уже после старта: при пересборке он в исключённых.
    func testLateHelperExcludedOnRebuild() {
        var processes = [process(1, "com.hnc.Discord")]
        XCTAssertEqual(ShareAudioExclusion.excluded(processes, muted: ["com.hnc.Discord"], ownPID: ownPID).count, 1)
        processes.append(process(9, "com.hnc.Discord.helper"))
        XCTAssertEqual(ShareAudioExclusion.excluded(processes, muted: ["com.hnc.Discord"], ownPID: ownPID).map(\.pid), [1, 9])
    }

    func testMuteCallsAddsKnownCallApps() {
        let muted = ShareAudioExclusion.muted(apps: ["com.spotify.client"], calls: true)
        XCTAssertTrue(muted.isSuperset(of: ["com.spotify.client", "com.hnc.Discord", "ru.keepcoder.Telegram", "com.viber.osx", "us.zoom.xos"]))
        XCTAssertEqual(ShareAudioExclusion.muted(apps: ["com.spotify.client"], calls: false), ["com.spotify.client"])
        let processes = [process(1, "ru.keepcoder.Telegram"), process(2, "com.hnc.Discord.helper"), process(3, "com.spotify.client")]
        XCTAssertEqual(ShareAudioExclusion.excluded(processes, muted: ShareAudioExclusion.muted(apps: [], calls: true), ownPID: ownPID).map(\.pid), [1, 2])
    }

    func testSummaryHasOnlyCountAndBundleIDs() {
        let summary = ShareAudioExclusion.summary([process(1, "com.hnc.Discord"), process(2, "com.hnc.Discord"), process(3, nil)])
        XCTAssertEqual(summary, "3: com.hnc.Discord, pid")
    }

    /// Запуск и закрытие программ пересобирают список; пачка событий — одна пересборка; после `stop` — тишина.
    func testWatcherRebuildsOnLaunchAndTerminate() {
        let center = NotificationCenter()
        var calls = 0
        let watcher = ShareAudioWatcher(workspace: center, coreAudio: false) { calls += 1 }
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(calls, 1, "пачка — одна пересборка")
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(calls, 2)
        watcher.stop()
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(calls, 2, "закрыто — не работает")
    }
}
