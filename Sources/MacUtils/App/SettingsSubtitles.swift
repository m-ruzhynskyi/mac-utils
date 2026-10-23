import Foundation
import MUCore
import MUDesign
import MUDownloadsSorter

extension SettingsSection {
    /// Подписи страниц, зависящие от функций: у MUDesign о них знания нет.
    static func installAppSubtitles() {
        dynamicSubtitle = { section in
            switch section {
            case .panel: return "Клик по значку — панель с вкладками прямо под ним (или \(HotKeyRegistry.combo(for: .tools).title))."
            case .downloads: return "Новые файлы сами перемещаются в папки по типу: \(DownloadsRules.Category.allCases.map(\.rawValue).joined(separator: ", ")) — и по вашим правилам ниже."
            default: return nil
            }
        }
    }
}
