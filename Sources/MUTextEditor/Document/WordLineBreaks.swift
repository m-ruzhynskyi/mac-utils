import Foundation

/// Где Word переносит строку по словам, а TextKit (правила UAX #14) — нет и наоборот. Перенос можно только запретить:
/// `DocumentController` отвечает на вопрос `NSLayoutManagerDelegate` перед каждым переносом по словам.
package enum WordLineBreaks {
    /// Можно ли перенести строку перед знаком `index` показанного текста.
    package static func allowsBreak(before index: Int, in text: NSString) -> Bool {
        guard index > 0, index <= text.length else { return true }
        // «Купли/продажи», «и/или»: Word после косой черты не переносит, слово уходит на новую строку целиком.
        return text.character(at: index - 1) != 0x2F
    }
}
