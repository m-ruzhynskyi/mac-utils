import AppKit
import Foundation

/// Программа, которую «Скрытый экран» уводит на невидимый экран.
package struct HiddenScreenApp: Identifiable, Equatable {
    package let bundleID: String
    package var name: String
    /// Сколько её окон сейчас на скрытом экране.
    package var windowCount: Int

    package var id: String { bundleID }

    package init(bundleID: String, name: String, windowCount: Int = 0) {
        self.bundleID = bundleID
        self.name = name
        self.windowCount = windowCount
    }
}

/// Всё, что нужно показать в интерфейсе. Движок отдаёт только факты, тексты собирает интерфейс (`HiddenScreenRules`).
package struct HiddenScreenState: Equatable {
    package var isEnabled: Bool
    package var apps: [HiddenScreenApp]
    /// Окно-зеркало сейчас на экране.
    package var mirrorShown: Bool
    /// Программа, показанная в зеркале (`bundleID`).
    package var activeApp: String?
    /// Результат проверки движка: окна правда не видны в демонстрации экрана. nil — ещё не проверяли.
    package var hidingVerified: Bool?

    package init(isEnabled: Bool = false, apps: [HiddenScreenApp] = [], mirrorShown: Bool = false,
                 activeApp: String? = nil, hidingVerified: Bool? = nil) {
        self.isEnabled = isEnabled
        self.apps = apps
        self.mirrorShown = mirrorShown
        self.activeApp = activeApp
        self.hidingVerified = hidingVerified
    }

    package var totalWindows: Int { apps.reduce(0) { $0 + $1.windowCount } }
}

/// Граница между интерфейсом «Скрытого экрана» и движком (MU · Connection, `MUHiddenScreen`).
/// Интерфейс только читает `state` и зовёт команды; всё остальное — дело движка. Подробности — `.audit/hidden-screen-contract.md`.
@MainActor
package protocol HiddenScreenControlling: AnyObject {
    var state: HiddenScreenState { get }
    /// Движок зовёт после любого изменения `state`.
    var onChange: (() -> Void)? { get set }
    /// Рамка окна-зеркала на экране (для полоски над ним); nil — зеркала нет.
    var mirrorFrame: CGRect? { get }
    /// Окно-зеркало: полоска цепляется к нему дочерним окном и двигает его за пустое место; nil — зеркала нет.
    var mirrorHostWindow: NSWindow? { get }

    func setEnabled(_ enabled: Bool)
    /// Показать или спрятать окно-зеркало.
    func setMirrorShown(_ shown: Bool)
    func selectApp(_ bundleID: String)
    func addApp(bundleID: String, name: String)
    func removeApp(_ bundleID: String)
    /// Вернуть все окна на обычный экран, туда, где они были.
    func returnAllWindows()
}

/// Заглушка для снимков и тестов: хранит всё в памяти и ничего не трогает в системе.
@MainActor
package final class StubHiddenScreenController: HiddenScreenControlling {
    package private(set) var state: HiddenScreenState { didSet { onChange?() } }
    package var onChange: (() -> Void)?
    package var mirrorFrame: CGRect?
    package var mirrorHostWindow: NSWindow?
    package private(set) var calls: [String] = []

    package init(_ state: HiddenScreenState = .demo, mirrorFrame: CGRect? = nil) {
        self.state = state
        self.mirrorFrame = mirrorFrame
    }

    package func setEnabled(_ enabled: Bool) { calls.append("enabled:\(enabled)"); state.isEnabled = enabled }
    package func setMirrorShown(_ shown: Bool) { calls.append("mirror:\(shown)"); state.mirrorShown = shown }
    package func selectApp(_ bundleID: String) { calls.append("select:\(bundleID)"); state.activeApp = bundleID }
    package func addApp(bundleID: String, name: String) {
        calls.append("add:\(bundleID)")
        guard !state.apps.contains(where: { $0.bundleID == bundleID }) else { return }
        state.apps.append(HiddenScreenApp(bundleID: bundleID, name: name))
    }
    package func removeApp(_ bundleID: String) {
        calls.append("remove:\(bundleID)")
        state.apps.removeAll { $0.bundleID == bundleID }
        if state.activeApp == bundleID { state.activeApp = state.apps.first?.bundleID }
    }
    package func returnAllWindows() {
        calls.append("returnAll")
        state.isEnabled = false
        state.mirrorShown = false
        for i in state.apps.indices { state.apps[i].windowCount = 0 }
    }
}

extension HiddenScreenState {
    /// Состояние из макета: Claude (2 окна) и ChatGPT (1 окно).
    package static let demo = HiddenScreenState(
        isEnabled: true,
        apps: [HiddenScreenApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude", windowCount: 2),
               HiddenScreenApp(bundleID: "com.openai.chat", name: "ChatGPT", windowCount: 1)],
        mirrorShown: true, activeApp: "com.anthropic.claudefordesktop", hidingVerified: true)
}
