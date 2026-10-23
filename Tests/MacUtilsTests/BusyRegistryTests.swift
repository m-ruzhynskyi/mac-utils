import Carbon.HIToolbox
import XCTest
@testable import MacUtils
@testable import MUCore

@MainActor
final class BusyRegistryTests: XCTestCase {
    typealias Reason = BusyRegistry.Reason

    func testEmptyRegistryIsNotBusy() {
        let registry = BusyRegistry()
        XCTAssertFalse(registry.isBusy)
        XCTAssertEqual(registry.active, [])
        XCTAssertFalse(BusyRegistry.shouldDefer(registry.active))
        XCTAssertNil(BusyRegistry.quitPrompt(for: registry.active))
    }

    func testBeginEndCountsPerReason() {
        let registry = BusyRegistry()
        registry.begin(.broadcast)
        registry.begin(.broadcast)
        XCTAssertTrue(registry.isBusy)
        registry.end(.broadcast)
        XCTAssertTrue(registry.isActive(.broadcast), "вторая причина ещё держит")
        registry.end(.broadcast)
        XCTAssertFalse(registry.isBusy)
        registry.end(.broadcast)
        registry.end(.steps)
        XCTAssertFalse(registry.isBusy, "лишний end не уводит счётчик в минус")
        registry.begin(.broadcast)
        XCTAssertTrue(registry.isBusy, "после лишних end begin работает как обычно")
    }

    func testReasonsAreIndependent() {
        let registry = BusyRegistry()
        registry.begin(.screenRecording)
        registry.begin(.uninstalling)
        registry.end(.screenRecording)
        XCTAssertEqual(registry.active, [.uninstalling])
    }

    func testProviderReflectsLiveStateWithoutBeginEnd() {
        let registry = BusyRegistry()
        var recording = false
        registry.setProvider(.screenRecording) { recording }
        XCTAssertFalse(registry.isBusy)
        recording = true
        XCTAssertEqual(registry.active, [.screenRecording])
        recording = false
        XCTAssertFalse(registry.isBusy, "состояние берётся в момент вопроса, «забытого end» быть не может")
    }

    func testProviderAndCounterCombine() {
        let registry = BusyRegistry()
        registry.setProvider(.viewing) { false }
        registry.begin(.viewing)
        XCTAssertTrue(registry.isActive(.viewing))
        registry.end(.viewing)
        XCTAssertFalse(registry.isActive(.viewing))
    }

    func testActiveKeepsDeclarationOrder() {
        let registry = BusyRegistry()
        registry.begin(.uninstalling)
        registry.begin(.broadcast)
        registry.begin(.screenRecording)
        XCTAssertEqual(registry.active, [.screenRecording, .broadcast, .uninstalling])
    }

    func testEveryReasonHasAReadableTitle() {
        for reason in Reason.allCases { XCTAssertFalse(reason.title.isEmpty, reason.rawValue) }
        XCTAssertEqual(Set(Reason.allCases.map(\.title)).count, Reason.allCases.count, "названия не повторяются")
    }

    func testListFormatting() {
        XCTAssertEqual(BusyRegistry.list([]), "")
        XCTAssertEqual(BusyRegistry.list([.screenRecording]), "запись экрана")
        XCTAssertEqual(BusyRegistry.list([.screenRecording, .broadcast]), "запись экрана и трансляция экрана")
        XCTAssertEqual(BusyRegistry.list([.screenRecording, .broadcast, .uninstalling]), "запись экрана, трансляция экрана и удаление программ")
    }

    func testQuitPromptForWindDownReasons() throws {
        let prompt = try XCTUnwrap(BusyRegistry.quitPrompt(for: [.screenRecording, .broadcast]))
        XCTAssertEqual(prompt.title, "Сейчас идёт: запись экрана и трансляция экрана")
        XCTAssertEqual(prompt.confirm, "Остановить и выйти")
        XCTAssertEqual(prompt.cancel, "Не выходить")
        XCTAssertTrue(prompt.message.contains("запись сохранится"))
        XCTAssertFalse(prompt.message.contains("Удаление программ"))
    }

    func testQuitPromptWarnsAboutUninstallAndProcessing() throws {
        let uninstall = try XCTUnwrap(BusyRegistry.quitPrompt(for: [.uninstalling]))
        XCTAssertEqual(uninstall.confirm, "Выйти", "останавливать нечего — кнопка без слова «остановить»")
        XCTAssertTrue(uninstall.message.contains("Удаление программ прервётся"))
        let processing = try XCTUnwrap(BusyRegistry.quitPrompt(for: [.meetingProcessing]))
        XCTAssertTrue(processing.message.contains("Расшифровка"))
        let mixed = try XCTUnwrap(BusyRegistry.quitPrompt(for: [.meetingRecording, .uninstalling]))
        XCTAssertEqual(mixed.confirm, "Остановить и выйти")
        XCTAssertTrue(mixed.message.contains("запись сохранится") && mixed.message.contains("Удаление программ"))
    }

