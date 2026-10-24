import Foundation

/// Карточка подключения из «Доступа» и колонок учётки: шаги «Как подключиться» (VPN, затем RDP) и учётные записи.
/// Разбор — подсказка, а не истина: что не разобралось, остаётся в «Доступе · как в файле». Ничего не выдумывается —
/// чего в файле нет, того в карточке нет. Пароли и ключи живут здесь только пока открыта карточка.
public struct ConnectionCard: Equatable, Sendable {
    public struct VPN: Equatable, Sendable {
        /// L2TP/IPsec, PPTP, FortiClient, WireGuard, OpenVPN…; nil — в файле не назван.
        public var kind: String?
        public var server: String?
        /// Второй адрес (IP2, «запасной»).
        public var backupServer: String?
        /// Общий ключ (L2tpPsk, PSK) или ключ WireGuard.
        public var key: String?
        public var login: String?
        public var password: String?
        /// Длинная строка-пояснение из файла, пароли под маской.
        public var note: String?

        public var isEmpty: Bool {
            kind == nil && server == nil && backupServer == nil && key == nil && login == nil && password == nil && note == nil
        }
    }

    public struct RDP: Equatable, Sendable {
        /// IP или имя, с портом, если он указан.
        public var address: String?
        public var login: String?
        public var password: String?
        /// Своей пары нет, а учёток несколько: «войдите одной из учёток ниже».
        public var useAccountsBelow = false

        public init(address: String? = nil, login: String? = nil, password: String? = nil, useAccountsBelow: Bool = false) {
            self.address = address
            self.login = login
            self.password = password
            self.useAccountsBelow = useAccountsBelow
        }
    }

    public struct Account: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case windows, server, router, vpn
        }
        public enum Source: Equatable, Sendable {
            /// Колонки «Учётная запись» и «Пароль учётной записи».
            case columns
            /// Строки «Доступа».
            case access
        }

        public var kind: Kind
        public var source: Source
        /// nil — логина в файле нет («не указан»).
        public var login: String?
        public var password: String?

        public init(kind: Kind, source: Source, login: String?, password: String?) {
            self.kind = kind
            self.source = source
            self.login = login
            self.password = password
        }
    }

    public var vpn: VPN?
    public var rdp: RDP?
    public var accounts: [Account] = []

    public var stepCount: Int { (vpn == nil ? 0 : 1) + (rdp == nil ? 0 : 1) }

    public init() {}
}

public enum AccessParser {
    static let maskDots = "••••••"

