import AppIntents
import Foundation
import MUCore
import MUAI
import MUDownloadsSorter
import MUScreenShare
import MUScreenshot

// Действия Mac Utils в приложении «Команды» (App Intents). Каждое зовёт `AppAction.run()` — ту же функцию, что горячая
// клавиша, панель и ссылка `macutils://…`; действия с файлами — `FileTools`, без окна редактора.
// Метаданные (`Metadata.appintents`) собирает build.sh: scripts/appintents-metadata.sh.

/// Ошибка действия с понятным текстом в «Командах».
struct ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
private func run(_ action: AppAction) -> some IntentResult {
    action.run()
    return .result()
}

/// Файл из «Команд» — путь на диске (Mac Utils не в песочнице и пишет файл на месте).
private func path(of file: IntentFile) throws -> URL {
    guard let url = file.fileURL else { throw ShortcutError(message: "Нужен файл на диске, а не содержимое") }
    return url
}

// MARK: - Перечисления параметров

extension WindowPlacement: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Место окна"
    static let caseDisplayRepresentations: [WindowPlacement: DisplayRepresentation] = [
        .left: "Левая половина", .right: "Правая половина", .top: "Верхняя половина", .bottom: "Нижняя половина",
        .topLeft: "Левая верхняя четверть", .topRight: "Правая верхняя четверть",
        .bottomLeft: "Левая нижняя четверть", .bottomRight: "Правая нижняя четверть",
        .maximize: "Во весь экран", .center: "По центру", .restore: "Вернуть размер",
    ]
}

extension KeepAwakeChoice: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Не засыпать"
    static let caseDisplayRepresentations: [KeepAwakeChoice: DisplayRepresentation] = [
        .on: "Включить, пока не выключу", .hour1: "Включить на 1 час", .hours3: "Включить на 3 часа",
        .hours8: "Включить на 8 часов", .off: "Выключить", .toggle: "Переключить",
    ]
}

extension MeetingCommand: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Запись встречи"
    static let caseDisplayRepresentations: [MeetingCommand: DisplayRepresentation] = [
        .start: "Начать", .stop: "Остановить", .toggle: "Начать или остановить",
    ]
}

enum ShareSource: String, AppEnum {
    case screen, choose

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Что показывать"
    static let caseDisplayRepresentations: [ShareSource: DisplayRepresentation] = [
        .screen: "Экран под курсором", .choose: "Выбрать экран, окно или программу",
    ]
}

enum WarmScreenCommand: String, AppEnum {
    case preview, toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Тёплый экран"
    static let caseDisplayRepresentations: [WarmScreenCommand: DisplayRepresentation] = [
        .preview: "Показать на пару секунд", .toggle: "Включить или выключить",
    ]
}

/// Кодировка и перевод строки для Команд: `AppEnum` обязан жить в исполняемом модуле, сами типы — в `MUCore`.
enum TextEncodingChoice: String, AppEnum {
    case utf8, utf8BOM, utf16LE, utf16BE
    case windows1251, windows1252, windows1250
    case koi8R, koi8U
    case iso8859_1, iso8859_2, iso8859_5
    case macRoman, cp866

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Кодировка"
    static let caseDisplayRepresentations: [TextEncodingChoice: DisplayRepresentation] = [
        .utf8: "UTF-8", .utf8BOM: "UTF-8 с BOM", .utf16LE: "UTF-16 LE", .utf16BE: "UTF-16 BE",
        .windows1251: "Windows-1251 (кириллица)", .windows1252: "Windows-1252 (Западная Европа)",
        .windows1250: "Windows-1250 (Центральная Европа)", .koi8R: "KOI8-R", .koi8U: "KOI8-U",
        .iso8859_1: "ISO 8859-1", .iso8859_2: "ISO 8859-2", .iso8859_5: "ISO 8859-5",
        .macRoman: "Mac Roman", .cp866: "CP866 (DOS)",
    ]

    var encoding: TextEncoding { TextEncoding(rawValue: rawValue) ?? .utf8 }
}

enum LineEndingChoice: String, AppEnum {
    case crlf, lf, cr

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Перевод строки"
    static let caseDisplayRepresentations: [LineEndingChoice: DisplayRepresentation] = [
        .crlf: "CRLF (Windows)", .lf: "LF (macOS и Linux)", .cr: "CR (старый Mac OS)",
    ]

