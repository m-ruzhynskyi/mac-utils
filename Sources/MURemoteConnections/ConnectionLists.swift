import Foundation

/// Избранное и недавние — по ID, без паролей. Хранит приложение (своими настройками), модуль — только правила.
public protocol RemotePreferencesStore: AnyObject {
    var favoriteIDs: [String] { get set }
    /// Последние подключения, новые первыми.
    var recentIDs: [String] { get set }
}

public final class InMemoryRemotePreferences: RemotePreferencesStore {
    public var favoriteIDs: [String]
    public var recentIDs: [String]

    public init(favoriteIDs: [String] = [], recentIDs: [String] = []) {
        self.favoriteIDs = favoriteIDs
        self.recentIDs = recentIDs
    }
}

public enum ConnectionLists {
    public static let recentLimit = 5

    public static func isFavorite(_ record: ConnectionRecord, in store: RemotePreferencesStore) -> Bool {
        store.favoriteIDs.contains(record.favoriteKey)
    }

    public static func toggleFavorite(_ record: ConnectionRecord, in store: RemotePreferencesStore) {
        let key = record.favoriteKey
        if let i = store.favoriteIDs.firstIndex(of: key) { store.favoriteIDs.remove(at: i) } else { store.favoriteIDs.append(key) }
    }

    /// После подключения: ID — первым в «Недавних», не больше пяти.
    public static func noteConnected(_ record: ConnectionRecord, in store: RemotePreferencesStore) {
        var recent = store.recentIDs.filter { $0 != record.favoriteKey }
        recent.insert(record.favoriteKey, at: 0)
        store.recentIDs = Array(recent.prefix(recentLimit))
    }
}

/// Фильтр-чипы «Все · AnyDesk · TeamViewer».
public enum ProgramFilter: Hashable, Sendable {
    case all
    case program(RemoteProgram)
}

public struct ConnectionSection: Identifiable, Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case favorites
        case recents
        case group(String)
        /// Записи без группы (в конце списка).
        case ungrouped
        /// Результаты поиска — одним списком по релевантности.
        case results
    }

    public let kind: Kind
    public let records: [ConnectionRecord]

    public var id: String {
        switch kind {
        case .favorites: return "favorites"
        case .recents: return "recents"
        case .group(let name): return "group:\(name)"
        case .ungrouped: return "ungrouped"
        case .results: return "results"
        }
    }
}

/// Готовый к показу список: секции, количество по программам, подсказка раскладки.
public struct ConnectionListing: Equatable, Sendable {
    public var sections: [ConnectionSection]
    /// Для чипов: сколько записей подходит под запрос — всего и по каждой программе.
    public var counts: [ProgramFilter: Int]
    public var hint: ConnectionSearch.LayoutHint?
    public var effectiveQuery: String

    /// Плоский порядок для стрелок: запись может стоять и в «Избранном», и в группе — это разные строки.
    public var rows: [ConnectionRow] {
        sections.flatMap { s in s.records.map { ConnectionRow(sectionID: s.id, record: $0) } }
    }

    public var isEmpty: Bool { sections.allSatisfy { $0.records.isEmpty } }
}

public struct ConnectionRow: Identifiable, Equatable, Sendable {
    public let sectionID: String
    public let record: ConnectionRecord
    public var id: String { "\(sectionID)|\(record.identity)" }

    public init(sectionID: String, record: ConnectionRecord) {
        self.sectionID = sectionID
        self.record = record
    }
}

public enum ConnectionListBuilder {
    /// Без запроса: «Избранное», «Недавние» (до 5), затем группы в порядке файла и «Без группы».
    /// С запросом: один список по релевантности. Фильтр по программе применяется ко всему.
    /// Исчезнувшие из файла ID в избранном и недавних не показываются.
    public static func build(search: ConnectionSearch, query: String, filter: ProgramFilter,
                             defaultProgram: RemoteProgram, favorites: [String], recents: [String]) -> ConnectionListing {
        let result = search.search(query)
        var counts: [ProgramFilter: Int] = [.all: result.records.count]
        for p in RemoteProgram.allCases { counts[.program(p)] = 0 }
        for r in result.records { counts[.program(r.program(default: defaultProgram)), default: 0] += 1 }

        let visible: [ConnectionRecord]
        switch filter {
        case .all: visible = result.records
        case .program(let p): visible = result.records.filter { $0.program(default: defaultProgram) == p }
        }

        var sections: [ConnectionSection] = []
        if !result.effectiveQuery.isEmpty {
            sections.append(ConnectionSection(kind: .results, records: visible))
        } else {
            let byKey = Dictionary(grouping: visible, by: \.favoriteKey)
            let fav = favorites.flatMap { byKey[$0] ?? [] }
            if !fav.isEmpty { sections.append(ConnectionSection(kind: .favorites, records: fav)) }
            var seenRecent = Set<String>()
            let recent = recents.filter { byKey[$0] != nil && seenRecent.insert($0).inserted }
                .prefix(ConnectionLists.recentLimit).flatMap { byKey[$0] ?? [] }
            if !recent.isEmpty { sections.append(ConnectionSection(kind: .recents, records: Array(recent))) }

            var order: [String] = []
            var groups: [String: [ConnectionRecord]] = [:]
            var ungrouped: [ConnectionRecord] = []
            for r in visible {
                if r.group.isEmpty { ungrouped.append(r); continue }
                if groups[r.group] == nil { order.append(r.group) }
                groups[r.group, default: []].append(r)
            }
            sections += order.map { ConnectionSection(kind: .group($0), records: groups[$0]!) }
            if !ungrouped.isEmpty { sections.append(ConnectionSection(kind: .ungrouped, records: ungrouped)) }
        }
        return ConnectionListing(sections: sections, counts: counts, hint: result.hint, effectiveQuery: result.effectiveQuery)
    }
}
