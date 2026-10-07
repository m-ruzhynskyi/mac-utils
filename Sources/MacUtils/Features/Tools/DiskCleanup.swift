import AppKit
import SwiftUI

/// Группа того, что можно убрать, и правила отбора (без UI — для тестов).
struct CleanupCategory: Identifiable {
    enum Kind: String, CaseIterable {
        case caches, logs, xcode, downloads, trash
    }

    let kind: Kind
    let title: String
    let detail: String
    let symbol: String
    /// Папки, содержимое которых (первый уровень) показывается по отдельности.
    let folders: [URL]
    /// Отмечать найденное по умолчанию.
    let checkedByDefault: Bool
    /// Корзина очищается безвозвратно, остальное уходит в Корзину.
    var permanent: Bool { kind == .trash }

    var id: String { kind.rawValue }

    static func all(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CleanupCategory] {
        let library = home.appendingPathComponent("Library")
        return [
            CleanupCategory(kind: .caches, title: "Кэш приложений",
                            detail: "Пересоздаётся сам. Закройте программы перед очисткой.",
                            symbol: "archivebox", folders: [library.appendingPathComponent("Caches")],
                            checkedByDefault: true),
            CleanupCategory(kind: .logs, title: "Журналы",
                            detail: "Отчёты и логи программ.",
                            symbol: "doc.text", folders: [library.appendingPathComponent("Logs")],
                            checkedByDefault: true),
            CleanupCategory(kind: .xcode, title: "Xcode",
                            detail: "DerivedData и файлы поддержки устройств — пересоздаются при сборке.",
                            symbol: "hammer",
                            folders: [library.appendingPathComponent("Developer/Xcode/DerivedData"),
                                      library.appendingPathComponent("Developer/Xcode/iOS DeviceSupport")],
                            checkedByDefault: true),
            CleanupCategory(kind: .downloads, title: "Старые загрузки",
                            detail: "Файлы в «Загрузках», не менявшиеся больше 30 дней. Проверьте перед удалением.",
                            symbol: "arrow.down.circle", folders: [home.appendingPathComponent("Downloads")],
                            checkedByDefault: false),
            CleanupCategory(kind: .trash, title: "Корзина",
                            detail: "Очищается безвозвратно.",
                            symbol: "trash", folders: [home.appendingPathComponent(".Trash")],
                            checkedByDefault: false),
        ]
    }

    /// Для «Загрузок» — только старше 30 дней; служебные .DS_Store и т. п. не показываем.
    func includes(name: String, modified: Date?, now: Date = Date()) -> Bool {
        if name.hasPrefix(".") { return false }
        guard kind == .downloads else { return true }
        guard let modified else { return false }
        return now.timeIntervalSince(modified) > 30 * 86_400
    }
}

struct CleanupItem: Identifiable, Hashable {
    let url: URL
    let category: CleanupCategory.Kind
    var size: Int64
    var id: URL { url }
}

@MainActor
final class DiskCleanupModel: ObservableObject {
    static let shared = DiskCleanupModel()

    let categories = CleanupCategory.all()
    @Published private(set) var items: [CleanupItem] = []
    @Published var checked: Set<URL> = []
    @Published private(set) var scanning = false
    @Published private(set) var lastResult: String?
    @Published var expanded: Set<CleanupCategory.Kind> = []

    func items(in kind: CleanupCategory.Kind) -> [CleanupItem] {
        items.filter { $0.category == kind }.sorted { $0.size > $1.size }
    }

    func total(_ kind: CleanupCategory.Kind, checkedOnly: Bool = false) -> Int64 {
        items(in: kind).filter { !checkedOnly || checked.contains($0.url) }.reduce(0) { $0 + $1.size }
    }

