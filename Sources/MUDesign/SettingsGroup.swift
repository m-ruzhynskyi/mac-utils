import Foundation
import MUCore


// MARK: - Группы боковой панели

/// Группы разделов в боковой панели настроек — как в концепте Graphite (`.audit/design-spec-v2.md` §3).
/// Порядок `SettingsSection.allCases` не меняется: на нём держатся сохранённые вкладки панели; порядок показа задаёт `sections`.
package enum SettingsGroup: String, CaseIterable, Identifiable {
    case general, capture, windowsInput, filesSystem, more

    package var id: String { rawValue }

    /// Название группы; в боковой панели показывается капсом.
    package var title: String {
        switch self {
        case .general: return "Основное"
        case .capture: return "Захват"
        case .windowsInput: return "Окна и ввод"
        case .filesSystem: return "Файлы и система"
        case .more: return "Ещё"
        }
    }

    package var sections: [SettingsSection] {
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
    package var group: SettingsGroup {
        SettingsGroup.allCases.first { $0.sections.contains(self) } ?? .general
    }

    /// Строка под заголовком в шапке страницы. Для «Общих» и «Снимков экрана» — из концепта, у остальных —
    /// первая фраза прежнего описания страницы (слова не менялись). Пусто — у страницы не было общего описания.
    /// Подписи, в которых есть значения из функций (сочетание панели, категории загрузок): подставляет приложение при запуске.
    package nonisolated(unsafe) static var dynamicSubtitle: (SettingsSection) -> String? = { _ in nil }

    package var subtitle: String {
        switch self {
        case .general: return "Запуск, значки, обновления"
        case .screenshot: return "Куда сохранять и что делать после снимка"
        case .hotKeys: return "Все сочетания Mac Utils."
        case .exclusions: return "В этих программах Mac Utils не перехватывает клавиши и колесо мыши: не работают переключатель окон ⌥Tab, подсказки при удержании ⌘, плавная прокрутка и исправление раскладки."
        case .panel, .downloads: return Self.dynamicSubtitle(self) ?? ""
        case .textInput: return "Автозамены macOS при наборе текста во всех программах."
        case .focus: return "Выбранная программа остаётся чёткой, а всё позади её окон размывается и чуть затемняется — ничего не отвлекает."
        case .cutPaste: return "⌘X — вырезать, ⌘V — переместить файлы и папки в Finder."
        case .smoothScroll: return "Колесо обычной мыши прокручивает плавно, как трекпад."
        case .windows: return "Как в Windows: перетащите окно за заголовок к краю экрана — оно займёт половину, к углу — четверть, к верхнему краю — весь экран."
        case .volume: return "Своя громкость (0–150 %) и выключение звука для каждой программы."
        case .layout: return "Набрали по-русски в английской раскладке (ghbdtn) или наоборот (руддщ)? Нажмите горячую клавишу — текст переведётся (привет, hello)."
        case .shelf: return "Временное место для файлов: положите их на полку, перейдите в нужную папку или программу и вытащите обратно — по одному или все сразу."
        case .cheatSheet: return "Удерживайте ⌘ — появятся все сочетания клавиш активной программы (из её меню) и Mac Utils."
        case .qr: return "Одно сочетание для двух дел: сделать QR-код из выделенного текста или прочитать QR-код с экрана."
        case .annotate: return "Стрелки, рамки, маркер и перо прямо поверх экрана — во время созвона, демонстрации или записи экрана (рисунки попадают в запись)."
        case .meetings: return "Записывает звук созвона (собеседников и ваш микрофон отдельно), расшифровывает прямо на Mac (Whisper или распознавание Apple), а локальная модель (Ollama) делает отчёт: итог, решения, задачи."
        case .ai: return "Всё работает на локальной модели через Ollama — тексты, снимки и файлы не уходят в интернет."
        case .textEditor: return "Вкладки, кодировки и знаки $ для .frm и других текстов"
        case .videoPlayer: return "Плейлист, субтитры, дорожки и запоминание места"
        case .remote: return "AnyDesk и TeamViewer из своей таблицы: ⌃⌥⌘A, набрали имя — Enter"
        case .music, .share, .switcher, .wellbeing, .uninstaller, .monitor, .tasks, .cleanup, .shots: return ""
        }
    }
}
