import SwiftUI

enum PermissionKind: CaseIterable {
    case accessibility, screenRecording, microphone, fullDiskAccess, automation

    var title: String {
        switch self {
        case .accessibility: return "Универсальный доступ"
        case .screenRecording: return "Запись экрана"
        case .microphone: return "Микрофон"
        case .fullDiskAccess: return "Полный доступ к диску"
        case .automation: return "Автоматизация"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "hand.raised"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .microphone: return "mic"
        case .fullDiskAccess: return "internaldrive"
        case .automation: return "gearshape.2"
        }
    }
}

enum PermissionState: Equatable {
    case granted, needed, denied

    var tone: DS.Tone {
        switch self {
        case .granted: return .success
        case .needed: return .warning
        case .denied: return .danger
        }
    }

    var label: String {
        switch self {
        case .granted: return "Выдано"
        case .needed: return "Нужно"
        case .denied: return "Запрещено"
        }
    }
}

/// Разрешение строкой карточки: плитка, название, зачем нужно, справа — «Выдано» или кнопки.
struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let purpose: String
    var actionTitle = "Открыть настройки"
    var action: (() -> Void)?
    /// «Запись экрана» и «Полный доступ к диску» действуют только после перезапуска — рядом «Перезапустить».
    var relaunchHint = false
    /// Прежняя фраза статуса («Универсальный доступ выдан») — для VoiceOver.
    var statusText: String?

    init(_ kind: PermissionKind, state: PermissionState, purpose: String, actionTitle: String = "Открыть настройки",
         action: (() -> Void)? = nil, relaunchHint: Bool = false, statusText: String? = nil) {
        self.kind = kind
        self.state = state
        self.purpose = purpose
        self.actionTitle = actionTitle
        self.action = action
        self.relaunchHint = relaunchHint
        self.statusText = statusText
    }

    var body: some View {
        Row(kind.title, subtitle: purpose, systemImage: kind.symbol) {
            HStack(spacing: DS.Space.s) {
                if state == .granted {
                    Pill(.success, state.label)
                } else {
                    if state == .denied { Pill(.danger, state.label) }
                    if let action { Button(actionTitle, action: action).buttonStyle(.graphite(.primary, size: .compact)) }
                    if relaunchHint {
                        Button("Перезапустить") { Permissions.relaunch() }
                            .buttonStyle(.graphite(.secondary, size: .compact))
                            .help("Уже выдали разрешение? Оно начнёт действовать после перезапуска Mac Utils")
                    }
                }
            }
        }
        .accessibilityValue(statusText ?? state.label)
    }
}

/// Разрешение отдельной карточкой (первый запуск): нужное — рамка 2 pt `accLine`, выданное — «Выдано», необязательное — «Позже».
struct PermissionCard: View {
    let title: String
    let purpose: String
    let state: PermissionState
    var optional = false
    var actionTitle = "Открыть настройки"
    var action: (() -> Void)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        let highlighted = state != .granted && !optional
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.manrope(15, .bold, relativeTo: .body)).foregroundStyle(.dsText)
                Text(purpose).font(DS.Font.manrope(13, .regular, relativeTo: .callout)).foregroundStyle(.dsMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.m)
            if state == .granted {
                Pill(.success, state.label)
            } else if optional {
                Pill(.neutral, "Позже")
            } else if let action {
                Button(actionTitle, action: action).buttonStyle(.graphite(.primary))
            }
        }
        .padding(.vertical, DS.Space.l)
        .padding(.horizontal, 18)
        .background(Color.dsPanel, in: shape)
        .overlay(shape.strokeBorder(highlighted ? Color.dsAccLine : Color.dsLine, lineWidth: highlighted ? 2 : 1))
        .accessibilityElement(children: .combine)
        .accessibilityValue(state.label)
    }
}

/// Кнопка в строке статуса.
struct StatusAction: Identifiable {
    let title: String
    var help: String?
    let action: () -> Void
    var id: String { title }
}

