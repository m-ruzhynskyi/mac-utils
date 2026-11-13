import Foundation

/// Кто говорит: собеседники (звук программы звонка) или вы (микрофон).
package enum CopilotSpeaker: String, Equatable {
    case other, me
}

package struct Utterance: Equatable, Identifiable {
    package let id = UUID()
    package let speaker: CopilotSpeaker
    package let text: String
    package let at: Date
    package init(_ speaker: CopilotSpeaker, _ text: String, at: Date = Date()) {
        self.speaker = speaker
        self.text = text
        self.at = at
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

    package init(meetingLanguage: String? = nil, answerLanguage: String? = nil, autoAnswer: Bool = true,
                 about: String = "", placement: CopilotPlacement = .underCamera) {
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

    package static func load(_ d: UserDefaults = .standard) -> CopilotSettings {
        CopilotSettings(
            meetingLanguage: d.string(forKey: meetingLanguage).flatMap { $0.isEmpty ? nil : $0 },
            answerLanguage: d.string(forKey: answerLanguage).flatMap { $0.isEmpty ? nil : $0 },
            autoAnswer: d.object(forKey: autoAnswer) as? Bool ?? true,
            about: d.string(forKey: about) ?? "",
            placement: d.string(forKey: placement).flatMap(CopilotPlacement.init(rawValue:)) ?? .underCamera)
    }
}
