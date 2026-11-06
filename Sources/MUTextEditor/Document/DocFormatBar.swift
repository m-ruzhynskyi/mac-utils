import SwiftUI
import MUDesign

/// Лента режима «Документ» (R1, `UI/DocRibbon.swift`) и линейка под ней. Здесь — «Главная» (R2): отмена и повтор, шрифт,
/// размер, Ж К Ч S, индексы, регистр «Aa», цвет текста и маркер, очистить формат; выравнивание, интервалы, отступы, ¶, «Ещё»;
/// «Найти» и «Заменить». На узком окне хвост уходит в «»» (уровни 0–5, `d06`). Сочетания клавиш работают на любой вкладке.
package struct DocFormatBar: View {
    @ObservedObject package var tab: EditorTab
    @ObservedObject package var document: DocumentController
    @ObservedObject package var formatter: DocFormatter
    @State private var fontsOpen = false
    @State private var colorOpen = false
    @State private var highlightOpen = false
    @State private var sizeText = ""
    @FocusState private var sizeFocused: Bool

    package init(tab: EditorTab, document: DocumentController) {
        self.tab = tab
        self.document = document
        formatter = DocFormatter.of(document)
    }

    private var state: DocFormatState { formatter.state }

    package var body: some View {
        VStack(spacing: 0) {
            // Колонка документа бывает узкой (рядом панель «$»): «Главная» берёт первый уровень, который помещается.
            DocRibbon(tab: tab, document: document, formatter: formatter) { level in home(level: level) }
                .background(shortcuts)
            FormatRuler(document: document, formatter: formatter)
                .frame(height: 26)
                .background(Color.dsSide)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 1) }
        }
        .onChange(of: state.halfPoints) { _, _ in if !sizeFocused { sizeText = Self.sizeTitle(state.halfPoints) } }
        .onAppear { sizeText = Self.sizeTitle(state.halfPoints) }
    }

    // MARK: - «Главная»

    /// Уровень ужатия: 0 — всё; 1 — «Очистить» и «Ещё» в «»», «Найти» мельче; 2 — и индексы с отступами; 3 — и зачёркнутый,
    /// регистр, маркер, интервалы; 4 — как узкое окно `d06`: отмена, шрифт и размер, Ж К Ч, цвет и ¶; 5 — ещё уже.
    @ViewBuilder
    private func home(level: Int) -> some View {
        DS.RibbonGroup("Буфер") {
            VStack(spacing: DS.Space.xxs) {
                DS.RibbonButton("Отменить", systemImage: "arrow.uturn.backward", shortcut: "⌘Z") { tab.undo.undo() }.disabled(!tab.undo.canUndo)
                if level < 5 {
                    DS.RibbonButton("Повторить", systemImage: "arrow.uturn.forward", shortcut: "⇧⌘Z") { tab.undo.redo() }.disabled(!tab.undo.canRedo)
                }
            }
        }
        DS.RibbonGroup("Шрифт") {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    fontButton(width: level >= 4 ? 104 : 150)
                    sizeControl
                }
                HStack(spacing: DS.Space.xxs) {
                    DS.RibbonButton("Полужирный", glyph: "Ж", isOn: state.bold, shortcut: "⌘B", action: formatter.toggleBold)
                    DS.RibbonButton("Курсив", glyph: "К", isOn: state.italic, shortcut: "⌘I", action: formatter.toggleItalic)
                    DS.RibbonButton("Подчёркнутый", glyph: "Ч", isOn: state.underline, shortcut: "⌘U", action: formatter.toggleUnderline)
                    if level < 3 {
                        DS.RibbonButton("Зачёркнутый", systemImage: "strikethrough", isOn: state.strike, shortcut: "⇧⌘X", action: formatter.toggleStrike)
                    }
                    if level < 2 {
                        DS.RibbonButton("Надстрочный", systemImage: "textformat.superscript", isOn: state.vertical == .superscript, shortcut: "⇧⌘=") {
                            formatter.toggleVertical(.superscript)
                        }
                        DS.RibbonButton("Подстрочный", systemImage: "textformat.subscript", isOn: state.vertical == .subscript, shortcut: "⌘=") {
                            formatter.toggleVertical(.subscript)
                        }
                    }
                    if level < 3 { caseMenu }
                    colorButton
                    if level < 3 { highlightButton }
                    if level == 0 { DS.RibbonButton("Очистить формат", systemImage: "eraser", action: formatter.clearFormatting) }
                }
            }
        }
        DS.RibbonGroup("Абзац", last: level >= 4) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if level < 4 {
                    HStack(spacing: DS.Space.xxs) {
                        ForEach(RTFAlignment.allCases, id: \.self) { alignment in
                            let (title, symbol, key) = Self.alignment(alignment)
                            DS.RibbonButton(title, systemImage: symbol, isOn: state.alignment == alignment, shortcut: key.map { "⌘" + String($0.character).uppercased() }) {
                                formatter.setAlignment(alignment)
                            }
                        }
                        if level < 3 { spacingMenu }
                    }
                }
                HStack(spacing: DS.Space.xxs) {
                    if level < 2 {
                        DS.RibbonButton("Уменьшить отступ", systemImage: "decrease.indent", shortcut: "⌘[") { formatter.stepIndent(-1) }
                        DS.RibbonButton("Увеличить отступ", systemImage: "increase.indent", shortcut: "⌘]") { formatter.stepIndent(1) }
                    }
                    DS.RibbonButton("Невидимые символы", systemImage: "paragraphsign", isOn: document.showsInvisibles, shortcut: "⌥⌘I") {
                        EditorWindowController.shared.workspace.showsInvisibles.toggle()
                    }
                    if level == 0 { moreFormatMenu }
                }
            }
        }
        if level < 4 {
            DS.RibbonGroup("Правка", last: level == 0) {
                if level == 0 {
                    DS.RibbonButton("Найти", systemImage: "magnifyingglass", size: .large, shortcut: "⌘F") { Self.find(replace: false) }
                    DS.RibbonButton("Найти и заменить", systemImage: "arrow.left.arrow.right", glyph: "Заменить", size: .large, shortcut: "⌥⌘F") {
                        Self.find(replace: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        DS.RibbonButton("Найти", systemImage: "magnifyingglass", glyph: "Найти", shortcut: "⌘F") { Self.find(replace: false) }
                        DS.RibbonButton("Найти и заменить", systemImage: "arrow.left.arrow.right", glyph: "Заменить", shortcut: "⌥⌘F") {
                            Self.find(replace: true)
                        }
                    }
                }
            }
        }
        if level > 0 { overflow(level: level).padding(.leading, DS.Space.xs).frame(maxHeight: .infinity) }
    }

    /// «Найти» / «Найти и заменить» — общая панель поиска редактора (ищет по исходнику, переводит в «Код» с тем же местом).
    package static func find(replace: Bool) { EditorWindowController.shared.showFind(replace: replace) }

    /// Регистр «Aa»: меняются сами буквы выделения (`DocCase`).
    private var caseMenu: some View {
        DS.RibbonMenuButton("Регистр", glyph: "Aa") {
            ForEach(DocCase.allCases, id: \.self) { mode in Button(mode.title) { formatter.changeCase(mode) } }
        }
    }

    /// Сочетания Word на любой вкладке ленты (и при свёрнутой ленте): невидимые кнопки.
    private var shortcuts: some View {
        Group {
            Button("") { formatter.toggleBold() }.keyboardShortcut("b", modifiers: .command)
            Button("") { formatter.toggleItalic() }.keyboardShortcut("i", modifiers: .command)
            Button("") { formatter.toggleUnderline() }.keyboardShortcut("u", modifiers: .command)
            Button("") { formatter.toggleStrike() }.keyboardShortcut("x", modifiers: [.command, .shift])
            // ⌘L занят «Перейти к строке» — у левого края сочетания нет.
            Button("") { formatter.setAlignment(.center) }.keyboardShortcut("e", modifiers: .command)
            Button("") { formatter.setAlignment(.right) }.keyboardShortcut("r", modifiers: .command)
            Button("") { formatter.setAlignment(.justify) }.keyboardShortcut("j", modifiers: .command)
            // Размер ⌘⇧< / ⌘⇧> — шаг по списку Word.
            Button("") { formatter.stepSize(-1) }.keyboardShortcut("<", modifiers: .command)
            Button("") { formatter.stepSize(1) }.keyboardShortcut(">", modifiers: .command)
            // E-4 — сочетания Word.
            Button("") { formatter.toggleVertical(.superscript) }.keyboardShortcut("=", modifiers: [.command, .shift])
            Button("") { formatter.toggleVertical(.subscript) }.keyboardShortcut("=", modifiers: .command)
            Button("") { formatter.toggleSmallCaps() }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button("") { formatter.toggleCaps() }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("") { formatter.toggleHidden() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("") { formatter.insertPageBreak() }.keyboardShortcut(.return, modifiers: .command)
            Button("") { formatter.updateFields() }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF9FunctionKey)!)), modifiers: [])
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    private var divider: some View {
        Rectangle().fill(Color.dsLine).frame(width: 1, height: 22).padding(.horizontal, 5).accessibilityHidden(true)
    }

    package static func alignment(_ alignment: RTFAlignment) -> (String, String, KeyEquivalent?) {
        switch alignment {
        case .left: return ("По левому краю", "text.alignleft", nil)
        case .center: return ("По центру (⌘E)", "text.aligncenter", "e")
        case .right: return ("По правому краю (⌘R)", "text.alignright", "r")
        case .justify: return ("По ширине (⌘J)", "text.justify", "j")
        }
    }

    // MARK: - Шрифт и размер

    private func fontButton(width: CGFloat) -> some View {
        let name = state.fontName ?? ""
        return Button { fontsOpen.toggle() } label: {
            HStack(spacing: DS.Space.xs) {
                Text(name.isEmpty ? " " : name)
                    .font(.custom(state.displayFont ?? "Times New Roman", size: 14))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(Color.dsText)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.dsMute).accessibilityHidden(true)
            }
            .padding(.horizontal, DS.Space.s)
            .frame(width: width, height: 30)
            .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(fontsOpen ? Color.dsAccLine : Color.dsLine, lineWidth: fontsOpen ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(fontHelp)
        .accessibilityLabel("Шрифт: \(name.isEmpty ? "разные" : name)")
        .popover(isPresented: $fontsOpen, arrowEdge: .bottom) {
            DocFontList(current: state.fontName, documentFonts: DocFonts.used(in: document.model)) { name in
                fontsOpen = false
                formatter.setFont(name)
            }
        }
    }

    private var fontHelp: String {
        guard let name = state.fontName else { return "Шрифт" }
        if let shown = state.displayFont, FontSubstitution.baseName(name) != shown {
            return "Шрифт «\(name)» — на Mac его нет, показан «\(shown)». В файле остаётся «\(name)»"
        }
        return "Шрифт «\(name)»"
    }

    package static func sizeTitle(_ halfPoints: Int?) -> String {
        guard let halfPoints else { return "" }
        return halfPoints % 2 == 0 ? "\(halfPoints / 2)" : "\(halfPoints / 2),5"
    }

    private var sizeControl: some View {
        HStack(spacing: 0) {
            icon("Уменьшить размер (⌘<)", "minus", small: true) { formatter.stepSize(-1) }
            HStack(spacing: 2) {
                TextField("", text: $sizeText)
                    .textFieldStyle(.plain)
                    .font(DS.Font.manrope(14, .semibold, relativeTo: .body))
                    .multilineTextAlignment(.center)
                    .frame(width: 34)
                    .focused($sizeFocused)
                    .onSubmit(applySizeText)
                    .accessibilityLabel("Размер шрифта")
                Menu {
                    ForEach(DocFormatter.sizes, id: \.self) { size in
                        Button(Self.sizeTitle(Int(size * 2))) { formatter.setSize(points: size) }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Размер шрифта, пт")
                .accessibilityLabel("Список размеров")
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            icon("Увеличить размер (⌘>)", "plus", small: true) { formatter.stepSize(1) }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.dsLine))
    }

    /// Можно ввести «10,5» или «10.5»; пусто или не число — вернуть как было.
    private func applySizeText() {
        let value = Double(sizeText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        if let value, value >= 1, value <= 1_638 {
            formatter.setSize(points: value)
        }
        sizeText = Self.sizeTitle(state.halfPoints)
        sizeFocused = false
    }

    // MARK: - Цвета

    private var colorButton: some View {
        let current: RTFColor? = state.color ?? nil
        return swatchButton("Цвет текста", symbol: "character", bar: current.map(FormatPalette.color) ?? Color.dsText, open: $colorOpen)
            .popover(isPresented: $colorOpen, arrowEdge: .bottom) {
                FormatColorPalette(title: "Цвет текста", noneTitle: "Авто", colors: FormatPalette.text, columns: 6,
                                   documentColors: FormatPalette.used(in: document.model), current: state.color) { color in
                    colorOpen = false
                    formatter.setColor(color)
                }
            }
    }

    private var highlightButton: some View {
        let current: RTFColor? = state.highlight ?? nil
        return swatchButton("Цвет выделения (маркер)", symbol: "highlighter", bar: current.map(FormatPalette.color) ?? Color(nsColor: .systemYellow),
                            open: $highlightOpen)
            .popover(isPresented: $highlightOpen, arrowEdge: .bottom) {
                FormatColorPalette(title: "Цвет выделения", noneTitle: "Нет цвета", colors: FormatPalette.highlight, columns: 5,
                                   documentColors: [], current: state.highlight) { color in
                    highlightOpen = false
                    formatter.setHighlight(color)
                }
            }
    }

    private func swatchButton(_ title: String, symbol: String, bar: Color, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 2) {
                VStack(spacing: 1) {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dsText)
                    RoundedRectangle(cornerRadius: 1).fill(bar).frame(width: 18, height: 4)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.dsMute)
            }
            .frame(width: 40, height: 30)
            .background(open.wrappedValue ? Color.dsField : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(open.wrappedValue ? Color.dsAccLine : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: - Интервалы и «»»

    private var spacingMenu: some View {
        DS.RibbonMenuButton("Интервалы и отступы", systemImage: "arrow.up.and.down.text.horizontal") { spacingItems }
    }

    @ViewBuilder
    private var spacingItems: some View {
        let line = state.paragraph.map { $0.lineSpacing == 0 ? 1.0 : ($0.lineMultiple ? Double($0.lineSpacing) / 240 : -1) }
        ForEach([1.0, 1.15, 1.5, 2.0, 2.5, 3.0], id: \.self) { multiple in
            Button {
                formatter.setLineSpacing(multiple)
            } label: {
                let title = String(format: "%.2f", multiple).replacingOccurrences(of: "0$", with: "", options: .regularExpression)
                    .replacingOccurrences(of: ".", with: ",")
                if let line, abs(line - multiple) < 0.01 { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
        }
        Divider()
        let before = state.paragraph?.spaceBefore ?? 0, after = state.paragraph?.spaceAfter ?? 0
        Button(before > 0 ? "Удалить интервал перед абзацем" : "Добавить интервал перед абзацем") {
            formatter.setSpacing(before: before > 0 ? 0 : 240)
        }
        Button(after > 0 ? "Удалить интервал после абзаца" : "Добавить интервал после абзаца") {
            formatter.setSpacing(after: after > 0 ? 0 : 240)
        }
        Divider()
        Button("Уменьшить отступ") { formatter.stepIndent(-1) }
        Button("Увеличить отступ") { formatter.stepIndent(1) }
    }

    /// Шрифт и абзац сверх кнопок (E-4): индексы, капитель, прописные, скрытый, флаги абзаца, разрыв страницы, поля.
    private var moreFormatMenu: some View {
        DS.RibbonMenuButton("Ещё: индексы, капитель, скрытый, абзац, разрыв страницы, поля", systemImage: "ellipsis.circle") { moreFormatItems }
    }

    @ViewBuilder private var moreFormatItems: some View {
        Toggle("Надстрочный (⇧⌘=)", isOn: binding(state.vertical == .superscript) { formatter.toggleVertical(.superscript) })
        Toggle("Подстрочный (⌘=)", isOn: binding(state.vertical == .subscript) { formatter.toggleVertical(.subscript) })
        Toggle("Капитель (⇧⌘K)", isOn: binding(state.smallCaps) { formatter.toggleSmallCaps() })
        Toggle("Все прописные (⇧⌘A)", isOn: binding(state.caps) { formatter.toggleCaps() })
        Toggle("Скрытый (⇧⌘H)", isOn: binding(state.hidden) { formatter.toggleHidden() })
        Divider()
        ForEach(DocParaFlag.allCases, id: \.self) { flag in
            Toggle(flag.title, isOn: binding(state.paragraph.map(flag.value) ?? false) { formatter.toggle(flag) })
        }
        Divider()
        Button("Разрыв страницы (⌘↩)") { formatter.insertPageBreak() }
        Button("Обновить поля (F9)") { formatter.updateFields() }
    }

    /// Флажок меню: показывает состояние, щелчок — команда.
    private func binding(_ value: Bool, _ action: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { _ in action() })
    }

    private func overflow(level: Int) -> some View {
        Menu {
            if level >= 5 { Button("Повторить") { tab.undo.redo() }.disabled(!tab.undo.canRedo) }
            if level >= 3 {
                Button("Зачёркнутый") { formatter.toggleStrike() }
                Menu("Цвет выделения") {
                    Button("Нет цвета") { formatter.setHighlight(nil) }
                    ForEach(FormatPalette.highlight, id: \.self) { color in
                        Button(FormatPalette.name(color)) { formatter.setHighlight(color) }
                    }
                }
                if level >= 4 {
                    Menu("Выравнивание") {
                        ForEach(RTFAlignment.allCases, id: \.self) { alignment in
                            Button(Self.alignment(alignment).0) { formatter.setAlignment(alignment) }
                        }
                    }
                }
                Menu("Интервалы и отступы") { spacingItems }
            } else {
                Button("Уменьшить отступ") { formatter.stepIndent(-1) }
                Button("Увеличить отступ") { formatter.stepIndent(1) }
            }
            if level >= 3 {
                Menu("Регистр") { ForEach(DocCase.allCases, id: \.self) { mode in Button(mode.title) { formatter.changeCase(mode) } } }
            }
            Button("Очистить формат") { formatter.clearFormatting() }
            Menu("Шрифт и абзац: ещё") { moreFormatItems }
            if level >= 4 {
                Divider()
                Button("Найти (⌘F)") { Self.find(replace: false) }
                Button("Найти и заменить (⌥⌘F)") { Self.find(replace: true) }
            }
        } label: {
            Image(systemName: "chevron.forward.2").font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: DS.RibbonMetrics.button)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Ещё")
        .accessibilityLabel("Ещё команды форматирования")
    }

    // MARK: - Кнопка

    private func icon(_ title: String, _ symbol: String, enabled: Bool = true, active: Bool = false, small: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: small ? 12 : 15, weight: .semibold))
                .foregroundStyle(active ? Color.dsAccInk : Color.dsText)
                .frame(width: small ? 24 : 28, height: small ? 26 : 30)
                .background(active ? Color.dsAcc : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : DS.State.disabledOpacity)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// Группы контекстной синей вкладки «Колонтитулы» ленты (макет «★2», `DocRibbon`): перейти к верхнему/нижнему, вставить номер,
/// число страниц, дату или другое поле, параметры раздела (особый первой, чётные/нечётные, как в предыдущем), удалить, закрыть.
/// Кнопки — только у тех действий, что уже работают: «Как в предыдущем» видна, когда у колонтитула есть предыдущий (H3).
package struct DocHeaderFooterGroups: View {
    @ObservedObject package var formatter: DocFormatter

    package var body: some View {
        let session = formatter.headerSession
        DS.RibbonGroup("Колонтитул") {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                DS.RibbonButton("Верхний колонтитул", systemImage: "rectangle.topthird.inset.filled", glyph: "Верхний",
                                isOn: session?.isHeader == true) { go(header: true) }
                DS.RibbonButton("Нижний колонтитул", systemImage: "rectangle.bottomthird.inset.filled", glyph: "Нижний",
                                isOn: session?.isHeader == false) { go(header: false) }
            }
        }
        DS.RibbonGroup("Вставить") {
            DS.RibbonButton("Номер страницы", systemImage: "number", size: .large) { formatter.insertField(.page) }
            DS.RibbonButton("Всего страниц", systemImage: "doc.on.doc", glyph: "Всего", size: .large) { formatter.insertField(.numPages) }
            DS.RibbonButton("Дата", systemImage: "calendar", size: .large) { formatter.insertField(.date(HeaderField.datePictures[0])) }
            DS.RibbonField("Вставить поле у курсора: «Стр. X из Y», дата, время, имя файла", value: "Поле…") { fieldMenu }
        }
        DS.RibbonGroup("Параметры") {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                DS.RibbonButton("Особый колонтитул первой страницы (\\titlepg)", glyph: "Особый первой", isOn: formatter.titlePageOn) {
                    formatter.setTitlePage(!formatter.titlePageOn)
                }
                DS.RibbonButton("Разные колонтитулы чётных и нечётных страниц (\\facingp)", glyph: "Чётные / нечётные",
                                isOn: formatter.facingPagesOn) { formatter.setFacingPages(!formatter.facingPagesOn) }
            }
            if let link = formatter.headerLink {
                DS.RibbonButton("Как в предыдущем разделе: показывать колонтитул предыдущего", systemImage: "link",
                                glyph: "Как в предыдущем", size: .large, isOn: link == .linked) {
                    formatter.setLinkedToPrevious(link != .linked)
                }
            }
        }
        DS.RibbonGroup("Правка") {
            DS.RibbonButton("Удалить этот колонтитул из файла", systemImage: "trash", glyph: "Удалить", size: .large) { formatter.removeHeader() }
        }
        DS.RibbonGroup("Закрыть", last: true) {
            DS.RibbonButton("Закрыть колонтитулы", systemImage: "xmark", glyph: "Закрыть", size: .large, shortcut: "Esc") {
                formatter.endHeaderEditing()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    /// Перейти к верхнему или нижнему колонтитулу той же страницы.
    private func go(header: Bool) {
        guard let page = formatter.headerSession?.page else { return }
        formatter.beginHeaderEditing(page: page, header: header)
    }

    @ViewBuilder private var fieldMenu: some View {
        Button(HeaderField.pageOfTotal.title) { formatter.insertField(.pageOfTotal) }
        Button(HeaderField.sectionPages.title) { formatter.insertField(.sectionPages) }
        Section("Дата") {
            ForEach(HeaderField.datePictures, id: \.self) { picture in
                Button(HeaderField.date(picture).title.replacingOccurrences(of: "Дата · ", with: "")) { formatter.insertField(.date(picture)) }
            }
        }
        Section("Время") {
            ForEach(HeaderField.timePictures, id: \.self) { picture in
                Button(HeaderField.time(picture).title.replacingOccurrences(of: "Время · ", with: "")) { formatter.insertField(.time(picture)) }
            }
        }
        Button(HeaderField.fileName.title) { formatter.insertField(.fileName) }
    }
}
