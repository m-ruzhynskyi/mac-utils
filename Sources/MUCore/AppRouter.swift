import CoreGraphics
import Foundation

/// Связь функций с приложением без прямых вызовов: функция просит действие по идентификатору горячей клавиши,
/// а что оно делает, решает приложение (подставляет при запуске).
@MainActor
package final class AppRouter {
    package static let shared = AppRouter()

    /// Выполнить то же, что нажатие горячей клавиши `HotKeyID.…` (из меню, панели, ссылки).
    package var runHotKey: (UInt32) -> Void = { _ in }

    /// После запуска/обновления показать «Что нового», если линейка версий новая.
    package var showWhatsNewIfUpdated: () -> Void = {}
    /// Программа лежит в «Программах» (иначе самообновление объясняет, куда её перенести).
    package var isInApplications: () -> Bool = { true }

    /// Подготовка к перезапуску приложения (например, перед установкой обновления): остановить перехваты и фоновые службы.
    package var prepareForRelaunch: () -> Void = {}

    /// «Шпаргалка»: группы, показываемые первыми, когда впереди окно самого приложения (например, клавиши плеера).
    package var cheatFrontGroups: () -> [CheatGroup] = { [] }
    /// «Шпаргалка»: группа сочетаний Mac Utils, которые действительно работают сейчас.
    package var cheatMacUtilsGroup: () -> CheatGroup = { CheatGroup(title: "Mac Utils", items: []) }

    /// Окно настроек открыто (чтобы не отнимать фокус у программы, из которой пришли).
    package var settingsVisible: () -> Bool = { false }
    /// Обновить режим Dock (обычное или фоновое приложение). `editorOpen`/`playerOpen` — пока окно открывается или закрывается.
    package var syncDock: (_ editorOpen: Bool?, _ playerOpen: Bool?) -> Void = { _, _ in }
    /// Открыть файлы в плеере Mac Utils.
    package var openMedia: ([URL]) -> Void = { _ in }
    /// Окно плеера сейчас главное, и «Открыть…» должно открывать файл в нём.
    package var playerIsKey: () -> Bool = { false }
    package var openPlayerPanel: () -> Void = {}
    /// Показать «Мои снимки» в окне инструментов.
    package var showShotsLibrary: () -> Void = {}

    /// Записать готовый снимок в «Мои снимки» (если они включены).
    package var addShot: (_ url: URL, _ image: CGImage, _ app: String) -> Void = { _, _, _ in }

    /// Запись экрана идёт: обновить, какие окна в неё попадают (после появления или исчезновения рисунков).
    package var refreshRecordingFilter: () -> Void = {}

    private init() {}
}
