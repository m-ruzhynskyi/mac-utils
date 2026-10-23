import AppKit
import SwiftUI
import MUCore

// MARK: - Горячие клавиши (сводный список)

/// Перерисовать виды, когда сочетания в настройках меняются (UserDefaults) или меняется их регистрация.
@MainActor
final class HotKeyPrefs: ObservableObject {
    static let shared = HotKeyPrefs()
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HotKeyPrefs.shared.objectWillChange.send() }
        }
    }

    /// Все сочетания Mac Utils как они настроены сейчас (с клавишами окон, если раскладка окон включена).
    func entries() -> [HotKeyRegistry.Entry] {
        let snap = UserDefaults.standard.bool(forKey: Pref.windowSnap) ? WindowSnapModifier.current : nil
        return HotKeyRegistry.entries(windowSnap: snap)
    }

    /// Проверка нового сочетания для `action` в записи: совпадение с другим сочетанием Mac Utils не сохраняем.
    func problem(_ combo: LayoutHotKey, for action: HotKeyAction) -> String? {
        let others = HotKeyConflicts.duplicates(of: combo, excluding: .action(action), in: entries())
        guard let first = others.first else { return nil }
        return "Уже занято: «\(first.title)»"
    }
}
