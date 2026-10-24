import AppKit
import Carbon.HIToolbox
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import MUCore
import MUDesign

/// Состояние интерфейса одного окна: режимы, меню, подсказки поверх видео, тосты.
@MainActor
final class PlayerUIState: ObservableObject {
    enum Menu: Equatable { case subtitles, audio, speed }

    enum HUD: Equatable {
        /// Шаг по кадрам (v08b): «Кадр 33 365 · 00:23:10:05 · пауза».
        case frame(number: Int, timecode: String)
        /// Удержание → (v14b): «2× ▸▸ пока держите →».
        case boost
        case volume(Int, muted: Bool)
        case rate(String)
        case subtitleDelay(String)
        case message(String)
    }

    @Published var playlistVisible = false
    @Published var videoOnly = false
    @Published var fullScreen = false
    /// Плавающая панель и курсор в полном экране и в режиме «Только видео».
    @Published var chromeVisible = true
    @Published var menu: Menu?
    @Published var hud: HUD?
    /// Подсказка двойного клика у края (v14b): «‹‹ 20 с».
    @Published var seekHint: (zone: ClickZone, seconds: Int)?
    /// Шаг назад на длинном GOP идёт дольше 200 мс — индикатор.
    @Published var stepping = false

    /// Тост «Кадр сохранён» (v08c).
    @Published var snapshot: PlayerSnapshot.Result?
    /// Мышь недавно двигалась над видео: кнопка «Пропустить…» возвращается вместе с панелью.
    @Published var pointerActive = false

    private var hudWork: DispatchWorkItem?
    private var hintWork: DispatchWorkItem?
    private var snapshotWork: DispatchWorkItem?
    private var pointerWork: DispatchWorkItem?

    /// Панель прикреплена под видео (окно) или плавает поверх (полный экран, «Только видео»).
    var floatingChrome: Bool { fullScreen || videoOnly }

    func flash(_ hud: HUD, for seconds: Double = 1.4) {
        self.hud = hud
        hudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hud = nil }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Подсказка без срока (удержание →) — снимается `clearHUD`.
    func show(_ hud: HUD) {
        hudWork?.cancel()
        self.hud = hud
    }

    func clearHUD(_ hud: HUD? = nil) {
        guard hud == nil || self.hud == hud else { return }
        hudWork?.cancel()
        self.hud = nil
    }

    func hint(_ zone: ClickZone, seconds: Int) {
        seekHint = (zone, seconds)
        hintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.seekHint = nil }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func pointerMoved() {
        if !pointerActive { pointerActive = true }
        pointerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pointerActive = false }
        pointerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func showSnapshot(_ result: PlayerSnapshot.Result) {
        snapshot = result
        snapshotWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.snapshot = nil }
        snapshotWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Отменить отложенное (окно закрыли): после закрытия ничего не срабатывает.
    func reset() {
        hudWork?.cancel()
        hintWork?.cancel()
        snapshotWork?.cancel()
        snapshot = nil
        pointerWork?.cancel()
        pointerActive = false
        hud = nil
        seekHint = nil
        menu = nil
        stepping = false
    }
}

