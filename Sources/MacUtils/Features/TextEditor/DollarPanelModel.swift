import AppKit
import Combine

/// Знак `$` для панели и подсветки: где стоит, строка, значение, оттенок по значению.
struct DollarEntry: Identifiable, Equatable {
    let mark: DollarMark
    let line: Int
    let value: String
    /// Оттенок по значению (0…5); `nil` — пустое значение, нейтральный.
    let hue: Int?
    var id: Int { mark.dollar }
}

/// «Пропускать первые N»: одна общая настройка для всех документов (по умолчанию включено, N = 3).
enum DollarSkip {
    static let maxCount = 999

    static var enabled: Bool { UserDefaults.standard.bool(forKey: Pref.editorSkipFirst) }
    static var count: Int { clamp(UserDefaults.standard.integer(forKey: Pref.editorSkipCount)) }
    /// Значение для `DollarMarks.split`: `nil` — выключено.
    static var current: Int? { enabled ? count : nil }

    static func clamp(_ value: Int) -> Int { min(max(value, 0), maxCount) }
}

/// Модель панели «Знаки $» одного документа: скан в фоне по снимку текста с номером поколения (устаревшее
/// отбрасывается), пересчёт через 250 мс после последней правки.
@MainActor
final class DollarPanelModel: ObservableObject {
    @Published private(set) var entries: [DollarEntry] = []
    /// Значение «Пропускать первые» (`nil` — выключено) — всегда из настройки.
    var skip: Int? { DollarSkip.current }
    private var lastSkip: Int? = DollarSkip.current
    /// Выбранное в списке вхождение (смещение `$`).
    @Published var selected: Int?
    /// «Убрано: N · Отменить ⌘Z» — до следующей правки.
    @Published var removedCount: Int?
    /// Скан ещё идёт (первый раз после открытия).
    @Published private(set) var scanning = false

    /// Вызывается, когда список готов (для подсветки текста).
    var onUpdate: (() -> Void)?

    private var generation = 0
    private var pending: DispatchWorkItem?
    private var defaultsObserver: AnyCancellable?
    static let debounce: TimeInterval = 0.25

    /// Свои часы и очередь — для тестов поколений и задержки.
    var schedule: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = { delay, block in
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
    var background: (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }

    init() {
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

    var split: (skipped: ArraySlice<DollarEntry>, active: ArraySlice<DollarEntry>) {
        let skipCount = min(max(skip ?? 0, 0), entries.count)
        return (entries[..<skipCount], entries[skipCount...])
    }

    /// Подсвеченные вхождения с непустыми значениями — то, что уберёт «Убрать значения».
    var removableCount: Int { split.active.filter { $0.mark.value.length > 0 }.count }

    /// Текст изменился: пересчитать через `debounce` (или сразу — при открытии).
    func textChanged(_ text: @escaping @MainActor () -> NSString, immediately: Bool = false) {
        pending?.cancel()
        generation += 1
        let current = generation
        if entries.isEmpty { scanning = true }
        let run: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, current == self.generation else { return }
                // Неизменяемая копия: фоновый скан не видит дальнейших правок.
                let snapshot = UncheckedSendable(text().copy() as! NSString)
                self.background {
                    let entries = Self.scan(snapshot.value)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.apply(entries, generation: current) }
                    }
                }
            }
        }
        if immediately { run() } else { pending = schedule(Self.debounce, run) }
    }

    /// Список соответствует тексту: последний скан применён и новых правок не было.
    var isCurrent: Bool { appliedGeneration == generation }
    private var appliedGeneration = -1

    /// Пересчитать сразу, на главном потоке (перед «Убрать значения», если список отстал).
    func scanNow(_ text: NSString) {
        pending?.cancel()
        generation += 1
        apply(Self.scan(text), generation: generation)
    }

    func apply(_ entries: [DollarEntry], generation: Int) {
        guard generation == self.generation else { return }
        appliedGeneration = generation
        self.entries = entries
        scanning = false
        if let selected, !entries.contains(where: { $0.mark.dollar == selected }) { self.selected = nil }
        onUpdate?()
    }

    var currentGeneration: Int { generation }

    nonisolated static func scan(_ text: NSString) -> [DollarEntry] {
        let marks = DollarMarks.scan(text)
        guard !marks.isEmpty else { return [] }
        let lines = LineIndex(text)
        return marks.map { mark in
            let value = text.substring(with: mark.value) as NSString
            return DollarEntry(mark: mark, line: lines.line(at: mark.dollar), value: value as String,
                               hue: DollarMarks.hue(of: value, hues: EditorStyle.hueCount))
        }
    }

    /// Сколько знаков `$` стоит раньше смещения.
    func count(before offset: Int) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].mark.dollar < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Вхождения, пересекающие диапазон (для подсветки видимой части): двоичный поиск по смещению.
    func entries(in range: NSRange) -> ArraySlice<DollarEntry> {
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
