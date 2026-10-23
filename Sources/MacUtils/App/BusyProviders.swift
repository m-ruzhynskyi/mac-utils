import Foundation
import MUCore
import MUUninstaller
import MUMeetings

/// Что считается «занято»: подключает состояние функций к реестру из Core (сам реестр функций не знает).
extension BusyRegistry {
    /// Просмотр занят только пока есть подключение: окно с надписью «Трансляция завершена» ничего не держит.
    static func viewerIsConnected(_ state: ShareViewer.State) -> Bool {
        switch state {
        case .connecting, .waiting, .watching, .reconnecting: return true
        case .idle, .ended: return false
        }
    }

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
        setProvider(.viewing) { BusyRegistry.viewerIsConnected(ShareViewer.shared.state) }
        setProvider(.scrollCapture) { ScrollCapture.current != nil }
        setProvider(.steps) { StepsSession.current.map { BusyRegistry.isFresh($0.lastActivity) } ?? false }
        setProvider(.uninstalling) { UninstallerModel.shared.working }
    }
}
