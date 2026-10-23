import AppKit
import SwiftUI
import MUCore
import MUDesign

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

    /// Для снимков интерфейса: демонстрационные записи, диск не сканируется.
    static func demo() -> DiskCleanupModel {
        let model = DiskCleanupModel()
        let home = URL(fileURLWithPath: "/demo")
        model.items = [
            CleanupItem(url: home.appendingPathComponent("Library/Caches/com.example.browser"), category: .caches, size: 820 << 20),
            CleanupItem(url: home.appendingPathComponent("Library/Caches/com.example.editor"), category: .caches, size: 310 << 20),
            CleanupItem(url: home.appendingPathComponent("Library/Logs/DiagnosticReports"), category: .logs, size: 48 << 20),
            CleanupItem(url: home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Demo-abc"), category: .xcode, size: 2_400 << 20),
            CleanupItem(url: home.appendingPathComponent("Downloads/installer.dmg"), category: .downloads, size: 540 << 20),
        ]
        model.denied = [.trash]
        model.checked = Set(model.items.filter { [.caches, .logs, .xcode].contains($0.category) }.map(\.url))
        model.expanded = [.caches]
        return model
    }

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
        ToolsPageFrame(.cleanup, compact: compact) {
            VStack(spacing: compact ? 0 : DS.Space.m) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        if !model.denied.isEmpty {
                            Banner(.warning, title: "Нет доступа — выдайте Полный доступ к диску",
                                   message: model.categories.filter { model.denied.contains($0.kind) }.map(\.title).joined(separator: ", ")) {
                                Button("Открыть") { Permissions.openFullDiskAccess() }
                                    .buttonStyle(.graphite(.primary, size: .compact))
                            }
                        }
                        ListCard(style: compact ? .field : .panel) {
                            ForEach(model.categories) { category in
                                categoryRow(category)
                                if model.expanded.contains(category.kind) {
                                    ForEach(model.items(in: category.kind)) { item in
                                        itemRow(item)
                                    }
                                }
                            }
                        }
                    }
                    .padding(compact ? DS.Space.s : 0)
                }
                if let result = model.lastResult {
                    Text(result).font(DS.Font.rowSub).foregroundStyle(.dsMute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, compact ? DS.Space.m : 0)
                        .padding(.top, compact ? DS.Space.xs : 0)
                }
                actionBar
            }
        }
        .onAppear { if model.items.isEmpty && !model.scanning { model.scan() } }
    }

    private var actionBar: some View {
        ToolsBar(compact: compact) {
            // Не помещается в одну строку (панель из строки меню, кнопки ИИ) — вторая строка, главная кнопка на всю ширину.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s) { Spacer(minLength: 0); secondaryActions; primaryAction }
                VStack(spacing: DS.Space.s) {
                    HStack(spacing: DS.Space.s) { Spacer(minLength: 0); secondaryActions }
                    primaryAction.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var primaryAction: some View {
        Button("Очистить · \(ByteCountFormatter.string(fromByteCount: model.checkedTotal, countStyle: .file))") {
            model.clean()
        }
        .buttonStyle(.graphite(.primary, size: .compact))
        .disabled(model.scanning || model.cleaning || model.checked.isEmpty)
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if model.scanning || model.cleaning || advisor.working { ProgressView().controlSize(.small) }
        if aiOn {
            Button {
                advisor.review(model.items)
                model.expanded = Set(CleanupCategory.Kind.allCases).subtracting([.trash])
            } label: { Label(compact ? "ИИ" : "Разобрать с ИИ", systemImage: "sparkles") }
            .buttonStyle(.graphite(.secondary, size: .compact))
            .disabled(model.scanning || advisor.working || model.items.isEmpty)
            .help("Локальная модель подскажет, что безопасно удалять: зелёный — безопасно, оранжевый — осторожно, красный — лучше оставить")
            if let progress = advisor.progress {
                Text(progress).font(DS.Font.rowSub).foregroundStyle(.dsMute).lineLimit(1)
            } else if let error = advisor.error {
                Text(error).font(DS.Font.rowSub).foregroundStyle(Color.dsRec).lineLimit(1)
            }
            if !advisor.advice.isEmpty {
                Button(compact ? "Безопасное" : "Отметить безопасное") {
                    model.checked = Set(model.items.filter { advisor.advice[$0.url]?.verdict == .safe }.map(\.url))
                }
                .buttonStyle(.graphite(.secondary, size: .compact))
                .help("Отметить только то, что ИИ считает безопасным")
            }
        }
        Button(compact ? "Обновить" : "Пересканировать") { model.scan() }
            .buttonStyle(.graphite(.secondary, size: .compact))
            .disabled(model.scanning || model.cleaning)
    }

    private func categoryRow(_ category: CleanupCategory) -> some View {
        let items = model.items(in: category.kind)
        let allChecked = !items.isEmpty && items.allSatisfy { model.checked.contains($0.url) }
        let expanded = model.expanded.contains(category.kind)
        return Row(category.title, subtitle: compact ? nil : category.detail, systemImage: category.symbol) {
            HStack(spacing: DS.Space.m) {
                Text(model.scanning ? "…" : ByteCountFormatter.string(fromByteCount: model.total(category.kind), countStyle: .file))
                    .font(DS.Font.mono(13, relativeTo: .callout)).foregroundStyle(.dsMute).lineLimit(1).fixedSize()
                IconButton("Показать файлы", systemImage: expanded ? "chevron.down" : "chevron.right", compact: true) {
                    if expanded { model.expanded.remove(category.kind) } else { model.expanded.insert(category.kind) }
                }
                .disabled(items.isEmpty)
                Toggle(category.title, isOn: Binding(get: { allChecked }, set: { model.setCategory(category.kind, checked: $0) }))
                    .toggleStyle(.graphite)
                    .disabled(items.isEmpty)
            }
        }
        .help(category.detail)
    }

    private func itemRow(_ item: CleanupItem) -> some View {
        let sub = advisor.advice[item.url]?.reason
        return Row(item.url.lastPathComponent, subtitle: sub) {
            HStack(spacing: DS.Space.s) {
                if let advice = advisor.advice[item.url] {
                    Circle().fill(advice.verdict == .safe ? Color.dsAccLine : advice.verdict == .careful ? Color(nsColor: DS.Palette.warn) : .dsRec)
                        .frame(width: 8, height: 8)
                }
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute).lineLimit(1).fixedSize()
                IconButton("Показать в Finder", systemImage: "magnifyingglass", compact: true) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                Toggle(item.url.lastPathComponent, isOn: Binding(
                    get: { model.checked.contains(item.url) },
                    set: { on in if on { model.checked.insert(item.url) } else { model.checked.remove(item.url) } }))
                    .toggleStyle(.graphite)
            }
        }
        .padding(.leading, compact ? 14 : 28)
        .help(advisor.advice[item.url]?.reason ?? item.url.path)
    }
}
