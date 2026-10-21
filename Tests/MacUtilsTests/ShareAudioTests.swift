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

    /// Буфер перехвата — последний, после входов подустройства: у USB-гарнитуры и AirPods первым идёт микрофон.
    func testTapBufferIsLastAfterSubdeviceInputs() {
        XCTAssertEqual(AggregateStreams.tapBuffer(inputCount: 1, subdeviceInputs: 0), 0, "встроенные динамики / трансляция без подустройства")
        XCTAssertEqual(AggregateStreams.tapBuffer(inputCount: 2, subdeviceInputs: 1), 1, "гарнитура: микрофон первым")
        XCTAssertEqual(AggregateStreams.tapBuffer(inputCount: 4, subdeviceInputs: 3), 3, "аудиоинтерфейс")
        // Входы подустройства выключены для IOProc, и HAL их в буферах опускает — остаётся один, перехват.
        XCTAssertEqual(AggregateStreams.tapBuffer(inputCount: 1, subdeviceInputs: 1, subdeviceInputsOff: true), 0)
        XCTAssertEqual(AggregateStreams.tapBuffer(inputCount: 2, subdeviceInputs: 1, subdeviceInputsOff: true), 1)
    }

    /// Раскладка не сходится (состав агрегата ещё собирается) — буфера нет, звук не берём, а не «первый попавшийся».
    func testTapBufferRefusesIncompleteLayout() {
        XCTAssertNil(AggregateStreams.tapBuffer(inputCount: 1, subdeviceInputs: 1), "только микрофон — перехвата ещё нет")
        XCTAssertNil(AggregateStreams.tapBuffer(inputCount: 0, subdeviceInputs: 0))
        XCTAssertNil(AggregateStreams.tapBuffer(inputCount: 3, subdeviceInputs: 1), "лишний поток")
        XCTAssertNil(AggregateStreams.tapBuffer(inputCount: 2, subdeviceInputs: 0), "у трансляции один буфер")
        XCTAssertNil(AggregateStreams.tapBuffer(inputCount: 1, subdeviceInputs: -1))
    }

    /// Для IOProc включён только поток перехвата, входы подустройства (микрофон AirPods) — выключены.
    func testInputStreamUsageKeepsOnlyTap() {
        XCTAssertEqual(AggregateStreams.inputStreamUsage(aggregateInputs: 1, subdeviceInputs: 0), [true])
        XCTAssertEqual(AggregateStreams.inputStreamUsage(aggregateInputs: 2, subdeviceInputs: 1), [false, true])
        XCTAssertEqual(AggregateStreams.inputStreamUsage(aggregateInputs: 3, subdeviceInputs: 2), [false, false, true])
        XCTAssertNil(AggregateStreams.inputStreamUsage(aggregateInputs: 1, subdeviceInputs: 1), "состав не собран — не трогаем")
        XCTAssertNil(AggregateStreams.inputStreamUsage(aggregateInputs: 0, subdeviceInputs: 0))
    }

    /// После ошибки перехвата — одна попытка на новую обстановку, а не на каждую пересборку.
    func testTapRetryOncePerSituation() {
        var retry = ShareTapRetry()
        XCTAssertTrue(retry.shouldTry("out1-10"))
        retry.failed(in: "out1-10")
        XCTAssertFalse(retry.shouldTry("out1-10"), "та же обстановка — не повторяем")
        XCTAssertTrue(retry.shouldTry("out2-10"), "сменился выход")
        XCTAssertTrue(retry.shouldTry("out1-11"), "запустилась программа")
        retry = ShareTapRetry()
        XCTAssertTrue(retry.shouldTry("out1-10"), "после успеха — заново")
    }
}
