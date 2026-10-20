import AppKit
import SwiftUI

/// Страницы документа вкладки (прокрутка контроллера) в окне редактора.
struct DocumentHost: NSViewRepresentable {
    let controller: DocumentController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.clipsToBounds = true
        install(controller.scrollView, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
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

/// Сегменты «Код | Документ» в заголовке окна (`d01`, `d02`), ⌘⇧D. Есть только у RTF.
struct ViewModeSwitch: View {
    @ObservedObject var tab: EditorTab

    var body: some View {
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
struct DocStatusBar: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var tab: EditorTab
    @ObservedObject var document: DocumentController

    var body: some View {
        HStack(spacing: 2) {
            item("Страница \(document.currentPage) из \(document.pageCount)")
                .accessibilityLabel("Страница \(document.currentPage) из \(document.pageCount)")
            item("Раздел \(document.currentSection)")
            item("\(EditorSearch.number(document.wordCount)) \(plural(document.wordCount, "слово", "слова", "слов"))")
            if let name = document.selection.fontName, let shown = document.selection.displayFont,
               FontSubstitution.baseName(name) != shown {
                item("\(name) → \(shown)").help("Шрифта «\(name)» нет на Mac: показан заменой, в файле остаётся «\(name)»")
            }
            Spacer(minLength: 0)
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
