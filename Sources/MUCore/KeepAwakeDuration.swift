import Foundation

/// Срок работы «Не засыпать».
package enum KeepAwakeDuration: String, CaseIterable, Identifiable {
    case indefinite, hour1, hours3, hours8

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .indefinite: return "Пока не выключу"
        case .hour1: return "1 час"
        case .hours3: return "3 часа"
        case .hours8: return "8 часов"
        }
    }

    /// nil — без ограничения.
    package var seconds: TimeInterval? {
        switch self {
        case .indefinite: return nil
        case .hour1: return 3_600
        case .hours3: return 3 * 3_600
        case .hours8: return 8 * 3_600
        }
    }
}
