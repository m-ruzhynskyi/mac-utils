import AppKit

/// Выход из приложения, безопасный из async-кода на главном акторе.
///
/// `NSApp.terminate`, вызванный прямо из задачи `@MainActor` (а это блок главной очереди GCD), при ответе
/// `.terminateLater` крутит вложенный цикл событий, который главную очередь не обслуживает: пока блок не вернётся,
/// CFRunLoop её не разбирает. Задачи штатного завершения (`Task { @MainActor … }`) и вообще всё на главном акторе
/// не выполняются, `reply(toApplicationShouldTerminate:)` не приходит, и приложение навсегда висит «на выходе»:
/// снимки, тосты, переподключение трансляции молча не работают (так было 30.10 после «Обновить и перезапустить»).
///
/// Блок цикла событий (`CFRunLoopPerformBlock`) выполняется вне главной очереди, поэтому вложенный цикл её разбирает —
/// как при выходе через ⌘Q или меню.
@MainActor
package enum AppTermination {
    /// Режимы, в которых блок выхода может выполниться (обычный и модальный — если открыт системный запрос).
    package static let modes: [RunLoop.Mode] = [.default, .modalPanel]

    /// Выполнить `action` следующим проходом главного цикла событий, вне главной очереди GCD.
    package static func onMainRunLoop(_ action: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: modes) {
            MainActor.assumeIsolated { action() }
        }
    }

    /// `NSApp.terminate(nil)`, отложенный за пределы текущей задачи или блока главной очереди.
    package static func terminate() {
        onMainRunLoop { NSApp.terminate(nil) }
    }
}
