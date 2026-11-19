import Foundation

/// Строки между Mac Utils и процессом-помощником (stdin/stdout, по строке на сообщение).
/// Помощник держит скрытый дисплей: дисплей живёт, пока жив создавший его процесс, а помощник переживает падение Mac Utils.
public enum HelperCommand: Equatable, Sendable {
    /// Создать дисплей (точки, HiDPI ×2).
    case open(width: Int, height: Int)
    /// Какие программы прятать, если Mac Utils пропадёт (bundle id).
    case apps([String])
    /// Обычное завершение: Mac Utils уже вернула или спрятала окна сама.
    case quit
    /// Спрятать программы, затем снять дисплей и выйти.
    case hideAndQuit

    public var line: String {
        switch self {
        case let .open(width, height): return "open \(width) \(height)"
        case let .apps(ids): return "apps \(ids.joined(separator: ","))"
        case .quit: return "quit"
        case .hideAndQuit: return "hide-quit"
        }
    }

    public init?(line: String) {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
        guard let head = parts.first else { return nil }
        switch head {
        case "open":
            let numbers = (parts.count > 1 ? parts[1] : "").split(separator: " ").compactMap { Int($0) }
            guard numbers.count == 2, (320...7680).contains(numbers[0]), (240...4320).contains(numbers[1]) else { return nil }
            self = .open(width: numbers[0], height: numbers[1])
        case "apps":
            let ids = (parts.count > 1 ? parts[1] : "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self = .apps(ids)
        case "quit":
            self = .quit
        case "hide-quit":
            self = .hideAndQuit
        default:
            return nil
        }
    }
}

public enum HelperMessage: Equatable, Sendable {
    /// Дисплей создан.
    case display(UInt32)
    case failed(String)
    /// Система сама сняла дисплей (помощник уже спрятал программы).
    case terminated

    public var line: String {
        switch self {
        case let .display(id): return "display \(id)"
        case let .failed(text): return "error \(text.replacingOccurrences(of: "\n", with: " "))"
        case .terminated: return "terminated"
        }
    }

    public init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "terminated" { self = .terminated; return }
        if trimmed.hasPrefix("error ") { self = .failed(String(trimmed.dropFirst(6))); return }
        if trimmed.hasPrefix("display "), let id = UInt32(trimmed.dropFirst(8)), id != 0 { self = .display(id); return }
        return nil
    }
}

/// Сборка строк из кусков, пришедших по трубе (кусок может оборваться посреди строки).
public struct LineBuffer: Sendable {
    private var pending = ""

    public init() {}

    public mutating func append(_ chunk: String) -> [String] {
        pending += chunk
        var lines: [String] = []
        while let newline = pending.firstIndex(of: "\n") {
            lines.append(String(pending[..<newline]))
            pending = String(pending[pending.index(after: newline)...])
        }
        return lines
    }
}
