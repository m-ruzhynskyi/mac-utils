import AppKit
import Combine
import ScreenCaptureKit
import MUCore
import MUDesign
import MUCopilot
import MUAIBackend

/// Подсказчик в приложении: сочетания, панель, снимок экрана. Включается только вручную; включённость не сохраняется.
/// Звук и расшифровка — `LiveCopilotListener`; ИИ — `BackendCopilotAI`: сервис со страницы «ИИ», своего выбора у подсказчика нет.
@MainActor
final class CopilotGlue {
    static let shared = CopilotGlue()

    var ai: CopilotAIClient = BackendCopilotAI()
    /// В самопроверке (`--copilot-selftest`) — беззвучный источник: микрофон и звук звонка не открываются, вопрос подаёт сама проверка.
    var listener: CopilotListening = CopilotSelfTest.options(CommandLine.arguments) == nil ? LiveCopilotListener() : SilentCopilotListener()

    private(set) lazy var session = CopilotSession(ai: ai, listener: listener)

    private var panel: CopilotPanel?
    private var panelHidden = false
    private var phaseWatch: AnyCancellable?

    /// Сочетания, которые нужны только при включённом подсказчике: зарегистрированные всегда, они глотали бы ввод
    /// (⌥⇧A — «Å», ⌥⇧S — «Í», ⌥⇧P — «∏») и тогда, когда подсказчик выключен.
    static let whileOnActions: [HotKeyAction] = [.copilotAnswer, .copilotScreen, .copilotPanel]

    /// ⌥⇧M — всегда; остальные — пока подсказчик включён. Вызывается при запуске и при смене сочетаний.
    func registerHotKeys() {
        let combo = HotKeyRegistry.combo(for: .copilot)
        HotKeyCenter.shared.register(id: HotKeyAction.copilot.hotKeyID, keyCode: combo.keyCode, modifiers: combo.modifiers) {
            AppAction(hotKey: .copilot).run()
        }
        syncWhileOnHotKeys()
        watchPhase()
    }

    private func syncWhileOnHotKeys() {
        let center = HotKeyCenter.shared
        for action in Self.whileOnActions {
            if session.isOn {
                let combo = HotKeyRegistry.combo(for: action)
                center.register(id: action.hotKeyID, keyCode: combo.keyCode, modifiers: combo.modifiers) { Self.run(action) }
            } else {
                center.unregister(id: action.hotKeyID)
            }
        }
    }

    /// То же действие, что у ссылки и «Команд» (`AppAction(hotKey:)`), — проверяет ShortcutsTests.
    private static func run(_ action: HotKeyAction) {
        switch action {
        case .copilotAnswer: AppAction(hotKey: .copilotAnswer).run()
        case .copilotScreen: AppAction(hotKey: .copilotScreen).run()
        case .copilotPanel: AppAction(hotKey: .copilotPanel).run()
        default: AppAction(hotKey: .copilot).run()
        }
    }

    /// Подсказчик выключается и сам (обрыв звука, нет доступа): тогда прячем панель, снимаем сочетания и показываем причину.
    private func watchPhase() {
        guard phaseWatch == nil else { return }
        phaseWatch = session.$phase.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.phaseChanged() }
        }
    }

    private func phaseChanged() {
        syncWhileOnHotKeys()
        if !session.isOn {
            panelHidden = false
            if let error = session.error { Toast.show("Подсказчик выключен: \(error)", symbol: "exclamationmark.triangle.fill", tint: .orange) }
        }
        syncPanel()
    }

    func toggle() {
        session.toggle()
        syncWhileOnHotKeys()
        syncPanel()
    }

    func answer() { if session.isOn { session.answerLast() } }

    func togglePanel() {
        guard session.isOn else { return }
        panelHidden.toggle()
        syncPanel()
    }

    func shutdown() { session.stop(); panel?.hide() }

    /// Свойства панели для самопроверки: видна ли в демонстрации и может ли забрать фокус.
    var panelFacts: String {
        guard let panel else { return "панели нет" }
        let sharing = panel.sharingType == .none ? "none" : "\(panel.sharingType.rawValue)"
        return "sharingType \(sharing), canBecomeKey \(panel.canBecomeKey), видна \(panel.isVisible), мышь сквозь \(panel.ignoresMouseEvents)"
    }

    private func syncPanel() {
        if session.isOn, !panelHidden {
            let panel = self.panel ?? CopilotPanel(session: session)
            self.panel = panel
            let settings = CopilotPrefs.load()
            let screens = Self.screens()
            let chosen = ScreenChoice.pick(screens, preferred: settings.screenID, placement: settings.placement)
            let screen = chosen.flatMap { c in NSScreen.screens.first { Self.id(of: $0) == c.id } }
            panel.show(placement: settings.placement, on: screen)
        } else {
            panel?.hide()
        }
    }

    static func id(of screen: NSScreen) -> String {
        ((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value).map(String.init) ?? screen.localizedName
    }

    /// Подключённые экраны для выбора «iPad / второй экран» (iPad в режиме Sidecar виден как обычный экран).
    static func screens() -> [CopilotScreen] {
        NSScreen.screens.map { CopilotScreen(id: id(of: $0), name: $0.localizedName, isMain: $0 == NSScreen.screens.first) }
    }

    /// ⌥⇧S: снимок экрана под курсором (окна Mac Utils исключены) уходит в запрос.
    func lookAtScreen() {
        guard session.isOn else { return }
        Task { @MainActor in
            do {
                let data = try await Self.captureScreenUnderCursor()
                session.lookAtScreen(image: data)
            } catch {
                Log.ai.error("Подсказчик: снимок экрана не получился: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func captureScreenUnderCursor() async throws -> Data {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw CopilotError.noDisplay
        }
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = min(display.width, 1920)
        config.height = Int(Double(config.width) * Double(display.height) / Double(max(display.width, 1)))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CopilotError.noDisplay }
        return png
    }
}

enum CopilotError: LocalizedError {
    case noDisplay, notConnected(String)
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Не удалось снять экран"
        case .notConnected(let what): return "\(what) ещё не подключён"
        }
    }
}

