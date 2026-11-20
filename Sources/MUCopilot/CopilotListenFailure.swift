import Foundation

/// Почему подсказчик не начал слушать — по-человечески и с действием (COPILOT-41), вместо «… ещё не подключён».
/// Системный запрос разрешения бывает только когда человек сам включает подсказчика (⌥⇧M, переключатель):
/// кнопки здесь только открывают настройки или скачивают модель по нажатию.
package enum CopilotListenFailure: LocalizedError, Equatable, Sendable {
    /// Модель распознавания языка не скачана (SpeechAnalyzer). `language` — код (ru, uk, en…).
    case modelMissing(language: String)
    /// Модель скачивается.
    case modelDownloading(language: String)
    case microphoneDenied
    /// Звук звонка идёт через «Запись экрана и системного звука».
    case screenAudioDenied
    /// Запасной путь (SFSpeechRecognizer) — нужно разрешение «Распознавание речи».
    case speechDenied
    /// Язык встречи не распознаётся на этом Mac (ни SpeechAnalyzer, ни распознавание на устройстве).
    case languageUnsupported(language: String)
    case other(String)

    package enum Action: Equatable, Sendable {
        case downloadModel(language: String)
        case openMicrophoneSettings
        case openScreenRecordingSettings
        case openSpeechSettings
        case chooseLanguage
    }

    /// Языки, которые подсказчик предлагает выбрать (`CopilotSettings.languages`, без «Сам»).
    package static let suggestedLanguages = ["ru", "uk", "en"]

    package static func languageName(_ code: String) -> String {
        Locale(identifier: "ru_RU").localizedString(forLanguageCode: code) ?? code
    }

    package var errorDescription: String? { message }

    package var message: String {
        switch self {
        case .modelMissing(let language): return "Нужна модель распознавания (\(Self.languageName(language))) — скачается один раз, дальше всё на Mac"
        case .modelDownloading(let language): return "Скачиваю модель распознавания (\(Self.languageName(language)))…"
        case .microphoneDenied: return "Нет доступа к микрофону: подсказчик не слышит ваши ответы"
        case .screenAudioDenied: return "Нет доступа к звуку звонка: разрешите «Запись экрана и системного звука» (сам экран не записывается)"
        case .speechDenied: return "Нет разрешения «Распознавание речи»: без него расшифровка на этом Mac не работает"
        case .languageUnsupported(let language):
            let names = Self.suggestedLanguages.map(Self.languageName).joined(separator: ", ")
            return "Язык «\(Self.languageName(language))» не распознаётся на этом Mac — выберите в «Язык встречи»: \(names)"
        case .other(let text): return text
        }
    }

    package var action: Action? {
        switch self {
        case .modelMissing(let language): return .downloadModel(language: language)
        case .modelDownloading: return nil
        case .microphoneDenied: return .openMicrophoneSettings
        case .screenAudioDenied: return .openScreenRecordingSettings
        case .speechDenied: return .openSpeechSettings
        case .languageUnsupported: return .chooseLanguage
        case .other: return nil
        }
    }

    package static func actionTitle(_ action: Action) -> String {
        switch action {
        case .downloadModel: return "Загрузить"
        case .openMicrophoneSettings, .openScreenRecordingSettings, .openSpeechSettings: return "Открыть настройки"
        case .chooseLanguage: return "Выбрать язык"
        }
    }
}

/// Какой путь расшифровки выбрать — чистое правило (проверяется тестами без Speech).
package enum CopilotTranscriptionPath: String, Equatable, Sendable {
    /// SpeechAnalyzer (macOS 26, SDK 26): SpeechTranscriber или DictationTranscriber.
    case speechAnalyzer = "SpeechAnalyzer"
    /// Запасной: SFSpeechRecognizer только на устройстве (`requiresOnDeviceRecognition`).
    case sfSpeech = "SFSpeech"

    /// Состояние модели SpeechAnalyzer для языка.
    package enum ModelState: Equatable, Sendable { case installed, downloadable, downloading, unsupported }

    /// - `analyzerBuilt`: код SpeechAnalyzer есть в сборке и macOS 26+;
    /// - `model`: состояние модели (nil — SpeechAnalyzer языка не знает);
    /// - `onDeviceSFSpeech`: SFSpeechRecognizer умеет этот язык без сети.
    package static func choose(analyzerBuilt: Bool, model: ModelState?, onDeviceSFSpeech: Bool, language: String)
        -> Result<CopilotTranscriptionPath, CopilotListenFailure> {
        if analyzerBuilt, let model {
            switch model {
            case .installed: return .success(.speechAnalyzer)
            // Модель не скачиваем сами: только по кнопке «Загрузить». Пока её нет — запасной путь, если он есть.
            case .downloadable: return onDeviceSFSpeech ? .success(.sfSpeech) : .failure(.modelMissing(language: language))
            case .downloading: return onDeviceSFSpeech ? .success(.sfSpeech) : .failure(.modelDownloading(language: language))
            case .unsupported: break
            }
        }
        return onDeviceSFSpeech ? .success(.sfSpeech) : .failure(.languageUnsupported(language: language))
    }
}
