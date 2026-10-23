import AppKit
import MUCore
import MUDesign
import MUFocus
import MUWellbeing
import MUMeetings
import MUQR

/// Где прилипает окно (действие «Команд», ссылка `macutils://snap?…`, сочетания ⌃⌥ + стрелки).
enum WindowPlacement: String, CaseIterable, Sendable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight, maximize, center, restore

    var title: String {
        switch self {
        case .left: return "Левая половина"
        case .right: return "Правая половина"
        case .top: return "Верхняя половина"
        case .bottom: return "Нижняя половина"
        case .topLeft: return "Левая верхняя четверть"
        case .topRight: return "Правая верхняя четверть"
        case .bottomLeft: return "Левая нижняя четверть"
        case .bottomRight: return "Правая нижняя четверть"
        case .maximize: return "Во весь экран"
        case .center: return "По центру"
        case .restore: return "Вернуть размер"
        }
    }

    var tilerAction: WindowTiler.Action {
        switch self {
        case .left: return .snap(.left)
        case .right: return .snap(.right)
        case .top: return .snap(.top)
        case .bottom: return .snap(.bottom)
        case .topLeft: return .snap(.topLeft)
        case .topRight: return .snap(.topRight)
        case .bottomLeft: return .snap(.bottomLeft)
        case .bottomRight: return .snap(.bottomRight)
        case .maximize: return .snap(.maximize)
        case .center: return .snap(.center)
        case .restore: return .restore
        }
    }
}

/// «Не засыпать»: включить на срок, выключить или переключить.
enum KeepAwakeChoice: String, CaseIterable, Sendable {
    case on, hour1 = "1h", hours3 = "3h", hours8 = "8h", off, toggle

    var title: String {
        switch self {
        case .on: return "Включить, пока не выключу"
        case .hour1: return "Включить на 1 час"
        case .hours3: return "Включить на 3 часа"
        case .hours8: return "Включить на 8 часов"
        case .off: return "Выключить"
        case .toggle: return "Переключить"
        }
    }
}

/// Запись встречи: начать, остановить или переключить (как ⌃⌥M).
enum MeetingCommand: String, CaseIterable, Sendable {
    case start, stop, toggle
}

/// Действие Mac Utils. Горячая клавиша, пункт панели, ссылка `macutils://…` и действие «Команд» зовут одно и то же —
/// `run()`, а оно ту же функцию, что была у горячей клавиши. Ссылки, которые меняют файлы, сначала спрашивают:
/// `macutils://` может открыть любая программа или страница.
enum AppAction: Equatable {
    case settings, tools
    case editor(path: String?)
    case screenshot, recognizeText, screenshotsFolder, qr, qrScreen, annotate
    case snap(WindowPlacement)
    case pinWindow, focus, shelf, appVolume, layoutFix, fixText
    case meeting(MeetingCommand)
    case breakNow, warmPreview, warmToggle
    case keepAwake(KeepAwakeChoice)
    case sortDownloads, openDownloads
    case shareStart(screen: Bool), shareStop, shareToggle(screen: Bool)
    case watch(code: String)
    case viewerMonitor(Int)
    case player, playerOpen(path: String), playerTogglePlay, playerContinue
    case remoteConnections
    case dollarsRemove(path: String, skipFirst: Int?)
    case dollarsFind(path: String)
    case convertEncoding(path: String, TextEncoding, from: TextEncoding?)
    case convertLineEndings(path: String, LineEnding)

    /// Тесты подменяют исполнение: действие записывается, а не выполняется (окна, захват экрана, файлы не трогаются).
    @MainActor static var interceptor: ((AppAction) -> Void)?

    /// То же, что горячая клавиша `hotKey`.
    init(hotKey: HotKeyAction) {
        switch hotKey {
        case .settings: self = .settings
        case .tools: self = .tools
        case .screenshot: self = .screenshot
        case .screenshotOCR: self = .recognizeText
        case .dropShelf: self = .shelf
        case .annotate: self = .annotate
        case .windowPin: self = .pinWindow
        case .fixText: self = .fixText
        case .meeting: self = .meeting(.toggle)
        case .focus: self = .focus
        case .qr: self = .qr
        case .appVolume: self = .appVolume
        case .layoutFix: self = .layoutFix
        case .textEditor: self = .editor(path: nil)
        case .videoPlayer: self = .player
        case .remoteConnections: self = .remoteConnections
        }
    }