    /// Метки паролей и ключей; значение после них до «·», «|», «;» или конца строки уходит под маску.
    /// Длинные варианты раньше коротких: «password» раньше «pass».
    private static let secretLabel = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d])(парол\p{L}*|ключ\p{L}*|секрет\p{L}*|токен\p{L}*|пін|пин|"#
        + #"password|passwort|passphrase|passwd|pass|pwd|pw|l2tp ?psk|pre-?shared[ -]?key|psk|private ?key|key|"#
        + #"secret|token|pin)(?![\p{L}\d])([\s:=—–\-]+)([^\s·|;:=—–\-](?:[^·|;\n]*[^\s·|;\n])?)"#,
        options: [.caseInsensitive])

    /// Строка «Доступа» для показа: значения после меток пароля, ключа и PSK заменены точками.
    /// «пароль: Qw3rty · логин admin» → «пароль: •••••• · логин admin». Сразу за меткой — пробел, «:», «=» или тире:
    /// «с общим ключом.» в пояснении — не значение.
    public static func mask(_ line: String) -> String {
        let ns = line as NSString
        return secretLabel.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length),
                                                    withTemplate: "$1$2" + maskDots)
    }

    // MARK: Разбор

    enum Section: Equatable { case none, vpn, rdp, router, server, program }

    enum Field: CaseIterable { case login, password, key, server, backup, port }

    /// Метки полей (нижний регистр, отдельным словом). Длинные раньше коротких.
    static let labels: [(Field, [String])] = [
        (.backup, ["ip2", "запасной", "запасний", "резервный", "резервний", "backup"]),
        (.server, ["ip1", "ip", "адрес", "адреса", "address", "host", "хост", "сервер", "server"]),
        (.port, ["порт", "port"]),
        (.key, ["l2tppsk", "l2tp psk", "pre-shared key", "preshared key", "общий ключ", "загальний ключ", "psk", "ключ", "key"]),
        (.password, ["password", "passwd", "пароля", "пароль", "pass", "pwd"]),
        (.login, ["username", "користувач", "пользователь", "логин", "логін", "login", "user"]),
    ]

    static let vpnKinds = ["WireGuard", "PPTP", "L2TP", "FortiClient", "OpenVPN", "IPsec", "IKEv2", "SoftEther"]

    /// Слово в начале строки, с которого начинается блок.
    static func header(_ word: String) -> Section? {
        switch word.lowercased() {
        case "vpn", "впн": return .vpn
        case let w where vpnKinds.contains { $0.lowercased() == w }: return .vpn
        case "rdp", "рдп": return .rdp
        case "router", "роутер", "маршрутизатор": return .router
        case "server", "сервер": return .server
        case "anydesk", "teamviewer", "rustdesk": return .program
        default: return nil
        }
    }

    struct Pair: Equatable {
        var login: String?
        var password: String?
    }

    struct Block {
        var section: Section
        var pairs: [Pair] = []
        var server: String?
        var backup: String?
        var key: String?
        var port: String?
        var kinds: [String] = []
        var notes: [String] = []

        mutating func add(login: String) {
            if let last = pairs.last, last.login == nil, last.password == nil { pairs[pairs.count - 1].login = login; return }
            pairs.append(Pair(login: login))
        }

        mutating func add(password: String) {
            if let last = pairs.last, last.password == nil { pairs[pairs.count - 1].password = password; return }
            pairs.append(Pair(password: password))
        }
    }

    /// Блоки «Доступа»: группы строк между пустыми строками; строка с заголовком (VPN, RDP, Router, Server, FortiClient…)
    /// начинает новый блок и без пустой строки.
    static func blocks(_ text: String) -> (blocks: [Block], serverAccountLine: Bool) {
        var result: [Block] = []
        var current: Block?
        var serverLine = false
        func close() { if let c = current { result.append(c) }; current = nil }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { close(); continue }
            // «Учётка Server — логин и пароль в колонках…»: учётка из колонок — от сервера; сама строка — пояснение.
            if line.range(of: #"^уч[её]тк\p{L}*\s+server\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                serverLine = true
                continue
            }
            var body = Substring(line)
            if let (section, rest) = headed(line) {
                close()
                current = Block(section: section)
                body = rest
                if section == .vpn, let kind = vpnKinds.first(where: { $0.lowercased() == firstWord(line).lowercased() }) {
                    current?.kinds.append(kind)
                }
            } else if current == nil || current?.section == Section.none {
                // Без заголовка: строка, где VPN или RDP упомянуты посередине, тоже открывает блок.
                let vpn = mentionsVPN(line)
                if vpn || words(line).contains("rdp") {
                    if current?.pairs.isEmpty == false { close() }
                    current = Block(section: vpn ? .vpn : .rdp)
                }
            }
            if current == nil { current = Block(section: .none) }
            read(String(body), into: &current!, isHeader: body.startIndex != line.startIndex)
        }
        close()
        return (result, serverLine)
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    static func mentionsVPN(_ text: String) -> Bool {
        let w = words(text)
        return w.contains("vpn") || w.contains("впн") || vpnKinds.contains { w.contains($0.lowercased()) }
    }

    static func firstWord(_ line: String) -> String {
        String(line.prefix { !$0.isWhitespace && !":—–-/·|(".contains($0) })
    }

    /// Заголовок блока в начале строки и остаток строки после него. «Server»/«Сервер» — заголовок, только если за ним
    /// конец строки, тире или «/» («Server: 10.0.0.1» — адрес, а не блок).
    static func headed(_ line: String) -> (Section, Substring)? {
        let word = firstWord(line)
        guard !word.isEmpty, let section = header(word) else { return nil }
        let after = line.dropFirst(word.count)
        let next = after.drop(while: \.isWhitespace).first
        if section == .server, let next, !"—–-/".contains(next) { return nil }
        let rest = after.drop(while: { $0.isWhitespace || ":—–-/·|".contains($0) })
        // «Роутер — VPN PPTP · IP: …» — это VPN.
        if section == .router || section == .server, mentionsVPN(String(rest)) { return (.vpn, rest) }
        return (section, rest)
    }

    /// Части строки: «·», «|», «;», «, » и « / ».
    static func segments(_ text: String) -> [String] {
        var parts = [text]
        for sep in ["·", "|", ";", ", ", " / "] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func read(_ text: String, into block: inout Block, isHeader: Bool = false) {
        let lower = text.lowercased()
        for kind in vpnKinds where block.section == .vpn && !block.kinds.contains(kind) {
            if lower.range(of: #"(?<![\p{L}\d])"# + NSRegularExpression.escapedPattern(for: kind.lowercased()), options: .regularExpression) != nil {
                block.kinds.append(kind)
            }
        }
        let parts = segments(text)
        var used = false
        for (i, part) in parts.enumerated() {
            var found = false
            for (field, value) in labelled(part) {
                found = true
                switch field {
                case .login: block.add(login: value)
                case .password: block.add(password: value)
                case .key: if block.key == nil { block.key = value }
                case .server: if block.server == nil, let h = host(value) ?? (block.section == .vpn ? value : nil) { block.server = h }
                case .backup: if block.backup == nil { block.backup = host(value) ?? value }
                case .port: if block.port == nil, value.allSatisfy(\.isNumber) { block.port = value }
                }
            }
            if found { used = true; continue }
            // «<логин> — <пароль>»: одно слово, тире, одно слово (только в начале строки).
            if i == 0, let pair = dashPair(part) {
                block.pairs.append(pair)
                used = true
                continue
            }
            if block.section == .vpn || block.section == .rdp, let h = firstHost(part) {
                if block.server == nil { block.server = h }
                used = true
            }
        }
        // Пояснение VPN — строка из четырёх слов и больше, где ничего не разобралось, или такая часть строки-заголовка
        // («VPN — 203.0.113.10 · подключение средствами Windows…»). Пароли в нём — под маской.
        guard block.section == .vpn else { return }
        let long = { (t: String) in t.split(separator: " ").count >= 4 }
        if !used {
            if long(text) { block.notes.append(mask(text)) }
        } else if isHeader {
            for part in parts where labelled(part).isEmpty && firstHost(part) == nil && dashPair(part) == nil && long(part) {
                block.notes.append(mask(part))
            }
        }
    }

    /// Пары «метка: значение» в части строки. Разделитель — «:», «=», тире; без разделителя — только если за значением
    /// конец части («user ivan»), иначе «логин и пароль в колонках» дал бы логин «и».
    static func labelled(_ part: String) -> [(Field, String)] {
        var out: [(Field, String)] = []
        let lower = part.lowercased()
        var taken: [Range<String.Index>] = []
        for (field, names) in labels {
            for name in names {
                var from = lower.startIndex
                while let r = lower.range(of: name, range: from..<lower.endIndex) {
                    from = r.upperBound
                    if taken.contains(where: { $0.overlaps(r) }) { continue }
                    if r.lowerBound > lower.startIndex, isWordChar(lower[lower.index(before: r.lowerBound)]) { continue }
                    if r.upperBound < lower.endIndex, isWordChar(lower[r.upperBound]) { continue }
                    let offset = lower.distance(from: lower.startIndex, to: r.upperBound)
                    let rest = part[part.index(part.startIndex, offsetBy: offset)...]
                    let afterSpace = rest.drop(while: { $0 == " " || $0 == "\t" })
                    let separated = afterSpace.first.map { ":=—–".contains($0) || ($0 == "-" && afterSpace.dropFirst().first == " ") } ?? false
                    var tokens = afterSpace.drop(while: { " :=—–-\t".contains($0) }).split(separator: " ").map(String.init)
                    // «IP: IP: 10.0.0.1» — повтор метки пропускаем.
                    while let t = tokens.first, t.hasSuffix(":"), names.contains(t.dropLast().lowercased()) { tokens.removeFirst() }
                    guard let value = tokens.first, !value.isEmpty else { continue }
                    if !separated && tokens.count > 1 { continue }
                    taken.append(r)
                    out.append((field, value))
                    break
                }
                if out.last?.0 == field { break }
            }
        }
        return out
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    static func dashPair(_ part: String) -> Pair? {
        let words = part.split(separator: " ").map(String.init)
        guard words.count == 3, ["—", "–", "-"].contains(words[1]) else { return nil }
        let login = words[0], password = words[2]
        let isWord = { (w: String) in
            header(w) == nil && host(w) == nil && !w.contains(":")
                && !labels.contains { $0.1.contains(w.lowercased()) }
        }
        guard isWord(login), isWord(password) else { return nil }
        return Pair(login: login, password: password)
    }

    /// Первый IPv4[:порт] или имя вида host.domain в тексте.
    static func firstHost(_ text: String) -> String? {
        for token in text.split(whereSeparator: { " |·,;()".contains($0) }) {
            if let h = host(String(token)) { return h }
        }
        return nil
    }

    static func host(_ token: String) -> String? {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ":—–-."))
        let ipv4 = #"^(\d{1,3}\.){3}\d{1,3}(:\d{1,5})?$"#
        let name = #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d{1,5})?$"#
        if t.range(of: ipv4, options: .regularExpression) != nil { return t }
        if t.range(of: name, options: .regularExpression) != nil, t.contains(where: \.isLetter) { return t }
        return nil
    }

    // MARK: Карточка

    /// Карточка записи. `access` — текст «Доступа» (nil — нет); `accountPassword` — пароль из колонки (nil — нет).
    public static func card(record: ConnectionRecord, access: String?, accountPassword: String?) -> ConnectionCard {
        let (blocks, serverLine) = blocks(access ?? "")
        var card = ConnectionCard()
        var accessAccounts: [ConnectionCard.Account] = []
        var stepPairs: [Pair] = []

        let vpnBlocks = blocks.filter { $0.section == .vpn }
        if !vpnBlocks.isEmpty || record.needsVPN {
            var v = ConnectionCard.VPN()
            let kinds = vpnBlocks.flatMap(\.kinds)
            v.server = vpnBlocks.lazy.compactMap(\.server).first
            v.backupServer = vpnBlocks.lazy.compactMap(\.backup).first
            v.key = vpnBlocks.lazy.compactMap(\.key).first
            if let kind = kinds.first(where: { $0 != "IPsec" }) ?? kinds.first {
                v.kind = kind == "L2TP" && (v.key != nil || kinds.contains("IPsec")) ? "L2TP/IPsec" : kind
            }
            let pairs = vpnBlocks.flatMap(\.pairs)
            if let first = pairs.first {
                v.login = first.login
                v.password = first.password
                stepPairs.append(first)
            }
            accessAccounts += pairs.dropFirst().map { .init(kind: .vpn, source: .access, login: $0.login, password: $0.password) }
            let notes = vpnBlocks.flatMap(\.notes)
            if !notes.isEmpty { v.note = notes.joined(separator: " ") }
            card.vpn = v
        }

        let rdpBlocks = blocks.filter { $0.section == .rdp }
        let rdpPairs = rdpBlocks.flatMap(\.pairs)
        if !rdpBlocks.isEmpty || record.usesRDP {
            var r = ConnectionCard.RDP()
            if record.method == .rdp, !record.id.isEmpty {
                r.address = record.id
            } else if var a = rdpBlocks.lazy.compactMap(\.server).first {
                if !a.contains(":"), let port = rdpBlocks.lazy.compactMap(\.port).first { a += ":" + port }
                r.address = a
            }
            if rdpPairs.count == 1 {
                r.login = rdpPairs[0].login
                r.password = rdpPairs[0].password
                stepPairs.append(rdpPairs[0])
            }
            card.rdp = r
        }
        if rdpPairs.count > 1 {
            accessAccounts += rdpPairs.map { .init(kind: .windows, source: .access, login: $0.login, password: $0.password) }
        }
        for block in blocks {
            let kind: ConnectionCard.Account.Kind
            switch block.section {
            case .none: kind = .windows
            case .server: kind = .server
            case .router: kind = .router
            case .vpn, .rdp, .program: continue
            }
            accessAccounts += block.pairs.map { .init(kind: kind, source: .access, login: $0.login, password: $0.password) }
        }

        var accounts: [ConnectionCard.Account] = []
        if !record.account.isEmpty || accountPassword != nil {
            accounts.append(.init(kind: serverLine ? .server : .windows, source: .columns,
                                  login: record.account.isEmpty ? nil : record.account, password: accountPassword))
        }
        // Пары из шагов и уже показанные — повторно не выводятся.
        var seen = Set(stepPairs.map { Pair(login: $0.login, password: $0.password) }.map(key))
        seen.formUnion(accounts.map { key(Pair(login: $0.login, password: $0.password)) })
        for a in accessAccounts where seen.insert(key(Pair(login: a.login, password: a.password))).inserted {
            accounts.append(a)
        }
        card.accounts = accounts
        if card.rdp != nil, card.rdp?.login == nil, card.rdp?.password == nil, accounts.count > 1 { card.rdp?.useAccountsBelow = true }
        return card
    }

    private static func key(_ p: Pair) -> String { (p.login ?? "\u{0}") + "\u{1}" + (p.password ?? "\u{0}") }
}

