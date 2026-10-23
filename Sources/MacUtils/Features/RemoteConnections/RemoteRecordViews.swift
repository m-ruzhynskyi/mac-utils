import AppKit
import MURemoteConnections
import SwiftUI
import MUCore
import MUDesign

// Метки, значки VPN/RDP, строка «МЕТКИ» и подробности записи — по утверждённому макету (.audit/rc-tags-design).

// MARK: - Цвета макета (тёмная тема — как в макете, светлая — те же оттенки на светлом фоне)

enum RemoteTint {
    struct Set3 {
        let bg: Color
        let fg: Color
        let dot: Color
    }

    private static func c(_ dark: UInt32, _ light: UInt32) -> Color { Color(nsColor: DS.color(dark: dark, light: light)) }

    static let reg = Set3(bg: c(0x1D2B3D, 0xE3EEFB), fg: c(0x8EC3FF, 0x1F5FA8), dot: c(0x5AA5FF, 0x2F7DE1))
    static let phyto = Set3(bg: c(0x1B3024, 0xE2F4E8), fg: c(0x8BE0A8, 0x1E7A44), dot: c(0x4CC97A, 0x2FA65E))
    static let other = Set3(bg: c(0x26292E, 0xEEF0EA), fg: c(0xC9CED6, 0x3D444D), dot: c(0x8A9099, 0x7A828C))
    static let vpn = Set3(bg: c(0x33270F, 0xFFF0DA), fg: c(0xFFB65C, 0xA35F00), dot: c(0xFFB65C, 0xD98200))
    static let rdp = Set3(bg: c(0x251F3D, 0xEEE9FF), fg: c(0xB9A6FF, 0x5B44C7), dot: c(0xB9A6FF, 0x7A63E0))
    static let banner = (bg: c(0x2A2110, 0xFFF6E8), line: c(0x5A4318, 0xF0D2A0), title: c(0xFFD8A3, 0x7A4A00), text: c(0xD9B98C, 0x8A5A10))

    static func of(_ kind: ConnectionTag.Kind) -> Set3 {
        switch kind {
        case .reg: return reg
        case .phyto: return phyto
        case .other: return other
        }
    }
}

// MARK: - Метки и значки

/// Метка записи: «Рег» — синяя, «Фито» — зелёная, остальные — серые; с точкой.
struct RemoteLabelChip: View {
    let title: String
    var large = false
    var selected = false
    var count: Int?

    var body: some View {
        let tint = RemoteTint.of(ConnectionTag.kind(title))
        HStack(spacing: 5) {
            Circle().fill(tint.dot).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(count.map { "\(title) \($0)" } ?? title).lineLimit(1)
        }
        .font(DS.Font.manrope(large ? 12 : 11, .semibold, relativeTo: .caption2))
        .foregroundStyle(tint.fg)
        .padding(.horizontal, large ? 10 : 8)
        .frame(height: large ? 24 : 20)
        .background(tint.bg, in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? tint.fg : .clear, lineWidth: 1.5))
        .fixedSize()
    }
}

/// «+N» после меток, которые не влезли.
struct RemoteMoreChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Font.manrope(11, .semibold, relativeTo: .caption2))
            .foregroundStyle(.dsMute)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(RemoteTint.other.bg, in: Capsule())
            .fixedSize()
    }
}

enum RemoteBadgeKind {
    case vpn, rdp

    var title: String { self == .vpn ? "VPN" : "RDP" }
    var symbol: String { self == .vpn ? "shield" : "display" }
    var tint: RemoteTint.Set3 { self == .vpn ? RemoteTint.vpn : RemoteTint.rdp }
    var help: String { self == .vpn ? RL("Сначала подключите VPN") : RL("Подключение через удалённый рабочий стол") }
}

/// Значок «VPN» (оранжевый щит) или «RDP» (фиолетовый монитор).
struct RemoteMethodBadge: View {
    let kind: RemoteBadgeKind
    var large = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol).font(.system(size: large ? 11 : 9, weight: .bold)).accessibilityHidden(true)
            Text(kind.title)
        }
        .font(DS.Font.manrope(large ? 12 : 10.5, .bold, relativeTo: .caption2))
        .tracking(0.4)
        .foregroundStyle(kind.tint.fg)
        .padding(.horizontal, large ? 10 : 7)
        .frame(height: large ? 24 : 20)
        .background(kind.tint.bg, in: RoundedRectangle(cornerRadius: large ? 12 : 6, style: .continuous))
        .fixedSize()
        .help(kind.help)
    }
}

