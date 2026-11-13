import XCTest
@testable import MacUtils
@testable import MUCopilot
import MUAIBackend

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
        let long = CopilotEvalGrader.grade(raw: String(repeating: "я", count: 400) + "\n- а\n- б", dialog: q)
        XCTAssertTrue(long.passed, "оценка — по строке после обрезки")
        XCTAssertTrue(long.rawTooLong)
        XCTAssertEqual(long.rawSayLength, 400)
        XCTAssertLessThanOrEqual(long.sayLength, 141)
        let n = try XCTUnwrap(dialogs.first { !$0.expectQuestion })
        XCTAssertTrue(CopilotEvalGrader.grade(raw: "NO_QUESTION", dialog: n).passed)
        XCTAssertFalse(CopilotEvalGrader.grade(raw: "Ответ.\n- а\n- б", dialog: n).passed)
    }
}

/// Прогон на настоящем ИИ. Включается только `MU_COPILOT_EVAL=codex|claude`: это расход подписки.
/// Режимы (`MU_COPILOT_MODE`):
///   cold         как раньше: CLI на каждый вопрос, основная модель
///   cold-fast    CLI на каждый вопрос, малое «размышление»
///   warm         тёплый процесс, основная модель
///   warm-fast    тёплый процесс, быстрая модель и малое «размышление» (по умолчанию в приложении)
///   hybrid       тёплые процессы: первая строка — быстрая модель, пункты — основная, одновременно
/// Замеряется поток: до первого куска, до конца первой строки, до конца ответа; отдельно — цена запуска процесса.
final class CopilotEvalRunTests: XCTestCase {
    private struct Result: Codable {
        let id: String
        let backend: String
        let mode: String
        let firstChunk: Double?
        let firstLine: Double?
        let total: Double
        let raw: String
        let grade: CopilotGrade
        let error: String?
        /// Холодный ли процесс у этого вопроса (Claude тёплый режим) и который по счёту в сессии — для разбора хвостов.
        let cold: Bool?
        let sessionQuestion: Int?
    }

    private func client(backend: String, mode: String) throws -> CopilotAIClient {
        let provider: AIProvider = backend == "codex" ? .codex : .claude
        switch mode {
        case "cold", "cold-fast": return ColdCopilotAI(provider: provider)
        case "warm", "warm-fast", "hybrid": return WarmCopilotAI(provider: provider)
        default: throw XCTSkip("Неизвестный режим \(mode)")
        }
    }

    /// Один ответ потоком; время — от запроса.
    private func measure(_ client: CopilotAIClient, system: String, user: String, profile: CopilotAIProfile,
                         onPiece: ((String) -> Void)? = nil) async throws -> (raw: String, firstChunk: Double?, firstLine: Double?, total: Double) {
        let started = Date()
        var raw = "", firstChunk: Double?, firstLine: Double?
        for try await piece in client.stream(prompt: user, system: system, images: [], profile: profile) {
            raw += piece
            let t = Date().timeIntervalSince(started)
            if firstChunk == nil { firstChunk = t }
            if firstLine == nil, raw.contains("\n") { firstLine = t }
            onPiece?(piece)
        }
        let total = Date().timeIntervalSince(started)
        // Ответ без перевода строки (одна строка или NO_QUESTION): строка закончилась вместе с ответом.
        return (raw, firstChunk, firstLine ?? (raw.isEmpty ? nil : total), total)
    }

