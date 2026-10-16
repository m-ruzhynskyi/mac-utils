import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// «Удаление программ»: приложение и все его файлы — в Корзину.
@MainActor
final class UninstallerModel: ObservableObject {
    static let shared = UninstallerModel()

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var appSizes: [URL: Int64] = [:]
    @Published var search = ""
    @Published private(set) var selected: InstalledApp?
    @Published private(set) var refusal: String?
    @Published private(set) var leftovers: [Leftover] = []
    @Published var checked: Set<URL> = []
    @Published private(set) var sizes: [URL: Int64] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var working = false
    /// Не удалось убрать часть файлов из-за защиты macOS — подсказка про «Полный доступ к диску».
    @Published private(set) var needsFullDiskAccess = false

    /// Для снимков интерфейса: демонстрационные данные, система не читается.
    static func demo(apps: [InstalledApp], appSizes: [URL: Int64], selected: InstalledApp?,
                     leftovers: [Leftover], sizes: [URL: Int64]) -> UninstallerModel {
        let model = UninstallerModel()
        model.apps = apps
        model.appSizes = appSizes
        model.selected = selected
        model.leftovers = leftovers
        model.sizes = sizes
        model.checked = Set(leftovers.filter(\.checkedByDefault).map(\.url))
        return model
    }

