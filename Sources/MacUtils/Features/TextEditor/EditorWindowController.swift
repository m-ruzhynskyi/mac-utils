import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MUCore
import MUDesign
import MUAudio
import MUScreenshot

/// Окно редактора: одно окно — много вкладок. Пока оно открыто, Mac Utils — обычное приложение со значком в Dock
/// и строкой меню «Файл / Правка / Поиск / Вид / Кодировка / Синтаксис»; с последним окном — снова фоновое.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let shared = EditorWindowController()

    let workspace = EditorWorkspace()
    private(set) var window: EditorWindow?
    private var closingWindow = false

    /// Окно открыто (для `AppDelegate.syncDock`).
    var isOpen: Bool { window?.isVisible ?? false }
    var isKey: Bool { window?.isKeyWindow ?? false }

    // MARK: - Окно

    /// Открыть редактор: вкладки прошлого сеанса или пустой документ.
    func show() {
        let window = self.window ?? makeWindow()
        if workspace.tabs.isEmpty {
            EditorSession.restore(into: workspace)
            if workspace.tabs.isEmpty { _ = workspace.newDocument() }
        }
        let wasVisible = window.isVisible
        if !wasVisible { FocusReturn.remember() }
        AppRouter.shared.syncDock(true, nil)
        ScreenOutput.activateApp()
        window.makeKeyAndOrderFrontOnScreen()
        window.centerTrafficLights()
        if !wasVisible { checkDisk() }
    }

    private func makeWindow() -> EditorWindow {
        let window = EditorWindow.make(workspace: workspace)
        window.delegate = self
        if !window.setFrameUsingName("MacUtilsEditor") { window.center() }
        window.setFrameAutosaveName("MacUtilsEditor")
        workspace.onChange = { [weak self] in self?.workspaceChanged() }
        workspace.onOpenFiles = { [weak self] in self?.open($0) }
        self.window = window
        return window
    }

    private func workspaceChanged() {
        guard let window else { return }
        let tab = workspace.current
        window.title = tab.map { workspace.displayTitle($0) } ?? "Текстовый редактор"
        window.representedURL = tab?.document.url
        window.isDocumentEdited = tab?.isDirty ?? false
        EditorSession.scheduleSave(workspace)
    }

    func windowDidResize(_ notification: Notification) { window?.centerTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { window?.centerTrafficLights() }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.centerTrafficLights()
        checkDisk()
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.centerTrafficLights()
        // Уход окна из фокуса — сохранить черновики сразу.
        EditorSession.save(workspace)
    }

    /// Что делать с вкладками при закрытии окна или выходе из приложения.
    enum ClosePlan: Equatable {
        /// Изменённых нет — закрыть.
        case close
        /// Изменённые уходят в черновики сессии молча (вернутся при следующем открытии).
        case keepInDrafts
        /// Спросить про изменённые: черновиков нет — иначе правки пропадут.
        case ask
    }

    static func closePlan(dirtyCount: Int, autosaveDrafts: Bool) -> ClosePlan {
        guard dirtyCount > 0 else { return .close }
        return autosaveDrafts ? .keepInDrafts : .ask
    }

    /// Закрытие окна: при автосохранении черновиков всё уходит в сессию молча; иначе — вопрос по каждой изменённой вкладке.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closingWindow else { return true }
        let dirty = workspace.tabs.filter(\.isDirty)
        switch Self.closePlan(dirtyCount: dirty.count, autosaveDrafts: EditorPrefs.autosaveDrafts) {
        case .close, .keepInDrafts:
            EditorSession.save(workspace)
            return true
        case .ask:
            break
        }
        closeAll(dirty) { [weak self] done in
            guard done, let self else { return }
            self.closingWindow = true
            self.window?.close()
            self.closingWindow = false
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        EditorSession.save(workspace)
        // Память 10-мегабайтных вкладок освобождается; при следующем открытии вкладки вернутся из сессии.
        EditorSession.suspended = true
        for tab in workspace.tabs { workspace.remove(tab) }
        EditorSession.suspended = false
        workspace.findMode = nil
        workspace.overlay = nil
        DispatchQueue.main.async {
            AppRouter.shared.syncDock(false, nil)
            if !AppRouter.shared.settingsVisible() { FocusReturn.restore() }
        }
    }

    /// Спросить по очереди про каждую изменённую вкладку; `done(false)` — «Отмена».
    private func closeAll(_ tabs: [EditorTab], done: @escaping (Bool) -> Void) {
        guard let tab = tabs.first else { return done(true) }
        workspace.selectedID = tab.id
        askToSave(tab) { [weak self] result in
            guard result != .cancel, let self else { return done(false) }
            self.closeAll(Array(tabs.dropFirst()), done: done)
        }
    }

    // MARK: - Открытие

    func newDocument() {
        show()
        _ = workspace.newDocument()
    }

    func openPanel() {
        show()
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Откройте .frm, .rtf, .txt, .json, .xml, .csv или любой текстовый файл"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.open(panel.urls) }
        }
    }

    /// Открыть файлы вкладками (уже открытый — только переключиться на него).
    func open(_ urls: [URL]) {
        show()
        for url in urls {
            if let existing = workspace.tab(for: url) {
                workspace.selectedID = existing.id
                continue
            }
            switch Self.openCheck(url) {
            case .ok: break
            case .large(let bytes):
                guard confirmLargeFile(url, bytes: bytes) else { continue }
            case .unreadable(let reason):
                showError("Не удалось открыть «\(url.lastPathComponent)»", EditorDocument.OpenError.notRegularFile(reason))
                continue
            }
            do {
                let document = try EditorDocument.open(url)
                let replaceEmpty = workspace.tabs.count == 1 && workspace.tabs[0].document.url == nil
                    && !workspace.tabs[0].isDirty && workspace.tabs[0].length == 0
                let blank = replaceEmpty ? workspace.tabs[0] : nil
                let tab = EditorTab(document: document, zoom: workspace.zoom)
                // .frm и .rtf — сразу «Документом» (или как выбирали для этого типа в последний раз).
                tab.restoreMode(nil)
                workspace.add(tab)
                if let blank { workspace.remove(blank) }
                EditorRecent.add(url)
            } catch {
                // Файла больше нет — и в недавних ему не место.
                if !FileManager.default.fileExists(atPath: url.path) { EditorRecent.remove(url) }
                showError("Не удалось открыть «\(url.lastPathComponent)»", error)
            }
        }
    }

    /// Открыть файл вкладкой сразу в нужном режиме (для «Команд», ссылок): «Документ» — только у RTF.
    func open(_ url: URL, mode: EditorViewMode) {
        open([url])
        guard let tab = workspace.tab(for: url) else { return }
        workspace.selectedID = tab.id
        if mode == .document, !tab.canShowDocument { return }
        tab.setMode(mode)
    }

    /// Что можно открыть: только обычный файл (не папка, устройство, канал); большой — после вопроса.
    enum OpenCheck: Equatable {
        case ok
        case large(Int)
        case unreadable(String)
    }

    static let largeFileBytes = 100 * 1024 * 1024

    static func openCheck(_ url: URL) -> OpenCheck {
        let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        guard let values else { return .unreadable("файл не найден") }
        if values.isDirectory == true { return .unreadable("это папка") }
        guard values.isRegularFile == true else { return .unreadable("это не обычный файл (устройство или канал)") }
        let size = values.fileSize ?? 0
        return size > largeFileBytes ? .large(size) : .ok
    }

    private func confirmLargeFile(_ url: URL, bytes: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Открыть большой файл «\(url.lastPathComponent)»?"
        alert.informativeText = "Размер — \(DS.Format.bytes(Int64(bytes))). Файл целиком читается в память, это может занять время."
        alert.addButton(withTitle: "Открыть")
        alert.addButton(withTitle: "Отмена")
        ScreenOutput.activateApp()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// `macutils://editor?path=…` может вызвать любая программа или страница — сначала показать путь и спросить.
    func openFromLink(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Открыть файл в текстовом редакторе?"
        alert.informativeText = "Ссылка просит открыть:\n\(url.path)"
        alert.addButton(withTitle: "Открыть")
        alert.addButton(withTitle: "Отмена")
        ScreenOutput.activateApp()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        open([url])
    }

    func openDropped(_ providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { EditorWindowController.shared.open([url]) } }
            }
        }
    }

    // MARK: - Сохранение

    enum SaveResult { case saved, discarded, cancel }

    /// Сохранить вкладку (новую — через «Сохранить как»). `done(true)` — записано.
    func save(_ tab: EditorTab, as forceDialog: Bool = false, done: ((Bool) -> Void)? = nil) {
        guard !forceDialog, let url = tab.document.url, !tab.fileMissing else {
            return saveAs(tab, done: done)
        }
        // Без правок — файл не трогаем (время изменения остаётся прежним).
        if !tab.isDirty, !tab.changedOnDisk { done?(true); return }
        // Свежая сверка с диском прямо перед записью: файл могли переписать, пока окно было в фокусе
        // (баннер появляется только при возврате в окно), — молча затирать чужую версию нельзя.
        guard tab.document.isChangedOnDisk else { return write(tab, to: url, done: done) }
        tab.changedOnDisk = true
        externalChangePrompt(tab) { [weak self] choice in
            guard let self else { done?(false); return }
            switch choice {
            case .overwrite: self.write(tab, to: url, done: done)
            case .reload:
                self.reloadFromDisk(tab)
                done?(false)
            case .cancel: done?(false)
            }
        }
    }

    enum ExternalChangeChoice { case overwrite, reload, cancel }

    /// Вопрос «Файл изменён другой программой: Перезаписать / Перезагрузить / Отмена» (в тестах подменяется).
    lazy var externalChangePrompt: (EditorTab, @escaping (ExternalChangeChoice) -> Void) -> Void = { [weak self] tab, answer in
        guard let self, let window = self.window else { return answer(.cancel) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Файл изменён другой программой"
        alert.informativeText = "«\(self.workspace.displayTitle(tab))» изменили на диске после того, как он был открыт здесь. "
            + "«Перезаписать» заменит ту версию вашей, «Перезагрузить» покажет её вместо вашей"
            + (tab.isDirty ? " (ваши правки пропадут)." : ".")
        alert.addButton(withTitle: "Перезаписать")
        alert.addButton(withTitle: "Перезагрузить")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: answer(.overwrite)
                case .alertSecondButtonReturn: answer(.reload)
                default: answer(.cancel)
                }
            }
        }
    }

    private func saveAs(_ tab: EditorTab, done: ((Bool) -> Void)?) {
        guard let window else { done?(false); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tab.document.url?.lastPathComponent ?? "\(tab.untitledName).txt"
        if let folder = tab.document.url?.deletingLastPathComponent() { panel.directoryURL = folder }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self else { done?(false); return }
                self.write(tab, to: url, done: done)
            }
        }
    }

    private func write(_ tab: EditorTab, to url: URL, lossy: Bool = false, done: ((Bool) -> Void)?) {
        // Правили в «Документе» — сначала проверки без потерь; не прошли — файл не пишется (лист `d10`).
        if tab.editedInDocument, !lossy {
            let report = DocSaveGuard.check(document: tab.document, text: tab.text, journal: tab.journal)
            guard report.passed else { return presentSaveGuard(report, for: tab, done: done) }
        }
        let text = tab.text.copy() as! NSString as String
        do {
            let data = try tab.document.data(for: text, lossy: lossy)
            try Self.writeFile(data, to: url)
            tab.document.didSave(data, text: text, to: url)
            if tab.document.language == .plain { tab.document.language = EditorLanguage.detect(url: url, head: data.prefix(64)) }
            tab.fileMissing = false
            tab.changedOnDisk = false
            tab.markSaved()
            EditorRecent.add(url)
            EditorSession.discardDraft(of: tab)
            workspaceChanged()
            done?(true)
        } catch let error as EditorDocument.SaveError {
            guard case .unrepresentable(let characters) = error, let window else { done?(false); return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Некоторых символов нет в \(tab.document.encoding.title)"
            alert.informativeText = "Не помещаются: \(characters.map(String.init).joined(separator: " "))\nПри сохранении они станут знаком «?». "
                + "Можно выбрать другую кодировку в строке состояния."
            alert.addButton(withTitle: "Сохранить с заменой")
            alert.addButton(withTitle: "Отмена")
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    guard response == .alertFirstButtonReturn else { done?(false); return }
                    self?.write(tab, to: url, lossy: true, done: done)
                }
            }
        } catch {
            showError("Не удалось сохранить «\(url.lastPathComponent)»", error)
            done?(false)
        }
    }

    /// Запись целиком: новый файл — атомарно; существующий — через замену (права, метки Finder и дата создания
    /// остаются, при сбое на диске остаётся прежний файл).
    nonisolated static func writeFile(_ data: Data, to link: URL) throws {
        // Пишем в настоящий файл: `replaceItemAt` по символической ссылке заменил бы саму ссылку обычным файлом.
        let url = link.resolvingSymlinksInPath()
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return try data.write(to: url, options: .atomic) }
        let folder = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? manager.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temporary)
        _ = try manager.replaceItemAt(url, withItemAt: temporary)
    }

    /// «Сохранить изменения?» — лист «Сохранить / Не сохранять / Отмена».
    func askToSave(_ tab: EditorTab, done: @escaping (SaveResult) -> Void) {
        guard tab.isDirty, let window else { return done(.discarded) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Сохранить изменения в «\(workspace.displayTitle(tab))»?"
        alert.informativeText = "Если не сохранить, правки пропадут."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Не сохранять")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn:
                    self?.save(tab) { saved in done(saved ? .saved : .cancel) }
                case .alertSecondButtonReturn:
                    done(.discarded)
                default:
                    done(.cancel)
                }
            }
        }
    }

    // MARK: - Вкладки

    /// ⌘W: закрыть вкладку (с вопросом, если есть правки); последняя — закрывает окно.
    func close(_ tab: EditorTab) {
        askToSave(tab) { [weak self] result in
            guard result != .cancel, let self else { return }
            EditorSession.discardDraft(of: tab)
            self.workspace.remove(tab)
            if self.workspace.tabs.isEmpty {
                self.closingWindow = true
                self.window?.close()
                self.closingWindow = false
            }
        }
    }

    func closeCurrentTab() {
        if let tab = workspace.current { close(tab) } else { window?.close() }
    }

    // MARK: - Кодировка, перевод строки, синтаксис

    /// «Открыть заново в…»: те же байты в другой кодировке; при несохранённых правках — сначала вопрос.
    func reopen(_ tab: EditorTab, as encoding: TextEncoding) {
        let apply = { [weak self] in
            tab.document.reinterpret(as: encoding)
            tab.load(tab.document.decodedText, resetUndo: true)
            tab.markSaved()
            tab.updateDirty()
            self?.workspaceChanged()
        }
        guard tab.isDirty, let window else { return apply() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Открыть заново в \(encoding.title)?"
        alert.informativeText = "Текст перечитается из исходных байтов, несохранённые правки пропадут."
        alert.addButton(withTitle: "Открыть заново")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { apply() } }
        }
    }

    /// «Преобразовать в…»: текст тот же, при сохранении — другая кодировка. Символов, которых нет, — предупреждение.
    func convert(_ tab: EditorTab, to encoding: TextEncoding) {
        let missing = encoding.unrepresentable(in: tab.text as String)
        let apply = { [weak self] in
            tab.document.encoding = encoding
            tab.document.reason = .manual
            tab.document.utf16BOM = true
            tab.updateDirty()
            self?.workspaceChanged()
        }
        guard !missing.isEmpty, let window else { return apply() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "В \(encoding.title) нет некоторых символов"
        alert.informativeText = "Не помещаются: \(missing.map(String.init).joined(separator: " "))\n"
            + "Если преобразовать, при сохранении они станут знаком «?»."
        alert.addButton(withTitle: "Преобразовать")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { apply() } }
        }
    }

    func setLanguage(_ language: EditorLanguage, for tab: EditorTab) {
        tab.document.language = language
        tab.rehighlight()
        workspaceChanged()
    }

    // MARK: - Файл на диске

    /// Файлы вкладок изменили снаружи или удалили — баннер в вкладке.
    func checkDisk() {
        for tab in workspace.tabs {
            guard let url = tab.document.url else { continue }
            let exists = FileManager.default.fileExists(atPath: url.path)
            if tab.fileMissing != !exists { tab.fileMissing = !exists }
            let changed = exists && tab.document.isChangedOnDisk
            if tab.changedOnDisk != changed { tab.changedOnDisk = changed }
        }
    }

    func reloadFromDisk(_ tab: EditorTab) {
        guard let url = tab.document.url else { return }
        do {
            let document = try EditorDocument.open(url)
            let language = tab.document.language
            tab.document = document
            tab.document.language = language
            tab.load(document.decodedText, resetUndo: true)
            tab.changedOnDisk = false
            tab.markSaved()
            workspaceChanged()
        } catch {
            showError("Не удалось перечитать «\(url.lastPathComponent)»", error)
        }
    }

    /// «Оставить мою версию»: баннер скрывается, вкладка остаётся изменённой (сохранение перезапишет файл).
    func keepMine(_ tab: EditorTab) {
        if let url = tab.document.url { tab.document.fileStamp = FileStamp(url: url) }
        tab.changedOnDisk = false
        tab.markChanged()
    }

    // MARK: - Поиск

    func showFind(replace: Bool) {
        guard let tab = workspace.current else { return }
        // Поиск и замена работают по исходнику — в «Код» (место переносится).
        if tab.mode == .document { tab.setMode(.code) }
        if workspace.findMode == nil { workspace.search.prepare(from: tab) }
        workspace.findMode = replace || workspace.findMode == true
        workspace.search.refresh()
        NotificationCenter.default.post(name: .editorFocusFind, object: nil)
    }

    // MARK: - Поиск в папке

    /// ⇧⌘F: панель «Поиск в папке» внизу окна; запрос и опции — из панели поиска, папка — последняя или папка файла.
    func showFolderSearch() {
        let model = workspace.folderSearch
        if model.query.isEmpty { model.query = workspace.search.query }
        if model.folder == nil { model.folder = workspace.current?.document.url?.deletingLastPathComponent() }
        // Опции панели поиска — только для нового списка: найденный список остаётся со своими.
        if model.summary == nil { model.options = workspace.search.options }
        model.dirtyOpenFiles = { [weak self] in
            Set((self?.workspace.tabs ?? []).filter(\.isDirty).compactMap { $0.document.url?.standardizedFileURL.resolvingSymlinksInPath().path })
        }
        model.reloadOpenFiles = { [weak self] urls in
            guard let self else { return }
            for url in urls { if let tab = self.workspace.tab(for: url), !tab.isDirty { self.reloadFromDisk(tab) } }
        }
        workspace.folderSearchVisible = true
    }

    /// Открыть найденное: вкладка файла и выделение совпадения.
    func openFolderMatch(_ url: URL, range: NSRange) {
        open([url])
        guard let tab = workspace.tab(for: url) else { return }
        workspace.selectedID = tab.id
        DispatchQueue.main.async { tab.reveal(range) }
    }

    /// «Заменить в папке…» — файлы на диске перезаписываются, отменить нельзя: сначала вопрос.
    func confirmFolderReplace() {
        let model = workspace.folderSearch
        guard model.canReplace, let summary = model.summary, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Заменить \(summary.matchCount) \(plural(summary.matchCount, "совпадение", "совпадения", "совпадений")) "
            + "в \(summary.files.count) \(plural(summary.files.count, "файле", "файлах", "файлах"))?"
        alert.informativeText = "Заменяется «\(model.query)» → «\(model.replacement)». Файлы перезапишутся на диске в своих кодировках — "
            + "⌘Z это не отменит. Не тронутся открытые вкладки с несохранёнными правками и файлы, изменённые после поиска."
        alert.addButton(withTitle: "Заменить")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { model.replaceAll() } }
        }
    }

    func hideFind() {
        workspace.findMode = nil
        workspace.search.clear()
        if let tab = workspace.current { tab.textView.window?.makeFirstResponder(tab.textView) }
    }

    // MARK: - Защита при записи

    /// Показ листа (подменяется в тестах): `d10` с выбором «Сохранить как копию…», «Показать в коде», «Отмена».
    lazy var saveGuardPrompt: (DocSaveGuard.Report, EditorTab, @escaping (Bool) -> Void) -> Void = { [weak self] report, tab, done in
        guard let self, let window = self.window else { return done(false) }
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.titled], backing: .buffered, defer: true)
        func finish() {
            window.endSheet(sheet)
        }
        let view = DocSaveGuardSheet(report: report) { [weak self] in
            finish()
            self?.saveCopy(report, of: tab) { _ in done(false) }
        } showInCode: {
            finish()
            if let range = report.problemRange { tab.showInCode(range) } else { tab.setMode(.code) }
            done(false)
        } cancel: {
            finish()
            done(false)
        }
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        sheet.contentView = host
        sheet.setContentSize(host.fittingSize)
        window.beginSheet(sheet)
    }

    private func presentSaveGuard(_ report: DocSaveGuard.Report, for tab: EditorTab, done: ((Bool) -> Void)?) {
        saveGuardPrompt(report, tab) { done?($0) }
    }

    /// «Сохранить как копию…»: те же байты с правками — в другой файл; оригинал и вкладка не меняются.
    func saveCopy(_ report: DocSaveGuard.Report, of tab: EditorTab, done: @escaping (Bool) -> Void) {
        guard let data = report.data, let window else { return done(false) }
        let panel = NSSavePanel()
        let base = tab.document.url?.deletingPathExtension().lastPathComponent ?? tab.untitledName
        let ext = tab.document.url?.pathExtension ?? "rtf"
        panel.nameFieldStringValue = "\(base) копия.\(ext.isEmpty ? "rtf" : ext)"
        if let folder = tab.document.url?.deletingLastPathComponent() { panel.directoryURL = folder }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return done(false) }
                do {
                    try Self.writeFile(data, to: url)
                    tab.documentController?.show(notice: "Копия сохранена: \(url.lastPathComponent). Оригинал не тронут.")
                    done(true)
                } catch {
                    self?.showError("Не удалось сохранить копию «\(url.lastPathComponent)»", error)
                    done(false)
                }
            }
        }
    }

    // MARK: - Открыть в Word

    static let wordBundleID = "com.microsoft.Word"

    /// Заглушка «Открыть в Word»: Word открывает файл с диска — несохранённые правки сначала сохранить или оставить.
    func openInWord(_ tab: EditorTab?) {
        guard let tab, let url = tab.document.url else { return Feedback.beep() }
        guard let word = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.wordBundleID) else {
            let alert = NSAlert()
            alert.messageText = "Microsoft Word не найден"
            alert.informativeText = "Этот элемент можно посмотреть в Word, но Word на этом Mac не установлен. «Показать в коде» откроет его исходник."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        let open = {
            NSWorkspace.shared.open([url], withApplicationAt: word, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        guard tab.isDirty, let window else { return open() }
        let alert = NSAlert()
        alert.messageText = "Открыть в Word версию с диска?"
        alert.informativeText = "Word прочитает файл с диска — несохранённых правок в нём ещё нет."
        alert.addButton(withTitle: "Сохранить и открыть")
        alert.addButton(withTitle: "Открыть с диска")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: self?.save(tab) { saved in if saved { open() } }
                case .alertSecondButtonReturn: open()
                default: break
                }
            }
        }
    }

    // MARK: - Ошибки

    func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = (error as NSError).localizedDescription
        if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - Выход из приложения

    /// ⌘Q: при автосохранении черновиков всё уходит в них молча; иначе — вопрос. `false` — выход отменён.
    func prepareForTermination() -> Bool {
        guard !workspace.tabs.isEmpty else { return true }
        EditorSession.save(workspace)
        let dirty = workspace.tabs.filter(\.isDirty)
        guard Self.closePlan(dirtyCount: dirty.count, autosaveDrafts: EditorPrefs.autosaveDrafts) == .ask else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dirty.count == 1 ? "Есть несохранённый документ" : "Несохранённых документов: \(dirty.count)"
        alert.informativeText = "Выйти без сохранения? Правки пропадут. Чтобы не терять их, включите «Автосохранение черновиков» в настройках редактора."
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Выйти без сохранения")
        ScreenOutput.activateApp()
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Пункты меню

    private var tab: EditorTab? { isKey || window?.isMainWindow == true ? workspace.current : nil }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        let tab = self.tab
        switch action {
        case #selector(editorReopen(_:)):
            let encoding = TextEncoding.allCases[item.tag]
            item.state = tab?.document.encoding == encoding && !(tab?.document.isConverted ?? false) ? .on : .off
            return tab != nil
        case #selector(editorConvert(_:)):
            item.state = tab?.document.encoding == TextEncoding.allCases[item.tag] ? .on : .off
            return tab != nil
        case #selector(editorLineEnding(_:)):
            item.state = tab?.lineEnding == .single(LineEnding.allCases[item.tag]) ? .on : .off
            return tab != nil
        case #selector(editorLanguage(_:)):
            item.state = tab?.document.language == EditorLanguage.allCases[item.tag] ? .on : .off
            return tab != nil
        case #selector(editorToggleInvisibles(_:)):
            item.state = workspace.showsInvisibles ? .on : .off
            return tab != nil
        case #selector(editorToggleBrackets(_:)):
            item.state = workspace.matchesBrackets ? .on : .off
            return tab != nil
        case #selector(editorToggleWrap(_:)):
            item.state = workspace.wraps ? .on : .off
            return tab != nil
        case #selector(editorToggleDocument(_:)):
            item.state = tab?.mode == .document ? .on : .off
            if let reason = tab?.documentUnavailableReason { item.toolTip = reason }
            return tab?.canShowDocument ?? false
        case #selector(editorShowCode(_:)):
            item.state = tab?.mode == .code ? .on : .off
            return tab?.isRTF ?? false
        case #selector(editorToggleDollarPanel(_:)):
            item.state = workspace.dollarPanelVisible ? .on : .off
            return tab != nil
        case #selector(editorRemoveValues(_:)):
            return (tab?.dollars.removableCount ?? 0) > 0
        case #selector(editorFindNext(_:)), #selector(editorFindPrevious(_:)):
            return tab != nil && !workspace.search.query.isEmpty
        case #selector(editorNextBookmark(_:)), #selector(editorPreviousBookmark(_:)), #selector(editorClearBookmarks(_:)):
            return !(tab?.bookmarks.isEmpty ?? true)
        case #selector(editorZoomOut(_:)):
            if let document = documentInFront { return document.zoom > DocumentController.zoomRange.lowerBound }
            return tab != nil && workspace.zoom > EditorStyle.zoomRange.lowerBound
        case #selector(editorZoomIn(_:)):
            if let document = documentInFront { return document.zoom < DocumentController.zoomRange.upperBound }
            return tab != nil && workspace.zoom < EditorStyle.zoomRange.upperBound
        default:
            return tab != nil
        }
    }

    @objc func editorSave(_ sender: Any?) { if let tab { save(tab) } }
    @objc func editorSaveAs(_ sender: Any?) { if let tab { save(tab, as: true) } }
    @objc func editorCloseTab(_ sender: Any?) { closeCurrentTab() }
    @objc func editorNextTab(_ sender: Any?) { workspace.select(offset: 1) }
    @objc func editorPreviousTab(_ sender: Any?) { workspace.select(offset: -1) }

    @objc func editorFind(_ sender: Any?) { showFind(replace: false) }
    @objc func editorReplace(_ sender: Any?) { showFind(replace: true) }
    @objc func editorFindNext(_ sender: Any?) {
        if workspace.findMode == nil { showFind(replace: false) }
        workspace.search.next()
    }
    @objc func editorFindPrevious(_ sender: Any?) {
        if workspace.findMode == nil { showFind(replace: false) }
        workspace.search.next(backwards: true)
    }
    @objc func editorGoToLine(_ sender: Any?) { workspace.overlay = .goToLine }
    @objc func editorFindInFolder(_ sender: Any?) { showFolderSearch() }

    @objc func editorToggleWrap(_ sender: Any?) { workspace.wraps.toggle() }
    @objc func editorToggleDocument(_ sender: Any?) { if let tab { tab.setMode(tab.mode == .document ? .code : .document) } }
    @objc func editorShowCode(_ sender: Any?) { tab?.setMode(.code) }
    @objc func editorToggleInvisibles(_ sender: Any?) { workspace.showsInvisibles.toggle() }
    @objc func editorToggleBrackets(_ sender: Any?) { workspace.matchesBrackets.toggle() }
    @objc func editorZoomIn(_ sender: Any?) {
        if let document = documentInFront { return document.step(zoom: 1) }
        workspace.zoom = min(EditorStyle.zoomRange.upperBound, (workspace.zoom * 10 + 1).rounded() / 10)
    }
    @objc func editorZoomOut(_ sender: Any?) {
        if let document = documentInFront { return document.step(zoom: -1) }
        workspace.zoom = max(EditorStyle.zoomRange.lowerBound, (workspace.zoom * 10 - 1).rounded() / 10)
    }
    @objc func editorZoomReset(_ sender: Any?) {
        if let document = documentInFront {
            document.fit = .none
            document.zoom = 1
            return
        }
        workspace.zoom = 1
    }

    /// Вкладка в «Документе»: ⌘+ / ⌘− / ⌘0 меняют масштаб страниц.
    private var documentInFront: DocumentController? { tab?.mode == .document ? tab?.documentController : nil }
    @objc func editorToggleDollarPanel(_ sender: Any?) { workspace.dollarPanelVisible.toggle() }
    @objc func editorRemoveValues(_ sender: Any?) {
        tab?.removeHighlightedValues()
    }

    @objc func editorReopen(_ sender: NSMenuItem) { if let tab { reopen(tab, as: TextEncoding.allCases[sender.tag]) } }
    @objc func editorConvert(_ sender: NSMenuItem) { if let tab { convert(tab, to: TextEncoding.allCases[sender.tag]) } }
    @objc func editorLineEnding(_ sender: NSMenuItem) { tab?.convertLineEndings(to: LineEnding.allCases[sender.tag]) }
    @objc func editorLanguage(_ sender: NSMenuItem) { if let tab { setLanguage(EditorLanguage.allCases[sender.tag], for: tab) } }

    @objc func editorDuplicateLine(_ sender: Any?) { tab?.apply(LineCommands.duplicate, name: "Дублировать строку") }
    @objc func editorDeleteLine(_ sender: Any?) { tab?.apply(LineCommands.delete, name: "Удалить строку") }
    @objc func editorMoveLineUp(_ sender: Any?) { tab?.apply({ LineCommands.move($0, $1, up: true) }, name: "Строку вверх") }
    @objc func editorMoveLineDown(_ sender: Any?) { tab?.apply({ LineCommands.move($0, $1, up: false) }, name: "Строку вниз") }
    @objc func editorTrimTrailing(_ sender: Any?) { tab?.apply(LineCommands.trimTrailingWhitespace, name: "Удалить хвостовые пробелы") }
    @objc func editorUppercase(_ sender: Any?) { tab?.apply({ LineCommands.changeCase($0, $1, .upper) }, name: "ВЕРХНИЙ РЕГИСТР") }
    @objc func editorLowercase(_ sender: Any?) { tab?.apply({ LineCommands.changeCase($0, $1, .lower) }, name: "нижний регистр") }
    @objc func editorSortAscending(_ sender: Any?) { tab?.apply({ LineCommands.sort($0, $1, .ascending) }, name: "Сортировать") }
    @objc func editorSortDescending(_ sender: Any?) { tab?.apply({ LineCommands.sort($0, $1, .descending) }, name: "Сортировать") }
    @objc func editorSortCaseInsensitive(_ sender: Any?) { tab?.apply({ LineCommands.sort($0, $1, .caseInsensitive) }, name: "Сортировать") }
    @objc func editorRemoveDuplicates(_ sender: Any?) {
        tab?.apply({ LineCommands.removeDuplicates($0, $1, caseSensitive: true) }, name: "Удалить повторы")
    }
    @objc func editorRemoveDuplicatesCaseInsensitive(_ sender: Any?) {
        tab?.apply({ LineCommands.removeDuplicates($0, $1, caseSensitive: false) }, name: "Удалить повторы")
    }
    @objc func editorTabsToSpaces(_ sender: Any?) {
        tab?.apply({ LineCommands.tabsToSpaces($0, $1, width: EditorPrefs.tabWidth) }, name: "Табы → пробелы")
    }
    @objc func editorSpacesToTabs(_ sender: Any?) {
        tab?.apply({ LineCommands.spacesToTabs($0, $1, width: EditorPrefs.tabWidth) }, name: "Пробелы → табы")
    }
    @objc func editorAddCaretAbove(_ sender: Any?) { tab?.textView.addCaret(lineOffset: -1) }
    @objc func editorAddCaretBelow(_ sender: Any?) { tab?.textView.addCaret(lineOffset: 1) }
    @objc func editorToggleBookmark(_ sender: Any?) { tab?.toggleBookmark() }
    @objc func editorNextBookmark(_ sender: Any?) { tab?.goToBookmark(backwards: false) }
    @objc func editorPreviousBookmark(_ sender: Any?) { tab?.goToBookmark(backwards: true) }
    @objc func editorClearBookmarks(_ sender: Any?) { tab?.clearBookmarks() }
    @objc func editorSentenceCase(_ sender: Any?) { tab?.apply({ LineCommands.changeCase($0, $1, .sentence) }, name: "Как в предложении") }
}