    var ending: LineEnding { LineEnding(rawValue: rawValue) ?? .lf }
}

// MARK: - Общее

struct OpenSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть настройки"
    static let description = IntentDescription("Окно настроек Mac Utils.")
    @MainActor func perform() async throws -> some IntentResult { run(.settings) }
}

struct OpenToolsIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть инструменты"
    static let description = IntentDescription("Панель «Инструменты» Mac Utils (⌃⌥⌘T).")
    @MainActor func perform() async throws -> some IntentResult { run(.tools) }
}

// MARK: - Окна

struct SnapWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Разместить окно"
    static let description = IntentDescription("Активное окно к краю, в четверть, во весь экран или по центру — как ⌃⌥ + стрелки. «Вернуть размер» — прежняя рамка.")
    @Parameter(title: "Куда", default: .left) var placement: WindowPlacement
    static var parameterSummary: some ParameterSummary { Summary("Разместить окно: \(\.$placement)") }
    @MainActor func perform() async throws -> some IntentResult { run(.snap(placement)) }
}

struct PinWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Окно поверх всех"
    static let description = IntentDescription("Закрепить активное окно поверх остальных или открепить (⌃⌥P).")
    @MainActor func perform() async throws -> some IntentResult { run(.pinWindow) }
}

struct FocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Фокус"
    static let description = IntentDescription("Размыть всё позади активной программы или выключить (⌃⌥F).")
    @MainActor func perform() async throws -> some IntentResult { run(.focus) }
}

// MARK: - Снимки

struct ScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Снимок экрана"
    static let description = IntentDescription("Выделить область или окно (⇧⌘X); в окне выделения — запись экрана и длинный скриншот.")
    @MainActor func perform() async throws -> some IntentResult { run(.screenshot) }
}

struct RecognizeTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Распознать текст на экране"
    static let description = IntentDescription("Выделить область — текст сразу в буфер (⌥⇧⌘X).")
    @MainActor func perform() async throws -> some IntentResult { run(.recognizeText) }
}

struct OpenScreenshotsFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть папку снимков"
    static let description = IntentDescription("Папка «Мои снимки» в Finder.")
    @MainActor func perform() async throws -> some IntentResult { run(.screenshotsFolder) }
}

struct QRIntent: AppIntent {
    static let title: LocalizedStringResource = "Мгновенный QR"
    static let description = IntentDescription("QR из выделенного текста, а без выделения — прочитать QR с экрана (⌃⌥Q).")
    @MainActor func perform() async throws -> some IntentResult { run(.qr) }
}

struct ReadQRFromScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Прочитать QR с экрана"
    static let description = IntentDescription("Найти QR-код на экране и прочитать его.")
    @MainActor func perform() async throws -> some IntentResult { run(.qrScreen) }
}

struct AnnotateIntent: AppIntent {
    static let title: LocalizedStringResource = "Рисовать на экране"
    static let description = IntentDescription("Включить или выключить рисование поверх экрана (⌃⌥A).")
    @MainActor func perform() async throws -> some IntentResult { run(.annotate) }
}

// MARK: - Трансляция

struct StartShareIntent: AppIntent {
    static let title: LocalizedStringResource = "Начать трансляцию"
    static let description = IntentDescription("Транслировать экран по своему ID. Каждого зрителя вы сначала разрешаете.")
    @Parameter(title: "Что показывать", default: .screen) var source: ShareSource
    static var parameterSummary: some ParameterSummary { Summary("Начать трансляцию: \(\.$source)") }
    @MainActor func perform() async throws -> some IntentResult { run(.shareStart(screen: source == .screen)) }
}

struct StopShareIntent: AppIntent {
    static let title: LocalizedStringResource = "Остановить трансляцию"
    static let description = IntentDescription("Закончить эфир сразу.")
    @MainActor func perform() async throws -> some IntentResult { run(.shareStop) }
}

struct WatchShareIntent: AppIntent {
    static let title: LocalizedStringResource = "Смотреть трансляцию"
    static let description = IntentDescription("Подключиться к трансляции по ID собеседника (10 цифр).")
    @Parameter(title: "ID") var code: String
    static var parameterSummary: some ParameterSummary { Summary("Смотреть трансляцию \(\.$code)") }
    @MainActor func perform() async throws -> some IntentResult {
        guard ShareCode.normalized(code) != nil else { throw ShortcutError(message: "ID — 10 цифр") }
        return run(.watch(code: code))
    }
}

