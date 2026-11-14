import CoreGraphics
import Foundation

/// Настройки движка: какие программы прятать, как передавать мышь, размер скрытого дисплея.
public struct HiddenScreenOptions: Equatable, Sendable {
    public var apps: [HiddenApp]
    public var clickMode: ClickMode
    public var scrollMode: ScrollMode
    public var keyMode: KeyMode = .active
    public var pressMode: PressMode = .tap
    /// Дисплей держит процесс-помощник (переживает падение Mac Utils). `--hs-helper=off` — в процессе Mac Utils.
    public var useHelper = true
    /// Как Mac Utils возвращает себе активность (`--hs-activate=auto|public|skylight`).
    public var activationMode: ActivationMode = .auto
    /// Наведение над зеркалом передаётся в окно программы (`--hs-hover=off` — нет).
    public var hover = true
    /// Пометки «временное» во временном буфере вставки (`--hs-clip-marks=off` — без них).
    public var clipboardMarks = true
    /// Размер скрытого дисплея в точках (HiDPI ×2).
    public var displaySize: CGSize

    public static let defaultApps: [HiddenApp] = [.claude, .chatGPT]
    public static let defaultDisplaySize = CGSize(width: 1440, height: 900)

    public init(apps: [HiddenApp] = HiddenScreenOptions.defaultApps, clickMode: ClickMode = .warp,
                scrollMode: ScrollMode = .handoff, displaySize: CGSize = HiddenScreenOptions.defaultDisplaySize) {
        self.apps = apps
        self.clickMode = clickMode
        self.scrollMode = scrollMode
        self.displaySize = displaySize
    }

    /// Программы из сохранённого списка bundle id (`Pref.hiddenScreenApps`); нет списка — Claude и ChatGPT.
    /// Известные идентификаторы собираются в одну программу (у ChatGPT их два), остальные — по одному, имя = id,
    /// пока интерфейс не подставит имя из `NSWorkspace`.
    public static func apps(fromBundleIDs stored: [String]?) -> [HiddenApp] {
        guard let stored else { return defaultApps }
        var result: [HiddenApp] = []
        for id in stored where !id.isEmpty {
            if result.contains(where: { $0.matches(bundleID: id) }) { continue }
            result.append(defaultApps.first { $0.matches(bundleID: id) } ?? HiddenApp(name: id, bundleIDs: [id]))
        }
        return result
    }

    /// Ключ отладочного запуска: `open -a "Mac Utils" --args --hidden-screen-debug [--hs-apps=id,id] [--hs-click=warp|pid]
    /// [--hs-scroll=handoff|pid] [--hs-keys=active|hid|inactive] [--hs-press=tap|mirror] [--hs-helper=on|off] [--hs-clip-marks=on|off] [--hs-hover=on|off] [--hs-activate=auto|public|skylight] [--hs-ax-dump] [--hs-size=1440x900]`.
    /// Без ключа — nil (обычный запуск). Ссылкой `macutils://` не включается.
    public static let debugFlag = "--hidden-screen-debug"

    public static func debug(arguments: [String], storedBundleIDs: [String]?) -> HiddenScreenOptions? {
        guard arguments.contains(debugFlag) else { return nil }
        var options = HiddenScreenOptions(apps: apps(fromBundleIDs: storedBundleIDs))
        for argument in arguments {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "--hs-apps":
                options.apps = apps(fromBundleIDs: parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            case "--hs-click":
                if let mode = ClickMode(rawValue: parts[1]) { options.clickMode = mode }
            case "--hs-scroll":
                if let mode = ScrollMode(rawValue: parts[1]) { options.scrollMode = mode }
            case "--hs-keys":
                if let mode = KeyMode(rawValue: parts[1]) { options.keyMode = mode }
            case "--hs-press":
                if let mode = PressMode(rawValue: parts[1]) { options.pressMode = mode }
            case "--hs-activate":
                if let mode = ActivationMode(rawValue: parts[1]) { options.activationMode = mode }
            case "--hs-hover":
                options.hover = parts[1] != "off"
            case "--hs-clip-marks":
                options.clipboardMarks = parts[1] != "off"
            case "--hs-helper":
                if parts[1] == "off" { options.useHelper = false } else if parts[1] == "on" { options.useHelper = true }
            case "--hs-size":
                let numbers = parts[1].lowercased().split(separator: "x").compactMap { Double($0) }
                if numbers.count == 2, (640...3840).contains(numbers[0]), (480...2400).contains(numbers[1]) {
                    options.displaySize = CGSize(width: numbers[0], height: numbers[1])
                }
            default:
                continue
            }
        }
        return options
    }
}

/// Наружу из чата: «Скопировать» в меню программы → буфер → своё перетаскивание из зеркала (с ⌥).
public enum ClipboardExport: Equatable, Sendable {
    case files([URL])
    /// Картинка без файла: перед перетаскиванием пишется во временный PNG (Finder и почта ждут файл).
    case image(type: String)
    case text(String)
    case nothing

    public static func route(fileURLs: [URL], types: [String], text: String?) -> ClipboardExport {
        let files = fileURLs.filter(\.isFileURL)
        if !files.isEmpty { return .files(files) }
        if let type = DropBridge.imageTypes.first(where: types.contains) { return .image(type: type) }
        if let text, !text.isEmpty { return .text(text) }
        return .nothing
    }

    /// Имя временного файла картинки: «Изображение 2026-11-13 в 19.31.55.png».
    public static func imageFileName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return "Изображение \(formatter.string(from: date)).png"
    }
}
