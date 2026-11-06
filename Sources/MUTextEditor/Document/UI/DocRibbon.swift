import SwiftUI
import MUCore
import MUDesign

// R1 (`.audit/plan-word-ui.md`): лента «Документа» вместо полосы `DocFormatBar` — «Главная», «Вставка», «Макет», «Вид» и
// контекстные синие «Таблица» (курсор в таблице) и «Колонтитулы» (правка колонтитула). Двойной щелчок по вкладке сворачивает
// ленту до строки вкладок, щелчок по вкладке — разворачивает. Запоминается только ключ обычной вкладки (`Pref.editorRibbonTab`).
// На вкладках — только то, что уже работает: нереализованные кнопки не показываются (и не серые).

/// Вкладка ленты.
package enum DocRibbonTab: String, CaseIterable {
    case home, insert, layout, view, table, header

    package var title: String {
        switch self {
        case .home: return "Главная"
        case .insert: return "Вставка"
        case .layout: return "Макет"
        case .view: return "Вид"
        case .table: return "Таблица"
        case .header: return "Колонтитулы"
        }
    }

    package var contextual: Bool { self == .table || self == .header }

    package static let base: [DocRibbonTab] = [.home, .insert, .layout, .view]

    /// Вкладки ленты: обычные и контекстные, когда они к месту.
    package static func visible(inTable: Bool, editingHeader: Bool) -> [DocRibbonTab] {
        base + (inTable && !editingHeader ? [.table] : []) + (editingHeader ? [.header] : [])
    }

    /// Какая вкладка показана: выбранная контекстная (пока она к месту), иначе запомненная обычная.
    package static func shown(stored: String, contextual: DocRibbonTab?, inTable: Bool, editingHeader: Bool) -> DocRibbonTab {
        if let contextual, visible(inTable: inTable, editingHeader: editingHeader).contains(contextual) { return contextual }
        let tab = DocRibbonTab(rawValue: stored) ?? .home
        return base.contains(tab) ? tab : .home
    }
}

/// Лента: вкладки и полоса групп показанной вкладки. «Главную» строит владелец (`DocFormatBar`) по уровню ужатия 0–5.
package struct DocRibbon<Home: View>: View {
    @ObservedObject package var tab: EditorTab
    @ObservedObject package var document: DocumentController
    @ObservedObject package var formatter: DocFormatter
    @ViewBuilder package let home: (_ level: Int) -> Home
    @AppStorage(Pref.editorRibbonTab) private var stored = DocRibbonTab.home.rawValue
    @State private var contextual: DocRibbonTab?
    @State private var collapsed = false

    /// `contextual` — открыть сразу на контекстной вкладке (снимок «Таблицы»); в окне — `nil`.
    package init(tab: EditorTab, document: DocumentController, formatter: DocFormatter, contextual: DocRibbonTab? = nil,
                 @ViewBuilder home: @escaping (_ level: Int) -> Home) {
        self.tab = tab
        self.document = document
        self.formatter = formatter
        self.home = home
        _contextual = State(initialValue: contextual)
    }

    private var editingHeader: Bool { formatter.headerSession != nil }
    private var shown: DocRibbonTab {
        DocRibbonTab.shown(stored: stored, contextual: contextual, inTable: formatter.state.inTable, editingHeader: editingHeader)
    }

    package var body: some View {
        let tabs = DocRibbonTab.visible(inTable: formatter.state.inTable, editingHeader: editingHeader)
            .map { DS.RibbonTabItem($0.rawValue, $0.title, contextual: $0.contextual) }
        let selection = Binding<String>(get: { shown.rawValue }, set: { id in
            collapsed = false
            guard let picked = DocRibbonTab(rawValue: id) else { return }
            if picked.contextual { contextual = picked } else { contextual = nil; stored = picked.rawValue }
        })
        DS.Ribbon(tabs: tabs, selection: selection, collapsed: collapsed, scrolls: shown != .home,
                  onDoubleClick: { collapsed.toggle() }) {
            switch shown {
            case .home:
                // Первый уровень, который помещается (как у прежней полосы: 0 — всё, 5 — самое узкое окно).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) { home(0) }
                    HStack(alignment: .top, spacing: 0) { home(1) }
                    HStack(alignment: .top, spacing: 0) { home(2) }
                    HStack(alignment: .top, spacing: 0) { home(3) }
                    HStack(alignment: .top, spacing: 0) { home(4) }
                    HStack(alignment: .top, spacing: 0) { home(5) }
                }
            case .insert: DocRibbonInsert(document: document, formatter: formatter, table: document.tableContext, insert: document.insertContext)
            case .layout: DocRibbonLayout(document: document, formatter: formatter)
            case .view: DocRibbonViewTab(document: document)
            case .table: DocRibbonTable(document: document, context: document.tableContext)
            case .header: DocHeaderFooterGroups(formatter: formatter)
            }
        }
        // Правка колонтитула открылась — сразу его вкладка (как в Word); закрылась — назад к обычной.
        .onChange(of: editingHeader) { _, editing in
            if editing { contextual = .header; collapsed = false } else if contextual == .header { contextual = nil }
        }
        .onChange(of: formatter.state.inTable) { _, inTable in
            if !inTable, contextual == .table { contextual = nil }
        }
    }
}

