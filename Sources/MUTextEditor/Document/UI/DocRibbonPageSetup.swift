import SwiftUI
import MUCore
import MUDesign

// R4: группа «Параметры страницы» на вкладке «Макет» (макет `.audit/word-ui-design`, группа «Параметры страницы»): «Поля» (пресеты Word и
// «Настраиваемые поля…»), «Ориентация», «Размер». У текущего значения — галочка. Команда — `DocumentController.perform(DocPageSetup.Change)`.

/// Подписи и отметки меню (чистые функции — для тестов).
package enum DocRibbonPageSetup {
    /// Текст поля ввода: сантиметры с запятой, без лишних нулей («2», «1,27», «2,54»).
    package static func text(cm twips: Int) -> String {
        var text = String(format: "%.2f", DocPageSetup.cm(twips: twips)).replacingOccurrences(of: ".", with: ",")
        while text.contains(","), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(",") { text.removeLast() }
        return text
    }

    /// Поля из четырёх строк ввода (см); `nil` — какая-то не число.
    package static func margins(top: String, bottom: String, left: String, right: String) -> DocPageSetup.Margins? {
        guard let t = DocPageSetup.parse(cm: top), let b = DocPageSetup.parse(cm: bottom), let l = DocPageSetup.parse(cm: left),
              let r = DocPageSetup.parse(cm: right) else { return nil }
        return DocPageSetup.Margins(left: DocPageSetup.twips(cm: l), right: DocPageSetup.twips(cm: r), top: DocPageSetup.twips(cm: t),
                                    bottom: DocPageSetup.twips(cm: b))
    }

    /// Строка для подписи кнопки «Поля»: пресет или «Свои».
    package static func marginsTitle(_ page: DocPageSetup.Page?) -> String {
        guard let page else { return "Поля" }
        return DocPageSetup.preset(of: page.margins)?.title ?? "Свои"
    }
}

package struct DocPageSetupGroup: View {
    @ObservedObject package var document: DocumentController
    @ObservedObject package var formatter: DocFormatter
    @State private var customOpen = false

    package init(document: DocumentController, formatter: DocFormatter) {
        self.document = document
        self.formatter = formatter
    }

    package var body: some View {
        let page = document.currentPageSetup
        let isDocument = document.tab?.mode == .document
        DS.RibbonGroup("Параметры страницы") {
            DS.RibbonMenuButton("Поля страницы", systemImage: "square.dashed", glyph: "Поля", size: .large) {
                ForEach(DocPageSetup.Preset.allCases, id: \.self) { preset in
                    toggle(preset.title, change: .margins(preset.margins), isOn: page.map { DocPageSetup.preset(of: $0.margins) == preset } ?? false,
                           page: page, isDocument: isDocument)
                }
                Divider()
                Button("Настраиваемые поля…") { customOpen = true }
            }
            .popover(isPresented: $customOpen, arrowEdge: .bottom) {
                if let page { DocCustomMarginsView(page: page, document: document, close: { customOpen = false }) }
            }
            DS.RibbonMenuButton("Ориентация страницы", systemImage: "rectangle.portrait.rotate", glyph: "Ориентация", size: .large) {
                toggle("Книжная", change: .landscape(false), isOn: page.map { !$0.isLandscape } ?? false, page: page, isDocument: isDocument)
                toggle("Альбомная", change: .landscape(true), isOn: page?.isLandscape ?? false, page: page, isDocument: isDocument)
            }
            DS.RibbonMenuButton("Размер бумаги", systemImage: "doc", glyph: "Размер", size: .large) {
                ForEach(DocPageSetup.Paper.allCases, id: \.self) { paper in
                    toggle(paper.title, change: .paper(paper), isOn: page.flatMap { DocPageSetup.paper(of: $0) } == paper, page: page, isDocument: isDocument)
                }
            }
        }
    }

    private func toggle(_ title: String, change: DocPageSetup.Change, isOn: Bool, page: DocPageSetup.Page?, isDocument: Bool) -> some View {
        let availability = DocPageSetupCommand.availability(change, isDocument: isDocument, page: page)
        return Toggle(title, isOn: Binding(get: { isOn }, set: { _ in document.perform(change) }))
            .disabled(!availability.isEnabled)
    }
}

/// «Настраиваемые поля…»: четыре поля в сантиметрах.
package struct DocCustomMarginsView: View {
    package let page: DocPageSetup.Page
    package let document: DocumentController
    package let close: () -> Void
    @State private var top: String
    @State private var bottom: String
    @State private var left: String
    @State private var right: String

    package init(page: DocPageSetup.Page, document: DocumentController, close: @escaping () -> Void) {
        self.page = page
        self.document = document
        self.close = close
        _top = State(initialValue: DocRibbonPageSetup.text(cm: page.margins.top))
        _bottom = State(initialValue: DocRibbonPageSetup.text(cm: page.margins.bottom))
        _left = State(initialValue: DocRibbonPageSetup.text(cm: page.margins.left))
        _right = State(initialValue: DocRibbonPageSetup.text(cm: page.margins.right))
    }

    private var parsed: DocPageSetup.Margins? { DocRibbonPageSetup.margins(top: top, bottom: bottom, left: left, right: right) }

    private var problem: String? {
        guard let parsed else { return "Введите числа в сантиметрах, например 2,5" }
        return DocPageSetup.problem(parsed, page: page)
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Поля, см").font(DS.Font.manrope(13, .bold, relativeTo: .headline))
            Grid(alignment: .leading, horizontalSpacing: DS.Space.s, verticalSpacing: DS.Space.xs) {
                GridRow { label("Верхнее"); field($top); label("Нижнее"); field($bottom) }
                GridRow { label("Левое"); field($left); label("Правое"); field($right) }
            }
            if let problem {
                Text(problem).font(DS.Font.manrope(11, .semibold, relativeTo: .caption)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Отмена", action: close).keyboardShortcut(.cancelAction)
                Button("Применить") {
                    if let parsed, document.perform(.margins(parsed)) { close() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(DS.Space.m)
        .frame(width: 330)
    }

    private func label(_ text: String) -> some View { Text(text).font(DS.Font.manrope(12, .semibold, relativeTo: .callout)).foregroundStyle(.dsMute) }

    private func field(_ value: Binding<String>) -> some View { TextField("", text: value).textFieldStyle(.roundedBorder).frame(width: 64) }
}
