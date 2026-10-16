import CoreMedia
import Foundation

// Надёжность трансляции без UI и сети (для тестов): отмена и таймаут подключения ведущего (SH3),
// пауза кодера без зрителей (SH4), переподключение зрителя (SH5).

/// Поколения попыток подключения ведущего. «Отмена», «Стоп» и таймаут начинают новое поколение:
/// запоздавший результат старой попытки (рукопожатие, начало захвата) отбрасывается, а не делает трансляцию живой.
struct ShareAttempts {
    private(set) var current = 0
    /// Сокет, который сейчас проходит рукопожатие, и как его закрыть. Без этого отменённый сокет дошёл бы до `auth`
    /// позже следующей попытки, и relay выбил бы свежую трансляцию того же ключа (`replaced`).
    private var pending: (socket: ObjectIdentifier, close: () -> Void)?

    mutating func begin() -> Int {
        current += 1
        return current
    }

    /// Текущая попытка больше не нужна: её сокет, если рукопожатие ещё идёт, закрывается сразу.
    mutating func cancel() {
        current += 1
        let close = pending?.close
        pending = nil
        close?()
    }

    /// Рукопожатие началось: до `untrack` «Отмена», «Стоп» и таймаут закроют этот сокет.
    mutating func track(_ socket: AnyObject, close: @escaping () -> Void) {
        pending = (ObjectIdentifier(socket), close)
    }

    /// Рукопожатие закончилось (чем угодно): дальше сокетом распоряжается вызывающий.
    mutating func untrack(_ socket: AnyObject) {
        if pending?.socket == ObjectIdentifier(socket) { pending = nil }
    }

    func isCurrent(_ attempt: Int) -> Bool { attempt == current }
}

enum ShareTimeouts {
    /// Сколько ждать сервер после выбора экрана: открытие сокета, проверка ключа, начало захвата.
    static let hostConnect: TimeInterval = 20

    static var hostConnectMessage: String {
        "Сервер трансляции не ответил за \(Int(hostConnect)) секунд. Проверьте связь и попробуйте ещё раз."
    }
}

/// Когда кодировать и отправлять видео (SH4).
enum ShareEncoderGate {
    /// Никто не смотрит — не кодируем и не шлём (3–6 Мбит/с впустую). Пока число зрителей не пришло от сервера (nil),
    /// не останавливаемся: старый ретранслятор мог бы и не прислать его, и зрители остались бы без картинки.
    static func shouldPause(viewers: Int?) -> Bool { viewers == 0 }
}

/// Зритель: что делать, когда соединение оборвалось (SH5).
enum ShareViewerReconnect {
    /// Паузы перед попытками, секунды: 7 попыток, около 60 секунд. Должны покрыть время, которое relay ждёт ведущего (45 с):
    /// ведущий сам переподключается до ~44 с, а пока его нет, relay отвечает зрителю 404. Сдадимся раньше — ведущий
    /// вернётся, а зритель уже отключён.
    static let delays: [UInt64] = [1, 2, 4, 8, 15, 15, 15]
    /// Сколько relay ждёт переподключения ведущего (`relay/src/index.js`, grace).
    static let hostGrace: TimeInterval = 45

    enum Decision: Equatable {
        case reconnect(attempt: Int, delay: UInt64)
        case end(String)
    }

    /// nil — это не обрыв просмотра (например, не удалось подключиться с первого раза): обычное сообщение об ошибке.
    /// - wasWatching: картинка уже шла;
    /// - attemptsMade: сколько попыток переподключения уже сделано подряд;
    /// - status: HTTP-код последнего отказа (404 — ведущий не в эфире).
    static func onDrop(wasWatching: Bool, attemptsMade: Int, status: Int?) -> Decision? {
        guard wasWatching || attemptsMade > 0 else { return nil }
        if attemptsMade < delays.count {
            return .reconnect(attempt: attemptsMade + 1, delay: delays[attemptsMade])
        }
        return .end(status == 404 ? "Трансляция завершена" : "Связь с ведущим потеряна — переподключиться не удалось")
    }

    /// Сервер шлёт heartbeat каждые 30 с (и во время ожидания разрешения): тишина дольше этого — связь умерла молча
    /// (Wi-Fi пропал без закрытия сокета). Больше, чем 45 с, которые сервер ждёт переподключения ведущего.
    static let silenceLimit: TimeInterval = 75

    static func isSilent(lastMessage: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastMessage) > silenceLimit
    }

    /// Сколько ждать одну попытку: без этого сокет висит до системных 60 с (Wi-Fi «подключён», но трафик не идёт),
    /// и все попытки растягиваются на минуты. `timeoutInterval` запроса не подходит: у веб-сокета он ограничивает
    /// и простой приёма во время просмотра.
    static let attemptTimeout: TimeInterval = 15

    /// Попытку пора прервать, только пока она ещё не дошла до сервера. `.waiting` — ведущий решает, пускать ли:
    /// человека не торопим.
    static func shouldAbortAttempt(state: ShareViewer.State) -> Bool {
        if case .reconnecting = state { return true }
        return false
    }

    static func status(attempt: Int) -> String {
        "Связь потеряна, переподключаюсь… (попытка \(attempt) из \(delays.count))"
    }
}

/// Метки времени для кодера (на очереди кодера). VideoToolbox ждёт строго растущих меток, а повтор последнего кадра
/// (`resendLast`) берёт метку «сейчас»: кадр, снятый раньше, но доставленный позже, получил бы метку меньше прежней,
/// и кодер его отбросил бы.
struct ShareFrameClock {
    /// Минимальный шаг между метками: 1/600 с.
    static let step = CMTime(value: 1, timescale: 600)
    private var last = CMTime.invalid

    mutating func next(_ time: CMTime) -> CMTime {
        var stamp = time
        if last.isValid {
            let earliest = CMTimeAdd(last, Self.step)
            if !stamp.isValid || stamp < earliest { stamp = earliest }
        }
        if stamp.isValid { last = stamp }
        return stamp
    }
}
