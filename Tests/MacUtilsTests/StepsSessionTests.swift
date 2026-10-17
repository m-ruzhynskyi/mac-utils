import CoreGraphics
import SwiftUI
import XCTest
@testable import MacUtils

/// Сессия коллажа без окон и без настоящего захвата: окружение (`StepsEnvironment`) подменено.
@MainActor
final class StepsSessionTests: XCTestCase {
    private struct SaveFailed: LocalizedError {
        var errorDescription: String? { "папка снимков недоступна" }
    }

    private var toasts: [String] = []
    private var copies = 0
    private var saves = 0
    private var quiet: [CGImage] = []

    private func image(_ width: Int = 64, _ height: Int = 48) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Окружение: сохранить — `save`, скопировать — `copy`, начать захват — `capture`.
    private func setEnvironment(save: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/Коллаж шагов.png")),
                                copy: Bool = true, capture: Bool = true) {
        var env = StepsEnvironment()
        env.showsWindows = false
        env.toast = { [unowned self] text, _, _ in toasts.append(text) }
        env.save = { [unowned self] _, done in saves += 1; done(save) }
        env.copy = { [unowned self] _, done in copies += 1; done(copy) }
        env.deliverQuietly = { [unowned self] image in quiet.append(image) }
        env.startCapture = { capture }
        env.captureBusy = { false }
        StepsSession.environment = env
    }

    private func session(steps: Int) -> StepsSession {
        for index in 0..<steps {
            StepsSession.add(image(64 + index), unit: 2, rect: CGRect(x: 0, y: 0, width: 100, height: 80))
        }
        return StepsSession.current!
    }

    override func setUp() async throws {
        setEnvironment()
        StepsSession.current?.discard()
        toasts = []
    }

    override func tearDown() async throws {
        StepsSession.current?.discard()
        StepsSession.environment = StepsEnvironment()
    }

    func testSaveFailureKeepsStepsAndPutsCollageOnClipboard() {
        setEnvironment(save: .failure(SaveFailed()))
        let session = session(steps: 3)
        session.setCaption("Откройте меню", for: session.model.steps[0].id)
        var outcome: Bool?
        session.deliver(image(), action: .save) { outcome = $0 }
        XCTAssertEqual(outcome, false)
        XCTAssertTrue(StepsSession.current === session, "сессия не закрыта")
        XCTAssertEqual(session.model.count, 3)
        XCTAssertEqual(session.model.steps[0].caption, "Откройте меню", "подписи на месте")
        XCTAssertEqual(copies, 1, "запасной путь — буфер обмена")
        XCTAssertTrue(toasts.last?.contains("скопирован в буфер обмена") == true, toasts.joined(separator: " | "))
        XCTAssertTrue(toasts.last?.contains("папка снимков недоступна") == true)
    }

    func testSaveAndClipboardFailureStillKeepsSteps() {
        setEnvironment(save: .failure(SaveFailed()), copy: false)
        let session = session(steps: 2)
        var outcome: Bool?
        session.deliver(image(), action: .save) { outcome = $0 }
        XCTAssertEqual(outcome, false)
        XCTAssertTrue(StepsSession.current === session)
        XCTAssertTrue(toasts.last?.contains("попробуйте ещё раз") == true)
    }

    func testSuccessfulSaveOrCopyEndsTheSession() {
        let session = session(steps: 2)
        var outcome: Bool?
        session.deliver(image(), action: .save) { outcome = $0 }
        XCTAssertEqual(outcome, true)
        XCTAssertNil(StepsSession.current)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(copies, 0)
        XCTAssertTrue(toasts.last?.hasPrefix("Коллаж сохранён") == true)

        let copied = self.session(steps: 1)
        copied.deliver(image(), action: .copy) { outcome = $0 }
        XCTAssertEqual(outcome, true)
        XCTAssertNil(StepsSession.current)
    }

    func testCopyFailureKeepsSession() {
        setEnvironment(copy: false)
        let session = session(steps: 2)
        var outcome: Bool?
        session.deliver(image(), action: .copy) { outcome = $0 }
        XCTAssertEqual(outcome, false)
        XCTAssertTrue(StepsSession.current === session)
    }

    func testCancelAsksWhenThereAreTwoOrMoreSteps() {
        let session = session(steps: 2)
        session.cancel()
        XCTAssertTrue(session.confirmingCancel, "сначала вопрос в панели")
        XCTAssertTrue(StepsSession.current === session)
        session.keepSteps()
        XCTAssertFalse(session.confirmingCancel)
        XCTAssertEqual(session.model.count, 2)
        session.cancel()
        session.cancel()
        XCTAssertNil(StepsSession.current, "второе «Удалить» отменяет коллаж")
        XCTAssertEqual(toasts.last, "Коллаж отменён")
        // Один шаг — без вопроса.
        let single = self.session(steps: 1)
        single.cancel()
        XCTAssertNil(StepsSession.current)
    }

    func testClosedCaptureCancelsRetake() {
        let session = session(steps: 2)
        session.retake(session.model.steps[0].id)
        XCTAssertEqual(session.model.retakeNumber, 1, "захват начат — пересъёмка ждёт снимка")
        XCTAssertEqual(StepsSession.captureHint, "Пересъёмка шага 1 · Enter — заменить")
        XCTAssertFalse(StepsSession.captureClosed(), "без предпросмотра фокус возвращается прошлому приложению")
        XCTAssertNil(session.model.retakeNumber, "Esc в режиме снимка отменяет пересъёмку")
        XCTAssertEqual(StepsSession.captureHint, "Шаг 3 коллажа · Enter — добавить")
        // Захват уступил место записи экрана: пересъёмка тоже отменяется, окна вернутся позже.
        session.retake(session.model.steps[1].id)
        XCTAssertFalse(StepsSession.captureClosed(resume: false))
        XCTAssertNil(session.model.retakeNumber)
    }

    func testRetakeIsDroppedWhenCaptureCannotStart() {
        setEnvironment(capture: false)
        let session = session(steps: 2)
        session.retake(session.model.steps[1].id)
        XCTAssertNil(session.model.retakeNumber, "захват не начался — следующий снимок не заменит шаг молча")
        StepsSession.add(image(), unit: 2, rect: nil)
        XCTAssertEqual(session.model.count, 3)
    }

    func testRetakeReplacesStepThroughSession() {
        let session = session(steps: 2)
        let target = session.model.steps[1].id
        session.retake(target)
        StepsSession.add(image(300, 200), unit: 1, rect: nil)
        XCTAssertEqual(session.model.count, 2)
        XCTAssertEqual(session.model.steps[1].id, target)
        XCTAssertEqual(session.model.steps[1].image.width, 300)
    }

    func testFinishDeliversWithSavedSettingsAndEnds() {
        let session = session(steps: 2)
        session.setCaption("Готово", for: session.model.steps[1].id)
        session.finish()
        XCTAssertNil(StepsSession.current)
        XCTAssertEqual(quiet.count, 1, "при выходе коллаж собирается и выдаётся без вопросов")
        XCTAssertTrue(toasts.isEmpty)
    }

    func testCaptureExcludesNothingWithoutWindows() {
        _ = session(steps: 1)
        XCTAssertEqual(StepsSession.prepareForCapture(), [], "окон нет — исключать нечего")
        XCTAssertEqual(StepsSession.proposedRect, CGRect(x: 0, y: 0, width: 100, height: 80))
    }
}
