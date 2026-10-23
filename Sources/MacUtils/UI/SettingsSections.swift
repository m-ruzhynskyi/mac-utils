import AppKit
import MURemoteConnections
import SwiftUI

// MARK: - Разделы

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, hotKeys, exclusions, panel, music, share, focus, textInput, cutPaste, smoothScroll, switcher, screenshot, windows, volume, layout, shelf, cheatSheet, downloads, qr,
         annotate, wellbeing, meetings, ai,
         uninstaller, monitor, tasks, cleanup, shots, textEditor, videoPlayer, remote

    var id: String { rawValue }

    /// Короткое имя для вкладки панели 🔧.
    var panelTitle: String {
        switch self {
        case .uninstaller: return "Программы"
        case .monitor: return "Монитор"
        case .tasks: return "Задачи"
        case .cleanup: return "Очистка"
        case .shots: return "Снимки"
        case .textEditor: return "Редактор"
        case .videoPlayer: return "Плеер"
        case .remote: return RL("Удалённые")
        case .cutPaste: return "Вырезать"
        case .smoothScroll: return "Прокрутка"
        case .switcher: return "Переключатель"
        case .screenshot: return "Скриншоты"
        case .windows: return "Окна"
        case .volume: return "Громкость"
        case .layout: return "Раскладка"
        case .shelf: return "Полка"
        case .cheatSheet: return "Шпаргалка"
        case .downloads: return "Загрузки"
        case .qr: return "QR"
        case .annotate: return "Рисование"
        case .wellbeing: return "Перерывы"
        case .meetings: return "Встречи"
        case .ai: return "ИИ"
        case .general: return "Общие"
        case .hotKeys: return "Клавиши"
        case .exclusions: return "Исключения"
        case .panel: return "Панель"
        case .music: return "Музыка"
        case .share: return "Трансляция"
        case .textInput: return "Ввод"
        case .focus: return "Фокус"
        }
    }

    var title: String {
        switch self {
        case .general: return "Общие"
        case .hotKeys: return "Горячие клавиши"
        case .exclusions: return "Исключённые программы"
        case .panel: return "Панель в строке меню"
        case .music: return "Музыка"
        case .share: return "Трансляция экрана"
        case .textInput: return "Ввод текста"
        case .focus: return "Фокус"
        case .cutPaste: return "Вырезать и вставить"
        case .smoothScroll: return "Плавная прокрутка"
        case .switcher: return "Переключатель приложений"
        case .screenshot: return "Снимки экрана"
        case .windows: return "Окна"
        case .volume: return "Громкость"
        case .layout: return "Раскладка"
        case .shelf: return "Полка"
        case .cheatSheet: return "Шпаргалка"
        case .downloads: return "Загрузки"
        case .qr: return "QR-коды"
        case .annotate: return "Рисование на экране"
        case .wellbeing: return "Перерывы и тёплый экран"
        case .meetings: return "Записи встреч"
        case .ai: return "ИИ (Ollama)"
        case .uninstaller: return "Удаление программ"
        case .monitor: return "Монитор системы"
        case .tasks: return "Диспетчер задач"
        case .cleanup: return "Очистка диска"
        case .shots: return "Мои снимки"
        case .textEditor: return "Текстовый редактор"
        case .videoPlayer: return "Видеоплеер"
        case .remote: return RL("Удалённые подключения")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .hotKeys: return "keyboard.badge.ellipsis"
        case .exclusions: return "rectangle.on.rectangle.slash"
        case .panel: return "menubar.rectangle"
        case .music: return "music.note"
        case .share: return "dot.radiowaves.left.and.right"
        case .textInput: return "character.cursor.ibeam"
        case .focus: return "scope"
        case .cutPaste: return "scissors"
        case .smoothScroll: return "computermouse"
        case .switcher: return "rectangle.on.rectangle"
        case .screenshot: return "camera.viewfinder"
        case .windows: return "rectangle.split.2x2"
        case .volume: return "speaker.wave.2"
        case .layout: return "keyboard"
        case .shelf: return "tray.full"
        case .cheatSheet: return "command"
        case .downloads: return "arrow.down.circle"
        case .qr: return "qrcode"
        case .annotate: return "pencil.tip.crop.circle"
        case .wellbeing: return "sun.horizon"
        case .meetings: return "waveform.badge.mic"
        case .ai: return "sparkles"
        case .uninstaller: return "trash"
        case .monitor: return "gauge.with.dots.needle.67percent"
        case .tasks: return "list.bullet.rectangle"
        case .cleanup: return "externaldrive.badge.minus"
        case .shots: return "photo.on.rectangle.angled"
        case .textEditor: return "doc.plaintext"
        case .videoPlayer: return "play.rectangle"
        case .remote: return "display.2"
        }
    }
}

