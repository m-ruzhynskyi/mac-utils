import Foundation

/// Точка входа интерфейса: движок подставляет сюда своё управление при запуске, до этого работает заглушка.
@MainActor
package enum HiddenScreenUI {
    package static var controller: HiddenScreenControlling = StubHiddenScreenController(HiddenScreenState())

    /// Включённость «Окна ИИ поверх всех окон» хранит интерфейс (движок читает тот же ключ).
    package static let alwaysOnTopKey = "hiddenScreenAlwaysOnTop"
}
