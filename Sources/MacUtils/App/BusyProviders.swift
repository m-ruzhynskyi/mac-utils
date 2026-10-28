import Foundation
import MUCore
import MUUninstaller
import MUMeetings
import MUScreenShare
import MUScreenshot

/// Что считается «занято»: подключает состояние функций к реестру из Core (сам реестр функций не знает).
extension BusyRegistry {
    /// Подключает существующее состояние приложения. Вызывается один раз при запуске.
    func installDefaultProviders() {
        setProvider(.screenRecording) { ScreenRecorder.current != nil }
        setProvider(.meetingRecording) { if case .recording = MeetingRecorder.shared.state { return true } else { return false } }
        setProvider(.meetingProcessing) { if case .processing = MeetingRecorder.shared.state { return true } else { return false } }
        setProvider(.broadcast) {
            switch ScreenShare.shared.state {
            case .connecting, .live: return true
            default: return false
            }
        }
        setProvider(.viewing) { ShareViewer.shared.state.isConnected }
        setProvider(.scrollCapture) { ScrollCapture.current != nil }
        setProvider(.steps) { StepsSession.current.map { BusyRegistry.isFresh($0.lastActivity) } ?? false }
        setProvider(.uninstalling) { UninstallerModel.shared.working }
    }
}
