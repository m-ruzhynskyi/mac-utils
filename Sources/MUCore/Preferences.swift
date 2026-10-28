import Foundation

/// Ключи UserDefaults. Значения по умолчанию регистрируются при запуске.
package enum Pref {
    package static let didShowWelcome = "didShowWelcome"
    /// Первый запуск: `false` — вводные шаги ещё не пройдены (ставится только на чистой установке), `true` — пройдены.
    /// Нет значения — вводных шагов не было (обновление с прежней версии): настройки открываются сразу.
    package static let onboardingDone = "onboardingDone"

    package static let cutPaste = "cutPasteEnabled"
    package static let cutPanel = "cutPanelEnabled"

    package static let smoothScroll = "smoothScrollEnabled"
    package static let smoothSpeed = "smoothScrollSpeed"
    package static let smoothDuration = "smoothScrollDuration"

    package static let switcher = "appSwitcherEnabled"
    /// "option" — ⌥Tab, "command" — заменить системный ⌘Tab.
    package static let switcherModifier = "appSwitcherModifier"
    package static let switcherPreviews = "appSwitcherPreviews"

    package static let screenshot = "screenshotEnabled"
    package static let screenshotFolder = "screenshotFolder"
    /// Куда отправлять снимок по Enter / двойному клику: "clipboard", "folder", "both".
    package static let screenshotDestination = "screenshotDestination"
    /// Раскладка коллажа шагов: "auto" (по умолчанию), "vertical", "horizontal", "grid".
    package static let screenshotStepsLayout = "screenshotStepsLayout"
    package static let screenshotStepsEqualSize = "screenshotStepsEqualSize"
    package static let screenshotStepsFrame = "screenshotStepsFrame"
    package static let screenshotStepsTitles = "screenshotStepsTitles"
    package static let screenshotStepsBadges = "screenshotStepsBadges"
    package static let screenshotStepsArrows = "screenshotStepsArrows"
    /// Рамка окна macOS для обычных снимков включена по умолчанию (кнопка / F в оверлее).
    package static let screenshotFrameDefault = "screenshotFrameDefault"
    /// Фон под рамкой и коллажем: см. ShotBackground.
    package static let screenshotBackground = "screenshotBackground"
    /// Наводишь на окно — оно выделяется и снимается кликом; выключено — область только вручную.
    package static let screenshotWindowSnap = "screenshotWindowSnap"

    /// Запись экрана: "mp4" или "gif", кадров в секунду (MP4), курсор, звук системы, микрофон.
    package static let recordingFormat = "recordingFormat"
    package static let recordingFPS = "recordingFPS"
    package static let recordingCursor = "recordingCursor"
    package static let recordingAudio = "recordingAudio"
    package static let recordingMicrophone = "recordingMicrophone"
    /// Папка для видео; пусто — как у снимков.
    package static let recordingFolder = "recordingFolder"
    package static let recordingCopy = "recordingCopy"

    package static let windowSnap = "windowSnapEnabled"
    package static let windowSnapDrag = "windowSnapDrag"
    /// Отступ между окнами: 0, 4 или 8 pt.
    package static let windowSnapGap = "windowSnapGap"
    /// "controlOption" (⌃⌥, по умолчанию), "controlCommand", "optionCommand".
    package static let windowSnapModifier = "windowSnapModifier"

    package static let appVolume = "appVolumeEnabled"
    /// JSON: bundle id → громкость и выключение (только не 100 %).
    package static let appVolumes = "appVolumes"
    package static let appVolumeKeyCode = "appVolumeKeyCode"
    package static let appVolumeModifiers = "appVolumeModifiers"

    /// Последняя открытая вкладка окна «Инструменты».
    package static let toolsTab = "toolsTab"
    /// Скрытые вкладки панели 🔧 (через запятую) — прежняя настройка.
    package static let toolsHiddenTabs = "toolsHiddenTabs"
    /// Вкладки панели 🔧: разделы настроек через запятую, в порядке настроек.
    package static let toolsPanelTabs = "toolsPanelTabs"
    /// Вкладка «Музыка» уже добавлена в панель 🔧 (один раз при обновлении).
    package static let panelTabsMusicAdded = "panelTabsMusicAdded"
    /// Согласие на значок «Инструменты» в Программах: нет ключа — ещё не спрашивали.
    package static let toolsLauncherInstall = "toolsLauncherInstall"
    /// «Полка» для файлов (встряхнуть мышь при перетаскивании или ⌃⌥D).
    package static let dropShelf = "dropShelfEnabled"
    /// «Шпаргалка»: удержание ⌘ показывает сочетания клавиш; задержка в секундах.
    package static let cheatSheet = "cheatSheetEnabled"
    package static let cheatSheetDelay = "cheatSheetDelay"
    /// Автосортировка «Загрузок» (по умолчанию выключена) и срок до Корзины в днях (0 — никогда).
    package static let downloadsSort = "downloadsSortEnabled"
    package static let downloadsTrashDays = "downloadsTrashDays"
    /// Свои правила «Загрузок»: расширение (без точки) → папка.
    package static let downloadsCustomRules = "downloadsCustomRules"
    /// Умная папка снимков (по дням и программам, поиск по тексту) и сбор системных снимков ⌘⇧3/4.
    package static let screenshotLibrary = "screenshotLibraryEnabled"
    package static let screenshotLibrarySystem = "screenshotLibrarySystem"
    package static let screenshotLibraryImported = "screenshotLibraryImported"
    /// Сохранять в умную папку и то, что скопировано только в буфер.
    package static let screenshotLibraryClipboard = "screenshotLibraryClipboard"
    /// Через сколько дней снимки и видео уходят в Корзину (0 — никогда).
    package static let screenshotLibraryTrashDays = "screenshotLibraryTrashDays"
    /// Мгновенный QR (⌃⌥Q).
    package static let qr = "qrEnabled"
    /// Раскладка по программам: включено, запоминать последнюю, правила и запомненное (bundle id → id раскладки).
    package static let appInputSource = "appInputSourceEnabled"
    package static let appInputRemember = "appInputSourceRemember"
    package static let appInputRules = "appInputSourceRules"
    package static let appInputRemembered = "appInputSourceRemembered"
    /// Значок Mac Utils в строке меню (клик — «Инструменты»).
    package static let menuBarIcon = "menuBarIconEnabled"
    /// Показывать Mac Utils в Dock (по умолчанию нет — работает в фоне).
    package static let showInDock = "showInDock"
    /// Режим «Фокус»: размытие всего позади программы (⌃⌥F).
    package static let focus = "focusEnabled"
    package static let focusFollow = "focusFollow"
    package static let focusStrength = "focusStrength"
    /// Музыка: что играло последним и плеер по умолчанию (bundle id или https://…).
    package static let musicLast = "musicLast"
    package static let musicPlayer = "musicPlayer"
    /// Адрес ретранслятора трансляции экрана (relay/, Cloudflare Workers).
    package static let shareServer = "shareServer"
    package static let shareAudio = "shareAudio"
    /// Зрители могут ставить метки и рисовать поверх экрана ведущего.
    package static let shareAllowMarks = "shareAllowMarks"
    /// Зрители сами переключают, какой монитор ведущего транслируется (без вопроса; ведущему — уведомление).
    /// По умолчанию выключено (приватность): ведущий включает один раз в настройках трансляции.
    package static let shareAllowMonitorSwitch = "shareAllowMonitorSwitch"
    /// Свой постоянный 10-значный ID и история подключений (JSON).
    package static let shareID = "shareID"
    package static let shareHistory = "shareHistory"
    /// Программы, чей звук не идёт в трансляцию (bundle id).
    package static let shareMutedApps = "shareMutedApps"
    /// «Не передавать звонки»: программы звонков (`ShareAudioExclusion.callApps`) заглушены для трансляции.
    package static let shareMuteCalls = "shareMuteCalls"
    /// Шпаргалка остаётся открытой после удержания ⌘ и закрывается повторным нажатием ⌘.
    package static let cheatSheetSticky = "cheatSheetSticky"

    /// Напоминание о перерыве: каждые N минут, длительность перерыва в секундах.
    package static let breakReminder = "breakReminderEnabled"
    package static let breakInterval = "breakIntervalMinutes"
    package static let breakDuration = "breakDurationSeconds"
    /// Тёплый экран вечером: сила (0…1) для встроенного и внешних мониторов, часы начала и конца.
    package static let warmScreen = "warmScreenEnabled"
    package static let warmStrength = "warmScreenStrength"
    package static let warmExternalStrength = "warmScreenExternalStrength"
    package static let warmFrom = "warmScreenFromHour"
    package static let warmTo = "warmScreenToHour"
    /// «Поверх всех» (⌃⌥P) и прозрачность копии; запоминание окон по мониторам.
    package static let windowPin = "windowPinEnabled"
    package static let windowPinOpacity = "windowPinOpacity"
    package static let windowMemory = "windowMemoryEnabled"
    /// Рисование поверх экрана (⌃⌥A).
    package static let annotate = "annotateEnabled"

    /// ИИ через локальную Ollama: общий выключатель, адрес, модель и отдельные функции.
    package static let ai = "aiEnabled"
    package static let aiURL = "aiURL"
    package static let aiModel = "aiModel"
    package static let aiFixText = "aiFixText"
    package static let aiShotNames = "aiShotNames"
    package static let aiShotSearch = "aiShotSearch"
    package static let aiDownloads = "aiDownloadsSuggest"
    package static let aiDownloadsTags = "aiDownloadsTags"
    package static let aiTasks = "aiTasks"
    package static let aiCleanup = "aiCleanup"
    package static let aiShelf = "aiShelf"
    /// Записи встреч (⌃⌥M): микрофон, язык расшифровки, отчёт ИИ.
    package static let meetings = "meetingsEnabled"
    package static let meetingsMicrophone = "meetingsMicrophone"
    package static let meetingsLanguage = "meetingsLanguage"
    package static let meetingsReport = "meetingsReport"
    /// Движок расшифровки: "whisper" (если установлен) или "apple".
    package static let meetingsEngine = "meetingsEngine"

    package static let layoutFix = "layoutFixEnabled"
    /// Горячая клавиша: код клавиши и модификаторы Carbon (по умолчанию ⌘P).
    package static let layoutFixKeyCode = "layoutFixKeyCode"
    package static let layoutFixModifiers = "layoutFixModifiers"
    /// Переключать раскладку системы после исправления.
    package static let layoutFixSwitchSource = "layoutFixSwitchSource"

    package static let autoUpdate = "autoUpdateEnabled"
    package static let updateRepo = "updateRepository"
    package static let justUpdatedTo = "justUpdatedTo"
    /// Линейка версий (например, «1.3»), для которой уже показали «Что нового».
    package static let lastSeenChangelog = "lastSeenChangelog"
    /// Тёплый экран: "schedule" — по времени, "manual" — включается вручную.
    package static let warmMode = "warmScreenMode"
    package static let warmManualOn = "warmScreenManualOn"
    /// «Не засыпать»: последний выбранный срок (сама функция после запуска всегда выключена).
    package static let keepAwakeDuration = "keepAwakeDuration"

    /// Текстовый редактор: «Пропускать первые N» знаков `$` (одна настройка на все файлы), новые документы,
    /// восстановление вкладок, черновики, вид и недавние файлы (пути, последний — первым).
    package static let editorSkipFirst = "editorSkipFirst"
    package static let editorSkipCount = "editorSkipCount"
    package static let editorNewEncoding = "editorNewEncoding"
    package static let editorNewLineEnding = "editorNewLineEnding"
    package static let editorRestoreSession = "editorRestoreSession"
    package static let editorAutosaveDrafts = "editorAutosaveDrafts"
    package static let editorWrap = "editorWrap"
    package static let editorZoom = "editorZoom"
    package static let editorDollarPanel = "editorDollarPanel"
    /// Вид: невидимые символы и подсветка парных скобок.
    package static let editorInvisibles = "editorInvisibles"
    package static let editorBrackets = "editorBrackets"
    /// «Документ»: автозамена «--» → «—» и кавычек в «ёлочки» (по умолчанию выключена).
    package static let docAutocorrect = "docAutocorrect"
    /// «Документ»: проверка орфографии (по умолчанию выключена — подчёркивание попадает в офскрин-снимки для сверки с Word).
    package static let docSpelling = "docSpelling"
    /// Ширина табуляции в пробелах (табы ↔ пробелы, отступ таба на экране).
    package static let editorTabWidth = "editorTabWidth"
    /// Поиск в папке: последняя папка и маска имён.
    package static let editorFolderSearchPath = "editorFolderSearchPath"
    package static let editorFolderSearchMask = "editorFolderSearchMask"
    package static let editorRecent = "editorRecent"
    /// Режим «Код» / «Документ» по расширению (последний выбор).
    package static let editorViewModes = "editorViewModes"
    /// Вкладка «Редактор» уже добавлена в панель 🔧 (один раз при обновлении).
    package static let panelTabsEditorAdded = "panelTabsEditorAdded"

    /// Видеоплеер: просмотр, субтитры, пропуск, «Мои снимки», последние выбранные языки и недавние файлы.
    package static let playerRememberPosition = "playerRememberPosition"
    package static let playerSeekStep = "playerSeekStep"
    package static let playerKeepAwake = "playerKeepAwake"
    package static let playerKeepPitch = "playerKeepPitch"
    package static let playerVolume = "playerVolume"
    package static let playerSubtitlesNearby = "playerSubtitlesNearby"
    package static let playerSubtitleSize = "playerSubtitleSize"
    package static let playerSubtitleBackground = "playerSubtitleBackground"
    package static let playerSubtitleLanguage = "playerSubtitleLanguage"
    package static let playerAudioLanguage = "playerAudioLanguage"
    package static let playerSkipAuto = "playerSkipAuto"
    package static let playerNextEpisode = "playerNextEpisode"
    /// Папки, где кнопку «Пропустить…» просили не показывать.
    package static let playerSkipHiddenFolders = "playerSkipHiddenFolders"
    /// Двойной клик по видео в «Моих снимках»: true — плеер Mac Utils, false — программа по умолчанию.
    package static let playerOpensShots = "playerOpensShots"
    package static let playerRecent = "playerRecent"
    package static let playerFinished = "playerFinished"

    package static func register() {
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
            screenshotStepsBadges: true,
            screenshotStepsArrows: false,
            screenshotFrameDefault: false,
            screenshotBackground: "sky",
            screenshotWindowSnap: false,
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
            showInDock: false,
            focus: true,
            focusFollow: false,
            focusStrength: 0.6,
            shareAudio: true,
            shareAllowMarks: true,
            shareMuteCalls: false,
            // Выключено, пока ведущий сам не включит: без этого зритель не видит другие его мониторы.
            shareAllowMonitorSwitch: false,
            shareServer: "https://mac-utils-relay.mako-62d.workers.dev",
            cheatSheetSticky: false,
            dropShelf: true,
            cheatSheet: true,
            cheatSheetDelay: 0.8,
            downloadsSort: false,
            downloadsTrashDays: 30,
            screenshotLibrary: true,
            screenshotLibrarySystem: false,
            screenshotLibraryClipboard: true,
            screenshotLibraryTrashDays: 0,
            qr: true,
            appInputSource: true,
            appInputRemember: true,
            breakReminder: false,
            breakInterval: 45,
            breakDuration: 20,
            warmScreen: false,
            warmStrength: 0.5,
            warmExternalStrength: 0.5,
            warmFrom: 21,
            warmTo: 7,
            warmMode: "schedule",
            warmManualOn: false,
            keepAwakeDuration: KeepAwakeDuration.indefinite.rawValue,
            annotate: true,
            windowPin: true,
            windowPinOpacity: 1.0,
            windowMemory: true,
            ai: true,
            aiURL: "http://localhost:11434",
            aiModel: "qwen2.5:7b",
            aiFixText: true,
            aiShotNames: true,
            aiShotSearch: true,
            aiDownloads: true,
            aiDownloadsTags: true,
            aiTasks: true,
            aiCleanup: true,
            aiShelf: true,
            meetings: true,
            meetingsMicrophone: true,
            meetingsLanguage: "auto",
            meetingsEngine: "whisper",
            meetingsReport: true,
            layoutFix: true,
            layoutFixSwitchSource: false,
            autoUpdate: true,
            editorSkipFirst: true,
            editorSkipCount: 3,
            editorNewEncoding: "utf8", // TextEncoding.utf8.rawValue (тип остаётся в приложении: App Intents не берут перечисления из другого модуля)
            editorNewLineEnding: "lf", // LineEnding.lf.rawValue
            editorRestoreSession: true,
            editorAutosaveDrafts: true,
            editorWrap: false,
            editorZoom: 1.0,
            editorDollarPanel: true,
            editorInvisibles: false,
            editorBrackets: true,
            docAutocorrect: false,
            docSpelling: false,
            editorTabWidth: 4,
            playerRememberPosition: true,
            playerSeekStep: 5,
            playerKeepAwake: true,
            playerKeepPitch: true,
            playerVolume: 1.0,
            playerSubtitlesNearby: true,
            playerSubtitleSize: 1,
            playerSubtitleBackground: false,
            playerSkipAuto: false,
            playerNextEpisode: true,
            playerOpensShots: true,
        ])
    }

    package enum ScreenshotDestination: String {
        case clipboard, folder, both
    }

    package static var screenshotDestinationValue: ScreenshotDestination {
        ScreenshotDestination(rawValue: UserDefaults.standard.string(forKey: screenshotDestination) ?? "") ?? .clipboard
    }

    /// Папка для записей экрана (по умолчанию — папка снимков).
    package static var recordingDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: recordingFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return screenshotDirectory
    }

    package static var screenshotDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: screenshotFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}

/// Русское склонение по числу: 1 объект, 2 объекта, 5 объектов.
package func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let mod10 = n % 10, mod100 = n % 100
    if mod10 == 1 && mod100 != 11 { return one }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
    return many
}
