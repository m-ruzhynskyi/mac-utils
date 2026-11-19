import Foundation

/// История значений `$` (V3): подсказки при вводе значения. Хранится только в памяти текущего сеанса и по имени знака;
/// на диск и в `UserDefaults` не пишется никогда (значения — персональные данные), настройки «сохранять» нет.
@MainActor
package final class DollarHistory {
    /// Общая история сеанса: живёт, пока работает программа; при выходе исчезает.
    package static let session = DollarHistory()

    package static let limitPerName = 10
    package static let limitNames = 200

    private var byName: [String: [String]] = [:]
    private var order: [String] = []

    package init() {}

    /// Имя знака: подпись перед `$` в его строке (без двоеточия и пробелов по краям, без учёта регистра); у длинной — последние
    /// 40 знаков, ближайшие к `$` («…, фамилия, имя, отчество: $»), а не начало строки.
    /// Знак без подписи получает пустое имя — у них общая история.
    package nonisolated static func name(forDollarAt offset: Int, in text: NSString) -> String {
        guard offset >= 0, offset <= text.length else { return "" }
        let lineStart = text.lineRange(for: NSRange(location: min(offset, max(0, text.length - 1)), length: 0)).location
        let start = min(lineStart, offset)
        let label = text.substring(with: NSRange(location: start, length: offset - start))
        let trimmed = label.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":：-–—\u{00A0}")))
        return String(trimmed.lowercased().suffix(40)).trimmingCharacters(in: .whitespaces)
    }

    /// Запомнить введённое значение под именем знака; повтор поднимается наверх, пустые значения не запоминаются.
    package func record(_ value: String, name: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var list = byName[name] ?? []
        list.removeAll { $0 == clean }
        list.insert(clean, at: 0)
        if list.count > Self.limitPerName { list.removeLast(list.count - Self.limitPerName) }
        byName[name] = list
        order.removeAll { $0 == name }
        order.append(name)
        if order.count > Self.limitNames, let oldest = order.first {
            order.removeFirst()
            byName[oldest] = nil
        }
    }

    /// Подсказки для знака: последние первыми; `prefix` отсекает не подходящие по началу (без учёта регистра).
    package func suggestions(name: String, prefix: String = "") -> [String] {
        let list = byName[name] ?? []
        guard !prefix.isEmpty else { return list }
        return list.filter { $0.lowercased().hasPrefix(prefix.lowercased()) && $0.lowercased() != prefix.lowercased() }
    }

    package func clear() {
        byName = [:]
        order = []
    }

    package var isEmpty: Bool { byName.isEmpty }
}

extension DollarPanelModel {
    /// Запомнить значение, введённое для знака (имя — по тексту, где знак стоит).
    package func remember(_ value: String, for entry: DollarEntry, in text: NSString, history: DollarHistory = .session) {
        history.record(value, name: DollarHistory.name(forDollarAt: entry.mark.dollar, in: text))
    }

    /// Подсказки значений для знака из истории сеанса.
    package func suggestions(for entry: DollarEntry, in text: NSString, prefix: String = "", history: DollarHistory = .session) -> [String] {
        history.suggestions(name: DollarHistory.name(forDollarAt: entry.mark.dollar, in: text), prefix: prefix)
    }
}
