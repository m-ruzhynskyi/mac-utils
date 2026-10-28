import AppKit
import Combine
import MUCore

/// Знак `$` для панели и подсветки: где стоит, строка, значение, оттенок по значению.
package struct DollarEntry: Identifiable, Equatable {
    package let mark: DollarMark
    package let line: Int
    /// Значение для списка (хвостовые пробелы обрезаны; само значение их включает).
    package let value: String
    /// Оттенок по значению (0…5); `nil` — пустое значение, нейтральный.
    package let hue: Int?
    /// Номер среди знаков текста страницы (для «Пропускать первые N»); `nil` — знак в служебной группе RTF.
    package var order: Int?
    package var id: Int { mark.dollar }

    package init(mark: DollarMark, line: Int, value: String, hue: Int?, order: Int? = nil) {
        self.mark = mark
        self.line = line
        self.value = value
        self.hue = hue
        self.order = order
    }

    package var isHidden: Bool { mark.hidden }
}

/// Статус знака в строке панели (макет «★3»): значение есть ✓ / пусто / правится (курсор в значении).
package enum DollarStatus: Equatable {
    case filled, empty, editing

    /// `value` — значение, как его показывает панель (в «Документе» — `visibleValue`), чтобы статус и текст строки совпадали.
    package static func of(value: String, editing: Bool) -> DollarStatus {
        if editing { return .editing }
        return value.allSatisfy(\.isWhitespace) ? .empty : .filled
    }
}

/// «Пропускать первые N»: одна общая настройка для всех документов (по умолчанию включено, N = 3).
package enum DollarSkip {
    package static let maxCount = 999

    package static var enabled: Bool { UserDefaults.standard.bool(forKey: Pref.editorSkipFirst) }
    package static var count: Int { clamp(UserDefaults.standard.integer(forKey: Pref.editorSkipCount)) }
    /// Значение для `DollarMarks.split`: `nil` — выключено.
    package static var current: Int? { enabled ? count : nil }

    package static func clamp(_ value: Int) -> Int { min(max(value, 0), maxCount) }
}