// MARK: - Вставка

/// «Вставка»: таблица (размер из списка), разрыв страницы, колонтитулы текущей страницы, обновить поля.
package struct DocRibbonInsert: View {
    @ObservedObject package var document: DocumentController
    @ObservedObject package var formatter: DocFormatter
    /// Место курсора — значениями от ленты (см. `DocRibbonTable.context`): для таблицы и для команд вставки (R3).
    package let table: TableCommand.Context
    package let insert: InsertCommand.Context

    package static let tableSizes = [(2, 2), (3, 2), (3, 3), (4, 3), (4, 4), (5, 2)]

    /// Поля из меню «Поле» и символы из меню «Символ» — по порядку `InsertCommand.catalog`, только видимые здесь.
    package static func fields(in context: InsertCommand.Context) -> [InsertCommand] {
        InsertCommand.visible(in: context).filter { if case .field = $0 { return true } else { return false } }
    }

    package static func symbols(in context: InsertCommand.Context) -> [InsertCommand] {
        InsertCommand.visible(in: context).filter { if case .symbol = $0 { return true } else { return false } }
    }

    package var body: some View {
        // Таблица в таблице не вставляется: `TableCommand` прячет команду, пока курсор в ячейке.
        if TableCommand.insertTable.availability(in: table).isVisible {
            DS.RibbonGroup("Таблица") {
                DS.RibbonMenuButton("Вставить таблицу после абзаца у курсора", systemImage: "tablecells", glyph: "Таблица", size: .large) {
                    ForEach(Array(Self.tableSizes.enumerated()), id: \.offset) { _, size in
                        Button("\(size.0) × \(size.1)") { document.perform(.insertTable, rows: size.1, columns: size.0) }
                    }
                }
            }
        }
        let visible = InsertCommand.visible(in: insert)
        if visible.contains(.pageBreak) {
            DS.RibbonGroup("Разрывы") {
                button(.pageBreak, "doc.badge.plus", "Разрыв страницы", shortcut: "⌘↩")
            }
        }
        DS.RibbonGroup("Колонтитулы") {
            DS.RibbonButton("Верхний колонтитул этой страницы", systemImage: "rectangle.topthird.inset.filled", glyph: "Верхний",
                            size: .large) { editHeader(true) }
            DS.RibbonButton("Нижний колонтитул этой страницы", systemImage: "rectangle.bottomthird.inset.filled", glyph: "Нижний",
                            size: .large) { editHeader(false) }
        }
        DS.RibbonGroup("Поля") {
            if visible.contains(.pageNumber) { button(.pageNumber, "number", "Номер страницы") }
            menu("Поле", "Вставить поле: число страниц, страниц в разделе, «Стр. X из Y»", "curlybraces", Self.fields(in: insert))
            DS.RibbonButton("Обновить поля: номера страниц, дата, время", systemImage: "arrow.clockwise", glyph: "Обновить",
                            size: .large, shortcut: "F9") { formatter.updateFields() }
        }
        DS.RibbonGroup("Символы", last: true) {
            menu("Символ", "Вставить символ: ©, №, §, тире, кавычки, неразрывный пробел…", "character", Self.symbols(in: insert))
        }
    }

    /// Кнопка команды: недоступная — серая, причина в подсказке (как у «Таблицы»).
    private func button(_ command: InsertCommand, _ image: String, _ glyph: String, shortcut: String? = nil) -> some View {
        let availability = command.availability(in: insert)
        return DS.RibbonButton(Self.tip(command, availability), systemImage: image, glyph: glyph, size: .large, shortcut: shortcut) {
            document.perform(command)
        }
        .disabled(!availability.isEnabled)
    }

    /// Меню команд одного вида; ни одна не доступна — меню серое, причина первой — в подсказке.
    @ViewBuilder
    private func menu(_ glyph: String, _ title: String, _ image: String, _ commands: [InsertCommand]) -> some View {
        if !commands.isEmpty {
            let refusal = commands.allSatisfy { !$0.availability(in: insert).isEnabled } ? commands.first.map { Self.tip($0, $0.availability(in: insert)) } : nil
            DS.RibbonMenuButton(refusal ?? title, systemImage: image, glyph: glyph, size: .large) {
                ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                    Button(Self.menuTitle(command)) { document.perform(command) }.disabled(!command.availability(in: insert).isEnabled)
                }
            }
            .disabled(refusal != nil)
        }
    }

    /// Пункт меню: у символа — сам символ и его название.
    package static func menuTitle(_ command: InsertCommand) -> String {
        if case .symbol(let text) = command { return text == "\u{00A0}" ? command.title : "\(text)  \(command.title.replacingOccurrences(of: "Символ ", with: ""))" }
        return command.title
    }

    /// Подсказка: название команды, у недоступной — и почему.
    package static func tip(_ command: InsertCommand, _ availability: InsertCommand.Availability) -> String {
        if case .disabled(let reason) = availability { return "\(command.title) — \(reason)" }
        return command.title
    }

    private func editHeader(_ header: Bool) {
        guard let page = document.pagesView.pages[safe: document.currentPage - 1] ?? document.pagesView.pages.first else { return }
        formatter.beginHeaderEditing(page: page, header: header)
    }
}

