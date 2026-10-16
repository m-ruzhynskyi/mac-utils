import AppKit
import CoreText
import os
import SwiftUI

/// Дизайн-система «Graphite» (`.audit/design-spec-v2.md` §1): графит, один лаймовый акцент, Manrope и JetBrains Mono.
/// Компоненты из `UI/Components` берут значения только отсюда. Тема — системная (светлая или тёмная).
enum DS {
    // MARK: - Цвета

    /// Токены концепта (`renderVals()` в `.audit/concept/*.dc.html`): у каждого — значение для тёмной и светлой темы.
    enum Palette {
        static let bg = DS.color(dark: 0x0E1013, light: 0xF4F5F2)
        static let side = DS.color(dark: 0x13161A, light: 0xECEEE9)
        static let panel = DS.color(dark: 0x171A1F, light: 0xFFFFFF)
        static let field = DS.color(dark: 0x1F2329, light: 0xEEF0EA)
        static let line = DS.color(dark: 0x2A2F37, light: 0xD9DDD3)
        static let off = DS.color(dark: 0x2F353E, light: 0xC9CEC4)
        static let text = DS.color(dark: 0xEDEFF2, light: 0x14171A)
        static let mute = DS.color(dark: 0x9AA3AF, light: 0x59626E)
        /// Лаймовая заливка акцента (одинакова в обеих темах).
        static let acc = DS.color(dark: 0xC8F05A, light: 0xC8F05A)
        /// Текст и значок на `acc`.
        static let accInk = DS.color(dark: 0x10140A, light: 0x10140A)
        /// Акцент текстом (в светлой теме — тёмно-зелёный, иначе лайм на светлом не читается).
        static let accText = DS.color(dark: 0xC8F05A, light: 0x3D6600)
        /// Точка заголовка группы, рамка выбранного, кольцо фокуса, обводка лаймовых заливок в светлой теме.
        static let accLine = DS.color(dark: 0xC8F05A, light: 0x6E9A00)
        static let blue = DS.color(dark: 0x6EA8FF, light: 0x1F6FDB)
        static let blueInk = DS.color(dark: 0x08111F, light: 0xFFFFFF)
        static let rec = DS.color(dark: 0xFF7A6B, light: 0xD93A2B)
        static let recInk = DS.color(dark: 0x240C08, light: 0xFFFFFF)
        /// Тон «внимание» — в концепте его нет (§1.1 спецификации v2).
        static let warn = DS.color(dark: 0xF5B83D, light: 0x8A5300)
        static let warnInk = DS.color(dark: 0x241800, light: 0xFFFFFF)
    }

