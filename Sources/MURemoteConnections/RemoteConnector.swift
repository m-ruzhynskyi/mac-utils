import Foundation

/// Что подключить.
public struct ConnectRequest: Sendable {
    public var record: ConnectionRecord
    public var program: RemoteProgram
    /// false — ⌘↩ «без пароля»: только открыть программу на этом ID.
    public var withPassword: Bool
    /// Поставить в окне пароля галочку «входить автоматически» (если она есть).
    public var autologin: Bool
    /// Сколько ждать окно пароля; не появилось — программа пустила без пароля.
    public var timeoutSeconds: Int
    /// Повтор после «Ввод прерван»: вводить можно и в окно пароля, которое открыло прерванное подключение
    /// к этой же записи. Другие открытые окна пароля по-прежнему не наши.
    public var reuseOpenWindow: Bool

    public init(record: ConnectionRecord, program: RemoteProgram, withPassword: Bool = true, autologin: Bool = false,
                timeoutSeconds: Int = 20, reuseOpenWindow: Bool = false) {
        self.record = record
        self.program = program
        self.withPassword = withPassword
        self.autologin = autologin
        self.timeoutSeconds = timeoutSeconds
        self.reuseOpenWindow = reuseOpenWindow
    }
}

/// Ход подключения для HUD.
public enum ConnectionPhase: Equatable, Sendable {
    case opening
    /// Жду окно пароля: прошло `elapsed` из `timeout` секунд.
    case waiting(elapsed: Int, timeout: Int)
    /// Пароль введён и отправлен, жду ответа программы.
    case entered
    case finished(ConnectionOutcome)
}

public enum ConnectionOutcome: Equatable, Sendable {
    /// Окно пароля закрылось после ввода, отказа нет.
    case connected
    /// Пароль отправлен, окно программы ещё открыто (ждёт подтверждения на той стороне).
    case submitted
    /// Окно пароля не появилось: программа помнит этот компьютер.
    case connectedWithoutPassword
    /// Программа открыта на этом ID, пароль не вводился.
    case openedWithoutPassword(NoPasswordReason)
    case cancelled
    case failed(ConnectionFailure)

    public enum NoPasswordReason: String, Equatable, Sendable {
        /// ⌘↩.
        case userChoice
        /// В файле у записи пароля нет.
        case notInFile
    }

    /// Код для журнала.
    public var code: String {
        switch self {
        case .connected: return "connected"
        case .submitted: return "submitted"
        case .connectedWithoutPassword: return "auto"
        case .openedWithoutPassword(let r): return "opened_\(r == .userChoice ? "user" : "nopassword")"
        case .cancelled: return "cancelled"
        case .failed(let f): return "failed_\(f.code)"
        }
    }

    public var isSuccess: Bool {
        switch self {
        case .connected, .submitted, .connectedWithoutPassword, .openedWithoutPassword: return true
        case .cancelled, .failed: return false
        }
    }
}

/// Ошибки из дизайна (m07/m07b).
public enum ConnectionFailure: Equatable, Sendable {
    /// Программа открыта, но «Универсального доступа» нет — пароль не введён.
    case noAccessibility
    case notInstalled
    case launchFailed
    /// Алиас `имя@ad` у программы без алиасов.
    case aliasNotSupported
    /// В файле обе программы, у строки программа не указана — выбрать.
    case programNotSpecified
    /// Окно пароля есть, поля нет (или в него не попасть). `structure` — роли элементов окна, без надписей и значений.
    case fieldNotFound(structure: [String])
    case wrongPassword
    /// Впереди оказалась другая программа или фокус ушёл из поля — ввод прерван, пароль не отправлен.
    case focusLost
    /// Процесс с нужным bundle id подписан не тем разработчиком (или подпись не проверилась) — пароль не вводится.
    case untrustedProgram
    /// Записи больше нет в файле.
    case entryGone
    /// Файл не прочитался в момент подключения.
    case fileUnavailable(ConnectionsError.Code)

    public var code: String {
        switch self {
        case .noAccessibility: return "accessibility"
        case .notInstalled: return "notinstalled"
        case .launchFailed: return "launch"
        case .aliasNotSupported: return "alias"
        case .programNotSpecified: return "program"
        case .fieldNotFound: return "nofield"
        case .wrongPassword: return "wrongpassword"
        case .focusLost: return "focus"
        case .untrustedProgram: return "untrusted"
        case .entryGone: return "entrygone"
        case .fileUnavailable(let c): return "file_\(c.rawValue)"
        }
    }
}

