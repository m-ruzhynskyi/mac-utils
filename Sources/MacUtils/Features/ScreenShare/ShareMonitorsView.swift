import SwiftUI

/// Схема мониторов ведущего: прямоугольники в пропорциях его раскладки (`at`), номер и масштаб внутри, у основного —
/// полоска меню сверху. Текущий — лайм, переключаемый — пунктирная лаймовая рамка со спиннером, под курсором — подсветка.
struct MonitorMap: View {
    let displays: [ShareDisplay]
    var current: Int?
    var pending: Int?
    var hover: Int?
    var height: CGFloat = 40
    var showsScale = true
    /// Плитки — кнопки (панель зрителя); без этого — просто схема (уведомление ведущему).
    var onTap: ((Int) -> Void)?
    var onHover: ((Int?) -> Void)?

    private let gap: CGFloat = 3
    private var bounds: CGRect { displays.map(\.at).reduce(displays.first?.at ?? .zero) { $0.union($1) } }
    private var unit: CGFloat { height / max(bounds.height, 1) }

    var body: some View {
        let box = bounds, k = unit
        ZStack(alignment: .topLeading) {
            ForEach(displays, id: \.n) { display in
                button(display)
                    .frame(width: max(4, display.at.width * k - gap), height: max(4, display.at.height * k - gap))
                    .offset(x: (display.at.minX - box.minX) * k, y: (display.at.minY - box.minY) * k)
            }
        }
        .frame(width: max(4, box.width * k - gap), height: max(4, box.height * k - gap), alignment: .topLeading)
    }

    @ViewBuilder private func button(_ display: ShareDisplay) -> some View {
        if let onTap {
            Button { onTap(display.n) } label: { tile(display).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { onHover?(display.n) } else if hover == display.n { onHover?(nil) }
                }
                .accessibilityLabel(display.accessibilityLabel(current: current))
                .accessibilityAddTraits(display.n == current ? .isSelected : [])
        } else {
            tile(display).accessibilityHidden(true)
        }
    }

    @ViewBuilder private func tile(_ display: ShareDisplay) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let isCurrent = display.n == current, isPending = display.n == pending, isHover = display.n == hover
        ZStack {
            shape.fill(isCurrent ? Color.dsAcc : (isHover ? Color.dsOff : Color.dsField))
            if isPending {
                shape.strokeBorder(Color.dsAccLine, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            } else if !isCurrent {
                shape.strokeBorder(Color.dsLine, lineWidth: 1)
            }
            if display.primary {
                VStack {
                    Capsule().fill(isCurrent ? Color.dsAccInk.opacity(0.55) : Color.dsMute.opacity(0.6))
                        .frame(width: max(10, (display.at.width * unit - gap) * 0.45), height: 2.5)
                        .padding(.top, 3)
                    Spacer(minLength: 0)
                }
            }
            VStack(spacing: isPending ? 2 : 0) {
                Text("\(display.n)").font(DS.Font.manrope(height >= 36 ? 14 : 10, .heavy, relativeTo: .caption))
                if isPending {
                    MonitorSpinner()
                } else if showsScale && height >= 36 {
                    Text(display.percent.replacingOccurrences(of: " ", with: "")).font(DS.Font.mono(9, relativeTo: .caption2)).opacity(0.75)
                }
            }
            .foregroundStyle(isCurrent ? Color.dsAccInk : Color.dsText)
            .padding(.top, display.primary ? 3 : 0)
        }
    }
}

/// Небольшой спиннер на плитке, к которой идёт переключение.
private struct MonitorSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.dsAccText.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: 0.3).stroke(Color.dsAccText, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turning ? 300 : -60))
        }
        .frame(width: 10, height: 10)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}

/// Уведомление ведущему (в окне меток, не в картинке): кто переключил и мини-схема с новым текущим.
struct ShareHostNotice: Equatable {
    let name: String
    let monitor: Int
    let displays: [ShareDisplay]

    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Зритель" : name }
    var title: String { "\(displayName) переключает на монитор \(monitor)" }
}

@MainActor
final class ShareHostNotices: ObservableObject {
    static let lifetime: TimeInterval = 4

    @Published private(set) var current: ShareHostNotice?
    /// Отступ сверху: строка меню и индикатор «Эфир».
    @Published private(set) var top: CGFloat = 44
    private var hideTask: Task<Void, Never>?

    func show(_ notice: ShareHostNotice, top: CGFloat) {
        self.top = top
        current = notice
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        current = nil
    }
}

struct ShareHostNoticeLayer: View {
    @ObservedObject var notices: ShareHostNotices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let notice = notices.current {
                HostSwitchNotice(notice: notice)
                    .padding(.top, notices.top)
                    .padding(.trailing, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.animation(DS.Motion.toggle, reduceMotion: reduceMotion), value: notices.current)
        .allowsHitTesting(false)
    }
}

struct HostSwitchNotice: View {
    let notice: ShareHostNotice

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Text(String(notice.displayName.prefix(1)).uppercased())
                .font(DS.Font.manrope(13, .heavy, relativeTo: .headline))
                .foregroundStyle(.dsText)
                .frame(width: 30, height: 30)
                .background(Color.dsField, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title).font(DS.Font.bodyStrong).foregroundStyle(.dsText)
                Text("Зрители видят этот экран").font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
            MonitorMap(displays: notice.displays, current: notice.monitor, height: 22, showsScale: false)
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Раздел «Монитор» в панели зрителя: схема-кнопки, подсказка над плиткой под курсором.
struct MonitorSwitcher: View {
    let picker: ShareMonitorPicker
    let request: (Int) -> Void
    @State private var hover: Int?

    var body: some View {
        MonitorMap(displays: picker.list, current: picker.current, pending: picker.pending, hover: hover, height: 40,
                   onTap: request, onHover: { hover = $0 })
            .padding(.horizontal, 4)
            .overlay(alignment: .topTrailing) {
                if let hover, let display = picker.list.first(where: { $0.n == hover }) {
                    MonitorTip(display: display).offset(x: 8, y: -52).allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Монитор ведущего")
    }
}

/// Подсказка над плиткой: «Монитор 3 · 1920×1080 · 100 %» и клавиша.
struct MonitorTip: View {
    let display: ShareDisplay

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(display.title).font(DS.Font.caption).foregroundStyle(.dsText)
            Text("\(display.n)").font(DS.Font.keycapCompact).foregroundStyle(.dsText)
                .frame(minWidth: 20, minHeight: 20)
                .background(Color.dsField, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .fixedSize()
        .accessibilityHidden(true)
    }
}
