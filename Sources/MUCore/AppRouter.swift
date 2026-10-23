import Foundation

/// Связь функций с приложением без прямых вызовов: функция просит действие по идентификатору горячей клавиши,
/// а что оно делает, решает приложение (подставляет при запуске).
@MainActor
package final class AppRouter {
    package static let shared = AppRouter()

    /// Выполнить то же, что нажатие горячей клавиши `HotKeyID.…` (из меню, панели, ссылки).
    package var runHotKey: (UInt32) -> Void = { _ in }

    private init() {}
}
