import Foundation

/// Удалённый рабочий стол для Windows App / Microsoft Remote Desktop — файлом `.rdp` (`full address:s:<адрес>`,
/// `username:s:<логин>`). Ссылка `rdp://full%20address=s:<адрес>` в `URL` не укладывается: после `s` двоеточие
/// читается как порт, и Foundation такую ссылку отвергает. Пароль в файл не пишется никогда.
public enum RDPLink {
    /// Приложения, которые открывают `.rdp` (Windows App и прежний Microsoft Remote Desktop — один bundle id).
    public static let bundleIDs = ["com.microsoft.rdc.macos", "com.microsoft.rdc.mac"]

    /// Адрес годится: имя, IPv4, [IPv6], порт — ничего, что дописало бы в файл свои строки.
    public static func isValidHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !h.isEmpty && h.count <= 255 && h.unicodeScalars.allSatisfy { allowedHost.contains($0) }
    }

    /// Содержимое `.rdp`; nil — адрес не годится. Логин с переводом строки или управляющими символами не пишется.
    public static func file(host: String, account: String = "") -> Data? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidHost(h) else { return nil }
        var lines = ["full address:s:" + h]
        let user = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty, !user.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            lines.append("username:s:" + user)
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Имя файла: только безопасные символы названия записи.
    public static func fileName(for name: String) -> String {
        let safe = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }
        let base = String(safe.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return (base.isEmpty ? "connection" : base) + ".rdp"
    }

    private static let allowedHost = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]")
}
