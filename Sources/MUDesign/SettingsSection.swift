import Foundation
import MUCore

package enum SettingsSection: String, CaseIterable, Identifiable {
    case general, hotKeys, exclusions, panel, music, share, focus, textInput, cutPaste, smoothScroll, switcher, screenshot, windows, volume, layout, shelf, cheatSheet, downloads, qr,
         annotate, wellbeing, meetings, ai,
         uninstaller, monitor, tasks, cleanup, shots, textEditor, videoPlayer, remote

    package var id: String { rawValue }

    /// Короткое имя для вкладки панели 🔧.
    package var panelTitle: String {
        switch self {
        case .uninstaller: return "Программы"
        case .monitor: return "Монитор"
        case .tasks: return "Задачи"
        case .cleanup: return "Очистка"
        case .shots: return "Снимки"
        case .textEditor: return "Редактор"
        case .videoPlayer: return "Плеер"
        case .remote: return "Удалённые"
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

    package var title: String {
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
        case .remote: return "Удалённые подключения"
        }
    }

    package var symbol: String {
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
