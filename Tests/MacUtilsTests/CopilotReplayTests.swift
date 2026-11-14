import XCTest
import AVFoundation
@testable import MacUtils
@testable import MUCopilot

/// CHK-4: «Подсказчик» без звонка, без динамиков и без настоящих codex/claude.
/// Речь синтезируется в ФАЙЛ (`AVSpeechSynthesizer.write`, ничего не воспроизводится), файлы читаются обратно,
/// по ним строится «слышимая» линия времени (начало и конец речи — по энергии звука), а дальше идёт тот же код, что в приложении:
/// `StreamingTranscriber` (VolatileSettler) → `CopilotSession` → `QuestionDetector` → заглушка провайдера, которая пишет запрос и время.
/// Время виртуальное: проверка быстрая и повторяемая.
/// Сам SpeechAnalyzer в этом режиме заменён расшифровкой «по сценарию» (слова выходят по мере речи, финал — через `finalDelay`):
/// настоящая расшифровка работает в `testRealSpeechAnalyzerReplay` — только если модель языка уже установлена (скачивать её тест не будет).
@MainActor
final class CopilotReplayTests: XCTestCase {
    // MARK: Корпус

    struct Segment { var speaker: CopilotSpeaker = .other; var text: String; var gapBefore: TimeInterval = 0.6 }
    struct Case {
        var id: String, lang: String, segments: [Segment]
        /// Сколько запросов в провайдер ожидается (0 — не вопрос, 1 — вопрос).
        var expectRequests: Int
        /// Слова вопроса, которые должны быть в запросе целиком (проверка, что вопрос не отправлен обрезанным).
        var expectInPrompt: String?
        var note = ""
        /// Пауза внутри вопроса: в режиме «только финал» обрывок может уйти (продолжение придёт позже окна ожидания), но тогда ответ заменяется полным запросом.
        var split = false
    }

    static let corpus: [Case] = [
        Case(id: "ru-вопрос-как", lang: "ru-RU", segments: [Segment(text: "Как бы вы организовали кэширование в этом сервисе?")], expectRequests: 1, expectInPrompt: "кэширование в этом сервисе"),
        Case(id: "ru-вопрос-без-знака", lang: "ru-RU", segments: [Segment(text: "Расскажите о вашем опыте работы с Кубернетес")], expectRequests: 1, expectInPrompt: "Кубернетес"),
        Case(id: "ru-не-вопрос-как-видите", lang: "ru-RU", segments: [Segment(text: "Как видите, мы расширяем команду и ищем разработчиков.")], expectRequests: 0, note: "вводное «как видите»"),
        Case(id: "ru-не-вопрос-утверждение", lang: "ru-RU", segments: [Segment(text: "Сегодня мы обсудим планы на следующий квартал.")], expectRequests: 0),
        Case(id: "ru-пауза-посреди-вопроса", lang: "ru-RU", segments: [Segment(text: "Расскажите про ваш опыт"), Segment(text: "особенно с базами данных?", gapBefore: 1.4)], expectRequests: 1, expectInPrompt: "базами данных", note: "пауза 1,4 с внутри вопроса", split: true),
        Case(id: "en-вопрос-how", lang: "en-US", segments: [Segment(text: "How would you design a rate limiter for this API?")], expectRequests: 1, expectInPrompt: "rate limiter"),
        Case(id: "en-вопрос-walk-me", lang: "en-US", segments: [Segment(text: "Can you walk me through your last project?")], expectRequests: 1, expectInPrompt: "last project"),
        Case(id: "en-не-вопрос-as-you-can-see", lang: "en-US", segments: [Segment(text: "As you can see, the roadmap is quite ambitious this year.")], expectRequests: 0),
        Case(id: "en-не-вопрос-приветствие", lang: "en-US", segments: [Segment(text: "Thanks for joining the call, everyone.")], expectRequests: 0),
        Case(id: "en-пауза-посреди-вопроса", lang: "en-US", segments: [Segment(text: "What would you do"), Segment(text: "if the production database goes down?", gapBefore: 1.3)], expectRequests: 1, expectInPrompt: "database goes down", note: "пауза 1,3 с внутри вопроса", split: true),
        Case(id: "en-вы-ответили-сами", lang: "en-US", segments: [
            Segment(text: "Tell me about your experience with distributed systems."),
            Segment(speaker: .me, text: "Well, I mostly worked with Kafka and Postgres at my last job.", gapBefore: 1.5),
            Segment(text: "Thanks, that is clear.", gapBefore: 1.0)], expectRequests: 1, expectInPrompt: "distributed systems", note: "после вашего ответа новых запросов нет"),
        Case(id: "en-перебивание", lang: "en-US", segments: [
            Segment(text: "How do you usually"),
            Segment(speaker: .me, text: "Sorry, one second, let me share my screen first.", gapBefore: 0.8),
            Segment(text: "handle code reviews in your team?", gapBefore: 1.0)], expectRequests: 1, expectInPrompt: "code reviews", note: "вы перебили на середине вопроса", split: true),
        Case(id: "uk-питання", lang: "uk-UA", segments: [Segment(text: "Як би ви налаштували моніторинг цього сервісу?")], expectRequests: 1, expectInPrompt: "моніторинг"),
    ]

