import SwiftUI
import MUDesign

/// Панель форматирования режима «Документ» (`d01`): полоса 44 pt под заголовком — отмена и повтор, шрифт, размер,
/// Ж К Ч S, цвет текста и маркер, выравнивание, интервалы, отступы, списки и таблица (позже), очистить формат, ¶.
/// На узком окне хвост уходит в «»» (`d06`). При правке колонтитула под ней — вкладка «Колонтитулы» (`d11`), ниже —
/// линейка.
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
            // Колонка документа бывает узкой (рядом панель «$»): берётся первый уровень, который помещается.
            ViewThatFits(in: .horizontal) {
                bar(level: 0)
                bar(level: 1)
                bar(level: 2)
                bar(level: 3)
                bar(level: 4)
                bar(level: 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44)
            .clipped()
            .background(Color.dsSide)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 1) }
            if formatter.headerSession != nil { DocHeaderFooterBar(formatter: formatter) }
            FormatRuler(document: document, formatter: formatter)
                .frame(height: 26)
                .background(Color.dsSide)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 1) }
        }
        .onChange(of: state.halfPoints) { _, _ in if !sizeFocused { sizeText = Self.sizeTitle(state.halfPoints) } }
        .onAppear { sizeText = Self.sizeTitle(state.halfPoints) }
    }

    // MARK: - Полоса

    /// Уровень ужатия панели: 0 — всё; 1 — отступы и «Очистить» в «»»; 2 — и списки с таблицей; 3 — и зачёркнутый,
    /// маркер, интервалы; 4 — как узкое окно `d06`: отмена, шрифт и размер, Ж К Ч, цвет и ¶; 5 — ещё уже.
    private func bar(level: Int) -> some View {
        HStack(spacing: 2) {
            icon("Отменить (⌘Z)", "arrow.uturn.backward", enabled: tab.undo.canUndo) { tab.undo.undo() }
            if level < 5 { icon("Повторить (⇧⌘Z)", "arrow.uturn.forward", enabled: tab.undo.canRedo) { tab.undo.redo() } }
            divider
            fontButton(width: level >= 4 ? 104 : 128)
            sizeControl
            divider
            icon("Полужирный (⌘B)", "bold", active: state.bold, action: formatter.toggleBold).keyboardShortcut("b", modifiers: .command)
            icon("Курсив (⌘I)", "italic", active: state.italic, action: formatter.toggleItalic).keyboardShortcut("i", modifiers: .command)
            icon("Подчёркнутый (⌘U)", "underline", active: state.underline, action: formatter.toggleUnderline).keyboardShortcut("u", modifiers: .command)
            if level < 3 {
                icon("Зачёркнутый (⌘⇧X)", "strikethrough", active: state.strike, action: formatter.toggleStrike)
                    .keyboardShortcut("x", modifiers: [.command, .shift])
            }
            colorButton
            if level < 3 { highlightButton }
            if level < 4 {
                divider
                ForEach(RTFAlignment.allCases, id: \.self) { alignment in
                    let (title, symbol, key) = Self.alignment(alignment)
                    let button = icon(title, symbol, active: state.alignment == alignment) { formatter.setAlignment(alignment) }
                    // ⌘L занят «Перейти к строке» — у левого края сочетания нет.
                    if let key { button.keyboardShortcut(key, modifiers: .command) } else { button }
                }
                if level < 3 { spacingMenu }
            }
            if level == 0 {
                icon("Уменьшить отступ", "decrease.indent") { formatter.stepIndent(-1) }
                icon("Увеличить отступ", "increase.indent") { formatter.stepIndent(1) }
            }
            if level < 2 {
                divider
                icon("Маркированный список — скоро. Пока измените это в режиме «Код»", "list.bullet", enabled: false) {}
                icon("Нумерованный список — скоро. Пока измените это в режиме «Код»", "list.number", enabled: false) {}
                icon("Таблица — скоро. Пока измените это в режиме «Код»", "tablecells", enabled: false) {}
            }
            if level == 0 { icon("Очистить формат", "textformat.alt", action: formatter.clearFormatting) }
            if level == 0 { moreFormatMenu }
            divider
            icon("Невидимые символы (⌥⌘I)", "paragraphsign", active: document.showsInvisibles) {
                EditorWindowController.shared.workspace.showsInvisibles.toggle()
            }
            Spacer(minLength: 0)
            if level > 0 { overflow(level: level) }
            // Размер ⌘⇧< / ⌘⇧> — шаг по списку Word.
            Group {
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
        .padding(.horizontal, DS.Space.m)
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
        Menu {
            spacingItems
        } label: {
            Image(systemName: "arrow.up.and.down.text.horizontal").font(.system(size: 15, weight: .medium))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34, height: 30)
        .help("Интервалы и отступы")
        .accessibilityLabel("Интервалы и отступы")
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
        Menu { moreFormatItems } label: {
            Image(systemName: "textformat.superscript").font(.system(size: 15))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34, height: 30)
        .help("Ещё: индексы, капитель, скрытый, абзац, разрыв страницы, поля")
        .accessibilityLabel("Ещё команды шрифта и абзаца")
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
            Button("Очистить формат") { formatter.clearFormatting() }
            Menu("Шрифт и абзац: ещё") { moreFormatItems }
            if level >= 2 {
                Divider()
                Button("Списки — скоро, пока в режиме «Код»") {}.disabled(true)
                Button("Таблица — скоро, пока в режиме «Код»") {}.disabled(true)
            }
        } label: {
            Image(systemName: "chevron.forward.2").font(.system(size: 15, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34, height: 30)
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

/// Контекстная синяя вкладка «Колонтитулы» (макет «★2», компоненты `DS.Ribbon*`): перейти к верхнему/нижнему, вставить номер,
/// число страниц, дату или другое поле, параметры раздела (особый первой, чётные/нечётные, как в предыдущем), удалить, закрыть.
/// Кнопки — только у тех действий, что уже работают: «Как в предыдущем» видна, когда у колонтитула есть предыдущий (H3).
package struct DocHeaderFooterBar: View {
    @ObservedObject package var formatter: DocFormatter
    private static let tabs = [DS.RibbonTabItem("header", "Колонтитулы", contextual: true)]

    package var body: some View {
        DS.Ribbon(tabs: Self.tabs, selection: .constant("header")) {
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
        .accessibilityLabel("Колонтитулы")
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