// MARK: - Поиск по разделам

extension SettingsSection {
    /// О чём раздел — для поиска (кроме заголовка и названий сочетаний, которые добавляются сами).
    var keywords: String {
        switch self {
        case .general: return "автозапуск вход в систему dock значок строка меню разрешения универсальный доступ запись экрана полный доступ к диску обновления версия что нового репозиторий"
        case .hotKeys: return "сочетания клавиш горячие клавиши шорткаты переназначить конфликт занято hotkey shortcut команды ссылки url macutils:// siri spotlight автоматизация действия"
        case .exclusions: return "исключения исключённые программы виртуальная машина parallels vmware utm виртуалбокс удалённый рабочий стол общий экран remote desktop teamviewer anydesk перехват клавиш колесо мыши не работает ⌥tab"
        case .panel: return "панель вкладки порядок инструменты значок 🔧"
        case .music: return "сейчас играет музыка spotify apple music плеер обложка"
        case .share: return "трансляция экрана зрители id ретранслятор relay доверенные отпечаток ключ эфир"
        case .textInput: return "ввод текста раскладка для приложения источник ввода язык"
        case .focus: return "фокус размытие фона затемнение"
        case .cutPaste: return "вырезать вставить finder перенос файлов ⌘x ⌘v"
        case .smoothScroll: return "плавная прокрутка колесо мыши скорость инерция"
        case .switcher: return "переключатель приложений ⌘tab окна превью"
        case .screenshot: return "снимок скриншот разметка распознать текст ocr запись экрана видео gif длинный снимок шаги коллаж папка буфер"
        case .windows: return "окна раскладка половины четверти прилипание поверх всех закрепить мониторы"
        case .volume: return "громкость приложений звук микшер"
        case .layout: return "раскладка ghbdtn исправить слово перевести клавиатуру"
        case .shelf: return "полка файлы перетаскивание встряхнуть"
        case .cheatSheet: return "шпаргалка удерживать ⌘ сочетания меню программы"
        case .downloads: return "загрузки сортировка папки правила корзина"
        case .qr: return "qr код ссылка распознать"
        case .annotate: return "рисование на экране перо стрелка маркер презентация"
        case .wellbeing: return "перерывы глаза тёплый экран ночной режим 20-20-20 не засыпать сон caffeinate кофеин"
        case .meetings: return "записи встреч созвон микрофон расшифровка whisper отчёт"
        case .ai: return "ии ollama модель исправить текст умные имена"
        case .uninstaller: return "удаление программ остатки приложения"
        case .monitor: return "монитор системы процессор память диск сеть батарея"
        case .tasks: return "диспетчер задач процессы завершить"
        case .cleanup: return "очистка диска кэш корзина загрузки место"
        case .shots: return "мои снимки история поиск умная папка копии снимков"
        case .textEditor: return "текстовый редактор блокнот notepad frm rtf txt log json xml csv кодировка вкладки знаки $ доллар открыть с помощью"
        case .videoPlayer: return "видеоплеер видео плеер фильм сериал mp4 mov m4v mp3 субтитры srt ass дорожка скорость плейлист пропустить интро титры следующая серия кадр картинка в картинке pip"
        case .remote: return "удалённые подключения anydesk teamviewer удалённый доступ компьютеры id пароль таблица xlsx xml excel ⌥⌘a"
        }
    }

    /// Всё, по чему ищется раздел.
    var searchText: String {
        let hotKeys = HotKeyAction.allCases.filter { $0.section == self }.map(\.title)
        return ([title, panelTitle, group.title, keywords] + hotKeys).joined(separator: " ")
    }
}

// MARK: - Группы боковой панели