    // MARK: Речь в файл

    /// Один голос → моно Float 16 кГц; обрезаны тишина в начале и конце (по энергии), чтобы границы речи были точные.
    private func synthesize(_ text: String, lang: String) async throws -> [Float] {
        guard let voice = AVSpeechSynthesisVoice(language: lang) else { throw XCTSkip("Нет голоса \(lang) для синтеза в файл") }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let synth = AVSpeechSynthesizer()
        final class Box: @unchecked Sendable { var samples: [Float] = []; var rate = 22_050.0; var finished = false }
        let box = Box()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    if !box.finished { box.finished = true; done.resume() }
                    return
                }
                box.rate = pcm.format.sampleRate
                let n = Int(pcm.frameLength)
                if let f = pcm.floatChannelData?[0] { box.samples += UnsafeBufferPointer(start: f, count: n) }
                else if let i = pcm.int16ChannelData?[0] { box.samples += (0..<n).map { Float(i[$0]) / 32768 } }
            }
        }
        withExtendedLifetime(synth) {}
        return Self.trimmed(Self.resample(box.samples, from: box.rate, to: Self.rate))
    }

    static let rate = 16_000.0

    private static func resample(_ s: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, !s.isEmpty else { return s }
        let n = Int(Double(s.count) * to / from)
        return (0..<n).map { i in
            let p = Double(i) * from / to
            let a = Int(p), b = min(a + 1, s.count - 1), f = Float(p - Double(a))
            return s[a] * (1 - f) + s[b] * f
        }
    }

    /// Речь = окна по 10 мс с энергией выше порога.
    private static func trimmed(_ s: [Float]) -> [Float] {
        let win = Int(rate / 100)
        func loud(_ i: Int) -> Bool {
            let end = min(i + win, s.count)
            guard i < end else { return false }
            let e = s[i..<end].reduce(0) { $0 + $1 * $1 } / Float(end - i)
            return e.squareRoot() > 0.01
        }
        guard let first = stride(from: 0, to: s.count, by: win).first(where: loud),
              let last = stride(from: s.count - 1, through: 0, by: -win).first(where: loud) else { return [] }
        return Array(s[first...min(last + win, s.count - 1)])
    }

    /// Две дорожки одной длины («собеседник» — звук звонка, «вы» — микрофон) и границы каждого куска речи.
    struct Timeline {
        var other: [Float] = [], mine: [Float] = []
        var spans: [(speaker: CopilotSpeaker, text: String, start: TimeInterval, end: TimeInterval)] = []
        var duration: TimeInterval { Double(other.count) / CopilotReplayTests.rate }
    }

    private func compose(_ c: Case) async throws -> Timeline {
        var t = Timeline()
        for seg in c.segments {
            let speech = try await synthesize(seg.text, lang: c.lang)
            let gap = [Float](repeating: 0, count: Int(seg.gapBefore * Self.rate))
            let start = Double(t.other.count + gap.count) / Self.rate
            let silence = [Float](repeating: 0, count: speech.count)
            if seg.speaker == .other { t.other += gap + speech; t.mine += gap + silence } else { t.mine += gap + speech; t.other += gap + silence }
            t.spans.append((seg.speaker, seg.text, start, start + Double(speech.count) / Self.rate))
        }
        // Хвост тишины после последней фразы: за ним финал расшифровки.
        let tail = [Float](repeating: 0, count: Int(3 * Self.rate))
        t.other += tail; t.mine += tail
        return t
    }

    private func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
                                                                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    // MARK: Заглушки

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSinceReferenceDate: 1_000_000) }

    final class Listener: CopilotListening {
        var started = 0, stopped = 0
        var onFailure: (@MainActor (String) -> Void)?
        var onActivity: (@MainActor () -> Void)?
        func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws { started += 1 }
        func stop() { stopped += 1 }
    }

    /// Провайдер-заглушка: ничего не запускает, пишет запросы и момент по часам теста.
    final class Provider: CopilotAIClient, @unchecked Sendable {
        struct Request { var at: Date; var prompt: String }
        private let lock = NSLock()
        private var _requests: [Request] = []
        let clock: Clock
        /// Ответ не заканчивается сам (идёт «долго»): проверяет, что замена вопроса отменяет прежний запрос.
        var hang = false
        private var _cancelled = 0
        var cancelled: Int { lock.lock(); defer { lock.unlock() }; return _cancelled }
        init(clock: Clock) { self.clock = clock }
        var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }
        func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
            lock.lock(); _requests.append(Request(at: clock.now, prompt: prompt)); lock.unlock()
            let hang = self.hang
            return AsyncThrowingStream { c in
                c.yield("SAY: ok\nPOINTS:\n- ok")
                if !hang { c.finish() }
                c.onTermination = { [weak self] reason in
                    if case .cancelled = reason, let self { self.lock.lock(); self._cancelled += 1; self.lock.unlock() }
                }
            }
        }
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() }; try? await Task.sleep(nanoseconds: 5_000_000) }

    // MARK: Прогон

    struct Outcome {
        var id: String, expected: Int, requests: Int
        /// Секунды от конца фразы с вопросом до запроса (первого и последнего), nil — запроса не было.
        var firstDelay: TimeInterval?, lastDelay: TimeInterval?
        var fullQuestion: Bool?, note: String
        var firstPrompt: String?, lastFull: Bool?
    }

    /// Настоящая расшифровка выдавала бы промежуточный текст раньше финала; здесь это сценарий: слово приходит через `lag`
    /// после того, как оно прозвучало (по доле знаков в куске речи), финал куска — через `finalDelay` после его конца.
    static let lag = 0.3, finalDelay = 2.0

    private func replay(_ c: Case, reactToPauses: Bool, timeline t: Timeline, turnedOn: Bool = true) async -> Outcome {
        let clock = Clock()
        let provider = Provider(clock: clock)
        let listener = Listener()
        var settings = CopilotSettings()
        settings.hybrid = false
        settings.reactToPauses = reactToPauses
        let session = CopilotSession(ai: provider, listener: listener, settings: { settings }, now: { clock.now }, log: { _ in })
        if turnedOn { session.start() }
        let origin = clock.now

        // Расшифровщики — настоящий класс приложения; текст из них собирается синхронно.
        final class Sink: @unchecked Sendable { let lock = NSLock(); var texts: [(String, SpeechSpan?)] = []
            func put(_ s: String, _ span: SpeechSpan?) { lock.lock(); texts.append((s, span)); lock.unlock() }
            func take() -> [(String, SpeechSpan?)] { lock.lock(); defer { lock.unlock() }; let r = texts; texts = []; return r } }
        let otherSink = Sink(), mineSink = Sink()
        let other = StreamingTranscriber(locale: Locale(identifier: c.lang), reactToPauses: reactToPauses) { otherSink.put($0, $1) }
        let mine = StreamingTranscriber(locale: Locale(identifier: c.lang), reactToPauses: reactToPauses) { mineSink.put($0, $1) }
        let activity: @Sendable () -> Void = { MainActor.assumeIsolated { listener.onActivity?() } }
        other.onActivity = activity
        mine.onActivity = activity

        // События распознавания.
        struct Event { var at: TimeInterval; var speaker: CopilotSpeaker; var text: String; var isFinal: Bool }
        var events: [Event] = []
        for s in t.spans {
            let words = s.text.split(separator: " ").map(String.init)
            let total = Double(s.text.count)
            var chars = 0.0
            var spoken: [String] = []
            for w in words {
                chars += Double(w.count + 1)
                spoken.append(w.filter { !",.?!".contains($0) })
                events.append(Event(at: s.start + (s.end - s.start) * min(chars / total, 1) + Self.lag, speaker: s.speaker,
                                    text: spoken.joined(separator: " "), isFinal: false))
            }
            // Финал куска приходит через `finalDelay`, но не позже начала следующей речи того же говорящего (новая речь закрывает прежний результат).
            let next = t.spans.first(where: { $0.speaker == s.speaker && $0.start > s.start })?.start
            events.append(Event(at: min(s.end + Self.finalDelay, (next ?? .infinity) - 0.05), speaker: s.speaker, text: s.text, isFinal: true))
        }
        events.sort { $0.at < $1.at }

        // Конец вопроса — конец последнего куска речи собеседника, содержащего слово из expectInPrompt (или просто последнего).
        let questionEnd: TimeInterval? = {
            if let key = c.expectInPrompt, let s = t.spans.last(where: { $0.speaker == .other && $0.text.localizedCaseInsensitiveContains(key.split(separator: " ").last.map(String.init) ?? key) }) { return s.end }
            return t.spans.last(where: { $0.speaker == .other })?.end
        }()

        var i = 0, step = 0
        let dt = 0.05
        var time = 0.0
        while time <= t.duration + Self.finalDelay + 1 {
            clock.now = origin.addingTimeInterval(time)
            while i < events.count, events[i].at <= time {
                let e = events[i]
                (e.speaker == .other ? other : mine).receive(e.text, isFinal: e.isFinal, at: clock.now)
                i += 1
            }
            if step % 3 == 0 { other.tick(at: clock.now); mine.tick(at: clock.now) }
            for (text, span) in otherSink.take() { session.feed(Utterance(.other, text, at: clock.now, spoke: span)); await settle() }
            for (text, span) in mineSink.take() { session.feed(Utterance(.me, text, at: clock.now, spoke: span)); await settle() }
            session.poll()
            await settle()
            time += dt; step += 1
        }
        await settle()
        let reqs = provider.requests
        let delays = reqs.compactMap { r in questionEnd.map { r.at.timeIntervalSince(origin) - $0 } }
        var full: Bool?
        var lastFull: Bool?
        if let key = c.expectInPrompt { full = reqs.first?.prompt.localizedCaseInsensitiveContains(key); lastFull = reqs.last?.prompt.localizedCaseInsensitiveContains(key) }
        session.stop()
        return Outcome(id: c.id, expected: c.expectRequests, requests: reqs.count, firstDelay: delays.first, lastDelay: delays.last,
                       fullQuestion: full, note: c.note, firstPrompt: reqs.first?.prompt, lastFull: lastFull)
    }

    // MARK: Тесты

    func testSynthesizedFilesAreRealSpeechAndStayOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for c in [Self.corpus[0], Self.corpus[5], Self.corpus[12]] {
            let t = try await compose(c)
            let url = dir.appendingPathComponent("\(c.id).wav")
            try write(t.other, to: url)
            let back = try read(url)
            XCTAssertEqual(Double(back.count) / Self.rate, t.duration, accuracy: 0.05, c.id)
            let peak = back.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.05, "в файле \(c.id) есть речь")
            let span = try XCTUnwrap(t.spans.first)
            XCTAssertGreaterThan(span.end - span.start, 1.0, "речь \(c.id) длится не меньше секунды")
            XCTAssertLessThan(span.end, t.duration - 2.5, "после речи остаётся тишина для финала")
        }
    }

    func testReplayTable() async throws {
        var rows: [String] = []
        var problems: [String] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for c in Self.corpus {
            let t = try await compose(c)
            try write(t.other, to: dir.appendingPathComponent("\(c.id).wav"))
            // Для расшифровщика берём то, что прочитано из файла (длительность и границы речи).
            for react in [true, false] {
                let o = await replay(c, reactToPauses: react, timeline: t)
                let d = { (x: TimeInterval?) in x.map { String(format: "%.2f", $0) } ?? "—" }
                // «Только финал» + пауза внутри вопроса: допускается обрывок и замена полным запросом (не больше двух запросов, последний полный).
                let relaxed = !react && c.split
                let ok = relaxed ? (o.requests >= 1 && o.requests <= 2 && (o.lastFull ?? true)) : (o.requests == o.expected && (o.fullQuestion ?? true))
                rows.append("| \(o.id) | \(react ? "с паузой 0,7 с" : "только финал") | \(o.expected) | \(o.requests) | \(d(o.firstDelay)) | \(d(o.lastDelay)) | \(o.fullQuestion.map { $0 ? "да" : "нет" } ?? "—") | \(o.lastFull.map { $0 ? "да" : "нет" } ?? "—") | \(ok ? "✓" : "✗") \(o.note) |")
                if !ok { problems.append("\(o.id) [\(react ? "пауза" : "финал")]: ожидали \(o.expected), было \(o.requests), вопрос целиком: \(o.fullQuestion.map { String($0) } ?? "—")") }
                if react, o.expected == 1, let f = o.firstDelay, f > 2.5 { problems.append("\(o.id): запрос через \(f) с") }
            }
        }
        let table = "| файл | режим | ждём запросов | запросов | задержка 1-го, с | задержка последнего, с | вопрос целиком в 1-м | в последнем | итог |\n|---|---|---|---|---|---|---|---|---|\n" + rows.joined(separator: "\n")
        print("COPILOT-REPLAY-TABLE\n" + table)
        if let path = ProcessInfo.processInfo.environment["MU_COPILOT_REPLAY_TABLE"] {
            try? (table + "\n\nПроблемы:\n" + problems.joined(separator: "\n")).write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Ручной режим: пока не нажали ⌥⇧M, ничего не слушается и в провайдер ничего не уходит, как бы ни звучали файлы.
    func testNothingIsListenedToOrSentWithoutTurningOn() async throws {
        for c in [Self.corpus[0], Self.corpus[5], Self.corpus[10]] {
            let t = try await compose(c)
            let o = await replay(c, reactToPauses: true, timeline: t, turnedOn: false)
            XCTAssertEqual(o.requests, 0, "\(c.id): выключенный подсказчик ничего не отправляет")
        }
        let clock = Clock()
        let provider = Provider(clock: clock)
        let listener = Listener()
        let session = CopilotSession(ai: provider, listener: listener, settings: { CopilotSettings() }, log: { _ in })
        XCTAssertEqual(listener.started, 0, "слушание не началось само")
        XCTAssertEqual(session.phase, .off)
        session.feed(Utterance(.other, "How would you design a rate limiter for this API?"))
        session.answerLast()
        await settle()
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(listener.started, 0)
        session.toggle()
        XCTAssertEqual(listener.started, 1, "слушание начинается только после ручного включения")
        session.toggle()
        XCTAssertEqual(listener.stopped, 1)
        // Приложение: состояние включения не хранится, значит после перезапуска подсказчик выключен.
        XCTAssertEqual(CopilotGlue.shared.session.phase, .off)
    }

    /// Настоящий SpeechAnalyzer по файлу, в темпе речи (без динамиков). Только если модель языка уже установлена:
    /// скачивание моделей меняет систему, тест его не запускает.
    func testRealSpeechAnalyzerReplay() async throws {
        let c = Self.corpus[5]
        guard await StreamingTranscriber.modelInstalled(for: Locale(identifier: c.lang)) else {
            throw XCTSkip("Модель расшифровки для \(c.lang) не установлена; тест её не скачивает")
        }
        let t = try await compose(c)
        final class Sink: @unchecked Sendable { let lock = NSLock(); var items: [(Date, String)] = []
            func put(_ s: String) { lock.lock(); items.append((Date(), s)); lock.unlock() } }
        let sink = Sink()
        let transcriber = StreamingTranscriber(locale: Locale(identifier: c.lang), reactToPauses: true) { text, _ in sink.put(text) }
        try await transcriber.start()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false)!
        let chunk = Int(Self.rate / 10)
        let begin = Date()
        var pos = 0
        while pos < t.other.count {
            let n = min(chunk, t.other.count - pos)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            t.other.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + pos, count: n) }
            transcriber.append(buffer)
            pos += n
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        transcriber.finish()
        let heard = sink.items.map(\.1).joined(separator: " ")
        let end = t.spans.last!.end
        let first = sink.items.first.map { $0.0.timeIntervalSince(begin) - end }
        print("REAL-ANALYZER heard=\(heard) firstTextAfterSpeechEnd=\(first.map { String($0) } ?? "—")")
        XCTAssertTrue(QuestionDetector.isQuestion(heard), "настоящая расшифровка: «\(heard)» распознана как вопрос")
    }
}


