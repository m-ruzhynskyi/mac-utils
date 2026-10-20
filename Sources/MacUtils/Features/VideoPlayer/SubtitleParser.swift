import Foundation

// MARK: - Модель

/// Цвет реплики (ASS `\c`, SRT `<font color>`).
struct SubtitleColor: Equatable, Codable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8 = 255

    static let white = SubtitleColor(red: 255, green: 255, blue: 255)

    /// ASS: `&HAABBGGRR` или `&HBBGGRR&` (альфа 00 — непрозрачный), в SSA бывает десятичное число.
    init?(ass value: String) {
        var text = value.trimmingCharacters(in: .whitespaces).uppercased()
        let hex = text.hasPrefix("&H")
        if hex { text.removeFirst(2) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "&H"))
        guard let number = hex ? UInt32(text, radix: 16) : (UInt32(text) ?? UInt32(text, radix: 16)) else { return nil }
        red = UInt8(number & 0xFF)
        green = UInt8(number >> 8 & 0xFF)
        blue = UInt8(number >> 16 & 0xFF)
        alpha = 255 - UInt8(number >> 24 & 0xFF)
    }

    /// HTML: `#RRGGBB`, `RRGGBB` или имя из короткого списка.
    init?(html value: String) {
        let names: [String: UInt32] = ["white": 0xFFFFFF, "black": 0x000000, "red": 0xFF0000, "green": 0x00FF00, "blue": 0x0000FF,
                                       "yellow": 0xFFFF00, "cyan": 0x00FFFF, "magenta": 0xFF00FF, "gray": 0x808080, "grey": 0x808080]
        let text = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' #")).lowercased()
        guard let number = names[text] ?? (text.count == 6 ? UInt32(text, radix: 16) : nil) else { return nil }
        red = UInt8(number >> 16 & 0xFF)
        green = UInt8(number >> 8 & 0xFF)
        blue = UInt8(number & 0xFF)
    }

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Кусок текста с одним оформлением. Перевод строки — `\n` внутри текста.
struct SubtitleRun: Equatable {
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var color: SubtitleColor?
}

struct SubtitleCue: Equatable {
    var start: Double
    var end: Double
    var runs: [SubtitleRun]
    /// Выравнивание по цифровой клавиатуре (ASS `\an`): 1–3 снизу, 4–6 посередине, 7–9 сверху; 2 — снизу по центру.
    var alignment = 2
    /// ASS `\pos(x, y)` в координатах `PlayResX × PlayResY`.
    var position: CGPoint?

    var text: String { runs.map(\.text).joined() }
}

struct SubtitleTrack: Equatable {
    enum Format: String { case srt, ass, vtt }

    var format: Format
    /// По началу; пустые реплики отброшены.
    private(set) var cues: [SubtitleCue]
    /// Размер «холста» ASS для `\pos`.
    var playResolution = CGSize(width: 384, height: 288)
    private let longest: Double

    init(format: Format, cues: [SubtitleCue], playResolution: CGSize? = nil) {
        self.format = format
        self.cues = cues.filter { $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        if let playResolution { self.playResolution = playResolution }
        longest = self.cues.map { $0.end - $0.start }.max() ?? 0
    }

    /// Реплики на экране в момент `time`: бинарный поиск последней начавшейся и шаг назад на длину самой длинной.
    func cues(at time: Double) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        var result: [SubtitleCue] = []
        var index = low - 1
        while index >= 0, cues[index].start >= time - longest {
            if cues[index].end > time { result.append(cues[index]) }
            index -= 1
        }
        return result.reversed()
    }
}

// MARK: - Разбор

