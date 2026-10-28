import MURemoteConnections
import SwiftUI
import MUCore
import MUDesign
import MUTextEditor

/// Состояние списка для вкладки и палитры: запрос, фильтр по программе, выбранная строка.
@MainActor
final class RemoteListModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { selection = 0 } } }
    @Published var filter: ProgramFilter = .all { didSet { if filter != oldValue { selection = 0 } } }
    /// Выбранные метки (ключи `ConnectionTag.key`): записи со всеми ими.
    @Published var tags: Set<String> = [] { didSet { if tags != oldValue { selection = 0 } } }
    @Published var selection = 0

    let center: RemoteConnectionsCenter

    init(center: RemoteConnectionsCenter? = nil) { self.center = center ?? .shared }

    var listing: ConnectionListing { center.listing(query: query, filter: filter, tags: tags) }

    func selectedRow(in listing: ConnectionListing) -> ConnectionRow? {
        let rows = listing.rows
        guard !rows.isEmpty else { return nil }
        return rows[min(max(selection, 0), rows.count - 1)]
    }

    func move(_ delta: Int) {
        let count = listing.rows.count
        guard count > 0 else { return }
        selection = (min(max(selection, 0), count - 1) + delta + count) % count
    }

    func select(_ row: ConnectionRow) {
        if let i = listing.rows.firstIndex(of: row) { selection = i }
    }

    /// Чипы — только программа подключения: «Все», AnyDesk, TeamViewer и — если такие записи есть — «Другое»
    /// (RDP, VPN и записи не через программу; значки VPN/RDP остаются в строке).
    func filters(_ counts: [ProgramFilter: Int]) -> [ProgramFilter] {
        [.all] + RemoteProgram.allCases.map { .program($0) } + [ProgramFilter.other].filter { (counts[$0] ?? 0) > 0 || filter == $0 }
    }

    /// ⇥ в палитре: Все → AnyDesk → TeamViewer (→ Другое) → Все.
    func cycleFilter() {
        let order = filters(listing.counts)
        filter = order[((order.firstIndex(of: filter) ?? 0) + 1) % order.count]
    }

    /// Подключиться к выбранной строке; `withPassword: false` — ⌘↩, без ввода пароля. false — выбрать нечего.
    @discardableResult
    func connectSelected(withPassword: Bool = true) -> Bool {
        guard let row = selectedRow(in: listing) else { return false }
        center.connect(row.record, withPassword: withPassword)
        return true
    }

    func toggleFavoriteSelected() {
        if let row = selectedRow(in: listing) { center.toggleFavorite(row.record) }
    }

    /// Подпись чипа: «Все 7», «AnyDesk 4».
    func chipTitle(_ filter: ProgramFilter, counts: [ProgramFilter: Int]) -> String {
        let n = counts[filter] ?? 0
        switch filter {
        case .all: return RL("Все %@", n)
        case .program(let p): return "\(p.title) \(n)"
        case .other: return RL("Другое %@", n)
        }
    }
}