    func testWindDownOrderAndSelection() {
        XCTAssertEqual(BusyRegistry.windDownOrder([.viewing, .broadcast, .meetingRecording, .screenRecording]),
                       [.screenRecording, .meetingRecording, .broadcast, .viewing], "записи раньше эфира")
        XCTAssertEqual(BusyRegistry.windDownOrder([.uninstalling, .meetingProcessing]), [], "то, что остановить нельзя, не вызывается")
        XCTAssertEqual(BusyRegistry.windDownOrder([.steps, .scrollCapture]), [.scrollCapture, .steps])
        XCTAssertEqual(BusyRegistry.windDownOrder([]), [])
    }

    func testCanWindDown() {
        XCTAssertTrue(Reason.screenRecording.canWindDown)
        XCTAssertTrue(Reason.broadcast.canWindDown)
        XCTAssertFalse(Reason.uninstalling.canWindDown)
        XCTAssertFalse(Reason.meetingProcessing.canWindDown)
    }

    func testAutoUpdateDefersWhileAnythingIsActive() {
        let registry = BusyRegistry()
        XCTAssertFalse(BusyRegistry.shouldDefer(registry.active))
        for reason in Reason.allCases {
            let r = BusyRegistry()
            r.begin(reason)
            XCTAssertTrue(BusyRegistry.shouldDefer(r.active), "\(reason.rawValue) откладывает автообновление")
        }
    }

    func testDefaultProvidersCoverAllReasonsAndAreIdleInTests() {
        let registry = BusyRegistry()
        registry.installDefaultProviders()
        // В тестах ничего не записывается и не транслируется.
        XCTAssertEqual(registry.active, [])
        XCTAssertFalse(registry.isBusy)
    }

    // MARK: MAJOR-2: просмотр и шаги

    func testViewerIsBusyOnlyWhileConnected() {
        XCTAssertTrue(BusyRegistry.viewerIsConnected(.connecting))
        XCTAssertTrue(BusyRegistry.viewerIsConnected(.waiting))
        XCTAssertTrue(BusyRegistry.viewerIsConnected(.watching))
        XCTAssertTrue(BusyRegistry.viewerIsConnected(.reconnecting(attempt: 1)), "переподключение — просмотр ещё идёт")
        XCTAssertFalse(BusyRegistry.viewerIsConnected(.idle))
        XCTAssertFalse(BusyRegistry.viewerIsConnected(.ended("Трансляция завершена")), "открытое окно с «завершена» ничего не держит")
    }