/// Окно редактора: «светофор» по центру полосы заголовка 50 pt; ⌘W закрывает вкладку, красная кнопка — окно.
final class EditorWindow: NSWindow {
    /// Окно без полосы заголовка: вкладки рисует `EditorRootView` на её месте.
    static func make(workspace: EditorWorkspace, size: NSSize = NSSize(width: 1100, height: 720)) -> EditorWindow {
        let window = EditorWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.title = "Текстовый редактор"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior.insert(.fullScreenPrimary)
        let host = NSHostingView(rootView: EditorRootView(workspace: workspace))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(size)
        return window
    }

    override func performClose(_ sender: Any?) {
        if let button = sender as? NSButton, button === standardWindowButton(.closeButton) {
            super.performClose(sender)
        } else {
            MainActor.assumeIsolated { EditorWindowController.shared.closeCurrentTab() }
        }
    }

    /// Кнопки окна — по центру полосы заголовка редактора (как в макете), а не у верхнего края.
    func centerTrafficLights() {
        guard !styleMask.contains(.fullScreen), let close = standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        let height = EditorRootView.titleBarHeight
        var frame = container.frame
        frame.size.height = height
        frame.origin.y = self.frame.height - height
        container.frame = frame
        titlebar.frame = container.bounds
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 20 + CGFloat(index) * 20, y: (height - button.frame.height) / 2))
        }
    }
}
