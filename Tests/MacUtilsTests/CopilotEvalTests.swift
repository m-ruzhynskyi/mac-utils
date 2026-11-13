import XCTest
@testable import MUCopilot

/// Диалоги для оценки ответов и прогонщик. Обычный `swift test` только проверяет сами диалоги и оценщик (без ИИ).
/// Настоящий прогон — команда менеджера:
///   scripts/copilot-eval.sh codex      (или claude)
/// Ответы и оценки — в `.audit/copilot-eval/<бэкенд>/`.
enum CopilotFixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Copilot")
    }

    static func load() throws -> [CopilotDialog] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try JSONDecoder().decode(CopilotDialog.self, from: Data(contentsOf: $0)) }
    }
}

final class CopilotFixturesTests: XCTestCase {
    func testDialogSetIsBigEnoughAndBalanced() throws {
        let dialogs = try CopilotFixtures.load()
        XCTAssertGreaterThanOrEqual(dialogs.count, 20)
        XCTAssertLessThanOrEqual(dialogs.count, 30)
        XCTAssertEqual(Set(dialogs.map(\.id)).count, dialogs.count, "id уникальны")
        for lang in ["ru", "uk", "en"] { XCTAssertGreaterThanOrEqual(dialogs.filter { $0.language == lang }.count, 6, lang) }
        XCTAssertGreaterThanOrEqual(dialogs.filter { !$0.expectQuestion }.count, 3)
        XCTAssertTrue(dialogs.contains { $0.kind == "interview" } && dialogs.contains { $0.kind == "work" })
        for d in dialogs {
            XCTAssertFalse(d.utterances.isEmpty, d.id)
            XCTAssertEqual(d.expectQuestion, !d.keywordGroups.isEmpty, d.id)
            XCTAssertEqual(d.utterances.map(\.secondsAgo), d.utterances.map(\.secondsAgo).sorted(by: >), "\(d.id): реплики по порядку")
        }
    }

    func testDetectorAgreesWithFixtures() throws {
        for d in try CopilotFixtures.load() {
            let found = QuestionDetector.pendingQuestion(in: d.utterances(now: Date())) != nil
            XCTAssertEqual(found, d.expectQuestion, "быстрое правило ошиблось на \(d.id)")
        }
    }

    func testPromptsFitTheDialogs() throws {
        for d in try CopilotFixtures.load() {
            let user = CopilotPrompt.user(settings: d.settings, utterances: d.utterances(now: Date()), now: Date(), mode: .lastQuestion)
            XCTAssertTrue(user.contains(d.utterances.last!.text), d.id)
        }
    }

    func testGraderOnGoodAndBadAnswers() throws {
        let dialogs = try CopilotFixtures.load()
        let q = try XCTUnwrap(dialogs.first { $0.id == "ru-01-sql-slow-report" })
        let good = CopilotEvalGrader.grade(raw: "Начну с плана запроса.\n- EXPLAIN ANALYZE\n- Составной индекс\n- Сводная таблица", dialog: q)
        XCTAssertTrue(good.passed)
        XCTAssertEqual(good.keywordGroupsHit, good.keywordGroupsTotal)
        XCTAssertFalse(CopilotEvalGrader.grade(raw: "NO_QUESTION", dialog: q).passed)
        XCTAssertFalse(CopilotEvalGrader.grade(raw: "Фраза.\n- один", dialog: q).passed)
        XCTAssertFalse(CopilotEvalGrader.grade(raw: String(repeating: "я", count: 400) + "\n- а\n- б", dialog: q).passed)
        let n = try XCTUnwrap(dialogs.first { !$0.expectQuestion })
        XCTAssertTrue(CopilotEvalGrader.grade(raw: "NO_QUESTION", dialog: n).passed)
        XCTAssertFalse(CopilotEvalGrader.grade(raw: "Ответ.\n- а\n- б", dialog: n).passed)
    }
}

