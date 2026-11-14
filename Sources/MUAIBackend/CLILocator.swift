import Foundation
import MUCore

/// Где лежат codex и claude. У программы, запущенной из Finder, в PATH нет `~/.local/bin` и папок npm,
/// поэтому сначала смотрим известные места, затем PATH login shell (`zsh -lc`).
package enum CLILocator {
    /// Известные места (в этом порядке), `~` — домашняя папка.
    package static func knownPaths(for program: String, home: String) -> [String] {
        let dirs = [
            "\(home)/.local/bin",
            "\(home)/.local/node/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        var paths = dirs.map { "\($0)/\(program)" }
        // Старая установка Claude Code (`claude migrate-installer`) — исполняемый файл в ~/.claude/local.
        if program == "claude" { paths.append("\(home)/.claude/local/claude") }
        return paths
    }

    /// Первый исполняемый файл: известные места, затем папки PATH login shell.
    package static func find(_ program: String, home: String, loginPath: String?,
                             isExecutable: (String) -> Bool) -> String? {
        let fromShell = (loginPath ?? "").split(separator: ":").map { "\($0)/\(program)" }
        var seen = Set<String>()
        for path in knownPaths(for: program, home: home) + fromShell where seen.insert(path).inserted {
            if isExecutable(path) { return path }
        }
        return nil
    }

    /// PATH для дочернего процесса: папка программы (codex — скрипт `#!/usr/bin/env node`, node лежит рядом),
    /// PATH login shell и системные папки — без повторов.
    package static func environmentPath(executable: String, loginPath: String?) -> String {
        let system = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let dirs = [(executable as NSString).deletingLastPathComponent]
            + (loginPath ?? "").split(separator: ":").map(String.init) + system
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Последняя непустая строка вывода `zsh -lc 'print -r -- $PATH'` (до неё .zprofile мог что-то напечатать).
    package static func parseLoginPath(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let line, line.contains("/") else { return nil }
        return line
    }
}

/// Найденные программы и PATH login shell — один раз за запуск (или до «Проверить»).
package actor CLIEnvironment {
    package static let shared = CLIEnvironment()

    private var loginPath: String??
    private var located: [AIProvider: String] = [:]

    /// Забыть найденное: человек мог только что поставить программу.
    package func reset() {
        loginPath = nil
        located = [:]
    }

    package func executable(for provider: AIProvider) async -> String? {
        if let path = located[provider], FileManager.default.isExecutableFile(atPath: path) { return path }
        let shellPath = await shellPATH()
        let path = CLILocator.find(provider.program, home: NSHomeDirectory(), loginPath: shellPath,
                                   isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
        located[provider] = path
        return path
    }

    /// Окружение для запуска: своё окружение программы + PATH с папкой найденной программы.
    package func environment(for executable: String) async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = CLILocator.environmentPath(executable: executable, loginPath: await shellPATH())
        environment["NO_COLOR"] = "1"
        // Если Mac Utils запущен из сессии Claude Code, не выдаём дочерний claude за вложенный.
        environment.removeValue(forKey: "CLAUDECODE")
        return environment
    }

    private func shellPATH() async -> String? {
        if let loginPath { return loginPath }
        let command = CLICommand(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "print -r -- $PATH"],
                                 directory: AIWorkspace.directory)
        let result = try? await CLIProcess.run(command, timeout: 5)
        let path = result.flatMap { $0.status == 0 ? CLILocator.parseLoginPath($0.stdout) : nil }
        if path == nil { Log.ai.info("PATH login shell не получен") }
        loginPath = .some(path)
        return path
    }
}

/// Пустая папка — рабочая для codex/claude: рядом нет файлов пользователя и git-репозитория.
package enum AIWorkspace {
    package static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacUtils-AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
