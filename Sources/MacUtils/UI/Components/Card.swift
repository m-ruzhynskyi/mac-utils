import SwiftUI

/// Вид карточки-списка: `panel` — карточка страницы настроек (обводка, разделители, строки 13×18);
/// `field` — карточка поповера (фон `field`, отступ 4, строки 8×10 со скруглением, без разделителей).
enum CardStyle {
    case panel, field
}

private struct CardStyleKey: EnvironmentKey {
    static let defaultValue = CardStyle.panel
}

extension EnvironmentValues {
    /// В какой карточке стоит строка (`Row` подстраивает отступы, плитку и разделитель).
    var dsCardStyle: CardStyle {
        get { self[CardStyleKey.self] }
        set { self[CardStyleKey.self] = newValue }
    }
}

/// Карточка-список: строки `Row` одна под другой. Разделители строки рисуют сами; первый скрыт под обводкой карточки.
struct ListCard<Content: View>: View {
    var style: CardStyle = .panel
    let content: Content

    init(style: CardStyle = .panel, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        VStack(spacing: 0) { content }
            .padding(style == .field ? DS.Space.xs : 0)
            .environment(\.dsCardStyle, style)
            .background(style == .panel ? Color.dsPanel : Color.dsField, in: shape)
            .clipShape(shape)
            .overlay { if style == .panel { shape.strokeBorder(Color.dsLine, lineWidth: 1) } }
            .accessibilityElement(children: .contain)
    }
}

/// Карточка со свободным содержимым: `panel`, обводка `line`, радиус 16, поля 16×18.
struct Card<Content: View>: View {
    var style: CardStyle = .panel
    let content: Content

    init(style: CardStyle = .panel, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.vertical, DS.Space.l)
            .padding(.horizontal, style == .panel ? 18 : DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.dsCardStyle, style)
            .background(style == .panel ? Color.dsPanel : Color.dsField, in: shape)
            .overlay { if style == .panel { shape.strokeBorder(Color.dsLine, lineWidth: 1) } }
            .accessibilityElement(children: .contain)
    }
}
