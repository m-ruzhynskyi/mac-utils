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
    /// `added` — когда файл попал в папку: у файлов из архивов и с серверов mtime старый, а загрузили их вчера.
    /// «Старым» файл считается, только если старыми являются обе даты (недавно добавленный или изменённый не трогаем).
    func includes(name: String, modified: Date?, added: Date? = nil, now: Date = Date()) -> Bool {
        if name.hasPrefix(".") { return false }
        guard kind == .downloads else { return true }
        guard let reference = [modified, added].compactMap({ $0 }).max() else { return false }
        return now.timeIntervalSince(reference) > 30 * 86_400
    }

    /// Ошибка чтения папки из-за защиты macOS (нет «Полного доступа к диску»), а не «папки нет».
    static func isAccessDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) { return true }
        if nsError.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(nsError.code) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error, underlying as NSError != nsError {
            return isAccessDenied(underlying)
        }
        return false
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
    /// Идёт очистка (удаление выполняется вне главного потока).
    @Published private(set) var cleaning = false
    /// Категории, которые не удалось прочитать из-за защиты macOS: пусто там — не значит «ничего нет».
    @Published private(set) var denied: Set<CleanupCategory.Kind> = []
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
        guard !scanning, !cleaning else { return }
        scanning = true
        lastResult = nil
        let categories = self.categories
        Task.detached(priority: .userInitiated) {
            var found: [CleanupItem] = []
            var denied: Set<CleanupCategory.Kind> = []
            let manager = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .addedToDirectoryDateKey]
            for category in categories {
                for folder in category.folders {
                    let entries: [URL]
                    do {
                        entries = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
                    } catch {
                        if CleanupCategory.isAccessDenied(error) { denied.insert(category.kind) }
                        continue
                    }
                    for url in entries {
                        let values = try? url.resourceValues(forKeys: Set(keys))
                        guard category.includes(name: url.lastPathComponent, modified: values?.contentModificationDate,
                                                added: values?.addedToDirectoryDate) else { continue }
                        let size = AppScanner.size(of: url)
                        guard size > 0 else { continue }
                        found.append(CleanupItem(url: url, category: category.kind, size: size))
                    }
                }
            }
            let result = found
            let deniedKinds = denied
            await MainActor.run {
                let found = result
                let model = DiskCleanupModel.shared
                model.items = found
                model.denied = deniedKinds
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

    /// Убирает отмеченное: Корзина очищается насовсем, остальное уходит в Корзину.
    /// `trash` и `remove` подменяются в тестах, чтобы не трогать настоящую Корзину.
    nonisolated static func perform(
        _ items: [CleanupItem],
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> (freed: Int64, failed: Int) {
        var freed: Int64 = 0, failed = 0
        for item in items {
            do {
                if item.category == .trash { try remove(item.url) } else { try trash(item.url) }
                freed += item.size
            } catch {
                failed += 1
            }
        }
        return (freed, failed)
    }

    /// Итог очистки: что ушло в Корзину, что удалено насовсем, сколько не вышло.
    struct Outcome: Equatable {
        var trashed: Int64 = 0
        var deleted: Int64 = 0
        var failed = 0
    }

    nonisolated static func performDetailed(
        _ items: [CleanupItem],
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> Outcome {
        var outcome = Outcome()
        for item in items {
            do {
                if item.category == .trash { try remove(item.url); outcome.deleted += item.size }
                else { try trash(item.url); outcome.trashed += item.size }
            } catch {
                outcome.failed += 1
            }
        }
        return outcome
    }

    /// Текст итога. Перенос в Корзину не освобождает место — так и называется; безвозвратное удаление — «освобождено».
    nonisolated static func resultText(_ outcome: Outcome) -> String {
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        var parts: [String] = []
        if outcome.deleted > 0 { parts.append("удалено насовсем \(size(outcome.deleted))") }
        if outcome.trashed > 0 { parts.append("перенесено в Корзину \(size(outcome.trashed)) (место освободится после её очистки)") }
        if parts.isEmpty { parts.append("ничего не убрано") }
        var text = parts.joined(separator: ", ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        if outcome.failed > 0 { text += ". Не удалось: \(outcome.failed) (файлы заняты или нет доступа)" }
        return text
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
        guard !cleaning else { return }
        cleaning = true
        // Рекурсивное удаление гигабайтов — не на главном потоке: окно остаётся живым.
        Task.detached(priority: .userInitiated) {
            let outcome = Self.performDetailed(selected)
            await MainActor.run {
                let model = DiskCleanupModel.shared
                model.lastResult = Self.resultText(outcome)
                model.cleaning = false
                model.scan()
            }
        }
    }
}

struct DiskCleanupView: View {
    @ObservedObject var model: DiskCleanupModel
    var compact = false
    @ObservedObject private var advisor = CleanupAdvisor.shared
    @AppStorage(Pref.ai) private var aiEnabled = true
    @AppStorage(Pref.aiCleanup) private var aiCleanup = true
    private var aiOn: Bool { aiEnabled && aiCleanup }

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
                if model.scanning || model.cleaning || advisor.working { ProgressView().controlSize(.small) }
                if aiOn {
                    Button {
                        advisor.review(model.items)
                        model.expanded = Set(CleanupCategory.Kind.allCases).subtracting([.trash])
                    } label: { Label(compact ? "ИИ" : "Разобрать с ИИ", systemImage: "sparkles") }
                    .disabled(model.scanning || advisor.working || model.items.isEmpty)
                    .help("Локальная модель подскажет, что безопасно удалять: зелёный — безопасно, оранжевый — осторожно, красный — лучше оставить")
                    if let progress = advisor.progress {
                        Text(progress).font(.caption).foregroundStyle(.secondary)
                    } else if let error = advisor.error {
                        Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
                    }
                    if !advisor.advice.isEmpty {
                        Button(compact ? "Безопасное" : "Отметить безопасное") {
                            model.checked = Set(model.items.filter { advisor.advice[$0.url]?.verdict == .safe }.map(\.url))
                        }
                        .help("Отметить только то, что ИИ считает безопасным")
                    }
                }
                Button(compact ? "Обновить" : "Пересканировать") { model.scan() }.disabled(model.scanning || model.cleaning)
                Button("Очистить · \(ByteCountFormatter.string(fromByteCount: model.checkedTotal, countStyle: .file))") {
                    model.clean()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.scanning || model.cleaning || model.checked.isEmpty)
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
                if model.denied.contains(category.kind) {
                    HStack(spacing: 6) {
                        Text("Нет доступа — выдайте Полный доступ к диску").font(.caption).foregroundStyle(.orange)
                        Button("Открыть") { Permissions.openFullDiskAccess() }.controlSize(.mini)
                    }
                } else if !compact {
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
            if let advice = advisor.advice[item.url] {
                Circle().fill(advice.verdict == .safe ? Color.green : advice.verdict == .careful ? .orange : .red)
                    .frame(width: 8, height: 8)
                    .help(advice.reason)
            }
            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                .help(advisor.advice[item.url]?.reason ?? item.url.path)
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
