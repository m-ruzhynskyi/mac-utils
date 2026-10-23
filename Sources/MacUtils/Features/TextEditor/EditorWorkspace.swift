import AppKit
import Combine
import MUCore

/// Вкладки окна редактора и действия над ними без окон и диалогов (их показывает `EditorWindowController`).
@MainActor
final class EditorWorkspace: ObservableObject {
    @Published private(set) var tabs: [EditorTab] = []
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { selectionChanged() } }
    }
    /// Панель поиска: `nil` — скрыта; `false` — только «Найти», `true` — с заменой.
    @Published var findMode: Bool?
    @Published var overlay: Overlay?
    @Published var dollarPanelVisible = UserDefaults.standard.bool(forKey: Pref.editorDollarPanel) {
        didSet { UserDefaults.standard.set(dollarPanelVisible, forKey: Pref.editorDollarPanel) }
    }
    @Published var wraps = UserDefaults.standard.bool(forKey: Pref.editorWrap) {
        didSet {
            UserDefaults.standard.set(wraps, forKey: Pref.editorWrap)
            for tab in tabs { tab.textView.setWraps(wraps) }
        }
    }
    @Published var showsInvisibles = UserDefaults.standard.bool(forKey: Pref.editorInvisibles) {
        didSet {
            UserDefaults.standard.set(showsInvisibles, forKey: Pref.editorInvisibles)
            for tab in tabs { tab.showsInvisibles = showsInvisibles }
        }
    }
    @Published var matchesBrackets = UserDefaults.standard.object(forKey: Pref.editorBrackets) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(matchesBrackets, forKey: Pref.editorBrackets)
            for tab in tabs { tab.matchesBrackets = matchesBrackets }
        }
    }
    @Published var zoom = EditorPrefs.zoom {
        didSet {
            EditorPrefs.zoom = zoom
            for tab in tabs { tab.zoom = zoom }
        }
    }
    let search = EditorSearch()
    let folderSearch = FolderSearchModel()
    @Published var folderSearchVisible = false {
        didSet { if !folderSearchVisible { folderSearch.stop() } }
    }

    enum Overlay: Equatable {
        case encoding, goToLine
    }

    /// Сменилась вкладка или её содержимое (сессия, заголовок окна).
    var onChange: (() -> Void)?
    /// Файлы, брошенные на текст, — открыть вкладками.
    var onOpenFiles: (([URL]) -> Void)?
    private var tabObservers: [UUID: AnyCancellable] = [:]

    var current: EditorTab? { tabs.first { $0.id == selectedID } ?? tabs.first }

    init() {
        search.workspace = self
    }

    // MARK: - Вкладки

    func add(_ tab: EditorTab, select: Bool = true, at index: Int? = nil) {
        tab.zoom = zoom
        tab.textView.setWraps(wraps)
        tab.showsInvisibles = showsInvisibles
        tab.matchesBrackets = matchesBrackets
        if let index { tabs.insert(tab, at: min(index, tabs.count)) } else { tabs.append(tab) }
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        tab.onEdit = { [weak self] in self?.onChange?() }
        tab.onDirtyChange = { [weak self] in self?.onChange?() }
        tab.textView.onFileDrop = { [weak self] in self?.onOpenFiles?($0) }
        tab.textView.onSwitchTab = { [weak self] in self?.select(offset: $0) }
        tab.textView.onEscape = { [weak self] in
            guard let self else { return }
            if self.overlay != nil { self.overlay = nil } else if self.findMode != nil { self.findMode = nil; self.search.clear() }
        }
        if select { selectedID = tab.id }
        onChange?()
    }

    func remove(_ tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        tabObservers[tab.id] = nil
        if selectedID == tab.id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        onChange?()
    }

    func select(offset: Int) {
        guard let current, let index = tabs.firstIndex(where: { $0.id == current.id }), tabs.count > 1 else { return }
        selectedID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        onChange?()
    }

    /// Вкладка уже открытого файла (повторное открытие только переключает на неё).
    func tab(for url: URL) -> EditorTab? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return tabs.first { $0.document.url?.standardizedFileURL.resolvingSymlinksInPath().path == path }
    }

    /// Имя для нового документа: «Без имени 1», «Без имени 2»…
    func untitledName() -> String {
        var number = 1
        let used = Set(tabs.filter { $0.document.url == nil }.map(\.untitledName))
        while used.contains("Без имени \(number)") { number += 1 }
        return "Без имени \(number)"
    }

    func newDocument() -> EditorTab {
        var document = EditorDocument(newWith: EditorPrefs.newEncoding)
        document.language = .plain
        let tab = EditorTab(document: document, zoom: zoom)
        tab.untitledName = untitledName()
        tab.textView.lineBreak = EditorPrefs.newLineEnding.string
        add(tab)
        return tab
    }

    /// Названия вкладок: одноимённые файлы из разных папок различаются папкой.
    func displayTitle(_ tab: EditorTab) -> String {
        guard let url = tab.document.url else { return tab.untitledName }
        let name = url.lastPathComponent
        let twins = tabs.filter { $0.document.url?.lastPathComponent == name }
        guard twins.count > 1 else { return name }
        return "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
    }

    private func selectionChanged() {
        search.tabChanged()
        onChange?()
    }
}
