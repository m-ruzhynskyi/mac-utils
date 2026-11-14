import Foundation
import MUCore

/// ИИ для подсказчика. Настоящий бэкенд (`MUAIBackend`: Codex / Claude) подключает приложение; тут — граница, чтобы
/// модуль не зависел от него и проверялся на заглушке.
package protocol CopilotAIClient: Sendable {
    /// Куски текста ответа по мере поступления. Отмена задачи должна останавливать процесс ИИ.
    /// `profile`: `.fast` — быстрая модель с малым «размышлением» (первая строка), `.main` — основная.
    func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error>
    /// Заранее запустить процесс ИИ (при включении подсказчика), чтобы первый вопрос не ждал запуска.
    func warmUp(system: String) async
    /// Остановить тёплые процессы (при выключении подсказчика).
    func shutdown() async
}

extension CopilotAIClient {
    package func warmUp(system: String) async {}
    package func shutdown() async {}
}

package enum CopilotAIProfile: String, Equatable, Sendable { case main, fast }

/// Источник звука и расшифровки (собеседники — звук программы звонка, вы — микрофон). Запускается только вручную.
@MainActor
package protocol CopilotListening: AnyObject {
    /// Начать слушать; реплики приходят в `onUtterance`.
    func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws
    /// Остановить и освободить микрофон и звук.
    func stop()
    /// Источник сам остановился (обрыв потока, нет доступа, нет языковой модели): подсказчик выключается и показывает причину.
    var onFailure: (@MainActor (String) -> Void)? { get set }
    /// Кто-то говорит (текст расшифровки изменился): пока говорят, незаконченный вопрос ждёт продолжения.
    var onActivity: (@MainActor () -> Void)? { get set }
}

extension CopilotListening {
    package var onActivity: (@MainActor () -> Void)? { get { nil } set {} }
}

/// Измеряет задержку «конец вопроса → первая строка ответа».
package struct LatencyMeter: Equatable {
    /// Цель: от конца вопроса до первой строки (без учёта расшифровки).
    package static let target: TimeInterval = 2.5
    package private(set) var questionAt: Date?
    package private(set) var firstLineAt: Date?
    package private(set) var lineCompleteAt: Date?

    package init() {}

    package mutating func questionEnded(at date: Date) { questionAt = date; firstLineAt = nil; lineCompleteAt = nil }
    package mutating func firstLine(at date: Date) { if firstLineAt == nil { firstLineAt = date } }
    /// Первая строка пришла целиком (за ней перевод строки или конец ответа).
    package mutating func lineComplete(at date: Date) { if lineCompleteAt == nil { lineCompleteAt = date } }
    package var lineCompleteSeconds: TimeInterval? {
        guard let q = questionAt, let f = lineCompleteAt else { return nil }
        return f.timeIntervalSince(q)
    }
    package var seconds: TimeInterval? {
        guard let q = questionAt, let f = firstLineAt else { return nil }
        return f.timeIntervalSince(q)
    }
    package var withinTarget: Bool { (seconds ?? .infinity) <= Self.target }
}