extension ConnectionRecord {
    var badges: [RemoteBadgeKind] { (needsVPN ? [.vpn] : []) + (usesRDP ? [.rdp] : []) }
}

/// Метки одной строкой: сколько влезло + «+N» (в подсказке — остальные).
struct RemoteLabelStrip: View {
    let labels: [String]

    var body: some View {
        let shown = Array(labels.prefix(6))
        ViewThatFits(in: .horizontal) {
            ForEach((0...shown.count).reversed(), id: \.self) { k in
                HStack(spacing: 5) {
                    ForEach(Array(shown.prefix(k).enumerated()), id: \.offset) { _, tag in
                        RemoteLabelChip(title: ConnectionTag.display(tag))
                    }
                    if labels.count > k {
                        RemoteMoreChip(text: "+\(labels.count - k)")
                            .help(labels.dropFirst(k).map(ConnectionTag.display).joined(separator: ", "))
                    }
                }
            }
        }
    }
}

/// Капсула программы: «● AD», «● TV», «● RDP», «● VPN», «● Другое».
struct RemoteKindBadge: View {
    let record: ConnectionRecord
    let program: RemoteProgram
    var dimmed = false

    var body: some View {
        if let method = record.method {
            HStack(spacing: 4) {
                Circle().fill(method == .rdp ? RemoteTint.rdp.dot : method == .vpn ? RemoteTint.vpn.dot : RemoteTint.other.dot)
                    .frame(width: 6, height: 6)
                Text(method.title).font(DS.Font.keycapCompact).foregroundStyle(.dsText)
            }
            .padding(.vertical, 3).padding(.horizontal, 7)
            .background(Color.dsPanel, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
            .accessibilityLabel(method.title)
        } else {
            RemoteProgramBadge(program: program, dimmed: dimmed)
        }
    }
}

// MARK: - Строка «МЕТКИ»

/// Фильтры по меткам: «Рег», «Фито», остальные по частоте, «ещё N». Можно выбрать несколько.
struct RemoteTagFilterRow: View {
    let tags: [TagCount]
    @Binding var selected: Set<String>
    @State private var expanded = false

    private let visible = 4

