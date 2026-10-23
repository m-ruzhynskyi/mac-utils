import AppKit
import ApplicationServices
import MUCore
import MUDesign

/// Правила вырезания без системных вызовов (для тестов).
enum CutRules {
    /// Что осталось из вырезанного: файлы могли переименовать или удалить между ⌘X и ⌘V. `exists` видит и «висячие» ссылки.
    static func alive(_ urls: [URL], exists: (URL) -> Bool) -> (alive: [URL], gone: [URL]) {
        var alive: [URL] = [], gone: [URL] = []
        for url in urls { if exists(url) { alive.append(url) } else { gone.append(url) } }
        return (alive, gone)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    enum PasteAction: Equatable {
        /// Вырезанного нет — обычная вставка.
        case passThrough
        /// В буфер обмена после ⌘X что-то скопировали: вырезание отменяется, ⌘V работает как обычно.
        case cancelledByClipboard
        /// Все вырезанные файлы исчезли.
        case allGone
        /// Часть исчезла: переносим оставшиеся, об остальных сообщаем.
        case move(alive: [URL], goneCount: Int)
    }

    static func pasteAction(items: [URL], changeCount: Int, cutChangeCount: Int, exists: (URL) -> Bool) -> PasteAction {
        guard !items.isEmpty else { return .passThrough }
        guard changeCount == cutChangeCount else { return .cancelledByClipboard }
        let split = alive(items, exists: exists)
        if split.alive.isEmpty { return .allGone }
        return .move(alive: split.alive, goneCount: split.gone.count)
    }

    static func goneMessage(_ count: Int) -> String {
        "Не найдено при вставке: \(count) \(plural(count, "объект", "объекта", "объектов")) (переименованы или удалены)"
    }

    static let clipboardCancelMessage = "Вырезание отменено: буфер обмена изменился. ⌘V вставит скопированное"
}

/// ⌘X / ⌘V для файлов в Finder: ⌘X запоминает выделенные объекты,
/// ⌘V перемещает их в открытую папку. В текстовых полях (переименование,
/// поиск) сочетания работают как обычно.
@MainActor
final class FinderCutPaste: NSObject, ObservableObject {
    static let shared = FinderCutPaste()

    @Published private(set) var items: [URL] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false

    private static let finderID = "com.apple.finder"
    private static let keyX: Int64 = 7
    private static let keyV: Int64 = 9

    private var tap: EventTap?
    private var cutChangeCount = 0
    private let worker = DispatchQueue(label: "macutils.finder", qos: .userInitiated)
    private let panel = CutPanelController()

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func sync() {
        let wanted = UserDefaults.standard.bool(forKey: Pref.cutPaste) && Permissions.accessibility
        if wanted {
            if tap == nil {
                tap = EventTap(types: [.keyDown]) { [weak self] type, event in
                    self?.handle(type: type, event: event) ?? true
                }
            }
            isRunning = tap?.start() ?? false
        } else {
            tap?.stop()
            tap = nil
            isRunning = false
            items = []
        }
        refreshPanel()
    }

    func cancelCut() {
        items = []
        refreshPanel()
    }

    // MARK: - Клавиши

    private var finderIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderID
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown, finderIsFrontmost else { return true }
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        guard event.flags.intersection(modifiers) == .maskCommand else { return true }

        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch key {
        case Self.keyX:
            if isEditingText() { return true }
            if !isRepeat { cut() }
            return false
        case Self.keyV:
            switch CutRules.pasteAction(items: items, changeCount: NSPasteboard.general.changeCount,
                                        cutChangeCount: cutChangeCount, exists: CutRules.exists) {
            case .passThrough:
                return true
            case .cancelledByClipboard:
                // Пользователь скопировал что-то после ⌘X — обычная вставка, но не молча.
                cancelCut()
                Toast.show(CutRules.clipboardCancelMessage, symbol: "doc.on.clipboard", tint: .orange)
                return true
            case .allGone:
                cancelCut()
                Toast.show(CutRules.goneMessage(items.count), symbol: "exclamationmark.triangle.fill", tint: .orange)
                return true
            case .move(let alive, let goneCount):
                if isEditingText() { return true }
                if goneCount > 0 {
                    items = alive
                    refreshPanel()
                    Toast.show(CutRules.goneMessage(goneCount), symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
                if !isRepeat { paste() }
                return false
            }
        default:
            return true
        }
    }

    private func isEditingText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "AXSearchField"].contains(role)
    }

    // MARK: - Вырезать / вставить

    private func cut() {
        guard !isBusy else { return }
        isBusy = true
        worker.async {
            let result = FinderScript.selection()
            DispatchQueue.main.async {
                self.isBusy = false
                self.applyCut(result)
            }
        }
    }

