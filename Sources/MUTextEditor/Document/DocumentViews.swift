import AppKit
import SwiftUI
import MUCore
import MUDesign

/// Страницы документа вкладки (прокрутка контроллера) в окне редактора.
package struct DocumentHost: NSViewRepresentable {
    package let controller: DocumentController
    /// Открыта панель «Знаки $» — только тогда знаки подсвечены на страницах.
    package var showsDollarMarks = false

    package func makeNSView(context: Context) -> NSView {
        controller.showsDollarMarks = showsDollarMarks
        let container = NSView()
        container.wantsLayer = true
        container.clipsToBounds = true
        install(controller.scrollView, in: container)
        return container
    }

    package func updateNSView(_ container: NSView, context: Context) {
        controller.showsDollarMarks = showsDollarMarks
        guard container.subviews.first !== controller.scrollView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        install(controller.scrollView, in: container)
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
                if let view = controller.textViews.first { scroll.window?.makeFirstResponder(view) }
                controller.highlightDollars()
            }
        }
    }
}

/// Подсказка над страницами: почему правка не сделана («Изменить это можно в режиме «Код»») и т. п.
package struct DocNoticeView: View {
    @ObservedObject package var document: DocumentController

    package var body: some View {
        if let notice = document.notice {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "info.circle.fill").foregroundStyle(Color.dsMute).accessibilityHidden(true)
                Text(notice).font(DS.Font.bodyStrong).foregroundStyle(.dsText).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(Color.dsPanel, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .padding(.bottom, DS.Space.l)
            .transition(.opacity)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// Сегменты «Код | Документ» в заголовке окна (`d01`, `d02`), ⌘⇧D. Есть только у RTF.
package struct ViewModeSwitch: View {
    @ObservedObject package var tab: EditorTab

    package var body: some View {
        HStack(spacing: 4) {
            segment(.code, title: "Код", symbol: "chevron.left.forwardslash.chevron.right", enabled: true)
            segment(.document, title: "Документ", symbol: "doc.text", enabled: tab.canShowDocument)
        }
        .padding(3)
        .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .fixedSize()
    }

    private func segment(_ mode: EditorViewMode, title: String, symbol: String, enabled: Bool) -> some View {
        let on = tab.mode == mode
        return Button { tab.setMode(mode) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).accessibilityHidden(true)
                Text(title).font(DS.Font.manrope(12.5, .bold, relativeTo: .callout))
            }
            .foregroundStyle(on ? Color.dsAccInk : Color.dsMute)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(on ? Color.dsAcc : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : DS.State.disabledOpacity)
        .help(enabled ? (mode == .code ? "Исходник RTF (⌘⇧D)" : "Как в Word: страницы, шрифты, таблицы (⌘⇧D)")
              : (tab.documentUnavailableReason ?? ""))
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

/// Строка состояния документа: «Страница 1 из 2 · Раздел 1 · 212 слов», замена шрифта у курсора; справа масштаб,
/// RTF и кодировка.
package struct DocStatusBar: View {
    @ObservedObject package var workspace: EditorWorkspace
    @ObservedObject package var tab: EditorTab
    @ObservedObject package var document: DocumentController

    package var body: some View {
        HStack(spacing: 2) {
            item("Страница \(document.currentPage) из \(document.pageCount)")
                .accessibilityLabel("Страница \(document.currentPage) из \(document.pageCount)")
            item("Раздел \(document.currentSection)")
            item("\(EditorSearch.number(document.wordCount)) \(plural(document.wordCount, "слово", "слова", "слов"))")
            languageMenu
            if let name = document.selection.fontName, let shown = document.selection.displayFont,
               FontSubstitution.baseName(name) != shown {
                item("\(name) → \(shown)").help("Шрифта «\(name)» нет на Mac: показан заменой, в файле остаётся «\(name)»")
            }
            Spacer(minLength: 0)
            if tab.isDirty {
                Button { EditorWindowController.shared.save(tab) { _ in } } label: { label("Изменён · ⌘S") }
                    .buttonStyle(.plain)
                    .help("Есть несохранённые правки. ⌘S записывает только ваши правки; не прошла проверка — предложит сохранить копию")
                    .accessibilityLabel("Изменён. Сохранить ⌘S")
            }
            Menu {
                ForEach([50, 75, 80, 100, 125, 150, 200], id: \.self) { percent in
                    Button("\(percent) %") {
                        document.fit = .none
                        document.zoom = CGFloat(percent) / 100
                    }
                }
                Divider()
                Button("По ширине") { document.fit = .width }
                Button("Страница целиком") { document.fit = .page }
            } label: { label(zoomTitle, menu: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Масштаб (⌘+ / ⌘−)")
            label("RTF")
            Button { workspace.overlay = workspace.overlay == .encoding ? nil : .encoding } label: {
                label(tab.document.encoding.title, menu: true, open: workspace.overlay == .encoding)
            }
            .buttonStyle(.plain)
            .help("Кодировка")
        }
        .padding(.horizontal, DS.Space.s)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(Color.dsSide.ignoresSafeArea())
        .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 1) }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    /// Язык у курсора (`\lang`) и проверка орфографии: по языку текста, одним языком на весь документ или выключена. Выбор — на время сеанса, в файл не пишется.
    @ViewBuilder private var languageMenu: some View {
        let on = UserDefaults.standard.bool(forKey: Pref.docSpelling)
        Menu {
            Toggle("Проверять орфографию", isOn: Binding(get: { on }, set: { _ in EditorWindowController.shared.editorToggleSpelling(nil) }))
            Divider()
            Button("Язык по тексту (\\lang)") { document.spelling.choice = .automatic }
            Button("Русский") { document.spelling.choice = .fixed("ru") }
            Button("Украинский") { document.spelling.choice = .fixed("uk") }
            Button("Английский") { document.spelling.choice = .fixed("en_US") }
            Button("Не проверять") { document.spelling.choice = .off }
        } label: { label(document.languageName ?? "Язык", menu: true) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Язык текста у курсора (\\lang) и проверка орфографии")
    }

    private var zoomTitle: String {
        switch document.fit {
        case .width: return "По ширине"
        case .page: return "Страница целиком"
        case .none: return "\(Int((document.zoom * 100).rounded())) %"
        }
    }

    private func item(_ title: String) -> some View { label(title) }

    private func label(_ title: String, menu: Bool = false, open: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).font(DS.Font.manrope(12, .semibold, relativeTo: .caption)).lineLimit(1)
            if menu { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).accessibilityHidden(true) }
        }
        .foregroundStyle(open ? Color.dsText : Color.dsMute)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(open ? Color.dsField : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}
