import Foundation

/// Кто говорит: собеседники (звук программы звонка) или вы (микрофон).
package enum CopilotSpeaker: String, Equatable {
    case other, me
}

/// Когда фраза звучала (по расшифровке), а не когда пришла в подсказчик: между ними проходят пауза и доразбор.
package struct SpeechSpan: Equatable, Sendable {
    package var start: Date
    package var end: Date
    package init(start: Date, end: Date) { self.start = start; self.end = end }
}

package struct Utterance: Equatable, Identifiable {
    package let id: UUID
    package let speaker: CopilotSpeaker
    package let text: String
    /// Момент прихода в подсказчик.
    package let at: Date
    /// Когда звучала; если расшифровка не знает — как `at`.
    package let spoke: SpeechSpan
    package var started: Date { spoke.start }
    package var ended: Date { spoke.end }
    /// Та же реплика, продлённая следующим куском: идентификатор сохраняется.
    package init(id: UUID, _ other: Utterance) {
        self.id = id
        speaker = other.speaker
        text = other.text
        at = other.at
        spoke = other.spoke
    }

    package init(_ speaker: CopilotSpeaker, _ text: String, at: Date = Date(), spoke: SpeechSpan? = nil) {
        id = UUID()
        self.speaker = speaker
        self.text = text
        self.at = at
        self.spoke = spoke ?? SpeechSpan(start: at, end: at)
    }
}

/// Ответ: первая строка — фраза, которую можно сказать вслух; дальше 2–4 пункта.
package struct CopilotAnswer: Equatable {
    package var say: String
    package var points: [String]
    /// Строка пришла целиком (дальше идут пункты) — можно показывать как готовую.
    package var sayComplete: Bool
    package static let empty = CopilotAnswer(say: "", points: [], sayComplete: false)
    package var isEmpty: Bool { say.isEmpty && points.isEmpty }
    package init(say: String, points: [String], sayComplete: Bool) {
        self.say = say
        self.points = points
        self.sayComplete = sayComplete
    }
}

/// Где стоит панель.
package enum CopilotPlacement: String, CaseIterable, Equatable {
    case underCamera, side, secondScreen
    package var title: String {
        switch self {
        case .underCamera: return "Под камерой"
        case .side: return "Сбоку"
        case .secondScreen: return "iPad / второй экран"
        }
    }
}

package struct CopilotSettings: Equatable {
    /// Язык встречи: nil — определять самому («Сам»).
    package var meetingLanguage: String?
    /// Язык ответов: nil — как во встрече.
    package var answerLanguage: String?
    package var autoAnswer: Bool
    package var about: String
    package var placement: CopilotPlacement
    /// Экран для панели в режиме «iPad / второй экран» (id); пусто — первый не основной.
    package var screenID: String?
    /// Реагировать на паузу ≥ 0,7 с по промежуточному тексту, не дожидаясь финала расшифровки (быстрее на 1–2 с).
    package var reactToPauses: Bool
    /// Быстрые модели и малое «размышление» (первая строка за ~2 с). Выключить — основные модели.
    package var fastModels: Bool
    /// Гибрид: первая строка — от быстрой модели, пункты — от основной, одновременно (два запроса вместо одного).
    package var hybrid: Bool

    package init(meetingLanguage: String? = nil, answerLanguage: String? = nil, autoAnswer: Bool = true,
                 about: String = "", placement: CopilotPlacement = .underCamera, screenID: String? = nil, reactToPauses: Bool = true,
                 fastModels: Bool = true, hybrid: Bool = false) {
        self.fastModels = fastModels
        self.hybrid = hybrid
        self.screenID = screenID
        self.reactToPauses = reactToPauses
        self.meetingLanguage = meetingLanguage
        self.answerLanguage = answerLanguage
        self.autoAnswer = autoAnswer
        self.about = about
        self.placement = placement
    }

    package static let languages: [(code: String?, title: String)] = [
        (nil, "Сам"), ("ru", "Русский"), ("uk", "Українська"), ("en", "English"), ("de", "Deutsch"),
    ]
}

/// Настройки подсказчика в `UserDefaults`. Включённость здесь НЕ хранится: подсказчик включается только вручную и
/// после перезапуска всегда выключен.
package enum CopilotPrefs {
    package static let meetingLanguage = "copilotMeetingLanguage"
    package static let answerLanguage = "copilotAnswerLanguage"
    package static let autoAnswer = "copilotAutoAnswer"
    package static let about = "copilotAbout"
    package static let placement = "copilotPlacement"
    package static let screenID = "copilotScreenID"
    package static let reactToPauses = "copilotReactToPauses"
    package static let fastModels = "copilotFastModels"
    package static let hybrid = "copilotHybrid"

    package static func load(_ d: UserDefaults = .standard) -> CopilotSettings {
        CopilotSettings(
            meetingLanguage: d.string(forKey: meetingLanguage).flatMap { $0.isEmpty ? nil : $0 },
            answerLanguage: d.string(forKey: answerLanguage).flatMap { $0.isEmpty ? nil : $0 },
            autoAnswer: d.object(forKey: autoAnswer) as? Bool ?? true,
            about: d.string(forKey: about) ?? "",
            placement: d.string(forKey: placement).flatMap(CopilotPlacement.init(rawValue:)) ?? .underCamera,
            screenID: d.string(forKey: screenID).flatMap { $0.isEmpty ? nil : $0 },
            reactToPauses: d.object(forKey: reactToPauses) as? Bool ?? true,
            fastModels: d.object(forKey: fastModels) as? Bool ?? true,
            hybrid: d.object(forKey: hybrid) as? Bool ?? false)
    }
}