/// Окно плеера. Одно окно с плейлистом (решение 3 макетов); ⌥⌘O — ещё одно, чтобы смотреть два видео рядом.
/// Пока открыто хоть одно окно, Mac Utils — обычное приложение со значком в Dock; закрыли последнее — снова фоновое.
/// Всё, что окно запустило (наблюдатели, отложенные подсказки, утверждения питания), снимается при закрытии.
@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    /// Открытые окна; последнее активное — в конце.
    private(set) static var windows: [PlayerWindowController] = []

    static var anyOpen: Bool { windows.contains { $0.window.isVisible } }
    static var isKey: Bool { windows.contains { $0.window.isKeyWindow } }
    static var current: PlayerWindowController? { windows.first { $0.window.isKeyWindow } ?? windows.last }
    /// Значок в Dock (подменяется в тестах: процесс тестов не трогает свою политику активации).
    static var syncDock: (Bool) -> Void = { AppRouter.shared.syncDock(nil, $0) }

    let model: PlayerModel
    let ui = PlayerUIState()
    let window: PlayerWindow
    private var hold = HoldToFastForward()
    private var holdWork: DispatchWorkItem?
    private var holdWasPaused = false
    private var clicks = ClickSeries()
    private var chromeWork: DispatchWorkItem?
    private var closing = false

    // MARK: - Точки входа

    /// Показать плеер: последнее окно или новое пустое (v07).
    static func show() {
        (current ?? PlayerWindowController()).present()
    }

    /// Открыть файлы: в текущем окне (после текущего файла) или в новом.
    static func open(_ urls: [URL], newWindow: Bool = false) {
        let media = PlayerMedia.expand(urls)
        let subtitles = urls.filter(PlayerMedia.isSubtitle)
        guard !media.isEmpty || !subtitles.isEmpty else { return }
        let controller = newWindow ? PlayerWindowController() : (current ?? PlayerWindowController())
        controller.present()
        if !media.isEmpty { controller.model.open(media) }
        for url in subtitles { controller.model.subtitles.addExternal(url) }
    }

    /// «Открыть…» (⌘O) или «Открыть в новом окне…» (⌥⌘O).
    static func openPanel(newWindow: Bool = false) {
        let controller = newWindow ? PlayerWindowController() : (current ?? PlayerWindowController())
        controller.present()
        controller.runOpenPanel { controller.model.open($0) }
    }

    /// Перетаскивание на вкладку панели 🔧.
    static func openDropped(_ providers: [NSItemProvider]) {
        loadURLs(providers) { open($0) }
    }

    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let collected = UncheckedBox<[Int: URL]>([:])
        for (index, provider) in providers.enumerated() where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { collected.value[index] = url }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let urls = collected.value.sorted { $0.key < $1.key }.map(\.value)
            MainActor.assumeIsolated { completion(urls) }
        }
    }

    // MARK: - Окно

    override convenience init() {
        self.init(model: PlayerModel())
    }

    init(model: PlayerModel) {
        self.model = model
        window = PlayerWindow.make()
        super.init()
        window.controller = self
        window.delegate = self
        let root = PlayerRootView(model: model, clock: model.clock, ui: ui, controller: self)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 960, height: 600))
        if Self.windows.isEmpty, window.setFrameUsingName(PlayerWindow.autosaveName) {
            // Первое окно — где было; следующие — со сдвигом, чтобы не закрывать первое.
        } else if let last = Self.windows.last?.window {
            window.setFrame(last.frame.offsetBy(dx: 30, dy: -30), display: false)
        } else {
            window.center()
        }
        model.onItemChange = { [weak self] in self?.itemChanged() }
        model.onPlayingChange = { [weak self] playing in self?.playingChanged(playing) }
        model.onTimingChange = { PlayerSystem.shared.update() }
        Self.windows.append(self)
    }

    func present() {
        // Закрытое окно не возвращаем (его виды уже отпущены) — показываем другое или новое.
        guard !closing else { return Self.show() }
        let wasVisible = window.isVisible
        if !wasVisible, !Self.anyOpen { FocusReturn.remember() }
        Self.syncDock(true)
        ScreenOutput.activateApp()
        window.makeKeyAndOrderFrontOnScreen("Окно плеера")
        window.centerTrafficLights()
        window.focusVideo()
        Self.windows.removeAll { $0 === self }
        Self.windows.append(self)
    }

    private func runOpenPanel(_ completion: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audiovisualContent]
        panel.message = "Видео и звук: MP4, MOV, M4V, MP3, M4A… Папка — все файлы по порядку"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { completion(urls) }
        }
    }

    private func itemChanged() {
        window.title = model.info.title.isEmpty ? "Видеоплеер" : model.info.title
        window.representedURL = model.currentURL
        ui.reset()
        PlayerSystem.shared.update()
    }

    private func playingChanged(_ playing: Bool) {
        PlayerSystem.shared.update()
        if playing, ui.floatingChrome { scheduleChromeHide() }
        if !playing { showChrome(autoHide: false) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window.centerTrafficLights()
        Self.windows.removeAll { $0 === self }
        Self.windows.append(self)
        PlayerSystem.shared.update()
    }

    func windowDidResignKey(_ notification: Notification) {
        endHold()
        window.centerTrafficLights()
    }

    func windowDidResize(_ notification: Notification) { window.centerTrafficLights() }

    func windowWillEnterFullScreen(_ notification: Notification) {
        ui.fullScreen = true
        ui.menu = nil
        scheduleChromeHide()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        ui.fullScreen = false
        showChrome(autoHide: false)
        window.centerTrafficLights()
    }

    /// Окно закрыто насовсем: контроллер больше не показывается (возврат из PiP его не оживит).
    var isClosed: Bool { closing }

    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }
        closing = true
        // PiP не переживает окно: иначе в нём остался бы пустой плеер, а возврат из PiP открыл бы закрытое окно.
        window.videoView?.stopPictureInPicture()
        endHold()
        chromeWork?.cancel()
        ui.reset()
        NSCursor.setHiddenUntilMouseMoves(false)
        // Звук стихает сразу, место запоминается, наблюдатели снимаются.
        model.shutdown()
        if Self.windows.count == 1 { window.saveFrame(usingName: PlayerWindow.autosaveName) }
        Self.windows.removeAll { $0 === self }
        PlayerSystem.shared.update()
        if Self.windows.isEmpty { PlayerMediaInfoCache.shared.clear() }
        // Виды держат контроллер (`PlayerRootView.controller`), а окно — виды: без этого закрытое окно
        // с моделью, AVPlayer и слоем жили бы до выхода из программы.
        window.contentView = nil
        DispatchQueue.main.async {
            Self.syncDock(Self.anyOpen)
            if !Self.anyOpen, !AppRouter.shared.settingsVisible() { FocusReturn.restore() }
        }
    }

    // MARK: - Полоса и курсор

    /// Мышь двинулась над видео: показать плавающую панель (и курсор); в полном экране — спрятать через 2 с.
    func mouseMoved() {
        ui.pointerMoved()
        guard ui.floatingChrome else { return }
        showChrome(autoHide: true)
    }

    func showChrome(autoHide: Bool) {
        if !ui.chromeVisible { ui.chromeVisible = true }
        window.setTrafficLightsHidden(ui.videoOnly && !ui.fullScreen && !ui.chromeVisible)
        chromeWork?.cancel()
        if autoHide { scheduleChromeHide() }
    }

    private func scheduleChromeHide() {
        chromeWork?.cancel()
        guard ui.floatingChrome else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ui.floatingChrome, self.model.isPlaying, self.ui.menu == nil, !self.window.isMouseOverControls else { return }
            self.ui.chromeVisible = false
            self.window.setTrafficLightsHidden(self.ui.videoOnly && !self.ui.fullScreen)
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        chromeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func toggleVideoOnly() {
        guard !ui.fullScreen else { return }
        ui.videoOnly.toggle()
        ui.chromeVisible = !ui.videoOnly
        window.setTrafficLightsHidden(ui.videoOnly)
        if ui.videoOnly { scheduleChromeHide() } else { chromeWork?.cancel() }
    }

    func toggleFullScreen() { window.toggleFullScreen(nil) }

    // MARK: - Клики по видео

    func videoClicked(count: Int, x: CGFloat, width: CGFloat) {
        guard model.phase == .ready else { return }
        if ui.menu != nil {
            ui.menu = nil
            return
        }
        let zone = ClickZone.at(x: x, width: width)
        for action in clicks.click(count: count, zone: zone, playing: model.isPlaying) {
            switch action {
            case .togglePlay: model.togglePlay()
            case .restore(let playing): playing ? model.play() : model.pause()
            case .seek(let delta): model.seek(by: delta)
            case .hint(let zone, let seconds): ui.hint(zone, seconds: seconds)
            case .fullScreen: toggleFullScreen()
            }
        }
    }

    // MARK: - Клавиши

    /// Клавиша в окне плеера; `false` — не наша, пусть идёт дальше.
    func handleKey(_ event: NSEvent) -> Bool {
        let keyCode = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection(PlayerShortcuts.relevantModifiers)
        let now = event.timestamp
        // Отпускание → — по коду клавиши, без модификаторов: отпустили → с зажатым ⇧ — удержание всё равно кончается.
        if event.type == .keyUp, keyCode == kVK_RightArrow, hold.pressedAt != nil {
            handleHold(hold.keyUp(at: now))
            return true
        }
        guard let action = PlayerShortcuts.action(keyCode: keyCode, modifiers: modifiers) else { return false }
        if event.type == .keyUp { return false }
        if action == .seekForward {
            handleHold(hold.keyDown(at: now, isRepeat: event.isARepeat))
            if !event.isARepeat, hold.pressedAt != nil {
                holdWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.handleHold(self.hold.tick(at: ProcessInfo.processInfo.systemUptime))
                }
                holdWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + HoldToFastForward.threshold, execute: work)
            }
            return true
        }
        // Повторы при удержании — только там, где это перемотка или громкость.
        let repeats: Set<PlayerAction> = [.seekBackward, .seekBackwardMinute, .seekForwardMinute, .jumpBackward, .jumpForward,
                                          .volumeUp, .volumeDown, .frameBackward, .frameForward, .subtitlesEarlier, .subtitlesLater]
        if event.isARepeat, !repeats.contains(action) { return true }
        perform(action)
        return true
    }

    private func handleHold(_ event: HoldToFastForward.Event) {
        switch event {
        case .none: break
        case .seekForward: perform(.seekForward)
        case .beginHold:
            guard model.phase == .ready else { return }
            let plan = HoldToFastForward.boost(rate: model.rate, playing: model.isPlaying)
            holdWasPaused = plan.play
            if let rate = plan.rate { model.setBoost(rate) }
            if plan.play { model.play() }
            ui.show(.boost)
        case .endHold:
            model.setBoost(nil)
            if holdWasPaused { model.pause() }
            holdWasPaused = false
            ui.clearHUD(.boost)
        }
    }

    private func endHold() {
        holdWork?.cancel()
        handleHold(hold.cancel())
    }

    func perform(_ action: PlayerAction) {
        let ready = model.phase == .ready
        switch action {
        case .togglePlay: model.togglePlay()
        case .seekBackward: if ready { model.seek(by: -PlayerPrefs.seekStep) }
        case .seekForward: if ready { model.seek(by: PlayerPrefs.seekStep) }
        case .seekBackwardMinute: if ready { model.seek(by: -60) }
        case .seekForwardMinute: if ready { model.seek(by: 60) }
        case .jumpBackward: if ready { model.seek(by: -10) }
        case .jumpForward: if ready { model.seek(by: 10) }
        case .frameBackward, .frameForward:
            guard ready, model.info.hasVideo else { return }
            stepFrame(forward: action == .frameForward)
        case .volumeUp, .volumeDown:
            model.isMuted = false
            model.volume = min(1, max(0, ((model.volume + (action == .volumeUp ? 0.05 : -0.05)) * 20).rounded() / 20))
            ui.flash(.volume(Int((model.volume * 100).rounded()), muted: false))
        case .mute:
            model.isMuted.toggle()
            ui.flash(.volume(Int((model.volume * 100).rounded()), muted: model.isMuted))
        case .slower, .faster:
            model.stepRate(action == .faster ? 1 : -1)
            ui.flash(.rate(PlaybackRate.title(model.rate)))
        case .skip: model.skip.skipCurrent()
        case .undoSkip: model.skip.undo()
        case .snapshot: if ready { PlayerSnapshot.take(from: self) }
        case .subtitlesMenu: toggleMenu(.subtitles)
        case .audioMenu: toggleMenu(.audio)
        case .subtitlesEarlier, .subtitlesLater:
            model.subtitles.shiftDelay(action == .subtitlesLater ? 0.1 : -0.1)
            ui.flash(.subtitleDelay(model.subtitles.delayTitle))
        case .fullScreen: toggleFullScreen()
        case .exitFullScreen:
            if ui.menu != nil { ui.menu = nil } else if model.skip.cancelCountdown() {
                // Esc на отсчёте «Следующая серия» — смотреть титры.
            } else if ui.fullScreen { toggleFullScreen() } else if ui.videoOnly { toggleVideoOnly() }
        case .videoOnly: toggleVideoOnly()
        case .pictureInPicture: window.videoView?.togglePictureInPicture()
        case .playlist: ui.playlistVisible.toggle()
        case .restart: if ready { model.restartFromBeginning() }
        case .open: Self.openPanel()
        case .openInNewWindow: Self.openPanel(newWindow: true)
        }
        if ui.floatingChrome, action != .togglePlay { showChrome(autoHide: true) }
    }

    func toggleMenu(_ menu: PlayerUIState.Menu) {
        guard model.phase == .ready else { return }
        ui.menu = ui.menu == menu ? nil : menu
        if ui.floatingChrome { showChrome(autoHide: false) }
    }

    /// `,` и `.`: кадр на паузе; подсказка v08b. Долгий шаг назад (длинный GOP) — индикатор через 200 мс.
    private func stepFrame(forward: Bool) {
        let before = model.frameNumber
        model.stepFrame(forward: forward)
        let started = Date()
        let indicator = DispatchWorkItem { [weak self] in self?.ui.stepping = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: indicator)
        Task { @MainActor [weak self] in
            // Номер кадра меняется, когда AVPlayer дошёл до него.
            for _ in 0..<100 {
                guard let self else { return }
                if self.model.frameNumber != before || Date().timeIntervalSince(started) > 2 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            indicator.cancel()
            guard let self else { return }
            self.ui.stepping = false
            self.ui.flash(.frame(number: self.model.frameNumber,
                                 timecode: PlayerFormat.timecode(self.model.currentTime, fps: self.model.info.fps)), for: 2)
        }
    }

    // MARK: - Перетаскивание

    /// Файлы на окно: видео — в плейлист после текущего, субтитры — к текущему видео.
    /// Сначала видео (его открытие сбрасывает субтитры прежнего файла), потом субтитры — к нему.
    func dropped(_ urls: [URL]) {
        let media = PlayerMedia.expand(urls.filter { !PlayerMedia.isSubtitle($0) })
        if !media.isEmpty { model.open(media) }
        for url in urls.filter(PlayerMedia.isSubtitle) { model.subtitles.addExternal(url) }
    }

    /// «Открыть в другой программе…» на экране неподдерживаемого формата.
    func openElsewhere(_ url: URL) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = "Выберите программу для «\(url.lastPathComponent)»"
        panel.prompt = "Открыть"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Значение, которое меняется из колбэков на главной очереди.
final class UncheckedBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Окно

/// Окно плеера: без полосы заголовка (её рисует `PlayerRootView`), «светофор» по центру полосы 50 pt.
/// Клавиши плеера разбираются здесь, до SwiftUI: так они работают, на чём бы ни стоял фокус (кроме полей ввода).
final class PlayerWindow: NSWindow {
    static let autosaveName = "MacUtilsPlayer"
    static let titleBarHeight: CGFloat = 50

    weak var controller: PlayerWindowController?
    weak var videoView: PlayerVideoView?
    /// Курсор над плавающей панелью: её не прячем.
    var isMouseOverControls = false

    static func make() -> PlayerWindow {
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.title = "Видеоплеер"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 560, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        return window
    }

    func focusVideo() {
        if let videoView { makeFirstResponder(videoView) }
    }

    /// Поле ввода в фокусе — клавиши ему, а не плееру.
    private var typing: Bool {
        guard let responder = firstResponder else { return false }
        return responder is NSText || responder is NSTextField || responder is NSSearchField
    }

    /// Фокус на кнопке (полный доступ с клавиатуры): ↩ и пробел нажимают её.
    private var focusOnControl: Bool {
        guard let responder = firstResponder else { return false }
        return !(responder === self || responder === contentView || responder === videoView)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp:
            let activatesControl = [kVK_Return, kVK_Space, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode))
            if !typing, !(activatesControl && focusOnControl), !event.modifierFlags.contains(.command),
               MainActor.assumeIsolated({ controller?.handleKey(event) ?? false }) {
                return
            }
        case .leftMouseDown where event.clickCount == 2 && isInTitleBar(event):
            // Двойной клик по заголовку — режим «Только видео» (вместо увеличения окна).
            MainActor.assumeIsolated { controller?.toggleVideoOnly() }
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    /// ⌘-сочетания плеера (⌘L, ⌘O, ⌥⌘O, ⌘Z, ⌃⌘T) — раньше главного меню: там ⌘O открывает редактор.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, !typing, event.modifierFlags.contains(.command),
           MainActor.assumeIsolated({ controller?.handleKey(event) ?? false }) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func isInTitleBar(_ event: NSEvent) -> Bool {
        guard !styleMask.contains(.fullScreen), let contentView else { return false }
        let point = event.locationInWindow
        guard point.y >= contentView.bounds.height - Self.titleBarHeight else { return false }
        // Не по «светофору» и не по кнопкам справа.
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
        if buttons.contains(where: { $0.convert($0.bounds, to: nil).insetBy(dx: -4, dy: -4).contains(point) }) { return false }
        return point.x > 100 && point.x < contentView.bounds.width - 100
    }

    /// Кнопки окна — по центру полосы заголовка (как у редактора), а не у верхнего края.
    func centerTrafficLights() {
        guard !styleMask.contains(.fullScreen), let close = standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        let height = Self.titleBarHeight
        var frame = container.frame
        frame.size.height = height
        frame.origin.y = self.frame.height - height
        container.frame = frame
        titlebar.frame = container.bounds
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 20 + CGFloat(index) * 20, y: (height - button.frame.height) / 2))
        }
    }

    func setTrafficLightsHidden(_ hidden: Bool) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(type)?.isHidden = hidden
        }
    }
}
