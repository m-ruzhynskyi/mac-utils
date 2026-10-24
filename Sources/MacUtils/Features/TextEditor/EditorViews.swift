import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MUCore
import MUDesign
import MUScreenshot

/// Окно редактора (макет a): заголовок со вкладками, текст, панель `$` справа, строка состояния.
struct EditorRootView: View {
    @ObservedObject var workspace: EditorWorkspace
    static let titleBarHeight: CGFloat = 50
    static let panelWidth: CGFloat = 272
    /// Уже — панель «$» в «Документе» поверх страниц, а не рядом.
    static let narrowDocumentWidth: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            EditorTitleBar(workspace: workspace)
            if let tab = workspace.current {
                GeometryReader { geometry in
                    // Узкое окно (< 720 pt) в «Документе»: панель «$» выдвигается поверх страниц (`d06`).
                    let overlayPanel = tab.mode == .document && geometry.size.width < Self.narrowDocumentWidth
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if workspace.findMode != nil { FindBar(workspace: workspace, search: workspace.search) }
                            EditorBanners(tab: tab)
                            if tab.mode == .document, let document = tab.documentController {
                                DocFormatBar(tab: tab, document: document)
                                DocumentHost(controller: document).clipped()
                                    .overlay(alignment: .bottom) { DocNoticeView(document: document) }
                            } else {
                                // Текст — строго в своей области: AppKit-вид поверх SwiftUI не должен заходить на строку состояния.
                                EditorTextHost(tab: tab).clipped()
                            }
                        }
                        if workspace.dollarPanelVisible, !overlayPanel {
                            Rectangle().fill(Color.dsLine).frame(width: 1).accessibilityHidden(true)
                            DollarPanelView(tab: tab).frame(width: Self.panelWidth)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if workspace.dollarPanelVisible, overlayPanel {
                            DollarPanelView(tab: tab).frame(width: Self.panelWidth)
                                .background(Color.dsSide)
                                .overlay(alignment: .leading) { Rectangle().fill(Color.dsLine).frame(width: 1) }
                                .shadow(color: .black.opacity(0.25), radius: 14, x: -4)
                                .transition(.move(edge: .trailing))
                        }
                    }
                }
                if workspace.folderSearchVisible {
                    FolderSearchPanel(model: workspace.folderSearch) { url, range in
                        EditorWindowController.shared.openFolderMatch(url, range: range)
                    } close: {
                        workspace.folderSearchVisible = false
                    } confirmReplace: {
                        EditorWindowController.shared.confirmFolderReplace()
                    }
                }
                if tab.mode == .document, let document = tab.documentController {
                    DocStatusBar(workspace: workspace, tab: tab, document: document)
                } else {
                    EditorStatusBar(workspace: workspace, tab: tab)
                }
            } else {
                EmptyState("Нет открытых документов", systemImage: "doc.plaintext",
                           message: "Создайте документ (⌘N) или откройте файл (⌘O) — можно перетащить его в окно",
                           actionTitle: "Новый документ") { EditorWindowController.shared.newDocument() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.dsPanel)
            }
        }
        .background(Color.dsPanel)
        .overlay { overlay }
        .ignoresSafeArea()
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            EditorWindowController.shared.openDropped(providers)
            return true
        }
        .tint(.dsAccText)
    }

    @ViewBuilder private var overlay: some View {
        if let kind = workspace.overlay, let tab = workspace.current {
            ZStack(alignment: kind == .encoding ? .bottomTrailing : .top) {
                // Клик мимо панели закрывает её.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { workspace.overlay = nil }
                    .accessibilityHidden(true)
                switch kind {
                case .encoding:
                    EncodingPanel(tab: tab) { workspace.overlay = nil }
                        .padding(.trailing, workspace.dollarPanelVisible ? 104 : 104)
                        .padding(.bottom, 32)
                case .goToLine:
                    GoToLinePanel(lineCount: tab.lineCount) { line, column in
                        workspace.overlay = nil
                        tab.goTo(line: line, column: column)
                    } onClose: {
                        workspace.overlay = nil
                        tab.textView.window?.makeFirstResponder(tab.textView)
                    }
                    .padding(.top, Self.titleBarHeight + 24)
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Заголовок и вкладки

/// Полоса заголовка 50 pt на `side`: место под «светофор», вкладки документов, кнопки поиска и панели `$`.
struct EditorTitleBar: View {
    @ObservedObject var workspace: EditorWorkspace
    @State private var dragging: UUID?

    var body: some View {
        HStack(spacing: DS.Space.m) {
            // «Светофор» окна стоит здесь (его ставит `EditorWindow`).
            Color.clear.frame(width: 64, height: 1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: DS.Space.xs) {
                        ForEach(workspace.tabs) { tab in
                            DocumentTab(tab: tab, title: workspace.displayTitle(tab), selected: tab.id == workspace.current?.id) {
                                workspace.selectedID = tab.id
                            } close: {
                                EditorWindowController.shared.close(tab)
                            }
                            .id(tab.id)
                            .onDrag {
                                dragging = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab.id, workspace: workspace, dragging: $dragging))
                        }
                        Button { EditorWindowController.shared.newDocument() } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(.dsMute)
                                .frame(width: 26, height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Новый документ (⌘N)")
                        .accessibilityLabel("Новый документ")
                    }
                    .padding(3)
                }
                .scrollIndicators(.never)
                .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: workspace.selectedID) { _, id in
                    if let id { withAnimation(DS.Motion.quick) { proxy.scrollTo(id) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let tab = workspace.current, tab.isRTF { ViewModeSwitch(tab: tab) }
            IconButton("Найти и заменить (⌘F)", systemImage: "magnifyingglass", active: workspace.findMode != nil, compact: true) {
                if workspace.findMode == nil { EditorWindowController.shared.showFind(replace: false) } else {
                    EditorWindowController.shared.hideFind()
                }
            }
            IconButton("Панель «Знаки $» (⌥⌘4)", systemImage: "dollarsign", active: workspace.dollarPanelVisible, compact: true) {
                workspace.dollarPanelVisible.toggle()
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: EditorRootView.titleBarHeight)
        .background { WindowDragArea().background(Color.dsSide) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 1) }
    }
}

/// Пустое место полосы заголовка двигает окно, двойной клик — как у заголовка (по настройке системы).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
            } else {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

/// Вкладка документа: выбранная — лайм; точка — несохранённые правки (при наведении — ×); × — закрыть.
struct DocumentTab: View {
    @ObservedObject var tab: EditorTab
    let title: String
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Self.symbol(tab.document.language, url: tab.document.url)).font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(title).font(DS.Font.manrope(12.5, .bold, relativeTo: .callout)).lineLimit(1)
            Button(action: close) {
                ZStack {
                    if tab.isDirty && !hovered {
                        Circle().fill(selected ? Color.dsAccInk : Color.dsMute).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(selected || hovered ? 0.7 : 0)
                    }
                }
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Закрыть вкладку (⌘W)")
            .accessibilityLabel("Закрыть \(title)")
        }
        .foregroundStyle(selected ? Color.dsAccInk : Color.dsMute)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(selected ? Color.dsAcc : (hovered ? Color.dsPanel.opacity(0.6) : .clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .help(tab.document.url?.path ?? title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title + (tab.isDirty ? ", не сохранено" : ""))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(.default, select)
    }

    static func symbol(_ language: EditorLanguage, url: URL?) -> String {
        switch language {
        case .rtf: return "doc.richtext"
        case .json: return "curlybraces"
        case .xml: return "chevron.left.forwardslash.chevron.right"
        case .plain: return "doc.plaintext"
        }
    }
}

/// Перетаскивание вкладки на другую — меняет порядок.
private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let workspace: EditorWorkspace
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        MainActor.assumeIsolated {
            withAnimation(DS.Motion.quick) { workspace.move(dragging, to: target) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - Текст

/// Текст вкладки (`NSScrollView` с `EditorTextView`); при смене вкладки подставляется её прокрутка.
struct EditorTextHost: NSViewRepresentable {
    let tab: EditorTab

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.clipsToBounds = true
        install(tab.container, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== tab.container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        install(tab.container, in: container)
    }

    private func install(_ scroll: NSView, in container: NSView) {
        scroll.removeFromSuperview()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                scroll.window?.makeFirstResponder(tab.textView)
                tab.rehighlight()
            }
        }
    }
}

/// Предупреждения над текстом: файл изменён на диске, файл не найден, байты не подошли кодировке.
struct EditorBanners: View {
    @ObservedObject var tab: EditorTab

    var body: some View {
        VStack(spacing: 0) {
            if tab.changedOnDisk {
                Banner(.warning, title: "Файл изменён на диске",
                       message: tab.isDirty ? "У вас есть несохранённые правки — при перезагрузке они пропадут." : nil) {
                    Button("Перезагрузить") { EditorWindowController.shared.reloadFromDisk(tab) }
                        .buttonStyle(.graphite(.primary, size: .compact))
                    Button("Оставить мою версию") { EditorWindowController.shared.keepMine(tab) }
                        .buttonStyle(.graphite(.secondary, size: .compact))
                }
                .padding(DS.Space.s)
            }
            if tab.fileMissing {
                Banner(.warning, title: "Файл не найден", message: "Текст сохранён в черновике. «Сохранить как…» запишет его в новый файл.")
                    .padding(DS.Space.s)
            }
            if tab.document.lossyDecode {
                Banner(.warning, title: "Байты не подходят для \(tab.document.encoding.title)",
                       message: "Такие места показаны знаком �. Пока текст не правили, сохраняются исходные байты.")
                    .padding(DS.Space.s)
            }
        }
        .background(Color.dsPanel)
    }
}

// MARK: - Строка состояния

/// Строка состояния 30 pt: позиция, выделение, длина/строк; справа — язык, кодировка, перевод строки, ВСТ/ЗАМ.
struct EditorStatusBar: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var tab: EditorTab

    var body: some View {
        HStack(spacing: 2) {
            item("Стр \(tab.caret.line), стл \(tab.caret.column)", mono: true)
                .accessibilityLabel("Строка \(tab.caret.line), столбец \(tab.caret.column)")
            item(selectionText)
            item("\(EditorSearch.number(tab.length)) симв. · \(EditorSearch.number(tab.lineCount)) стр.")
            Spacer(minLength: 0)
            Menu {
                ForEach(EditorLanguage.allCases, id: \.self) { language in
                    Button { EditorWindowController.shared.setLanguage(language, for: tab) } label: {
                        if language == tab.document.language { Label(language.title, systemImage: "checkmark") } else { Text(language.title) }
                    }
                }
            } label: { label(tab.document.language.short, menu: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Синтаксис")
            Button { workspace.overlay = workspace.overlay == .encoding ? nil : .encoding } label: {
                label(tab.document.encoding.title, menu: true, open: workspace.overlay == .encoding)
            }
            .buttonStyle(.plain)
            .help("Кодировка")
            Menu {
                ForEach(LineEnding.allCases, id: \.self) { ending in
                    Button { tab.convertLineEndings(to: ending) } label: {
                        let title = "\(ending.title) — \(ending.detail)"
                        if tab.lineEnding == .single(ending) { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            } label: { label(tab.lineEnding.title, menu: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Перевод строки")
            Button { tab.textView.overwrite.toggle() } label: { label(tab.overwrite ? "ЗАМ" : "ВСТ", mono: true) }
                .buttonStyle(.plain)
                .help(tab.overwrite ? "Замена — набранный символ заменяет следующий (Insert)" : "Вставка (Insert — замена)")
                .accessibilityLabel(tab.overwrite ? "Режим замены" : "Режим вставки")
        }
        .padding(.horizontal, DS.Space.s)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        // На всю ширину окна до самых нижних углов: без отступов «безопасной зоны» у скруглённых углов окна.
        .background(Color.dsSide.ignoresSafeArea())
        .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 1) }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    private var selectionText: String {
        let caret = tab.caret
        if caret.cursors > 1 { return "Курсоров \(caret.cursors)" }
        guard caret.selected > 0 else { return "Выделено 0" }
        if caret.selectedLines > 1 { return "Выделено \(EditorSearch.number(caret.selected)) · \(caret.selectedLines) стр." }
        return "Выделено \(EditorSearch.number(caret.selected))"
    }

    private func item(_ title: String, mono: Bool = false) -> some View { label(title, mono: mono) }

    private func label(_ title: String, mono: Bool = false, menu: Bool = false, open: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).font(mono ? DS.Font.mono(11.5, relativeTo: .caption) : DS.Font.manrope(12, .semibold, relativeTo: .caption))
                .lineLimit(1)
            if menu { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).accessibilityHidden(true) }
        }
        .foregroundStyle(open ? Color.dsText : Color.dsMute)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(open ? Color.dsField : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { if open { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.dsAccLine, lineWidth: 1.5) } }
        .contentShape(Rectangle())
    }
}

// MARK: - Меню «Кодировка»

/// Плавающая панель Graphite (макет b): «Открыть заново в…» / «Преобразовать в…» и 14 кодировок по группам.
struct EncodingPanel: View {
    @ObservedObject var tab: EditorTab
    let close: () -> Void
    @State private var mode = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Кодировка").font(DS.Font.manrope(15, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
                Spacer()
                Text("определена \(tab.document.reason.title)").font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
            Segmented(selection: $mode, options: [(0, "Открыть заново в…"), (1, "Преобразовать в…")])
            HStack(alignment: .top, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    group(.unicode)
                    Spacer().frame(height: 6)
                    group(.western)
                }
                VStack(alignment: .leading, spacing: 2) {
                    group(.cyrillic)
                    Spacer().frame(height: 6)
                    group(.central)
                }
            }
            Text("«Открыть заново» читает те же байты в другой кодировке. «Преобразовать» сохранит текст в новой.")
                .font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 430)
        .floating()
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .onExitCommand(perform: close)
    }

    private func group(_ group: TextEncoding.Group) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            GroupLabel(group.title).padding(.leading, 6).padding(.bottom, 2)
            ForEach(TextEncoding.allCases.filter { $0.group == group }, id: \.self) { encoding in
                EncodingRow(encoding: encoding, current: encoding == tab.document.encoding) {
                    close()
                    if mode == 0 {
                        EditorWindowController.shared.reopen(tab, as: encoding)
                    } else {
                        EditorWindowController.shared.convert(tab, to: encoding)
                    }
                }
            }
        }
    }
}

private struct EncodingRow: View {
    let encoding: TextEncoding
    let current: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).opacity(current ? 1 : 0)
                    .accessibilityHidden(true)
                Text(encoding.title).font(current ? DS.Font.bodyStrong : DS.Font.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(current ? Color.dsAccInk : Color.dsText)
            .padding(.horizontal, 8)
            .frame(width: 190, height: 26)
            .background(current ? Color.dsAcc : (hovered ? Color.dsField : .clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(encoding.title)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
