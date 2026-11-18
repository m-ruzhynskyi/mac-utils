import SwiftUI
import MUCore
import MUDesign

// S1 в ленте (макет `.audit/word-ui-design`, раздел «3 Стили»): группа «Стили» на «Главной» — плитки самых используемых абзацных стилей
// документа (текущий обведён лаймовой рамкой) и «▾» со всем списком, абзацные и знаковые отдельно. В узком окне вся группа — одна
// кнопка-меню. Команда — `DocumentController.applyStyle`, доступность — `DocStyleCommand.availability`.

/// Как стиль выглядит на плитке: начертание и размер (в пределах плитки).
package struct DocStyleLook: Equatable {
    package var bold = false
    package var italic = false
    package var halfPoints = 24

    /// Размер образца на плитке: размер стиля, но не меньше 11 и не больше 15 pt.
    package var previewSize: CGFloat { min(15, max(11, CGFloat(halfPoints) / 2 * 0.8)) }
}

extension DocumentController {
    /// Вид стиля для плитки; читается один раз на версию исходника.
    package func styleLook(_ style: DocStyle) -> DocStyleLook {
        guard let tab else { return DocStyleLook() }
        if styleLookCache.revision != tab.sourceRevision { styleLookCache = (tab.sourceRevision, [:]) }
        if let cached = styleLookCache.looks[style.id] { return cached }
        var look = DocStyleLook()
        if let properties = styleSheet.properties(of: style) {
            look = DocStyleLook(bold: properties.character.bold, italic: properties.character.italic, halfPoints: properties.character.halfPoints)
        }
        styleLookCache.looks[style.id] = look
        return look
    }
}

package enum DocRibbonStyles {
    /// Сколько плиток при уровне ужатия «Главной»: 0 — четыре, 1 — три, 2 — две; дальше — только кнопка-меню.
    package static func tileCount(level: Int) -> Int { [4, 3, 2][safe: level] ?? 0 }

    /// Сколько абзацев у каждого стиля (абзац без `\sN` — «Обычный», номер 0).
    package static func usage(_ model: RTFDocumentModel) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for paragraph in model.body.paragraphs { result[paragraph.props.style ?? 0, default: 0] += 1 }
        return result
    }

    /// Плитки: самые используемые абзацные стили (при равенстве — по номеру); текущий стиль всегда на виду — встаёт на последнее место.
    package static func tiles(_ sheet: DocStyleSheet, usage: [Int: Int], current: Int?, count: Int) -> [DocStyle] {
        guard count > 0 else { return [] }
        let ranked = sheet.paragraphStyles.sorted { (usage[$0.number] ?? 0, -$0.number) > (usage[$1.number] ?? 0, -$1.number) }
        var result = Array(ranked.prefix(count))
        if let current, !result.contains(where: { $0.number == current }), let style = sheet.style(.paragraph, current), !result.isEmpty {
            result[result.count - 1] = style
        }
        return result
    }

    /// Какой абзацный стиль подсвечен: номер `\sN` абзаца под курсором, а у абзаца без `\sN` — «Обычный» (0); `nil` — курсора в тексте нет.
    package static func currentNumber(_ paragraph: RTFParaProps?) -> Int? { paragraph.map { $0.style ?? 0 } }

    /// Подсказка кнопки: название; у недоступной — с причиной.
    package static func tip(_ style: DocStyle, _ availability: DocStyleCommand.Availability) -> String {
        if case .disabled(let reason) = availability { return "Стиль «\(style.displayName)» — \(reason)" }
        return "Стиль «\(style.displayName)»"
    }
}

/// Группа «Стили» на «Главной».
package struct DocStylesGroup: View {
    @ObservedObject package var document: DocumentController
    @ObservedObject package var formatter: DocFormatter
    package let level: Int
    package var last = false

    package init(document: DocumentController, formatter: DocFormatter, level: Int, last: Bool = false) {
        self.document = document
        self.formatter = formatter
        self.level = level
        self.last = last
    }

    private var currentParagraph: Int? { DocRibbonStyles.currentNumber(formatter.state.paragraph) }

    package var body: some View {
        let sheet = document.styleSheet
        let context = document.styleContext
        if context.isDocument, !sheet.paragraphStyles.isEmpty || !sheet.characterStyles.isEmpty {
            let current = currentParagraph
            DS.RibbonGroup("Стили", last: last) {
                let tiles = DocRibbonStyles.tiles(sheet, usage: DocRibbonStyles.usage(document.model), current: current,
                                                  count: DocRibbonStyles.tileCount(level: level))
                if tiles.isEmpty {
                    DS.RibbonMenuButton("Стили: применить стиль абзаца или знаков", systemImage: "textformat", glyph: "Стили", size: .large) {
                        allStyles(sheet, context: context, current: current)
                    }
                } else {
                    ForEach(tiles) { style in tile(style, context: context, current: current) }
                    DS.RibbonMenuButton("Все стили", systemImage: "chevron.down") { allStyles(sheet, context: context, current: current) }
                }
            }
        }
    }

    private func tile(_ style: DocStyle, context: DocStyleCommand.Context, current: Int?) -> some View {
        let availability = DocStyleCommand.availability(style, in: context)
        let look = document.styleLook(style)
        let isCurrent = style.number == current
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            document.applyStyle(style)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("АаБбВв")
                    .font(.system(size: look.previewSize, weight: look.bold ? .bold : .regular, design: .serif))
                    .italic(look.italic)
                    .lineLimit(1)
                Text(style.displayName)
                    .font(DS.Font.manrope(9.5, .semibold, relativeTo: .caption2))
                    .foregroundStyle(.dsMute)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(width: 84, height: 56, alignment: .leading)
            .background(Color.dsField, in: shape)
            .overlay(shape.strokeBorder(Color.dsLine, lineWidth: 1))
            .overlay {
                if isCurrent { shape.strokeBorder(Color.dsAccLine, lineWidth: 2).padding(-3) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!availability.isEnabled)
        .opacity(availability.isEnabled ? 1 : DS.State.disabledOpacity)
        .help(DocRibbonStyles.tip(style, availability))
        .accessibilityLabel("Стиль «\(style.displayName)»")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func allStyles(_ sheet: DocStyleSheet, context: DocStyleCommand.Context, current: Int?) -> some View {
        if !sheet.paragraphStyles.isEmpty {
            Section("Стили абзацев") {
                ForEach(sheet.paragraphStyles) { style in item(style, context: context, isCurrent: style.number == current) }
            }
        }
        if !sheet.characterStyles.isEmpty {
            Section("Стили знаков") {
                ForEach(sheet.characterStyles) { style in
                    item(style, context: context, isCurrent: style.number == document.currentCharacterStyleNumber(formatter.state))
                }
            }
        }
    }

    private func item(_ style: DocStyle, context: DocStyleCommand.Context, isCurrent: Bool) -> some View {
        let availability = DocStyleCommand.availability(style, in: context)
        return Toggle(style.displayName, isOn: Binding(get: { isCurrent }, set: { _ in document.applyStyle(style) }))
            .disabled(!availability.isEnabled)
            .help(DocRibbonStyles.tip(style, availability))
    }
}
