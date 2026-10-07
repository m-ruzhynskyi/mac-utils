import Foundation

/// Ключи UserDefaults. Значения по умолчанию регистрируются при запуске.
enum Pref {
    static let didShowWelcome = "didShowWelcome"

    static let cutPaste = "cutPasteEnabled"
    static let cutPanel = "cutPanelEnabled"

    static let smoothScroll = "smoothScrollEnabled"
    static let smoothSpeed = "smoothScrollSpeed"
    static let smoothDuration = "smoothScrollDuration"

    static let switcher = "appSwitcherEnabled"
    /// "option" — ⌥Tab, "command" — заменить системный ⌘Tab.
    static let switcherModifier = "appSwitcherModifier"
    static let switcherPreviews = "appSwitcherPreviews"

    static let screenshot = "screenshotEnabled"
    static let screenshotFolder = "screenshotFolder"
    /// Куда отправлять снимок по Enter / двойному клику: "clipboard", "folder", "both".
    static let screenshotDestination = "screenshotDestination"
    /// Раскладка коллажа шагов: "auto" (по умолчанию), "vertical", "horizontal", "grid".
    static let screenshotStepsLayout = "screenshotStepsLayout"
    static let screenshotStepsEqualSize = "screenshotStepsEqualSize"
    static let screenshotStepsFrame = "screenshotStepsFrame"
    static let screenshotStepsTitles = "screenshotStepsTitles"
    /// Рамка окна macOS для обычных снимков включена по умолчанию (кнопка / F в оверлее).
    static let screenshotFrameDefault = "screenshotFrameDefault"
    /// Фон под рамкой и коллажем: см. ShotBackground.
    static let screenshotBackground = "screenshotBackground"

    /// Запись экрана: "mp4" или "gif", кадров в секунду (MP4), курсор, звук системы, микрофон.
    static let recordingFormat = "recordingFormat"
    static let recordingFPS = "recordingFPS"
    static let recordingCursor = "recordingCursor"
    static let recordingAudio = "recordingAudio"
    static let recordingMicrophone = "recordingMicrophone"
    /// Папка для видео; пусто — как у снимков.
    static let recordingFolder = "recordingFolder"
    static let recordingCopy = "recordingCopy"

    static let windowSnap = "windowSnapEnabled"
    static let windowSnapDrag = "windowSnapDrag"
    /// Отступ между окнами: 0, 4 или 8 pt.
    static let windowSnapGap = "windowSnapGap"
    /// "controlOption" (⌃⌥, по умолчанию), "controlCommand", "optionCommand".
    static let windowSnapModifier = "windowSnapModifier"

    static let appVolume = "appVolumeEnabled"
    /// JSON: bundle id → громкость и выключение (только не 100 %).
    static let appVolumes = "appVolumes"
    static let appVolumeKeyCode = "appVolumeKeyCode"
    static let appVolumeModifiers = "appVolumeModifiers"

    /// Последняя открытая вкладка окна «Инструменты».
    static let toolsTab = "toolsTab"
    /// «Полка» для файлов (встряхнуть мышь при перетаскивании или ⌃⌥D).
    static let dropShelf = "dropShelfEnabled"
    /// «Шпаргалка»: удержание ⌘ показывает сочетания клавиш; задержка в секундах.
    static let cheatSheet = "cheatSheetEnabled"
    static let cheatSheetDelay = "cheatSheetDelay"
    /// Автосортировка «Загрузок» (по умолчанию выключена) и срок до Корзины в днях (0 — никогда).
    static let downloadsSort = "downloadsSortEnabled"
    static let downloadsTrashDays = "downloadsTrashDays"
    /// Свои правила «Загрузок»: расширение (без точки) → папка.
    static let downloadsCustomRules = "downloadsCustomRules"
    /// Умная папка снимков (по дням и программам, поиск по тексту) и сбор системных снимков ⌘⇧3/4.
    static let screenshotLibrary = "screenshotLibraryEnabled"
    static let screenshotLibrarySystem = "screenshotLibrarySystem"
    /// Мгновенный QR (⌃⌥Q).
    static let qr = "qrEnabled"
    /// Раскладка по программам: включено, запоминать последнюю, правила и запомненное (bundle id → id раскладки).
    static let appInputSource = "appInputSourceEnabled"
    static let appInputRemember = "appInputSourceRemember"
    static let appInputRules = "appInputSourceRules"
    static let appInputRemembered = "appInputSourceRemembered"
    /// Значок Mac Utils в строке меню (клик — «Инструменты»).
    static let menuBarIcon = "menuBarIconEnabled"

    static let layoutFix = "layoutFixEnabled"
    /// Горячая клавиша: код клавиши и модификаторы Carbon (по умолчанию ⌘P).
    static let layoutFixKeyCode = "layoutFixKeyCode"
    static let layoutFixModifiers = "layoutFixModifiers"
    /// Переключать раскладку системы после исправления.
    static let layoutFixSwitchSource = "layoutFixSwitchSource"

    static let autoUpdate = "autoUpdateEnabled"
    static let updateRepo = "updateRepository"
    static let justUpdatedTo = "justUpdatedTo"

    static func register() {
        UserDefaults.standard.register(defaults: [
            cutPaste: true,
            cutPanel: true,
            smoothScroll: true,
            smoothSpeed: 1.0,
            smoothDuration: 0.35,
            switcher: true,
            switcherModifier: "option",
            switcherPreviews: true,
            screenshot: true,
            screenshotDestination: "clipboard",
            screenshotStepsLayout: "auto",
            screenshotStepsEqualSize: true,
            screenshotStepsFrame: true,
            screenshotStepsTitles: true,
            screenshotFrameDefault: false,
            screenshotBackground: "sky",
            recordingFormat: "mp4",
            recordingFPS: 30,
            recordingCursor: true,
            recordingAudio: false,
            recordingMicrophone: false,
            recordingCopy: true,
            windowSnap: true,
            windowSnapDrag: true,
            windowSnapGap: 0,
            windowSnapModifier: "controlOption",
            appVolume: true,
            menuBarIcon: true,
            dropShelf: true,
            cheatSheet: true,
            cheatSheetDelay: 0.8,
            downloadsSort: false,
            downloadsTrashDays: 30,
            screenshotLibrary: true,
            screenshotLibrarySystem: false,
            qr: true,
            appInputSource: true,
            appInputRemember: true,
            layoutFix: true,
            layoutFixSwitchSource: false,
            autoUpdate: true,
        ])
    }

    enum ScreenshotDestination: String {
        case clipboard, folder, both
    }

    static var screenshotDestinationValue: ScreenshotDestination {
        ScreenshotDestination(rawValue: UserDefaults.standard.string(forKey: screenshotDestination) ?? "") ?? .clipboard
    }

    /// Папка для записей экрана (по умолчанию — папка снимков).
    static var recordingDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: recordingFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return screenshotDirectory
    }

    static var screenshotDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: screenshotFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}

/// Русское склонение по числу: 1 объект, 2 объекта, 5 объектов.
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let mod10 = n % 10, mod100 = n % 100
    if mod10 == 1 && mod100 != 11 { return one }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
    return many
}