struct ViewerMonitorIntent: AppIntent {
    static let title: LocalizedStringResource = "Показать монитор ведущего"
    static let description = IntentDescription("Во время просмотра попросить ведущего показать монитор с этим номером (если он разрешил).")
    @Parameter(title: "Номер монитора", default: 1, inclusiveRange: (1, 9)) var number: Int
    static var parameterSummary: some ParameterSummary { Summary("Показать монитор \(\.$number) ведущего") }
    @MainActor func perform() async throws -> some IntentResult { run(.viewerMonitor(number)) }
}

// MARK: - Текстовый редактор

struct OpenEditorIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть редактор"
    static let description = IntentDescription("Текстовый редактор Mac Utils; если указан файл — открыть его вкладкой.")
    @Parameter(title: "Файл") var file: IntentFile?
    static var parameterSummary: some ParameterSummary { Summary("Открыть в редакторе \(\.$file)") }
    @MainActor func perform() async throws -> some IntentResult {
        // Файл из «Команд» пользователь выбрал сам — открываем без вопроса ссылки (`openFromLink`).
        if let file {
            let url = try path(of: file)
            if let interceptor = AppAction.interceptor { interceptor(.editor(path: url.path)) } else { EditorWindowController.shared.open([url]) }
        } else {
            AppAction.editor(path: nil).run()
        }
        return .result()
    }
}

struct RemoveDollarValuesIntent: AppIntent {
    static let title: LocalizedStringResource = "Убрать значения $ в файле"
    static let description = IntentDescription("Как «Убрать значения $» в редакторе, без окна: знаки $ остаются, их значения убираются, остальные байты файла не меняются. Если после удаления нарушится баланс скобок { }, файл не меняется. Возвращает число убранных значений.")
    @Parameter(title: "Файл") var file: IntentFile
    @Parameter(title: "Пропускать первые", default: true) var skip: Bool
    @Parameter(title: "Сколько пропустить", default: 3, inclusiveRange: (0, 999)) var skipCount: Int
    static var parameterSummary: some ParameterSummary {
        When(\.$skip, .equalTo, true) {
            Summary("Убрать значения $ в \(\.$file)") { \.$skip; \.$skipCount }
        } otherwise: {
            Summary("Убрать значения $ в \(\.$file)") { \.$skip }
        }
    }
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let url = try path(of: file)
        do {
            let removed = try FileTools.removeDollarValues(in: url, skipFirst: skip ? DollarSkip.clamp(skipCount) : nil)
            return .result(value: removed, dialog: "Убрано значений: \(removed)")
        } catch {
            throw ShortcutError(message: error.localizedDescription)
        }
    }
}

struct FindDollarValuesIntent: AppIntent {
    static let title: LocalizedStringResource = "Найти значения $ в файле"
    static let description = IntentDescription("Значения знаков $ файла по порядку (как в панели «Знаки $»); пропущенные первые N в список не входят.")
    @Parameter(title: "Файл") var file: IntentFile
    @Parameter(title: "Пропускать первые", default: true) var skip: Bool
    @Parameter(title: "Сколько пропустить", default: 3, inclusiveRange: (0, 999)) var skipCount: Int
    static var parameterSummary: some ParameterSummary {
        When(\.$skip, .equalTo, true) {
            Summary("Найти значения $ в \(\.$file)") { \.$skip; \.$skipCount }
        } otherwise: {
            Summary("Найти значения $ в \(\.$file)") { \.$skip }
        }
    }
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let url = try path(of: file)
        do {
            let values = try FileTools.findDollarValues(in: url, skipFirst: skip ? DollarSkip.clamp(skipCount) : nil)
            return .result(value: values.filter { !$0.skipped }.map(\.value))
        } catch {
            throw ShortcutError(message: error.localizedDescription)
        }
    }
}