// MARK: - Контакты

/// Контакт из колонки «Контакты»: имя или должность, пояснение и телефоны.
public struct ConnectionContact: Equatable, Sendable {
    public var title: String
    public var detail: String?
    public var phones: [String]

    public init(title: String, detail: String? = nil, phones: [String] = []) {
        self.title = title
        self.detail = detail
        self.phones = phones
    }
}

public enum ContactsParser {
    private static let phone = try! NSRegularExpression(pattern: #"\+?\(?\d[\d \t\u00A0()\-]{5,}\d"#)

    /// Телефоны в строке: цифры с `+ ( ) -` и пробелами, не меньше 7 цифр.
    static func phoneRanges(in line: String) -> [(range: Range<String.Index>, text: String)] {
        phone.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { m in
            guard let r = Range(m.range, in: line) else { return nil }
            let text = line[r].trimmingCharacters(in: .whitespaces)
            return text.filter(\.isNumber).count >= 7 ? (r, text) : nil
        }
    }

    public static func phones(in text: String) -> [String] { phoneRanges(in: text).map(\.text) }

    /// Контакты по строкам. Строка с маленькой буквы продолжает предыдущую («Заступник директора» + «вірусологічного
    /// відділу» — одна должность). Контакт заканчивается телефоном или пустой строкой; текст перед телефоном — его подпись,
    /// после последнего телефона строки — пояснение («каб. 12»).
    public static func parse(_ text: String) -> [ConnectionContact] {
        var lines: [String?] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { lines.append(nil); continue }
            if let last = lines.last, let prev = last, phoneRanges(in: prev).isEmpty, let first = line.first, first.isLowercase {
                lines[lines.count - 1] = prev + " " + line
            } else {
                lines.append(line)
            }
        }
        let clean = { (s: Substring) in
            s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—–-·|\t"))
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        }
        var contacts: [ConnectionContact] = []
        var pending: [String] = []
        func flush() {
            guard let title = pending.first else { return }
            let detail = pending.dropFirst().joined(separator: " ")
            contacts.append(ConnectionContact(title: title, detail: detail.isEmpty ? nil : detail))
            pending = []
        }
        for line in lines {
            guard let line else { flush(); continue }
            let found = phoneRanges(in: line)
            if found.isEmpty { pending.append(line); continue }
            var cursor = line.startIndex
            for m in found {
                let label = clean(line[cursor..<m.range.lowerBound])
                cursor = m.range.upperBound
                if !label.isEmpty { pending.append(label) }
                if pending.isEmpty, !contacts.isEmpty {
                    // Второй номер того же человека.
                    contacts[contacts.count - 1].phones.append(m.text)
                    continue
                }
                let detail = pending.dropFirst().joined(separator: " ")
                contacts.append(ConnectionContact(title: pending.first ?? "", detail: detail.isEmpty ? nil : detail, phones: [m.text]))
                pending = []
            }
            let tail = clean(line[cursor...])
            if !tail.isEmpty, !contacts.isEmpty {
                let last = contacts.count - 1
                contacts[last].detail = [contacts[last].detail, tail].compactMap { $0 }.joined(separator: " · ")
            }
        }
        flush()
        return contacts
    }
}