/// Прогон на настоящем ИИ через его командную строку. Включается только `MU_COPILOT_EVAL=codex|claude`: это расход подписки.
/// После появления `MUAIBackend` прогон пойдёт через него (`CopilotAIClient`); командные строки здесь — те же, что в задаче бэкенда.
final class CopilotEvalRunTests: XCTestCase {
    private struct Result: Codable {
        let id: String
        let backend: String
        let seconds: Double
        let raw: String
        let grade: CopilotGrade
        let error: String?
    }

    func testRunDialogsOnRealBackend() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let backend = env["MU_COPILOT_EVAL"], ["codex", "claude"].contains(backend) else {
            throw XCTSkip("Настоящий прогон: scripts/copilot-eval.sh codex|claude (расход подписки, только по команде менеджера)")
        }
        let only = env["MU_COPILOT_ONLY"]
        let out = URL(fileURLWithPath: env["MU_COPILOT_OUT"] ?? FileManager.default.currentDirectoryPath + "/.audit/copilot-eval")
            .appendingPathComponent(backend, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let dialogs = try CopilotFixtures.load().filter { only == nil || $0.id.hasPrefix(only!) }
        var results: [Result] = []
        for d in dialogs {
            let now = Date()
            let system = CopilotPrompt.system(settings: d.settings)
            let user = CopilotPrompt.user(settings: d.settings, utterances: d.utterances(now: now), now: now, mode: .lastQuestion)
            let started = Date()
            var raw = "", error: String?
            do { raw = try await Self.run(backend: backend, system: system, user: user) } catch let e { error = "\(e)" }
            let seconds = Date().timeIntervalSince(started)
            let result = Result(id: d.id, backend: backend, seconds: seconds, raw: raw, grade: CopilotEvalGrader.grade(raw: raw, dialog: d), error: error)
            results.append(result)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: out.appendingPathComponent("\(d.id).json"))
        }
        try Self.summary(results, backend: backend).write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    private static func summary(_ r: [Result], backend: String) -> String {
        let passed = r.filter { $0.grade.passed && $0.error == nil }.count
        let times = r.map(\.seconds).sorted()
        let median = times.isEmpty ? 0 : times[times.count / 2]
        var s = "# Прогон подсказчика на \(backend)\n\nПрошли автопроверку: \(passed) из \(r.count). Время ответа целиком: медиана \(String(format: "%.1f", median)) с, максимум \(String(format: "%.1f", times.last ?? 0)) с (до первой строки меньше: ответ приходит целиком).\n\nАвтопроверка ловит только явные провалы (формат, решение «вопрос / не вопрос», длина, ключевые слова). Качество ответов оценивает человек: читать `<id>.json` → `raw`.\n\n| диалог | с | решение | пунктов | ключи | заметки |\n|---|---|---|---|---|---|\n"
        for x in r {
            s += "| \(x.id) | \(String(format: "%.1f", x.seconds)) | \(x.grade.correctDecision ? "ок" : "нет") | \(x.grade.pointCount) | \(x.grade.keywordGroupsHit)/\(x.grade.keywordGroupsTotal) | \(x.error ?? x.grade.notes.joined(separator: "; ")) |\n"
        }
        return s
    }

    /// Команды как в задаче бэкенда: без инструментов и файлов, одноразовая сессия.
    private static func run(backend: String, system: String, user: String) async throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let process = Process()
        let outFile = work.appendingPathComponent("answer.txt")
        if backend == "codex" {
            process.executableURL = home.appendingPathComponent(".local/node/bin/codex")
            process.arguments = ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--color", "never",
                                 "-C", work.path, "-o", outFile.path, "-"]
        } else {
            process.executableURL = home.appendingPathComponent(".local/bin/claude")
            process.arguments = ["-p", "--output-format", "text", "--tools", "", "--no-session-persistence", "--system-prompt", system]
        }
        process.currentDirectoryURL = work
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = home.appendingPathComponent(".local/node/bin").path + ":" + home.appendingPathComponent(".local/bin").path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        let prompt = backend == "codex" ? system + "\n\n" + user : user
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try input.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "eval", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: stderr.suffix(400), as: UTF8.self)])
        }
        if backend == "codex" { return (try? String(contentsOf: outFile, encoding: .utf8)) ?? String(decoding: stdout, as: UTF8.self) }
        return String(decoding: stdout, as: UTF8.self)
    }
}
