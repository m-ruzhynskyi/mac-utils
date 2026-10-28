import AppKit
import SwiftUI

/// Квадратная кнопка-значок индикатора: 26×26, радиус 8; «Стоп» — красная.
package struct HUDIconButton: View {
    package init(symbol: String, help: String, kind: Kind = .plain, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.kind = kind
        self.action = action
    }

    package enum Kind { case plain, stop }
    package let symbol: String
    package let help: String
    package var kind: Kind = .plain
    package let action: () -> Void

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind == .stop ? Color.dsRecInk : Color.dsText)
                .frame(width: 26, height: 26)
                .background(kind == .stop ? Color.dsRec : Color.dsField, in: shape)
                .overlay(shape.strokeBorder(kind == .stop ? .clear : Color.dsLine, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}
