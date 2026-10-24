import AppKit
import CoreAudio
import XCTest
@testable import MacUtils
@testable import MUAudio
@testable import MUScreenShare

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

    private func format(_ rate: Double, channels: UInt32 = 1) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                                    mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                                    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    /// Конвертер — по фактическому формату входа агрегата; нет его — по формату перехвата.
    func testConverterFormatPrefersAggregateStream() {
        XCTAssertEqual(ShareTapFormat.chosen(tap: format(48_000), stream: format(44_100)).mSampleRate, 44_100)
        XCTAssertEqual(ShareTapFormat.chosen(tap: format(48_000), stream: nil).mSampleRate, 48_000)
        XCTAssertEqual(ShareTapFormat.chosen(tap: format(48_000), stream: format(0)).mSampleRate, 48_000, "пустой формат потока")
        XCTAssertEqual(ShareTapFormat.chosen(tap: format(48_000), stream: format(16_000, channels: 0)).mSampleRate, 48_000)
    }

    /// AirPods + звонок (HFP): частота 48 → 16/24 кГц — конвертер пересобирается; та же частота — нет.
    func testRateChangeRebuildsConverter() {
        XCTAssertFalse(ShareTapFormat.needsRebuild(converterRate: 48_000, tap: format(48_000), stream: format(48_000)))
        XCTAssertTrue(ShareTapFormat.needsRebuild(converterRate: 48_000, tap: format(16_000), stream: format(16_000)), "HFP")
        XCTAssertTrue(ShareTapFormat.needsRebuild(converterRate: 48_000, tap: format(48_000), stream: format(24_000)), "вход агрегата")
        XCTAssertTrue(ShareTapFormat.needsRebuild(converterRate: 48_000, tap: format(44_100), stream: nil), "Audio-MIDI")
        XCTAssertFalse(ShareTapFormat.needsRebuild(converterRate: 48_000, tap: format(0), stream: nil), "формат не прочитан — не трогаем")
    }

    /// Сторож запуска: нет колбэков или ни одного буфера перехвата с данными — ошибка Core Audio; тишина — не ошибка.
    func testWatchdogVerdicts() {
        var watchdog = ShareTapWatchdog()
        XCTAssertEqual(watchdog.verdict, .noCallbacks, "агрегат без часов: IOProc не вызывается (1.9.2)")
        watchdog.record(inputBuffers: 1, tapData: false)
        watchdog.record(inputBuffers: 1, tapData: false)
        XCTAssertEqual(watchdog.verdict, .noData, "колбэки идут, но буфер перехвата NULL или пустой")
        watchdog.record(inputBuffers: 2, tapData: true)
        XCTAssertEqual(watchdog.verdict, .ok, "буфер с данными (даже тишиной) — перехват работает")
        XCTAssertEqual(watchdog.callbacks, 3)
        XCTAssertEqual(watchdog.withData, 1)
        XCTAssertEqual(watchdog.inputBuffers, 2)
    }

    /// Журнал сторожа — только числа.
    func testWatchdogSummaryHasOnlyNumbers() {
        var watchdog = ShareTapWatchdog()
        for _ in 0..<150 { watchdog.record(inputBuffers: 1, tapData: true) }
        let line = watchdog.summary(tapRate: 48_000, streamRate: 48_000, outputRate: 44_100)
        XCTAssertEqual(line, "колбэков за 3 с: 150, с данными перехвата: 150, входных буферов: 1, частоты: перехват 48000, вход агрегата 48000, выход 44100 Гц")
    }

    /// Агрегат трансляции — с выходом как основным подустройством (часы) и перехватом в списке перехватов (как до 99363c8
    /// и как в «Громкости приложений»); без основного подустройства у агрегата нет часов и звука нет совсем.
    @available(macOS 14.2, *)
    func testShareAggregateHasMainSubdeviceAndTap() {
        let description = ShareAudioTap.aggregateDescription(outputUID: "out-uid", tapUUID: "tap-uuid", unique: "u1")
        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "out-uid")
        XCTAssertEqual(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: String]], [[kAudioSubDeviceUIDKey: "out-uid"]])
        let taps = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        XCTAssertEqual(taps?.count, 1)
        XCTAssertEqual(taps?.first?[kAudioSubTapUIDKey] as? String, "tap-uuid")
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceUIDKey] as? String, "com.mruzhynskyi.macutils.share.u1")
    }

    /// Буфер перехвата у трансляции с выходом-подустройством: последний после входов выхода; входы выключены и HAL их
    /// опустил — единственный; только входы выхода (перехвата ещё нет) — ничего, микрофон никогда.
    func testShareTapBufferWithOutputSubdevice() {
        XCTAssertEqual(AggregateStreams.tapBuffer(inputCount: 1, subdeviceInputs: 0), 0, "встроенные динамики: входов нет")
        XCTAssertEqual(AggregateStreams.tapBuffer(inputCount: 2, subdeviceInputs: 1, subdeviceInputsOff: true), 1, "AirPods, входы выключены, но в списке")
        XCTAssertEqual(AggregateStreams.tapBuffer(inputCount: 1, subdeviceInputs: 1, subdeviceInputsOff: true), 0, "AirPods, HAL опустил выключенный вход")
        XCTAssertNil(AggregateStreams.tapBuffer(inputCount: 1, subdeviceInputs: 1, subdeviceInputsOff: false), "один буфер при включённом микрофоне — это микрофон")
    }

    /// Часы агрегата: выход-агрегат («Устройство с несколькими выходами») вложить нельзя — его подустройство, нет его —
    /// встроенный выход; обычный выход (встроенный, USB, Bluetooth, виртуальный) — он сам.
    func testTapClockAvoidsNestedAggregate() {
        let multi = ShareTapClock.Output(id: 50, transport: kAudioDeviceTransportTypeAggregate, subdevice: 51)
        XCTAssertEqual(ShareTapClock.choose(output: multi, builtIn: 7), 51)
        let empty = ShareTapClock.Output(id: 50, transport: kAudioDeviceTransportTypeAggregate, subdevice: nil)
        XCTAssertEqual(ShareTapClock.choose(output: empty, builtIn: 7), 7)
        XCTAssertNil(ShareTapClock.choose(output: empty, builtIn: nil))
        for transport in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
                          kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeHDMI] {
            XCTAssertEqual(ShareTapClock.choose(output: .init(id: 9, transport: transport, subdevice: nil), builtIn: 7), 9)
        }
    }

    /// Транспорт в журнале — код из четырёх букв, без имён устройств.
    func testTapClockCode() {
        XCTAssertEqual(ShareTapClock.code(kAudioDeviceTransportTypeAggregate), "grup")
        XCTAssertEqual(ShareTapClock.code(kAudioDeviceTransportTypeBuiltIn), "bltn")
        XCTAssertEqual(ShareTapClock.code(0), "0")
    }

    /// Запасной способ (SCK) помощников не исключает — при «Не передавать звонки» говорим прямо про звонок.
    func testFallbackMessageWarnsAboutCalls() {
        XCTAssertTrue(ShareAudioFallback.message(muteCalls: true, mutedApps: 0).contains("звонок"))
        XCTAssertTrue(ShareAudioFallback.message(muteCalls: false, mutedApps: 2).contains("заглушённые программы"))
        XCTAssertEqual(ShareAudioFallback.message(muteCalls: false, mutedApps: 0), "Звук трансляции — запасным способом")
    }

    /// Смена списка исключённых: до первых колбэков — откладывается (не трогаем описание только что запущенного перехвата);
    /// после — на лету; если на лету уже останавливало колбэки — пересборкой.
    @available(macOS 14.2, *)
    func testExclusionUpdatePlan() {
        XCTAssertEqual(ShareAudioTap.plan(changed: false, ioProven: false, rebuildOnChange: false), .unchanged)
        XCTAssertEqual(ShareAudioTap.plan(changed: true, ioProven: false, rebuildOnChange: false), .deferred)
        XCTAssertEqual(ShareAudioTap.plan(changed: true, ioProven: false, rebuildOnChange: true), .deferred)
        XCTAssertEqual(ShareAudioTap.plan(changed: true, ioProven: true, rebuildOnChange: false), .applied)
        XCTAssertEqual(ShareAudioTap.plan(changed: true, ioProven: true, rebuildOnChange: true), .rebuilt)
    }
}
