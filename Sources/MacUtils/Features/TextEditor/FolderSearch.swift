import Foundation

/// Поиск и замена по папке: обход в фоне с отменой, маска имён, пропуск двоичных и очень больших файлов, кодировка
/// каждого файла — автоопределением ядра. Только чтение, кроме явного «Заменить в папке».
enum FolderSearch {
    /// Больше — файл пропускается (в редакторе такие открываются с вопросом).
    static let maxFileBytes = 50 * 1024 * 1024
    /// Столько совпадений собираем всего — дальше «и ещё…», поиск останавливается.
    static let maxMatches = 10_000
    /// NUL в начале файла — двоичный.
    static let binaryProbe = 8 * 1024

    struct Match: Equatable, Identifiable {
        let range: NSRange
        let line: Int
        let column: Int
        /// Строка с совпадением (обрезанная до 200 символов вокруг него).
        let preview: String
        var id: Int { range.location }
    }

    struct FileResult: Equatable, Identifiable {
        let url: URL
        let encoding: TextEncoding
        let matches: [Match]
        var id: URL { url }
    }

    struct Summary: Equatable {
        var files: [FileResult] = []
        var scanned = 0
        var skippedBinary = 0
        var skippedLarge = 0
        var unreadable = 0
        /// Совпадений больше `maxMatches` — список неполный.
        var truncated = false
        var matchCount: Int { files.reduce(0) { $0 + $1.matches.count } }
    }

    // MARK: - Маска

    /// «*.frm; *.txt», «*.frm, *.rtf» или пусто (все файлы). Без учёта регистра.
    static func patterns(_ mask: String) -> [String] {
        mask.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func matches(_ name: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        let lower = name.lowercased()
        return patterns.contains { fnmatch($0, lower, 0) == 0 }
    }

    // MARK: - Файлы

    /// Обычные файлы папки (вложенные тоже), без скрытых и без содержимого пакетов (.app и т. п.), по маске.
    static func files(in folder: URL, mask: String) -> [URL] {
        let patterns = patterns(mask)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  matches(url.lastPathComponent, patterns: patterns) else { continue }
            result.append(url)
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    enum Reading: Equatable {
        case text(Data)
        case binary, large, unreadable
    }

    static func read(_ url: URL) -> Reading {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return .unreadable }
        guard size <= maxFileBytes else { return .large }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .unreadable }
        return isBinary(data) ? .binary : .text(data)
    }

    /// NUL в первых 8 КБ — двоичный (UTF-16 с BOM — текст, в нём нули на месте старших байтов).
    static func isBinary(_ data: Data) -> Bool {
        if data.starts(with: TextEncoding.bomUTF16LE) || data.starts(with: TextEncoding.bomUTF16BE) { return false }
        return data.prefix(binaryProbe).contains(0)
    }

    // MARK: - Поиск

    /// Поиск по папке. `progress` вызывается после каждого файла (в той же очереди), `isCancelled` — между файлами
    /// и внутри поиска (regex).
    static func search(_ query: String, options: SearchOptions, in folder: URL, mask: String,
                       isCancelled: @escaping () -> Bool = { false }, progress: (Summary) -> Void = { _ in }) throws -> Summary {
        var summary = Summary()
        var options = options
        options.inSelection = false
        // Ошибка выражения — сразу, а не на каждом файле.
        if options.regex { _ = try TextSearch.expression(query, options: options) }
        for url in files(in: folder, mask: mask) {
            if isCancelled() { throw TextSearch.Failure.cancelled }
            summary.scanned += 1
            switch read(url) {
            case .binary: summary.skippedBinary += 1
            case .large: summary.skippedLarge += 1
            case .unreadable: summary.unreadable += 1
            case .text(let data):
                let encoding = TextEncoding.detect(data).encoding
                guard let text = encoding.decode(data) as NSString? else { summary.unreadable += 1; continue }
                let left = maxMatches - summary.matchCount
                let found = try TextSearch.find(query, in: text, options: options, limit: left, isCancelled: isCancelled)
                if !found.ranges.isEmpty {
                    let lines = LineIndex(text)
                    let matches = found.ranges.map { range -> Match in
                        let position = lines.position(at: range.location)
                        return Match(range: range, line: position.line, column: position.column,
                                     preview: preview(text, line: position.line, lines: lines, around: range))
                    }
                    summary.files.append(FileResult(url: url, encoding: encoding, matches: matches))
                }
                if found.truncated || summary.matchCount >= maxMatches {
                    summary.truncated = true
                    progress(summary)
                    return summary
                }
            }
            progress(summary)
        }
        return summary
    }

    /// Строка совпадения без перевода строки; длинная — 200 символов вокруг совпадения.
    static func preview(_ text: NSString, line: Int, lines: LineIndex, around range: NSRange) -> String {
        let start = lines.starts[line - 1]
        var end = line < lines.lineCount ? lines.starts[line] : text.length
        while end > start, LineCommands.isBreak(text.character(at: end - 1)) { end -= 1 }
        var from = start, to = end
        if to - from > 200 {
            from = max(start, range.location - 80)
            to = min(end, from + 200)
        }
        let body = text.substring(with: NSRange(location: from, length: to - from)).replacingOccurrences(of: "\t", with: " ")
        return (from > start ? "…" : "") + body + (to < end ? "…" : "")
    }

    // MARK: - Замена

    struct ReplaceReport: Equatable {
        var replacedFiles: [URL] = []
        var replacements = 0
        /// Файл изменился после поиска — не трогали.
        var changedSinceSearch: [URL] = []
        /// В кодировке файла нет символов замены — не трогали.
        var unrepresentable: [URL] = []
        var failed: [URL] = []
        /// Открыт в редакторе с несохранёнными правками — не трогали.
        var openWithEdits: [URL] = []
    }

    /// План замены в одном файле: новый текст в той же кодировке. `nil` — совпадений нет.
    static func replacement(in data: Data, query: String, template: String, options: SearchOptions) throws -> (data: Data, count: Int)? {
        let document = EditorDocument(data: data)
        let text = document.decodedText as NSString
        var options = options
        options.inSelection = false
        let plan = try TextSearch.replacements(query, template: template, in: text, options: options)
        guard !plan.ranges.isEmpty else { return nil }
        let result = NSMutableString(string: text)
        for (range, string) in zip(plan.ranges, plan.strings).reversed() { result.replaceCharacters(in: range, with: string) }
        // Кодировка, BOM и переводы строк файла те же; символа нет в кодировке — ошибка, файл не трогаем.
        return (try document.data(for: result as String), plan.ranges.count)
    }
}
