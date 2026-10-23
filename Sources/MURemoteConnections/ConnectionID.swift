import Foundation

/// Нормализация ID: число, текст с пробелами, 1.23E+08, 123456789.0, алиас name@ad.
enum ConnectionID {
    struct Normalized: Equatable {
        let value: String
        /// Записано как 1.23E+08: нулей в конце могло не быть в исходном ID.
        let lossy: Bool

        var isAlias: Bool { value.contains("@") }
    }

    /// Невидимые знаки, которые приносит копирование из мессенджеров и веба.
    private static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]

    /// nil — значение не похоже на ID. Пустую строку вызывающий обрабатывает отдельно.
    static func normalize(_ raw: String) -> Normalized? {
        let s = String(raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !invisible.contains($0) })
        guard !s.isEmpty else { return nil }
        if s.contains("@") { return alias(s).map { Normalized(value: $0, lossy: false) } }
        return number(s)
    }

    private static func alias(_ s: String) -> String? {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let ok: (Substring) -> Bool = { part in
            part.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0) }
        }
        guard ok(parts[0]), ok(parts[1]) else { return nil }
        return s.lowercased()
    }

    private static func number(_ s: String) -> Normalized? {
        var mantissa = s.lowercased()
        // «1,23E+08» — так экспоненту пишет Excel с русской или украинской локалью.
        if mantissa.contains("e") { mantissa = mantissa.replacingOccurrences(of: ",", with: ".") }
        var exponent = 0
        var hasExponent = false
        if let e = mantissa.firstIndex(of: "e") {
            guard let x = Int(mantissa[mantissa.index(after: e)...].replacingOccurrences(of: "+", with: "")),
                  abs(x) <= 30 else { return nil }
            exponent = x
            hasExponent = true
            mantissa = String(mantissa[..<e])
        }
        let halves = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard halves.count <= 2, let whole = halves.first, !whole.isEmpty || halves.count == 2 else { return nil }
        let fraction = halves.count == 2 ? String(halves[1]) : ""
        guard (whole + fraction).allSatisfy({ $0.isASCII && $0.isNumber }), !(whole + fraction).isEmpty else { return nil }
        var digits = Array(whole + fraction)
        let point = whole.count + exponent
        if point < 0 { return nil }
        if point >= digits.count {
            digits += Array(repeating: "0", count: point - digits.count)
        } else {
            // Дробная часть допустима, только если она нулевая (123456789.0).
            guard digits[point...].allSatisfy({ $0 == "0" }) else { return nil }
            digits = Array(digits[..<point])
        }
        var text = String(digits)
        // Нули слева у «чистого» текста — часть ID; у числа с точкой или экспонентой — артефакт записи.
        if hasExponent || halves.count == 2 { while text.count > 1, text.hasPrefix("0") { text.removeFirst() } }
        guard (9...10).contains(text.count) else { return nil }
        // Экспонента дописала нули: в 1.23E+08 цифр меньше, чем в ID.
        return Normalized(value: text, lossy: hasExponent && (whole.count + fraction.count) < text.count)
    }
}
