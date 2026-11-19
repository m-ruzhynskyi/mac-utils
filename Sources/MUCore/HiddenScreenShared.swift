import Foundation

/// Что прячет «Скрытый экран» — для других функций (HSCR-47). Пока он включён, переключатель ⌥Tab не показывает
/// эти программы (Claude, ChatGPT), а его панель не попадает в демонстрацию экрана — способ переключать программы,
/// который в звонке не виден. Заполняет движок скрытого экрана.
@MainActor
package enum HiddenScreenShared {
    package private(set) static var hiddenBundleIDs: Set<String> = []

    package static var isActive: Bool { !hiddenBundleIDs.isEmpty }

    package static func update(active: Bool, bundleIDs: [String]) {
        hiddenBundleIDs = active ? Set(bundleIDs.map { $0.lowercased() }) : []
    }

    package static func hides(_ bundleID: String?) -> Bool { hides(bundleID, in: hiddenBundleIDs) }

    nonisolated package static func hides(_ bundleID: String?, in set: Set<String>) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return set.contains(id)
    }
}
