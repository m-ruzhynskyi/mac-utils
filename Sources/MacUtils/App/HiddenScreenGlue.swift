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

    /// Вызывается при запуске и после смены управления: регистрирует сочетания и подписывается на изменения.
    func sync() {
        let center = HotKeyCenter.shared
        for action in [HotKeyAction.hiddenScreen, .hiddenScreenWindow] {
            let combo = HotKeyRegistry.combo(for: action)
            center.register(id: action.hotKeyID, keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
                guard let self else { return }
                if action == .hiddenScreen { self.controller.setEnabled(!self.controller.state.isEnabled) }
                else { self.controller.setMirrorShown(!self.controller.state.mirrorShown) }
            }
        }
        let strip = MirrorStripController(controller)
        self.strip = strip
        let previous = controller.onChange
        controller.onChange = { previous?(); strip.refresh() }
        strip.refresh()
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
