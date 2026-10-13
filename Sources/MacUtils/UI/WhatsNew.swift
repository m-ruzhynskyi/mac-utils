import AppKit
import SwiftUI

/// История версий: что появилось. Новая версия — сверху.
enum Changelog {
    struct Release: Identifiable {
        let version: String
        let date: String
        let items: [String]
        var id: String { version }
    }

    static let releases: [Release] = [
        Release(version: "1.3", date: "12 октября 2026", items: [
            "Записи встреч: расшифровка Whisper — украинский, русский, английский, язык определяется сам, со знаками препинания",
            "Отчёты о встречах подробнее: итог, темы, решения, задачи, открытые вопросы — без выдуманного",
            "Записи встреч можно расшифровать заново и удалить",
            "Микрофон с подавлением эха: в записи экрана и встреч звук системы больше не двоится",
            "Снимки: режим «Окно под курсором» или «Своя область» (кнопка вверху экрана или Tab)",
            "Снимки: название кнопки панели — сразу при наведении; по умолчанию — своя область",
            "«Снимки» в панели 🔧: кнопка «Скопировать» и перетаскивание в любую программу",
            "Шпаргалка листается колесом мыши; режим «Оставлять открытой»",
            "Тёплый экран можно включать вручную, без расписания",
            "В панель 🔧 можно вынести любые возможности Mac Utils; можно показывать Mac Utils в Dock",
            "Приложение само предложит перенестись в «Программы», чтобы обновляться",
            "Окно «Что нового» после обновления и история версий в настройках",
            "Музыкальный плеер: что играет в любой программе (браузер, Музыка, Spotify…), пауза, треки, перемотка",
            "Вкладки панели 🔧 — свой компактный вид с быстрыми действиями для каждого раздела",
            "Трансляция экрана по коду через интернет — со звуком системы; можно выбрать экран, окно или программу; смотреть и транслировать можно и с Windows",
            "Больше 5 вкладок в панели 🔧 — переносятся на второй ряд",
        ]),
        Release(version: "1.2", date: "7–10 октября 2026", items: [
            "ИИ на локальной Ollama: исправление текста ⌃⌥E, умные имена и поиск снимков, подсказки в диспетчере задач и очистке, группы на полке, подписи файлов в «Загрузках»",
            "Записи встреч (⌃⌥M) с расшифровкой и отчётом",
            "Рисование поверх экрана (⌃⌥A), окно поверх всех (⌃⌥P), окна по мониторам",
            "Перерывы и тёплый экран вечером",
            "Полка для файлов, шпаргалка ⌘, автосортировка «Загрузок», мгновенный QR, раскладка по программам",
            "Умная папка снимков с поиском по тексту, запись экрана в MP4 и GIF, коллаж шагов",
            "Инструменты: удаление программ, монитор, диспетчер задач, очистка диска",
            "Раскладка окон, громкость приложений, исправление раскладки, переключатель окон",
        ]),
    ]

    /// «1.3.4» → «1.3».
    static func family(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }
}

/// Окно «Что нового»: один раз после обновления, а также из настроек.
@MainActor
final class WhatsNewWindowController {
    static let shared = WhatsNewWindowController()
    private var window: NSWindow?

    /// После обновления на новую линейку версий — показать один раз.
    func showIfUpdated() {
        let current = Changelog.family(Updater.shared.currentVersion)
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Pref.lastSeenChangelog) != current,
              Changelog.releases.contains(where: { $0.version == current }) else { return }
        defaults.set(current, forKey: Pref.lastSeenChangelog)
        show()
    }

    func show() {
        let window = self.window ?? make()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Что нового в Mac Utils"
        window.contentViewController = NSHostingController(rootView: WhatsNewView())
        window.setContentSize(NSSize(width: 520, height: 560))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        return window
    }
}

struct WhatsNewView: View {
    private let current = Changelog.family(Updater.shared.currentVersion)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Что нового").font(.title2.weight(.bold))
                        Text("Версия \(Updater.shared.currentVersion)").foregroundStyle(.secondary)
                    }
                }
                ForEach(Changelog.releases) { release in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Версия \(release.version)").font(.headline)
                            if release.version == current {
                                Text("сейчас").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                            }
                            Spacer()
                            Text(release.date).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(release.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                                Text(item).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(release.version == current ? 0.06 : 0.03),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(22)
        }
        .frame(minWidth: 440, minHeight: 400)
    }
}
