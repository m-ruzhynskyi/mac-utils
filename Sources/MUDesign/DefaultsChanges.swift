import SwiftUI

/// Перерисовать виды, когда меняются настройки (UserDefaults): например, после переназначения сочетания.
@MainActor
package final class DefaultsChanges: ObservableObject {
    package static let shared = DefaultsChanges()
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DefaultsChanges.shared.objectWillChange.send() }
        }
    }
}