/// Правила ожидания продолжения вопроса: время речи, вторая пауза, замена ответа.
@MainActor
final class CopilotHoldTests: XCTestCase {
    private let clock = CopilotReplayTests.Clock()
    private func t(_ s: Double) -> Date { Date(timeIntervalSinceReferenceDate: 1_000_000 + s) }
    private func span(_ a: Double, _ b: Double) -> SpeechSpan { SpeechSpan(start: t(a), end: t(b)) }
    private func settle() async { for _ in 0..<30 { await Task.yield() }; try? await Task.sleep(nanoseconds: 5_000_000) }

    private func make(hang: Bool = false) -> (CopilotSession, CopilotReplayTests.Provider) {
        let p = CopilotReplayTests.Provider(clock: clock)
        p.hang = hang
        var settings = CopilotSettings(); settings.hybrid = false
        let s = CopilotSession(ai: p, listener: CopilotReplayTests.Listener(), settings: { settings }, now: { [clock] in clock.now }, log: { _ in })
        s.start()
        return (s, p)
    }

    private func say(_ s: CopilotSession, _ text: String, at arrival: Double, spoke: SpeechSpan, speaker: CopilotSpeaker = .other) async {
        clock.now = t(arrival)
        s.feed(Utterance(speaker, text, at: t(arrival), spoke: spoke))
        await settle()
    }

