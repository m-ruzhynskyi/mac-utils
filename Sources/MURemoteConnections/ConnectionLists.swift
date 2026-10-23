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

/// Фильтр-чипы «Все · AnyDesk · TeamViewer · RDP · VPN».
public enum ProgramFilter: Hashable, Sendable {
    case all
    case program(RemoteProgram)
    /// Через удалённый рабочий стол (программа RDP или метка RDP).
    case rdp
    /// Нужен VPN (программа VPN или метка VPN).
    case vpn

    func matches(_ r: ConnectionRecord, _ defaultProgram: RemoteProgram) -> Bool {
        switch self {
        case .all: return true
        case .program(let p): return r.method == nil && r.program(default: defaultProgram) == p
        case .rdp: return r.usesRDP
        case .vpn: return r.needsVPN
        }
    }
}

/// Метка в строке «МЕТКИ»: ключ сравнения, как показывать, сколько записей.
public struct TagCount: Equatable, Hashable, Sendable {
    public let key: String
    public let title: String
    public let kind: ConnectionTag.Kind
    public let count: Int
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
    /// Метки найденных записей: «Рег», «Фито», затем по частоте. VPN и RDP — не метки, а фильтры программ.
    public var tags: [TagCount] = []

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
    /// Метки (`tags`, ключи `ConnectionTag.key`) — все выбранные сразу; вместе с фильтром программы.
    public static func build(search: ConnectionSearch, query: String, filter: ProgramFilter,
                             defaultProgram: RemoteProgram, favorites: [String], recents: [String],
                             tags selectedTags: Set<String> = []) -> ConnectionListing {
        let result = search.search(query)
        var counts: [ProgramFilter: Int] = [.all: result.records.count]
        for p in RemoteProgram.allCases { counts[.program(p)] = 0 }
        counts[.rdp] = 0
        counts[.vpn] = 0
        for r in result.records {
            if r.method == nil { counts[.program(r.program(default: defaultProgram)), default: 0] += 1 }
            if r.usesRDP { counts[.rdp, default: 0] += 1 }
            if r.needsVPN { counts[.vpn, default: 0] += 1 }
        }

        let byProgram = result.records.filter { filter.matches($0, defaultProgram) }
        let visible = byProgram.filter { r in
            selectedTags.isEmpty || selectedTags.isSubset(of: Set(r.labels.map(ConnectionTag.key)))
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
        return ConnectionListing(sections: sections, counts: counts, hint: result.hint, effectiveQuery: result.effectiveQuery,
                                 tags: tagCounts(byProgram, keeping: selectedTags))
    }

    /// Метки по записям после поиска и фильтра программы. Выбранные остаются в строке, даже если их стало 0.
    static func tagCounts(_ records: [ConnectionRecord], keeping selected: Set<String>) -> [TagCount] {
        var count: [String: Int] = [:]
        var title: [String: String] = [:]
        var order: [String] = []
        for r in records {
            for tag in r.labels {
                let key = ConnectionTag.key(tag)
                if count[key] == nil { order.append(key); title[key] = ConnectionTag.display(tag) }
                count[key, default: 0] += 1
            }
        }
        for key in selected where count[key] == nil {
            order.append(key)
            count[key] = 0
            title[key] = key == "рег" ? "Рег" : key == "фито" ? "Фито" : key
        }
        let rank = { (k: String) -> Int in k == "рег" ? 0 : k == "фито" ? 1 : 2 }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if count[$0]! != count[$1]! { return count[$0]! > count[$1]! }
            return position[$0]! < position[$1]!
        }.map { TagCount(key: $0, title: title[$0]!, kind: ConnectionTag.kind(title[$0]!), count: count[$0]!) }
    }
}
