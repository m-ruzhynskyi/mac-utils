import AppKit
import ScreenCaptureKit
import MUCore
import MUCopilot
import MUAIBackend

/// Подсказчик в приложении: сочетания, панель, снимок экрана. Включается только вручную; включённость не сохраняется.
/// Звук и расшифровка — `LiveCopilotListener`; ИИ — `BackendCopilotAI` (Codex или Claude по выбору на странице «ИИ»).
@MainActor
final class CopilotGlue {
    static let shared = CopilotGlue()

    /// Подставляются, когда готовы `feature/ai-backend` и расшифровка (`MUMeetings`).
    var ai: CopilotAIClient = BackendCopilotAI()
    var listener: CopilotListening = LiveCopilotListener()

    private(set) lazy var session = CopilotSession(ai: ai, listener: listener, onLatency: { seconds in
        CopilotGlue.recordLatency(seconds)
    })

    /// Сервис подсказчика: свой выбор или тот, что в Mac Utils.
    nonisolated static func effectiveProvider(choice: CopilotProviderChoice = CopilotProviderChoice.load(), system: AIProvider = AI.provider) -> AIProvider {
        switch choice {
        case .system: return system
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    /// Замер «до первой строки» по сервису: из него складывается совет «Claude отвечает быстрее».
    nonisolated static func recordLatency(_ seconds: TimeInterval) {
        var stats = LatencyStats.load()
        stats.add(seconds, provider: effectiveProvider().rawValue)
        stats.save()
    }
    private var panel: CopilotPanel?
    private var panelHidden = false

    func registerHotKeys() {
        let center = HotKeyCenter.shared
        for (action, appAction) in [(HotKeyAction.copilot, AppAction.copilotToggle), (.copilotAnswer, .copilotAnswer),
                                    (.copilotScreen, .copilotScreen), (.copilotPanel, .copilotPanel)] {
            let combo = HotKeyRegistry.combo(for: action)
            center.register(id: action.hotKeyID, keyCode: combo.keyCode, modifiers: combo.modifiers) { appAction.run() }
        }
    }

    func toggle() {
        session.toggle()
        syncPanel()
    }

    func answer() { if session.isOn { session.answerLast() } }

    func togglePanel() {
        guard session.isOn else { return }
        panelHidden.toggle()
        syncPanel()
    }

    func shutdown() { session.stop(); panel?.hide() }

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

/// Подсказчик через общий бэкенд ИИ: сервис по выбору подсказчика («Как в Mac Utils» — Codex по умолчанию, или Claude / ChatGPT). Тёплый процесс (по умолчанию) или
/// запуск на каждый вопрос; быстрые модели у профиля `.fast`. Запасной сервис из страницы «ИИ» здесь не используется:
/// подсказке нужен ответ сейчас, а не через 20 с.
struct BackendCopilotAI: CopilotAIClient {
    static let timeout: TimeInterval = 45

    private var provider: AIProvider { CopilotGlue.effectiveProvider() }

    func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
        guard AI.enabled else {
            return AsyncThrowingStream { $0.finish(throwing: CopilotError.notConnected("ИИ выключен: включите его на странице «ИИ»")) }
        }
        let provider = self.provider
        let client: CopilotAIClient = CopilotModels.warmEnabled() ? CopilotWarmRegistry.shared.client(provider) : ColdCopilotAI(provider: provider)
        return client.stream(prompt: prompt, system: system, images: images, profile: profile)
    }

    func warmUp(system: String) async {
        guard AI.enabled, CopilotModels.warmEnabled() else { return }
        await CopilotWarmRegistry.shared.client(provider).warmUp(system: system)
    }

    func shutdown() async { await CopilotWarmRegistry.shared.shutdownAll() }
}

/// Тёплые клиенты по сервисам: переключили Codex ↔ Claude — прежний останавливается при выключении подсказчика.
final class CopilotWarmRegistry: @unchecked Sendable {
    static let shared = CopilotWarmRegistry()
    private let lock = NSLock()
    private var clients: [AIProvider: WarmCopilotAI] = [:]

    func client(_ provider: AIProvider) -> WarmCopilotAI {
        lock.lock(); defer { lock.unlock() }
        if let c = clients[provider] { return c }
        let c = WarmCopilotAI(provider: provider)
        clients[provider] = c
        return c
    }

    func shutdownAll() async {
        lock.lock(); let all = Array(clients.values); lock.unlock()
        for c in all { await c.shutdown() }
    }
}