    func testIncompleteFragments() {
        for text in ["What would you do", "Расскажите про ваш опыт", "How do you usually", "Как бы вы организовали кэширование в", "Why Kafka"] {
            XCTAssertTrue(QuestionDetector.isIncomplete(text), text)
        }
        for text in ["How would you design a rate limiter for this API", "Как бы вы организовали кэширование в этом сервисе", "What would you do?", "Расскажите про ваш опыт."] {
            XCTAssertFalse(QuestionDetector.isIncomplete(text), text)
        }
    }

    func testCompleteQuestionGoesImmediately() async {
        let (s, p) = make()
        await say(s, "How would you design a rate limiter for this API", at: 5, spoke: span(1, 4.3))
        XCTAssertEqual(p.requests.count, 1, "простой вопрос не ждёт")
    }

    func testFragmentWaitsAndContinuationGivesOneFullRequest() async {
        let (s, p) = make()
        await say(s, "What would you do", at: 3, spoke: span(1, 2.3))
        XCTAssertTrue(p.requests.isEmpty, "обрывок ждёт продолжения")
        // Идёт речь: ожидание продлевается и после 1,5 с с прихода обрывка.
        clock.now = t(4.4); s.speechActivity(); s.poll(); await settle()
        XCTAssertTrue(p.requests.isEmpty, "пока говорят, не отправляем")
        // Продолжение звучало через 1,4 с после конца обрывка, пришло намного позже 1,5 с после прихода обрывка.
        await say(s, "if the production database goes down", at: 6.5, spoke: span(3.7, 5.5))
        XCTAssertEqual(p.requests.count, 1)
        XCTAssertTrue(p.requests[0].prompt.contains("What would you do if the production database goes down"))
    }

