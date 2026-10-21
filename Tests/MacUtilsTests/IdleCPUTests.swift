import AppKit
import XCTest
@testable import MacUtils

/// Простой без нагрузки (1.6.10: 3–5 % ядра с закрытыми настройками): модели опрашивают, только пока их видно на экране
/// или пока ждут события, и останавливаются, когда вид ушёл.
@MainActor
final class IdleCPUTests: XCTestCase {
    // MARK: - Счётчик зрителей

    func testViewerCountBalancesAndNeverGoesNegative() {
        var count = ViewerCount()
        XCTAssertFalse(count.any)
        count.update(true)
        count.update(true)
        count.update(false)
        XCTAssertTrue(count.any, "второй вид ещё на экране")
        count.update(false)
        count.update(false)
        XCTAssertEqual(count.value, 0)
        XCTAssertFalse(count.any)
    }

    func testProbeInHiddenWindowReportsNothing() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let probe = OnScreenView()
        var reports: [Bool] = []
        probe.changed = { reports.append($0) }
        window.contentView?.addSubview(probe)
        probe.detach()
        XCTAssertEqual(reports, [], "окно не показано — вид не на экране, и «скрыт» без «показан» не приходит")
    }

    // MARK: - Разрешения

    func testPermissionsPollOnlyWhenSomethingIsMissingAndSomeoneWaits() {
        XCTAssertFalse(PermissionsModel.pollNeeded(missing: true, onScreen: false, waiting: false), "настройки закрыты — опроса нет")
        XCTAssertTrue(PermissionsModel.pollNeeded(missing: true, onScreen: true, waiting: false))
        XCTAssertTrue(PermissionsModel.pollNeeded(missing: true, onScreen: false, waiting: true), "ждём выдачи после «Открыть настройки»")
        XCTAssertFalse(PermissionsModel.pollNeeded(missing: false, onScreen: true, waiting: true), "всё выдано — ждать нечего")
    }

    func testPermissionsModelDoesNotPollWhileHidden() {
        let model = PermissionsModel.shared
        model.awaitGrant(for: 0)
        model.refresh(includingLogin: false)
        XCTAssertFalse(model.isPolling, "без зрителей и ожидания таймера нет")

        model.viewerChanged(true)
        XCTAssertEqual(model.isPolling, model.missing, "экран с разрешениями виден — опрос, если чего-то не хватает")
        model.viewerChanged(false)
        XCTAssertFalse(model.isPolling, "окно скрыто — опрос стоп")

        model.awaitGrant(for: 60)
        XCTAssertEqual(model.isPolling, model.missing)
        model.awaitGrant(for: 0)
        model.refresh(includingLogin: false)
        XCTAssertFalse(model.isPolling, "время ожидания вышло — опрос стоп")
    }

    func testOpeningSystemSettingsStartsWaitingForGrant() {
        let model = PermissionsModel.shared
        model.awaitGrant(for: 0)
        model.refresh(includingLogin: false)
        // Permissions.open открывает Системные настройки — его не зовём; ожидание включает тот же awaitGrant().
        model.awaitGrant()
        XCTAssertEqual(model.isPolling, model.missing)
        model.awaitGrant(for: 0)
        model.refresh(includingLogin: false)
        XCTAssertFalse(model.isPolling)
    }

    // MARK: - Громкость приложений

    func testVolumePollsOnlyForVisibleListOrUnprovenTaps() {
        XCTAssertFalse(AppVolume.pollNeeded(running: true, onScreen: false, tapping: false, proven: false), "простой — без опроса")
        XCTAssertFalse(AppVolume.pollNeeded(running: true, onScreen: false, tapping: true, proven: true),
                       "перехват идёт, разрешение доказано — без опроса")
        XCTAssertTrue(AppVolume.pollNeeded(running: true, onScreen: false, tapping: true, proven: false), "проверка разрешения")
        XCTAssertTrue(AppVolume.pollNeeded(running: true, onScreen: true, tapping: false, proven: false), "список на экране")
        XCTAssertFalse(AppVolume.pollNeeded(running: false, onScreen: true, tapping: true, proven: false), "функция выключена")
    }

    func testVolumeDisabledDoesNotPollEvenWhenShown() {
        let model = AppVolume.shared
        XCTAssertFalse(model.isRunning)
        model.viewerChanged(true)
        XCTAssertFalse(model.isPolling)
        model.viewerChanged(false)
        XCTAssertFalse(model.isPolling)
    }

    // MARK: - Задачи

    func testTaskManagerSamplesOnlyWhileShown() {
        let model = TaskManagerModel.shared
        XCTAssertFalse(model.isSampling, "страница «Задачи» не на экране — перебора процессов нет")
        model.viewerChanged(true)
        XCTAssertTrue(model.isSampling)
        XCTAssertFalse(model.rows.isEmpty, "при показе список сразу заполнен")
        model.viewerChanged(true)
        model.viewerChanged(false)
        XCTAssertTrue(model.isSampling, "вторая вкладка «Задачи» ещё на экране")
        model.viewerChanged(false)
        XCTAssertFalse(model.isSampling, "закрыли окно — выборка стоп")
    }

    // MARK: - Прочее

    func testTrustCheckIsRareOnceGranted() {
        XCTAssertEqual(AppDelegate.trustCheckInterval(trusted: false), 2)
        XCTAssertEqual(AppDelegate.trustCheckInterval(trusted: true), 5)
    }

    // MARK: - Видеоплеер

    /// Закрыто — значит не работает: без окна плеера нет ни наблюдателей AVPlayer, ни утверждения питания,
    /// ни обработчиков медиаклавиш.
    func testVideoPlayerIdleWithoutWindow() {
        XCTAssertTrue(PlayerWindowController.windows.isEmpty, "окна плеера сами не создаются")
        XCTAssertEqual(PlayerSystem.plan(openWindows: 0, playing: false, keepAwake: true),
                       .init(preventDisplaySleep: false, remoteCommands: false))
        XCTAssertEqual(PlayerSystem.plan(openWindows: 1, playing: false, keepAwake: true),
                       .init(preventDisplaySleep: false, remoteCommands: true), "пауза — экран может гаснуть")
        XCTAssertEqual(PlayerSystem.plan(openWindows: 1, playing: true, keepAwake: true),
                       .init(preventDisplaySleep: true, remoteCommands: true))
        XCTAssertEqual(PlayerSystem.plan(openWindows: 1, playing: true, keepAwake: false),
                       .init(preventDisplaySleep: false, remoteCommands: true), "настройка выключена — утверждения нет")
        PlayerSystem.shared.update()
        XCTAssertFalse(PlayerSystem.shared.holdsAssertion)
        XCTAssertFalse(PlayerSystem.shared.handlesRemoteCommands)
        XCTAssertFalse(PlayerSystem.shared.publishesNowPlaying)
        let model = PlayerModel(silent: true, positions: PositionStore(file: nil))
        XCTAssertEqual(model.activeObserverCount, 0, "модель без файла ни на что не подписана")
    }

    func testSwitcherCacheTimerIsOnlyAFallback() {
        XCTAssertGreaterThanOrEqual(AppSwitcher.cacheRefreshInterval, 60)
    }
}