/// Модель панели «Знаки $» одного документа: скан в фоне по снимку текста с номером поколения (устаревшее
/// отбрасывается), пересчёт через 250 мс после последней правки.
@MainActor
package final class DollarPanelModel: ObservableObject {
    @Published package private(set) var entries: [DollarEntry] = []
    /// Значение «Пропускать первые» (`nil` — выключено) — всегда из настройки.
    package var skip: Int? { DollarSkip.current }
    private var lastSkip: Int? = DollarSkip.current
    /// Выбранное в списке вхождение (смещение `$`).
    @Published package var selected: Int?
    /// «Убрано: N · Отменить ⌘Z» — до следующей правки.
    @Published package var removedCount: Int? {
        didSet { if removedCount == nil { unbalancedAfterRemoval = nil } }
    }
    /// После «Убрать значения» в файле, где был баланс `{}`, стало столько непарных скобок (предупреждение в плашке).
    @Published package var unbalancedAfterRemoval: Int?
    /// Скан ещё идёт (первый раз после открытия).
    @Published package private(set) var scanning = false
    /// Знак, в значении которого стоит курсор (смещение `$`): строка панели — «правится…». Ставит вкладка (`caretMoved`).
    @Published package private(set) var editing: Int?
    /// Последнее выделение исходника: после пересчёта списка «правится» ищется заново (смещения могли сдвинуться).
    private var caret: NSRange?

    /// Вызывается, когда список готов (для подсветки текста).
    package var onUpdate: (() -> Void)?

    private var generation = 0
    private var pending: DispatchWorkItem?
    private var defaultsObserver: AnyCancellable?
    package static let debounce: TimeInterval = 0.25

    /// Свои часы и очередь — для тестов поколений и задержки.
    package var schedule: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = { delay, block in
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
    package var background: (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }

    package init() {
        defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = DollarSkip.current
                    if now != self.lastSkip {
                        self.lastSkip = now
                        self.objectWillChange.send()
                        self.onUpdate?()
                    }
                }
            }
    }

    /// Как считать значения: по видимому тексту RTF или по исходнику (ставит вкладка; смена — пересчёт).
    package var rule: DollarRule = .source
    /// Кодировка документа — для `\'hh` в RTF без `\ansicpg`.
    package var encoding: TextEncoding = .windows1252

    /// Знаки текста страницы (без служебных групп RTF): первые N пропущены, остальные подсвечены.
    package var split: (skipped: ArraySlice<DollarEntry>, active: ArraySlice<DollarEntry>) {
        let skipCount = min(max(skip ?? 0, 0), body.count)
        return (body[..<skipCount], body[skipCount...])
    }

    /// Знаки в служебных группах RTF (`\info`, `{\*\…}`): показываются отдельно, не подсвечиваются и не убираются.
    package var service: [DollarEntry] { entries.filter(\.isHidden) }

    private var body: ArraySlice<DollarEntry> { ArraySlice(entries.filter { !$0.isHidden }) }

    /// Знак пропущен («Пропускать первые N»).
    package func isSkipped(_ entry: DollarEntry) -> Bool {
        guard let order = entry.order else { return false }
        return order < max(skip ?? 0, 0)
    }

    /// Подсвеченные вхождения с непустыми значениями — то, что уберёт «Убрать значения».
    package var removableCount: Int { split.active.filter { !$0.mark.isEmpty }.count }

    /// Текст изменился: пересчитать через `debounce` (или сразу — при открытии).
    package func textChanged(_ text: @escaping @MainActor () -> NSString, immediately: Bool = false) {
        pending?.cancel()
        generation += 1
        let current = generation
        if entries.isEmpty { scanning = true }
        let run: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, current == self.generation else { return }
                // Неизменяемая копия: фоновый скан не видит дальнейших правок.
                let snapshot = UncheckedSendable(text().copy() as! NSString)
                let rule = self.rule, encoding = self.encoding
                self.background {
                    let entries = Self.scan(snapshot.value, rule: rule, encoding: encoding)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.apply(entries, generation: current) }
                    }
                }
            }
        }
        if immediately { run() } else { pending = schedule(Self.debounce, run) }
    }

    /// Текст изменился (любой правкой хранилища) — список устарел, даже если пересчёт ещё не запланирован.
    package func invalidate() { generation += 1 }

    /// Список соответствует тексту: последний скан применён и новых правок не было.
    package var isCurrent: Bool { appliedGeneration == generation }
    private var appliedGeneration = -1

    /// Пересчитать сразу, на главном потоке (перед «Убрать значения», если список отстал).
    package func scanNow(_ text: NSString) {
        pending?.cancel()
        generation += 1
        apply(Self.scan(text, rule: rule, encoding: encoding), generation: generation)
    }

    package func apply(_ entries: [DollarEntry], generation: Int) {
        guard generation == self.generation else { return }
        appliedGeneration = generation
        self.entries = entries
        scanning = false
        if let selected, !entries.contains(where: { $0.mark.dollar == selected }) { self.selected = nil }
        if let caret { caretMoved(to: caret) }
        onUpdate?()
    }

    // MARK: - Статусы

    /// Курсор или выделение исходника сдвинулись (в «Коде» или в «Документе»): какой знак сейчас правится.
    package func caretMoved(to selection: NSRange) {
        caret = selection
        let next = entry(containing: selection)?.mark.dollar
        if next != editing { editing = next }
    }

    /// Знак страницы, в значении которого стоит курсор: сразу после `$`, внутри значения или сразу за ним
    /// (набор там дописывает значение). Выделение — если задевает значение. Служебные знаки RTF не правятся.
    package func entry(containing selection: NSRange) -> DollarEntry? {
        // Последний знак, у которого `$` левее конца выделения (двоичный поиск); знаки не пересекаются, так что раньше — только он.
        let index = count(before: NSMaxRange(selection))
        guard index > 0 else { return nil }
        let entry = entries[index - 1]
        guard selection.location <= NSMaxRange(entry.mark.whole), !entry.isHidden else { return nil }
        return entry
    }

    package func status(of entry: DollarEntry, value: String) -> DollarStatus {
        DollarStatus.of(value: value, editing: editing == entry.mark.dollar)
    }

    /// «Заполнено N из M» для строки состояния: среди подсвеченных знаков (без пропущенных и служебных) — с непустым значением.
    /// `value` — то же значение, что в строке панели (`EditorTab.dollarValue`), поэтому счётчик совпадает со статусами строк.
    package func fill(value: (DollarEntry) -> String) -> (filled: Int, total: Int) {
        let active = split.active
        return (active.reduce(0) { $0 + (value($1).allSatisfy(\.isWhitespace) ? 0 : 1) }, active.count)
    }

    package var currentGeneration: Int { generation }

    package nonisolated static func scan(_ text: NSString, rule: DollarRule = .source, encoding: TextEncoding = .windows1252) -> [DollarEntry] {
        let marks = DollarMarks.scan(text, rule: rule, encoding: encoding)
        guard !marks.isEmpty else { return [] }
        let lines = LineIndex(text)
        var order = 0
        return marks.map { mark in
            // В списке — без хвостовых пробелов (в самом значении они есть).
            let shown = mark.text(in: text).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let entry = DollarEntry(mark: mark, line: lines.line(at: mark.dollar), value: shown,
                                    hue: DollarMarks.hue(of: shown as NSString, hues: EditorStyle.hueCount),
                                    order: mark.hidden ? nil : order)
            if !mark.hidden { order += 1 }
            return entry
        }
    }

    /// Свежие записи для устаревших: по месту `$` и тем же кускам значения; не совпало — `nil` (список отстал).
    package func current(_ stale: [DollarEntry]) -> [DollarEntry]? {
        let byDollar = Dictionary(entries.map { ($0.mark.dollar, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [DollarEntry] = []
        for entry in stale {
            guard let fresh = byDollar[entry.mark.dollar], fresh.mark.parts == entry.mark.parts, fresh.value == entry.value else { return nil }
            result.append(fresh)
        }
        return result
    }

    /// Сколько знаков `$` стоит раньше смещения.
    package func count(before offset: Int) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].mark.dollar < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Вхождения, пересекающие диапазон (для подсветки видимой части): двоичный поиск по смещению.
    package func entries(in range: NSRange) -> ArraySlice<DollarEntry> {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(entries[mid].mark.whole) <= range.location { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < entries.count, entries[end].mark.dollar < NSMaxRange(range) { end += 1 }
        return entries[low..<end]
    }
}
