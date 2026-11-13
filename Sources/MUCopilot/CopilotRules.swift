import Foundation

/// Экран в списке выбора (для «iPad / второй экран»).
package struct CopilotScreen: Equatable, Identifiable {
    package let id: String
    package let name: String
    package let isMain: Bool
    package init(id: String, name: String, isMain: Bool) {
        self.id = id
        self.name = name
        self.isMain = isMain
    }
}

package enum ScreenChoice {
    /// Какой экран взять для панели. `preferred` — выбор из настроек (id); если такого экрана нет (iPad отключён) —
    /// первый не основной, а если он один — основной.
    package static func pick(_ screens: [CopilotScreen], preferred: String?, placement: CopilotPlacement) -> CopilotScreen? {
        guard !screens.isEmpty else { return nil }
        let main = screens.first { $0.isMain } ?? screens[0]
        guard placement == .secondScreen else { return main }
        if let preferred, !preferred.isEmpty, let chosen = screens.first(where: { $0.id == preferred }) { return chosen }
        return screens.first { !$0.isMain } ?? main
    }

    /// Подпись под выбором: что будет, если выбранного экрана сейчас нет.
    package static func note(_ screens: [CopilotScreen], preferred: String?) -> String? {
        if screens.count < 2 { return "Второй экран не подключён: панель встанет на основной" }
        if let preferred, !preferred.isEmpty, !screens.contains(where: { $0.id == preferred }) {
            return "Выбранный экран не найден: панель на первом из подключённых"
        }
        return nil
    }
}

/// Склейка кусков одной реплики: расшифровка отдаёт куски по паузам, а вопрос может быть разбит надвое.
package enum UtteranceMerge {
    package static let gap: TimeInterval = 1.5

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return true }
        return ".!?…".contains(last)
    }

    /// Продолжение ли `new` предыдущей реплики `last` того же говорящего.
    package static func continues(_ last: Utterance, with new: Utterance) -> Bool {
        last.speaker == new.speaker && !endsSentence(last.text) && new.at.timeIntervalSince(last.at) <= gap
    }
}

/// Язык расшифровки по настройке: nil («Сам») — как у записи встреч, русский.
package enum CopilotLocale {
    package static func identifier(for code: String?) -> String {
        switch code {
        case "ru": return "ru_RU"
        case "uk": return "uk_UA"
        case "en": return "en_US"
        case "de": return "de_DE"
        default: return "ru_RU"
        }
    }
}
