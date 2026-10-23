import Foundation

/// «Как подключиться» из текста «Доступа»: строки про VPN и RDP. Разбор — подсказка, а не истина: что не
/// разобралось, показывается строками «Доступа» как есть. Пароли и ключи остаются в разобранном виде только
/// на время открытой карточки и на экран не выводятся.
public struct AccessInfo: Equatable, Sendable {
    public struct VPN: Equatable, Sendable {
        /// WireGuard, PPTP, L2TP, FortiClient, OpenVPN, IPsec; nil — не назван.
        public var kind: String?
        public var server: String?
        public var login: String?
        /// Пароль, ключ или PSK — только для «Скопировать».
        public var secret: String?
        public var lines: [String] = []
    }

    public struct RDP: Equatable, Sendable {
        /// IP или имя, с портом, если он указан.
        public var address: String?
        public var login: String?
        public var lines: [String] = []
    }

    public var vpn: VPN?
    public var rdp: RDP?
}

public enum AccessParser {
    static let vpnKinds = ["WireGuard", "PPTP", "L2TP", "FortiClient", "OpenVPN", "IPsec", "IKEv2", "SoftEther"]

    public static func parse(_ text: String) -> AccessInfo {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var info = AccessInfo()
        let vpnLines = lines.filter { line in
            let l = line.lowercased()
            return l.contains("vpn") || vpnKinds.contains { l.contains($0.lowercased()) }
        }
        if !vpnLines.isEmpty {
            var v = AccessInfo.VPN(lines: vpnLines)
            let joined = vpnLines.joined(separator: "\n")
            v.kind = vpnKinds.first { joined.lowercased().contains($0.lowercased()) }
            v.server = value(after: ["сервер", "server", "адрес", "address", "host", "ip"], in: vpnLines) ?? firstHost(in: vpnLines)
            v.login = value(after: ["логин", "логін", "login", "user", "користувач", "пользователь"], in: vpnLines)
            v.secret = value(after: ["пароль", "password", "pass", "ключ", "key", "psk", "secret"], in: vpnLines)
            info.vpn = v
        }
        let rdpLines = lines.filter { $0.lowercased().contains("rdp") || $0.lowercased().contains("remote desktop") }
        if !rdpLines.isEmpty {
            var r = AccessInfo.RDP(lines: rdpLines)
            r.address = value(after: ["ip", "адрес", "address", "host", "сервер", "server"], in: rdpLines).flatMap(host) ?? firstHost(in: rdpLines)
            if let a = r.address, !a.contains(":"), let port = value(after: ["порт", "port"], in: rdpLines)?.prefix(while: \.isNumber),
               !port.isEmpty { r.address = a + ":" + port }
            r.login = value(after: ["логин", "логін", "login", "user", "користувач", "пользователь"], in: rdpLines)
            info.rdp = r
        }
        return info
    }

    /// Значение после метки: «логин: admin», «Login — admin», «пароль admin123» (до «·», «|», «,» или конца строки).
    static func value(after labels: [String], in lines: [String]) -> String? {
        for line in lines {
            for part in line.components(separatedBy: CharacterSet(charactersIn: "·|;")) {
                let p = part.trimmingCharacters(in: .whitespaces)
                let lower = p.lowercased()
                for label in labels {
                    guard let r = lower.range(of: label) else { continue }
                    // Метка — отдельным словом.
                    if r.lowerBound > lower.startIndex, lower[lower.index(before: r.lowerBound)].isLetter { continue }
                    if r.upperBound < lower.endIndex, lower[r.upperBound].isLetter { continue }
                    let offset = lower.distance(from: lower.startIndex, to: r.upperBound)
                    let rest = String(p[p.index(p.startIndex, offsetBy: offset)...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " :=—–-\t"))
                    let word = rest.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? ""
                    if !word.isEmpty { return word }
                }
            }
        }
        return nil
    }

    /// Первый IPv4[:порт] или имя вида host.domain в строках.
    static func firstHost(in lines: [String]) -> String? {
        for line in lines {
            for token in line.split(whereSeparator: { " |·,;()".contains($0) }) {
                if let h = host(String(token)) { return h }
            }
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
}

/// Телефоны в «Контактах»: последовательности цифр с `+ ( ) -` и пробелами, не меньше 7 цифр.
public enum ContactPhones {
    public static func find(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\+?\d[\d\s()\-]{5,}\d"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let s = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            return s.filter(\.isNumber).count >= 7 ? s : nil
        }
    }
}