    var body: some View {
        if !tags.isEmpty {
            FlowLayout(spacing: 6) {
                Text(RL("МЕТКИ")).font(DS.Font.manrope(11, .bold, relativeTo: .caption2)).tracking(1.1)
                    .foregroundStyle(.dsMute).frame(height: 24)
                ForEach(shown, id: \.key) { tag in
                    Button {
                        if selected.contains(tag.key) { selected.remove(tag.key) } else { selected.insert(tag.key) }
                    } label: {
                        RemoteLabelChip(title: tag.title, large: true, selected: selected.contains(tag.key), count: tag.count)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected.contains(tag.key) ? .isSelected : [])
                }
                if hidden > 0 {
                    Button { expanded = true } label: {
                        Text(RL("ещё %@", hidden))
                            .font(DS.Font.manrope(12, .semibold, relativeTo: .caption))
                            .foregroundStyle(.dsMute)
                            .padding(.horizontal, 8).frame(height: 24)
                            .overlay(Capsule().strokeBorder(Color.dsLine, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Выбранные видны всегда, даже если не в первых четырёх.
    private var shown: [TagCount] {
        if expanded { return tags }
        let head = Array(tags.prefix(visible))
        return head + tags.dropFirst(visible).filter { selected.contains($0.key) }
    }

    private var hidden: Int { tags.count - shown.count }
}

/// Чип фильтра программы со значком (RDP, VPN) — как `Chip`.
struct RemoteFilterChip: View {
    let title: String
    var badge: RemoteBadgeKind?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        if let badge {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: badge.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(badge.tint.fg)
                    Text(title)
                }
                .font(selected ? DS.Font.chip : DS.Font.manrope(13, .semibold, relativeTo: .callout))
                .foregroundStyle(selected ? Color.dsAccInk : Color.dsMute)
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
                .capsuleFill(selected ? Color.dsAcc : Color.dsField, border: selected ? Color.dsAccLine : Color.dsLine)
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            Chip(title, selected: selected, action: action)
        }
    }
}

// MARK: - Подробности

/// Подробности записи (по «i» или по значку): метки, VPN, RDP, учётка, заметка, «Доступ» из файла.
/// Пароль учётки на экран не выводится; «Доступ» — только по «Показать» и только пока открыт этот экран.
struct RemoteDetailsView: View {
    let record: ConnectionRecord
    @ObservedObject var center: RemoteConnectionsCenter
    let onBack: () -> Void

    @State private var access: String?
    @State private var accessError: String?
    /// Разобранные строки «Доступа» про VPN/RDP — только пока открыта карточка.
    @State private var info: AccessInfo?
    @State private var contacts: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !record.labels.isEmpty || !record.badges.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(Array(record.labels.enumerated()), id: \.offset) { _, tag in
                                RemoteLabelChip(title: ConnectionTag.display(tag), large: true)
                            }
                            ForEach(record.badges, id: \.title) { RemoteMethodBadge(kind: $0, large: true) }
                        }
                    }
                    if record.needsVPN { vpnBanner }
                    if record.needsVPN || record.usesRDP || info?.vpn != nil || info?.rdp != nil { howToConnect }
                    if !record.account.isEmpty || record.hasAccountPassword { accountCard }
                    if let contacts, !contacts.isEmpty { contactsCard(contacts) }
                    if !record.note.isEmpty {
                        card {
                            label(RL("ЗАМЕТКА"))
                            Text(record.note).font(DS.Font.manrope(13.5, .regular, relativeTo: .body)).foregroundStyle(.dsText)
                                .lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if record.accessLines > 0 { accessCard }
                }
                .padding(.bottom, DS.Space.s)
            }
        }
        .onExitCommand(perform: back)
        .task(id: record.identity) { await loadDetails() }
        .onDisappear(perform: forget)
    }

    private func back() {
        forget()
        onBack()
    }

    private func forget() {
        access = nil
        info = nil
        contacts = nil
    }

    /// «Как подключиться» и «Контакты» — из файла при открытии карточки; текст «Доступа» тут же отпускается.
    private func loadDetails() async {
        if record.accessLines > 0, let secret = await center.readSecret(.access, of: record) {
            info = secret.withBytes { AccessParser.parse(String(decoding: $0, as: UTF8.self)) }
            secret.wipe()
        }
        if record.hasContacts, let secret = await center.readSecret(.contacts, of: record) {
            contacts = secret.withBytes { String(decoding: $0, as: UTF8.self) }
            secret.wipe()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(.dsText)
                    .frame(width: 32, height: 32)
                    .background(Color.dsField, in: Circle())
                    .overlay(Circle().strokeBorder(Color.dsLine, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(RL("Назад к списку"))
            .accessibilityLabel(RL("Назад к списку"))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(DS.Font.manrope(17, .bold, relativeTo: .title3)).foregroundStyle(.dsText).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(DS.Font.manrope(12.5, .regular, relativeTo: .caption)).foregroundStyle(.dsMute).lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !record.group.isEmpty { parts.append(RL("Группа «%@»", record.group)) }
        parts.append(record.method?.title ?? record.program(default: center.defaultProgram).title)
        if !record.id.isEmpty { parts.append(record.displayID) }
        return parts.joined(separator: " · ")
    }

    private var vpnBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield").font(.system(size: 15, weight: .bold)).foregroundStyle(RemoteTint.vpn.fg)
            VStack(alignment: .leading, spacing: 3) {
                Text(RL("Сначала подключите VPN")).font(DS.Font.manrope(13.5, .bold, relativeTo: .body)).foregroundStyle(RemoteTint.banner.title)
                Text(record.accessLines > 0 ? RL("Компьютер виден только через VPN. Профиль и ключ — в разделе «Доступ» ниже.")
                                            : RL("Компьютер виден только через VPN."))
                    .font(DS.Font.manrope(12.5, .regular, relativeTo: .caption)).foregroundStyle(RemoteTint.banner.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RemoteTint.banner.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(RemoteTint.banner.line, lineWidth: 1))
    }

    /// «Как подключиться»: VPN (тип, сервер, логин, скрытый пароль или ключ) и RDP (адрес, логин, открыть).
    /// Не разобралось — соответствующие строки «Доступа» как есть.
    private var howToConnect: some View {
        card {
            label(RL("КАК ПОДКЛЮЧИТЬСЯ"))
            if record.needsVPN || info?.vpn != nil { vpnSection }
            if record.usesRDP || info?.rdp != nil { rdpSection }
        }
    }

    @ViewBuilder private var vpnSection: some View {
        let vpn = info?.vpn
        HStack(spacing: 8) {
            Image(systemName: "shield").font(.system(size: 12, weight: .bold)).foregroundStyle(RemoteTint.vpn.fg)
            label("VPN", color: RemoteTint.vpn.fg)
            if let kind = vpn?.kind { Text(kind).font(DS.Font.manrope(13, .semibold, relativeTo: .body)).foregroundStyle(.dsText) }
        }
        if let vpn, vpn.server != nil || vpn.login != nil || vpn.secret != nil {
            if let server = vpn.server { fact(RL("Сервер"), server, mono: true) }
            if let login = vpn.login { fact(RL("Логин"), login) }
            if let secret = vpn.secret {
                HStack(spacing: 10) {
                    Text(RL("Пароль или ключ")).font(DS.Font.rowSub).foregroundStyle(.dsMute).frame(width: 110, alignment: .leading)
                    Text("••••••••").font(.system(size: 15)).tracking(3).foregroundStyle(.dsMute).accessibilityHidden(true)
                    Spacer(minLength: 4)
                    Button(RL("Скопировать")) { center.copyConcealed(secret, title: RL("Пароль VPN скопирован")) }
                        .buttonStyle(.graphite(.secondary, size: .compact))
                        .accessibilityLabel(RL("Скопировать пароль VPN"))
                }
            }
        } else if let lines = vpn?.lines, !lines.isEmpty {
            rawLines(lines)
        } else {
            Text(record.accessLines > 0 ? RL("Профиль и ключ — в разделе «Доступ» ниже.") : RL("Подробностей о VPN в файле нет."))
                .font(DS.Font.rowSub).foregroundStyle(.dsMute)
        }
    }

    @ViewBuilder private var rdpSection: some View {
        let rdp = info?.rdp
        let address = record.method == .rdp && !record.id.isEmpty ? record.id : rdp?.address
        let login = record.account.isEmpty ? rdp?.login : record.account
        HStack(spacing: 8) {
            Image(systemName: "display").font(.system(size: 12, weight: .bold)).foregroundStyle(RemoteTint.rdp.fg)
            label(RL("ПОДКЛЮЧЕНИЕ ЧЕРЕЗ RDP"), color: RemoteTint.rdp.fg)
        }
        if let address {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(address).font(DS.Font.mono(16, relativeTo: .body).weight(.bold)).foregroundStyle(.dsText).textSelection(.enabled)
                Text(RL("удалённый рабочий стол")).font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
            if let login { fact(RL("Логин"), login) }
            HStack(spacing: 8) {
                if RDPLink.isValidHost(address) {
                    Button(RL("Открыть в Windows App ⏎")) { center.openRDP(record, host: address, account: login ?? "") }
                        .buttonStyle(.graphite(.primary, size: .compact)).keyboardShortcut(.defaultAction)
                }
                Button(RL("Скопировать адрес")) { center.copyPlain(address, title: RL("Адрес скопирован")) }
                    .buttonStyle(.graphite(.secondary, size: .compact))
            }
        } else if let lines = rdp?.lines, !lines.isEmpty {
            rawLines(lines)
        } else {
            Text(RL("Адрес — в разделе «Доступ».")).font(DS.Font.rowSub).foregroundStyle(.dsMute)
        }
    }

    private func contactsCard(_ text: String) -> some View {
        card {
            label(RL("КОНТАКТЫ"))
            Text(text).font(DS.Font.manrope(13.5, .regular, relativeTo: .body)).foregroundStyle(.dsText)
                .lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(ContactPhones.find(in: text).enumerated()), id: \.offset) { _, phone in
                HStack(spacing: 10) {
                    Image(systemName: "phone").font(.system(size: 12, weight: .semibold)).foregroundStyle(.dsMute)
                    Text(phone).font(DS.Font.mono(13, relativeTo: .body)).foregroundStyle(.dsText)
                    Spacer(minLength: 4)
                    Button(RL("Скопировать")) { center.copyPlain(phone, title: RL("Телефон скопирован")) }
                        .buttonStyle(.graphite(.secondary, size: .compact))
                        .accessibilityLabel(RL("Скопировать телефон %@", phone))
                }
            }
        }
    }

    private func fact(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title).font(DS.Font.rowSub).foregroundStyle(.dsMute).frame(width: 110, alignment: .leading)
            Text(value).font(mono ? DS.Font.mono(13, relativeTo: .body) : DS.Font.manrope(13.5, .semibold, relativeTo: .body))
                .foregroundStyle(.dsText).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func rawLines(_ lines: [String]) -> some View {
        Text(lines.joined(separator: "\n")).font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsText)
            .lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.dsBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var accountCard: some View {
        card {
            label(RL("УЧЁТКА WINDOWS"))
            HStack(spacing: 10) {
                Text(record.account.isEmpty ? "—" : record.account).font(DS.Font.manrope(14, .semibold, relativeTo: .body))
                    .foregroundStyle(.dsText).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 4)
                if record.hasAccountPassword {
                    Text("••••••••").font(.system(size: 15)).tracking(3).foregroundStyle(.dsMute).accessibilityHidden(true)
                    Button(RL("Копировать пароль")) { center.copySecret(.accountPassword, of: record) }
                        .buttonStyle(.graphite(.secondary, size: .compact))
                        .accessibilityLabel(RL("Скопировать пароль учётки"))
                }
            }
            if record.hasAccountPassword {
                Text(RL("Буфер очистится через 30 с. Пароль на экране не показывается."))
                    .font(DS.Font.manrope(11.5, .regular, relativeTo: .caption2)).foregroundStyle(.dsMute)
            }
        }
    }

    private var accessCard: some View {
        card {
            HStack(spacing: 8) {
                label(RL("ДОСТУП · ИЗ ФАЙЛА")).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if access == nil { Task { await loadAccess() } } else { access = nil }
                } label: {
                    Label(access == nil ? RL("Показать") : RL("Скрыть"), systemImage: access == nil ? "eye" : "eye.slash")
                }
                .buttonStyle(.graphite(.secondary, size: .compact))
                Button(RL("Скопировать")) { center.copySecret(.access, of: record) }
                    .buttonStyle(.graphite(.secondary, size: .compact))
            }
            ZStack {
                if let access {
                    // Переносы и пустые строки между блоками — как в файле.
                    Text(access).font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsText)
                        .lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else {
                    // Вместо текста — размытые полосы: самого «Доступа» до «Показать» в окне нет.
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(0..<min(record.accessLines, 8), id: \.self) { i in
                            Capsule().fill(Color.dsMute.opacity(0.45))
                                .frame(width: [190, 240, 150, 120, 210, 230, 170, 140][i % 8], height: 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .blur(radius: 3)
                    Text(accessError ?? RL("%@ · могут быть пароли", RL("строк скрыто: %@", record.accessLines)))
                        .font(DS.Font.manrope(12.5, .regular, relativeTo: .caption)).foregroundStyle(.dsText)
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(Color.dsBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            Text(RL("Всё, что было на вкладке в Excel, без изменений. Не участвует в поиске и не пишется в журнал."))
                .font(DS.Font.manrope(11.5, .regular, relativeTo: .caption2)).foregroundStyle(.dsMute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadAccess() async {
        accessError = nil
        guard let secret = await center.readSecret(.access, of: record) else {
            accessError = RL("Не удалось прочитать файл")
            return
        }
        defer { secret.wipe() }
        access = secret.withBytes { String(decoding: $0, as: UTF8.self) }
    }

    private func label(_ text: String, color: Color = .dsMute) -> some View {
        Text(text).font(DS.Font.manrope(11, .bold, relativeTo: .caption2)).tracking(1.3).foregroundStyle(color)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }
}