// MARK: - Звонок

public enum PhoneNumber {
    /// Номер для звонка в виде +380XXXXXXXXX: «050 000 00 01» → «+380500000001». nil — не похоже на украинский номер.
    /// Другие страны с «+» — как есть, только цифры.
    public static func dialable(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        let plus = raw.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        switch digits.count {
        case 12 where digits.hasPrefix("380"): return "+" + digits
        case 11 where digits.hasPrefix("80"): return "+3" + digits
        case 10 where digits.hasPrefix("0"): return "+38" + digits
        case 9 where !digits.hasPrefix("0"): return "+380" + digits
        case 8...15 where plus: return "+" + digits
        default: return nil
        }
    }

    /// `tel:+380…`; nil — номер не распознан.
    public static func telURL(_ raw: String) -> URL? { dialable(raw).flatMap { URL(string: "tel:" + $0) } }
}

/// Звонок через UniTalk: приложение, которому отдаётся `tel:` (обработчик по умолчанию не меняется).
public enum PhoneCall {
    public static let uniTalkBundleID = "com.unitalk.desktop"

    public enum Plan: Equatable, Sendable {
        /// Открыть ссылку в UniTalk.
        case call(URL)
        /// Скопировать номер: UniTalk не найден или номер не распознан.
        case copy(String, reason: Reason)
    }