    var filtered: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
    }

    var totalChecked: Int64 {
        leftovers.filter { checked.contains($0.url) }.reduce(0) { $0 + (sizes[$1.url] ?? 0) }
    }

    func reload() {
        Task.detached(priority: .utility) {
            let installed = InstalledApp.all()
            let urls = installed.map(\.url)
            await MainActor.run { UninstallerModel.shared.apps = installed }
            for url in urls {
                let size = AppScanner.size(of: url)
                await MainActor.run { UninstallerModel.shared.appSizes[url] = size }
            }
        }
    }

    // MARK: - Выбор и поиск хвостов

    func select(url: URL) {
        guard let app = InstalledApp(url: url) else {
            refusal = "Это не приложение"
            selected = nil
            leftovers = []
            return
        }
        select(app)
    }

    func clearSelection() {
        selected = nil
        leftovers = []
        checked = []
        refusal = nil
    }

    func select(_ app: InstalledApp) {
        selected = app
        leftovers = []
        checked = []
        sizes = [:]
        needsFullDiskAccess = false
        refusal = app.refusal
        scanning = false
        guard refusal == nil else { return }
        scanning = true
        let known = apps
        // Обход Containers, Caches и т. д. — вне главного потока: выбор программы не вешает окно.
        Task.detached(priority: .userInitiated) {
            let others = known.isEmpty ? InstalledApp.all() : known
            let found = AppScanner.scan(app, others: others)
            let applied = await MainActor.run { () -> Bool in
                let model = UninstallerModel.shared
                // Пока шёл обход, пользователь мог выбрать другую программу: старый результат отбрасывается.
                guard model.selected?.url == app.url else { return false }
                model.leftovers = found
                model.checked = Set(found.filter(\.checkedByDefault).map(\.url))
                model.scanning = false
                return true
            }
            guard applied else { return }
            for url in found.filter({ !$0.sizeUnknown }).map(\.url) {
                let size = AppScanner.size(of: url)
                await MainActor.run {
                    guard UninstallerModel.shared.selected?.url == app.url else { return }
                    UninstallerModel.shared.sizes[url] = size
                }
            }
        }
    }

    // MARK: - Удаление

    func moveToTrash() {
        guard let app = selected, app.refusal == nil, !working else { return }
        let items = leftovers.filter { checked.contains($0.url) && $0.kind != .receipt }
        guard !items.isEmpty else { return }

        // Все копии: программу можно запустить несколько раз (`open -n`), и каждая держит свои файлы.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = "«\(app.name)» сейчас запущено"
            alert.informativeText = "Чтобы удалить его полностью, приложение нужно закрыть."
            alert.addButton(withTitle: "Закрыть и удалить")
            alert.addButton(withTitle: "Отмена")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            running.forEach { $0.terminate() }
            working = true
            Task { @MainActor in
                // Программа может спросить «Сохранить изменения?» — убивать её нельзя: ждём и спрашиваем пользователя.
                while true {
                    let closed = await LaunchUnload.waitForExit(attempts: 150, isTerminated: { running.allSatisfy(\.isTerminated) },
                                                                sleep: { try? await Task.sleep(nanoseconds: 100_000_000) })
                    if closed { break }
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "«\(app.name)» не закрылось"
                    alert.informativeText = "Закройте программу — возможно, есть несохранённые изменения. Затем нажмите «Подождать» или отмените удаление."
                    alert.addButton(withTitle: "Подождать")
                    alert.addButton(withTitle: "Отмена")
                    alert.addButton(withTitle: "Завершить принудительно")
                    NSApp.activate()
                    switch alert.runModal() {
                    case .alertFirstButtonReturn:
                        continue
                    case .alertThirdButtonReturn:
                        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
                        for _ in 0..<30 where !running.allSatisfy(\.isTerminated) { try? await Task.sleep(nanoseconds: 100_000_000) }
                    default:
                        self.working = false
                        return
                    }
                    break
                }
                self.trash(items, app: app)
            }
            return
        }
        working = true
        trash(items, app: app)
    }

    private func trash(_ items: [Leftover], app: InstalledApp) {
        // Службы пользователя останавливаем до переноса plist (иначе они работают до перезагрузки), вне главного потока:
        // `launchctl bootout` ждёт, пока служба завершится.
        let urls = items.map(\.url)
        let apps = items.filter { $0.kind == .app }.map(\.url)
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                // Агенты, зарегистрированные программой из своего бандла (SMAppService), тоже останавливаем.
                _ = LaunchUnload.bootoutUserServices(urls + apps.flatMap { LaunchUnload.bundledAgents(in: $0) })
            }.value
            self.trashNow(items, app: app)
        }
    }

    /// Результат удаления относится к выбранной сейчас программе, а не к той, что выбрали позже.
    nonisolated static func isStillSelected(_ selected: URL?, app: URL) -> Bool { selected == app }

    private func trashNow(_ items: [Leftover], app: InstalledApp) {
        var failed: [Leftover] = []
        var adminItems: [Leftover] = []
        for item in items {
            if item.needsAdmin {
                adminItems.append(item)
                continue
            }
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                Log.uninstall.error("Не удалось в Корзину: \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failed.append(item)
            }
        }
        if !adminItems.isEmpty, !Self.trashWithAdmin(adminItems.map(\.url)) {
            failed.append(contentsOf: adminItems)
        }

        working = false
        let removed = items.count - failed.count
        // Пока шло удаление, пользователь мог выбрать другую программу: её список не трогаем.
        let stillSelected = Self.isStillSelected(selected?.url, app: app.url)
        if failed.isEmpty {
            Toast.show("«\(app.name)» удалено: \(removed) \(plural(removed, "объект", "объекта", "объектов")) в Корзине",
                       symbol: "trash.fill", tint: .green)
            if stillSelected {
                selected = nil
                leftovers = []
            }
            reload()
        } else {
            if stillSelected {
                needsFullDiskAccess = failed.contains { $0.group == "Контейнеры" }
                leftovers = leftovers.filter { item in failed.contains(item) || item.kind == .receipt }
                checked = Set(failed.map(\.url))
            }
            Toast.show("Перемещено \(removed), не удалось \(failed.count)",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    /// Один запрос пароля администратора. Root переносит файлы не в `~/.Trash` (его контролирует пользователь:
    /// заранее созданный symlink увёл бы root-`mv` куда угодно), а в свежий каталог в sticky `/private/var/tmp`
    /// и отдаёт его пользователю; в Корзину содержимое переносится уже без root.
    private static func trashWithAdmin(_ urls: [URL]) -> Bool {
        let staging = "/private/var/tmp/MacUtilsTrash.\(UUID().uuidString)"
        let commands = adminStagingScript(urls, staging: staging)
        let script = "do shell script \(appleScriptQuote(commands)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        var ok = error == nil
        if let error { Log.uninstall.error("Админ-перемещение: \(error.description, privacy: .public)") }
        // Даже при частичном сбое то, что уже перенесено, не должно остаться в staging.
        if !finishStaging(URL(fileURLWithPath: staging)) { ok = false }
        return ok
    }

    /// Скрипт для root: создать `staging` (mkdir падает, если путь уже занят, в том числе symlink'ом),
    /// перенести файлы и отдать каталог пользователю ВСЕГДА, даже если часть переносов не удалась
    /// (иначе уже перенесённые файлы останутся запертыми в каталоге root). Любой сбой — ненулевой код выхода.
    /// Содержимое каталогов уже отдано пользователю в `adminTrashCommands`, здесь — только сам staging.
    static func adminStagingScript(_ urls: [URL], staging: String, owner: String = NSUserName(),
                                   identity: (URL) -> AdminSourceIdentity? = AdminSourceIdentity.read) -> String {
        let moves = urls.isEmpty ? ":" : adminTrashCommands(urls, trash: staging, stamp: nil, owner: owner, identity: identity)
        // Системные демоны останавливаются до переноса; сбой остановки (демон не загружен) перенос не отменяет.
        let unload = LaunchUnload.rootCommands(for: urls, quote: shellQuote)
        return "/bin/mkdir -m 700 \(shellQuote(staging)) && { \(unload)\(moves); rc=$?; "
            + "/usr/sbin/chown -h \(shellQuote(owner)) \(shellQuote(staging)); exit $rc; }"
    }

    /// Без root: содержимое staging — в Корзину, затем сам каталог удаляется. false при любой ошибке
    /// (нельзя прочитать каталог, не перенеслось, не удалился): тогда файлы остаются в staging, путь — в журнале.
    static func finishStaging(_ staging: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: staging.path) else { return true }
        let items: [URL]
        do {
            items = try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        } catch {
            Log.uninstall.error("Не удалось прочитать \(staging.path, privacy: .public), файлы могут остаться в нём: \(error.localizedDescription, privacy: .public)")
            return false
        }
        var ok = true
        for item in items {
            do { try manager.trashItem(at: item, resultingItemURL: nil) } catch {
                Log.uninstall.error("Не удалось в Корзину: \(item.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                ok = false
            }
        }
        // Если что-то осталось, каталог не трогаем: файлы остаются доступны пользователю.
        guard ok else { return false }
        do { try manager.removeItem(at: staging) } catch {
            Log.uninstall.error("Не удалось удалить \(staging.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    /// Команды sh, переносящие каждый файл в каталог `trash` (вынесено для тестов).
    /// Одноимённые файлы получают разные цели («имя stamp», «имя stamp-1»…; без stamp — «имя», «имя-1»…). Занятая цель или файл, который после
    /// `mv -n` остался на месте, — ошибка (`mv -n` сам возвращает 0, ничего не сделав).
    ///
    /// Защита от подмены пути между построением скрипта и `mv` (root переносит то, что ему подсунули):
    /// - `cd -P` в родительский каталог, затем сверка `устройство:inode` этого каталога и самого элемента с тем, что было
    ///   при построении скрипта (`identity`). `mv` и проверка, что исходник исчез, — относительно текущего каталога,
    ///   то есть уже открытого inode: подмена любого предка symlink'ом после `cd` ни на что не влияет, а до `cd` — не пройдёт сверку;
    /// - пользователю отдаются только каталоги. Файлы сохраняют владельца: удалить их из своего каталога пользователь
    ///   может и так, а жёсткая ссылка на системный файл, подложенная в переносимую папку, не станет его файлом;
    /// - смена владельца — тоже без путей: `cd -P` в `trash` (его подменить нельзя) и `find ./имя -execdir chown -h`.
    ///   find сам переходит в каждый каталог (без перехода по ссылкам, со сверкой при входе), а chown получает
    ///   только последнее имя в уже открытом каталоге. С полными путями (`-exec`) содержимое перенесённой папки,
    ///   которое пользователь меняет через заранее открытый дескриптор, могло бы подменить промежуточный каталог
    ///   symlink'ом, и chown ушёл бы в системный каталог.
    static func adminTrashCommands(_ urls: [URL], trash: String, stamp: Int?, owner: String = NSUserName(),
                                   identity: (URL) -> AdminSourceIdentity? = AdminSourceIdentity.read) -> String {
        var used: [String: Int] = [:]
        return urls.map { url -> String in
            let name = url.lastPathComponent
            let index = used[name, default: 0]
            used[name] = index + 1
            let targetName = name + (stamp.map { " \($0)" } ?? "") + (index == 0 ? "" : "-\(index)")
            let target = shellQuote("\(trash)/\(targetName)")
            let parent = shellQuote(url.deletingLastPathComponent().path)
            let source = shellQuote("./" + name)
            // Элемент пропал до построения скрипта — сверка заведомо не пройдёт.
            let expected = identity(url) ?? AdminSourceIdentity(parent: "-", item: "-")
            let check = "cd -P -- \(parent) || exit 1; "
                + "[ \"$(/usr/bin/stat -f %d:%i .)\" = \(shellQuote(expected.parent)) ] || exit 1; "
                + "[ \"$(/usr/bin/stat -f %d:%i \(source))\" = \(shellQuote(expected.item)) ] || exit 1"
            let move = "/bin/mv -n \(source) \(target) || exit 1"
            return "(if [ -e \(target) ] || [ -L \(target) ]; then exit 1; fi; \(check); \(move); "
                + "if [ -e \(source) ] || [ -L \(source) ]; then exit 1; fi; "
                + "cd -P -- \(shellQuote(trash)) || exit 1; "
                + "/usr/bin/find \(shellQuote("./" + targetName)) -type d -execdir /usr/sbin/chown -h \(shellQuote(owner)) {} +)"
        }.joined(separator: " && ")
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Что root должен застать на месте перед переносом: родительский каталог (как его откроет `cd -P`, по `stat`)
/// и сам элемент (по `lstat`, ссылка — это сама ссылка), в виде `устройство:inode`, как печатает `stat -f %d:%i`.
struct AdminSourceIdentity: Equatable {
    let parent: String
    let item: String

    static func read(_ url: URL) -> AdminSourceIdentity? {
        var info = stat()
        guard stat(url.deletingLastPathComponent().path, &info) == 0 else { return nil }
        let parent = "\(info.st_dev):\(info.st_ino)"
        guard lstat(url.path, &info) == 0 else { return nil }
        return AdminSourceIdentity(parent: parent, item: "\(info.st_dev):\(info.st_ino)")
    }
}

extension InstalledApp {
    /// Демонстрационная программа для снимков интерфейса: файлов на диске нет.
    init(demoName: String, bundleID: String) {
        url = URL(fileURLWithPath: "/demo/Applications/\(demoName).app")
        name = demoName
        self.bundleID = bundleID
        teamID = "DEMO123456"
    }
}

// MARK: - Вид (страница настроек «Удаление программ»)

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @State private var dropTargeted = false

    /// Компактно (панель из строки меню): список и подробности на одном месте, с «Назад».
    var compact = false

    var body: some View {
        Group {
            if compact {
                if model.selected != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            model.clearSelection()
                        } label: {
                            Label("Все программы", systemImage: "chevron.left")
                        }
                        .buttonStyle(.graphite(.ghost, size: .compact))
                        .padding(.horizontal, DS.Space.s)
                        .padding(.top, DS.Space.s)
                        details
                    }
                } else {
                    listColumn
                }
            } else {
                // Колонка списка тянется вместе с окном (220…340), детали занимают остальное.
                GeometryReader { geometry in
                    HStack(spacing: DS.Space.l) {
                        listColumn
                            .frame(width: min(max(geometry.size.width * 0.36, 220), 300))
                        details
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in UninstallerModel.shared.select(url: url) }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(Color.dsAccLine, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
    }

    private var listColumn: some View {
        VStack(spacing: DS.Space.s) {
            ToolsSearchField(prompt: "Поиск", text: $model.search)
                .padding(.horizontal, compact ? DS.Space.s : 0)
                .padding(.top, compact ? DS.Space.s : 0)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.filtered) { app in appRow(app) }
                }
                .padding(DS.Space.xs)
            }
            .background(compact ? Color.clear : Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                if !compact { RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1) }
            }
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let selected = model.selected?.url == app.url
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        return Button {
            model.select(app)
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable().frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
                Text(app.name).font(DS.Font.bodyStrong).foregroundStyle(selected ? Color.dsAccText : .dsText).lineLimit(1)
                Spacer(minLength: DS.Space.xs)
                Text(byteString(model.appSizes[app.url]))
                    .font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute).lineLimit(1).fixedSize()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(selected ? Color.dsField : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var details: some View {
        if let app = model.selected {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: compact ? 32 : 46, height: compact ? 32 : 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(compact ? DS.Font.headline : DS.Font.dialogTitle).foregroundStyle(.dsText)
                            .lineLimit(1).truncationMode(.tail)
                        Text(app.bundleID + (app.teamID.map { " · Team ID \($0)" } ?? ""))
                            .font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if let refusal = model.refusal {
                    Banner(.warning, title: "\(refusal) — удалять нельзя.")
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            ForEach(groups, id: \.self) { group in
                                GroupLabel(group)
                                ListCard(style: compact ? .field : .panel) {
                                    ForEach(model.leftovers.filter { $0.group == group }) { item in
                                        row(item)
                                    }
                                }
                            }
                        }
                    }
                    if model.needsFullDiskAccess {
                        Banner(.warning, title: "Контейнеры защищены macOS. Дайте Mac Utils «Полный доступ к диску».") {
                            Button("Открыть настройки") { Permissions.openFullDiskAccess() }.buttonStyle(.graphite(.primary, size: .compact))
                            Button("Перезапустить") { Permissions.relaunch() }.buttonStyle(.graphite(.secondary, size: .compact))
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            selectedTotal
                            Spacer()
                            trashButton
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            selectedTotal
                            trashButton
                        }
                    }
                }
            }
            .padding(compact ? DS.Space.m : 0)
        } else {
            emptyState
        }
    }

    private var selectedTotal: some View {
        Text("Выбрано: \(byteString(model.totalChecked))").font(DS.Font.bodyStrong).foregroundStyle(.dsText).monospacedDigit()
    }

    private var trashButton: some View {
        Button("Переместить в корзину") { model.moveToTrash() }
            .buttonStyle(.graphite(.danger))
            .disabled(model.working || !model.leftovers.contains { model.checked.contains($0.url) && $0.kind != .receipt })
    }

    private var emptyState: some View {
        EmptyState("Выберите приложение слева или перетащите .app на эту страницу", systemImage: "trash", compact: compact)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groups: [String] {
        var seen: [String] = []
        for item in model.leftovers where !seen.contains(item.group) { seen.append(item.group) }
        return seen
    }

    @ViewBuilder
    private func row(_ item: Leftover) -> some View {
        let sub = item.url.deletingLastPathComponent().path
            + (item.needsAdmin ? " · нужен пароль администратора" : "")
            + (item.shared ? " · общая папка разработчика — проверьте перед удалением" : "")
        Row(item.url.lastPathComponent, subtitle: sub, systemImage: item.kind == .receipt ? "doc.text" : nil) {
            HStack(spacing: DS.Space.s) {
                Text(item.sizeUnknown ? "—" : byteString(model.sizes[item.url]))
                    .font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute).lineLimit(1).fixedSize()
                if item.kind != .receipt {
                    Toggle(item.url.lastPathComponent, isOn: Binding(
                        get: { model.checked.contains(item.url) },
                        set: { on in if on { model.checked.insert(item.url) } else { model.checked.remove(item.url) } }
                    ))
                    .toggleStyle(.graphite)
                }
                IconButton("Показать в Finder", systemImage: "magnifyingglass", compact: true) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            }
        }
    }
}

private func byteString(_ bytes: Int64?) -> String {
    guard let bytes else { return "…" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
