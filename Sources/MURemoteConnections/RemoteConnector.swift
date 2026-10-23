import Foundation

/// Что подключить.
public struct ConnectRequest: Sendable {
    public var record: ConnectionRecord
    public var program: RemoteProgram
    /// false — ⌘↩ «без пароля»: только открыть программу на этом ID.
    public var withPassword: Bool
    /// Поставить в окне пароля галочку «входить автоматически» (если она есть).
    public var autologin: Bool
    /// Сколько ждать окно пароля или открытый сеанс. Пока открыто промежуточное окно программы, время не идёт.
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
    /// Программа показала промежуточное окно; таймаут стоит, пока оно открыто.
    case intermediate(IntermediateWindow)
    /// Ссылка не подставила ID — вписываю его в поле программы и нажимаю «Connect».
    case typingID
    /// Пароль введён и отправлен, жду ответа программы.
    case entered
    case finished(ConnectionOutcome)
}

public enum IntermediateWindow: Equatable, Sendable {
    /// «Terminal Session»: выбор по умолчанию оставлен, «Connect» нажат.
    case sessionChoice
    /// Программа соединяется или ждёт, пока та сторона примет запрос.
    case remoteSide
    /// Незнакомое окно — ничего не нажимаем, ждём.
    case unknown
}

public enum ConnectionOutcome: Equatable, Sendable {
    /// Окно пароля закрылось после ввода, отказа нет.
    case connected
    /// Пароль отправлен, окно программы ещё открыто (ждёт подтверждения на той стороне).
    case submitted
    /// Окна пароля не было, сеанс открыт: программа помнит этот компьютер.
    case connectedWithoutPassword
    /// К таймауту нет ни окна пароля, ни открытого сеанса. `copyID` — посоветовать вставить ID вручную.
    case unconfirmed(copyID: Bool)
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
        case .unconfirmed: return "unconfirmed"
        case .openedWithoutPassword(let r): return "opened_\(r == .userChoice ? "user" : "nopassword")"
        case .cancelled: return "cancelled"
        case .failed(let f): return "failed_\(f.code)"
        }
    }

    public var isSuccess: Bool {
        switch self {
        case .connected, .submitted, .connectedWithoutPassword, .openedWithoutPassword: return true
        case .unconfirmed, .cancelled, .failed: return false
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
/// 4) ждать окно с защищённым полем у процесса с нужным bundle id. Промежуточные окна проходятся сами («Terminal
/// Session» — «Connect» с выбором по умолчанию; отмену не нажимаем никогда), пока они открыты, таймаут стоит.
/// Без пароля подключено, только когда виден открытый сеанс; к таймауту его нет — «не подтверждено»;
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
        /// Окно этого подключения без диалогов столько времени — сеанс открыт. С запасом: ложный успех хуже, чем «не подтверждено».
        public var sessionSettle = 5000
        /// Программа запущена, а ссылка за это время ничего не открыла — вписать ID в поле самим.
        public var formGrace = 3000
        /// Нажатое нами «Connect» не закрыло промежуточное окно за это время — дальше ждём, ничего не нажимая.
        public var promptGrace = 3000
        /// Дольше этого не ждём даже с промежуточными окнами: пароль не держится в памяти без конца.
        public var limit = 180_000

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

        let trusted = ax.isTrusted
        let typing = request.withPassword && trusted
        // Ссылка может не подставить ID (TeamViewer на главном экране) — тогда смотрим и без ввода пароля.
        let watching = trusted && (typing || provider.fillsConnectForm)
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
        let known = watching ? secureFields(bundleID).filter { f in !(retry.map { $0.field.isSame(as: f) } ?? false) } : []
        let before = watching ? launcher.runningProcess(bundleID: bundleID).map(ax.windows(ofProcess:)) ?? [] : []
        guard launcher.open(url) else { return .failed(.launchFailed) }
        let unconfirmed = ConnectionOutcome.unconfirmed(copyID: provider.copiesIDWhenUnconfirmed)
        guard request.withPassword else {
            return watching ? await openOnly(.userChoice, request, provider, known, before, progress) : .openedWithoutPassword(.userChoice)
        }
        guard trusted else { return .failed(.noAccessibility) }
        guard let secret, !secret.isEmpty else {
            return provider.fillsConnectForm ? await openOnly(.notInFile, request, provider, known, before, progress)
                                             : .openedWithoutPassword(.notInFile)
        }

        let target: Target
        switch await waitForField(request, provider, known: known, before: before, progress) {
        case .found(let t): target = t
        case .session: return .connectedWithoutPassword
        case .timeout: return unconfirmed
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

    /// Без ввода пароля, но с проверкой, что программа открылась на этом ID (иначе — вписать его самим).
    private func openOnly(_ reason: ConnectionOutcome.NoPasswordReason, _ request: ConnectRequest, _ provider: RemoteProvider,
                          _ known: [AXNode], _ before: [AXNode], _ progress: (ConnectionPhase) -> Void) async -> ConnectionOutcome {
        switch await waitForField(request, provider, known: known, before: before, progress) {
        case .found, .noField: return .openedWithoutPassword(reason)
        case .session: return .connectedWithoutPassword
        case .timeout, .neverStarted: return .unconfirmed(copyID: provider.copiesIDWhenUnconfirmed)
        case .untrusted: return .failed(.untrustedProgram)
        case .cancelled: return .cancelled
        }
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
        /// Сеанс открыт без окна пароля.
        case session
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

    /// Ждём окно пароля. Пока открыто промежуточное окно программы, время ожидания не идёт (но не дольше `limit`).
    private func waitForField(_ request: ConnectRequest, _ provider: RemoteProvider, known: [AXNode], before: [AXNode],
                              _ progress: (ConnectionPhase) -> Void) async -> Wait {
        let bundleID = provider.program.bundleID
        let texts = provider.texts
        let timeout = max(request.timeoutSeconds, 1) * 1000
        let start = clock.milliseconds
        var last = start
        var counted = 0
        var paused = false
        var shownSecond = -1
        var shownWindow: IntermediateWindow?
        var sawProcess = false
        var processSince: Int?
        var passwordWindowSince: Int?
        var calmSince: Int?
        var formFilled = false
        var watch = SessionWatch()
        while true {
            let now = clock.milliseconds
            if !paused { counted += now - last }
            last = now
            var intermediate: IntermediateWindow?
            if let pid = launcher.runningProcess(bundleID: bundleID), launcher.bundleID(ofProcess: pid) == bundleID {
                guard launcher.teamID(ofProcess: pid) == provider.program.teamID else { return .untrusted }
                sawProcess = true
                let firstSeen = processSince ?? now
                processSince = firstSeen
                let windows = ax.windows(ofProcess: pid)
                var bare: AXNode?
                var blocked = false
                for window in windows {
                    // Промежуточное окно — раньше поля: в «Terminal Session» может быть своё поле, не для нашего пароля.
                    if let marker = texts.shows(texts.promptTexts, in: window) {
                        watch.track(window)
                        blocked = true
                        let pressed = continuePrompt(marker, in: window, texts, &watch, now: now)
                        intermediate = pressed ? .sessionChoice : .unknown
                        continue
                    }
                    let fields = AXTree.all(in: window, where: AXTree.isSecureField)
                    if let field = fields.first(where: { f in !known.contains { $0.isSame(as: f) } }) {
                        return .found(Target(pid: pid, window: window, field: field))
                    }
                    if !fields.isEmpty { continue }   // окно пароля другого подключения
                    if texts.isPasswordWindow(window) {
                        bare = window
                        watch.track(window)
                        continue
                    }
                    if texts.shows(texts.sessionTexts, in: window) != nil { return .session }
                    if texts.shows(texts.progressTexts, in: window) != nil {
                        watch.track(window)
                        blocked = true
                        intermediate = intermediate ?? .remoteSide
                        continue
                    }
                    if texts.shows(texts.closedTexts, in: window) != nil || texts.isRejection(window) {
                        blocked = true   // сеанс не открылся — ждём до таймаута, успехом не считаем
                        continue
                    }
                    let isNew = !before.contains { $0.isSame(as: window) }
                    if isNew, Self.isDialog(window) {
                        blocked = true
                        intermediate = intermediate ?? .unknown
                        continue
                    }
                    if isNew, Self.title(of: window, matches: request.record) { watch.track(window) }
                }
                if let bare {
                    let since = passwordWindowSince ?? now
                    passwordWindowSince = since
                    if now - since >= timing.fieldGrace { return .noField(AXTree.structure(of: bare)) }
                } else {
                    passwordWindowSince = nil
                }

                // Окно этого подключения открыто и без диалогов — сеанс.
                let calm = !blocked && bare == nil && windows.contains { w in watch.isTracked(w) }
                if calm {
                    let since = calmSince ?? now
                    calmSince = since
                    if now - since >= timing.sessionSettle { return .session }
                } else {
                    calmSince = nil
                }

                // Ссылка ничего не открыла — вписать ID в поле главного окна и нажать «Connect».
                if provider.fillsConnectForm, !formFilled, !watch.any, !blocked, bare == nil,
                   now - firstSeen >= timing.formGrace, let form = connectForm(in: windows, texts) {
                    formFilled = true
                    progress(.typingID)
                    shownSecond = -1
                    if await fill(form, id: request.record.id, pid: pid, provider) { counted = 0 }
                    last = clock.milliseconds
                    if Task.isCancelled { return .cancelled }
                    continue
                }
            }
            paused = intermediate != nil
            if clock.milliseconds - start >= timing.limit || counted >= timeout { return sawProcess ? .timeout : .neverStarted }
            if let intermediate {
                if intermediate != shownWindow { progress(.intermediate(intermediate)) }
                shownWindow = intermediate
            } else {
                if shownWindow != nil { shownWindow = nil; shownSecond = -1 }
                if counted / 1000 != shownSecond {
                    shownSecond = counted / 1000
                    progress(.waiting(elapsed: shownSecond, timeout: max(request.timeoutSeconds, 1)))
                }
            }
            do { try await clock.sleep(milliseconds: timing.poll) } catch { return .cancelled }
            if Task.isCancelled { return .cancelled }
        }
    }

    /// Окна этого подключения и кнопки, которые мы уже нажали.
    private struct SessionWatch {
        private(set) var windows: [AXNode] = []
        var pressed: [(button: AXNode, at: Int)] = []

        var any: Bool { !windows.isEmpty }
        mutating func track(_ window: AXNode) { if !isTracked(window) { windows.append(window) } }
        func isTracked(_ window: AXNode) -> Bool { windows.contains { $0.isSame(as: window) } }
    }

    /// Диалог или лист, открытый после ссылки.
    private static func isDialog(_ window: AXNode) -> Bool {
        if ["AXDialog", "AXSystemDialog"].contains(window.subrole ?? "") { return true }
        return window.children.contains { $0.role == "AXSheet" }
    }

    /// Заголовок окна называет этот компьютер: цифры ID (пробелы не в счёт) или алиас.
    static func title(of window: AXNode, matches record: ConnectionRecord) -> Bool {
        guard let title = window.label?.lowercased(), !title.isEmpty else { return false }
        let id = record.id.lowercased()
        if record.isAlias { return title.contains(id) }
        let digits = id.filter(\.isNumber)
        return digits.count >= 6 && title.filter(\.isNumber).contains(digits)
    }

    /// Промежуточное окно с кнопкой продолжения: выбор по умолчанию оставить (поставить, если программа запомнила
    /// другой), нажать «Connect». Только кнопки из `promptContinueTitles` — отмену и закрытие не нажимаем никогда.
    /// false — кнопки нет или нажатая не помогла: ждём, ничего не трогая.
    private func continuePrompt(_ marker: AXNode, in window: AXNode, _ texts: ProviderTexts,
                                _ watch: inout SessionWatch, now: Int) -> Bool {
        let isContinue: (AXNode) -> Bool = { $0.role == "AXButton" && ProviderTexts.named($0, texts.promptContinueTitles) }
        guard let button = AXTree.nearest(to: marker, in: window, where: isContinue) else { return false }
        if let done = watch.pressed.first(where: { $0.button.isSame(as: button) }) {
            return now - done.at < timing.promptGrace
        }
        let isDefault: (AXNode) -> Bool = { node in
            node.role == "AXRadioButton" && AXTree.names(of: node).contains { name in
                texts.promptDefaultTitles.contains { ProviderTexts.key(name).hasPrefix($0) }
            }
        }
        if let choice = AXTree.nearest(to: marker, in: window, where: isDefault), choice.isChecked == false { _ = choice.press() }
        guard button.press() else { return false }
        watch.pressed.append((button, now))
        return true
    }

    private struct ConnectForm {
        let field: AXNode
        let button: AXNode?
    }

    /// Поле ID на главном экране: по своей подписи или подсказке, иначе ближайшее к надписи над ним.
    private func connectForm(in windows: [AXNode], _ texts: ProviderTexts) -> ConnectForm? {
        guard !texts.connectFieldTexts.isEmpty else { return nil }
        for window in windows {
            var field = AXTree.first(in: window) { AXTree.isTextInput($0) && ProviderTexts.named($0, texts.connectFieldTexts) }
            if field == nil, let caption = AXTree.first(in: window, where: {
                $0.role == "AXStaticText" && ProviderTexts.named($0, texts.connectFieldTexts)
            }) {
                field = AXTree.nearest(to: caption, in: window, where: AXTree.isTextInput)
            }
            guard let field else { continue }
            let button = AXTree.nearest(to: field, in: window) {
                $0.role == "AXButton" && ProviderTexts.named($0, texts.connectButtonTitles)
            }
            return ConnectForm(field: field, button: button)
        }
        return nil
    }

    /// ID — не секрет: набрать в поле (веб-поля надёжнее берут нажатия), не вышло — `AXValue`; затем «Connect».
    private func fill(_ form: ConnectForm, id: String, pid: Int32, _ provider: RemoteProvider) async -> Bool {
        let bundleID = provider.program.bundleID
        guard form.field.processID == pid, isGenuine(pid, provider.program) else { return false }
        let expected: Set<Int> = [id.unicodeScalars.count, id.utf16.count]
        launcher.activate(process: pid)
        var entered = false
        if await waitFrontmost(pid) {
            _ = form.field.clearValue()
            _ = form.field.focus()
            if isFocused(form.field, pid) {
                entered = typeText(id, into: form.field, pid, bundleID) && matches(form.field.valueLength, expected, unknownIs: true)
            }
        }
        if !entered {
            _ = form.field.clearValue()
            entered = form.field.setText(id) && matches(form.field.valueLength, expected, unknownIs: true)
        }
        guard entered else { return false }
        if let button = form.button, button.press() { return true }
        guard isFront(pid, bundleID) else { return false }
        keyboard.pressReturn(to: pid)
        return true
    }

    /// Посимвольно, пока поле в фокусе у нужного процесса.
    private func typeText(_ text: String, into field: AXNode, _ pid: Int32, _ bundleID: String) -> Bool {
        for scalar in text.unicodeScalars {
            guard isFocused(field, pid), launcher.bundleID(ofProcess: pid) == bundleID else { return false }
            let units = Array(String(scalar).utf16)
            units.withUnsafeBufferPointer { keyboard.type($0, to: pid) }
        }
        return true
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

    private func isFocused(_ target: Target) -> Bool { isFocused(target.field, target.pid) }

    private func isFocused(_ field: AXNode, _ pid: Int32) -> Bool {
        launcher.frontmostProcess == pid && ax.focusedElement(ofProcess: pid).map { $0.isSame(as: field) } == true
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

    /// Отмена, закрытие, отказ — такие кнопки не нажимаются никогда, даже если они «по умолчанию».
    static let cancelTitles: Set<String> = Set(["Cancel", "Отмена", "Скасувати", "Abbrechen", "Annuler", "Cancelar", "Annulla",
                                                "Close", "Закрыть", "Закрити", "Deny", "Отклонить", "Відхилити", "Abort",
                                                "Прервать", "Перервати", "Disconnect", "Отключить"].map(ProviderTexts.key))

    private enum Submit { case pressed, notFront, onlyCancel }

    /// «ОК»: кнопка по умолчанию (если это не отмена), кнопка с надписью подтверждения, иначе Return в процесс
    /// программы — но не тогда, когда по умолчанию стоит отмена: Return нажал бы её.
    private func submit(_ target: Target, _ texts: ProviderTexts, _ bundleID: String) -> Submit {
        let isCancel: (AXNode) -> Bool = { ProviderTexts.named($0, Self.cancelTitles) }
        let defaultButton = target.window.defaultButton
        if let button = defaultButton, !isCancel(button), button.press() { return .pressed }
        let buttons = AXTree.all(in: target.window) { $0.role == "AXButton" && !isCancel($0) }
        if let ok = buttons.first(where: { ProviderTexts.named($0, texts.confirmTitles) }), ok.press() { return .pressed }
        if let button = defaultButton, isCancel(button) { return .onlyCancel }
        guard isFront(target.pid, bundleID) else { return .notFront }
        keyboard.pressReturn(to: target.pid)
        return .pressed
    }

    // MARK: - Ответ программы

    private func confirm(_ target: Target, _ provider: RemoteProvider, known: [AXNode]) async -> ConnectionOutcome {
        switch submit(target, provider.texts, provider.program.bundleID) {
        case .pressed: break
        case .notFront:
            _ = target.field.clearValue()
            return .failed(.focusLost)
        case .onlyCancel:
            // Кнопки подтверждения не нашлось — пароль не отправляем, пусть пользователь нажмёт сам.
            _ = target.field.clearValue()
            return .failed(.fieldNotFound(structure: AXTree.structure(of: target.window)))
        }
        let start = clock.milliseconds
        var goneAt: Int?
        var watch = SessionWatch()
        while clock.milliseconds - start < timing.confirm {
            do { try await clock.sleep(milliseconds: timing.poll) } catch { return .submitted }
            let texts = provider.texts
            let windows = ax.windows(ofProcess: target.pid)
            if windows.contains(where: texts.isRejection) { return .failed(.wrongPassword) }
            if windows.contains(where: { texts.shows(texts.sessionTexts, in: $0) != nil }) { return .connected }
            // После пароля бывает «Terminal Session» или ожидание той стороны — это ещё не подключено.
            var busy = false
            for window in windows {
                if let marker = texts.shows(texts.promptTexts, in: window) {
                    _ = continuePrompt(marker, in: window, texts, &watch, now: clock.milliseconds)
                    busy = true
                } else if texts.shows(texts.progressTexts, in: window) != nil {
                    busy = true
                }
            }
            let fields = windows.flatMap { AXTree.all(in: $0, where: AXTree.isSecureField) }
            if busy {
                goneAt = nil
            } else if fields.contains(where: { $0.isSame(as: target.field) }) {
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