    var checkedTotal: Int64 { items.filter { checked.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func scan() {
        guard !scanning else { return }
        scanning = true
        lastResult = nil
        let categories = self.categories
        Task.detached(priority: .userInitiated) {
            var found: [CleanupItem] = []
            let manager = FileManager.default
            for category in categories {
                for folder in category.folders {
                    guard let entries = try? manager.contentsOfDirectory(
                        at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { continue }
                    for url in entries {
                        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        guard category.includes(name: url.lastPathComponent, modified: modified) else { continue }
                        let size = AppScanner.size(of: url)
                        guard size > 0 else { continue }
                        found.append(CleanupItem(url: url, category: category.kind, size: size))
                    }
                }
            }
            let result = found
            await MainActor.run {
                let found = result
                let model = DiskCleanupModel.shared
                model.items = found
                let defaults = Set(categories.filter(\.checkedByDefault).map(\.kind))
                model.checked = Set(found.filter { defaults.contains($0.category) }.map(\.url))
                model.scanning = false
            }
        }
    }

    func setCategory(_ kind: CleanupCategory.Kind, checked on: Bool) {
        for item in items(in: kind) {
            if on { checked.insert(item.url) } else { checked.remove(item.url) }
        }
    }

    /// В Корзину (или безвозвратно — для самой Корзины).
    func clean() {
        let selected = items.filter { checked.contains($0.url) }
        guard !selected.isEmpty else { return }
        if selected.contains(where: { $0.category == .trash }) {
            let alert = NSAlert()
            alert.messageText = "Очистить Корзину безвозвратно?"
            alert.informativeText = "Отмеченные файлы из Корзины будут удалены навсегда."
            alert.addButton(withTitle: "Очистить")
            alert.addButton(withTitle: "Отмена")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var freed: Int64 = 0, failed = 0
        for item in selected {
            do {
                if item.category == .trash {
                    try FileManager.default.removeItem(at: item.url)
                } else {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                }
                freed += item.size
            } catch {
                failed += 1
            }
        }
        let freedText = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
        lastResult = failed == 0
            ? "Освобождено \(freedText). Кроме Корзины, всё перемещено в Корзину — место освободится после её очистки."
            : "Освобождено \(freedText), не удалось: \(failed) (файлы заняты или нет доступа)"
        scan()
    }
}

struct DiskCleanupView: View {
    @ObservedObject var model: DiskCleanupModel
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.categories) { category in
                    categoryRow(category)
                    if model.expanded.contains(category.kind) {
                        ForEach(model.items(in: category.kind)) { item in
                            itemRow(item).padding(.leading, 30)
                        }
                    }
                }
            }
            if compact, let result = model.lastResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.top, 6)
            }
            HStack(spacing: 10) {
                if !compact, let result = model.lastResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button(compact ? "Обновить" : "Пересканировать") { model.scan() }.disabled(model.scanning)
                Button("Очистить · \(ByteCountFormatter.string(fromByteCount: model.checkedTotal, countStyle: .file))") {
                    model.clean()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.scanning || model.checked.isEmpty)
            }
            .padding(10)
        }
        .onAppear { if model.items.isEmpty && !model.scanning { model.scan() } }
    }

    private func categoryRow(_ category: CleanupCategory) -> some View {
        let items = model.items(in: category.kind)
        let allChecked = !items.isEmpty && items.allSatisfy { model.checked.contains($0.url) }
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { allChecked },
                                     set: { model.setCategory(category.kind, checked: $0) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(items.isEmpty)
            Image(systemName: category.symbol).frame(width: 20).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title).font(compact ? .callout.weight(.semibold) : .headline)
                if !compact {
                    Text(category.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(category.detail)
            Spacer(minLength: 8)
            Text(model.scanning ? "…" : ByteCountFormatter.string(fromByteCount: model.total(category.kind), countStyle: .file))
                .monospacedDigit().foregroundStyle(.secondary)
            Button {
                if model.expanded.contains(category.kind) { model.expanded.remove(category.kind) }
                else { model.expanded.insert(category.kind) }
            } label: {
                Image(systemName: model.expanded.contains(category.kind) ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(items.isEmpty)
            .help("Показать файлы")
        }
        .padding(.vertical, 4)
    }

    private func itemRow(_ item: CleanupItem) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { model.checked.contains(item.url) },
                                     set: { on in if on { model.checked.insert(item.url) } else { model.checked.remove(item.url) } }))
                .labelsHidden().toggleStyle(.checkbox)
            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Показать в Finder")
        }
    }
}