enum SubtitleParser {
    /// Файлы больше этого не читаем: субтитры фильма — сотни килобайт.
    static let maxBytes = 20 * 1024 * 1024
    static let extensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    enum LoadError: LocalizedError {
        case tooLarge
        case empty

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Файл субтитров больше 20 МБ"
            case .empty: return "В файле не нашлось ни одной реплики"
            }
        }
    }

    /// Прочитать файл: кодировка — своя (`encoding`) или определённая автоматически.
    static func load(_ url: URL, encoding: TextEncoding? = nil) throws -> (track: SubtitleTrack, encoding: TextEncoding) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw LoadError.tooLarge }
        let data = try Data(contentsOf: url)
        let decoded = SubtitleText.decode(data, encoding: encoding)
        let track = parse(decoded.text, fileExtension: url.pathExtension)
        guard !track.cues.isEmpty else { throw LoadError.empty }
        return (track, decoded.encoding)
    }

    static func parse(_ text: String, fileExtension: String = "") -> SubtitleTrack {
        let normalized = normalize(text)
        let head = normalized.prefix(4096)
        if head.hasPrefix("WEBVTT") || fileExtension.lowercased() == "vtt" { return parseVTT(normalized) }
        if head.contains("[Script Info]") || head.contains("[Events]") || ["ass", "ssa"].contains(fileExtension.lowercased()) {
            return parseASS(normalized)
        }
        return parseSRT(normalized)
    }

    /// Без BOM, переводы строк — `\n`.
    static func normalize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if result.hasPrefix("\u{FEFF}") { result.removeFirst() }
        return result
    }

    // MARK: SRT

    /// «00:01:02,500 --> 00:01:04,000» (часы можно опустить, точка вместо запятой тоже встречается).
    private static let timing = try! NSRegularExpression(
        pattern: #"^\s*((?:\d+:)?\d{1,2}:\d{1,2}[,.]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{1,2}[,.]\d{1,3})"#)

    static func timingLine(_ line: String) -> (start: Double, end: Double)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = timing.firstMatch(in: line, range: range),
              let a = Range(match.range(at: 1), in: line), let b = Range(match.range(at: 2), in: line),
              let start = seconds(String(line[a])), let end = seconds(String(line[b])) else { return nil }
        return (start, end)
    }

    /// «1:02:03,5» → 3723,5. Дробная часть — по числу цифр (`,5` — полсекунды, `,500` — тоже).
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "," || $0 == "." }).map(String.init)
        guard parts.count >= 3, parts.count <= 4 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        let fraction = Double(numbers.last!) / pow(10, Double(parts.last!.count))
        let whole = numbers.dropLast()
        let total = whole.reduce(0) { $0 * 60 + $1 }
        return Double(total) + fraction
    }

    static func parseSRT(_ text: String) -> SubtitleTrack {
        let lines = text.components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            guard let time = timingLine(lines[index]) else { index += 1; continue }
            var body: [String] = []
            var next = index + 1
            while next < lines.count {
                let line = lines[next]
                if line.trimmingCharacters(in: .whitespaces).isEmpty || timingLine(line) != nil { break }
                // Номер следующей реплики без пустой строки перед ним — не текст.
                if Int(line.trimmingCharacters(in: .whitespaces)) != nil, next + 1 < lines.count, timingLine(lines[next + 1]) != nil { break }
                body.append(line)
                next += 1
            }
            var cue = markup(body.joined(separator: "\n"))
            cue.start = time.start
            cue.end = time.end
            cues.append(cue)
            index = next
        }
        return SubtitleTrack(format: .srt, cues: cues)
    }

    /// Разметка SRT/VTT: `<b> <i> <u> <s> <font color>`, прочие теги убираются; `{\an8}` и другие вставки ASS — как в ASS.
    static func markup(_ text: String) -> SubtitleCue {
        var cue = SubtitleCue(start: 0, end: 0, runs: [])
        var state = SubtitleRun(text: "")
        var colors: [SubtitleColor?] = []
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            var run = state
            run.text = decodeEntities(buffer)
            cue.runs.append(run)
            buffer = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "<", let close = text[index...].firstIndex(of: ">") {
                flush()
                let tag = text[text.index(after: index)..<close].trimmingCharacters(in: .whitespaces).lowercased()
                let closing = tag.hasPrefix("/")
                let name = String(tag.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter }))
                switch name {
                case "b": state.bold = !closing
                case "i": state.italic = !closing
                case "u": state.underline = !closing
                case "s": state.strike = !closing
                case "font":
                    if closing {
                        state.color = colors.popLast() ?? nil
                    } else {
                        colors.append(state.color)
                        if let value = attribute("color", in: tag) { state.color = SubtitleColor(html: value) ?? state.color }
                    }
                default: break
                }
                index = text.index(after: close)
            } else if character == "{", let close = text[index...].firstIndex(of: "}") {
                flush()
                let block = String(text[text.index(after: index)..<close])
                if block.hasPrefix("\\") { applyOverrides(block, to: &state, cue: &cue, style: nil) }
                index = text.index(after: close)
            } else {
                buffer.append(character)
                index = text.index(after: index)
            }
        }
        flush()
        trimRuns(&cue.runs)
        return cue
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: name + "=") else { return nil }
        let rest = tag[range.upperBound...]
        if let quote = rest.first, quote == "\"" || quote == "'" {
            return String(rest.dropFirst().prefix(while: { $0 != quote }))
        }
        return String(rest.prefix(while: { !$0.isWhitespace }))
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Пробелы по краям реплики не нужны; пустые куски выбрасываются.
    private static func trimRuns(_ runs: inout [SubtitleRun]) {
        runs = runs.filter { !$0.text.isEmpty }
        if let first = runs.indices.first {
            runs[first].text = String(runs[first].text.drop(while: { $0 == " " || $0 == "\n" }))
        }
        if let last = runs.indices.last {
            runs[last].text = String(runs[last].text.reversed().drop(while: { $0 == " " || $0 == "\n" }).reversed())
        }
        runs = runs.filter { !$0.text.isEmpty }
    }

    // MARK: WebVTT

    static func parseVTT(_ text: String) -> SubtitleTrack {
        let blocks = text.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let time = vttTiming(lines[timingIndex]) else { continue }
            // Внутренние метки времени караоке `<00:00:01.000>` убираются вместе с прочими тегами.
            var cue = markup(lines[(timingIndex + 1)...].joined(separator: "\n"))
            cue.start = time.start
            cue.end = time.end
            if lines[timingIndex].contains("line:0") || lines[timingIndex].contains("line:10%") { cue.alignment = 8 }
            cues.append(cue)
        }
        return SubtitleTrack(format: .vtt, cues: cues)
    }

    private static func vttTiming(_ line: String) -> (start: Double, end: Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = seconds(parts[0].trimmingCharacters(in: .whitespaces)),
              let endText = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
              let end = seconds(String(endText)) else { return nil }
        return (start, end)
    }

    // MARK: ASS / SSA

    struct ASSStyle: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var color: SubtitleColor?
        var alignment = 2
    }

    static func parseASS(_ text: String) -> SubtitleTrack {
        var section = ""
        var styleFormat: [String] = []
        var eventFormat: [String] = []
        var styles: [String: ASSStyle] = [:]
        var resolution = CGSize(width: 384, height: 288)
        var legacyAlignment = false
        var cues: [SubtitleCue] = []

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.lowercased()
                legacyAlignment = legacyAlignment || section == "[v4 styles]"
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch (section, key) {
            case ("[script info]", "playresx"): resolution.width = CGFloat(Double(value) ?? 384)
            case ("[script info]", "playresy"): resolution.height = CGFloat(Double(value) ?? 288)
            case ("[script info]", "scripttype"): legacyAlignment = legacyAlignment || value.lowercased().hasPrefix("v4.00") && !value.contains("+")
            case (_, "format") where section.contains("styles"):
                styleFormat = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            case (_, "style") where section.contains("styles"):
                let fields = split(value, count: styleFormat.count)
                func field(_ name: String) -> String? { styleFormat.firstIndex(of: name).flatMap { $0 < fields.count ? fields[$0] : nil } }
                var style = ASSStyle()
                style.bold = flag(field("bold"))
                style.italic = flag(field("italic"))
                style.underline = flag(field("underline"))
                style.strike = flag(field("strikeout"))
                style.color = field("primarycolour").flatMap(SubtitleColor.init(ass:))
                if let alignment = field("alignment").flatMap({ Int($0) }) {
                    style.alignment = legacyAlignment ? numpad(legacy: alignment) : min(max(alignment, 1), 9)
                }
                styles[(field("name") ?? "Default").lowercased()] = style
            case ("[events]", "format"):
                eventFormat = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            case ("[events]", "dialogue"):
                let format = eventFormat.isEmpty
                    ? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"] : eventFormat
                let fields = split(value, count: format.count)
                func field(_ name: String) -> String? { format.firstIndex(of: name).flatMap { $0 < fields.count ? fields[$0] : nil } }
                guard let start = field("start").flatMap(seconds), let end = field("end").flatMap(seconds) else { continue }
                let style = styles[(field("style") ?? "default").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "*"))]
                    ?? styles["default"] ?? ASSStyle()
                var cue = assText(field("text") ?? "", style: style)
                cue.start = start
                cue.end = end
                cues.append(cue)
            default:
                break
            }
        }
        return SubtitleTrack(format: .ass, cues: cues, playResolution: resolution)
    }

    /// Поля через запятую; последнее (текст) забирает остаток вместе с запятыми.
    private static func split(_ value: String, count: Int) -> [String] {
        value.split(separator: ",", maxSplits: max(0, count - 1), omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func flag(_ value: String?) -> Bool {
        guard let value, let number = Int(value) else { return false }
        return number != 0
    }

    /// SSA (v4): 1–3 снизу, +4 — сверху, +8 — посередине.
    static func numpad(legacy value: Int) -> Int {
        let base = max(1, min(3, value & 3))
        if value & 4 != 0 { return base + 6 }
        if value & 8 != 0 { return base + 3 }
        return base
    }

    /// Текст события ASS: `\N` — перевод строки, `{…}` — вставки оформления, остальное — текст без эффектов.
    static func assText(_ text: String, style: ASSStyle) -> SubtitleCue {
        var cue = SubtitleCue(start: 0, end: 0, runs: [], alignment: style.alignment)
        var state = SubtitleRun(text: "", bold: style.bold, italic: style.italic, underline: style.underline,
                                strike: style.strike, color: style.color)
        var buffer = ""
        var drawing = false
        func flush() {
            guard !buffer.isEmpty else { return }
            if !drawing {
                var run = state
                run.text = buffer
                cue.runs.append(run)
            }
            buffer = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                flush()
                guard let close = text[index...].firstIndex(of: "}") else {
                    // Незакрытая вставка: всё до конца — оформление, на экран не выводим.
                    break
                }
                let block = String(text[text.index(after: index)..<close])
                if block.contains("\\") { applyOverrides(block, to: &state, cue: &cue, style: style, drawing: &drawing) }
                index = text.index(after: close)
                continue
            }
            if character == "\\", let next = text.index(index, offsetBy: 1, limitedBy: text.index(before: text.endIndex)) {
                switch text[next] {
                case "N", "n":
                    buffer.append("\n")
                    index = text.index(after: next)
                    continue
                case "h":
                    buffer.append("\u{00A0}")
                    index = text.index(after: next)
                    continue
                default: break
                }
            }
            buffer.append(character)
            index = text.index(after: index)
        }
        flush()
        trimRuns(&cue.runs)
        return cue
    }

    private static func applyOverrides(_ block: String, to state: inout SubtitleRun, cue: inout SubtitleCue, style: ASSStyle?) {
        var drawing = false
        applyOverrides(block, to: &state, cue: &cue, style: style, drawing: &drawing)
    }

    /// Теги `\b \i \u \s \c \1c \an \a \pos \r \p`; `\k`, `\move`, `\t(…)`, `\fad`, `\fs` и прочие — без эффекта.
    private static func applyOverrides(_ block: String, to state: inout SubtitleRun, cue: inout SubtitleCue, style: ASSStyle?,
                                       drawing: inout Bool) {
        for tag in overrideTags(block) {
            let lower = tag.lowercased()
            func number(after prefix: Int) -> Int? { Int(tag.dropFirst(prefix).prefix(while: { $0.isNumber || $0 == "-" })) }
            if lower.hasPrefix("pos(") {
                let values = tag.dropFirst(4).prefix(while: { $0 != ")" }).split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if values.count == 2 { cue.position = CGPoint(x: values[0], y: values[1]) }
            } else if lower.hasPrefix("an"), let value = number(after: 2), (1...9).contains(value) {
                cue.alignment = value
            } else if lower.hasPrefix("a"), !lower.hasPrefix("alpha"), let value = number(after: 1), value > 0 {
                cue.alignment = numpad(legacy: value)
            } else if lower.hasPrefix("blur") || lower.hasPrefix("be") || lower.hasPrefix("bord") {
                continue
            } else if lower.hasPrefix("b"), let value = number(after: 1) {
                state.bold = value != 0
            } else if lower.hasPrefix("iclip") {
                continue
            } else if lower.hasPrefix("i"), let value = number(after: 1) {
                state.italic = value != 0
            } else if lower.hasPrefix("u"), let value = number(after: 1) {
                state.underline = value != 0
            } else if lower.hasPrefix("shad") {
                continue
            } else if lower.hasPrefix("s"), let value = number(after: 1) {
                state.strike = value != 0
            } else if lower.hasPrefix("c&") || lower.hasPrefix("1c&") {
                state.color = SubtitleColor(ass: String(tag.drop(while: { $0 != "&" })))
            } else if lower == "c" || lower == "1c" {
                state.color = style?.color
            } else if lower.hasPrefix("r") {
                let reset = style ?? ASSStyle()
                state = SubtitleRun(text: "", bold: reset.bold, italic: reset.italic, underline: reset.underline,
                                    strike: reset.strike, color: reset.color)
            } else if lower.hasPrefix("p"), let value = number(after: 1) {
                drawing = value > 0
            }
        }
    }

    /// `\b1\i1\t(0,500,\fs40)` → ["b1", "i1", "t(0,500,\fs40)"]: скобки целиком, чтобы `\t(…)` не разбирался изнутри.
    private static func overrideTags(_ block: String) -> [String] {
        var tags: [String] = []
        var current = ""
        var depth = 0
        for character in block {
            if character == "\\" && depth == 0 {
                if !current.isEmpty { tags.append(current) }
                current = ""
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            current.append(character)
        }
        if !current.isEmpty { tags.append(current) }
        return tags.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Кодировка

/// Кодировка файла субтитров: ядро текстового редактора (`TextEncoding.detect`), а если это не UTF-8 —
/// выбор между кириллическими однобайтовыми по частоте строчных букв (SRT в cp1251 встречается часто).
enum SubtitleText {
    static func decode(_ data: Data, encoding forced: TextEncoding? = nil) -> (text: String, encoding: TextEncoding) {
        if let forced, let text = forced.decode(data) { return (text, forced) }
        let detected = TextEncoding.detect(data)
        if detected.reason == .bom || detected.reason == .validUTF8 {
            return (detected.encoding.decode(data) ?? "", detected.encoding)
        }
        let encoding = guessSingleByte(data)
        return (encoding.decode(data) ?? "", encoding)
    }

    /// Западный текст — байтов выше 0x7F мало; русский — почти все буквы. Среди кириллических побеждает та,
    /// где больше строчных букв: в обычном тексте их намного больше, чем заглавных, а чужая кодировка меняет регистр.
    static func guessSingleByte(_ data: Data) -> TextEncoding {
        let sample = data.prefix(256 * 1024)
        var high = 0, letters = 0
        for byte in sample {
            if byte >= 0x80 { high += 1 } else if (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) { letters += 1 }
        }
        guard high > 0, Double(high) / Double(high + letters) >= 0.3 else { return .windows1252 }
        let candidates: [TextEncoding] = [.windows1251, .koi8R, .cp866, .iso8859_5, .macRoman]
        var best = TextEncoding.windows1251, bestScore = Int.min
        for candidate in candidates {
            guard let text = candidate.decode(sample) else { continue }
            var score = 0
            for scalar in text.unicodeScalars where scalar.value >= 0x80 {
                switch scalar.value {
                case 0x0430...0x044F, 0x0451: score += 2      // строчные а–я, ё
                case 0x0410...0x042F, 0x0401: score -= 1      // заглавные
                case 0x00A0, 0x00AB, 0x00BB, 0x2013, 0x2014, 0x2026, 0x201C, 0x201D, 0x201E, 0x2116: break
                default: score -= 3                           // псевдографика, латиница с диакритикой
                }
            }
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }
}

// MARK: - Поиск рядом с видео

/// Внешние субтитры рядом с видео: `имя.srt`, `имя.ru.srt`, `имя.English.ass`…
enum SubtitleFinder {
    struct Candidate: Equatable {
        let url: URL
        /// «ru», «eng», «English» или nil — без пометки языка.
        let language: String?
    }

    /// Файлы субтитров с тем же именем, что у видео (без учёта регистра). Сначала язык системы, потом без языка.
    static func candidates(for video: URL, names: [String], preferredLanguages: [String] = Locale.preferredLanguages) -> [Candidate] {
        let base = video.deletingPathExtension().lastPathComponent.lowercased()
        let folder = video.deletingLastPathComponent()
        var found: [Candidate] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            guard SubtitleParser.extensions.contains(url.pathExtension.lowercased()) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            if stem.lowercased() == base {
                found.append(Candidate(url: url, language: nil))
            } else if stem.lowercased().hasPrefix(base + ".") {
                let tag = String(stem.dropFirst(base.count + 1))
                // «ru», «English», «ru.forced»; длинный хвост — уже другое имя («Серия 1.режиссёрская версия»).
                guard !tag.isEmpty, tag.count <= 16 else { continue }
                found.append(Candidate(url: url, language: tag))
            }
        }
        let preferred = preferredLanguages.map { String($0.prefix(2)).lowercased() }
        func rank(_ candidate: Candidate) -> Int {
            guard let language = candidate.language else { return preferred.count }
            let code = languageCode(language)
            return preferred.firstIndex(of: code) ?? preferred.count + 1
        }
        return found.sorted { (rank($0), $0.url.lastPathComponent) < (rank($1), $1.url.lastPathComponent) }
    }

    /// «rus», «Russian», «ru-RU» → «ru».
    static func languageCode(_ tag: String) -> String {
        let lower = tag.lowercased()
        let known: [String: String] = ["rus": "ru", "russian": "ru", "русский": "ru", "eng": "en", "english": "en",
                                       "ukr": "uk", "ukrainian": "uk", "ger": "de", "deu": "de", "german": "de",
                                       "fre": "fr", "fra": "fr", "french": "fr", "spa": "es", "spanish": "es", "jpn": "ja", "japanese": "ja"]
        if let code = known[lower] { return code }
        return String(lower.prefix(while: { $0.isLetter }).prefix(2))
    }
}