struct UnavailableCopilotAI: CopilotAIClient {
    func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: CopilotError.notConnected("ИИ (Codex / Claude)")) }
    }
}

@MainActor
final class UnavailableCopilotListener: CopilotListening {
    var onFailure: (@MainActor (String) -> Void)?
    func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {
        throw CopilotError.notConnected("Звук и расшифровка")
    }
    func stop() {}
}

/// Подсказчик через общий бэкенд ИИ: сервис — тот, что выбран на странице «ИИ» (`AI.provider`), как у всех функций Mac Utils.
/// Тёплый процесс (по умолчанию) или запуск на каждый вопрос; быстрые модели у профиля `.fast`. Запасной сервис со страницы
/// «ИИ» здесь не используется: подсказке нужен ответ сейчас, а не через 20 с, и вопрос не уходит в сервис, который не выбран.
struct BackendCopilotAI: CopilotAIClient {
    static let timeout: TimeInterval = 45

    /// Клиент для сервиса: тёплый или разовый. Подменяется в тестах (заглушка бэкенда).
    nonisolated(unsafe) static var makeClient: @Sendable (AIProvider, _ warm: Bool) -> CopilotAIClient = { provider, warm in
        warm ? CopilotWarmRegistry.shared.client(provider) : ColdCopilotAI(provider: provider)
    }

    /// Кто отвечает: выбор на странице «ИИ».
    static var provider: AIProvider { AI.provider }

    var service: String { Self.provider.rawValue }

    func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
        guard AI.enabled else {
            return AsyncThrowingStream { $0.finish(throwing: CopilotError.notConnected("ИИ выключен: включите его на странице «ИИ»")) }
        }
        return Self.makeClient(Self.provider, CopilotModels.warmEnabled()).stream(prompt: prompt, system: system, images: images, profile: profile)
    }

    func warmUp(system: String) async {
        guard AI.enabled, CopilotModels.warmEnabled() else { return }
        await Self.makeClient(Self.provider, true).warmUp(system: system)
    }

    func shutdown() async { await CopilotWarmRegistry.shared.shutdownAll() }
}

/// Тёплые клиенты по сервисам. Сменили сервис на странице «ИИ» при включённом подсказчике — тёплый процесс прежнего
/// закрывается при первом же обращении к новому, а не живёт до выключения подсказчика.
final class CopilotWarmRegistry: @unchecked Sendable {
    static let shared = CopilotWarmRegistry()
    private let lock = NSLock()
    private var clients: [AIProvider: WarmCopilotAI] = [:]

    func client(_ provider: AIProvider) -> WarmCopilotAI {
        let (client, stale): (WarmCopilotAI, [WarmCopilotAI]) = lock.withLock {
            let stale = clients.filter { $0.key != provider }.map(\.value)
            clients = clients.filter { $0.key == provider }
            if let c = clients[provider] { return (c, stale) }
            let c = WarmCopilotAI(provider: provider)
            clients[provider] = c
            return (c, stale)
        }
        if !stale.isEmpty { Task { for c in stale { await c.shutdown() } } }
        return client
    }

    /// Каким путём ушёл последний вопрос сервиса (самопроверка): «да», «нет (<категория>)», nil — вопросов не было.
    func lastPath(_ provider: AIProvider) -> String? { lock.withLock { clients[provider] }?.lastPath }

    func shutdownAll() async {
        let all = lock.withLock { () -> [WarmCopilotAI] in let all = Array(clients.values); clients = [:]; return all }
        for c in all { await c.shutdown() }
    }
}
