import Foundation
import MUCore
import MUDesign

/// «Что нужно для работы» на странице подсказчика: ИИ со страницы «ИИ», микрофон, звук звонка, расшифровка.
/// Чистая логика: состояние системы читает страница (`Permissions` — без системных окон), здесь только строки.
package enum CopilotReadiness {
    /// Состояние выбранного сервиса ИИ (со страницы «ИИ»).
    package enum AIState: Equatable {
        case off, checking, connected, notFound, notLoggedIn, problem(String)
    }

    package struct Item: Equatable, Identifiable {
        package enum Fix: Equatable { case aiPage, microphone, screenRecording, downloadModel(language: String) }
        package let id: String
        package let tone: DS.Tone
        package let label: String
        package let detail: String?
        package let fix: Fix?
    }

    /// Расшифровка на Mac для языка встречи (проверка без скачивания и без системных окон).
    package enum Transcription: Equatable {
        /// Модель SpeechAnalyzer установлена.
        case modelInstalled(language: String)
        /// Модель не скачана; `fallback` — есть ли пока распознавание речи macOS на устройстве.
        case modelMissing(language: String, fallback: Bool)
        case downloading(language: String)
        /// SpeechAnalyzer нет (macOS до 26) — только распознавание речи macOS на устройстве.
        case fallbackOnly(language: String)
        case unsupported(language: String)
    }

    package static func items(service: String, ai: AIState, microphone: Permissions.Level, screenAudio: Bool,
                              transcription: Transcription? = nil) -> [Item] {
        var items: [Item] = []
        switch ai {
        case .off:
            items.append(Item(id: "ai", tone: .warning, label: "ИИ выключен", detail: "Включите ИИ на странице «ИИ» — подсказчик отвечает через него", fix: .aiPage))
        case .checking:
            items.append(Item(id: "ai", tone: .neutral, label: "\(service): проверяю…", detail: nil, fix: nil))
        case .connected:
            items.append(Item(id: "ai", tone: .success, label: "\(service) подключён", detail: nil, fix: nil))
        case .notFound:
            items.append(Item(id: "ai", tone: .warning, label: "\(service) не найден", detail: "Поставьте и подключите его на странице «ИИ»", fix: .aiPage))
        case .notLoggedIn:
            items.append(Item(id: "ai", tone: .warning, label: "\(service): не выполнен вход", detail: "Как войти — на странице «ИИ»", fix: .aiPage))
        case .problem(let message):
            items.append(Item(id: "ai", tone: .warning, label: "\(service): \(message)", detail: nil, fix: .aiPage))
        }
        switch microphone {
        case .granted:
            items.append(Item(id: "mic", tone: .success, label: "Микрофон разрешён", detail: nil, fix: nil))
        case .notAsked:
            items.append(Item(id: "mic", tone: .neutral, label: "Микрофон", detail: "Mac спросит разрешение при первом включении — чтобы слышать ваши ответы", fix: nil))
        case .denied:
            items.append(Item(id: "mic", tone: .warning, label: "Микрофон запрещён", detail: "Разрешите Mac Utils в «Конфиденциальность и безопасность → Микрофон»", fix: .microphone))
        }
        if screenAudio {
            items.append(Item(id: "audio", tone: .success, label: "Звук звонка разрешён", detail: nil, fix: nil))
        } else {
            items.append(Item(id: "audio", tone: .neutral, label: "Звук звонка",
                              detail: "Собеседников слышно через «Запись экрана и системного звука»: Mac спросит при первом включении. Сам экран не записывается",
                              fix: .screenRecording))
        }
        let name = CopilotListenFailure.languageName
        switch transcription {
        case .modelInstalled(let l):
            items.append(Item(id: "speech", tone: .success, label: "Расшифровка на Mac: \(name(l))", detail: nil, fix: nil))
        case .modelMissing(let l, let fallback):
            items.append(Item(id: "speech", tone: fallback ? .neutral : .warning, label: "Модель распознавания: \(name(l))",
                              detail: fallback ? "Не скачана — пока работает распознавание речи macOS. С моделью точнее; скачается один раз"
                                               : "Не скачана — без неё подсказчик не услышит звонок. Скачается один раз, дальше всё на Mac",
                              fix: .downloadModel(language: l)))
        case .downloading(let l):
            items.append(Item(id: "speech", tone: .neutral, label: "Модель распознавания: \(name(l))", detail: "Скачивается…", fix: nil))
        case .fallbackOnly(let l):
            items.append(Item(id: "speech", tone: .success, label: "Расшифровка на Mac: \(name(l))",
                              detail: "Распознавание речи macOS на устройстве; Mac спросит разрешение при первом включении", fix: nil))
        case .unsupported(let l):
            items.append(Item(id: "speech", tone: .warning, label: "Язык не распознаётся: \(name(l))",
                              detail: CopilotListenFailure.languageUnsupported(language: l).message, fix: nil))
        case nil:
            break
        }
        return items
    }

    /// Всё готово: можно включать без вопросов от Mac.
    package static func ready(_ items: [Item]) -> Bool { items.allSatisfy { $0.tone == .success } }
}
