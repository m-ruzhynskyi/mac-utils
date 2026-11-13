import Foundation

/// Какой сервис ИИ использует подсказчик.
package enum CopilotProviderChoice: String, CaseIterable, Equatable {
    /// Как выбрано на странице «ИИ» (по умолчанию Codex).
    case system
    case claude
    case codex

    package var title: String {
        switch self {
        case .system: return "Как в Mac Utils"
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        }
    }

    package static let key = "copilotProvider"

    package static func load(_ d: UserDefaults = .standard) -> CopilotProviderChoice {
        d.string(forKey: key).flatMap(CopilotProviderChoice.init(rawValue:)) ?? .system
    }
}

/// Скользящие замеры «до первой строки» по сервисам (последние 10 ответов).
package struct LatencyStats: Equatable {
    package private(set) var samples: [String: [Double]] = [:]
    package static let window = 10

    package init(samples: [String: [Double]] = [:]) { self.samples = samples }

    package mutating func add(_ seconds: Double, provider: String) {
        var list = samples[provider] ?? []
        list.append(seconds)
        if list.count > Self.window { list.removeFirst(list.count - Self.window) }
        samples[provider] = list
    }

    package func mean(_ provider: String) -> (seconds: Double, count: Int)? {
        guard let list = samples[provider], !list.isEmpty else { return nil }
        return (list.reduce(0, +) / Double(list.count), list.count)
    }

    package static let storeKey = "copilotLatencyStats"

    package static func load(_ d: UserDefaults = .standard) -> LatencyStats {
        LatencyStats(samples: (d.dictionary(forKey: storeKey) as? [String: [Double]]) ?? [:])
    }

    package func save(_ d: UserDefaults = .standard) { d.set(samples, forKey: Self.storeKey) }
}

package enum ProviderAdvice {
    /// Дольше этого (среднее «до первой строки») совет переключиться.
    package static let slowSeconds: Double = 3
    /// Сколько замеров нужно, чтобы советовать.
    package static let minSamples = 3

    package struct Suggestion: Equatable {
        package let provider: String
        package let text: String
        /// Совет по замерам этого Mac (false) или заранее известный (true: своих замеров ещё нет).
        package let isPrior: Bool
    }

    /// Совет «Claude · быстрый». Выбор остаётся как в Mac Utils (Codex по умолчанию): подсказчик только предлагает.
    /// - есть замеры Codex (≥ 3): советуем, если среднее > 3 с и у Claude не хуже;
    /// - замеров ещё нет, а Claude подключён: советуем по известным цифрам (Claude ≈ 1 с, ChatGPT ≈ 4 с до первой строки).
    package static func suggest(effective: String, stats: LatencyStats, claudeConnected: Bool) -> Suggestion? {
        guard effective == "codex", claudeConnected else { return nil }
        guard let codex = stats.mean("codex"), codex.count >= minSamples else {
            return Suggestion(provider: "claude", text: "Claude · быстрый: первая строка примерно за 1 с, у ChatGPT — около 4 с", isPrior: true)
        }
        guard codex.seconds > slowSeconds else { return nil }
        if let claude = stats.mean("claude"), claude.count >= minSamples, claude.seconds >= codex.seconds { return nil }
        return Suggestion(provider: "claude", text: String(format: "Claude отвечает быстрее: у ChatGPT первая строка в среднем через %.1f с", codex.seconds),
                          isPrior: false)
    }
}