    func testFragmentIsSentAfterSecondPauseAndThenReplaced() async {
        let (s, p) = make(hang: true)
        await say(s, "Расскажите про ваш опыт", at: 3, spoke: span(1, 2.3))
        clock.now = t(4.4); s.poll(); await settle()
        XCTAssertTrue(p.requests.isEmpty, "1,4 с с прихода — ещё ждём")
        clock.now = t(4.6); s.poll(); await settle()
        XCTAssertEqual(p.requests.count, 1, "вторая пауза прошла — уходит обрывок")
        await say(s, "особенно с базами данных", at: 7, spoke: span(3.9, 5.8))
        XCTAssertEqual(p.requests.count, 2, "вопрос дополнился — запрос заменён")
        XCTAssertEqual(p.cancelled, 1, "прежний запрос отменён, второго мигающего ответа нет")
        XCTAssertTrue(p.requests[1].prompt.contains("Расскажите про ваш опыт особенно с базами данных"))
        XCTAssertEqual(s.question, "Расскажите про ваш опыт особенно с базами данных")
    }

    func testWindowIsSpeechTimeNotArrivalTime() {
        let a = Utterance(.other, "What would you do", at: t(3), spoke: span(1, 2.3))
        let late = Utterance(.other, "if it fails", at: t(60), spoke: span(3.6, 4.5))
        XCTAssertTrue(UtteranceMerge.continues(a, with: late), "пауза в речи 1,3 с — продолжение, сколько бы ни шла расшифровка")
        let far = Utterance(.other, "if it fails", at: t(6), spoke: span(5, 6))
        XCTAssertFalse(UtteranceMerge.continues(a, with: far), "пауза 2,7 с — уже новая фраза")
    }