/// Статус готовности функции: таблетка тона, пояснение обычным текстом, кнопки.
struct FeatureStatusRow: View {
    let tone: DS.Tone
    let label: String
    var detail: String?
    var actions: [StatusAction] = []

    @Environment(\.dsCardStyle) private var style

    init(tone: DS.Tone, label: String, detail: String? = nil, actions: [StatusAction] = []) {
        self.tone = tone
        self.label = label
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Pill(tone, label)
            if let detail {
                Text(detail).font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            ForEach(actions) { item in
                Button(item.title, action: item.action)
                    .buttonStyle(.graphite(.secondary, size: .compact))
                    .help(item.help ?? item.title)
            }
        }
        .padding(.vertical, style == .panel ? DS.Space.m : DS.Space.s)
        .padding(.horizontal, style == .panel ? 18 : 10)
        .overlay(alignment: .top) {
            if style == .panel { Rectangle().fill(Color.dsLine).frame(height: 1).accessibilityHidden(true) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Предупреждение или подсказка: карточка `panel` с рамкой 2 pt цвета тона и плиткой значка (по образцу выделенной
/// карточки первого запуска). Единственный вид предупреждений.
struct Banner<Actions: View>: View {
    let tone: DS.Tone
    let title: String
    var message: String?
    let actions: Actions

    @Environment(\.colorScheme) private var scheme

    init(_ tone: DS.Tone, title: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.tone = tone
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: tone.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone.ink)
                .frame(width: DS.Size.rowTile, height: DS.Size.rowTile)
                .background(tone.fill, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(tone == .success && scheme == .light ? Color.dsAccLine : .clear, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title).font(DS.Font.manrope(15, .bold, relativeTo: .body)).foregroundStyle(.dsText)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).font(DS.Font.manrope(13, .regular, relativeTo: .callout)).foregroundStyle(.dsMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DS.Space.s) { actions }
                    .padding(.top, DS.Space.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsPanel, in: shape)
        .overlay(shape.strokeBorder(tone.line, lineWidth: 2))
        .accessibilityElement(children: .contain)
    }
}

extension Banner where Actions == EmptyView {
    init(_ tone: DS.Tone, title: String, message: String? = nil) {
        self.init(tone, title: title, message: message) { EmptyView() }
    }
}

/// Пустое состояние: плитка 46 со значком, заголовок, пояснение, главная кнопка. `compact` — внутри карточки.
struct EmptyState: View {
    let title: String
    let systemImage: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var compact = false

    init(_ title: String, systemImage: String, message: String? = nil, actionTitle: String? = nil,
         action: (() -> Void)? = nil, compact: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.compact = compact
    }

    /// Функция выключена — вместо живого списка.
    static func featureOff(_ section: SettingsSection, compact: Bool = true, turnOn: @escaping () -> Void) -> EmptyState {
        EmptyState("Функция выключена", systemImage: section.symbol, actionTitle: "Включить", action: turnOn, compact: compact)
    }

    /// Идёт загрузка.
    static func loading(_ title: String) -> some View {
        VStack(spacing: DS.Space.m) {
            ProgressView().controlSize(.small)
            Text(title).font(DS.Font.body).foregroundStyle(.dsMute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.l)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 18 : 22, weight: .medium))
                .foregroundStyle(.dsMute)
                .frame(width: compact ? DS.Size.rowTile : DS.Size.headerTile, height: compact ? DS.Size.rowTile : DS.Size.headerTile)
                .background(Color.dsField, in: RoundedRectangle(cornerRadius: compact ? DS.Radius.control : DS.Radius.tile,
                                                                style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: DS.Space.xs) {
                Text(title).font(DS.Font.manrope(15, .bold, relativeTo: .body)).foregroundStyle(.dsText)
                if let message {
                    Text(message).font(DS.Font.manrope(13, .regular, relativeTo: .callout)).foregroundStyle(.dsMute)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.graphite(.primary, size: .compact))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        .padding(.vertical, compact ? DS.Space.xl : DS.Space.xxl)
        .accessibilityElement(children: .combine)
    }
}