/// Подключение с вводом пароля в окно программы. Порядок:
/// 1) программа установлена, ссылка есть; 2) пароль — из файла сейчас, в `SecretBuffer`; 3) открыть ссылку;
/// 4) ждать окно с защищённым полем у процесса с нужным bundle id; не появилось за таймаут — вход без пароля;
/// 5) программа впереди, поле её — `AXValue`, не взялось — посимвольно, с проверкой фокуса перед каждым символом;
/// 6) галочка автологина, «ОК»; 7) поле закрылось — подключено, отказ или новое окно пароля — неверный пароль.
/// Пароль затирается при любом исходе.
@MainActor
public final class RemoteConnector {
    public struct Timing: Sendable {
        public var poll = 250
        /// Сколько ждать, пока программа выйдет вперёд.
        public var activation = 1500
        /// Окно пароля без поля дольше этого — «поле не найдено».
        public var fieldGrace = 2000
        /// Сколько после «ОК» ждать ответа программы.
        public var confirm = 8000
        /// Поле закрылось — столько ещё смотрим, не придёт ли отказ.
        public var settle = 1500

        public init() {}
    }

    private let ax: AXAccess
    private let launcher: AppLauncher
    private let keyboard: KeyboardSender
    private let clock: RemoteClock
    private let logger: RemoteLogger?
    public var timing = Timing()
    /// Окно пароля, ввод в которое прервался («Ввод прерван»): «Повторить» для той же записи может вводить только в него.
    private var interrupted: (recordID: String, program: RemoteProgram, pid: Int32, field: AXNode)?

    public init(ax: AXAccess, launcher: AppLauncher, keyboard: KeyboardSender, clock: RemoteClock = SystemClock(),
                logger: RemoteLogger? = nil) {
        self.ax = ax
        self.launcher = launcher
        self.keyboard = keyboard
        self.clock = clock
        self.logger = logger
    }

    /// `password` вызывается один раз, только если пароль действительно будет вводиться.
    public func connect(_ request: ConnectRequest, provider: RemoteProvider,
                        password: () async throws -> PasswordLookup,
                        progress: (ConnectionPhase) -> Void) async -> ConnectionOutcome {
        let started = clock.milliseconds
        var opened = false
        let outcome = await run(request, provider, password, progress, opened: &opened)
        logger?.log(.connection(result: outcome.code, typed: opened, milliseconds: clock.milliseconds - started))
        progress(.finished(outcome))
        return outcome
    }

    // MARK: - Шаги

    private func run(_ request: ConnectRequest, _ provider: RemoteProvider,
                     _ password: () async throws -> PasswordLookup,
                     _ progress: (ConnectionPhase) -> Void, opened: inout Bool) async -> ConnectionOutcome {
        let bundleID = provider.program.bundleID
        guard launcher.isInstalled(bundleID: bundleID) else { return .failed(.notInstalled) }
        guard let url = provider.connectURL(id: request.record.id) else { return .failed(.aliasNotSupported) }

        let typing = request.withPassword && ax.isTrusted
        var secret: SecretBuffer?
        defer { secret?.wipe() }
        if typing {
            do {
                switch try await password() {
                case .found(let s): secret = s
                case .noPassword: break
                case .entryGone: return .failed(.entryGone)
                }
            } catch let error as ConnectionsError {
                return .failed(.fileUnavailable(error.code))
            } catch {
                return Task.isCancelled ? .cancelled : .failed(.fileUnavailable(.unavailable))
            }
        }
        if Task.isCancelled { return .cancelled }

        progress(.opening)
        // Поля пароля, открытые до нас, — не наши (например, окно другого подключения). Исключение — «Повторить»:
        // окно, которое открыло прерванное подключение к этой же записи.
        let retry = request.reuseOpenWindow
            ? interrupted.flatMap { $0.recordID == request.record.id && $0.program == provider.program ? $0 : nil } : nil
        interrupted = nil
        let known = typing ? secureFields(bundleID).filter { f in !(retry.map { $0.field.isSame(as: f) } ?? false) } : []
        guard launcher.open(url) else { return .failed(.launchFailed) }
        guard request.withPassword else { return .openedWithoutPassword(.userChoice) }
        guard ax.isTrusted else { return .failed(.noAccessibility) }
        guard let secret, !secret.isEmpty else { return .openedWithoutPassword(.notInFile) }

        let target: Target
        switch await waitForField(request, provider, known: known, progress) {
        case .found(let t): target = t
        case .timeout: return .connectedWithoutPassword
        case .neverStarted: return .failed(.launchFailed)
        case .untrusted: return .failed(.untrustedProgram)
        case .noField(let structure): return .failed(.fieldNotFound(structure: structure))
        case .cancelled: return .cancelled
        }

        opened = true
        let outcome: ConnectionOutcome
        if let failure = await enter(secret, into: target, request, provider) {
            outcome = .failed(failure)
        } else {
            secret.wipe()
            progress(.entered)
            outcome = await confirm(target, provider, known: known)
        }
        if outcome == .failed(.focusLost) {
            interrupted = (request.record.id, provider.program, target.pid, target.field)
        }
        return outcome
    }