    /// Тон статуса: заливка и текст на ней, цвет текста на `panel`, значок.
    enum Tone: CaseIterable {
        case success, warning, danger, info, neutral

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "xmark.octagon.fill"
            case .info: return "info.circle.fill"
            case .neutral: return "circle.dashed"
            }
        }

        var fillColor: NSColor {
            switch self {
            case .success: return Palette.acc
            case .warning: return Palette.warn
            case .danger: return Palette.rec
            case .info: return Palette.blue
            case .neutral: return Palette.field
            }
        }

        var inkColor: NSColor {
            switch self {
            case .success: return Palette.accInk
            case .warning: return Palette.warnInk
            case .danger: return Palette.recInk
            case .info: return Palette.blueInk
            case .neutral: return Palette.mute
            }
        }

        /// Текст тона на `panel` (на `field` цветной текст не ставим: §1.1).
        var textColor: NSColor {
            switch self {
            case .success: return Palette.accText
            case .warning: return Palette.warn
            case .danger: return Palette.rec
            case .info: return Palette.blue
            case .neutral: return Palette.mute
            }
        }

        /// Рамка тона: у баннера и выделенной карточки.
        var lineColor: NSColor { self == .success ? Palette.accLine : textColor }

        var fill: Color { Color(nsColor: fillColor) }
        var ink: Color { Color(nsColor: inkColor) }
        var text: Color { Color(nsColor: textColor) }
        var line: Color { Color(nsColor: lineColor) }

        /// Тон по прежнему цвету `tint` (для старых вызовов Toast и подобных).
        static func from(tint: SwiftUI.Color) -> Tone {
            switch tint {
            case .green: return .success
            case .orange, .yellow: return .warning
            case .red: return .danger
            case .blue, .accentColor: return .info
            default: return .neutral
            }
        }
    }

    // MARK: - Форма

    /// Отступы кратны 4.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        /// Поля страницы настроек.
        static let pageVertical: CGFloat = 30
        static let pageHorizontal: CGFloat = 36
        /// Промежуток между блоками страницы.
        static let section: CGFloat = 18
    }

    enum Radius {
        static let keycap: CGFloat = 7
        /// Кнопка, плитка строки, строка навигации.
        static let control: CGFloat = 10
        /// Кнопка-иконка 40, сегмент.
        static let iconButton: CGFloat = 12
        /// Плитка шапки, ряд вкладок, сегментный контрол.
        static let tile: CGFloat = 14
        /// Карточка-список.
        static let card: CGFloat = 16
        /// Диалог, HUD-панель, панель инструментов снимка.
        static let floating: CGFloat = 20
        static let popover: CGFloat = 22
    }

    enum Size {
        /// Концепт — 250, но «Переключатель приложений» (198 pt в Manrope 14/600) там не помещается: 264 вмещает все названия.
        static let sidebar: CGFloat = 264
        static let rowTile: CGFloat = 34
        static let rowIcon: CGFloat = 18
        static let headerTile: CGFloat = 46
        static let headerIcon: CGFloat = 24
        static let toggleTrack = CGSize(width: 42, height: 24)
        static let toggleKnob: CGFloat = 18
        static let button: CGFloat = 36
        static let buttonLarge: CGFloat = 44
        static let iconButton: CGFloat = 40
        static let contentMaxWidth: CGFloat = 760
        static let settingsWindow = CGSize(width: 1040, height: 760)
        static let settingsWindowMin = CGSize(width: 860, height: 560)
        /// Поповер в строке меню (концепт — 520; 460 вмещает вкладки и строки с кейкапами и не слишком широк для строки меню).
        static let popover = CGSize(width: 460, height: 620)
        /// Высота под «светофор» над боковой панелью (окно `fullSizeContentView`).
        static let titlebar: CGFloat = 44
        /// Колонка сочетания в строке шпаргалки.
        static let shortcutColumn: CGFloat = 72
    }

    // MARK: - Шрифты

    /// Шкала §1.2: Manrope и JetBrains Mono, масштабируются вместе с размером текста системы.
    /// Если шрифты не зарегистрированы, — системный шрифт того же размера и веса.
    enum Font {
        static let display = manrope(26, .heavy, relativeTo: .largeTitle)
        static let dialogTitle = manrope(19, .heavy, relativeTo: .title2)
        static let welcomeTitle = manrope(30, .heavy, relativeTo: .largeTitle)
        static let headline = manrope(17, .heavy, relativeTo: .headline)
        static let rowTitle = manrope(15, .semibold, relativeTo: .body)
        static let body = manrope(14, .regular, relativeTo: .body)
        static let bodyStrong = manrope(14, .semibold, relativeTo: .body)
        static let button = manrope(14, .bold, relativeTo: .body)
        static let buttonPrimary = manrope(14, .heavy, relativeTo: .body)
        static let rowSub = manrope(12, .regular, relativeTo: .subheadline)
        static let caption = manrope(12, .semibold, relativeTo: .caption)
        static let groupLabel = manrope(11, .heavy, relativeTo: .caption2)
        static let chip = manrope(13, .bold, relativeTo: .callout)
        static let keycap = mono(13, relativeTo: .callout)
        static let keycapCompact = mono(12, relativeTo: .caption)
        static let mono = DS.Font.mono(14, relativeTo: .body)
        static let monoLarge = DS.Font.mono(18, relativeTo: .title3)

        /// Трекинг (pt) для размера `size` и доли em.
        static func tracking(_ em: CGFloat, size: CGFloat) -> CGFloat { em * size }

        static func manrope(_ size: CGFloat, _ weight: SwiftUI.Font.Weight, relativeTo style: SwiftUI.Font.TextStyle) -> SwiftUI.Font {
            guard DSFonts.isAvailable(DSFonts.manrope) else { return .system(size: size, weight: weight) }
            return .custom(DSFonts.manropeName(weight), size: size, relativeTo: style)
        }

        static func mono(_ size: CGFloat, relativeTo style: SwiftUI.Font.TextStyle) -> SwiftUI.Font {
            guard DSFonts.isAvailable(DSFonts.jetBrainsMono) else { return .system(size: size, weight: .medium, design: .monospaced) }
            return .custom("JetBrainsMonoRoman-Medium", size: size, relativeTo: style)
        }
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.15)
        static let standard = Animation.easeInOut(duration: 0.2)
        static let toggle = Animation.spring(response: 0.2, dampingFraction: 0.85)

        /// nil при «Уменьшить движение».
        static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? { reduceMotion ? nil : animation }
    }

    /// Состояния интерактивных элементов (§2 спецификации v2).
    enum State {
        static let disabledOpacity: Double = 0.45
        static let pressedOpacity: Double = 0.92
        static let pressedScale: CGFloat = 0.98
        static let hoverOverlay: Double = 0.06
        static let focusRing: CGFloat = 2
    }

    enum Format {
        /// Байты без «Zero KB»: нечисловые подписи выключены.
        static func bytes(_ value: Int64, style: ByteCountFormatter.CountStyle = .file) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = style
            formatter.allowsNonnumericFormatting = false
            return formatter.string(fromByteCount: value)
        }

        /// Скорость: «12,4 МБ/с».
        static func rate(_ bytesPerSecond: Double) -> String {
            bytes(Int64(max(0, bytesPerSecond).rounded()), style: .file) + "/с"
        }
    }

    // MARK: - Помощники цвета

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark, .accessibilityHighContrastAqua,
                                    .accessibilityHighContrastDarkAqua])
            .map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0) } ?? false
    }

    /// Цвет с двумя значениями (0xRRGGBB): меняется вместе с темой системы без перезапуска.
    static func color(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in isDark(appearance) ? rgb(dark) : rgb(light) }
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Цвета дизайн-системы для SwiftUI: `.foregroundStyle(.dsMute)`, `.background(Color.dsPanel)`.
extension Color {
    static let dsBg = Color(nsColor: DS.Palette.bg)
    static let dsSide = Color(nsColor: DS.Palette.side)
    static let dsPanel = Color(nsColor: DS.Palette.panel)
    static let dsField = Color(nsColor: DS.Palette.field)
    static let dsLine = Color(nsColor: DS.Palette.line)
    static let dsOff = Color(nsColor: DS.Palette.off)
    static let dsText = Color(nsColor: DS.Palette.text)
    static let dsMute = Color(nsColor: DS.Palette.mute)
    static let dsAcc = Color(nsColor: DS.Palette.acc)
    static let dsAccInk = Color(nsColor: DS.Palette.accInk)
    static let dsAccText = Color(nsColor: DS.Palette.accText)
    static let dsAccLine = Color(nsColor: DS.Palette.accLine)
    static let dsBlue = Color(nsColor: DS.Palette.blue)
    static let dsRec = Color(nsColor: DS.Palette.rec)
    static let dsRecInk = Color(nsColor: DS.Palette.recInk)
}

