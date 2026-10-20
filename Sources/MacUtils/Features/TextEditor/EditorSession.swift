import AppKit

/// Сессия редактора: вкладки и черновики в `~/Library/Application Support/Mac Utils/Editor/`
/// (`session.json` + `Drafts/<uuid>.txt`, запись атомарная). Черновики — UTF-8, незашифрованные.
@MainActor
enum EditorSession {
    struct Entry: Codable, Equatable {
        var id: UUID
        var path: String?
        var untitledName: String?
        var encoding: TextEncoding
        /// Кодировка, в которой прочитан файл (отличается после «Преобразовать в…»).
        var decodedEncoding: TextEncoding?
        var language: EditorLanguage
        var selection: [Int]
        var scroll: [Double]
        var bookmarks: [Int]
        var fileStamp: FileStamp?
        /// Текст отличается от файла — он в черновике.
        var draftID: UUID?
    }

    struct State: Codable, Equatable {
        var version = 1
        var tabs: [Entry]
        var selected: UUID?
    }

    static var folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Mac Utils/Editor", isDirectory: true)
    }()

    static var sessionURL: URL { folder.appendingPathComponent("session.json") }
    static var draftsFolder: URL { folder.appendingPathComponent("Drafts", isDirectory: true) }
    static func draftURL(_ id: UUID) -> URL { draftsFolder.appendingPathComponent("\(id.uuidString).txt") }

    /// Черновик без вкладки удаляется через 30 дней.
    static let orphanDraftAge: TimeInterval = 30 * 24 * 3600
    static let autosaveDelay: TimeInterval = 2

    private static var pending: DispatchWorkItem?
    /// Номер правки, уже записанной в черновик (чтобы не переписывать 10 МБ без изменений).
    private static var savedVersions: [UUID: Int] = [:]
    private static var versions: [UUID: Int] = [:]
    /// Окно закрывается — вкладки убираются, сессию не трогаем.
    static var suspended = false

    // MARK: - Запись

    /// Через 2 с после последней правки.
    static func scheduleSave(_ workspace: EditorWorkspace) {
        guard !suspended else { return }
        if let tab = workspace.current { versions[tab.id, default: 0] += 1 }
        pending?.cancel()
        let work = DispatchWorkItem { [weak workspace] in
            MainActor.assumeIsolated { if let workspace { save(workspace) } }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: work)
    }

    static func noteEdit(_ tab: EditorTab) { versions[tab.id, default: 0] += 1 }

    /// Записать сессию и черновики изменённых вкладок.
    static func save(_ workspace: EditorWorkspace) {
        pending?.cancel()
        pending = nil
        guard !suspended else { return }
        let keepDrafts = EditorPrefs.autosaveDrafts
        guard EditorPrefs.restoreSession || keepDrafts else { return }
        var entries: [Entry] = []
        for tab in workspace.tabs {
            let untitled = tab.document.url == nil
            if untitled && tab.length == 0 { continue }
            var entry = Entry(id: tab.id, path: tab.document.url?.path, untitledName: untitled ? tab.untitledName : nil,
                              encoding: tab.document.encoding, decodedEncoding: tab.document.isConverted ? nil : tab.document.encoding,
                              language: tab.document.language,
                              selection: [tab.textView.selectedRange().location, tab.textView.selectedRange().length],
                              scroll: [Double(tab.scrollView.contentView.bounds.minX), Double(tab.scrollView.contentView.bounds.minY)],
                              bookmarks: tab.bookmarks.sorted(), fileStamp: tab.document.fileStamp, draftID: nil)
            if tab.isDirty || untitled {
                guard keepDrafts else {
                    // Без черновиков правки не хранятся, но файл вкладки откроется снова (как чистые).
                    if !untitled, EditorPrefs.restoreSession { entries.append(entry) }
                    continue
                }
                let draft = tab.draftID ?? UUID()
                tab.draftID = draft
                let version = versions[tab.id, default: 0]
                if savedVersions[draft] != version || !FileManager.default.fileExists(atPath: draftURL(draft).path) {
                    do {
                        try FileManager.default.createDirectory(at: draftsFolder, withIntermediateDirectories: true)
                        try Data((tab.text as String).utf8).write(to: draftURL(draft), options: .atomic)
                        savedVersions[draft] = version
                    } catch {
                        continue
                    }
                }
                entry.draftID = draft
            } else if !EditorPrefs.restoreSession {
                continue
            }
            entries.append(entry)
        }
        let state = State(tabs: entries, selected: workspace.current?.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: sessionURL, options: .atomic)
        } catch {
            NSLog("Editor session not saved: \(error.localizedDescription)")
        }
    }

    /// Вкладку закрыли без сохранения или сохранили — черновик больше не нужен.
    static func discardDraft(of tab: EditorTab) {
        guard let draft = tab.draftID else { return }
        try? FileManager.default.removeItem(at: draftURL(draft))
        savedVersions[draft] = nil
        tab.draftID = nil
    }

    // MARK: - Восстановление

    /// Прочитать сессию; сломанный файл переименовывается в `.broken`, начинаем с пустой.
    static func load() -> State? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        do {
            return try JSONDecoder().decode(State.self, from: data)
        } catch {
            let broken = sessionURL.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: sessionURL, to: broken)
            return nil
        }
    }

    static func restore(into workspace: EditorWorkspace) {
        defer { removeOrphanDrafts(keeping: Set(workspace.tabs.compactMap(\.draftID))) }
        guard EditorPrefs.restoreSession || EditorPrefs.autosaveDrafts, let state = load() else { return }
        for entry in state.tabs {
            if let tab = makeTab(entry, workspace: workspace) { workspace.add(tab, select: false) }
        }
        workspace.selectedID = state.selected.flatMap { id in workspace.tabs.first { $0.id == id }?.id } ?? workspace.tabs.first?.id
    }

    static func makeTab(_ entry: Entry, workspace: EditorWorkspace) -> EditorTab? {
        let draft = entry.draftID.flatMap { try? Data(contentsOf: draftURL($0)) }.map { String(decoding: $0, as: UTF8.self) }
        if entry.draftID == nil, !EditorPrefs.restoreSession { return nil }
        var document: EditorDocument
        var missing = false
        if let path = entry.path {
            let url = URL(fileURLWithPath: path)
            if let opened = try? EditorDocument.open(url) {
                document = opened
                if let decoded = entry.decodedEncoding, decoded != document.encoding { document.reinterpret(as: decoded) }
                document.encoding = entry.encoding
            } else {
                guard draft != nil else { return nil }
                missing = true
                document = EditorDocument(newWith: entry.encoding)
                document.url = url
            }
            document.language = entry.language
        } else {
            guard draft != nil else { return nil }
            document = EditorDocument(newWith: entry.encoding)
            document.language = entry.language
        }
        let tab = EditorTab(document: document, text: draft, id: entry.id, zoom: workspace.zoom)
        tab.untitledName = entry.untitledName ?? workspace.untitledName()
        tab.draftID = draft == nil ? nil : entry.draftID
        tab.fileMissing = missing
        tab.bookmarks = Set(entry.bookmarks)
        if missing || document.isConverted { tab.markChanged() }
        // Файл изменён снаружи после того, как правки ушли в черновик, — баннер «Перезагрузить / Оставить мою версию».
        if !missing, let saved = entry.fileStamp, let now = document.fileStamp, saved != now, draft != nil { tab.changedOnDisk = true }
        let length = tab.storage.length
        if entry.selection.count == 2 {
            let location = min(max(entry.selection[0], 0), length)
            tab.textView.setSelectedRange(NSRange(location: location, length: min(max(entry.selection[1], 0), length - location)))
        }
        if entry.scroll.count == 2 {
            let point = NSPoint(x: entry.scroll[0], y: entry.scroll[1])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    tab.textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(length, tab.textView.selectedRange().location + 1)))
                    tab.scrollView.contentView.scroll(to: point)
                    tab.scrollView.reflectScrolledClipView(tab.scrollView.contentView)
                }
            }
        }
        return tab
    }

    /// Черновики без вкладки старше 30 дней.
    static func removeOrphanDrafts(keeping: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: draftsFolder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let referenced = Set((load()?.tabs ?? []).compactMap(\.draftID)).union(keeping)
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !referenced.contains(id) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > orphanDraftAge { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// Недавние файлы редактора: 15 путей, последний — первым.
enum EditorRecent {
    static let limit = 15

    static var paths: [String] { UserDefaults.standard.stringArray(forKey: Pref.editorRecent) ?? [] }

    static var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    static func add(_ url: URL) {
        var list = paths.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: Pref.editorRecent)
    }

    static func remove(_ url: URL) {
        UserDefaults.standard.set(paths.filter { $0 != url.path }, forKey: Pref.editorRecent)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: Pref.editorRecent) }

    /// «~/Documents/Формы» вместо полного пути.
    static func folderTitle(_ url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}