    @MainActor
    func run() {
        if let interceptor = Self.interceptor { return interceptor(self) }
        switch self {
        case .settings: SettingsWindowController.shared.show()
        case .tools: ToolsWindowController.shared.show()
        case .editor(let path):
            if let path, !path.isEmpty {
                EditorWindowController.shared.openFromLink(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            } else {
                EditorWindowController.shared.show()
            }
        case .screenshot: _ = ScreenshotService.shared.start(.edit)
        case .recognizeText: _ = ScreenshotService.shared.start(.ocr)
        case .screenshotsFolder: NSWorkspace.shared.open(Pref.screenshotDirectory)
        case .qr: QRCodeService.shared.run()
        case .qrScreen: QRCodeService.shared.scanScreen()
        case .annotate: ScreenAnnotator.shared.toggle()
        case .snap(let placement): WindowTiler.shared.perform(placement.tilerAction)
        case .pinWindow: WindowPin.shared.toggleFocused()
        case .focus: FocusBlur.shared.toggle()
        case .shelf: DropShelf.shared.toggle()
        case .appVolume: AppVolume.shared.toggleHUD()
        case .layoutFix: LayoutFix.shared.fix()
        case .fixText: TextFixer.shared.fix()
        case .meeting(let command):
            switch command {
            case .start: MeetingRecorder.shared.start()
            case .stop: MeetingRecorder.shared.stop()
            case .toggle: MeetingRecorder.shared.toggle()
            }
        case .breakNow: BreakReminder.shared.show()
        case .warmPreview: WarmScreen.shared.preview()
        case .warmToggle: WarmScreen.shared.toggleManual()
        case .keepAwake(let choice):
            switch choice {
            case .on: KeepAwake.shared.start(.indefinite)
            case .hour1: KeepAwake.shared.start(.hour1)
            case .hours3: KeepAwake.shared.start(.hours3)
            case .hours8: KeepAwake.shared.start(.hours8)
            case .off: KeepAwake.shared.stop()
            case .toggle: KeepAwake.shared.toggle()
            }
        case .sortDownloads:
            let result = DownloadsSorter.shared.run()
            Toast.show(result.moved == 0 ? "В «Загрузках» нечего раскладывать" : "Разложено файлов: \(result.moved)",
                       symbol: "arrow.down.to.line.compact")
        case .openDownloads: NSWorkspace.shared.open(DownloadsSorter.shared.folder)
        case .shareStart(let screen): if !ScreenShare.shared.isLive { ScreenShare.shared.start(screen: screen) }
        case .shareStop: ScreenShare.shared.stop()
        case .shareToggle(let screen): ScreenShare.shared.isLive ? ScreenShare.shared.stop() : ScreenShare.shared.start(screen: screen)
        case .watch(let code): ShareViewer.shared.watch(code: code)
        case .viewerMonitor(let n): ShareViewer.shared.requestDisplay(n)
        case .player: PlayerWindowController.show()
        case .remoteConnections: RemotePaletteController.shared.toggle()
        case .playerOpen(let path): PlayerWindowController.open([Self.fileURL(path)])
        case .playerTogglePlay:
            if let controller = PlayerWindowController.current { controller.model.togglePlay() } else { PlayerWindowController.show() }
        case .playerContinue:
            // «Продолжить просмотр»: последний недосмотренный файл, который ещё на месте; нет такого — пустое окно со списком.
            let finished = PlayerRecent.finished
            if let url = PlayerRecent.urls.first(where: { !finished.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }) {
                PlayerWindowController.open([url])
            } else {
                PlayerWindowController.show()
            }
        case .dollarsFind(let path):
            // Список знаков — в панели «Знаки $» редактора (ссылка сначала спрашивает, открывать ли файл).
            EditorWindowController.shared.openFromLink(Self.fileURL(path))
        case .dollarsRemove(let path, let skip):
            let url = Self.fileURL(path)
            let what = skip.map { "Убрать значения $ (первые \($0) не трогать)" } ?? "Убрать все значения $"
            guard Self.confirm(what, url) else { return }
            Self.report { "Убрано значений: \(try FileTools.removeDollarValues(in: url, skipFirst: skip))" }
        case .convertEncoding(let path, let encoding, let source):
            let url = Self.fileURL(path)
            guard Self.confirm("Перевести в \(encoding.title)", url) else { return }
            Self.report {
                try FileTools.convertEncoding(of: url, to: encoding, from: source) ? "Кодировка: \(encoding.title)" : "Файл уже в \(encoding.title)"
            }
        case .convertLineEndings(let path, let ending):
            let url = Self.fileURL(path)
            guard Self.confirm("Перевести строки в \(ending.title)", url) else { return }
            Self.report { try FileTools.convertLineEndings(of: url, to: ending) ? "Переводы строк: \(ending.title)" : "Переводы строк уже \(ending.title)" }
        }
    }

    static func fileURL(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    /// Ссылку может открыть любая страница: прежде чем менять файл — показать, что и где, и спросить.
    @MainActor
    private static func confirm(_ what: String, _ url: URL) -> Bool {
        guard ScreenOutput.mayShow("Вопрос ссылки") else { return false }
        let alert = NSAlert()
        alert.messageText = "\(what)?"
        alert.informativeText = "Ссылка macutils:// просит изменить файл:\n\(url.path)"
        alert.addButton(withTitle: "Изменить")
        alert.addButton(withTitle: "Отмена")
        ScreenOutput.activateApp()
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func report(_ work: () throws -> String) {
        do { Toast.show(try work(), symbol: "checkmark.circle.fill") }
        catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange) }
    }
}

// MARK: - Ссылки macutils://

extension AppAction {
    /// Действие по ссылке `macutils://<действие>?<параметр>`. Прежние ссылки (`share`, `meeting`, `keep-awake`, `focus`…)
    /// делают то же, что раньше. nil — служебная или незнакомая ссылка.
    init?(url: URL) {
        guard url.scheme == "macutils", let host = url.host else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let query = url.query?.removingPercentEncoding ?? ""
        switch host {
        case "settings": self = .settings
        case "tools": self = .tools
        case "editor": self = .editor(path: value("path"))
        case "screenshot": self = .screenshot
        case "ocr": self = .recognizeText
        case "screenshots-folder": self = .screenshotsFolder
        case "qr": self = .qr
        case "qr-screen": self = .qrScreen
        case "annotate": self = .annotate
        case "snap":
            guard let placement = WindowPlacement(rawValue: query) else { return nil }
            self = .snap(placement)
        case "pin": self = .pinWindow
        case "focus": self = .focus
        case "shelf": self = .shelf
        case "app-volume": self = .appVolume
        case "layout-fix": self = .layoutFix
        case "fix-text": self = .fixText
        case "meeting": self = .meeting(.toggle)
        case "meeting-start": self = .meeting(.start)
        case "meeting-stop": self = .meeting(.stop)
        case "break": self = .breakNow
        case "warm": self = .warmPreview
        case "warm-toggle": self = .warmToggle
        case "keep-awake":
            guard let choice = query.isEmpty ? .toggle : KeepAwakeChoice(rawValue: query) else { return nil }
            self = .keepAwake(choice)
        case "player": self = .player
        case "player-open":
            guard let path = value("path"), !path.isEmpty else { return nil }
            self = .playerOpen(path: path)
        case "player-pause": self = .playerTogglePlay
        case "player-continue": self = .playerContinue
        case "downloads-sort": self = .sortDownloads
        case "downloads-open": self = .openDownloads
        case "share": self = .shareToggle(screen: query == "screen")
        case "share-start": self = .shareStart(screen: query == "screen")
        case "share-stop": self = .shareStop
        case "watch":
            guard !query.isEmpty else { return nil }
            self = .watch(code: query)
        case "viewer-monitor":
            guard let n = Int(query), (1...9).contains(n) else { return nil }
            self = .viewerMonitor(n)
        case "dollars-find":
            guard let path = value("path"), !path.isEmpty else { return nil }
            self = .dollarsFind(path: path)
        case "dollars-remove":
            guard let path = value("path"), !path.isEmpty else { return nil }
            let skip = value("skip")
            if skip == "off" { self = .dollarsRemove(path: path, skipFirst: nil); return }
            self = .dollarsRemove(path: path, skipFirst: skip.flatMap(Int.init).map(DollarSkip.clamp) ?? DollarSkip.current)
        case "encoding":
            guard let path = value("path"), !path.isEmpty, let to = value("to").flatMap(TextEncoding.init(rawValue:)) else { return nil }
            let from = value("from")
            if let from, TextEncoding(rawValue: from) == nil { return nil }
            self = .convertEncoding(path: path, to, from: from.flatMap(TextEncoding.init(rawValue:)))
        case "line-endings":
            guard let path = value("path"), !path.isEmpty, let to = value("to").flatMap(LineEnding.init(rawValue:)) else { return nil }
            self = .convertLineEndings(path: path, to)
        default: return nil
        }
    }
}

// MARK: - Список для страницы «Команды и ссылки»

/// Строка списка: что делает, ссылка и действие «Команд» с тем же смыслом.
struct AppActionInfo: Identifiable {
    let group: String
    let title: String
    let link: String
    let shortcut: String
    var id: String { link }
}

extension AppAction {
    static let catalog: [AppActionInfo] = [
        AppActionInfo(group: "Общее", title: "Настройки", link: "macutils://settings", shortcut: "Открыть настройки"),
        AppActionInfo(group: "Общее", title: "Инструменты", link: "macutils://tools", shortcut: "Открыть инструменты"),
        AppActionInfo(group: "Окна", title: "Окно к краю или в четверть", link: "macutils://snap?left", shortcut: "Разместить окно"),
        AppActionInfo(group: "Окна", title: "Вернуть размер окна", link: "macutils://snap?restore", shortcut: "Разместить окно"),
        AppActionInfo(group: "Окна", title: "Окно поверх всех", link: "macutils://pin", shortcut: "Окно поверх всех"),
        AppActionInfo(group: "Окна", title: "Фокус: размыть фон", link: "macutils://focus", shortcut: "Фокус"),
        AppActionInfo(group: "Снимки", title: "Снимок области или окна", link: "macutils://screenshot", shortcut: "Снимок экрана"),
        AppActionInfo(group: "Снимки", title: "Распознать текст", link: "macutils://ocr", shortcut: "Распознать текст на экране"),
        AppActionInfo(group: "Снимки", title: "Папка снимков", link: "macutils://screenshots-folder", shortcut: "Открыть папку снимков"),
        AppActionInfo(group: "Снимки", title: "QR: выделенный текст или экран", link: "macutils://qr", shortcut: "Мгновенный QR"),
        AppActionInfo(group: "Снимки", title: "Прочитать QR с экрана", link: "macutils://qr-screen", shortcut: "Прочитать QR с экрана"),
        AppActionInfo(group: "Снимки", title: "Рисовать на экране", link: "macutils://annotate", shortcut: "Рисовать на экране"),
        AppActionInfo(group: "Трансляция", title: "Начать трансляцию (экран под курсором)", link: "macutils://share-start?screen", shortcut: "Начать трансляцию"),
        AppActionInfo(group: "Трансляция", title: "Начать трансляцию с выбором", link: "macutils://share-start", shortcut: "Начать трансляцию"),
        AppActionInfo(group: "Трансляция", title: "Остановить трансляцию", link: "macutils://share-stop", shortcut: "Остановить трансляцию"),
        AppActionInfo(group: "Трансляция", title: "Смотреть по ID", link: "macutils://watch?1234567890", shortcut: "Смотреть трансляцию"),
        AppActionInfo(group: "Трансляция", title: "Попросить ведущего показать монитор", link: "macutils://viewer-monitor?2", shortcut: "Показать монитор ведущего"),
        AppActionInfo(group: "Текстовый редактор", title: "Открыть редактор", link: "macutils://editor", shortcut: "Открыть редактор"),
        AppActionInfo(group: "Текстовый редактор", title: "Открыть файл", link: "macutils://editor?path=~/Documents/a.frm", shortcut: "Открыть редактор"),
        AppActionInfo(group: "Текстовый редактор", title: "Убрать значения $ в файле", link: "macutils://dollars-remove?path=~/Documents/a.frm&skip=3", shortcut: "Убрать значения $ в файле"),
        AppActionInfo(group: "Текстовый редактор", title: "Знаки $ файла (в редакторе)", link: "macutils://dollars-find?path=~/Documents/a.frm", shortcut: "Найти значения $ в файле"),
        AppActionInfo(group: "Текстовый редактор", title: "Сменить кодировку файла", link: "macutils://encoding?path=~/Documents/a.txt&to=utf8", shortcut: "Сменить кодировку файла"),
        AppActionInfo(group: "Текстовый редактор", title: "Переводы строк файла", link: "macutils://line-endings?path=~/Documents/a.txt&to=lf", shortcut: "Переводы строк файла"),
        AppActionInfo(group: "Видеоплеер", title: "Открыть плеер", link: "macutils://player", shortcut: "Открыть видеоплеер"),
        AppActionInfo(group: "Видеоплеер", title: "Открыть видео или папку", link: "macutils://player-open?path=~/Movies/film.mp4", shortcut: "Открыть видеоплеер"),
        AppActionInfo(group: "Видеоплеер", title: "Пауза или продолжить", link: "macutils://player-pause", shortcut: "Пауза в плеере"),
        AppActionInfo(group: "Видеоплеер", title: "Продолжить просмотр", link: "macutils://player-continue", shortcut: "Продолжить просмотр"),
        AppActionInfo(group: "Встречи", title: "Запись встречи: начать или остановить", link: "macutils://meeting", shortcut: "Запись встречи"),
        AppActionInfo(group: "Встречи", title: "Начать запись встречи", link: "macutils://meeting-start", shortcut: "Запись встречи"),
        AppActionInfo(group: "Встречи", title: "Остановить запись встречи", link: "macutils://meeting-stop", shortcut: "Запись встречи"),
        AppActionInfo(group: "Текст", title: "Исправить выделенный текст (ИИ)", link: "macutils://fix-text", shortcut: "Исправить текст"),
        AppActionInfo(group: "Текст", title: "Исправить раскладку", link: "macutils://layout-fix", shortcut: "Исправить раскладку"),
        AppActionInfo(group: "Здоровье", title: "Перерыв сейчас", link: "macutils://break", shortcut: "Перерыв"),
        AppActionInfo(group: "Здоровье", title: "Тёплый экран: показать", link: "macutils://warm", shortcut: "Тёплый экран"),
        AppActionInfo(group: "Здоровье", title: "Тёплый экран: включить или выключить", link: "macutils://warm-toggle", shortcut: "Тёплый экран"),
        AppActionInfo(group: "Здоровье", title: "«Не засыпать»: переключить", link: "macutils://keep-awake", shortcut: "Не засыпать"),
        AppActionInfo(group: "Здоровье", title: "«Не засыпать» на час", link: "macutils://keep-awake?1h", shortcut: "Не засыпать"),
        AppActionInfo(group: "Здоровье", title: "«Не засыпать»: выключить", link: "macutils://keep-awake?off", shortcut: "Не засыпать"),
        AppActionInfo(group: "Прочее", title: "Полка файлов", link: "macutils://shelf", shortcut: "Полка"),
        AppActionInfo(group: "Прочее", title: "Громкость приложений", link: "macutils://app-volume", shortcut: "Громкость приложений"),
        AppActionInfo(group: "Прочее", title: "Разложить «Загрузки»", link: "macutils://downloads-sort", shortcut: "Разложить «Загрузки»"),
        AppActionInfo(group: "Прочее", title: "Открыть «Загрузки»", link: "macutils://downloads-open", shortcut: "Открыть «Загрузки»"),
    ]
}
