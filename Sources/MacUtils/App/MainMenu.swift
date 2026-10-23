import AppKit
import MUCore
import MUUpdate

/// Строка меню у LSUIElement-приложения не видна, но главное меню всё равно
/// нужно: через него работают ⌘W, ⌘Q и правка текста (⌘C/⌘V) в окне настроек.
@MainActor
enum MainMenu {
    private static let actions = MainMenuActions()

    static func install() {
        NSApp.mainMenu = build()
    }

    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "О программе Mac Utils", action: #selector(MainMenuActions.about), keyEquivalent: "")
        about.target = actions
        let updates = appMenu.addItem(withTitle: "Проверить обновления…", action: #selector(MainMenuActions.checkUpdates), keyEquivalent: "")
        updates.target = actions
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Настройки…", action: #selector(MainMenuActions.settings), keyEquivalent: ",")
        settings.target = actions
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Выйти из Mac Utils", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        EditorMenus.addEditItems(to: editMenu)
        editItem.submenu = editMenu
        // «Файл» — перед «Правкой», остальные меню редактора — после неё (видны, пока открыт редактор).
        main.insertItem(EditorMenus.file(), at: 1)
        main.addItem(editItem)
        for item in EditorMenus.trailing() { main.addItem(item) }

        return main
    }
}

@MainActor
private final class MainMenuActions: NSObject {
    @objc func about() {
        ScreenOutput.activateApp()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc func checkUpdates() {
        SettingsWindowController.shared.show(section: .general)
        Updater.shared.check(install: false, userInitiated: true)
    }

    @objc func settings() { SettingsWindowController.shared.show() }
}
