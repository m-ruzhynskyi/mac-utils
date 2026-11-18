import AppKit
import MUCore
import MUHiddenScreen

/// Связка «Скрытого экрана» с приложением: сочетания, полоска над окном-зеркалом и раздел меню.
/// Сам движок подставляет управление в `HiddenScreenUI.controller`; до него работает заглушка.
@MainActor
final class HiddenScreenGlue {
    static let shared = HiddenScreenGlue()
    private var strip: MirrorStripController?
    private var menuBuilder: HiddenScreenMenuBuilder?

    private var controller: HiddenScreenControlling { HiddenScreenUI.controller }

    /// Сколько раз создавалась полоска (для проверки: подписка одна, сколько бы раз ни звали `sync`).
    private(set) var stripCreations = 0
    private var connectedController: HiddenScreenControlling?

    /// Вызывается из `syncFeatures` при каждом изменении настроек: сочетания регистрируются заново (безопасно — Carbon не
    /// трогается, если сочетание не менялось), а подписка на движок и полоска — один раз на управление.
    func sync() {
        registerHotKeys()
        connect()
    }

    func registerHotKeys() {
        // То же действие, что у «Команд» и ссылок (`AppAction`), — как у остальных сочетаний (ShortcutsTests).
        register(.hiddenScreen) { AppAction(hotKey: .hiddenScreen).run() }
        register(.hiddenScreenWindow) { AppAction(hotKey: .hiddenScreenWindow).run() }
    }

    /// Подписывается на изменения движка и ставит полоску. Повторный вызов с тем же управлением ничего не делает;
    /// если управление подменили, прежняя полоска убирается и всё подключается заново.
    func connect() {
        let controller = self.controller
        if let connected = connectedController, connected === controller { return }
        strip?.hide()
        let strip = MirrorStripController(controller)
        stripCreations += 1
        self.strip = strip
        connectedController = controller
        let previous = controller.onChange
        controller.onChange = { previous?(); strip.refresh() }
        strip.refresh()
    }

    private func register(_ action: HotKeyAction, run: @escaping () -> Void) {
        let combo = HotKeyRegistry.combo(for: action)
        _ = HotKeyCenter.shared.register(id: action.hotKeyID, keyCode: combo.keyCode, modifiers: combo.modifiers, handler: run)
    }

    /// Пункты раздела для меню значка.
    func menuItems() -> [NSMenuItem] {
        let builder = HiddenScreenMenuBuilder(controller: controller) {
            HiddenScreenAppPicker.choose { [weak self] in self?.controller.addApp(bundleID: $0.bundleID, name: $0.name) }
        }
        menuBuilder = builder
        return builder.items(toggleKey: HotKeyRegistry.combo(for: .hiddenScreen),
                             windowKey: HotKeyRegistry.combo(for: .hiddenScreenWindow))
    }
}
