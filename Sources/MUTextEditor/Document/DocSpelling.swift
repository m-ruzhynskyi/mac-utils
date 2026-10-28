import AppKit
import MUCore

/// Орфография «Документа» (T4): `NSSpellChecker` проверяет текст страниц по языку места (`\lang`), опечатки подчёркиваются системной
/// красной пунктирной линией временным атрибутом `spellingState` — текст и исходник не меняются. Исправление из контекстного меню —
/// обычная точечная правка. Выключена по умолчанию (`Pref.docSpelling`): подчёркивание попадало бы в офскрин-снимки для сверки с Word.
@MainActor
package final class DocSpelling {
    package enum Choice: Equatable { case automatic, off, fixed(String) }

    private weak var controller: DocumentController?
    package private(set) var misspelled: [NSRange] = []
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()
    private var work: DispatchWorkItem?
    private var generation = 0

    /// Выбор языка проверки в строке состояния (на время сеанса, в файл не пишется): по `\lang`, выключить или один язык на всё.
    package var choice = Choice.automatic { didSet { if choice != oldValue { schedule(after: 0) } } }

    package var isEnabled: Bool { UserDefaults.standard.bool(forKey: Pref.docSpelling) }

    init(controller: DocumentController) { self.controller = controller }

    deinit { NSSpellChecker.shared.closeSpellDocument(withTag: tag) }

    /// Языки, для которых на этом Mac есть словарь.
    package static func available(_ code: String) -> Bool {
        NSSpellChecker.shared.availableLanguages.contains { $0 == code || $0.hasPrefix(code + "_") || $0.hasPrefix(code + "-") }
    }

    package func schedule(after delay: TimeInterval = 0.5) {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.run() } }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Снять подчёркивание (выключили проверку).
    package func clear() {
        work?.cancel()
        generation += 1
        guard let controller else { return }
        let full = NSRange(location: 0, length: controller.storage.length)
        for range in misspelled { controller.layoutManager.removeTemporaryAttribute(.spellingState, forCharacterRange: NSIntersectionRange(range, full)) }
        misspelled = []
    }

    /// Проверить весь текст кусками (по абзацам), не занимая главный поток надолго.
    package func run() {
        guard let controller else { return }
        clear()
        guard isEnabled, choice != .off, controller.tab?.mode == .document else { return }
        let shown = controller.storage.string as NSString
        guard shown.length > 0 else { return }
        let source = controller.tab?.text ?? ""
        let paragraphs = controller.rendering.paragraphRanges
        let map = controller.rendering.map
        let skip = valueRanges(controller)
        let mine = generation
        var index = 0
        func step() {
            guard mine == generation, let controller = self.controller else { return }
            let stop = min(paragraphs.count, index + 40)
            while index < stop {
                let range = NSIntersectionRange(paragraphs[index], NSRange(location: 0, length: shown.length))
                index += 1
                guard range.length > 0 else { continue }
                for (piece, code) in segments(of: range, shown: shown, map: map, source: source, model: controller.model, index: index - 1) {
                    for bad in check(shown, in: piece, code: code) where !skip.contains(where: { NSIntersectionRange($0, bad).length > 0 }) {
                        misspelled.append(bad)
                        controller.layoutManager.addTemporaryAttribute(.spellingState, value: 1,  // NSSpellingStateSpellingFlag
                                                                       forCharacterRange: bad)
                    }
                }
            }
            if index < paragraphs.count { DispatchQueue.main.async { MainActor.assumeIsolated { step() } } }
        }
        step()
    }

    /// Куски абзаца с их словарём: язык по `\lang` в исходнике (или выбор пользователя); без словаря — не проверяется.
    private func segments(of range: NSRange, shown: NSString, map: DocSourceMap, source: NSString, model: RTFDocumentModel, index: Int) -> [(NSRange, String)] {
        if case .fixed(let code) = choice { return Self.available(code) ? [(range, code)] : [] }
        guard let paragraph = model.body.paragraphs[safe: index] else { return [] }
        let first = map.sourceLocation(beforeUnit: range.location)
        let changes = DocLanguage.changes(from: paragraph.regionStart, to: min(NSMaxRange(paragraph.endRange), source.length), in: source)
        // Язык в начале показанного текста абзаца и каждая смена после него.
        var starts: [(unit: Int, lcid: Int)] = []
        for change in changes {
            let unit = change.location <= first ? range.location : max(range.location, min(NSMaxRange(range), map.unit(forSource: change.location)))
            if let last = starts.last, last.unit == unit { starts[starts.count - 1].lcid = change.lcid } else { starts.append((unit, change.lcid)) }
        }
        if starts.isEmpty { starts = [(range.location, DocLanguage.documentDefault(in: source))] }
        var result: [(NSRange, String)] = []
        for (offset, entry) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1].unit : NSMaxRange(range)
            guard end > entry.unit, let code = DocLanguage.spellingCode(lcid: entry.lcid), Self.available(code) else { continue }
            result.append((NSRange(location: entry.unit, length: end - entry.unit), code))
        }
        return result
    }

    private func check(_ text: NSString, in range: NSRange, code: String) -> [NSRange] {
        let checker = NSSpellChecker.shared
        var found: [NSRange] = []
        var position = range.location
        var guardCount = 0
        while position < NSMaxRange(range), guardCount < 5000 {
            guardCount += 1
            let sub = text.substring(with: NSRange(location: 0, length: NSMaxRange(range)))
            let bad = checker.checkSpelling(of: sub, startingAt: position, language: code, wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
            guard bad.location != NSNotFound, bad.length > 0, bad.location < NSMaxRange(range) else { break }
            found.append(bad)
            position = NSMaxRange(bad)
        }
        return found
    }

    /// Значения знаков `$` не проверяем: это подстановки, а не слова.
    private func valueRanges(_ controller: DocumentController) -> [NSRange] {
        guard let tab = controller.tab else { return [] }
        let map = controller.rendering.map
        var ranges: [NSRange] = []
        for entry in tab.dollars.entries {
            let dollar = map.unit(forSource: entry.mark.dollar)
            if dollar < map.count { ranges.append(NSRange(location: dollar, length: 1)) }
            ranges.append(contentsOf: entry.mark.parts.flatMap { map.units(inside: $0) })
        }
        return ranges
    }

    // MARK: - Исправление

    /// Опечатка под показанной единицей `unit` (если есть).
    package func misspelling(atUnit unit: Int) -> NSRange? {
        misspelled.first { NSLocationInRange(unit, $0) }
    }

    /// Варианты исправления слова (до 6).
    package func guesses(for range: NSRange) -> [String] {
        guard let controller else { return [] }
        let text = controller.storage.string as NSString
        guard NSMaxRange(range) <= text.length else { return [] }
        let word = text.substring(with: range)
        let code = DocLanguage.spellingCode(lcid: languageCode(at: range.location)) ?? "ru"
        return Array((NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word, language: code,
                                                    inSpellDocumentWithTag: tag) ?? []).prefix(6))
    }

    private func languageCode(at unit: Int) -> Int {
        guard let controller, let tab = controller.tab else { return 1049 }
        let location = controller.rendering.map.sourceLocation(beforeUnit: unit)
        let paragraph = controller.rendering.paragraph(atUnit: unit).flatMap { controller.model.body.paragraphs[safe: $0] }
        return DocLanguage.lcid(atSource: location, from: paragraph?.regionStart ?? max(0, location - 2000), in: tab.text)
    }

    package func learn(_ range: NSRange) {
        guard let controller, NSMaxRange(range) <= controller.storage.length else { return }
        NSSpellChecker.shared.learnWord((controller.storage.string as NSString).substring(with: range))
        schedule(after: 0)
    }

    package func ignore(_ range: NSRange) {
        guard let controller, NSMaxRange(range) <= controller.storage.length else { return }
        NSSpellChecker.shared.ignoreWord((controller.storage.string as NSString).substring(with: range), inSpellDocumentWithTag: tag)
        schedule(after: 0)
    }

    /// Пункты контекстного меню для опечатки под кликом: варианты (точечная правка), «Добавить в словарь», «Пропустить».
    package func menuItems(forUnit unit: Int, target: AnyObject, apply: Selector) -> [NSMenuItem] {
        guard isEnabled, let range = misspelling(atUnit: unit) else { return [] }
        var items: [NSMenuItem] = []
        for guess in guesses(for: range) {
            let item = NSMenuItem(title: guess, action: apply, keyEquivalent: "")
            item.target = target
            item.representedObject = [NSValue(range: range), guess] as [Any]
            items.append(item)
        }
        if items.isEmpty { let none = NSMenuItem(title: "Вариантов нет", action: nil, keyEquivalent: ""); none.isEnabled = false; items.append(none) }
        return items
    }
}
