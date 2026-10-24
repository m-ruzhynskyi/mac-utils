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

// MARK: - Подробности

/// Карточка записи по утверждённому макету (.audit/rc-tags-design/Details, Accounts): метки, «Как подключиться» шагами
/// из блоков «Доступа», учётные записи, пароль подключения, «Доступ · как в файле» (пароли под маской), контакты внизу.
/// Пароли — «••••••••»; 👁 показывает на 10 с, ⧉ копирует скрыто от истории буфера. Всё разобранное живёт только пока
/// открыта карточка; в журнал и поиск не попадает.
struct RemoteDetailsView: View {
    let record: ConnectionRecord
    @ObservedObject var center: RemoteConnectionsCenter
    let onBack: () -> Void

    @State private var card = ConnectionCard()
    @State private var contacts: [ConnectionContact] = []
    /// «Доступ · как в файле» после «Показать» — построчно под маской.
    @State private var access: String?
    @State private var accessError: String?
    @State private var reveal = SecretReveal()
    /// Показанные сейчас значения: ключ поля → текст. Истёк срок — значение убирается.
    @State private var revealed: [String: String] = [:]
    @State private var now = Date()
    @State private var copied: (key: String, until: Date)?

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
                    if card.stepCount > 0 { stepsCard }
                    if !card.accounts.isEmpty { accountsCard }
                    if record.method == nil, record.hasPassword { connectionPasswordCard }
                    if !record.note.isEmpty {
                        cardBox {
                            label(RL("ЗАМЕТКА"))
                            Text(record.note).font(DS.Font.manrope(13.5, .regular, relativeTo: .body)).foregroundStyle(.dsText)
                                .lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if record.accessLines > 0 { accessCard }
                    if !contacts.isEmpty { contactsCard }
                }
                .padding(.bottom, DS.Space.s)
            }
        }
        .onExitCommand(perform: back)
        .task(id: record.identity) { await loadDetails() }
        .task(id: reveal.isEmpty && copied == nil) { await tick() }
        .onDisappear(perform: forget)
    }

    private func back() {
        forget()
        onBack()
    }

    private func forget() {
        card = ConnectionCard()
        contacts = []
        access = nil
        reveal.hideAll()
        revealed = [:]
        copied = nil
    }

    /// Шаги, учётки и контакты — из файла при открытии карточки; тексты «Доступа» и пароля учётки тут же отпускаются.
    private func loadDetails() async {
        var accessText: String?
        if record.accessLines > 0, let secret = await center.readSecret(.access, of: record) {
            accessText = secret.withBytes { String(decoding: $0, as: UTF8.self) }
            secret.wipe()
        }
        var accountPassword: String?
        if record.hasAccountPassword, let secret = await center.readSecret(.accountPassword, of: record) {
            accountPassword = secret.withBytes { String(decoding: $0, as: UTF8.self) }
            secret.wipe()
        }
        card = AccessParser.card(record: record, access: accessText, accountPassword: accountPassword)
        if record.hasContacts, let secret = await center.readSecret(.contacts, of: record) {
            contacts = secret.withBytes { ContactsParser.parse(String(decoding: $0, as: UTF8.self)) }
            secret.wipe()
        }
    }

    /// Раз в полсекунды, пока что-то показано или только что скопировано: «скроется через N с», затем скрыть.
    private func tick() async {
        while !Task.isCancelled, !reveal.isEmpty || copied != nil {
            now = Date()
            for key in reveal.expire(now: now) { revealed[key] = nil }
            if let c = copied, c.until <= now { copied = nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: Шапка

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
        if card.vpn != nil, card.rdp != nil {
            parts.append(RL("VPN, затем RDP"))
        } else {
            parts.append(record.method?.title ?? record.program(default: center.defaultProgram).title)
        }
        if record.method == nil, !record.id.isEmpty { parts.append(record.displayID) }
        return parts.joined(separator: " · ")
    }

    // MARK: Как подключиться

    private var stepsCard: some View {
        cardBox(spacing: 14) {
            label(card.stepCount == 1 ? RL("КАК ПОДКЛЮЧИТЬСЯ · 1 ШАГ") : RL("КАК ПОДКЛЮЧИТЬСЯ · %@ ШАГА", card.stepCount))
            if let vpn = card.vpn { step(1, tint: RemoteTint.vpn) { vpnStep(vpn) } }
            if card.vpn != nil, card.rdp != nil { Divider().overlay(Color.dsLine).padding(.leading, 36) }
            if let rdp = card.rdp { step(card.vpn == nil ? 1 : 2, tint: RemoteTint.rdp) { rdpStep(rdp) } }
        }
    }

    private func step<Content: View>(_ n: Int, tint: RemoteTint.Set3, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(DS.Font.manrope(12.5, .bold, relativeTo: .caption)).foregroundStyle(tint.fg)
                .frame(width: 24, height: 24).background(tint.bg, in: Circle())
                .accessibilityLabel(RL("Шаг %@", n))
            VStack(alignment: .leading, spacing: 4, content: content).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func vpnStep(_ vpn: ConnectionCard.VPN) -> some View {
        stepTitle(vpn.kind.map { RL("Включите VPN · %@", $0) } ?? RL("Включите VPN"))
        if vpn.isEmpty {
            Text(RL("Подробностей о VPN в файле нет.")).font(DS.Font.rowSub).foregroundStyle(.dsMute)
        }
        if let server = vpn.server { plainRow(RL("Сервер"), server, mono: true, copyLabel: RL("Скопировать сервер")) }
        if let backup = vpn.backupServer {
            plainRow(RL("Запасной"), backup, mono: true, secondary: true, copyLabel: RL("Скопировать запасной сервер"))
        }
        if let key = vpn.key {
            secretRow(RL("Общий ключ"), key: "vpn.key", value: key, what: RL("общий ключ"))
        }
        if let login = vpn.login { plainRow(RL("Логин"), login, copyLabel: RL("Скопировать логин VPN")) }
        if let password = vpn.password { secretRow(RL("Пароль"), key: "vpn.password", value: password, what: RL("пароль VPN")) }
        if let note = vpn.note {
            Text(RL("Из файла: «%@»", note)).font(DS.Font.manrope(12, .regular, relativeTo: .caption)).foregroundStyle(.dsMute)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.dsField, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 2)
        }
    }

    @ViewBuilder private func rdpStep(_ rdp: ConnectionCard.RDP) -> some View {
        stepTitle(RL("Подключитесь по RDP"))
        if let address = rdp.address {
            plainRow(RL("Адрес"), address, mono: true, copyLabel: RL("Скопировать адрес RDP"))
        } else {
            Text(RL("Адрес в файле не указан.")).font(DS.Font.rowSub).foregroundStyle(.dsMute)
        }
        if let login = rdp.login { plainRow(RL("Логин"), login, copyLabel: RL("Скопировать логин RDP")) }
        if let password = rdp.password { secretRow(RL("Пароль"), key: "rdp.password", value: password, what: RL("пароль RDP")) }
        if rdp.useAccountsBelow {
            Text(RL("Войдите одной из учёток ниже.")).font(DS.Font.rowSub).foregroundStyle(.dsMute)
        }
        if let address = rdp.address, RDPLink.isValidHost(address) {
            HStack(spacing: 8) {
                Button(RL("Открыть в Windows App")) {
                    center.openRDP(record, host: address, account: rdp.login ?? (record.account.isEmpty ? "" : record.account))
                }
                .buttonStyle(.graphite(.primary, size: .compact))
                if card.vpn != nil {
                    Text(RL("сначала шаг 1")).font(DS.Font.manrope(11.5, .regular, relativeTo: .caption2)).foregroundStyle(.dsMute)
                }
            }
            .padding(.top, 4)
        }
    }

    private func stepTitle(_ text: String) -> some View {
        Text(text).font(DS.Font.manrope(14, .bold, relativeTo: .body)).foregroundStyle(.dsText)
    }

    // MARK: Учётные записи

    /// Несколько пар одного вида (RDP-сервер с тремя входами) — нумерованным списком, как в макете Accounts.
    private var numbered: Bool {
        card.accounts.count > 1 && Set(card.accounts.map(\.kind)).count == 1 && card.accounts.allSatisfy { $0.source == .access }
    }

    private var accountsCard: some View {
        cardBox {
            label(RL("УЧЁТНЫЕ ЗАПИСИ · %@", card.accounts.count))
            if numbered {
                Text(RL("В файле несколько пар «Логин · Пароль» — показаны все, по порядку."))
                    .font(DS.Font.manrope(12, .regular, relativeTo: .caption)).foregroundStyle(.dsMute)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(card.accounts.enumerated()), id: \.offset) { i, account in
                    if i > 0 { Divider().overlay(Color.dsLine) }
                    numberedAccount(i + 1, account)
                }
                Text(RL("Нажатие на логин копирует его. Пароль — 👁 показать на 10 с, ⧉ скопировать."))
                    .font(DS.Font.manrope(11.5, .regular, relativeTo: .caption2)).foregroundStyle(.dsMute)
            } else {
                ForEach(Array(card.accounts.enumerated()), id: \.offset) { i, account in
                    if i > 0 { Divider().overlay(Color.dsLine) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(kindTitle(account.kind)).font(DS.Font.manrope(11, .semibold, relativeTo: .caption2))
                                .foregroundStyle(.dsText).padding(.horizontal, 8).frame(height: 20)
                                .background(RemoteTint.other.bg, in: Capsule())
                            Text(kindHint(account)).font(DS.Font.manrope(11.5, .regular, relativeTo: .caption2)).foregroundStyle(.dsMute)
                        }
                        if let login = account.login {
                            plainRow(RL("Логин"), login, copyLabel: RL("Скопировать логин %@", kindTitle(account.kind)))
                        } else {
                            factRow(RL("Логин")) { Text(RL("не указан")).font(DS.Font.manrope(13.5, .medium, relativeTo: .body)).foregroundStyle(.dsMute) }
                        }
                        if let password = account.password {
                            secretRow(RL("Пароль"), key: "account.\(i)", value: password, what: RL("пароль %@", kindTitle(account.kind)))
                        }
                    }
                }
            }
        }
    }

    private func numberedAccount(_ n: Int, _ account: ConnectionCard.Account) -> some View {
        let key = "account.\(n - 1)"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("\(n)").font(DS.Font.manrope(12, .bold, relativeTo: .caption)).foregroundStyle(.dsMute).frame(width: 22)
                if let login = account.login {
                    Button { center.copyPlain(login, title: RL("Логин скопирован")) } label: {
                        Text(login).font(DS.Font.manrope(13.5, .semibold, relativeTo: .body)).foregroundStyle(.dsText)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help(RL("Скопировать логин"))
                    .accessibilityLabel(RL("Скопировать логин %@", login))
                } else {
                    Text(RL("не указан")).font(DS.Font.manrope(13.5, .medium, relativeTo: .body)).foregroundStyle(.dsMute)
                }
                Spacer(minLength: 6)
                if let password = account.password {
                    secretValue(key: key).frame(width: 110, alignment: .leading)
                    secretButtons(key: key, value: password, what: RL("пароль %@", n))
                }
            }
            secretCaption(key: key).padding(.leading, 30)
        }
    }

    private func kindTitle(_ kind: ConnectionCard.Account.Kind) -> String {
        switch kind {
        case .windows: return "Windows"
        case .server: return "Server"
        case .router: return RL("Роутер")
        case .vpn: return "VPN"
        }
    }

    private func kindHint(_ account: ConnectionCard.Account) -> String {
        switch account.kind {
        case .windows: return RL("для входа на компьютер")
        case .server: return RL("для входа на сервер")
        case .router: return RL("из блока «Router»")
        case .vpn: return RL("ещё одна пара из блока VPN")
        }
    }

    // MARK: Пароль подключения

    private var connectionPasswordCard: some View {
        let program = record.program(default: center.defaultProgram)
        return cardBox {
            label(RL("ПАРОЛЬ ПОДКЛЮЧЕНИЯ · %@", program.title.uppercased()))
            HStack(spacing: 8) {
                Text(record.displayID).font(DS.Font.mono(13.5, relativeTo: .body).weight(.semibold)).foregroundStyle(.dsText)
                    .lineLimit(1).fixedSize().textSelection(.enabled)
                Spacer(minLength: 6)
                secretValue(key: "program.password")
                secretButtons(key: "program.password", value: nil, what: RL("пароль %@", program.title))
            }
            secretCaption(key: "program.password")
        }
    }

    // MARK: Строки «название — значение»

    private func factRow<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 8) {
            Text(title).font(DS.Font.manrope(12.5, .regular, relativeTo: .caption)).foregroundStyle(.dsMute)
                .frame(width: 92, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 30)
    }

    /// Не секрет (адрес, логин): значение и ⧉ — обычной копией.
    private func plainRow(_ title: String, _ value: String, mono: Bool = false, secondary: Bool = false, copyLabel: String) -> some View {
        factRow(title) {
            HStack(spacing: 8) {
                Text(value)
                    .font(mono ? DS.Font.mono(13.5, relativeTo: .body).weight(secondary ? .medium : .semibold)
                               : DS.Font.manrope(13.5, .semibold, relativeTo: .body))
                    .foregroundStyle(secondary ? Color.dsMute : Color.dsText)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconButton(copyLabel, systemImage: "doc.on.doc", compact: true) { center.copyPlain(value, title: RL("Скопировано")) }
            }
        }
    }

    /// Секрет: «••••••••», 👁 на 10 с, ⧉ — скрыто от истории буфера; подпись — «Показан · скроется через N с» или
    /// «Скопирован · буфер очистится через 30 с».
    private func secretRow(_ title: String, key: String, value: String, what: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            factRow(title) {
                HStack(spacing: 8) {
                    secretValue(key: key).frame(maxWidth: .infinity, alignment: .leading)
                    secretButtons(key: key, value: value, what: what)
                }
            }
            secretCaption(key: key).padding(.leading, 100)
        }
    }

    @ViewBuilder private func secretValue(key: String) -> some View {
        if let shown = revealed[key], reveal.isShown(key, now: now) {
            Text(shown).font(DS.Font.mono(13, relativeTo: .body).weight(.semibold)).foregroundStyle(.dsText)
                .lineLimit(1).truncationMode(.middle)
        } else {
            Text("••••••••").font(.system(size: 15, weight: .semibold)).tracking(3).foregroundStyle(.dsMute)
                .accessibilityLabel(RL("Скрыто"))
        }
    }

    /// `value` nil — пароль программы: читается из файла в момент нажатия.
    private func secretButtons(key: String, value: String?, what: String) -> some View {
        let shown = revealed[key] != nil && reveal.isShown(key, now: now)
        let isCopied = copied?.key == key
        return HStack(spacing: 6) {
            IconButton(shown ? RL("Скрыть %@", what) : RL("Показать %@", what), systemImage: shown ? "eye.slash" : "eye",
                       active: shown, compact: true) {
                Task { await toggleReveal(key, value: value) }
            }
            IconButton(RL("Скопировать %@", what), systemImage: isCopied ? "checkmark" : "doc.on.doc", compact: true) {
                Task { await copySecret(key, value: value) }
            }
        }
    }

    @ViewBuilder private func secretCaption(key: String) -> some View {
        if let left = revealed[key] == nil ? nil : reveal.remaining(key, now: now) {
            Text(RL("Показан · скроется через %@ с", left)).font(DS.Font.manrope(11.5, .regular, relativeTo: .caption2))
                .foregroundStyle(RemoteTint.vpn.fg)
        } else if copied?.key == key {
            Text(RL("Скопирован · буфер очистится через 30 с")).font(DS.Font.manrope(11.5, .regular, relativeTo: .caption2))
                .foregroundStyle(RemoteTint.phyto.fg)
        }
    }

    private func toggleReveal(_ key: String, value: String?) async {
        now = Date()
        guard reveal.toggle(key, now: now) else { revealed[key] = nil; return }
        if let value {
            revealed[key] = value
        } else if let secret = await center.readSecret(.password, of: record) {
            revealed[key] = secret.withBytes { String(decoding: $0, as: UTF8.self) }
            secret.wipe()
        } else {
            reveal.toggle(key, now: Date())
            center.showReadFailure()
        }
    }

    private func copySecret(_ key: String, value: String?) async {
        let ok: Bool
        if let value {
            center.copyConcealed(value, title: nil)
            ok = true
        } else {
            ok = await center.copySecretValue(.password, of: record)
        }
        if ok { copied = (key, Date().addingTimeInterval(30)) }
    }

    // MARK: «Доступ · как в файле»

    private var accessCard: some View {
        cardBox {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    label(RL("ДОСТУП · КАК В ФАЙЛЕ"))
                    Text(accessError ?? RL("%@. Всё выше собрано из них; пароли скрыты", RL("строк: %@", record.accessLines)))
                        .font(DS.Font.manrope(12, .regular, relativeTo: .caption)).foregroundStyle(.dsMute)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(access == nil ? RL("Показать") : RL("Скрыть")) {
                    if access == nil { Task { await loadAccess() } } else { access = nil }
                }
                .buttonStyle(.graphite(.secondary, size: .compact))
            }
            if let access {
                // Переносы и пустые строки между блоками — как в файле; пароли и ключи — под маской.
                Text(access).font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsText)
                    .lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(Color.dsBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            }
        }
    }

    private func loadAccess() async {
        accessError = nil
        guard let secret = await center.readSecret(.access, of: record) else {
            accessError = RL("Не удалось прочитать файл")
            return
        }
        defer { secret.wipe() }
        access = secret.withBytes {
            String(decoding: $0, as: UTF8.self).components(separatedBy: "\n").map(AccessParser.mask).joined(separator: "\n")
        }
    }

    // MARK: Контакты

    private var contactsCard: some View {
        cardBox {
            label(RL("КОНТАКТЫ"))
            ForEach(Array(contacts.enumerated()), id: \.offset) { i, contact in
                if i > 0 { Divider().overlay(Color.dsLine) }
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !contact.title.isEmpty {
                            Text(contact.title).font(DS.Font.manrope(13.5, .semibold, relativeTo: .body)).foregroundStyle(.dsText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let detail = contact.detail {
                            Text(detail).font(DS.Font.manrope(12, .regular, relativeTo: .caption)).foregroundStyle(.dsMute)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if contact.phones.isEmpty {
                            Text(RL("Телефона в файле нет")).font(DS.Font.manrope(12, .regular, relativeTo: .caption))
                                .foregroundStyle(.dsMute)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(contact.phones, id: \.self) { phone in
                            HStack(spacing: 6) {
                                Button { center.call(phone) } label: {
                                    Label(phone, systemImage: "phone.fill")
                                        .font(DS.Font.mono(13.5, relativeTo: .body).weight(.semibold))
                                        .foregroundStyle(Color.dsAccInk)
                                        .padding(.horizontal, 10).frame(height: 30)
                                        .background(Color.dsAcc, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .fixedSize()
                                }
                                .buttonStyle(PressScaleStyle())
                                .help(RL("Позвонить"))
                                .accessibilityLabel(RL("Позвонить %@", phone))
                                IconButton(RL("Скопировать телефон %@", phone), systemImage: "doc.on.doc", compact: true) {
                                    center.copyPlain(phone, title: RL("Телефон скопирован"))
                                }
                            }
                        }
                    }
                }
            }
            if contacts.contains(where: { !$0.phones.isEmpty }) {
                Text(RL("Нажатие на номер — звонок через UniTalk; ⧉ — скопировать номер."))
                    .font(DS.Font.manrope(11.5, .regular, relativeTo: .caption2)).foregroundStyle(.dsMute)
            }
        }
    }

    // MARK: Оформление

    private func label(_ text: String, color: Color = .dsMute) -> some View {
        Text(text).font(DS.Font.manrope(11, .bold, relativeTo: .caption2)).tracking(1.3).foregroundStyle(color)
    }

    private func cardBox<Content: View>(spacing: CGFloat = 10, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }
}
