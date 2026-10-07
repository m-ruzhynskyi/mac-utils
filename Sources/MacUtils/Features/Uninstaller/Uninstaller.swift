// SPDX-License-Identifier: GPL-3.0-or-later

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

    var filtered: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
    }

    var totalChecked: Int64 {
        leftovers.filter { checked.contains($0.url) }.reduce(0) { $0 + (sizes[$1.url] ?? 0) }
    }

    func reload() {
        apps = InstalledApp.all()
        let urls = apps.map(\.url)
        Task.detached(priority: .utility) {
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

    func select(_ app: InstalledApp) {
        selected = app
        leftovers = []
        checked = []
        sizes = [:]
        needsFullDiskAccess = false
        refusal = app.refusal
        guard refusal == nil else { return }
        scanning = true
        let others = apps.isEmpty ? InstalledApp.all() : apps
        let found = AppScanner.scan(app, others: others)
        leftovers = found
        checked = Set(found.filter(\.checkedByDefault).map(\.url))
        scanning = false
        let targets = found.filter { !$0.sizeUnknown }.map(\.url)
        Task.detached(priority: .userInitiated) {
            for url in targets {
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

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
            let alert = NSAlert()
            alert.messageText = "«\(app.name)» сейчас запущено"
            alert.informativeText = "Чтобы удалить его полностью, приложение нужно закрыть."
            alert.addButton(withTitle: "Закрыть и удалить")
            alert.addButton(withTitle: "Отмена")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            running.terminate()
            working = true
            Task { @MainActor in
                for _ in 0..<50 where !running.isTerminated {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if !running.isTerminated { running.forceTerminate() }
                self.trash(items, app: app)
            }
            return
        }
        working = true
        trash(items, app: app)
    }

    private func trash(_ items: [Leftover], app: InstalledApp) {
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
        if failed.isEmpty {
            Toast.show("«\(app.name)» удалено: \(removed) \(plural(removed, "объект", "объекта", "объектов")) в Корзине",
                       symbol: "trash.fill", tint: .green)
            selected = nil
            leftovers = []
            reload()
        } else {
            needsFullDiskAccess = failed.contains { $0.group == "Контейнеры" }
            leftovers = leftovers.filter { item in failed.contains(item) || item.kind == .receipt }
            checked = Set(failed.map(\.url))
            Toast.show("Перемещено \(removed), не удалось \(failed.count)",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    /// Один запрос пароля администратора: mv в Корзину пользователя.
    private static func trashWithAdmin(_ urls: [URL]) -> Bool {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        let stamp = Int(Date().timeIntervalSince1970)
        let commands = urls.map { url -> String in
            let target = "\(trash)/\(url.lastPathComponent) \(stamp)"
            return "/bin/mv -f \(shellQuote(url.path)) \(shellQuote(target))"
        }.joined(separator: " && ")
        let script = "do shell script \(appleScriptQuote(commands)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { Log.uninstall.error("Админ-перемещение: \(error.description, privacy: .public)") }
        return error == nil
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Вид (страница настроек «Удаление программ»)

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @State private var dropTargeted = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Поиск", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(model.filtered, selection: Binding(
                    get: { model.selected?.url },
                    set: { url in if let app = model.apps.first(where: { $0.url == url }) { model.select(app) } }
                )) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable().frame(width: 22, height: 22)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text(byteString(model.appSizes[app.url]))
                            .foregroundStyle(.secondary).font(.caption).monospacedDigit()
                    }
                    .tag(app.url)
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            details
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
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
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if let app = model.selected {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title2.weight(.semibold))
                        Text(app.bundleID + (app.teamID.map { " · Team ID \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let refusal = model.refusal {
                    Label("\(refusal) — удалять нельзя.", systemImage: "lock.fill").foregroundStyle(.orange)
                    Spacer()
                } else {
                    List {
                        ForEach(groups, id: \.self) { group in
                            Section(group) {
                                ForEach(model.leftovers.filter { $0.group == group }) { item in
                                    row(item)
                                }
                            }
                        }
                    }
                    if model.needsFullDiskAccess {
                        HStack {
                            Label("Контейнеры защищены macOS. Дайте Mac Utils «Полный доступ к диску».",
                                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Button("Открыть настройки") { Permissions.openFullDiskAccess() }
                            Button("Перезапустить") { Permissions.relaunch() }
                        }
                    }
                    HStack {
                        Text("Выбрано: \(byteString(model.totalChecked))").monospacedDigit()
                        Spacer()
                        Button("Переместить в корзину") { model.moveToTrash() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(model.working || !model.leftovers.contains { model.checked.contains($0.url) && $0.kind != .receipt })
                    }
                }
            }
            .padding(14)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "trash.circle").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Выберите приложение слева или перетащите .app в это окно")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var groups: [String] {
        var seen: [String] = []
        for item in model.leftovers where !seen.contains(item.group) { seen.append(item.group) }
        return seen
    }

    @ViewBuilder
    private func row(_ item: Leftover) -> some View {
        HStack(spacing: 8) {
            if item.kind == .receipt {
                Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 18)
            } else {
                Toggle("", isOn: Binding(
                    get: { model.checked.contains(item.url) },
                    set: { on in if on { model.checked.insert(item.url) } else { model.checked.remove(item.url) } }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if item.needsAdmin {
                    Text("нужен пароль администратора").font(.caption).foregroundStyle(.orange)
                }
                if item.shared {
                    Text("общая папка разработчика — проверьте перед удалением").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(item.sizeUnknown ? "—" : byteString(model.sizes[item.url]))
                .foregroundStyle(.secondary).font(.caption).monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Показать в Finder")
        }
    }
}

private func byteString(_ bytes: Int64?) -> String {
    guard let bytes else { return "…" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