@MainActor
package final class CopilotSession: ObservableObject {
    package enum Phase: Equatable { case off, listening }

    @Published package private(set) var phase: Phase = .off
    @Published package private(set) var transcript: [Utterance] = []
    @Published package private(set) var question: String?
    @Published package private(set) var answer: CopilotAnswer = .empty
    @Published package private(set) var isAnswering = false
    @Published package private(set) var lastLatency: TimeInterval?
    @Published package private(set) var error: String?
    /// Когда панель раскрылась (для автосворачивания через 20 с).
    @Published package private(set) var expandedAt: Date?

    private let ai: CopilotAIClient
    private let listener: CopilotListening
    private let settings: () -> CopilotSettings
    private let now: () -> Date
    private let log: (String) -> Void
    /// Замер «конец вопроса → первая строка» для статистики по сервисам (приложение пишет её и даёт совет).
    private let onLatency: (TimeInterval) -> Void
    private var task: Task<Void, Never>?
    /// Прогрев и остановка тёплых процессов — строго по очереди: иначе быстрое «вкл → выкл» могло прогреть процесс
    /// уже после остановки, и он жил бы при выключенном подсказчике.
    private var lifecycle: Task<Void, Never>?
    private var meter = LatencyMeter()
    private var answeredQuestionID: UUID?
    /// Вопрос без «?» и законченной мысли ждёт вторую паузу: если за это время пришло продолжение, уйдёт один запрос с полным вопросом.
    package static let holdSeconds: TimeInterval = 1.5
    private var hold: (id: UUID, deadline: Date)?
    private var holdTimer: Task<Void, Never>?

    package init(ai: CopilotAIClient, listener: CopilotListening, settings: @escaping () -> CopilotSettings = { CopilotPrefs.load() },
                 now: @escaping () -> Date = Date.init, log: @escaping (String) -> Void = { Log.ai.info("\($0, privacy: .public)") },
                 onLatency: @escaping (TimeInterval) -> Void = { _ in }) {
        self.onLatency = onLatency
        self.ai = ai
        self.listener = listener
        self.settings = settings
        self.now = now
        self.log = log
    }

    package var isOn: Bool { phase == .listening }

    // MARK: Включение — только вручную (⌥⇧M или меню Mac Utils)

    package func toggle() { isOn ? stop() : start() }

    package func start() {
        guard !isOn else { return }
        do {
            listener.onFailure = { [weak self] message in
                guard let self else { return }
                self.stop()
                self.error = message
            }
            listener.onActivity = { [weak self] in self?.speechActivity() }
            try listener.start(language: settings().meetingLanguage, reactToPauses: settings().reactToPauses) { [weak self] in self?.feed($0) }
            phase = .listening
            error = nil
            let ai = self.ai, system = CopilotPrompt.system(settings: settings()), previous = lifecycle
            lifecycle = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                await ai.warmUp(system: system)
            }
            log("Подсказчик: включён вручную")
        } catch {
            self.error = "Не удалось начать слушать: \(error.localizedDescription)"
            log("Подсказчик: не включился — \(error.localizedDescription)")
        }
    }

    /// Выключает: микрофон и звук звонка освобождаются, расшифровка и ответы стираются.
    package func stop() {
        guard isOn || task != nil else { return }
        task?.cancel()
        task = nil
        hold = nil
        holdTimer?.cancel()
        holdTimer = nil
        listener.stop()
        // Незаконченный прогрев отменяется, остановка идёт после него.
        let ai = self.ai, previous = lifecycle
        previous?.cancel()
        lifecycle = Task {
            await previous?.value
            await ai.shutdown()
        }
        phase = .off
        transcript = []
        question = nil
        answer = .empty
        isAnswering = false
        expandedAt = nil
        answeredQuestionID = nil
        log("Подсказчик: выключен")
    }

    // MARK: Расшифровка

    package func feed(_ utterance: Utterance) {
        guard isOn else { return }
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let incoming = Utterance(utterance.speaker, text, at: utterance.at, spoke: utterance.spoke)
        merge(incoming)
        let cutoff = now().addingTimeInterval(-CopilotPrompt.contextSeconds * 2)
        transcript.removeAll { $0.at < cutoff }
        guard settings().autoAnswer else { return }
        if utterance.speaker == .me { speechActivity(); return }
        guard let q = QuestionDetector.pendingQuestion(in: transcript), q.id != answeredQuestionID else { return }
        if QuestionDetector.isIncomplete(q.text) {
            // Обрывок: ждём продолжение. Если пришло и вопрос дополнился, а ответ на обрывок уже шёл, `ask` его заменит.
            hold = (q.id, now().addingTimeInterval(Self.holdSeconds))
            startHoldTimer()
            return
        }
        hold = nil
        ask(.lastQuestion, questionUtterance: q)
    }

    /// Склеивает куски одной реплики (по времени речи, а не прихода). Ваша реплика посреди вопроса не мешает:
    /// вопрос собеседника дополняется и встаёт после неё, чтобы «вы уже ответили» не отменило его.
    private func merge(_ incoming: Utterance) {
        var index = transcript.count - 1
        var aside: Date?
        if incoming.speaker == .other {
            while index >= 0, transcript[index].speaker == .me { aside = max(aside ?? .distantPast, transcript[index].ended); index -= 1 }
        }
        // Вопрос, на который уже ответили и который выглядит законченным, не дополняется: следующая фраза — новая.
        let extendable = index >= 0 && (transcript[index].id != answeredQuestionID || QuestionDetector.isIncomplete(transcript[index].text))
            && (aside == nil || QuestionDetector.isIncomplete(transcript[index].text))
        if extendable, UtteranceMerge.continues(transcript[index], with: incoming, spokeUntil: aside) {
            let last = transcript[index]
            let text = last.text + " " + incoming.text
            let span = SpeechSpan(start: last.started, end: max(incoming.ended, last.ended))
            let merged = Utterance(last.speaker, text, at: incoming.at, spoke: span)
            // Если на прежний вопрос уже ответили, дополненный — новый вопрос (новый номер).
            let result = last.id == answeredQuestionID ? merged : Utterance(id: last.id, merged)
            transcript.remove(at: index)
            transcript.append(result)
        } else {
            transcript.append(incoming)
        }
    }

    /// Пока кто-то говорит, ожидание продолжения вопроса продлевается.
    package func speechActivity() {
        guard hold != nil else { return }
        hold?.deadline = now().addingTimeInterval(Self.holdSeconds)
    }

    /// Вторая пауза прошла, продолжения нет: уходит то, что есть. Зовёт таймер; в проверках — время вручную.
    package func poll() {
        guard isOn, let h = hold, now() >= h.deadline else { return }
        hold = nil
        guard settings().autoAnswer, let q = QuestionDetector.pendingQuestion(in: transcript), q.id == h.id, q.id != answeredQuestionID else { return }
        ask(.lastQuestion, questionUtterance: q)
    }

    private func startHoldTimer() {
        guard holdTimer == nil else { return }
        holdTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled else { return }
                self.poll()
                if self.hold == nil { self.holdTimer = nil; return }
            }
        }
    }

    // MARK: Запросы

    package func answerLast() { ask(.lastQuestion, questionUtterance: QuestionDetector.pendingQuestion(in: transcript)) }
    package func shorter() { ask(.shorter, questionUtterance: nil) }
    package func ask(custom text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        question = t
        ask(.custom(t), questionUtterance: nil)
    }
    /// ⌥⇧S: снимок экрана делает приложение и передаёт сюда.
    package func lookAtScreen(image: Data) { ask(.screen, questionUtterance: nil, images: [image]) }

    private func ask(_ mode: CopilotPrompt.Mode, questionUtterance: Utterance?, images: [Data] = []) {
        guard isOn else { return }
        task?.cancel()
        if let q = questionUtterance { question = q.text; answeredQuestionID = q.id }
        let started = now()
        meter.questionEnded(at: questionUtterance?.at ?? started)
        let settings = settings()
        let prompt = CopilotPrompt.user(settings: settings, utterances: transcript, now: started, mode: mode,
                                        previous: mode == .shorter ? answer : nil)
        let previousAnswer = answer
        isAnswering = true
        error = nil
        if mode != .shorter { answer = .empty }
        hybrid = HybridAnswer()
        let ai = self.ai
        // Гибрид: фраза — быстрой моделью, пункты — основной, одновременно. Со снимком экрана и «Короче» — один запрос.
        let hybrid = settings.hybrid && images.isEmpty && mode != .shorter
        let profile: CopilotAIProfile = settings.fastModels ? .fast : .main
        task = Task { [weak self] in
            do {
                if hybrid {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for (part, leg) in [(CopilotPrompt.Part.sayOnly, CopilotAIProfile.fast), (.pointsOnly, .main)] {
                            let stream = ai.stream(prompt: prompt, system: CopilotPrompt.system(settings: settings, part: part), images: [], profile: leg)
                            group.addTask { [weak self] in
                                for try await piece in stream {
                                    try Task.checkCancellation()
                                    await self?.hybridPiece(part: part, piece: piece)
                                }
                                await self?.hybridDone(part: part)
                            }
                        }
                        try await group.waitForAll()
                    }
                    if let self { self.finish(parsed: self.hybrid.parsed, previous: previousAnswer) }
                } else {
                    var raw = ""
                    let stream = ai.stream(prompt: prompt, system: CopilotPrompt.system(settings: settings), images: images, profile: profile)
                    for try await chunk in stream {
                        guard let self, !Task.isCancelled else { return }
                        raw += chunk
                        self.apply(CopilotPrompt.parse(raw))
                    }
                    self?.finish(parsed: CopilotPrompt.parse(raw), previous: previousAnswer)
                }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isAnswering = false
                self.error = error.localizedDescription
                self.log("Подсказчик: ошибка ИИ — \(error.localizedDescription)")
            }
        }
    }

    // Гибрид: две половины приходят в разном порядке; общее состояние держит главный поток.
    private var hybrid = HybridAnswer()

    private func hybridPiece(part: CopilotPrompt.Part, piece: String) {
        if part == .sayOnly { hybrid.appendSay(piece) } else { hybrid.appendPoints(piece) }
        if case .noQuestion = hybrid.parsed { return }
        apply(hybrid.parsed)
    }

    private func hybridDone(part: CopilotPrompt.Part) {
        if part == .sayOnly { hybrid.finishSay() } else { hybrid.finishPoints() }
        apply(hybrid.parsed)
    }

    private func apply(_ parsed: CopilotPrompt.Parsed) {
        switch parsed {
        case .noQuestion: break
        case .answer(let a):
            if !a.say.isEmpty {
                meter.firstLine(at: now())
                if expandedAt == nil { expandedAt = now() }
            }
            if a.sayComplete { meter.lineComplete(at: now()) }
            // Слишком длинную первую строку (модель не послушалась) обрезаем для показа: её надо успеть сказать вслух.
            var shown = a
            shown.say = CopilotPrompt.trimSay(a.say)
            answer = shown
        }
    }

    private func finish(parsed: CopilotPrompt.Parsed, previous: CopilotAnswer) {
        isAnswering = false
        if case .noQuestion = parsed {
            answer = previous.isEmpty ? .empty : previous
            question = nil
            expandedAt = nil
            log("Подсказчик: модель не нашла вопроса")
            return
        }
        // Ответ пришёл одним куском: строка закончилась вместе с ответом.
        if case .answer(let a) = parsed, !a.say.isEmpty { meter.lineComplete(at: now()) }
        if let s = meter.seconds {
            lastLatency = s
            onLatency(meter.lineCompleteSeconds ?? s)
            let complete = meter.lineCompleteSeconds.map { String(format: ", первая строка целиком через %.1f с", $0) } ?? ""
            log(String(format: "Подсказчик: первый кусок через %.1f с%@%@", s, complete, meter.withinTarget ? "" : " (дольше цели 2,5 с)"))
        }
        expandedAt = now()
    }

    /// Esc или 20 секунд: панель сворачивается в полоску.
    package func collapse() { expandedAt = nil }
}

