import Foundation

// MARK: - Отрезки

/// Отрезок «Пропустить…» (§ 8.2): вид, время, откуда он взялся.
package struct SkipSegment: Equatable {
    package enum Kind: String, Equatable {
        case intro, recap, credits
    }

    /// Порядок — приоритет: ручная метка файла → метка папки → главы → SponsorBlock → звук.
    package enum Source: Int, Comparable {
        case manualFile, manualFolder, chapter, sponsorBlock, audio

        package static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    package var kind: Kind
    package var range: ClosedRange<Double>
    package var source: Source
    /// Название главы («Opening») — для подписи источника и тоста.
    package var label: String = ""

    /// Подпись кнопки.
    package func title(nextEpisode: Bool) -> String {
        switch kind {
        case .intro: return "Пропустить интро"
        case .recap: return "Пропустить пересказ"
        case .credits: return nextEpisode ? "Следующая серия" : "Пропустить титры"
        }
    }

    /// «интро · глава „Opening“» — подпись под шкалой.
    package var sourceTitle: String {
        let what: String
        switch kind {
        case .intro: what = "интро"
        case .recap: what = "пересказ"
        case .credits: what = "титры"
        }
        return source == .chapter && !label.isEmpty ? "\(what) · глава «\(label)»" : what
    }
}

package enum SkipSources {
    /// Из отрезков разных источников для каждого вида оставить самый приоритетный источник.
    /// `suppressed` — виды с ручной меткой «нет» («Не показывать в этой папке»): их не показываем совсем.
    package static func resolve(_ segments: [SkipSegment], suppressed: Set<SkipSegment.Kind> = []) -> [SkipSegment] {
        var result: [SkipSegment] = []
        for kind in [SkipSegment.Kind.intro, .recap, .credits] where !suppressed.contains(kind) {
            let candidates = segments.filter { $0.kind == kind }
            guard let best = candidates.map(\.source).min() else { continue }
            result += candidates.filter { $0.source == best }
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

// MARK: - Главы

/// Вид главы по названию и месту (§ 8.3). Кнопка по ошибке — не беда, авто-пропуск по ошибке — беда:
/// поэтому название должно начинаться со слова из словаря, быть не длиннее 3 слов и стоять там, где такие главы бывают.
package enum ChapterClassifier {
    package enum Kind: Equatable { case intro, recap, credits, preview }

    private static let dictionary: [(Kind, [String])] = [
        (.intro, ["intro", "opening", "op", "opening credits", "opening theme", "title sequence", "заставка", "вступление",
                  "интро", "опенинг", "начальные титры", "オープニング"]),
        (.recap, ["recap", "previously", "previously on", "пересказ", "ранее в сериале", "в предыдущих сериях"]),
        (.credits, ["credits", "end credits", "ending", "ed", "outro", "титры", "финальные титры", "эндинг", "エンディング"]),
        (.preview, ["preview", "next episode", "анонс", "следующая серия", "予告"]),
    ]

    /// После этих фраз может идти название («Previously on Harbor»). После остальных — только номер
    /// («OP 1», «Ending 2»): «Intro to Swift», «Op. 27 No. 2» и «Ed Sheeran» — обычные главы.
    private static let phrasesWithTail: Set<String> = ["previously on"]

    /// Слова в нижнем регистре: ё → е, апострофы удаляются («Ed's» → «eds»), прочая пунктуация и цифры — пробел.
    package static func words(_ title: String) -> [String] {
        tokens(title).filter { !$0.allSatisfy(\.isNumber) }
    }

    /// Слова и числа по отдельности: «OP1» → [«op», «1»], «Op. 27 No. 2» → [«op», «27», «no», «2»].
    package static func tokens(_ title: String) -> [String] {
        var text = title.lowercased().replacingOccurrences(of: "ё", with: "е")
        for apostrophe in ["'", "’", "ʼ", "`", "‘"] { text = text.replacingOccurrences(of: apostrophe, with: "") }
        var tokens: [String] = []
        var current = ""
        var currentIsNumber = false
        for character in text {
            let letter = character.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            let digit = character.isASCII && character.isNumber
            if (letter || digit), current.isEmpty || currentIsNumber == digit {
                current.append(character)
                currentIsNumber = digit
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = letter || digit ? String(character) : ""
                currentIsNumber = digit
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Вид по названию (без учёта места): название — это фраза из словаря, после неё — разве что номер.
    package static func kind(title: String) -> Kind? {
        let tokens = tokens(title)
        guard !tokens.isEmpty else { return nil }
        var best: (kind: Kind, length: Int)?
        for (kind, phrases) in dictionary {
            for phrase in phrases {
                let parts = phrase.split(separator: " ").map(String.init)
                guard tokens.starts(with: parts), parts.count > (best?.length ?? 0) else { continue }
                let tail = tokens.dropFirst(parts.count)
                let fits = phrasesWithTail.contains(phrase)
                    ? tail.filter { !$0.allSatisfy(\.isNumber) }.count + parts.count <= 3
                    : tail.count <= 1 && tail.allSatisfy { $0.allSatisfy(\.isNumber) }
                if fits { best = (kind, parts.count) }
            }
        }
        return best?.kind
    }

    /// Вид с учётом места и длины; nil — обычная глава.
    package static func kind(title: String, start: Double, length: Double, fileDuration: Double) -> Kind? {
        guard let kind = kind(title: title), fileDuration > 0, length > 0 else { return nil }
        switch kind {
        case .intro, .recap:
            return start <= min(fileDuration * 0.25, 600) && length <= 300 ? kind : nil
        case .credits, .preview:
            return start >= fileDuration * 0.8 && length <= 600 ? kind : nil
        }
    }

    package struct Chapter: Equatable {
        package let title: String
        package let start: Double
        package let end: Double
    }

    /// Главы → отрезки: соседние главы одного вида склеиваются, анонс сразу после титров — их хвост.
    package static func segments(from chapters: [Chapter], fileDuration: Double) -> [SkipSegment] {
        var result: [SkipSegment] = []
        for chapter in chapters.sorted(by: { $0.start < $1.start }) {
            guard let kind = kind(title: chapter.title, start: chapter.start, length: chapter.end - chapter.start,
                                  fileDuration: fileDuration) else { continue }
            let segmentKind: SkipSegment.Kind
            switch kind {
            case .intro: segmentKind = .intro
            case .recap: segmentKind = .recap
            case .credits: segmentKind = .credits
            case .preview:
                // Анонс без титров перед ним не трогаем.
                guard let last = result.last, last.kind == .credits, abs(last.range.upperBound - chapter.start) < 1 else { continue }
                segmentKind = .credits
            }
            if let last = result.last, last.kind == segmentKind, abs(last.range.upperBound - chapter.start) < 1 {
                result[result.count - 1].range = last.range.lowerBound...max(last.range.upperBound, chapter.end)
            } else {
                result.append(SkipSegment(kind: segmentKind, range: chapter.start...chapter.end, source: .chapter, label: chapter.title))
            }
        }
        return result
    }
}

// MARK: - Планировщик

/// Что показать сейчас: ничего, кнопку, пропустить сразу или отсчёт до следующей серии. Чистая функция:
/// всё состояние — в `SkipState`, время и настройки — на входе (табличные тесты `SkipPlannerTests`).
package enum SkipPlanner {
    package static let buttonSeconds: Double = 10
    package static let countdownSeconds: Double = 5
    /// Отрезок кончается так близко к концу файла — это «конец серии».
    package static let endSlack: Double = 3

    package struct Context: Equatable {
        package var duration: Double
        package var hasNext: Bool
        package var autoSkip: Bool
        package var autoNext: Bool
        /// «Не показывать в этой папке».
        package var hidden = false
    }

    package struct State: Equatable {
        /// Отрезок, внутри которого мы сейчас, и как в него попали.
        package var inside: Int?
        package var enteredAt: Double = 0
        package var enteredNaturally = false
        /// Авто-пропуск — один раз за открытие файла.
        package var autoSkipped: Set<Int> = []
        /// «Вернуть» — этот отрезок больше не пропускаем сами.
        package var undone: Set<Int> = []
        package var countdownCancelled = false
        package var lastTime: Double?
        /// С прошлого тика была перемотка (пользователем или пропуском).
        package var seeked = false
    }

    package enum Decision: Equatable {
        case none
        /// Кнопка «Пропустить …» (видна `fresh` первые 10 с или пока видна панель).
        case button(segment: Int, title: String, fresh: Bool)
        /// Авто-пропуск: перемотать на конец отрезка (или к следующему файлу).
        case skipNow(segment: Int)
        /// Карточка «Следующая серия через N».
        case countdown(segment: Int, remaining: Double)
        /// Отсчёт кончился — к следующему файлу.
        case playNext
    }

    package static func segmentIndex(at time: Double, in segments: [SkipSegment]) -> Int? {
        segments.firstIndex { time >= $0.range.lowerBound && time < $0.range.upperBound }
    }

    /// Отрезок доходит до конца файла (титры в конце серии).
    package static func endsFile(_ segment: SkipSegment, duration: Double) -> Bool {
        segment.range.upperBound >= duration - endSlack
    }

    package static func decide(time: Double, segments: [SkipSegment], context: Context, state: inout State) -> Decision {
        defer {
            state.lastTime = time
            state.seeked = false
        }
        guard !context.hidden, let index = segmentIndex(at: time, in: segments) else {
            if state.inside != nil { state.countdownCancelled = false }
            state.inside = nil
            return .none
        }
        let segment = segments[index]
        if state.inside != index {
            state.inside = index
            state.enteredAt = time
            // Сами дошли: без перемотки, и прошлый тик был до начала отрезка (или у самого начала).
            let previous = state.lastTime ?? -1
            state.enteredNaturally = !state.seeked && previous < segment.range.lowerBound + 0.5 && previous <= time
            state.countdownCancelled = false
        }
        let elapsed = max(0, time - state.enteredAt)
        let fresh = elapsed < min(buttonSeconds, segment.range.upperBound - segment.range.lowerBound)
        switch segment.kind {
        case .credits:
            let nextEpisode = context.hasNext && endsFile(segment, duration: context.duration)
            if nextEpisode, context.autoNext, state.enteredNaturally, !state.countdownCancelled {
                let remaining = countdownSeconds - elapsed
                return remaining > 0 ? .countdown(segment: index, remaining: remaining) : .playNext
            }
            return .button(segment: index, title: segment.title(nextEpisode: nextEpisode), fresh: fresh)
        case .intro, .recap:
            if context.autoSkip, state.enteredNaturally, !state.autoSkipped.contains(index), !state.undone.contains(index) {
                state.autoSkipped.insert(index)
                return .skipNow(segment: index)
            }
            return .button(segment: index, title: segment.title(nextEpisode: false), fresh: fresh)
        }
    }

    /// Куда перематывать при пропуске: конец отрезка; у конца файла — следующий файл (`nil`).
    package static func target(for segment: SkipSegment, duration: Double, hasNext: Bool) -> Double? {
        if endsFile(segment, duration: duration), hasNext { return nil }
        return min(segment.range.upperBound, duration)
    }
}

// MARK: - Главы Nero (chpl)

/// Атом `moov/udta/chpl`: AVFoundation его не читает (проверено фикстурой этапа 1), разбираем сами.
/// Формат: версия (1 байт), флаги (3), при версии ≥ 1 — 4 байта резерва, число глав (1), для каждой — начало
/// (u64, единицы 100 нс), длина названия (1) и название в UTF-8.
package enum NeroChapters {
    package static let maxMoovBytes = 64 * 1024 * 1024

    package static func parse(chpl data: Data) -> [(title: String, start: Double)] {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return [] }
        var offset = 4 + (bytes[0] >= 1 ? 4 : 0)
        guard offset < bytes.count else { return [] }
        let count = Int(bytes[offset])
        offset += 1
        var chapters: [(String, Double)] = []
        for _ in 0..<count {
            guard offset + 9 <= bytes.count else { break }
            let start = bytes[offset..<offset + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let length = Int(bytes[offset + 8])
            offset += 9
            guard offset + length <= bytes.count else { break }
            let title = String(decoding: bytes[offset..<offset + length], as: UTF8.self)
            offset += length
            chapters.append((title, Double(start) / 10_000_000))
        }
        return chapters.map { (title: $0.0, start: $0.1) }
    }

    /// Атомы подряд: (тип, полезная нагрузка). 64-битный размер и «до конца» поддерживаются.
    /// Размеры из файла сравниваются с остатком данных вычитанием: `offset + size` на мусорном размере переполнился бы.
    /// Разбирает и полезную нагрузку образцов WebVTT, которую AVFoundation не проверяет, — поэтому без доверия к данным.
    package static func boxes(in data: Data) -> [(type: String, payload: Data)] {
        var result: [(String, Data)] = []
        var offset = data.startIndex
        while data.endIndex - offset >= 8 {
            let remaining = data.endIndex - offset
            var size = UInt64(data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard remaining >= 16 else { break }
                size = data[offset + 8..<offset + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                header = 16
            } else if size == 0 {
                size = UInt64(remaining)
            }
            guard size >= UInt64(header), size <= UInt64(remaining) else { break }
            let length = Int(size)
            result.append((type, data[offset + header..<offset + length]))
            offset += length
        }
        return result.map { (type: $0.0, payload: $0.1) }
    }

    /// Главы из файла: ищем `moov` среди атомов верхнего уровня, не читая `mdat`.
    package static func read(_ url: URL) -> [(title: String, start: Double)] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        let end = (try? handle.seekToEnd()) ?? 0
        while end - offset >= 8 {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var size = UInt64(header.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var headerSize: UInt64 = 8
            if size == 1, header.count >= 16 {
                size = header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                headerSize = 16
            } else if size == 0 {
                size = end - offset
            }
            // Остаток файла — вычитанием: мусорный 64-битный размер не переполнит `offset + size`.
            guard size >= headerSize, size <= end - offset else { break }
            if type == "moov" {
                guard size - headerSize <= UInt64(maxMoovBytes) else { return [] }
                try? handle.seek(toOffset: offset + headerSize)
                guard let moov = try? handle.read(upToCount: Int(size - headerSize)) else { return [] }
                return chapters(inMoov: moov)
            }
            offset += size
        }
        return []
    }

    package static func chapters(inMoov moov: Data) -> [(title: String, start: Double)] {
        for box in boxes(in: moov) where box.type == "udta" {
            for child in boxes(in: box.payload) where child.type == "chpl" {
                return parse(chpl: Data(child.payload))
            }
        }
        return []
    }
}
