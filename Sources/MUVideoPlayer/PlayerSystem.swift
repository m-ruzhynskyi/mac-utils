import AppKit
import IOKit.pwr_mgt
import MediaPlayer

/// Связь плеера с системой: экран не гаснет во время просмотра (своё утверждение, не «Не засыпать»),
/// медиаклавиши и «Сейчас играет». Всё это есть, только пока открыто окно плеера: закрыли последнее — снято.
@MainActor
package final class PlayerSystem {
    package static let shared = PlayerSystem()
    package static let assertionReason = "Mac Utils: просмотр видео"

    package private(set) var assertionID: IOPMAssertionID?
    package private(set) var commandTargets: [(MPRemoteCommand, Any)] = []
    package private(set) var publishesNowPlaying = false

    /// Тесты: план считается, а система (утверждения, медиаклавиши, «Сейчас играет») не трогается.
    package var integratesWithSystem = true
    /// Последний применённый план.
    package private(set) var lastPlan = Plan(preventDisplaySleep: false, remoteCommands: false)

    package var holdsAssertion: Bool { assertionID != nil }
    package var handlesRemoteCommands: Bool { !commandTargets.isEmpty }

    package struct Plan: Equatable {
        package var preventDisplaySleep: Bool
        package var remoteCommands: Bool
    }

    /// Что должно быть включено: утверждение — только пока что-то играет (и включена настройка),
    /// медиаклавиши — пока открыто хоть одно окно.
    package static func plan(openWindows: Int, playing: Bool, keepAwake: Bool) -> Plan {
        Plan(preventDisplaySleep: openWindows > 0 && playing && keepAwake, remoteCommands: openWindows > 0)
    }

    /// Окно, которым управляют медиаклавиши: играющее, иначе последнее активное.
    private var target: PlayerWindowController? {
        PlayerWindowController.windows.last { $0.model.isPlaying } ?? PlayerWindowController.current
    }

    /// Привести в соответствие с окнами (открытие, закрытие, пауза, смена файла, перемотка).
    package func update() {
        let windows = PlayerWindowController.windows
        let playing = windows.contains { $0.model.isPlaying }
        let plan = Self.plan(openWindows: windows.count, playing: playing, keepAwake: PlayerPrefs.keepAwake)
        lastPlan = plan
        guard integratesWithSystem else { return }
        setAssertion(plan.preventDisplaySleep)
        setRemoteCommands(plan.remoteCommands)
        updateNowPlaying()
    }

    private func setAssertion(_ on: Bool) {
        if on, assertionID == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.assertionReason as CFString, &id)
            if result == kIOReturnSuccess { assertionID = id }
        } else if !on, let id = assertionID {
            IOPMAssertionRelease(id)
            assertionID = nil
        }
    }

    private func setRemoteCommands(_ on: Bool) {
        let center = MPRemoteCommandCenter.shared()
        if on, commandTargets.isEmpty {
            func add(_ command: MPRemoteCommand, _ handler: @escaping @MainActor (MPRemoteCommandEvent) -> Bool) {
                command.isEnabled = true
                let token = command.addTarget { event in
                    MainActor.assumeIsolated { handler(event) ? .success : .noActionableNowPlayingItem }
                }
                commandTargets.append((command, token))
            }
            add(center.togglePlayPauseCommand) { [weak self] _ in self?.target.map { $0.model.togglePlay(); return true } ?? false }
            add(center.playCommand) { [weak self] _ in self?.target.map { $0.model.play(); return true } ?? false }
            add(center.pauseCommand) { [weak self] _ in self?.target.map { $0.model.pause(); return true } ?? false }
            add(center.nextTrackCommand) { [weak self] _ in self?.target.map { $0.model.next(); return true } ?? false }
            add(center.previousTrackCommand) { [weak self] _ in self?.target.map { $0.model.previous(); return true } ?? false }
            add(center.changePlaybackPositionCommand) { [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent, let target = self?.target else { return false }
                target.model.seek(to: event.positionTime)
                return true
            }
        } else if !on, !commandTargets.isEmpty {
            for (command, token) in commandTargets {
                command.removeTarget(token)
                command.isEnabled = false
            }
            commandTargets = []
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let target, target.model.phase == .ready else {
            if publishesNowPlaying {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
                publishesNowPlaying = false
            }
            return
        }
        let model = target.model
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: model.info.title,
            MPMediaItemPropertyPlaybackDuration: model.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: model.isPlaying ? Double(model.effectiveRate) : 0,
            MPNowPlayingInfoPropertyMediaType: model.info.hasVideo ? MPNowPlayingInfoMediaType.video.rawValue
                : MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        center.playbackState = model.isPlaying ? .playing : .paused
        publishesNowPlaying = true
    }
}