/// Те же цвета в местах, где ждут `ShapeStyle`: `.foregroundStyle(.dsMute)`.
extension ShapeStyle where Self == Color {
    static var dsBg: Color { Color.dsBg }
    static var dsSide: Color { Color.dsSide }
    static var dsPanel: Color { Color.dsPanel }
    static var dsField: Color { Color.dsField }
    static var dsLine: Color { Color.dsLine }
    static var dsOff: Color { Color.dsOff }
    static var dsText: Color { Color.dsText }
    static var dsMute: Color { Color.dsMute }
    static var dsAcc: Color { Color.dsAcc }
    static var dsAccInk: Color { Color.dsAccInk }
    static var dsAccText: Color { Color.dsAccText }
    static var dsAccLine: Color { Color.dsAccLine }
    static var dsBlue: Color { Color.dsBlue }
    static var dsRec: Color { Color.dsRec }
    static var dsRecInk: Color { Color.dsRecInk }
}

// MARK: - Регистрация шрифтов

/// Встроенные шрифты (`Resources/Fonts`, SIL OFL 1.1): регистрируются для процесса при запуске.
enum DSFonts {
    static let manrope = "Manrope"
    static let jetBrainsMono = "JetBrains Mono"
    static let files = ["Manrope[wght].ttf", "JetBrainsMono[wght].ttf"]

    private static var registered = false
    private static let log = Logger(subsystem: "com.mruzhynskyi.macutils", category: "ui")

    /// Папки, где могут лежать шрифты: ресурсы приложения, а в отладочной сборке и тестах — `Resources/Fonts` репозитория.
    static var searchFolders: [URL] {
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL { folders.append(resources.appendingPathComponent("Fonts")) }
        #if DEBUG
        // Sources/MacUtils/UI/DesignSystem.swift → корень репозитория.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        folders.append(repo.appendingPathComponent("Resources/Fonts"))
        #endif
        return folders
    }

    /// Регистрирует шрифты один раз; повторный вызов ничего не делает. Возвращает имена зарегистрированных файлов.
    @discardableResult
    static func registerAll() -> [String] {
        guard !registered else { return [] }
        registered = true
        var done: [String] = []
        for name in files {
            guard let url = searchFolders.map({ $0.appendingPathComponent(name) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                done.append(name)
            } else if let error = error?.takeRetainedValue(),
                      CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
                done.append(name)
            } else {
                log.error("Шрифт \(name, privacy: .public) не зарегистрирован — будет системный")
            }
        }
        return done
    }

    /// Семейство доступно (зарегистрировано или установлено в системе).
    static func isAvailable(_ family: String) -> Bool {
        registerAll()
        return NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
    }

    /// PostScript-имя начертания Manrope для веса SwiftUI (у переменного шрифта есть именованные начертания).
    static func manropeName(_ weight: SwiftUI.Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin: return "Manrope-ExtraLight"
        case .light: return "Manrope-Light"
        case .medium: return "Manrope-Medium"
        case .semibold: return "Manrope-SemiBold"
        case .bold: return "Manrope-Bold"
        case .heavy, .black: return "Manrope-ExtraBold"
        default: return "Manrope-Regular"
        }
    }
}
