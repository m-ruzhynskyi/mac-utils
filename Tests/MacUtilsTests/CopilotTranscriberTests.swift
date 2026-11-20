import XCTest
@testable import MacUtils
@testable import MUCopilot

/// COPILOT-41: путь расшифровки (SpeechAnalyzer или SFSpeech на устройстве) и понятные причины, почему подсказчик не слушает.
/// Чистые правила: Speech, микрофон и системные окна здесь не трогаются.
final class CopilotTranscriberTests: XCTestCase {
    typealias Path = CopilotTranscriptionPath

    func testPathChoice() {
        // Модель установлена — SpeechAnalyzer.
        XCTAssertEqual(Path.choose(analyzerBuilt: true, model: .installed, onDeviceSFSpeech: true, language: "ru"), .success(.speechAnalyzer))
        // Модели нет: не скачиваем сами — пока запасной путь, если он есть; иначе «Нужна модель — Загрузить».
        XCTAssertEqual(Path.choose(analyzerBuilt: true, model: .downloadable, onDeviceSFSpeech: true, language: "ru"), .success(.sfSpeech))
        XCTAssertEqual(Path.choose(analyzerBuilt: true, model: .downloadable, onDeviceSFSpeech: false, language: "uk"),
                       .failure(.modelMissing(language: "uk")))
        XCTAssertEqual(Path.choose(analyzerBuilt: true, model: .downloading, onDeviceSFSpeech: false, language: "en"),
                       .failure(.modelDownloading(language: "en")))
        // Сборка без SpeechAnalyzer (так был собран 1.11.1) — запасной путь, а не «ещё не подключён».
        XCTAssertEqual(Path.choose(analyzerBuilt: false, model: nil, onDeviceSFSpeech: true, language: "ru"), .success(.sfSpeech))
        XCTAssertEqual(Path.choose(analyzerBuilt: true, model: .unsupported, onDeviceSFSpeech: true, language: "ru"), .success(.sfSpeech))
        XCTAssertEqual(Path.choose(analyzerBuilt: false, model: nil, onDeviceSFSpeech: false, language: "xx"),
                       .failure(.languageUnsupported(language: "xx")))
    }

    func testFailureTextsAndActions() {
        let model = CopilotListenFailure.modelMissing(language: "ru")
        XCTAssertTrue(model.message.contains("русский"), model.message)
        XCTAssertEqual(model.action, .downloadModel(language: "ru"))
        XCTAssertEqual(CopilotListenFailure.actionTitle(model.action!), "Загрузить")
        XCTAssertEqual(CopilotListenFailure.microphoneDenied.action, .openMicrophoneSettings)
        XCTAssertEqual(CopilotListenFailure.screenAudioDenied.action, .openScreenRecordingSettings)
        XCTAssertTrue(CopilotListenFailure.screenAudioDenied.message.contains("Запись экрана и системного звука"))
        XCTAssertEqual(CopilotListenFailure.speechDenied.action, .openSpeechSettings)
        XCTAssertEqual(CopilotListenFailure.actionTitle(.openSpeechSettings), "Открыть настройки")
        let language = CopilotListenFailure.languageUnsupported(language: "de")
        XCTAssertTrue(language.message.contains("немецкий") && language.message.contains("украинский"), language.message)
        XCTAssertEqual(language.action, .chooseLanguage)
        XCTAssertNil(CopilotListenFailure.other("x").action)
        for failure in [model, .microphoneDenied, .screenAudioDenied, .speechDenied, language] {
            XCTAssertFalse(failure.message.contains("ещё не подключён"), "старого «… ещё не подключён» больше нет")
            XCTAssertEqual(failure.localizedDescription, failure.message)
        }
    }

    /// Причина от источника звука доходит до страницы (`session.failure`) и выключает подсказчика.
    @MainActor
    func testSessionKeepsReason() {
        final class Failing: CopilotListening {
            var onFailure: (@MainActor (String) -> Void)?
            var onListenFailure: (@MainActor (CopilotListenFailure) -> Void)?
            var startError: Error?
            func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {
                if let startError { throw startError }
            }
            func stop() {}
        }
        struct NoAI: CopilotAIClient {
            func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let listener = Failing()
        let session = CopilotSession(ai: NoAI(), listener: listener, settings: { CopilotSettings() }, log: { _ in }, logError: { _ in })
        listener.startError = CopilotListenFailure.microphoneDenied
        session.start()
        XCTAssertFalse(session.isOn)
        XCTAssertEqual(session.failure, .microphoneDenied)
        XCTAssertEqual(session.error, CopilotListenFailure.microphoneDenied.message)
        listener.startError = nil
        session.start()
        XCTAssertTrue(session.isOn)
        XCTAssertNil(session.failure)
        listener.onListenFailure?(.modelMissing(language: "uk"))
        XCTAssertFalse(session.isOn, "источник сам остановился — подсказчик выключен")
        XCTAssertEqual(session.failure, .modelMissing(language: "uk"))
    }

    /// Без модели и без системных окон: сборка на SDK 26 видит код SpeechAnalyzer (на SDK 15 его не было).
    func testAnalyzerIsBuiltWithThisToolchain() {
        #if compiler(>=6.2)
        XCTAssertEqual(StreamingTranscriber.analyzerBuilt, ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
        #else
        XCTAssertFalse(StreamingTranscriber.analyzerBuilt)
        #endif
        XCTAssertEqual(StreamingTranscriber.languageCode(Locale(identifier: "uk_UA")), "uk")
    }
}