    private func applyCut(_ result: FinderScript.Result<[URL]>) {
        switch result {
        case .failure(let message):
            Toast.show(message, symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .success(let urls):
            guard !urls.isEmpty else {
                Feedback.beep()
                return
            }
            items = urls
            cutChangeCount = NSPasteboard.general.changeCount
            if !UserDefaults.standard.bool(forKey: Pref.cutPanel) {
                Toast.show("Вырезано: \(urls.count) \(plural(urls.count, "объект", "объекта", "объектов"))",
                           symbol: "scissors", tint: .accentColor)
            }
            refreshPanel()
        }
    }

    private func paste() {
        guard !isBusy else { return }
        isBusy = true
        let urls = items
        worker.async {
            let destination = FinderScript.insertionFolder()
            var outcome: MoveOutcome?
            if case .success(let folder) = destination {
                outcome = FileMover.move(urls, into: folder)
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.finishPaste(destination: destination, outcome: outcome)
            }
        }
    }

    private func finishPaste(destination: FinderScript.Result<URL>, outcome: MoveOutcome?) {
        if case .failure(let message) = destination {
            Toast.show(message, symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        guard let outcome else { return }
        items = outcome.failed
        refreshPanel()
        if outcome.failed.isEmpty {
            Toast.show("Перемещено: \(outcome.moved) \(plural(outcome.moved, "объект", "объекта", "объектов"))",
                       symbol: "checkmark.circle.fill", tint: .green)
        } else {
            Toast.show("Не удалось переместить: \(outcome.failed.count). \(outcome.error ?? "")",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    // MARK: - Панель

    @objc private func appActivated() {
        refreshPanel()
    }

    private func refreshPanel() {
        // Панель не должна показывать файлы, которых уже нет (переименованы или удалены после ⌘X).
        if finderIsFrontmost, !items.isEmpty {
            let split = CutRules.alive(items, exists: CutRules.exists)
            if !split.gone.isEmpty { items = split.alive }
        }
        let show = isRunning
            && !items.isEmpty
            && UserDefaults.standard.bool(forKey: Pref.cutPanel)
            && finderIsFrontmost
        if show {
            panel.show()
        } else {
            panel.hide()
        }
    }
}

// MARK: - Finder через AppleScript

enum FinderScript {
    enum Result<T> {
        case success(T)
        case failure(String)
    }

    private static func run(_ source: String) -> Result<String> {
        guard let script = NSAppleScript(source: source) else { return .failure("Ошибка AppleScript") }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                return .failure("Разрешите Mac Utils управлять Finder: Настройки → Конфиденциальность → Автоматизация")
            }
            return .failure(error[NSAppleScript.errorMessage] as? String ?? "Finder не ответил")
        }
        return .success(output.stringValue ?? "")
    }

    static func selection() -> Result<[URL]> {
        let source = """
        tell application "Finder"
            set out to ""
            repeat with anItem in (get selection)
                set out to out & POSIX path of (anItem as alias) & linefeed
            end repeat
            return out
        end tell
        """
        switch run(source) {
        case .failure(let message): return .failure(message)
        case .success(let text):
            let urls = text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            return .success(urls)
        }
    }

    static func insertionFolder() -> Result<URL> {
        let source = """
        tell application "Finder" to return POSIX path of (insertion location as alias)
        """
        switch run(source) {
        case .failure(let message): return .failure(message)
        case .success(let path):
            guard !path.isEmpty else { return .failure("Не удалось определить папку") }
            return .success(URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}

// MARK: - Перемещение файлов

struct MoveOutcome {
    var moved = 0
    var failed: [URL] = []
    var error: String?
}

enum FileMover {
    static func move(_ urls: [URL], into folder: URL) -> MoveOutcome {
        let fm = FileManager()
        var outcome = MoveOutcome()
        // Папка назначения со снятыми ссылками и «.»/«..»: «та же папка» и «внутри себя» определяются по настоящему пути.
        let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        for source in urls {
            let src = source.standardizedFileURL
            // Родитель — по настоящему пути, а сам объект не трогаем: перемещается ссылка, а не её цель.
            let parentPath = src.deletingLastPathComponent().resolvingSymlinksInPath().path
            let realPath = (parentPath as NSString).appendingPathComponent(src.lastPathComponent)
            // Уже в этой папке — ничего не делаем.
            if parentPath == folderPath || sameDirectory(src.deletingLastPathComponent(), folder) {
                outcome.moved += 1
                continue
            }
            // Нельзя переместить папку внутрь самой себя.
            if (folderPath + "/").hasPrefix(realPath + "/") {
                outcome.failed.append(source)
                outcome.error = "Нельзя переместить папку в саму себя."
                continue
            }
            let destination = uniqueDestination(for: src, in: folder, fm: fm)
            do {
                try fm.moveItem(at: src, to: destination)
                outcome.moved += 1
            } catch {
                outcome.failed.append(source)
                outcome.error = error.localizedDescription
            }
        }
        return outcome
    }

    /// Один и тот же каталог по идентификатору файловой системы: ловит регистр (`~/downloads` и `~/Downloads` на обычном
    /// томе macOS) и firmlink'и, которые сравнение строк не видит.
    private static func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        guard let first = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let second = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return first.isEqual(second)
    }

    /// «Файл.txt» → «Файл 2.txt», «Папка v1.2» → «Папка v1.2 2», «Программа.app» → «Программа 2.app».
    /// Расширением считается только у файлов и пакетов (.app, .bundle): у обычной папки точка в имени — часть имени.
    private static func uniqueDestination(for source: URL, in folder: URL, fm: FileManager) -> URL {
        let name = source.lastPathComponent
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) || isLink(candidate) else { return candidate }
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        let plainFolder = values?.isSymbolicLink != true && values?.isDirectory == true && values?.isPackage != true
        let ext = plainFolder ? "" : (name as NSString).pathExtension
        let base = plainFolder ? name : (name as NSString).deletingPathExtension
        var index = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            index += 1
        } while fm.fileExists(atPath: candidate.path) || isLink(candidate)
        return candidate
    }

    /// Существующая, в том числе «висячая», ссылка: `fileExists` по ней говорит «нет», а имя занято.
    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
