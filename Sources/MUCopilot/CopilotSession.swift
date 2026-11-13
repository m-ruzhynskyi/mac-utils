import Foundation
import MUCore

/// ИИ для подсказчика. Настоящий бэкенд (`MUAIBackend`: Codex / Claude) подключает приложение; тут — граница, чтобы
/// модуль не зависел от него и проверялся на заглушке.
package protocol CopilotAIClient: Sendable {
    /// Куски текста ответа по мере поступления. Отмена задачи должна останавливать процесс ИИ.
    func stream(prompt: String, system: String, images: [Data]) -> AsyncThrowingStream<String, Error>
}

/// Источник звука и расшифровки (собеседники — звук программы звонка, вы — микрофон). Запускается только вручную.
@MainActor
package protocol CopilotListening: AnyObject {
    /// Начать слушать; реплики приходят в `onUtterance`.
    func start(language: String?, onUtterance: @escaping @MainActor (Utterance) -> Void) throws
    /// Остановить и освободить микрофон и звук.
    func stop()
    /// Источник сам остановился (обрыв потока, нет доступа, нет языковой модели): подсказчик выключается и показывает причину.
    var onFailure: (@MainActor (String) -> Void)? { get set }
}

/// Измеряет задержку «конец вопроса → первая строка ответа».
package struct LatencyMeter: Equatable {
    package static let target: TimeInterval = 4
    package private(set) var questionAt: Date?
    package private(set) var firstLineAt: Date?

    package init() {}

    package mutating func questionEnded(at date: Date) { questionAt = date; firstLineAt = nil }
    package mutating func firstLine(at date: Date) { if firstLineAt == nil { firstLineAt = date } }
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
    private var task: Task<Void, Never>?
    private var meter = LatencyMeter()
    private var answeredQuestionID: UUID?

    package init(ai: CopilotAIClient, listener: CopilotListening, settings: @escaping () -> CopilotSettings = { CopilotPrefs.load() },
                 now: @escaping () -> Date = Date.init, log: @escaping (String) -> Void = { Log.ai.info("\($0, privacy: .public)") }) {
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
            try listener.start(language: settings().meetingLanguage) { [weak self] in self?.feed($0) }
            phase = .listening
            error = nil
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
        listener.stop()
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
        let incoming = Utterance(utterance.speaker, text, at: utterance.at)
        if let last = transcript.last, UtteranceMerge.continues(last, with: incoming) {
            // Склеиваем куски одной реплики; если на прежний вопрос уже ответили, это новый вопрос.
            let merged = Utterance(last.speaker, last.text + " " + text, at: incoming.at)
            transcript[transcript.count - 1] = last.id == answeredQuestionID ? merged : Utterance(id: last.id, merged)
        } else {
            transcript.append(incoming)
        }
        let cutoff = now().addingTimeInterval(-CopilotPrompt.contextSeconds * 2)
        transcript.removeAll { $0.at < cutoff }
        guard settings().autoAnswer, utterance.speaker == .other,
              let q = QuestionDetector.pendingQuestion(in: transcript), q.id != answeredQuestionID else { return }
        ask(.lastQuestion, questionUtterance: q)
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
        let system = CopilotPrompt.system(settings: settings)
        let prompt = CopilotPrompt.user(settings: settings, utterances: transcript, now: started, mode: mode,
                                        previous: mode == .shorter ? answer : nil)
        let previousAnswer = answer
        isAnswering = true
        error = nil
        if mode != .shorter { answer = .empty }
        let stream = ai.stream(prompt: prompt, system: system, images: images)
        task = Task { [weak self] in
            var raw = ""
            do {
                for try await chunk in stream {
                    guard let self, !Task.isCancelled else { return }
                    raw += chunk
                    self.apply(CopilotPrompt.parse(raw))
                }
                self?.finish(raw: raw, previous: previousAnswer)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isAnswering = false
                self.error = error.localizedDescription
                self.log("Подсказчик: ошибка ИИ — \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ parsed: CopilotPrompt.Parsed) {
        switch parsed {
        case .noQuestion: break
        case .answer(let a):
            if !a.say.isEmpty {
                meter.firstLine(at: now())
                if expandedAt == nil { expandedAt = now() }
            }
            answer = a
        }
    }

    private func finish(raw: String, previous: CopilotAnswer) {
        isAnswering = false
        if case .noQuestion = CopilotPrompt.parse(raw) {
            answer = previous.isEmpty ? .empty : previous
            question = nil
            expandedAt = nil
            log("Подсказчик: модель не нашла вопроса")
            return
        }
        if let s = meter.seconds {
            lastLatency = s
            log(String(format: "Подсказчик: первая строка через %.1f с%@", s, meter.withinTarget ? "" : " (дольше цели 4 с)"))
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
