import AppKit
import SwiftUI
import MUCore
import MUDesign

// MARK: - Разделы

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
        case .remote: return "удалённые подключения anydesk teamviewer удалённый доступ компьютеры id пароль таблица xlsx xml excel ⌃⌥⌘a"
        }
    }

    /// Всё, по чему ищется раздел.
    var searchText: String {
        let hotKeys = HotKeyAction.allCases.filter { $0.section == self }.map(\.title)
        return ([title, panelTitle, group.title, keywords] + hotKeys).joined(separator: " ")
    }
}
