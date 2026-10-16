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

/// Точка «идёт запись»: мигает раз в секунду (без «Уменьшить движение»). Плавная repeatForever-анимация пересчитывалась
/// на каждом кадре и держала ~4,5 % ядра всю запись; шаг раз в секунду совпадает с таймером рядом и почти ничего не стоит.
struct PulsingDot: View {
    var color: Color = .dsRec
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(!reduceMotion && Int(context.date.timeIntervalSinceReferenceDate) % 2 == 1 ? 0.35 : 1)
        }
        .accessibilityHidden(true)
    }
}

/// Знак Mac Utils — ⌘ из иконки приложения: квадрат между четырьмя петлями, в петлях тёмные точки (поле 64×64).
struct AppMark: View {
    var size: CGFloat = 22
    var color: Color = .dsAccText

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 64
            let center = CGPoint(x: 32 * scale, y: 32 * scale)
            let half = 11 * scale, loop = 6.5 * scale
            let corners = [CGPoint(x: center.x - half, y: center.y - half), CGPoint(x: center.x + half, y: center.y - half),
                           CGPoint(x: center.x + half, y: center.y + half), CGPoint(x: center.x - half, y: center.y + half)]
            let square = Path(CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2))
            context.stroke(square, with: .color(color), style: StrokeStyle(lineWidth: max(1.5, 4.6 * scale), lineJoin: .round))
            for point in corners {
                context.fill(Path(ellipseIn: CGRect(x: point.x - loop, y: point.y - loop, width: loop * 2, height: loop * 2)),
                             with: .color(color))
                let pin = max(0.8, 1.8 * scale)
                context.fill(Path(ellipseIn: CGRect(x: point.x - pin, y: point.y - pin, width: pin * 2, height: pin * 2)),
                             with: .color(.black.opacity(0.45)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Mac Utils")
    }
}