/// Правила панели без обращения к системе.
package enum CopilotPanelRules {
    package static let collapseSeconds: TimeInterval = 20

    package static func shouldCollapse(expandedAt: Date?, now: Date, isAnswering: Bool, holdingOption: Bool) -> Bool {
        guard let expandedAt, !isAnswering, !holdingOption else { return false }
        return now.timeIntervalSince(expandedAt) >= collapseSeconds
    }

    /// Мышь проходит сквозь панель, пока не держат ⌥.
    package static func ignoresMouse(optionHeld: Bool) -> Bool { !optionHeld }

    /// Размер и место панели. `screen` — видимая область экрана, `camera` — высота выреза/камеры сверху.
    package static func frame(placement: CopilotPlacement, expanded: Bool, in screen: CGRect, notchHeight: CGFloat = 0) -> CGRect {
        switch placement {
        case .underCamera, .secondScreen:
            let w = min(560, screen.width - 40)
            let h: CGFloat = expanded ? 128 : 26
            return CGRect(x: screen.midX - w / 2, y: screen.maxY - notchHeight - h, width: w, height: h)
        case .side:
            let w: CGFloat = 300
            let h: CGFloat = expanded ? min(420, screen.height - 80) : 40
            return CGRect(x: screen.maxX - w - 12, y: screen.maxY - h - 60, width: w, height: h)
        }
    }
}
