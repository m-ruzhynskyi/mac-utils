import Foundation

/// Реакция на паузу, не дожидаясь «финала» расшифровки.
/// SpeechAnalyzer отдаёт промежуточный текст (volatile) почти сразу, а финал фразы — позже (после паузы и доразбора).
/// Settler получает оба потока и отдаёт новые слова, как только промежуточный текст не менялся `pause` секунд;
/// финал дописывает только то, что ещё не отдано. Чистая логика: время приходит параметром.
package struct VolatileSettler: Equatable {
    /// Сколько текст должен не меняться, чтобы считать фразу законченной (0,7 с по задаче).
    package static let defaultPause: TimeInterval = 0.7

    package var pause: TimeInterval
    private var words: [String] = []
    private var changedAt: Date?
    private var emitted = 0
    private var pieceStart: Date?
    /// Когда звучал последний отданный кусок (начало — первое изменение текста, конец — последнее).
    package private(set) var lastSpan: SpeechSpan?

    package init(pause: TimeInterval = VolatileSettler.defaultPause) { self.pause = pause }

    private static func split(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Слово без знаков препинания и регистра: финал часто добавляет точку и заглавную букву.
    static func key(_ word: String) -> String { word.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Новый промежуточный текст текущей фразы (он целиком заменяет прежний).
    package mutating func volatile(_ text: String, at date: Date) {
        let new = Self.split(text)
        if new.map(Self.key) != words.map(Self.key) { changedAt = date; if pieceStart == nil { pieceStart = date } }
        words = new
    }

    /// Вызывать часто (например, каждые 0,2 с). Возвращает новые слова, если пауза выдержана.
    package mutating func tick(at date: Date) -> String? {
        guard let changedAt, words.count > emitted, date.timeIntervalSince(changedAt) >= pause else { return nil }
        let piece = words[emitted...].joined(separator: " ")
        emitted = words.count
        lastSpan = SpeechSpan(start: pieceStart ?? changedAt, end: changedAt)
        pieceStart = nil
        return piece
    }

    /// Финал фразы: отдаёт то, что ещё не отдано, и начинает новую фразу.
    /// Если распознавание пересмотрело уже отданные слова, они не повторяются: отдаются только слова после них.
    package mutating func final(_ text: String) -> String? {
        let final = Self.split(text)
        lastSpan = changedAt.map { SpeechSpan(start: pieceStart ?? $0, end: $0) }
        defer { words = []; changedAt = nil; emitted = 0; pieceStart = nil }
        guard !final.isEmpty else { return nil }
        guard emitted > 0 else { return final.joined(separator: " ") }
        guard final.count > emitted else { return nil }
        return final[emitted...].joined(separator: " ")
    }

    /// Сколько слов фразы уже отдано (для проверок).
    package var emittedWords: Int { emitted }
}