    func testRunDialogsOnRealBackend() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let backend = env["MU_COPILOT_EVAL"], ["codex", "claude"].contains(backend) else {
            throw XCTSkip("Настоящий прогон: scripts/copilot-eval.sh codex|claude [режим] (расход подписки, только по команде менеджера)")
        }
        let mode = env["MU_COPILOT_MODE"] ?? "cold"
        let only = env["MU_COPILOT_ONLY"]
        let out = URL(fileURLWithPath: env["MU_COPILOT_OUT"] ?? FileManager.default.currentDirectoryPath + "/.audit/copilot-eval")
            .appendingPathComponent("\(backend)-\(mode)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let ai = try client(backend: backend, mode: mode)
        let fast = mode.hasSuffix("fast")
        let dialogs = try CopilotFixtures.load().filter { only == nil || $0.id.hasPrefix(only!) }

        // Цена запуска: тёплый режим — время до готовности процесса; холодный — её платит каждый вопрос.
        var startup: Double?
        if mode.hasPrefix("warm") || mode == "hybrid" {
            let t = Date()
            // Прогреваем сессии для каждого языка диалогов: у каждого свой системный текст, как в приложении.
            let part: CopilotPrompt.Part = mode == "hybrid" ? .sayOnly : .full
            for lang in Set(dialogs.map(\.language)).sorted() {
                await ai.warmUp(system: CopilotPrompt.system(settings: CopilotSettings(meetingLanguage: lang), part: part))
            }
            startup = Date().timeIntervalSince(t)
        }
        var results: [Result] = []
        // MU_COPILOT_REPEAT=2 — те же диалоги ещё раз подряд в той же сессии: так видно хвосты установившегося режима.
        let rounds = max(1, Int(env["MU_COPILOT_REPEAT"] ?? "") ?? 1)
        for round in 1...rounds { for d in dialogs {
            let now = Date()
            let user = CopilotPrompt.user(settings: d.settings, utterances: d.utterances(now: now), now: now, mode: .lastQuestion)
            var raw = "", firstChunk: Double?, firstLine: Double?, total = 0.0, error: String?
            do {
                if mode == "hybrid" {
                    // Две половины одновременно, как в приложении; первая строка — как только быстрая половина её закончила.
                    let started = Date()
                    var h = HybridAnswer()
                    let stream: (CopilotPrompt.Part, CopilotAIProfile) async throws -> Void = { part, profile in
                        let system = CopilotPrompt.system(settings: d.settings, part: part)
                        for try await piece in ai.stream(prompt: user, system: system, images: [], profile: profile) {
                            await MainActor.run {
                                if part == .sayOnly { h.appendSay(piece) } else { h.appendPoints(piece) }
                                let t = Date().timeIntervalSince(started)
                                if firstChunk == nil, part == .sayOnly { firstChunk = t }
                            }
                        }
                        await MainActor.run {
                            if part == .sayOnly { h.finishSay(); if firstLine == nil { firstLine = Date().timeIntervalSince(started) } } else { h.finishPoints() }
                        }
                    }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await stream(.sayOnly, .fast) }
                        group.addTask { try await stream(.pointsOnly, .main) }
                        try await group.waitForAll()
                    }
                    total = Date().timeIntervalSince(started)
                    if case .noQuestion = h.parsed { raw = CopilotPrompt.noQuestionMarker }
                    else if case .answer(let a) = h.parsed { raw = a.say + "\n" + a.points.map { "- " + $0 }.joined(separator: "\n") }
                } else {
                    let r = try await measure(ai, system: CopilotPrompt.system(settings: d.settings), user: user, profile: fast ? .fast : .main)
                    (raw, firstChunk, firstLine, total) = (r.raw, r.firstChunk, r.firstLine, r.total)
                }
            } catch let e { error = "\(e)" }
            let info = (ai as? WarmCopilotAI)?.lastInfo
            let result = Result(id: rounds > 1 ? "\(d.id)-r\(round)" : d.id, backend: backend, mode: mode, firstChunk: firstChunk, firstLine: firstLine,
                                total: total, raw: raw, grade: CopilotEvalGrader.grade(raw: raw, dialog: d), error: error,
                                cold: info?.cold, sessionQuestion: info.map { $0.usesBefore + 1 })
            results.append(result)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: out.appendingPathComponent("\(result.id).json"))
        } }
        await ai.shutdown()
        try Self.summary(results, backend: backend, mode: mode, startup: startup).write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    private static func stat(_ values: [Double]) -> String {
        let v = values.sorted()
        guard !v.isEmpty else { return "—" }
        return String(format: "медиана %.1f, p90 %.1f, макс %.1f", v[v.count / 2], v[min(v.count - 1, Int(Double(v.count) * 0.9))], v.last!)
    }

    private static func summary(_ r: [Result], backend: String, mode: String, startup: Double?) -> String {
        let asked = r.filter { $0.error == nil && $0.grade.sayLength > 0 }
        let rawLong = asked.filter { $0.grade.rawTooLong }.count
        let passed = r.filter { $0.grade.passed && $0.error == nil }.count
        var s = "# Подсказчик: \(backend), режим \(mode)\n\nАвтопроверка: \(passed) из \(r.count) (первая строка — после обрезки в показе, ≤ \(CopilotPrompt.maxSayLength) знаков).\nСырых первых строк длиннее \(CopilotPrompt.maxSayLength) знаков или \(CopilotPrompt.maxSayWords) слов: \(rawLong) из \(asked.count) (в показе режутся, но модель стоит поправить).\n\n"
        s += "- до первого куска, с: \(stat(asked.compactMap(\.firstChunk)))\n"
        s += "- до конца первой строки, с (цель ≤ 2,5): \(stat(asked.compactMap(\.firstLine)))\n"
        s += "- до конца ответа, с (цель ≤ 6): \(stat(r.map(\.total)))\n"
        let cold = r.filter { $0.cold == true }
        if !r.compactMap(\.cold).isEmpty {
            s += "- вопросов на холодном процессе: \(cold.count) из \(r.count)" + (cold.isEmpty ? "\n" : " (их первая строка: \(stat(cold.compactMap(\.firstLine))))\n")
            let warmOnly = r.filter { $0.cold == false }.compactMap(\.firstLine)
            if !warmOnly.isEmpty { s += "- первая строка только на тёплых: \(stat(warmOnly))\n" }
        }
        if let startup { s += "- запуск тёплого процесса (платится один раз при включении), с: \(String(format: "%.1f", startup))\n" }
        s += "\nАвтопроверка ловит явные провалы; качество оценивает человек (`<id>.json` → `raw`).\n\n| диалог | 1-й кусок | 1-я строка | всё | решение | пунктов | ключи | знаков в 1-й | сессия | заметки |\n|---|---|---|---|---|---|---|---|---|---|\n"
        func f(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "—" }
        for x in r {
            s += "| \(x.id) | \(f(x.firstChunk)) | \(f(x.firstLine)) | \(f(x.total)) | \(x.grade.correctDecision ? "ок" : "нет") | \(x.grade.pointCount) | \(x.grade.keywordGroupsHit)/\(x.grade.keywordGroupsTotal) | \(x.grade.sayLength) | \(x.cold.map { ($0 ? "холодная" : "тёплая") + " №\(x.sessionQuestion ?? 0)" } ?? "—") | \(x.error ?? x.grade.notes.joined(separator: "; ")) |\n"
        }
        return s
    }
}
