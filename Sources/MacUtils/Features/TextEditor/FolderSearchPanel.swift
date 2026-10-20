import AppKit
import SwiftUI

/// Поиск и замена в папке: запуск в фоне, отмена, итог и список «файл: строка — фрагмент».
@MainActor
final class FolderSearchModel: ObservableObject {
    @Published var folder: URL? = UserDefaults.standard.string(forKey: Pref.editorFolderSearchPath).map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(folder?.path, forKey: Pref.editorFolderSearchPath) }
    }
    @Published var mask = UserDefaults.standard.string(forKey: Pref.editorFolderSearchMask) ?? "*.frm; *.rtf; *.txt" {
        didSet { UserDefaults.standard.set(mask, forKey: Pref.editorFolderSearchMask) }
    }
    @Published var query = ""
    @Published var replacement = ""
    @Published var options = SearchOptions()
    @Published private(set) var summary: FolderSearch.Summary?
    @Published private(set) var running = false
    @Published private(set) var error: String?
    @Published private(set) var note: String?

    private var cancel: TextSearch.Cancellation?
    private var generation = 0
    private let queue = DispatchQueue(label: "macutils.editor.folder", qos: .userInitiated)

    /// Пути открытых вкладок с несохранёнными правками (их «Заменить в папке» не трогает) и перезагрузка
    /// открытых без правок после замены — даёт окно редактора.
    var dirtyOpenFiles: () -> Set<String> = { [] }
    var reloadOpenFiles: ([URL]) -> Void = { _ in }

    var canSearch: Bool { folder != nil && !query.isEmpty && !running }

    func start() {
        guard let folder, !query.isEmpty else { return }
        stop()
        generation += 1
        let generation = self.generation
        let query = self.query, options = self.options, mask = self.mask
        let cancel = TextSearch.Cancellation(timeout: 600)
        self.cancel = cancel
        running = true
        error = nil
        note = nil
        summary = FolderSearch.Summary()
        var lastProgress: TimeInterval = 0
        queue.async { [weak self] in
            let outcome = Result {
                try FolderSearch.search(query, options: options, in: folder, mask: mask, isCancelled: { cancel.isCancelled }) { partial in
                    // Ход поиска — не чаще 10 раз в секунду.
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - lastProgress > 0.1 else { return }
                    lastProgress = now
                    let snapshot = partial
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.generation == generation, self.running else { return }
                            self.summary = snapshot
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.running = false
                    self.cancel = nil
                    switch outcome {
                    case .success(let summary): self.summary = summary
                    case .failure(TextSearch.Failure.cancelled): self.note = "Поиск остановлен"
                    case .failure(let failure): self.error = failure.localizedDescription
                    }
                }
            }
        }
    }

    func stop() {
        cancel?.cancel()
        cancel = nil
        if running {
            running = false
            note = "Поиск остановлен"
        }
        generation += 1
    }

    /// «Заменить в папке» по найденным файлам: каждый перечитывается и пишется в своей кодировке; файлы, открытые
    /// с несохранёнными правками, и те, где символа замены нет в кодировке, не трогаются.
    func replaceAll() {
        guard let summary, !summary.files.isEmpty, !running else { return }
        stop()
        generation += 1
        let generation = self.generation
        let query = self.query, template = replacement, options = self.options
        let files = summary.files.map(\.url)
        let dirty = dirtyOpenFiles()
        running = true
        note = nil
        error = nil
        queue.async { [weak self] in
            var report = FolderSearch.ReplaceReport()
            for url in files {
                if dirty.contains(url.standardizedFileURL.resolvingSymlinksInPath().path) {
                    report.openWithEdits.append(url)
                    continue
                }
                guard case .text(let data) = FolderSearch.read(url) else { report.failed.append(url); continue }
                do {
                    guard let plan = try FolderSearch.replacement(in: data, query: query, template: template, options: options) else { continue }
                    try EditorWindowController.writeFile(plan.data, to: url)
                    report.replacedFiles.append(url)
                    report.replacements += plan.count
                } catch is EditorDocument.SaveError {
                    report.unrepresentable.append(url)
                } catch {
                    report.failed.append(url)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.running = false
                    self.reloadOpenFiles(report.replacedFiles)
                    self.note = Self.describe(report)
                    self.summary = nil
                }
            }
        }
    }

    static func describe(_ report: FolderSearch.ReplaceReport) -> String {
        var parts = ["Заменено: \(report.replacements) в \(report.replacedFiles.count) \(plural(report.replacedFiles.count, "файле", "файлах", "файлах"))"]
        if !report.openWithEdits.isEmpty { parts.append("не тронуты открытые с правками: \(report.openWithEdits.count)") }
        if !report.unrepresentable.isEmpty { parts.append("нет символов в кодировке: \(report.unrepresentable.count)") }
        if !report.failed.isEmpty { parts.append("не удалось записать: \(report.failed.count)") }
        return parts.joined(separator: " · ")
    }

    var status: String {
        guard let summary else { return note ?? "" }
        var parts = ["Файлов: \(summary.scanned)", "совпадений: \(summary.matchCount)\(summary.truncated ? "+" : "") в \(summary.files.count)"]
        if summary.skippedBinary > 0 { parts.append("двоичных пропущено: \(summary.skippedBinary)") }
        if summary.skippedLarge > 0 { parts.append("больше 50 МБ: \(summary.skippedLarge)") }
        if summary.unreadable > 0 { parts.append("не прочитано: \(summary.unreadable)") }
        return parts.joined(separator: " · ")
    }
}

