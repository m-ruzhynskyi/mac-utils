import Foundation

/// Метки записи. «Рег», «рег.», «РЕГ» — одна метка; «фито» и «фіто» — тоже: сравнение без регистра, точек,
/// пробелов и с украинскими буквами как русскими.
public enum ConnectionTag {
    public enum Kind: Equatable, Sendable { case reg, phyto, other }

    static let vpn = "vpn"
    static let rdp = "rdp"

    public static func key(_ tag: String) -> String {
        var out = String.UnicodeScalarView()
        for u in tag.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(u) {
            switch u {
            case "і", "ї": out.append("и")
            case "є": out.append("е")
            case "ґ": out.append("г")
            case "ё": out.append("е")
            default: out.append(u)
            }
        }
        return String(out)
    }

    public static func kind(_ tag: String) -> Kind {
        switch key(tag) {
        case "рег": return .reg
        case "фито": return .phyto
        default: return .other
        }
    }

    /// VPN и RDP показываются значками, а не метками.
    public static func isBadge(_ tag: String) -> Bool { [vpn, rdp].contains(key(tag)) }

    /// Как показывать: «Рег» и «Фито» — единообразно, остальные — как в файле.
    public static func display(_ tag: String) -> String {
        switch kind(tag) {
        case .reg: return "Рег"
        case .phyto: return "Фито"
        case .other: return tag
        }
    }
}
