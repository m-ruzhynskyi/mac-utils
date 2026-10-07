import AppKit
import CoreAudio
import SwiftUI

/// «Громкость»: своя громкость для каждого приложения (0–150 %, выключение).
/// Перехватываются только приложения, у которых громкость не 100 % —
/// остальные звучат как обычно, без задержек и нагрузки.
@MainActor
final class AppVolume: ObservableObject {
    static let shared = AppVolume()

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var store: VolumeStore
    @Published private(set) var lastError: String?
    /// Перехват идёт, а звука нет — похоже, macOS не дала разрешение на запись звука.
    @Published private(set) var permissionSuspect = false
    @Published private(set) var isRunning = false

    private var taps: [String: VolumeTapping] = [:]
    private var listenersInstalled = false
    private var refreshTimer: Timer?
    private var silentTicks = 0
    private let hud = VolumeHUDController()

    private init() {
        store = VolumeStore(data: UserDefaults.standard.data(forKey: Pref.appVolumes))
    }

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    // MARK: - Включение

    func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.appVolume) && Self.isSupported
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.appVolume)
        guard enabled else {
            stopAll()
            refreshTimer?.invalidate()
            refreshTimer = nil
            hud.hide()
            isRunning = false
            return
        }
        let key = LayoutHotKey.load(codeKey: Pref.appVolumeKeyCode, modifiersKey: Pref.appVolumeModifiers,
                                    default: .controlOptionV)
        center.register(id: HotKeyID.appVolume, keyCode: key.keyCode, modifiers: key.modifiers) {
            AppVolume.shared.toggleHUD()
        }
        installListeners()
        if refreshTimer == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
        refresh()
        isRunning = true
    }

    // MARK: - Громкость

    func entry(for bundleID: String) -> VolumeStore.Entry { store.entry(for: bundleID) }

    func set(percent: Int? = nil, muted: Bool? = nil, for bundleID: String) {
        var entry = store.entry(for: bundleID)
        if let percent { entry.percent = percent }
        if let muted { entry.muted = muted }
        store.set(entry, for: bundleID)
        UserDefaults.standard.set(store.data, forKey: Pref.appVolumes)
        apply(bundleID)
    }

    func reset(_ bundleID: String) {
        set(percent: 100, muted: false, for: bundleID)
    }

    /// Создаёт, обновляет или убирает перехват приложения по его настройке.
    private func apply(_ bundleID: String) {
        guard #available(macOS 14.2, *) else { return }
        let entry = store.entry(for: bundleID)
        let gain = VolumeMath.gain(percent: entry.percent, muted: entry.muted)
        guard VolumeMath.needsTap(percent: entry.percent, muted: entry.muted),
              let app = apps.first(where: { $0.bundleID == bundleID }), !app.processObjects.isEmpty else {
            taps.removeValue(forKey: bundleID)?.stop()
            return
        }
        let output = CoreAudioHelper.defaultOutputDevice
        if let tap = taps[bundleID] as? AppVolumeTap, tap.processObjects == app.processObjects, tap.outputDevice == output {
            tap.gain = gain
            return
        }
        taps.removeValue(forKey: bundleID)?.stop()
        do {
            taps[bundleID] = try AppVolumeTap(bundleID: bundleID, processObjects: app.processObjects,
                                              outputDevice: output, gain: gain)
            lastError = nil
            Log.audio.info("Громкость: перехват \(bundleID, privacy: .public) \(Int(gain * 100))%")
        } catch {
            lastError = error.localizedDescription
            Log.audio.error("Громкость: \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopAll() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
    }

    // MARK: - Список и слежение

    func refresh() {
        let configured = Set(store.entries.keys)
        let list = AudioProcesses.list(including: configured)
        if list != apps {
            apps = list
            if hud.isVisible { hud.relayout() }
        }
        for bundleID in configured { apply(bundleID) }
        // Перехваты приложений, которые закрылись, убираем.
        for bundleID in taps.keys where !list.contains(where: { $0.bundleID == bundleID }) {
            taps.removeValue(forKey: bundleID)?.stop()
        }
    }

    @objc private func tick() {
        refresh()
        checkLevels()
    }

    /// Уровни перехвата: если приложение играет, а на входе тишина — нет разрешения.
    private func checkLevels() {
        guard #available(macOS 14.2, *), !taps.isEmpty else {
            silentTicks = 0
            permissionSuspect = false
            return
        }
        var anyPlaying = false, anySound = false
        for (bundleID, tap) in taps {
            guard let tap = tap as? AppVolumeTap else { continue }
            let levels = tap.takeLevels()
            if apps.first(where: { $0.bundleID == bundleID })?.isPlaying == true { anyPlaying = true }
            if levels.input > 0.0001 { anySound = true }
            if levels.input > 0 {
                Log.audio.debug("Уровень \(bundleID, privacy: .public): вход \(levels.input) → выход \(levels.output)")
            }
        }
        silentTicks = anyPlaying && !anySound ? silentTicks + 1 : 0
        let suspect = silentTicks >= 3
        if suspect != permissionSuspect { permissionSuspect = suspect }
    }

    private func installListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
            var address = CoreAudioHelper.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in
                MainActor.assumeIsolated { AppVolume.shared.refresh() }
            }
        }
    }

    // MARK: - Панель

    func toggleHUD() {
        if hud.isVisible {
            hud.hide()
        } else {
            refresh()
            hud.show()
        }
    }

    func openPrivacySettings() {
        Permissions.open(.screenRecording)
    }
}