struct ConvertEncodingIntent: AppIntent {
    static let title: LocalizedStringResource = "Сменить кодировку файла"
    static let description = IntentDescription("Тот же текст в другой кодировке (как «Преобразовать в…»). Символов, которых нет в новой кодировке, — ошибка, файл не меняется.")
    @Parameter(title: "Файл") var file: IntentFile
    @Parameter(title: "Кодировка", default: .utf8) var encoding: TextEncodingChoice
    @Parameter(title: "Сейчас файл в кодировке", description: "Если автоопределение ошибается (например, Windows-1251 без \\ansicpg читается как Windows-1252). Пусто — определить самому.")
    var source: TextEncodingChoice?
    static var parameterSummary: some ParameterSummary {
        Summary("Перевести \(\.$file) в \(\.$encoding)") { \.$source }
    }
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        do { return .result(value: try FileTools.convertEncoding(of: try path(of: file), to: encoding.encoding, from: source?.encoding)) }
        catch let error as ShortcutError { throw error }
        catch { throw ShortcutError(message: error.localizedDescription) }
    }
}

struct ConvertLineEndingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Переводы строк файла"
    static let description = IntentDescription("Все переводы строк файла одного вида: CRLF, LF или CR.")
    @Parameter(title: "Файл") var file: IntentFile
    @Parameter(title: "Перевод строки", default: .crlf) var ending: LineEndingChoice
    static var parameterSummary: some ParameterSummary { Summary("Переводы строк \(\.$file): \(\.$ending)") }
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        do { return .result(value: try FileTools.convertLineEndings(of: try path(of: file), to: ending.ending)) }
        catch let error as ShortcutError { throw error }
        catch { throw ShortcutError(message: error.localizedDescription) }
    }
}

// MARK: - Видеоплеер

struct OpenPlayerIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть видеоплеер"
    static let description = IntentDescription("Видеоплеер Mac Utils (⌃⌥⌘P); если указан файл или папка — открыть их (папку — плейлистом).")
    @Parameter(title: "Видео или папка") var file: IntentFile?
    static var parameterSummary: some ParameterSummary { Summary("Открыть в плеере \(\.$file)") }
    @MainActor func perform() async throws -> some IntentResult {
        if let file { AppAction.playerOpen(path: try path(of: file).path).run() } else { AppAction.player.run() }
        return .result()
    }
}

struct PlayerTogglePlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Пауза в плеере"
    static let description = IntentDescription("Пауза или продолжить в активном окне видеоплеера.")
    @MainActor func perform() async throws -> some IntentResult { run(.playerTogglePlay) }
}

struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Продолжить просмотр"
    static let description = IntentDescription("Открыть последнее недосмотренное видео с того же места.")
    @MainActor func perform() async throws -> some IntentResult { run(.playerContinue) }
}

// MARK: - Встречи, текст, здоровье, прочее

struct MeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Запись встречи"
    static let description = IntentDescription("Записать звук встречи и расшифровать (⌃⌥M).")
    @Parameter(title: "Действие", default: .toggle) var command: MeetingCommand
    static var parameterSummary: some ParameterSummary { Summary("Запись встречи: \(\.$command)") }
    @MainActor func perform() async throws -> some IntentResult { run(.meeting(command)) }
}

struct FixSelectedTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Исправить выделенный текст"
    static let description = IntentDescription("Исправить ошибки в выделенном тексте любой программы локальной ИИ-моделью (⌃⌥E).")
    @MainActor func perform() async throws -> some IntentResult { run(.fixText) }
}

struct FixTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Исправить текст"
    static let description = IntentDescription("Исправить ошибки в тексте локальной ИИ-моделью (Ollama) и вернуть исправленный текст.")
    @Parameter(title: "Текст") var text: String
    static var parameterSummary: some ParameterSummary { Summary("Исправить \(\.$text)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        do {
            let answer = try await Ollama.generate(text, system: TextFixer.system, temperature: 0)
            return .result(value: AIParsing.keepingEdges(of: text, AIParsing.cleanedText(answer)))
        } catch {
            throw ShortcutError(message: error.localizedDescription)
        }
    }
}

struct LayoutFixIntent: AppIntent {
    static let title: LocalizedStringResource = "Исправить раскладку"
    static let description = IntentDescription("Перепечатать последнее слово или выделение в другой раскладке, как горячая клавиша.")
    @MainActor func perform() async throws -> some IntentResult { run(.layoutFix) }
}

