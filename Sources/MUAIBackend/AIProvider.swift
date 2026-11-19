import Foundation

/// Сервис ИИ: программа ChatGPT (Codex) или Claude Code на этом Mac, под аккаунтом пользователя.
package enum AIProvider: String, CaseIterable, Sendable {
    case codex, claude

    /// Выбор по умолчанию.
    package static let standard: AIProvider = .codex

    package var title: String {
        switch self {
        case .codex: return "ChatGPT (Codex)"
        case .claude: return "Claude"
        }
    }

    /// Имя программы в PATH.
    package var program: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }

    /// Команда входа в аккаунт — для подсказок.
    package var loginCommand: String {
        switch self {
        case .codex: return "codex login"
        case .claude: return "claude auth login"
        }
    }

    /// Как поставить программу — для подсказки «не найдено».
    package var installHint: String {
        switch self {
        case .codex: return "Установите Codex CLI: npm install -g @openai/codex"
        case .claude: return "Установите Claude Code: claude.ai/install"
        }
    }

    package var other: AIProvider { self == .codex ? .claude : .codex }

    /// Сохранённое значение настройки → сервис (неизвестное и пустое — по умолчанию Codex).
    package init(stored: String?) {
        self = stored.flatMap(AIProvider.init(rawValue:)) ?? .standard
    }
}

/// Состояние подключения сервиса для страницы «ИИ» и проверок перед работой.
package enum AIConnection: Equatable, Sendable {
    case unknown
    case checking
    case connected
    case notFound
    case notLoggedIn
    /// Программа есть, но проверка не удалась (таймаут, странный ответ).
    case problem(String)

    package var isReady: Bool { self == .connected }
}

/// Ошибка запроса к ИИ с понятным текстом.
package struct AIFailure: LocalizedError, Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case notFound, notLoggedIn, timeout, empty, failed
    }

    package let provider: AIProvider?
    package let kind: Kind
    package let message: String

    package init(_ kind: Kind, provider: AIProvider?, message: String) {
        self.kind = kind
        self.provider = provider
        self.message = message
    }

    package var errorDescription: String? { message }

    package static func notFound(_ provider: AIProvider) -> AIFailure {
        AIFailure(.notFound, provider: provider, message: "\(provider.title) не найден на этом Mac. \(provider.installHint)")
    }

    package static func notLoggedIn(_ provider: AIProvider) -> AIFailure {
        AIFailure(.notLoggedIn, provider: provider,
                  message: "Войдите в \(provider == .codex ? "Codex" : "Claude"): \(provider.loginCommand) в Терминале")
    }

    package static func timeout(_ provider: AIProvider, seconds: TimeInterval) -> AIFailure {
        AIFailure(.timeout, provider: provider, message: "\(provider.title) не ответил за \(Int(seconds.rounded())) с")
    }

    package static func empty(_ provider: AIProvider) -> AIFailure {
        AIFailure(.empty, provider: provider, message: "\(provider.title) вернул пустой ответ")
    }

    /// Модель взялась за инструмент (команду, файл), хотя ответ должен быть только текстом: процесс остановлен.
    package static func toolUse(_ provider: AIProvider, kind: String) -> AIFailure {
        AIFailure(.failed, provider: provider,
                  message: "\(provider.title) попытался выполнить действие на Mac (\(kind)) — остановлено, ответ не использован. Повторите запрос.")
    }

    /// Ошибки обоих сервисов (выбранного и запасного) — одним текстом, чтобы первая не терялась за второй.
    /// Вид — от первого (выбранного): по нему интерфейс решает, что подсказать.
    package static func combined(_ failures: [AIFailure]) -> AIFailure {
        guard let first = failures.first else { return AIFailure(.failed, provider: nil, message: "ИИ не выбран") }
        guard failures.count > 1 else { return first }
        return AIFailure(first.kind, provider: first.provider, message: failures.map(\.message).joined(separator: " · "))
    }

    /// Ошибка из вывода программы: вход в аккаунт узнаём по тексту, остальное — как есть (коротко).
    package static func from(_ provider: AIProvider, output: String) -> AIFailure {
        if mentionsLogin(output) { return .notLoggedIn(provider) }
        // Старый codex не знает выключаемую функцию (`--disable …`): без неё инструменты не выключить — просим обновить.
        if provider == .codex, output.lowercased().contains("unknown feature flag") {
            return AIFailure(.failed, provider: provider, message: "\(provider.title): версия устарела — обновите в Терминале: codex update")
        }
        let line = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        let text = line.isEmpty ? "ошибка без описания" : String(line.prefix(300))
        return AIFailure(.failed, provider: provider, message: "\(provider.title): \(text)")
    }

    /// Признаки «не вошли в аккаунт» в выводе codex и claude.
    package static func mentionsLogin(_ output: String) -> Bool {
        let text = output.lowercased()
        return ["not logged in", "please run /login", "codex login", "claude auth login", "unauthorized", "status 401",
                "invalid api key", "authentication_error", "not authenticated", "oauth token has expired",
                "please log in", "login required"].contains { text.contains($0) }
    }
}

/// Один запрос к модели.
package struct AIRequest: Equatable, Sendable {
    package var prompt: String
    package var system: String?
    /// Картинки (PNG/JPEG/GIF/WebP) — файлы на диске.
    package var images: [URL]
    package var timeout: TimeInterval
    /// Короткая задача (имя файла, категория): меньше рассуждений — быстрее ответ.
    package var quick: Bool

    package init(prompt: String, system: String? = nil, images: [URL] = [], timeout: TimeInterval = 120, quick: Bool = false) {
        self.prompt = prompt
        self.system = system
        self.images = images
        self.timeout = timeout
        self.quick = quick
    }

    /// Системный текст по умолчанию: без него Claude Code берёт свой — для программирования.
    package static let defaultSystem = "Ты помощник в программе Mac Utils. Отвечай по делу, без вступлений."
    /// Добавка к системному тексту: ответ — только текст, никаких действий.
    package static let textOnly = "Отвечай только текстом. Не запускай команды, не читай и не меняй файлы."
    /// Добавка для ответов-JSON.
    package static let jsonOnly = "Ответь только JSON-объектом, без пояснений и без ```."
}

/// Бэкенд ИИ: одна программа (Codex или Claude).
package protocol AIEngine: Sendable {
    var provider: AIProvider { get }
    /// Куски ответа по мере появления; ошибка — `AIFailure` или `CancellationError`.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>
    /// То же, плюс `alive` — модель уже работает, хотя текста ещё нет (codex отдаёт ответ целиком в конце).
    /// По нему `AIRouter` не уходит к запасному сервису по таймеру первого куска.
    func stream(_ request: AIRequest, alive: @escaping @Sendable () -> Void) -> AsyncThrowingStream<String, Error>
}

extension AIEngine {
    package func stream(_ request: AIRequest, alive: @escaping @Sendable () -> Void) -> AsyncThrowingStream<String, Error> {
        stream(request)
    }

    package func stream(prompt: String, system: String?, images: [URL], timeout: TimeInterval) -> AsyncThrowingStream<String, Error> {
        stream(AIRequest(prompt: prompt, system: system, images: images, timeout: timeout))
    }

    package func generate(_ request: AIRequest) async throws -> String {
        var text = ""
        for try await chunk in stream(request) { text += chunk }
        return text
    }

    package func generate(prompt: String, system: String?, images: [URL], timeout: TimeInterval) async throws -> String {
        try await generate(AIRequest(prompt: prompt, system: system, images: images, timeout: timeout))
    }
}
