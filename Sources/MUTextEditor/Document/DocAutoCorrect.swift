import Foundation

/// Автозамена при наборе в «Документе» (T5): «--» → «—», прямые кавычки `"` → «ёлочки». По умолчанию выключена
/// (`Pref.docAutocorrect`, меню «Вид»). Чистая функция: по набранному знаку и тексту слева решает, какие показанные единицы
/// заменить; дальше правка идёт обычным путём (`DocTextEditor`), то есть точечно и с проверкой «без потерь».
package enum DocAutoCorrect {
    package struct Replacement: Equatable {
        /// Показанные единицы, которые заменяются (набранный знак встаёт на их место).
        package var units: NSRange
        package var text: String
    }

    package static let emDash = "—"
    package static let openQuote = "«", closeQuote = "»"

    /// - Parameters:
    ///   - units: куда набирают (курсор или выделение);
    ///   - typed: набранное; автозамена только для одного знака;
    ///   - shown: показанный текст страницы;
    ///   - isPlainText: единица показанного текста — обычный текст (не поле, не номер списка, не рисунок).
    package static func resolve(units: NSRange, typed: String, shown: NSString, isPlainText: (Int) -> Bool) -> Replacement? {
        guard typed.utf16.count == 1, units.location <= shown.length else { return nil }
        switch typed {
        case "-":
            // Второй дефис подряд: оба знака — одно тире. Три дефиса и больше (линия) не трогаем.
            let at = units.location
            guard units.length == 0, at >= 1, shown.character(at: at - 1) == 0x2D, isPlainText(at - 1) else { return nil }
            if at >= 2, shown.character(at: at - 2) == 0x2D { return nil }
            if at < shown.length, shown.character(at: at) == 0x2D { return nil }
            return Replacement(units: NSRange(location: at - 1, length: 1), text: emDash)
        case "\"":
            return Replacement(units: units, text: opens(before: units.location, in: shown) ? openQuote : closeQuote)
        default:
            return nil
        }
    }

    /// Кавычка открывающая: в начале абзаца, после пробела, открывающей скобки или тире.
    static func opens(before location: Int, in shown: NSString) -> Bool {
        guard location > 0, location <= shown.length else { return true }
        let previous = shown.character(at: location - 1)
        guard let scalar = Unicode.Scalar(previous) else { return false }
        if scalar.properties.isWhitespace { return true }
        return "([{«„—–-/\u{2028}\u{0B}".unicodeScalars.contains(scalar)
    }
}
