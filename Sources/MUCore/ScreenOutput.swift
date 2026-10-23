import AppKit

/// Где запущен код: в приложении или в тестах (`swift test`, Xcode).
package enum AppEnvironment {
    /// Тестовый процесс: XCTest загружен (у приложения его нет) или Xcode передал конфигурацию тестов.
    package static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}

/// Всё, что выходит на экран и в динамики: показ окон и панелей, активация приложения, звук.
/// Под тестами ничего из этого не происходит — окна создаются и настраиваются как обычно (рамка, содержимое, модель),
/// но не выводятся поверх экрана пользователя, звука нет; в журнал — «скрыто тестом». Прямые `orderFront…`,
/// `makeKeyAndOrderFront`, `NSApp.activate`, `NSSound.beep` и `NSSound(named:)` в коде не используются (проверяет ScreenOutputTests).
@MainActor
package enum ScreenOutput {
    /// Сколько показов окон, активаций и звуков не состоялось под тестами (для тестов-сторожей).
    package private(set) static var suppressedWindows = 0
    package private(set) static var suppressedSounds = 0

    /// Можно ли показать `what` на экране; под тестами — нет (и строка в журнал).
    package static func mayShow(_ what: String) -> Bool {
        guard AppEnvironment.isRunningTests else { return true }
        suppressedWindows += 1
        Log.window.info("\(what, privacy: .public): скрыто тестом")
        return false
    }

    /// Вывести приложение на передний план (окно настроек, вопрос, окно редактора).
    package static func activateApp(ignoringOtherApps: Bool = false, _ file: StaticString = #fileID) {
        guard mayShow("Активация (\(file))") else { return }
        if ignoringOtherApps { NSApp.activate(ignoringOtherApps: true) } else { NSApp.activate() }
    }

    /// Звуковой сигнал «нельзя» / «не найдено».
    package static func beep() {
        guard !AppEnvironment.isRunningTests else {
            suppressedSounds += 1
            return
        }
        NSSound.beep()
    }

    /// Системный звук по имени («Ping», «Glass»).
    package static func play(_ name: String) {
        guard !AppEnvironment.isRunningTests else {
            suppressedSounds += 1
            return
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// Короткий звуковой сигнал (как `NSSound.beep()`), под тестами — тишина.
@MainActor
package enum Feedback {
    package static func beep() { ScreenOutput.beep() }
    package static func play(_ name: String) { ScreenOutput.play(name) }
}

extension NSWindow {
    /// `orderFrontRegardless()`, кроме тестов.
    package func orderFrontRegardlessOnScreen(_ what: String? = nil, _ file: StaticString = #fileID) {
        guard ScreenOutput.mayShow(what ?? "Окно (\(file))") else { return }
        orderFrontRegardless()
    }

    /// `makeKeyAndOrderFront(nil)`, кроме тестов.
    package func makeKeyAndOrderFrontOnScreen(_ what: String? = nil, _ file: StaticString = #fileID) {
        guard ScreenOutput.mayShow(what ?? "Окно (\(file))") else { return }
        makeKeyAndOrderFront(nil)
    }

    /// `orderFront(nil)`, кроме тестов.
    package func orderFrontOnScreen(_ what: String? = nil, _ file: StaticString = #fileID) {
        guard ScreenOutput.mayShow(what ?? "Окно (\(file))") else { return }
        orderFront(nil)
    }
}
