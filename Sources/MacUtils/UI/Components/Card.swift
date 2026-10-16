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

/// Сворачиваемая карточка-список (сочетания и подсказки): заголовок группы со стрелкой; содержимое — строки `Row`.
struct CollapsibleCard<Content: View>: View {
    let title: String
    let content: Content

    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, expanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.section) {
            Button {
                withAnimation(DS.Motion.animation(DS.Motion.standard, reduceMotion: reduceMotion)) { expanded.toggle() }
            } label: {
                HStack(spacing: DS.Space.s) {
                    GroupLabel(title)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.dsMute)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(.top, DS.Space.xs)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
            if expanded {
                ListCard { content }
            }
        }
    }
}

/// Перенос элементов по строкам (чипы вкладок и т. п.).
struct FlowLayout: Layout {
    var spacing: CGFloat = DS.Space.s
    var lineSpacing: CGFloat = DS.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map { $0.height }.reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if needed > width, !line.indices.isEmpty {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}