struct BreakIntent: AppIntent {
    static let title: LocalizedStringResource = "Перерыв"
    static let description = IntentDescription("Напоминание о перерыве — сейчас.")
    @MainActor func perform() async throws -> some IntentResult { run(.breakNow) }
}

struct WarmScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Тёплый экран"
    static let description = IntentDescription("Тёплые цвета экрана вечером: показать или включить и выключить.")
    @Parameter(title: "Действие", default: .toggle) var command: WarmScreenCommand
    static var parameterSummary: some ParameterSummary { Summary("Тёплый экран: \(\.$command)") }
    @MainActor func perform() async throws -> some IntentResult { run(command == .preview ? .warmPreview : .warmToggle) }
}

struct KeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Не засыпать"
    static let description = IntentDescription("Mac не уходит в сон (экран при этом гаснет): на срок, пока не выключите, или выключить.")
    @Parameter(title: "Действие", default: .toggle) var choice: KeepAwakeChoice
    static var parameterSummary: some ParameterSummary { Summary("Не засыпать: \(\.$choice)") }
    @MainActor func perform() async throws -> some IntentResult { run(.keepAwake(choice)) }
}

struct ShelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Полка"
    static let description = IntentDescription("Показать или спрятать полку файлов (⌃⌥D).")
    @MainActor func perform() async throws -> some IntentResult { run(.shelf) }
}

struct AppVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Громкость приложений"
    static let description = IntentDescription("Панель громкости по программам.")
    @MainActor func perform() async throws -> some IntentResult { run(.appVolume) }
}

struct SortDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Разложить «Загрузки»"
    static let description = IntentDescription("Разложить новые файлы «Загрузок» по папкам, как кнопка «Разложить сейчас». Возвращает, сколько файлов разложено.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        if let interceptor = AppAction.interceptor {
            interceptor(.sortDownloads)
            return .result(value: 0)
        }
        return .result(value: DownloadsSorter.shared.run().moved)
    }
}

struct OpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть «Загрузки»"
    static let description = IntentDescription("Папка «Загрузки» в Finder.")
    @MainActor func perform() async throws -> some IntentResult { run(.openDownloads) }
}

// MARK: - Фразы для Siri и Spotlight

struct MacUtilsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScreenshotIntent(), phrases: ["Снимок экрана в \(.applicationName)", "Сделай снимок в \(.applicationName)"],
                    shortTitle: "Снимок экрана", systemImageName: "camera.viewfinder")
        AppShortcut(intent: RecognizeTextIntent(), phrases: ["Распознай текст в \(.applicationName)"],
                    shortTitle: "Распознать текст", systemImageName: "text.viewfinder")
        AppShortcut(intent: SnapWindowIntent(), phrases: ["Размести окно в \(.applicationName)", "Окно \(\.$placement) в \(.applicationName)"],
                    shortTitle: "Разместить окно", systemImageName: "rectangle.split.2x1")
        AppShortcut(intent: OpenEditorIntent(), phrases: ["Открой редактор в \(.applicationName)"],
                    shortTitle: "Текстовый редактор", systemImageName: "doc.plaintext")
        AppShortcut(intent: RemoveDollarValuesIntent(), phrases: ["Убери значения доллара в \(.applicationName)"],
                    shortTitle: "Убрать значения $", systemImageName: "dollarsign.circle")
        AppShortcut(intent: StartShareIntent(), phrases: ["Начни трансляцию в \(.applicationName)"],
                    shortTitle: "Начать трансляцию", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: MeetingIntent(), phrases: ["Запись встречи в \(.applicationName)"],
                    shortTitle: "Запись встречи", systemImageName: "waveform.badge.mic")
        AppShortcut(intent: KeepAwakeIntent(), phrases: ["Не засыпать в \(.applicationName)", "\(.applicationName) не засыпать \(\.$choice)"],
                    shortTitle: "Не засыпать", systemImageName: "cup.and.heat.waves")
        AppShortcut(intent: AnnotateIntent(), phrases: ["Рисовать на экране в \(.applicationName)"],
                    shortTitle: "Рисовать на экране", systemImageName: "pencil.tip.crop.circle")
        AppShortcut(intent: OpenToolsIntent(), phrases: ["Инструменты \(.applicationName)", "Открой инструменты в \(.applicationName)"],
                    shortTitle: "Инструменты", systemImageName: "wrench.and.screwdriver")
    }
}
