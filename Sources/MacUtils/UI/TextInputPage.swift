import SwiftUI

/// Автозамены macOS при наборе текста (общие для всех программ).
/// Например, «точка с пробелом»: двойной пробел превращается в «. », и после точки появляется лишний пробел.
enum TextInputSettings {
    struct Option: Identifiable {
        let key: String
        let title: String
        let detail: String
        var id: String { key }
    }

    static let options: [Option] = [
        Option(key: "NSAutomaticPeriodSubstitutionEnabled", title: "Точка по двойному пробелу",
               detail: "Два пробела подряд превращаются в «. » — из-за этого после точки появляется лишний пробел."),
        Option(key: "NSAutomaticCapitalizationEnabled", title: "Заглавная буква в начале предложения",
               detail: "После точки следующее слово само начинается с большой буквы."),
        Option(key: "NSAutomaticSpellingCorrectionEnabled", title: "Автоисправление опечаток",
               detail: "Слова с ошибками заменяются при наборе."),
        Option(key: "NSAutomaticInlinePredictionEnabled", title: "Подсказки слов в строке",
               detail: "Серое продолжение слова прямо в тексте (принять — пробелом или Tab)."),
        Option(key: "NSAutomaticQuoteSubstitutionEnabled", title: "«Умные» кавычки",
               detail: "Прямые кавычки заменяются на типографские."),
        Option(key: "NSAutomaticDashSubstitutionEnabled", title: "Умные тире",
               detail: "Два дефиса превращаются в тире."),
    ]

    /// Если ключа нет — у macOS эти функции включены по умолчанию.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? Bool ?? true
    }

    static func set(_ key: String, _ on: Bool) {
        var global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        global[key] = on
        UserDefaults.standard.setPersistentDomain(global, forName: UserDefaults.globalDomain)
        // Программы, которые слушают изменения, подхватят сразу; остальные — после перезапуска.
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("NSAutomaticTextSubstitutionPreferencesChanged"), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

struct TextInputPage: View {
    @State private var values: [String: Bool] = [:]

    var body: some View {
        SettingsPage(.textInput) {
            Footnote("Самое частое: после точки сам ставится пробел — его даёт «Точка по двойному пробелу».")
            GroupLabel("Автозамены")
            ListCard {
                ForEach(TextInputSettings.options) { option in
                    ToggleRow(option.title, subtitle: option.detail, isOn: Binding(get: { values[option.key] ?? true }, set: { on in
                        values[option.key] = on
                        TextInputSettings.set(option.key, on)
                    }))
                }
            }
            Footnote("Изменения действуют в новых окнах; в уже открытых программах — после их перезапуска.")
        }
        .onAppear {
            values = Dictionary(uniqueKeysWithValues: TextInputSettings.options.map { ($0.key, TextInputSettings.isOn($0.key)) })
        }
    }
}