// MARK: - Вид

/// Список приложений со звуком: ползунок, выключение, проценты.
struct AppVolumeList: View {
    @ObservedObject var model: AppVolume
    var compact = false

    var body: some View {
        if model.apps.isEmpty {
            Text("Сейчас никакое приложение не воспроизводит звук.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: compact ? 6 : 10) {
                ForEach(model.apps) { app in
                    AppVolumeRow(model: model, app: app)
                }
            }
        }
    }
}

private struct AppVolumeRow: View {
    @ObservedObject var model: AppVolume
    let app: AudioApp

    var body: some View {
        let entry = model.entry(for: app.bundleID)
        HStack(spacing: 10) {
            Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                .opacity(app.isPlaying ? 1 : 0.5)
            Text(app.name).lineLimit(1).truncationMode(.tail).frame(width: 110, alignment: .leading)
            Button {
                model.set(muted: !entry.muted, for: app.bundleID)
            } label: {
                Image(systemName: entry.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(entry.muted ? Color.red : Color.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help(entry.muted ? "Включить звук" : "Выключить звук")
            Slider(value: Binding(
                get: { Double(entry.percent) },
                set: { model.set(percent: Int($0.rounded()), for: app.bundleID) }
            ), in: 0...Double(VolumeMath.maxPercent), step: 5)
            .disabled(entry.muted)
            .frame(minWidth: 120)
            Text("\(entry.percent)%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(entry.muted ? .secondary : .primary)
                .onTapGesture(count: 2) { model.reset(app.bundleID) }
                .help("Двойной клик — 100 %")
        }
    }
}

/// Плавающая панель громкости (⌃⌥V): не активирует приложение, закрывается
/// по Esc или клику мимо.
@MainActor
final class VolumeHUDController {
    private var panel: NSPanel?
    private var outsideMonitor: Any?
    private var keyTap: EventTap?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? make()
        relayout()
        panel.orderFrontRegardless()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        let tap = EventTap(types: [.keyDown]) { [weak self] _, event in
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return true } // Esc
            self?.hide()
            return false
        }
        tap.start()
        keyTap = tap
    }

    /// Размер под текущий список; верхний край остаётся на месте.
    func relayout() {
        guard let panel, let host = panel.contentView as? NSHostingView<VolumeHUDView> else { return }
        let size = host.fittingSize
        if panel.isVisible {
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.midX - size.width / 2, y: top - size.height,
                                  width: size.width, height: size.height), display: true)
        } else if let screen = NSScreen.withMouse ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 80,
                                  width: size.width, height: size.height), display: true)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        keyTap?.stop()
        keyTap = nil
    }

    private func make() -> NSPanel {
        let host = FirstMouseHostingView(rootView: VolumeHUDView(model: .shared))
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

struct VolumeHUDView: View {
    @ObservedObject var model: AppVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(Color.accentColor)
                Text("Громкость приложений").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Esc").font(.caption).foregroundStyle(.secondary)
            }
            AppVolumeList(model: model, compact: true)
            if model.permissionSuspect {
                Text("Нет звука из перехвата — разрешите Mac Utils «Запись системного звука» в настройках конфиденциальности.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(4)
    }
}