    func testYourInterjectionDoesNotCancelTheQuestion() async {
        let (s, p) = make()
        await say(s, "How do you usually", at: 3, spoke: span(1, 2.2))
        await say(s, "Sorry, one second, let me share my screen first", at: 6, spoke: span(3, 5.5), speaker: .me)
        XCTAssertTrue(p.requests.isEmpty)
        await say(s, "handle code reviews in your team", at: 9, spoke: span(6.5, 8))
        XCTAssertEqual(p.requests.count, 1)
        XCTAssertTrue(p.requests[0].prompt.contains("How do you usually handle code reviews in your team"))
    }

    func testAnsweredCompleteQuestionIsNotExtendedByTheNextSentence() async {
        let (s, p) = make()
        await say(s, "Tell me about your experience with distributed systems", at: 4, spoke: span(1, 3.2))
        await say(s, "Thanks, that is clear", at: 6, spoke: span(4, 5.2))
        XCTAssertEqual(p.requests.count, 1, "следующая фраза — не продолжение вопроса, на который уже ответили")
    }

    func testStopDropsTheWait() async {
        let (s, p) = make()
        await say(s, "What would you do", at: 3, spoke: span(1, 2.3))
        s.stop()
        clock.now = t(10); s.poll(); await settle()
        XCTAssertTrue(p.requests.isEmpty)
    }
}