    public enum Reason: Equatable, Sendable { case noUniTalk, notANumber }

    public static func plan(_ raw: String, uniTalkInstalled: Bool) -> Plan {
        let number = raw.trimmingCharacters(in: .whitespaces)
        guard let url = PhoneNumber.telURL(number) else { return .copy(number, reason: .notANumber) }
        return uniTalkInstalled ? .call(url) : .copy(number, reason: .noUniTalk)
    }
}

// MARK: - Показ на 10 секунд

/// Какие секреты карточки показаны и когда скроются. Значения хранит карточка — здесь только сроки.
public struct SecretReveal: Equatable, Sendable {
    public static let seconds: TimeInterval = 10
    private var until: [String: Date] = [:]

    public init() {}

    /// 👁: показать на 10 с; если уже показан — скрыть сразу. true — теперь показан.
    @discardableResult
    public mutating func toggle(_ key: String, now: Date) -> Bool {
        if isShown(key, now: now) { until[key] = nil; return false }
        until[key] = now.addingTimeInterval(Self.seconds)
        return true
    }

    public func isShown(_ key: String, now: Date) -> Bool { (until[key].map { $0 > now }) ?? false }

    /// Сколько целых секунд осталось («скроется через N с»); nil — скрыт.
    public func remaining(_ key: String, now: Date) -> Int? {
        guard let end = until[key], end > now else { return nil }
        return Int(end.timeIntervalSince(now).rounded(.up))
    }

    /// Убрать истёкшие; вернуть их ключи (их значения карточка затирает).
    public mutating func expire(now: Date) -> [String] {
        let gone = until.filter { $0.value <= now }.map(\.key)
        for k in gone { until[k] = nil }
        return gone.sorted()
    }

    public mutating func hideAll() { until = [:] }

    public var isEmpty: Bool { until.isEmpty }
}