    /// Процесс — та программа: bundle id и Team ID действительной подписи.
    private func isGenuine(_ pid: Int32, _ program: RemoteProgram) -> Bool {
        launcher.bundleID(ofProcess: pid) == program.bundleID && launcher.teamID(ofProcess: pid) == program.teamID
    }

    private struct Target {
        let pid: Int32
        let window: AXNode
        let field: AXNode
    }

    private enum Wait {
        case found(Target)
        case timeout
        case neverStarted
        case noField([String])
        case untrusted
        case cancelled
    }

    private func secureFields(_ bundleID: String) -> [AXNode] {
        guard let pid = launcher.runningProcess(bundleID: bundleID) else { return [] }
        return ax.windows(ofProcess: pid).flatMap { AXTree.all(in: $0, where: AXTree.isSecureField) }
    }

    private func waitForField(_ request: ConnectRequest, _ provider: RemoteProvider, known: [AXNode],
                              _ progress: (ConnectionPhase) -> Void) async -> Wait {
        let bundleID = provider.program.bundleID
        let timeout = max(request.timeoutSeconds, 1) * 1000
        let start = clock.milliseconds
        var shownSecond = -1
        var sawProcess = false
        var passwordWindowSince: Int?
        while true {
            let elapsed = clock.milliseconds - start
            if let pid = launcher.runningProcess(bundleID: bundleID), launcher.bundleID(ofProcess: pid) == bundleID {
                guard launcher.teamID(ofProcess: pid) == provider.program.teamID else { return .untrusted }
                sawProcess = true
                var bare: AXNode?
                for window in ax.windows(ofProcess: pid) {
                    let fields = AXTree.all(in: window, where: AXTree.isSecureField)
                    if let field = fields.first(where: { f in !known.contains { $0.isSame(as: f) } }) {
                        return .found(Target(pid: pid, window: window, field: field))
                    }
                    if fields.isEmpty, provider.texts.isPasswordWindow(window) { bare = window }
                }
                if let bare {
                    let since = passwordWindowSince ?? elapsed
                    passwordWindowSince = since
                    if elapsed - since >= timing.fieldGrace { return .noField(AXTree.structure(of: bare)) }
                } else {
                    passwordWindowSince = nil
                }
            }
            if elapsed >= timeout { return sawProcess ? .timeout : .neverStarted }
            if elapsed / 1000 != shownSecond {
                shownSecond = elapsed / 1000
                progress(.waiting(elapsed: shownSecond, timeout: max(request.timeoutSeconds, 1)))
            }
            do { try await clock.sleep(milliseconds: timing.poll) } catch { return .cancelled }
            if Task.isCancelled { return .cancelled }
        }
    }

    /// Ввод: только в процесс нужной программы, когда она впереди. nil — введено.
    private func enter(_ secret: SecretBuffer, into target: Target, _ request: ConnectRequest,
                       _ provider: RemoteProvider) async -> ConnectionFailure? {
        let bundleID = provider.program.bundleID
        guard target.field.processID == target.pid else { return .focusLost }
        guard isGenuine(target.pid, provider.program) else { return .untrustedProgram }
        launcher.activate(process: target.pid)
        guard await waitFrontmost(target.pid) else { return .focusLost }

        if request.autologin, provider.supportsAutologin { tickAutologin(in: target.window, provider.texts) }

        let expected = Self.lengths(of: secret)
        guard isFront(target.pid, bundleID) else { return .focusLost }
        if target.field.setSecretValue(secret), matches(target.field.valueLength, expected, unknownIs: true) {
            return isFront(target.pid, bundleID) ? nil : clear(target, .focusLost)
        }

        // AX не взял значение — посимвольно, только пока поле в фокусе у нужного процесса.
        _ = target.field.clearValue()
        _ = target.field.focus()
        guard isFocused(target) else {
            return isFront(target.pid, bundleID) ? .fieldNotFound(structure: AXTree.structure(of: target.window)) : .focusLost
        }
        guard typeSecret(secret, into: target, bundleID) else { return clear(target, .focusLost) }
        guard matches(target.field.valueLength, expected, unknownIs: true) else {
            return clear(target, .fieldNotFound(structure: AXTree.structure(of: target.window)))
        }
        return isFront(target.pid, bundleID) ? nil : clear(target, .focusLost)
    }

    private func clear(_ target: Target, _ failure: ConnectionFailure) -> ConnectionFailure {
        _ = target.field.clearValue()
        return failure
    }

    private func waitFrontmost(_ pid: Int32) async -> Bool {
        let start = clock.milliseconds
        while launcher.frontmostProcess != pid {
            guard clock.milliseconds - start < timing.activation else { return false }
            do { try await clock.sleep(milliseconds: 50) } catch { return false }
        }
        return true
    }

