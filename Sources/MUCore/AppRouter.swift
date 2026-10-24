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

    private init() {}
}
