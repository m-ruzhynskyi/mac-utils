import Foundation

extension ShareViewer.State {
    /// Просмотр занят только пока есть подключение: окно с надписью «Трансляция завершена» ничего не держит.
    package var isConnected: Bool {
        switch self {
        case .connecting, .waiting, .watching, .reconnecting: return true
        case .idle, .ended: return false
        }
    }
}
