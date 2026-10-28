import AppKit
import SwiftUI
import MUDesign

/// Палитры «Цвет текста» и «Цвет выделения» (`d09b`): «Авто» / «Нет цвета», стандартные цвета, цвета этого документа,
/// «Другой цвет…».
package enum FormatPalette {
    /// Цвет текста: оттенки серого, насыщенные и светлые (как на макете).
    package static let text: [RTFColor] = [
        0x000000, 0x404040, 0x808080, 0xA6A6A6, 0xF2F2F2, 0xC00000,
        0xE46C0A, 0xFFC000, 0x00B050, 0x0070C0, 0x002060, 0x7030A0,
        0xF2DCDB, 0xFDE9D9, 0xFFF2CC, 0xEBF1DE, 0xDBE5F1, 0xE5E0EC,
    ].map(rgb)

    /// Маркер — 15 цветов выделения Word: другие Word всё равно покажет ближайшим из них.
    package static let highlight: [RTFColor] = [
        0xFFFF00, 0x00FF00, 0x00FFFF, 0xFF00FF, 0x0000FF,
        0xFF0000, 0x000080, 0x008080, 0x008000, 0x800080,
        0x800000, 0x808000, 0x808080, 0xC0C0C0, 0x000000,
    ].map(rgb)

    package static func rgb(_ hex: UInt32) -> RTFColor {
        RTFColor(red: Int(hex >> 16 & 0xFF), green: Int(hex >> 8 & 0xFF), blue: Int(hex & 0xFF))
    }

    package static func color(_ color: RTFColor) -> Color {
        Color(nsColor: NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1))
    }

    /// Цвета из `\colortbl`, которыми написан текст (без повторов, не больше 12).
    package static func used(in model: RTFDocumentModel) -> [RTFColor] {
        var seen: [RTFColor] = []
        func visit(_ story: RTFStory) {
            for paragraph in story.paragraphs {
                for run in paragraph.runs where FormatEdits.isTarget(run.kind) {
                    if let color = model.color(run.props.color), !seen.contains(color) { seen.append(color) }
                    if seen.count >= 12 { return }
                }
            }
        }
        visit(model.body)
        return seen
    }

    package static func name(_ color: RTFColor) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }
}

/// Сетка цветов с заголовком, «Авто»/«Нет цвета», цветами документа и «Другой цвет…».
package struct FormatColorPalette: View {
    package let title: String
    package let noneTitle: String
    package let colors: [RTFColor]
    package let columns: Int
    package let documentColors: [RTFColor]
    package let current: RTFColor??
    package let choose: (RTFColor?) -> Void
    @State private var custom = Color.black

    package var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            label(title)
            Button { choose(nil) } label: {
                HStack(spacing: DS.Space.m) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(noneTitle == "Авто" ? Color.black : Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.dsLine))
                        .overlay { if noneTitle != "Авто" { Image(systemName: "slash.circle").foregroundStyle(Color.dsMute) } }
                        .frame(width: 22, height: 22)
                    Text(noneTitle).font(DS.Font.rowTitle).foregroundStyle(Color.dsText)
                    Spacer()
                    if current == .some(nil) { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).accessibilityHidden(true) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(noneTitle)
            grid(colors, columns: columns)
            if !documentColors.isEmpty {
                label("В этом документе")
                grid(documentColors, columns: columns)
            }
            ColorPicker(selection: Binding(get: { custom }, set: { value in
                custom = value
                if let picked = NSColor(value).usingColorSpace(.sRGB) {
                    choose(RTFColor(red: Int((picked.redComponent * 255).rounded()), green: Int((picked.greenComponent * 255).rounded()),
                                    blue: Int((picked.blueComponent * 255).rounded())))
                }
            }), supportsOpacity: false) {
                Text("Другой цвет…").font(DS.Font.rowTitle).foregroundStyle(Color.dsText)
            }
        }
        .padding(DS.Space.l)
        .frame(width: CGFloat(columns) * 34 + 2 * DS.Space.l)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(DS.Font.groupLabel).tracking(DS.Font.tracking(0.08, size: 11)).foregroundStyle(Color.dsMute)
            .accessibilityAddTraits(.isHeader)
    }

    private func grid(_ colors: [RTFColor], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: columns), alignment: .leading, spacing: 8) {
            ForEach(colors, id: \.self) { color in
                let selected = current == .some(color)
                Button { choose(color) } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(FormatPalette.color(color))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? Color.dsAccLine : Color.dsLine,
                                                                                              lineWidth: selected ? 2.5 : 1))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(FormatPalette.name(color))
                .accessibilityLabel("Цвет \(FormatPalette.name(color))")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
