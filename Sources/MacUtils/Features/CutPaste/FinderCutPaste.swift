import AppKit
import ApplicationServices

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
            guard !items.isEmpty else { return true }
            // Пользователь скопировал что-то после ⌘X — обычная вставка.
            if NSPasteboard.general.changeCount != cutChangeCount {
                cancelCut()
                return true
            }
            if isEditingText() { return true }
            if !isRepeat { paste() }
            return false
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
                NSSound.beep()
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
        let folderPath = folder.standardizedFileURL.path
        for source in urls {
            let src = source.standardizedFileURL
            // Уже в этой папке — ничего не делаем.
            if src.deletingLastPathComponent().path == folderPath {
                outcome.moved += 1
                continue
            }
            // Нельзя переместить папку внутрь самой себя.
            if (folderPath + "/").hasPrefix(src.path + "/") {
                outcome.failed.append(source)
                outcome.error = "Нельзя переместить папку в саму себя."
                continue
            }
            let destination = uniqueDestination(for: src.lastPathComponent, in: folder, fm: fm)
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

    /// «Файл.txt» → «Файл 2.txt», если имя занято.
    private static func uniqueDestination(for name: String, in folder: URL, fm: FileManager) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var index = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            index += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
