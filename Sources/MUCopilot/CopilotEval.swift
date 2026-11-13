import Foundation

/// Записанный диалог для проверки качества ответов (`Tests/Fixtures/Copilot/*.json`).
package struct CopilotDialog: Codable, Equatable {
    package struct Line: Codable, Equatable {
        package let speaker: String
        package let text: String
        /// Сколько секунд назад прозвучала реплика (к моменту вопроса).
        package let secondsAgo: Double
    }
    package let id: String
    package let language: String
    package let kind: String
    package let about: String
    package let utterances: [Line]
    /// Есть ли в конце вопрос к пользователю (false — ждём `NO_QUESTION`).
    package let expectQuestion: Bool
    package let questionGist: String
    /// Группы ключевых слов: из каждой группы в ответе должно встретиться хотя бы одно (по корню, без регистра).
    package let keywordGroups: [[String]]

    package func utterances(now: Date) -> [Utterance] {
        utterances.map { Utterance($0.speaker == "me" ? .me : .other, $0.text, at: now.addingTimeInterval(-$0.secondsAgo)) }
    }

    package var settings: CopilotSettings {
        CopilotSettings(meetingLanguage: language, answerLanguage: nil, autoAnswer: true, about: about)
    }
}

/// Автоматическая первая оценка ответа. Это не замена чтению ответов глазами, а фильтр явных провалов.
package struct CopilotGrade: Codable, Equatable {
    package var parsedOK: Bool
    package var correctDecision: Bool
    package var sayLength: Int
    package var sayShortEnough: Bool
    package var pointCount: Int
    package var pointsInRange: Bool
    package var keywordGroupsHit: Int
    package var keywordGroupsTotal: Int
    package var notes: [String]

    package var passed: Bool { parsedOK && correctDecision && sayShortEnough && pointsInRange }
}

package enum CopilotEvalGrader {
    /// Фразу вслух не стоит делать длиннее ~280 знаков (2 предложения).
    package static let maxSayLength = 280

    package static func grade(raw: String, dialog: CopilotDialog) -> CopilotGrade {
        let parsed = CopilotPrompt.parse(raw)
        var grade = CopilotGrade(parsedOK: true, correctDecision: false, sayLength: 0, sayShortEnough: true, pointCount: 0,
                                 pointsInRange: true, keywordGroupsHit: 0, keywordGroupsTotal: dialog.keywordGroups.count, notes: [])
        switch parsed {
        case .noQuestion:
            grade.correctDecision = !dialog.expectQuestion
            if dialog.expectQuestion { grade.notes.append("модель не нашла вопрос, а он есть") }
        case .answer(let answer):
            grade.correctDecision = dialog.expectQuestion
            if !dialog.expectQuestion { grade.notes.append("ответ там, где вопроса к пользователю нет") }
            grade.sayLength = answer.say.count
            grade.parsedOK = !answer.say.isEmpty
            if answer.say.isEmpty { grade.notes.append("нет первой строки") }
            grade.sayShortEnough = answer.say.count <= maxSayLength
            if !grade.sayShortEnough { grade.notes.append("первая строка длиннее \(maxSayLength) знаков") }
            grade.pointCount = answer.points.count
            if dialog.expectQuestion {
                grade.pointsInRange = (2...4).contains(answer.points.count)
                if !grade.pointsInRange { grade.notes.append("пунктов \(answer.points.count), нужно 2–4") }
                let text = (answer.say + " " + answer.points.joined(separator: " ")).lowercased()
                grade.keywordGroupsHit = dialog.keywordGroups.filter { group in group.contains { text.contains($0.lowercased()) } }.count
                if grade.keywordGroupsHit < grade.keywordGroupsTotal { grade.notes.append("ключевых групп \(grade.keywordGroupsHit) из \(grade.keywordGroupsTotal)") }
            }
        }
        return grade
    }
}
