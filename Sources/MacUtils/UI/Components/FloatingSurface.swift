import SwiftUI

/// Форма плавающей панели: `panel` — радиус 20 (панель с содержимым), `pill` — капсула (статусы).
enum FloatingShape {
    case panel, pill
}

private struct FloatingModifier: ViewModifier {
    let shape: FloatingShape

    func body(content: Content) -> some View {
        switch shape {
        case .panel:
            let outline = RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous)
            content
                .padding(14)
                .background(Color.dsPanel, in: outline)
                .overlay(outline.strokeBorder(Color.dsLine, lineWidth: 1))
        case .pill:
            content
                .padding(.vertical, 6)
                .padding(.horizontal, DS.Space.m)
                .capsuleFill(Color.dsPanel, border: Color.dsLine)
        }
    }
}

extension View {
    /// Фон `panel`, обводка `line` и поля плавающей панели. Тень даёт окно (`hasShadow`).
    func floating(_ shape: FloatingShape = .panel) -> some View {
        modifier(FloatingModifier(shape: shape))
    }
}

/// Индикатор «идёт…» (запись экрана, встреча, эфир): таблетка капсом с пульсирующей точкой, время, пояснение, кнопки.
struct LiveIndicator<Actions: View>: View {
    enum Kind {
        case recording, meeting, broadcast

        var label: String {
            switch self {
            case .recording: return "Запись"
            case .meeting: return "Встреча"
            case .broadcast: return "В эфире"
            }
        }
    }

    let kind: Kind
    var since: Date?
    var detail: String?
    var warning: String?
    let actions: Actions

    init(_ kind: Kind, since: Date? = nil, detail: String? = nil, warning: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.kind = kind
        self.since = since
        self.detail = detail
        self.warning = warning
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                PulsingDot(color: .dsRecInk)
                Text(kind.label.uppercased()).font(DS.Font.groupLabel).tracking(DS.Font.tracking(0.06, size: 11))
            }
            .foregroundStyle(Color.dsRecInk)
            .padding(.vertical, DS.Space.xs)
            .padding(.horizontal, 10)
            .background(Color.dsRec, in: Capsule())
            if let since {
                Text(since, style: .timer).font(DS.Font.mono).foregroundStyle(.dsText)
            }
            if let detail {
                Text(detail).font(DS.Font.caption).foregroundStyle(.dsMute)
            }
            if let warning {
                Label(warning, systemImage: DS.Tone.warning.symbol).font(DS.Font.caption).foregroundStyle(DS.Tone.warning.text)
            }
            actions
        }
        .floating(.pill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.label)
    }
}

extension LiveIndicator where Actions == EmptyView {
    init(_ kind: Kind, since: Date? = nil, detail: String? = nil, warning: String? = nil) {
        self.init(kind, since: since, detail: detail, warning: warning) { EmptyView() }
    }
}

/// Точка «идёт запись»: пульсирует, если не включено «Уменьшить движение».
struct PulsingDot: View {
    var color: Color = .dsRec
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// Знак Mac Utils из концепта: «M» линией (`M14 46V18l18 20 18-20v28` в поле 64×64).
struct AppMark: View {
    var size: CGFloat = 22
    var color: Color = .dsAccText

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 64
            var path = Path()
            path.move(to: CGPoint(x: 14 * scale, y: 46 * scale))
            path.addLine(to: CGPoint(x: 14 * scale, y: 18 * scale))
            path.addLine(to: CGPoint(x: 32 * scale, y: 38 * scale))
            path.addLine(to: CGPoint(x: 50 * scale, y: 18 * scale))
            path.addLine(to: CGPoint(x: 50 * scale, y: 46 * scale))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: max(1.5, 5.5 * scale), lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Mac Utils")
    }
}