/// Панель «Поиск в папке» внизу окна редактора.
struct FolderSearchPanel: View {
    @ObservedObject var model: FolderSearchModel
    let open: (URL, NSRange) -> Void
    let close: () -> Void
    let confirmReplace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text("Поиск в папке").font(DS.Font.manrope(14, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
                    .accessibilityAddTraits(.isHeader)
                Button { chooseFolder() } label: {
                    Label(model.folder.map(EditorRecent.folderTitle(ofFolder:)) ?? "Выбрать папку…", systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.graphite(.secondary, size: .compact))
                .help(model.folder?.path ?? "Папка, где искать")
                TextField("Маска: *.frm; *.txt", text: $model.mask)
                    .textFieldStyle(.graphite)
                    .frame(width: 180)
                    .accessibilityLabel("Маска имён файлов")
                Spacer(minLength: 0)
                IconButton("Закрыть", systemImage: "xmark", compact: true, action: close)
            }
            HStack(spacing: DS.Space.s) {
                TextField("Найти в файлах", text: $model.query)
                    .textFieldStyle(.graphite)
                    .font(DS.Font.mono(13, relativeTo: .body))
                    .onSubmit { model.start() }
                option("Aa", "Учитывать регистр", $model.options.caseSensitive)
                option("ab", "Слово целиком", $model.options.wholeWord)
                option(".*", "Регулярное выражение", $model.options.regex)
                if model.running {
                    Button("Стоп") { model.stop() }.buttonStyle(.graphite(.secondary, size: .compact))
                } else {
                    Button("Найти") { model.start() }.buttonStyle(.graphite(.primary, size: .compact)).disabled(!model.canSearch)
                }
            }
            HStack(spacing: DS.Space.s) {
                TextField("Заменить на", text: $model.replacement)
                    .textFieldStyle(.graphite)
                    .font(DS.Font.mono(13, relativeTo: .body))
                Button("Заменить в папке…", action: confirmReplace)
                    .buttonStyle(.graphite(.secondary, size: .compact))
                    .disabled(model.running || (model.summary?.files.isEmpty ?? true))
            }
            HStack(spacing: DS.Space.s) {
                if model.running { ProgressView().controlSize(.small) }
                Text(model.error ?? model.status).font(DS.Font.rowSub)
                    .foregroundStyle(model.error == nil ? Color.dsMute : DS.Tone.danger.text).lineLimit(1)
            }
            results
        }
        .padding(DS.Space.m)
        .frame(height: 300)
        .background(Color.dsSide)
        .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 1) }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.summary?.files ?? []) { file in
                    HStack(spacing: 6) {
                        Image(systemName: DocumentTab.symbol(EditorLanguage.detect(url: file.url, head: Data()), url: file.url))
                            .font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                        Text(file.url.lastPathComponent).font(DS.Font.bodyStrong)
                        Text("\(EditorRecent.folderTitle(file.url)) · \(file.encoding.title) · \(file.matches.count)")
                            .font(DS.Font.rowSub).foregroundStyle(.dsMute).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(.dsText)
                    .padding(.top, DS.Space.xs)
                    ForEach(file.matches) { match in
                        Button { open(file.url, match.range) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                                Text("\(match.line)").font(DS.Font.mono(11, relativeTo: .caption)).foregroundStyle(.dsMute)
                                    .frame(minWidth: 36, alignment: .trailing)
                                Text(match.preview).font(DS.Font.mono(12, relativeTo: .body)).foregroundStyle(.dsText)
                                    .lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(file.url.lastPathComponent), строка \(match.line): \(match.preview)")
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func option(_ title: String, _ help: String, _ isOn: Binding<Bool>) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { isOn.wrappedValue.toggle() } label: {
            Text(title).font(DS.Font.mono(12, relativeTo: .caption))
                .foregroundStyle(isOn.wrappedValue ? Color.dsAccInk : Color.dsMute)
                .frame(width: 30, height: 30)
                .background(isOn.wrappedValue ? Color.dsAcc : Color.dsField, in: shape)
                .overlay(shape.strokeBorder(isOn.wrappedValue ? Color.clear : Color.dsLine, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Папка, в которой искать"
        if let folder = model.folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.folder = url
    }
}
