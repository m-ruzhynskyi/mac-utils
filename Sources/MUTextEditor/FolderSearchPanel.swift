import AppKit
import SwiftUI
import MUCore
import MUDesign

/// Поиск и замена в папке: запуск в фоне, отмена, итог и список «файл: строка — фрагмент».
/// Список всегда соответствует запросу, опциям, папке и маске, по которым он получен: при любой их смене он сбрасывается,
/// а замена идёт строго по параметрам найденного списка.
@MainActor
package final class FolderSearchModel: ObservableObject {
    @Published package var folder: URL? = UserDefaults.standard.string(forKey: Pref.editorFolderSearchPath).map { URL(fileURLWithPath: $0) } {
        didSet {
            UserDefaults.standard.set(folder?.path, forKey: Pref.editorFolderSearchPath)
            parametersChanged()
        }
    }
    @Published package var mask = UserDefaults.standard.string(forKey: Pref.editorFolderSearchMask) ?? "*.frm; *.rtf; *.txt" {
        didSet {
            UserDefaults.standard.set(mask, forKey: Pref.editorFolderSearchMask)
            parametersChanged()
        }
    }
    @Published package var query = "" { didSet { parametersChanged() } }
    @Published package var replacement = ""
    @Published package var options = SearchOptions() { didSet { parametersChanged() } }
    @Published package private(set) var summary: FolderSearch.Summary?
    @Published package private(set) var phase = Phase.idle
    @Published package private(set) var error: String?
    @Published package private(set) var note: String?

    package enum Phase { case idle, searching, replacing }

    /// По чему получен `summary`.
    package struct Key: Equatable {
        package let folder: URL
        package let mask: String
        package let query: String
        package let options: SearchOptions
    }

    private var searchedKey: Key?
    private var cancel: TextSearch.Cancellation?
    private var replaceCancel: TextSearch.Cancellation?
    private var generation = 0
    private let queue = DispatchQueue(label: "macutils.editor.folder", qos: .userInitiated)

    /// Пути открытых вкладок с несохранёнными правками (их «Заменить в папке» не трогает) и перезагрузка
    /// открытых без правок после замены — даёт окно редактора.
    package var dirtyOpenFiles: () -> Set<String> = { [] }
    package var reloadOpenFiles: ([URL]) -> Void = { _ in }

    package var running: Bool { phase != .idle }
    package var replacing: Bool { phase == .replacing }
    package var canSearch: Bool { folder != nil && !query.isEmpty && !running }

    private var currentKey: Key? {
        folder.map { Key(folder: $0, mask: mask, query: query, options: options) }
    }

    /// Заменять можно только найденное по тем же параметрам и только полный список (без «10 000+»).
    package var canReplace: Bool {
        guard phase == .idle, let summary, !summary.files.isEmpty, !summary.truncated else { return false }
        return searchedKey != nil && searchedKey == currentKey
    }

    /// Запрос, опции, папка или маска изменились — список больше не про них: сбрасываем (идущий поиск — останавливаем).
    private func parametersChanged() {
        guard phase != .replacing, let searchedKey, searchedKey != currentKey else { return }
        if phase == .searching { stop() }
        self.searchedKey = nil
        summary = nil
        note = nil
    }

    package func start() {
        guard let key = currentKey, !query.isEmpty, phase != .replacing else { return }
        stop()
        generation += 1
        let generation = self.generation
        let cancel = TextSearch.Cancellation(timeout: 600)
        self.cancel = cancel
        phase = .searching
        error = nil
        note = nil
        searchedKey = key
        summary = FolderSearch.Summary()
        var lastProgress: TimeInterval = 0
        queue.async { [weak self] in
            let outcome = Result {
                try FolderSearch.search(key.query, options: key.options, in: key.folder, mask: key.mask,
                                        isCancelled: { cancel.isCancelled }) { partial in
                    // Ход поиска — не чаще 10 раз в секунду.
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - lastProgress > 0.1 else { return }
                    lastProgress = now
                    let snapshot = partial
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.generation == generation, self.phase == .searching else { return }
                            self.summary = snapshot
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.phase = .idle
                    self.cancel = nil
                    switch outcome {
                    case .success(let summary): self.summary = summary
                    case .failure(TextSearch.Failure.cancelled):
                        self.note = "Поиск остановлен"
                        self.summary = nil
                        self.searchedKey = nil
                    case .failure(let failure):
                        self.error = failure.localizedDescription
                        self.summary = nil
                        self.searchedKey = nil
                    }
                }
            }
        }
    }

    /// «Стоп»: поиск прерывается сразу (неполный список отбрасывается); замена — после текущего файла, каждый файл
    /// пишется целиком или не пишется вовсе. Итог замены и перечитывание вкладок — в обоих случаях.
    package func stop() {
        switch phase {
        case .idle:
            break
        case .searching:
            cancel?.cancel()
            cancel = nil
            generation += 1
            phase = .idle
            note = "Поиск остановлен"
            summary = nil
            searchedKey = nil
        case .replacing:
            replaceCancel?.cancel()
            note = "Останавливаю замену…"
        }
    }

    /// «Заменить в папке» по найденным файлам — по запросу и опциям найденного списка. Каждый файл перечитывается и
    /// пишется в своей кодировке; не трогаются: открытые с несохранёнными правками, изменённые после поиска и те, где
    /// символа замены нет в кодировке.
    package func replaceAll() {
        guard canReplace, let summary, let key = searchedKey else { return }
        let template = replacement
        let files = summary.files.map { (url: $0.url, stamp: $0.stamp) }
        let dirty = dirtyOpenFiles()
        let cancel = TextSearch.Cancellation(timeout: 3_600)
        replaceCancel = cancel
        phase = .replacing
        note = nil
        error = nil
        queue.async { [weak self] in
            var report = FolderSearch.ReplaceReport()
            report.total = files.count
            for file in files {
                if cancel.isCancelled {
                    report.stopped = true
                    break
                }
                let url = file.url
                if dirty.contains(url.standardizedFileURL.resolvingSymlinksInPath().path) {
                    report.openWithEdits.append(url)
                    continue
                }
                // Изменён после поиска — найденное в списке уже не про него.
                if let stamp = file.stamp, FileStamp(url: url) != stamp {
                    report.changedSinceSearch.append(url)
                    continue
                }
                guard case .text(let data) = FolderSearch.read(url) else { report.failed.append(url); continue }
                do {
                    guard let plan = try FolderSearch.replacement(in: data, query: key.query, template: template, options: key.options,
                                                                 isCancelled: { cancel.isCancelled }) else { continue }
                    try EditorWindowController.writeFile(plan.data, to: url)
                    report.replacedFiles.append(url)
                    report.replacements += plan.count
                } catch TextSearch.Failure.cancelled {
                    // Остановили посреди файла — он не записан.
                    report.stopped = true
                    break
                } catch is EditorDocument.SaveError {
                    report.unrepresentable.append(url)
                } catch {
                    report.failed.append(url)
                }
            }
            let result = report
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.finishReplace(result)
                }
            }
        }
    }

    /// Итог замены — всегда, и после «Стоп»: вкладки уже заменённых файлов перечитываются, список сбрасывается
    /// (повторная замена по нему удвоила бы правку).
    private func finishReplace(_ report: FolderSearch.ReplaceReport) {
        phase = .idle
        replaceCancel = nil
        reloadOpenFiles(report.replacedFiles)
        summary = nil
        searchedKey = nil
        note = Self.describe(report)
    }

    package static func describe(_ report: FolderSearch.ReplaceReport) -> String {
        var parts = ["Заменено: \(report.replacements) в \(report.replacedFiles.count) \(plural(report.replacedFiles.count, "файле", "файлах", "файлах"))"]
        if report.stopped { parts[0] += " из \(report.total) — остановлено" }
        if !report.changedSinceSearch.isEmpty { parts.append("изменены после поиска, не тронуты: \(report.changedSinceSearch.count)") }
        if !report.openWithEdits.isEmpty { parts.append("не тронуты открытые с правками: \(report.openWithEdits.count)") }
        if !report.unrepresentable.isEmpty { parts.append("нет символов в кодировке: \(report.unrepresentable.count)") }
        if !report.failed.isEmpty { parts.append("не удалось записать: \(report.failed.count)") }
        return parts.joined(separator: " · ")
    }

    package var status: String {
        guard let summary else { return note ?? "" }
        var parts = ["Файлов: \(summary.scanned)", "совпадений: \(summary.matchCount)\(summary.truncated ? "+" : "") в \(summary.files.count)"]
        if summary.skippedBinary > 0 { parts.append("двоичных пропущено: \(summary.skippedBinary)") }
        if summary.skippedLarge > 0 { parts.append("больше 50 МБ: \(summary.skippedLarge)") }
        if summary.unreadable > 0 { parts.append("не прочитано: \(summary.unreadable)") }
        if summary.truncated, phase == .idle { parts.append("список неполный — сузьте поиск, чтобы заменить") }
        return parts.joined(separator: " · ")
    }
}

/// Панель «Поиск в папке» внизу окна редактора.
package struct FolderSearchPanel: View {
    @ObservedObject package var model: FolderSearchModel
    package let open: (URL, NSRange) -> Void
    package let close: () -> Void
    package let confirmReplace: () -> Void

    package var body: some View {
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
                    Button(model.replacing ? "Остановить замену" : "Стоп") { model.stop() }
                        .buttonStyle(.graphite(.secondary, size: .compact))
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
                    .disabled(!model.canReplace)
                    .help(model.canReplace ? "Заменить найденное во всех файлах списка" : "Сначала «Найти» с этим запросом и опциями")
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