    private func isFront(_ pid: Int32, _ bundleID: String) -> Bool {
        guard let front = launcher.frontmostProcess else { return false }
        return front == pid && launcher.bundleID(ofProcess: front) == bundleID
    }

    private func isFocused(_ target: Target) -> Bool {
        launcher.frontmostProcess == target.pid
            && ax.focusedElement(ofProcess: target.pid).map { $0.isSame(as: target.field) } == true
    }

    /// Галочка «входить автоматически»: по надписи, иначе единственная галочка окна.
    private func tickAutologin(in window: AXNode, _ texts: ProviderTexts) {
        let boxes = AXTree.all(in: window) { $0.role == "AXCheckBox" }
        let box = boxes.first { $0.label.map { texts.autologinTitles.contains(ProviderTexts.key($0)) } == true }
            ?? (boxes.count == 1 ? boxes[0] : nil)
        if let box, box.isChecked == false { _ = box.press() }
    }

    /// Посимвольно из буфера, без `String`. Перед каждым символом — фокус в поле нужного процесса.
    private func typeSecret(_ secret: SecretBuffer, into target: Target, _ bundleID: String) -> Bool {
        secret.withBytes { raw in
            var iterator = raw.makeIterator()
            var decoder = UTF8()
            return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 2) { units in
                units.initialize(repeating: 0)
                defer { units.initialize(repeating: 0) }
                while true {
                    switch decoder.decode(&iterator) {
                    case .scalarValue(let scalar):
                        guard isFocused(target), launcher.bundleID(ofProcess: target.pid) == bundleID else { return false }
                        var n = 0
                        UTF16.encode(scalar) { units[n] = $0; n += 1 }
                        keyboard.type(UnsafeBufferPointer(rebasing: units[0..<n]), to: target.pid)
                        units.initialize(repeating: 0)
                    case .emptyInput:
                        return true
                    case .error:
                        return false
                    }
                }
            }
        }
    }

    /// Длина секрета в символах Unicode и в единицах UTF-16: поле может считать и так, и так.
    static func lengths(of secret: SecretBuffer) -> Set<Int> {
        secret.withBytes { raw in
            var iterator = raw.makeIterator()
            var decoder = UTF8()
            var scalars = 0, utf16 = 0
            while case .scalarValue(let s) = decoder.decode(&iterator) {
                scalars += 1
                utf16 += UTF16.width(s)
            }
            return [scalars, utf16]
        }
    }

    private func matches(_ length: Int?, _ expected: Set<Int>, unknownIs: Bool) -> Bool {
        guard let length else { return unknownIs }
        return expected.contains(length)
    }

    /// «ОК»: кнопка по умолчанию, кнопка с надписью подтверждения, иначе Return в процесс программы.
    private func submit(_ target: Target, _ texts: ProviderTexts, _ bundleID: String) -> Bool {
        if let button = target.window.defaultButton, button.press() { return true }
        let buttons = AXTree.all(in: target.window) { $0.role == "AXButton" }
        if let ok = buttons.first(where: { $0.label.map { texts.confirmTitles.contains(ProviderTexts.key($0)) } == true }),
           ok.press() { return true }
        guard isFront(target.pid, bundleID) else { return false }
        keyboard.pressReturn(to: target.pid)
        return true
    }

    // MARK: - Ответ программы

    private func confirm(_ target: Target, _ provider: RemoteProvider, known: [AXNode]) async -> ConnectionOutcome {
        guard submit(target, provider.texts, provider.program.bundleID) else {
            _ = target.field.clearValue()
            return .failed(.focusLost)
        }
        let start = clock.milliseconds
        var goneAt: Int?
        while clock.milliseconds - start < timing.confirm {
            do { try await clock.sleep(milliseconds: timing.poll) } catch { return .submitted }
            let windows = ax.windows(ofProcess: target.pid)
            if windows.contains(where: provider.texts.isRejection) { return .failed(.wrongPassword) }
            let fields = windows.flatMap { AXTree.all(in: $0, where: AXTree.isSecureField) }
            if fields.contains(where: { $0.isSame(as: target.field) }) {
                goneAt = nil
                // Программа очистила поле — пароль не подошёл.
                if target.field.valueLength == 0 { return .failed(.wrongPassword) }
            } else if fields.contains(where: { f in !known.contains { $0.isSame(as: f) } }) {
                // Окно пароля появилось снова.
                return .failed(.wrongPassword)
            } else {
                let since = goneAt ?? clock.milliseconds
                goneAt = since
                if clock.milliseconds - since >= timing.settle { return .connected }
            }
        }
        return goneAt == nil ? .submitted : .connected
    }
}