// MARK: - Макет

/// «Макет»: разрыв страницы, положение абзаца на странице (`\keepn`, `\keep`, `\pagebb`), отступы и интервалы.
package struct DocRibbonLayout: View {
    @ObservedObject package var document: DocumentController
    @ObservedObject package var formatter: DocFormatter

    package var body: some View {
        DocPageSetupGroup(document: document, formatter: formatter)
        DS.RibbonGroup("Разрывы") {
            DS.RibbonButton("Разрыв страницы", systemImage: "doc.badge.plus", glyph: "Страница", size: .large, shortcut: "⌘↩") {
                formatter.insertPageBreak()
            }
        }
        // Две строки, как у остальных групп: третья строка подняла бы ленту выше, чем на других вкладках.
        DS.RibbonGroup("Положение на странице") {
            let flags = DocParaFlag.allCases
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                ForEach(Array(stride(from: 0, to: flags.count, by: 2)), id: \.self) { start in
                    HStack(spacing: DS.Space.xxs) {
                        ForEach(flags[start..<min(start + 2, flags.count)], id: \.self) { flag in
                            DS.RibbonButton(flag.title, glyph: flag.title, isOn: formatter.state.paragraph.map(flag.value) ?? false) {
                                formatter.toggle(flag)
                            }
                        }
                    }
                }
            }
        }
        DS.RibbonGroup("Абзац", last: true) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xxs) {
                    DS.RibbonButton("Уменьшить отступ", systemImage: "decrease.indent") { formatter.stepIndent(-1) }
                    DS.RibbonButton("Увеличить отступ", systemImage: "increase.indent") { formatter.stepIndent(1) }
                }
                DS.RibbonMenuButton("Междустрочный интервал", systemImage: "arrow.up.and.down.text.horizontal", glyph: "Интервал") {
                    ForEach([1.0, 1.15, 1.5, 2.0], id: \.self) { multiple in
                        Button(DocRibbonLayout.title(multiple)) { formatter.setLineSpacing(multiple) }
                    }
                }
            }
        }
    }

    package static func title(_ multiple: Double) -> String {
        String(format: "%.2f", multiple).replacingOccurrences(of: "0$", with: "", options: .regularExpression)
            .replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Вид

/// «Вид»: знаки ¶ и масштаб (шаги Word, 100 %, по ширине, страница целиком).
package struct DocRibbonViewTab: View {
    @ObservedObject package var document: DocumentController

    package var body: some View {
        DS.RibbonGroup("Показать") {
            DS.RibbonButton("Невидимые символы", systemImage: "paragraphsign", glyph: "Знаки ¶", size: .large,
                            isOn: document.showsInvisibles, shortcut: "⌥⌘I") {
                EditorWindowController.shared.workspace.showsInvisibles.toggle()
            }
        }
        DS.RibbonGroup("Масштаб", last: true) {
            DS.RibbonButton("Уменьшить масштаб", systemImage: "minus.magnifyingglass", shortcut: "⌘−") { document.step(zoom: -1) }
            DS.RibbonButton("Масштаб 100 %", glyph: "100 %", isOn: document.fit == .none && abs(document.zoom - 1) < 0.001, shortcut: "⌘0") {
                document.fit = .none
                document.zoom = 1
            }
            DS.RibbonButton("Увеличить масштаб", systemImage: "plus.magnifyingglass", shortcut: "⌘+") { document.step(zoom: 1) }
            DS.RibbonButton("По ширине окна", systemImage: "arrow.left.and.right", glyph: "По ширине", size: .large,
                            isOn: document.fit == .width) { document.fit = .width }
            DS.RibbonButton("Страница целиком", systemImage: "doc", glyph: "Страница", size: .large, isOn: document.fit == .page) {
                document.fit = .page
            }
        }
    }
}

// MARK: - Таблица (контекстная)

/// Контекстная «Таблица»: строки и столбцы, объединение, границы, заливка — команды E-1/E-3, как в меню правого щелчка.
package struct DocRibbonTable: View {
    @ObservedObject package var document: DocumentController
    /// Место курсора — значением от ленты, чтобы вкладка перерисовывалась при каждом сдвиге курсора.
    package let context: TableCommand.Context

    package static let shades: [(String, RTFColor?)] = [
        ("Без заливки", nil), ("Серая", RTFColor(red: 217, green: 217, blue: 217)), ("Жёлтая", RTFColor(red: 255, green: 242, blue: 204)),
        ("Голубая", RTFColor(red: 222, green: 234, blue: 246)), ("Зелёная", RTFColor(red: 226, green: 239, blue: 217)),
    ]

    /// Команды, у которых на вкладке есть кнопка или пункт меню (порядок ленты); вставка таблицы — на «Вставке».
    package static let laidOut: [TableCommand] = [.rowAbove, .rowBelow, .columnLeft, .columnRight, .deleteRow, .deleteColumn,
                                                  .merge, .split, .bordersAll, .bordersOuter, .bordersNone, .shading]

    /// Команды вкладки — ровно те, что `TableCommand.visible` даёт в этом месте (вставка таблицы — на «Вставке»).
    package static func commands(in context: TableCommand.Context) -> [TableCommand] {
        TableCommand.visible(in: context).filter { $0 != .insertTable }
    }

    package var body: some View {
        let shown = Set(Self.commands(in: context))
        DS.RibbonGroup("Строки и столбцы") {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xxs) {
                    button(.rowAbove, "arrow.up.to.line", "Выше", context, shown)
                    button(.rowBelow, "arrow.down.to.line", "Ниже", context, shown)
                }
                HStack(spacing: DS.Space.xxs) {
                    button(.columnLeft, "arrow.left.to.line", "Слева", context, shown)
                    button(.columnRight, "arrow.right.to.line", "Справа", context, shown)
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                button(.deleteRow, "minus.rectangle", "Удалить строку", context, shown)
                button(.deleteColumn, "minus.square", "Удалить столбец", context, shown)
            }
        }
        DS.RibbonGroup("Объединение") {
            button(.merge, "rectangle.split.2x1", "Объединить", context, shown, size: .large)
            button(.split, "rectangle.split.3x1", "Разбить", context, shown, size: .large)
        }
        DS.RibbonGroup("Границы и заливка", last: true) {
            let borders: [TableCommand] = [.bordersAll, .bordersOuter, .bordersNone].filter(shown.contains)
            if !borders.isEmpty {
                DS.RibbonMenuButton("Границы ячеек", systemImage: "square.dashed", glyph: "Границы", size: .large) {
                    ForEach(borders, id: \.self) { command in
                        Button(command.title) { document.perform(command) }.disabled(!command.availability(in: context).isEnabled)
                    }
                }
            }
            if shown.contains(.shading) {
                DS.RibbonMenuButton("Заливка ячеек", systemImage: "paintbrush", glyph: "Заливка", size: .large) {
                    ForEach(Self.shades, id: \.0) { shade in Button(shade.0) { document.perform(.shading, color: shade.1) } }
                }
                .disabled(!TableCommand.shading.availability(in: context).isEnabled)
            }
        }
    }

    /// Кнопка команды: нет в `visible` — нет кнопки; `.disabled(причина)` — серая, причина в подсказке.
    @ViewBuilder
    private func button(_ command: TableCommand, _ image: String, _ glyph: String, _ context: TableCommand.Context,
                        _ shown: Set<TableCommand>, size: DS.RibbonButton.Size = .small) -> some View {
        if shown.contains(command) {
            let availability = command.availability(in: context)
            DS.RibbonButton(Self.tip(command, availability), systemImage: image, glyph: glyph, size: size) { document.perform(command) }
                .disabled(!availability.isEnabled)
        }
    }

    /// Подсказка: название команды, у недоступной — и почему.
    package static func tip(_ command: TableCommand, _ availability: TableCommand.Availability) -> String {
        if case .disabled(let reason) = availability { return "\(command.title) — \(reason)" }
        return command.title
    }
}