    func testStepsSessionExpiresWhenForgotten() {
        let now = Date()
        XCTAssertTrue(BusyRegistry.isFresh(now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(BusyRegistry.isFresh(now.addingTimeInterval(-3599), now: now))
        XCTAssertFalse(BusyRegistry.isFresh(now.addingTimeInterval(-3601), now: now))
        XCTAssertFalse(BusyRegistry.isFresh(now.addingTimeInterval(-86_400), now: now), "вчерашний коллаж обновление не задерживает")
        XCTAssertTrue(BusyRegistry.isFresh(now.addingTimeInterval(5), now: now), "часы ушли назад — не считаем старым")
    }

    func testUpdaterDoesNotDeferForever() {
        // Закрытое/завершённое окно просмотра и забытые шаги: реестр пуст — установка проходит.
        let registry = BusyRegistry()
        registry.setProvider(.viewing) { BusyRegistry.viewerIsConnected(.ended("x")) }
        registry.setProvider(.steps) { BusyRegistry.isFresh(Date().addingTimeInterval(-7200)) }
        XCTAssertFalse(BusyRegistry.shouldDefer(registry.active))
    }

    // MARK: MAJOR-3: системное завершение

    func testSystemShutdownNeverShowsAWindow() {
        for reasons in [[Reason.screenRecording], [.broadcast, .viewing], [.uninstalling], [.meetingProcessing, .steps]] {
            XCTAssertEqual(BusyRegistry.terminationPlan(reasons: reasons, systemShutdown: true, confirmed: false), .windDownSilently, "\(reasons)")
        }
    }

    func testQuitByUserAsks() throws {
        let plan = BusyRegistry.terminationPlan(reasons: [.screenRecording], systemShutdown: false, confirmed: false)
        guard case .ask(let prompt) = plan else { return XCTFail() }
        XCTAssertEqual(prompt, BusyRegistry.quitPrompt(for: [.screenRecording]))
    }

    func testNothingRunningQuitsImmediatelyInAnyCase() {
        XCTAssertEqual(BusyRegistry.terminationPlan(reasons: [], systemShutdown: true, confirmed: false), .now)
        XCTAssertEqual(BusyRegistry.terminationPlan(reasons: [], systemShutdown: false, confirmed: false), .now)
        XCTAssertEqual(BusyRegistry.terminationPlan(reasons: [], systemShutdown: false, confirmed: true), .now)
    }

    func testConfirmedRestartForUpdateDoesNotAskTwice() {
        XCTAssertEqual(BusyRegistry.terminationPlan(reasons: [.broadcast], systemShutdown: false, confirmed: true), .windDownSilently)
    }

    func testConfirmationFlagIsOffByDefault() {
        XCTAssertFalse(BusyRegistry().terminationConfirmed)
    }

    func testWaitLimits() {
        XCTAssertEqual(BusyRegistry.waitAttempts(for: .screenRecording, silent: false), 600, "GIF собирается долго")
        XCTAssertEqual(BusyRegistry.waitAttempts(for: .broadcast, silent: false), 80)
        for reason in Reason.allCases {
            XCTAssertEqual(BusyRegistry.waitAttempts(for: reason, silent: true), 20, "при выключении ждём недолго: \(reason.rawValue)")
        }
        XCTAssertLessThanOrEqual(BusyRegistry.systemShutdownLimit, 10)
    }

    // MARK: rel-4fix N1: сохранение снимка

    func testScreenshotSavingDefersUpdatesAndIsWaitedOnQuit() {
        let registry = BusyRegistry()
        registry.begin(.screenshotSaving)
        XCTAssertTrue(BusyRegistry.shouldDefer(registry.active))
        XCTAssertTrue(Reason.screenshotSaving.canWindDown)
        XCTAssertEqual(BusyRegistry.windDownOrder([.broadcast, .screenshotSaving, .screenRecording]),
                       [.screenshotSaving, .screenRecording, .broadcast], "сначала дописывается снимок")
        registry.end(.screenshotSaving)
        XCTAssertFalse(registry.isBusy)
    }

    func testOverlappingScreenshotSavesCount() {
        let registry = BusyRegistry()
        registry.begin(.screenshotSaving)   // длинный снимок
        registry.begin(.screenshotSaving)   // обычный сразу за ним
        registry.end(.screenshotSaving)
        XCTAssertTrue(registry.isActive(.screenshotSaving), "пока кодируется второй, занято")
        registry.end(.screenshotSaving)
        XCTAssertFalse(registry.isBusy)
    }

    // MARK: rel-6 N1/N2: причина выхода и срок флага

    func testQuitReasonCodesOfSystemShutdown() {
        for code in [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown] {
            XCTAssertTrue(QuitReason.isSystemShutdown(OSType(code)), "\(code)")
        }
    }

    func testOrdinaryQuitIsNotSystemShutdown() {
        XCTAssertFalse(QuitReason.isSystemShutdown(nil), "⌘Q приходит без причины")
        XCTAssertFalse(QuitReason.isSystemShutdown(OSType(kAEQuitAll)))
        XCTAssertFalse(QuitReason.isSystemShutdown(0))
    }

    func testSystemQuitReasonSkipsTheWindowEvenWithoutNotification() {
        let systemQuit = false || QuitReason.isSystemShutdown(OSType(kAEShutDown))
        XCTAssertEqual(BusyRegistry.terminationPlan(reasons: [.screenRecording], systemShutdown: systemQuit, confirmed: false), .windDownSilently)
    }

    func testShutdownFlagExpires() {
        var flag = SystemShutdownFlag()
        let now = Date()
        XCTAssertFalse(flag.isActive(at: now))
        flag.note(at: now)
        XCTAssertTrue(flag.isActive(at: now.addingTimeInterval(60)))
        XCTAssertFalse(flag.isActive(at: now.addingTimeInterval(121)), "выключение отменили — следующий ⌘Q снова спросит")
        flag.note(at: now.addingTimeInterval(200))
        XCTAssertTrue(flag.isActive(at: now.addingTimeInterval(210)), "новое уведомление продлевает")
        flag.clear()
        XCTAssertFalse(flag.isActive(at: now.addingTimeInterval(210)))
    }

    func testShutdownFlagIgnoresClockGoingBackwards() {
        var flag = SystemShutdownFlag()
        let now = Date()
        flag.note(at: now)
        XCTAssertTrue(flag.isActive(at: now.addingTimeInterval(-30)))
    }
}
