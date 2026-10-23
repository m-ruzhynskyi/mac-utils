import Foundation

/// Очередь плеера (чистая модель): файлы по порядку, текущий, повтор и перемешивание.
/// Новый файл встаёт после текущего (решение 3 макетов); уже открытый не дублируется — к нему переходим.
package struct Playlist: Equatable {
    package struct Item: Equatable, Identifiable, Codable {
        package let id: UUID
        package let url: URL

        package init(url: URL, id: UUID = UUID()) {
            self.id = id
            self.url = url
        }
    }

    package enum Repeat: String, CaseIterable, Codable {
        case off, all, one

        /// Кнопка повтора: выкл. → весь список → один файл → выкл.
        package var next: Repeat {
            switch self {
            case .off: return .all
            case .all: return .one
            case .one: return .off
            }
        }
    }

    package private(set) var items: [Item] = []
    package private(set) var currentID: UUID?
    package var repeatMode: Repeat = .off
    /// Порядок воспроизведения при перемешивании (идентификаторы); пусто — по списку.
    package private(set) var shuffleOrder: [UUID] = []
    package var isShuffled: Bool { !shuffleOrder.isEmpty }

    package var current: Item? { currentID.flatMap { id in items.first { $0.id == id } } }
    package var currentIndex: Int? { currentID.flatMap { id in items.firstIndex { $0.id == id } } }
    package var isEmpty: Bool { items.isEmpty }
    package var count: Int { items.count }

    // MARK: - Добавление

    /// Добавить файлы после текущего (или в конец, если текущего нет). Возвращает элемент, с которого играть:
    /// первый новый или уже бывший в списке (дубль не создаётся).
    @discardableResult
    package mutating func insertAfterCurrent(_ urls: [URL]) -> Item? {
        var insertAt = currentIndex.map { $0 + 1 } ?? items.count
        var first: Item?
        for url in urls {
            if let existing = item(for: url) {
                if first == nil { first = existing }
                continue
            }
            let item = Item(url: url)
            items.insert(item, at: insertAt)
            insertAt += 1
            if isShuffled { shuffleOrder.append(item.id) }
            if first == nil { first = item }
        }
        return first
    }

    /// Добавить в конец («+» в панели, папка).
    package mutating func append(_ urls: [URL]) {
        for url in urls where item(for: url) == nil {
            let item = Item(url: url)
            items.append(item)
            if isShuffled { shuffleOrder.append(item.id) }
        }
    }

    package func item(for url: URL) -> Item? {
        let path = url.standardizedFileURL.path
        return items.first { $0.url.standardizedFileURL.path == path }
    }

    // MARK: - Выбор и порядок

    package mutating func select(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        currentID = id
    }

    package mutating func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // Удалили текущий — текущим становится следующий по списку (или предыдущий, если он был последним).
        if id == currentID {
            let neighbour = index + 1 < items.count ? items[index + 1] : (index > 0 ? items[index - 1] : nil)
            currentID = neighbour?.id
        }
        items.remove(at: index)
        shuffleOrder.removeAll { $0 == id }
    }

    package mutating func removeAll() {
        items = []
        currentID = nil
        shuffleOrder = []
    }

    /// Перетаскивание внутри списка: `offsets` встают перед элементом с индексом `destination` (как `List.onMove`).
    package mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.sorted().map { items[$0] }
        var rest = items.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let before = offsets.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(rest.count, destination - before)))
        items = rest
    }

    // MARK: - Перемешивание

    /// Включить: текущий остаётся первым, остальные — в случайном порядке.
    package mutating func shuffle<G: RandomNumberGenerator>(using generator: inout G) {
        var others = items.map(\.id).filter { $0 != currentID }
        others.shuffle(using: &generator)
        shuffleOrder = (currentID.map { [$0] } ?? []) + others
    }

    package mutating func shuffle() {
        var generator = SystemRandomNumberGenerator()
        shuffle(using: &generator)
    }

    package mutating func unshuffle() { shuffleOrder = [] }

    private var order: [UUID] { isShuffled ? shuffleOrder : items.map(\.id) }

    // MARK: - Переходы

    /// Следующий элемент. `automatic` — файл доиграл сам: «повтор одного» возвращает тот же файл;
    /// кнопка «Дальше» и медиаклавиша ⏭ переходят дальше и при нём.
    package func next(automatic: Bool) -> Item? {
        guard let currentID, let position = order.firstIndex(of: currentID) else { return items.first }
        if automatic, repeatMode == .one { return current }
        if position + 1 < order.count { return item(id: order[position + 1]) }
        return repeatMode == .off ? nil : item(id: order[0])
    }

    package func previous() -> Item? {
        guard let currentID, let position = order.firstIndex(of: currentID) else { return nil }
        if position > 0 { return item(id: order[position - 1]) }
        return repeatMode == .off ? nil : order.last.flatMap(item(id:))
    }

    /// Есть ли что играть после текущего (для «Следующей серии»): повтор одного файла не в счёт.
    package var hasNext: Bool { next(automatic: false) != nil && next(automatic: false)?.id != currentID }

    private func item(id: UUID) -> Item? { items.first { $0.id == id } }

    /// «3 из 6».
    package var positionTitle: String? {
        guard let index = currentIndex, items.count > 1 else { return nil }
        return "\(index + 1) из \(items.count)"
    }
}
