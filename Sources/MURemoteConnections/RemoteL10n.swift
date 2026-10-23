import Foundation

/// Язык интерфейса «Удалённых подключений». По умолчанию — русский, как всё приложение.
public enum RemoteLanguage: String, CaseIterable, Sendable {
    case ru, uk, en

    /// Название языка на нём самом — для переключателя.
    public var title: String {
        switch self {
        case .ru: return "Русский"
        case .uk: return "Українська"
        case .en: return "English"
        }
    }
}

public enum RemoteL10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = RemoteLanguage.ru

    public static var language: RemoteLanguage {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    /// Перевод строки; ключ — русский текст. Нет перевода — русский (тест следит, чтобы переводы были у всех).
    public static func text(_ ru: String, in language: RemoteLanguage? = nil) -> String {
        switch language ?? self.language {
        case .ru: return ru
        case .uk: return RemoteStrings.table[ru]?.uk ?? ru
        case .en: return RemoteStrings.table[ru]?.en ?? ru
        }
    }

    /// Есть ли перевод — для теста полноты.
    static func hasTranslation(_ ru: String) -> Bool { RemoteStrings.table[ru] != nil }
}

/// Строка интерфейса модуля на выбранном языке; ключ — русский текст. Каждое `%@` по порядку заменяется
/// следующим аргументом (`String(describing:)`), поэтому в переводе порядок `%@` тот же.
public func RL(_ ru: String, _ args: Any...) -> String {
    let text = RemoteL10n.text(ru)
    guard !args.isEmpty else { return text }
    var out = ""
    var rest = Substring(text)
    var index = 0
    while let r = rest.range(of: "%@") {
        out += rest[..<r.lowerBound]
        if index < args.count { out += String(describing: args[index]) }
        index += 1
        rest = rest[r.upperBound...]
    }
    return out + rest
}
