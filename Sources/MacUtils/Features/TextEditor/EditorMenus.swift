import AppKit

/// Меню текстового редактора в строке меню: «Файл / Правка / Поиск / Вид / Кодировка / Синтаксис».
/// Пункты, которым нужна вкладка, идут по цепочке ответчиков к `EditorWindowController` (делегат окна редактора)
/// и недоступны в других окнах; «Новый», «Открыть» и «Недавние» открывают редактор откуда угодно.
@MainActor
enum EditorMenus {
    private static let actions = EditorMenuActions()
    private typealias C = EditorWindowController

    private static func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                             tag: Int = 0, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        item.target = target
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for child in items { menu.addItem(child) }
        item.submenu = menu
        return item
    }

    private static func key(_ function: Int) -> String { String(Character(UnicodeScalar(UInt16(function))!)) }

    static func file() -> NSMenuItem {
        let recent = NSMenuItem(title: "Открыть недавние", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Открыть недавние")
        recentMenu.delegate = actions
        recent.submenu = recentMenu
        return submenu("Файл", [
            item("Новый документ", #selector(EditorMenuActions.newDocument), "n", target: actions),
            item("Открыть…", #selector(EditorMenuActions.open), "o", target: actions),
            recent,
            .separator(),
            item("Сохранить", #selector(C.editorSave(_:)), "s"),
            item("Сохранить как…", #selector(C.editorSaveAs(_:)), "s", [.command, .shift]),
            .separator(),
            item("Закрыть вкладку", #selector(C.editorCloseTab(_:)), "w"),
        ])
    }

    static func addEditItems(to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(item("Дублировать строку", #selector(C.editorDuplicateLine(_:)), "d"))
        menu.addItem(item("Удалить строку", #selector(C.editorDeleteLine(_:)), "k", [.command, .shift]))
        menu.addItem(item("Строку вверх", #selector(C.editorMoveLineUp(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), .option))
        menu.addItem(item("Строку вниз", #selector(C.editorMoveLineDown(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), .option))
        menu.addItem(submenu("Регистр", [
            item("ВЕРХНИЙ РЕГИСТР", #selector(C.editorUppercase(_:)), "u", [.command, .shift]),
            item("нижний регистр", #selector(C.editorLowercase(_:)), "u", [.command, .shift, .option]),
            item("Как в предложении", #selector(C.editorSentenceCase(_:))),
        ]))
        menu.addItem(item("Удалить хвостовые пробелы", #selector(C.editorTrimTrailing(_:))))
        menu.addItem(item("Добавить курсор выше", #selector(C.editorAddCaretAbove(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
                          [.control, .shift]))
        menu.addItem(item("Добавить курсор ниже", #selector(C.editorAddCaretBelow(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
                          [.control, .shift]))
        menu.addItem(submenu("Строки", [
            item("Сортировать А → Я", #selector(C.editorSortAscending(_:))),
            item("Сортировать Я → А", #selector(C.editorSortDescending(_:))),
            item("Сортировать без учёта регистра", #selector(C.editorSortCaseInsensitive(_:))),
            .separator(),
            item("Удалить повторы", #selector(C.editorRemoveDuplicates(_:))),
            item("Удалить повторы без учёта регистра", #selector(C.editorRemoveDuplicatesCaseInsensitive(_:))),
            .separator(),
            item("Табы → пробелы", #selector(C.editorTabsToSpaces(_:))),
            item("Пробелы → табы", #selector(C.editorSpacesToTabs(_:))),
        ]))
        menu.addItem(.separator())
        menu.addItem(item("Убрать значения $", #selector(C.editorRemoveValues(_:))))
    }

    static func trailing() -> [NSMenuItem] {
        let reopen = TextEncoding.Group.allCases.flatMap { group -> [NSMenuItem] in
            [NSMenuItem.sectionHeader(title: group.title)] + TextEncoding.allCases.enumerated().filter { $0.element.group == group }.map {
                item($0.element.title, #selector(C.editorReopen(_:)), tag: $0.offset)
            }
        }
        let convert = TextEncoding.Group.allCases.flatMap { group -> [NSMenuItem] in
            [NSMenuItem.sectionHeader(title: group.title)] + TextEncoding.allCases.enumerated().filter { $0.element.group == group }.map {
                item($0.element.title, #selector(C.editorConvert(_:)), tag: $0.offset)
            }
        }
        return [
            submenu("Поиск", [
                item("Найти…", #selector(C.editorFind(_:)), "f"),
                item("Найти и заменить…", #selector(C.editorReplace(_:)), "f", [.command, .option]),
                item("Найти далее", #selector(C.editorFindNext(_:)), "g"),
                item("Найти ранее", #selector(C.editorFindPrevious(_:)), "g", [.command, .shift]),
                item("Найти в папке…", #selector(C.editorFindInFolder(_:)), "f", [.command, .shift]),
                .separator(),
                item("Перейти к строке…", #selector(C.editorGoToLine(_:)), "l"),
                .separator(),
                submenu("Закладки", [
                    item("Поставить или снять", #selector(C.editorToggleBookmark(_:)), Self.key(NSF2FunctionKey)),
                    item("Следующая", #selector(C.editorNextBookmark(_:)), Self.key(NSF2FunctionKey), []),
                    item("Предыдущая", #selector(C.editorPreviousBookmark(_:)), Self.key(NSF2FunctionKey), .shift),
                    .separator(),
                    item("Удалить все закладки", #selector(C.editorClearBookmarks(_:))),
                ]),
            ]),
            submenu("Вид", [
                item("Код", #selector(C.editorShowCode(_:))),
                item("Документ", #selector(C.editorToggleDocument(_:)), "d", [.command, .shift]),
                .separator(),
                item("Перенос строк", #selector(C.editorToggleWrap(_:))),
                item("Невидимые символы", #selector(C.editorToggleInvisibles(_:)), "i", [.command, .option]),
                item("Парные скобки", #selector(C.editorToggleBrackets(_:))),
                .separator(),
                item("Крупнее", #selector(C.editorZoomIn(_:)), "="),
                item("Мельче", #selector(C.editorZoomOut(_:)), "-"),
                item("Обычный размер", #selector(C.editorZoomReset(_:)), "0"),
                .separator(),
                item("Панель «Знаки $»", #selector(C.editorToggleDollarPanel(_:)), "4", [.command, .option]),
                .separator(),
                item("Следующая вкладка", #selector(C.editorNextTab(_:)), "]", [.command, .shift]),
                item("Предыдущая вкладка", #selector(C.editorPreviousTab(_:)), "[", [.command, .shift]),
            ]),
            submenu("Кодировка", [
                submenu("Открыть заново в", reopen),
                submenu("Преобразовать в", convert),
                .separator(),
                NSMenuItem.sectionHeader(title: "Перевод строки"),
            ] + LineEnding.allCases.enumerated().map {
                item("\($0.element.title) — \($0.element.detail)", #selector(C.editorLineEnding(_:)), tag: $0.offset)
            }),
            submenu("Синтаксис", EditorLanguage.allCases.enumerated().map {
                item($0.element.title, #selector(C.editorLanguage(_:)), tag: $0.offset)
            }),
        ]
    }
}

@MainActor
private final class EditorMenuActions: NSObject, NSMenuDelegate, NSMenuItemValidation {
    @objc func newDocument() { EditorWindowController.shared.newDocument() }
    @objc func open() { EditorWindowController.shared.openPanel() }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Файла больше нет — убираем из списка.
            EditorRecent.remove(url)
            Feedback.beep()
            return
        }
        EditorWindowController.shared.open([url])
    }

    @objc func clearRecent() { EditorRecent.clear() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(clearRecent) ? !EditorRecent.paths.isEmpty : true
    }

    /// «Открыть недавние» собирается при каждом открытии: несуществующие файлы — серым.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in EditorRecent.urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            if !FileManager.default.fileExists(atPath: url.path) {
                item.attributedTitle = NSAttributedString(string: url.lastPathComponent + " — файл не найден",
                                                          attributes: [.foregroundColor: NSColor.disabledControlTextColor])
            }
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Очистить меню", action: #selector(clearRecent), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }
}