/// Группы разделов в боковой панели настроек — как в концепте Graphite (`.audit/design-spec-v2.md` §3).
/// Порядок `SettingsSection.allCases` не меняется: на нём держатся сохранённые вкладки панели; порядок показа задаёт `sections`.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case general, capture, windowsInput, filesSystem, more

    var id: String { rawValue }

    /// Название группы; в боковой панели показывается капсом.
    var title: String {
        switch self {
        case .general: return "Основное"
        case .capture: return "Захват"
        case .windowsInput: return "Окна и ввод"
        case .filesSystem: return "Файлы и система"
        case .more: return "Ещё"
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .general: return [.general, .hotKeys, .exclusions, .panel]
        case .capture: return [.screenshot, .shots, .annotate, .qr, .meetings]
        case .windowsInput: return [.switcher, .windows, .volume, .layout, .smoothScroll, .cutPaste, .textInput]
        case .filesSystem: return [.shelf, .downloads, .textEditor, .videoPlayer, .cheatSheet, .uninstaller, .cleanup, .monitor, .tasks]
        case .more: return [.wellbeing, .focus, .music, .share, .remote, .ai]
        }
    }
}

extension SettingsSection {
    var group: SettingsGroup {
        SettingsGroup.allCases.first { $0.sections.contains(self) } ?? .general
    }

    /// Строка под заголовком в шапке страницы. Для «Общих» и «Снимков экрана» — из концепта, у остальных —
    /// первая фраза прежнего описания страницы (слова не менялись). Пусто — у страницы не было общего описания.
    var subtitle: String {
        switch self {
        case .general: return "Запуск, значки, обновления"
        case .screenshot: return "Куда сохранять и что делать после снимка"
        case .hotKeys: return "Все сочетания Mac Utils."
        case .exclusions: return "В этих программах Mac Utils не перехватывает клавиши и колесо мыши: не работают переключатель окон ⌥Tab, подсказки при удержании ⌘, плавная прокрутка и исправление раскладки."
        case .panel: return "Клик по значку — панель с вкладками прямо под ним (или \(HotKeyRegistry.combo(for: .tools).title))."
        case .textInput: return "Автозамены macOS при наборе текста во всех программах."
        case .focus: return "Выбранная программа остаётся чёткой, а всё позади её окон размывается и чуть затемняется — ничего не отвлекает."
        case .cutPaste: return "⌘X — вырезать, ⌘V — переместить файлы и папки в Finder."
        case .smoothScroll: return "Колесо обычной мыши прокручивает плавно, как трекпад."
        case .windows: return "Как в Windows: перетащите окно за заголовок к краю экрана — оно займёт половину, к углу — четверть, к верхнему краю — весь экран."
        case .volume: return "Своя громкость (0–150 %) и выключение звука для каждой программы."
        case .layout: return "Набрали по-русски в английской раскладке (ghbdtn) или наоборот (руддщ)? Нажмите горячую клавишу — текст переведётся (привет, hello)."
        case .shelf: return "Временное место для файлов: положите их на полку, перейдите в нужную папку или программу и вытащите обратно — по одному или все сразу."
        case .cheatSheet: return "Удерживайте ⌘ — появятся все сочетания клавиш активной программы (из её меню) и Mac Utils."
        case .downloads: return "Новые файлы сами перемещаются в папки по типу: \(DownloadsRules.Category.allCases.map(\.rawValue).joined(separator: ", ")) — и по вашим правилам ниже."
        case .qr: return "Одно сочетание для двух дел: сделать QR-код из выделенного текста или прочитать QR-код с экрана."
        case .annotate: return "Стрелки, рамки, маркер и перо прямо поверх экрана — во время созвона, демонстрации или записи экрана (рисунки попадают в запись)."
        case .meetings: return "Записывает звук созвона (собеседников и ваш микрофон отдельно), расшифровывает прямо на Mac (Whisper или распознавание Apple), а локальная модель (Ollama) делает отчёт: итог, решения, задачи."
        case .ai: return "Всё работает на локальной модели через Ollama — тексты, снимки и файлы не уходят в интернет."
        case .textEditor: return "Вкладки, кодировки и знаки $ для .frm и других текстов"
        case .videoPlayer: return "Плейлист, субтитры, дорожки и запоминание места"
        case .remote: return RL("AnyDesk и TeamViewer из своей таблицы: ⌥⌘A, набрали имя — Enter")
        case .music, .share, .switcher, .wellbeing, .uninstaller, .monitor, .tasks, .cleanup, .shots: return ""
        }
    }
}
