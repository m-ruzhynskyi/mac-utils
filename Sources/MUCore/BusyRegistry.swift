import Carbon.HIToolbox
import Foundation

/// Реестр «приложение занято»: пока что-то идёт, автообновление не перезапускает приложение,
/// а выход (⌘Q, выход из системы) просит подтверждения и сначала корректно завершает запись.
///
/// Занятость берётся двумя способами:
/// - `begin`/`end` — счётчик по причине (для кода, у которого нет читаемого состояния);
/// - `setProvider` — функция, которая сама отвечает «идёт ли это сейчас» по уже существующему состоянию
///   (`ScreenRecorder.current`, `MeetingRecorder.state` и т. п.), поэтому в самих функциях ничего менять не нужно
///   и «забытый end» не может навсегда заблокировать обновление.
@MainActor
package final class BusyRegistry {
    package static let shared = BusyRegistry()

    package enum Reason: String, CaseIterable, Equatable {
        case screenRecording, meetingRecording, meetingProcessing, broadcast, viewing, scrollCapture, steps, uninstalling, screenshotSaving

        /// Родительный падеж после «идёт»: «идёт запись экрана».
        package var title: String {
            switch self {
            case .screenRecording: return "запись экрана"
            case .meetingRecording: return "запись встречи"
            case .meetingProcessing: return "обработка записи встречи"
            case .broadcast: return "трансляция экрана"
            case .viewing: return "просмотр чужой трансляции"
            case .scrollCapture: return "длинный снимок"
            case .steps: return "сбор шагов для коллажа"
            case .uninstalling: return "удаление программ"
            case .screenshotSaving: return "сохранение снимка"
            }
        }

        /// Можно ли завершить это штатно перед выходом (сохранить запись, закрыть эфир), а не просто потерять.
        package var canWindDown: Bool { self != .uninstalling && self != .meetingProcessing }
    }

    private var counts: [Reason: Int] = [:]
    private var providers: [Reason: () -> Bool] = [:]

    package init() {}

    package func begin(_ reason: Reason) { counts[reason, default: 0] += 1 }

    package func end(_ reason: Reason) {
        guard let count = counts[reason] else { return }
        if count <= 1 { counts[reason] = nil } else { counts[reason] = count - 1 }
    }

    package func setProvider(_ reason: Reason, _ isActive: @escaping () -> Bool) { providers[reason] = isActive }

    package func isActive(_ reason: Reason) -> Bool {
        (counts[reason] ?? 0) > 0 || providers[reason]?() == true
    }

    /// Что идёт сейчас, в порядке объявления причин.
    package var active: [Reason] { Reason.allCases.filter(isActive) }
    package var isBusy: Bool { Reason.allCases.contains(where: isActive) }

    // MARK: - Тексты и решение при выходе (чистая логика)

    /// «запись экрана», «запись экрана и трансляция экрана», «a, b и c».
    package static func list(_ reasons: [Reason]) -> String {
        let names = reasons.map(\.title)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " и " + names[names.count - 1]
        }
    }

    package struct QuitPrompt: Equatable {
        package let title: String
        package let message: String
        package let confirm: String
        package let cancel = "Не выходить"
    }

    /// nil — спрашивать нечего, можно выходить.
    package static func quitPrompt(for reasons: [Reason]) -> QuitPrompt? {
        guard !reasons.isEmpty else { return nil }
        let windDown = reasons.filter(\.canWindDown)
        let lost = reasons.filter { !$0.canWindDown }
        var lines: [String] = []
        if !windDown.isEmpty {
            lines.append("Если выйти сейчас, всё идущее будет остановлено: запись сохранится, трансляция завершится у зрителей.")
        }
        if lost.contains(.uninstalling) { lines.append("Удаление программ прервётся на середине.") }
        if lost.contains(.meetingProcessing) { lines.append("Расшифровка и отчёт по встрече не будут готовы.") }
        return QuitPrompt(title: "Сейчас идёт: \(list(reasons))",
                          message: lines.joined(separator: "\n"),
                          confirm: windDown.isEmpty ? "Выйти" : "Остановить и выйти")
    }

    /// Какие причины нужно завершить штатно перед выходом, в порядке выполнения.
    package static func windDownOrder(_ reasons: [Reason]) -> [Reason] {
        // Сначала то, что отдаёт данные пользователю, потом эфир и просмотр.
        let order: [Reason] = [.screenshotSaving, .screenRecording, .meetingRecording, .scrollCapture, .steps, .broadcast, .viewing]
        return order.filter { reasons.contains($0) }
    }

    /// Сессия шагов без новых шагов дольше этого срока занятостью не считается (забытый коллаж не блокирует обновления).
    package nonisolated static let stepsIdleLimit: TimeInterval = 3600

    package nonisolated static func isFresh(_ lastActivity: Date, now: Date = Date(), limit: TimeInterval = stepsIdleLimit) -> Bool {
        now.timeIntervalSince(lastActivity) < limit
    }

    /// Выход подтверждён заранее (например, пользователь согласился на перезапуск ради обновления): окно не показываем.
    package var terminationConfirmed = false

    package enum TerminationPlan: Equatable {
        case now
        /// Остановить идущее и выйти без вопросов (выключение, перезагрузка, выход из системы, подтверждённый перезапуск).
        case windDownSilently
        case ask(QuitPrompt)
    }

    /// Что делать на запрос выхода. Выключение и выход из системы окном не блокируются: человека может не быть рядом.
    package static func terminationPlan(reasons: [Reason], systemShutdown: Bool, confirmed: Bool) -> TerminationPlan {
        guard let prompt = quitPrompt(for: reasons) else { return .now }
        return systemShutdown || confirmed ? .windDownSilently : .ask(prompt)
    }

    /// Сколько раз по 250 мс ждать завершения причины. Запись экрана в GIF собирается долго; при выключении ждать нельзя.
    package static func waitAttempts(for reason: Reason, silent: Bool) -> Int {
        if silent { return 20 }
        return reason == .screenRecording ? 600 : 80
    }

    /// Общий предел ожидания при системном завершении, секунды.
    package static let systemShutdownLimit: TimeInterval = 10

    /// Автоматические действия (установка обновления) откладываются, пока что-то идёт.
    package static func shouldDefer(_ reasons: [Reason]) -> Bool { !reasons.isEmpty }
}


/// Причина запроса выхода из самого события «quit» (вторая проверка рядом с уведомлением о выключении: порядок
/// уведомлений не гарантирован, а при `shutdown`/MDM или перезапуске после обновления macOS его может не быть).
package enum QuitReason {
    /// Коды выключения, перезагрузки и выхода из системы (`kAEQuitReason`).
    package static let systemCodes: Set<OSType> = [
        OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog), OSType(kAERestart),
        OSType(kAEShowShutdownDialog), OSType(kAEShutDown),
    ]

    /// nil — причины в событии нет (⌘Q, «Выйти» из меню присылают обычный `quit`).
    package static func isSystemShutdown(_ code: OSType?) -> Bool {
        guard let code else { return false }
        return systemCodes.contains(code)
    }
}

/// Флаг «система выключается». Не вечный: если выключение отменили, следующий ⌘Q снова спросит.
package struct SystemShutdownFlag {
    package static let lifetime: TimeInterval = 120
    private var since: Date?

    package init() {}

    package mutating func note(at now: Date = Date()) { since = now }
    package mutating func clear() { since = nil }

    package func isActive(at now: Date = Date()) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) < Self.lifetime
    }
}
