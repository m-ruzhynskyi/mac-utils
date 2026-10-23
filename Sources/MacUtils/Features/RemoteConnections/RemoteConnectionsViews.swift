import MURemoteConnections
import SwiftUI

// MARK: - Части строки

extension RemoteProgram {
    var shortTitle: String { self == .anyDesk ? "AD" : "TV" }
    var dot: Color { self == .anyDesk ? Color(nsColor: DS.rgb(0xE8523F)) : .dsBlue }
}

/// Капсула программы «● AD» / «● TV» (логотипы не копируем).
struct RemoteProgramBadge: View {
    let program: RemoteProgram
    var dimmed = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(program.dot).frame(width: 6, height: 6)
            Text(program.shortTitle).font(DS.Font.keycapCompact).foregroundStyle(.dsText)
        }
        .padding(.vertical, 3).padding(.horizontal, 7)
        .background(Color.dsPanel, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
        .opacity(dimmed ? DS.State.disabledOpacity : 1)
        .help(dimmed ? "\(program.title) не установлен" : program.title)
        .accessibilityLabel(program.title)
    }
}

/// Значок ключа: пароль в файле есть или нет. Сам пароль нигде не показывается.
struct RemotePasswordBadge: View {
    let has: Bool

    var body: some View {
        Image(systemName: has ? "key.fill" : "key.slash")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(has ? Color.dsAccText : Color.dsMute)
            .frame(width: 26, height: 26)
            .background(Color.dsPanel, in: Circle())
            .overlay(Circle().strokeBorder(has ? Color.dsAccLine : Color.dsLine, lineWidth: 1))
            .help(has ? "Пароль есть в файле" : "В файле нет пароля — введите вручную")
            .accessibilityLabel(has ? "Пароль есть" : "Пароля нет")
    }
}

/// Текст с подсвеченными совпадениями поиска.
private func highlighted(_ text: String, _ ranges: [Range<String.Index>]) -> AttributedString {
    var out = AttributedString(text)
    for r in ranges {
        guard let lo = AttributedString.Index(r.lowerBound, within: out),
              let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
        out[lo..<hi].foregroundColor = .dsAccText
        out[lo..<hi].underlineStyle = .single
    }
    return out
}

/// Строка записи: значок, название, ID (и группа), программа, ключ, звезда; выбранная — с ↩.
struct RemoteRow: View {
    let record: ConnectionRecord
    let program: RemoteProgram
    var query = ""
    var selected = false
    var showGroup = false
    var favorite = false
    var dimmed = false
    var onFavorite: () -> Void
    var onConnect: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        HStack(spacing: 12) {
            RowTile(systemImage: "display", kind: selected ? .accent : .neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(record.name, ConnectionSearch.highlights(in: record.name, query: query)))
                    .font(DS.Font.rowTitle).foregroundStyle(.dsText).lineLimit(1)
                HStack(spacing: 6) {
                    Text(highlighted(record.displayID, ConnectionSearch.highlightsInID(record.displayID, query: query)))
                        .font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsText)
                    if showGroup, !record.group.isEmpty {
                        Text("· \(record.group)").font(DS.Font.rowSub).foregroundStyle(.dsMute).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            RemoteProgramBadge(program: program, dimmed: dimmed)
            RemotePasswordBadge(has: record.hasPassword)
            Button(action: onFavorite) {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(favorite ? Color.dsAccText : Color.dsMute)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(favorite ? "Убрать из избранного" : "В избранное")
            if selected { Keycap(["↩"], compact: true, onPanel: true) }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(selected ? Color.dsPanel : .clear, in: shape)
        .overlay(shape.strokeBorder(selected ? Color.dsAccLine : .clear, lineWidth: selected ? DS.State.focusRing : 0))
        .contentShape(shape)
        .onTapGesture(count: 2, perform: onConnect)
        .opacity(dimmed ? 0.75 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Подключиться", onConnect)
    }
}

struct RemoteSectionLabel: View {
    let title: String
    let symbol: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.dsAccText)
            Text(title.uppercased()).font(DS.Font.groupLabel).tracking(DS.Font.tracking(0.12, size: 11)).foregroundStyle(.dsMute)
            if let count { Text("\(count)").font(DS.Font.keycapCompact).foregroundStyle(.dsMute) }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, DS.Space.s)
        .accessibilityAddTraits(.isHeader)
    }
}

extension ConnectionSection {
    var title: String {
        switch kind {
        case .favorites: return "Избранное"
        case .recents: return "Недавние"
        case .group(let name): return name
        case .ungrouped: return "Без группы"
        case .results: return "Найдено"
        }
    }

    var symbol: String {
        switch kind {
        case .favorites: return "star.fill"
        case .recents: return "clock"
        case .group, .ungrouped: return "folder"
        case .results: return "magnifyingglass"
        }
    }
}

/// Поле поиска с подсказкой клавиши и плашкой раскладки («ctdth → север»).
struct RemoteSearchField: View {
    @Binding var text: String
    var placeholder = "Название, ID, группа, тег…"
    var large = false
    var hint: ConnectionSearch.LayoutHint?
    var programPill: String?
    var focused: FocusState<Bool>.Binding
    var trailingKeys: [String]?
    var hotKey: HotKeyAction?
    var onClearProgram: (() -> Void)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: large ? 18 : 14, weight: .medium)).foregroundStyle(.dsMute)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(large ? DS.Font.manrope(19, .semibold, relativeTo: .title3) : DS.Font.bodyStrong)
                .foregroundStyle(.dsText)
                .focused(focused)
                .accessibilityLabel("Поиск подключений")
            if let programPill {
                Button { onClearProgram?() } label: { Pill(.neutral, "\(programPill) ✕") }
                    .buttonStyle(.plain)
                    .help("Показать все программы")
            }
            if let hint { Pill(.info, "\(hint.typed) → \(hint.converted)") }
            if let trailingKeys { Keycap(trailingKeys, compact: true, onPanel: true) }
            if let hotKey { Keycap(action: hotKey, compact: true, onPanel: true) }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: large ? 52 : DS.Size.button + 2)
        .background(Color.dsField, in: shape)
        .overlay(shape.strokeBorder(focused.wrappedValue ? Color.dsAccLine : Color.dsLine,
                                    lineWidth: focused.wrappedValue ? DS.State.focusRing : 1))
    }
}

/// Список секций с выбором; общий для вкладки и палитры.
struct RemoteSectionsList: View {
    @ObservedObject var model: RemoteListModel
    @ObservedObject var center: RemoteConnectionsCenter
    let listing: ConnectionListing
    var showSectionLabels = true
    var dimmed: Set<RemoteProgram> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let selectedID = model.selectedRow(in: listing)?.id
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(listing.sections) { section in
                        if showSectionLabels {
                            RemoteSectionLabel(title: section.title, symbol: section.symbol,
                                               count: section.kind == .favorites ? nil : section.records.count)
                        }
                        ListCard(style: .field) {
                            ForEach(section.records, id: \.identity) { record in
                                let row = ConnectionRow(sectionID: section.id, record: record)
                                let program = record.program(default: center.defaultProgram)
                                RemoteRow(record: record, program: program, query: listing.effectiveQuery,
                                          selected: row.id == selectedID,
                                          showGroup: section.kind == .results || section.kind == .recents || section.kind == .favorites,
                                          favorite: center.isFavorite(record), dimmed: dimmed.contains(program),
                                          onFavorite: { center.toggleFavorite(record) },
                                          onConnect: { model.select(row); model.connectSelected() })
                                    .id(row.id)
                                    .onTapGesture { model.select(row) }
                            }
                        }
                    }
                }
                .padding(.bottom, DS.Space.xs)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(DS.Motion.animation(DS.Motion.quick, reduceMotion: reduceMotion)) { proxy.scrollTo(id) }
            }
        }
    }
}

// MARK: - Диагностика в списке

extension SkippedRow {
    var message: String {
        switch reason {
        case .missingName: return "Нет названия — запись пропущена"
        case .missingID: return "Нет ID — запись пропущена"
        case .invalidID: return "ID «\(value)» — не 9–10 цифр и не алиас — пропущена"
        case .unknownProgram: return "Программа «\(value)» не распознана — запись пропущена"
        case .aliasNotSupported: return "Алиас «\(value)» у TeamViewer — нужен числовой ID"
        }
    }
}

extension ConnectionField {
    var columnTitle: String {
        switch self {
        case .name: return "Название"
        case .id: return "ID"
        case .password: return "Пароль"
        case .group: return "Группа"
        case .tags: return "Теги"
        case .note: return "Заметка"
        case .program: return "Программа"
        }
    }
}

/// Сводка внизу списка: «Загружено 214 · пропущено 3 · дубликатов 1 ›». Если всё чисто — только «Загружено 214».
struct RemoteDiagnosticsSummary: View {
    let diagnostics: ConnectionsDiagnostics
    @Binding var expanded: Bool

    private var text: String {
        var parts = ["Загружено \(diagnostics.loaded)"]
        if !diagnostics.skipped.isEmpty { parts.append("пропущено \(diagnostics.skipped.count)") }
        if diagnostics.duplicateCount > 0 { parts.append("дубликатов \(diagnostics.duplicateCount)") }
        let other = diagnostics.unrecognizedColumns.count + diagnostics.lossyIDRows.count + diagnostics.ambiguousProgramRows.count
        if other > 0 { parts.append("замечаний \(other)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if diagnostics.isClean {
            Text(text).font(DS.Font.rowSub).foregroundStyle(.dsMute).lineLimit(1)
        } else {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Text(text).font(DS.Font.rowSub).foregroundStyle(.dsMute).underline(true, color: .dsLine)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.dsMute)
                }
            }
            .buttonStyle(.plain)
            .help(expanded ? "Скрыть подробности" : "Показать пропущенные строки и дубликаты")
            .accessibilityHint("Подробности проверки файла")
        }
    }
}

/// Подробности проверки — раскрываются прямо в списке, отдельного окна нет.
struct RemoteDiagnosticsList: View {
    let diagnostics: ConnectionsDiagnostics
    let defaultProgram: RemoteProgram
    let records: [ConnectionRecord]

    private struct Issue: Identifiable {
        let id: String
        let text: String
        let detail: String
    }

    private var issues: [Issue] {
        var out = diagnostics.skipped.map { Issue(id: "s\($0.row)", text: $0.message, detail: "строка \($0.row)") }
        out += diagnostics.duplicates.map { d in
            let names = d.names.map { "«\($0)»" }.joined(separator: ", ")
            let display = ConnectionRecord(sourceRow: 0, name: "", id: d.id).displayID
            return Issue(id: "d\(d.id)", text: "\(display) — \(names) — показаны все",
                         detail: "строки " + d.rows.map(String.init).joined(separator: ", "))
        }
        out += diagnostics.lossyIDRows.map {
            Issue(id: "l\($0)", text: "ID записан как 1,23E+08 — цифры могли потеряться; сделайте ячейку текстовой",
                  detail: "строка \($0)")
        }
        out += diagnostics.ambiguousProgramRows.map {
            Issue(id: "a\($0)", text: "Программа пуста — взята по умолчанию (\(defaultProgram.title))", detail: "строка \($0)")
        }
        if !diagnostics.unrecognizedColumns.isEmpty {
            out.append(Issue(id: "c", text: "Не распознаны колонки: " + diagnostics.unrecognizedColumns.map { "«\($0)»" }.joined(separator: ", "),
                             detail: "их значения не читаются"))
        }
        return out
    }

    private var columnsLine: String {
        diagnostics.columns.map { c in
            "\(c.field.columnTitle) — \(c.columnLetter.map { "\($0) " } ?? "")«\(c.title)»"
        }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RemoteSectionLabel(title: "Проверка файла", symbol: "stethoscope")
            ListCard(style: .field) {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Tone.warning.ink)
                            .frame(width: 26, height: 26)
                            .background(DS.Tone.warning.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.text).font(DS.Font.rowTitle).foregroundStyle(.dsText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(issue.detail).font(DS.Font.rowSub).foregroundStyle(.dsMute)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .accessibilityElement(children: .combine)
                }
                if !diagnostics.columns.isEmpty {
                    Text("Колонки: \(columnsLine)").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6).padding(.horizontal, 10)
                }
            }
            Text("Пароли здесь и в журнале не показываются: только номера строк и причины.")
                .font(DS.Font.rowSub).foregroundStyle(.dsMute).padding(.horizontal, 6)
        }
    }
}

// MARK: - Пустые состояния

/// Нет файла, недоступен, нет колонок, повреждён, читается.
struct RemoteFileStateView: View {
    @ObservedObject var center: RemoteConnectionsCenter

    var body: some View {
        switch center.state {
        case .noFile:
            panel("Файл подключений не выбран", "doc.badge.plus",
                  "Укажите таблицу .xlsx или .xml со своими компьютерами (AnyDesk, TeamViewer) — Mac Utils её только читает.",
                  primary: ("Выбрать файл подключений", center.chooseFile))
        case .loading:
            EmptyState.loading("Читаю файл подключений…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cloudNotDownloaded:
            panel("Файл ещё скачивается", "icloud.and.arrow.down",
                  "\(fileName) скачивается из облака. Список появится сам, как только файл будет на диске.",
                  primary: ("Выбрать файл", center.chooseFile))
        case .unavailable:
            panel("Файл подключений недоступен", "externaldrive.badge.xmark",
                  "\(filePath) не открывается: диск отключён или файл ещё не скачан из облака. Повторю сам, как только он появится.",
                  primary: ("Выбрать файл", center.chooseFile), secondary: ("Повторить", center.reload))
        case .failed(let error):
            failed(error)
        case .ready:
            EmptyView()
        }
    }

    private var fileName: String { center.fileURL?.lastPathComponent ?? "Файл" }
    private var filePath: String { (center.fileURL?.path as NSString?)?.abbreviatingWithTildeInPath ?? "Файл" }

    @ViewBuilder private func failed(_ error: ConnectionsError) -> some View {
        switch error {
        case .missingColumns(let found):
            panel("Не нашёл нужные колонки", "tablecells.badge.ellipsis",
                  found.isEmpty ? "Лист пуст: в первой строке нужны «Название» и «ID»."
                      : "В первой строке нет «Название» и «ID/Адрес». Нашёл заголовки:",
                  primary: ("Открыть файл", center.openFile), secondary: ("Выбрать другой", center.chooseFile),
                  pills: found)
        case .noSheet(let name):
            panel("Нет листа «\(name)»", "tablecells",
                  "В книге \(fileName) нет выбранного листа. Будет прочитан первый лист.",
                  primary: ("Читать первый лист", { center.setSheet(nil) }), secondary: ("Открыть файл", center.openFile))
        case .locked:
            panel("Файл занят", "lock",
                  "\(fileName) не читается — другая программа держит его или ещё сохраняет. Повторю, когда он изменится.",
                  primary: ("Повторить", center.reload))
        case .unsupportedType:
            panel("Этот формат не подходит", "doc.questionmark",
                  "Нужна таблица .xlsx или файл .xml. Сохраните список в одном из этих форматов.",
                  primary: ("Выбрать файл", center.chooseFile))
        case .tooLarge:
            panel("Файл слишком большой", "doc.badge.ellipsis",
                  "\(fileName) больше 64 МБ — это не похоже на список подключений.",
                  primary: ("Выбрать файл", center.chooseFile))
        case .corrupt(let reason):
            panel("Файл повреждён", "exclamationmark.triangle",
                  "\(reason). Прежний список не сохранён — исправьте файл, список обновится сам.",
                  primary: ("Открыть файл", center.openFile), secondary: ("Выбрать другой", center.chooseFile))
        case .noFile, .unavailable, .cloudNotDownloaded:
            EmptyView()
        }
    }

    private func panel(_ title: String, _ symbol: String, _ message: String,
                       primary: (String, () -> Void), secondary: (String, () -> Void)? = nil,
                       pills: [String] = []) -> some View {
        VStack(spacing: DS.Space.m) {
            Spacer(minLength: 0)
            HeaderTile(systemImage: symbol)
            Text(title).font(DS.Font.dialogTitle).foregroundStyle(.dsText).multilineTextAlignment(.center)
            Text(message).font(DS.Font.body).foregroundStyle(.dsMute).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 28)
            if !pills.isEmpty {
                FlowLayout { ForEach(pills, id: \.self) { Pill(.neutral, $0) } }.padding(.horizontal, 28)
            }
            HStack {
                Button(primary.0, action: primary.1).buttonStyle(.graphite(.primary))
                if let secondary { Button(secondary.0, action: secondary.1).buttonStyle(.graphite(.secondary)) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Вкладка «Удалённые»

struct RemoteConnectionsPanel: View {
    @StateObject private var model: RemoteListModel
    @ObservedObject private var center: RemoteConnectionsCenter
    @FocusState private var searchFocused: Bool
    @State private var diagnosticsExpanded: Bool
    @State private var installed: Set<RemoteProgram> = Set(RemoteProgram.allCases)

    /// `center`, `query`, `diagnosticsExpanded` — для снимков интерфейса; в приложении — общий центр и пустой поиск.
    init(center: RemoteConnectionsCenter? = nil, query: String = "", diagnosticsExpanded: Bool = false) {
        let center = center ?? .shared
        let model = RemoteListModel(center: center)
        model.query = query
        _center = ObservedObject(wrappedValue: center)
        _model = StateObject(wrappedValue: model)
        _diagnosticsExpanded = State(initialValue: diagnosticsExpanded)
    }

    var body: some View {
        let listing = model.listing
        VStack(spacing: DS.Space.s) {
            RemoteSearchField(text: $model.query, hint: listing.hint, focused: $searchFocused, hotKey: .remoteConnections)
                .disabled(center.state != .ready)
                .opacity(center.state == .ready ? 1 : DS.State.disabledOpacity)
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.return) { model.connectSelected() ? .handled : .ignored }
                .padding(.horizontal, DS.Space.l)
            if center.state == .ready {
                HStack(spacing: 6) {
                    ForEach([ProgramFilter.all] + RemoteProgram.allCases.map { .program($0) }, id: \.self) { f in
                        Chip(model.chipTitle(f, counts: listing.counts), selected: model.filter == f) { model.filter = f }
                    }
                    Spacer()
                }
                .padding(.horizontal, DS.Space.l)
                missingProgramBanner(listing).padding(.horizontal, DS.Space.l)
                Group {
                    if diagnosticsExpanded {
                        ScrollView {
                            RemoteDiagnosticsList(diagnostics: center.snapshot.diagnostics, defaultProgram: center.defaultProgram,
                                                  records: center.snapshot.records)
                        }
                    } else if listing.isEmpty {
                        emptyList
                    } else {
                        RemoteSectionsList(model: model, center: center, listing: listing,
                                           dimmed: Set(RemoteProgram.allCases).subtracting(installed))
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .frame(maxHeight: .infinity)
            } else {
                RemoteFileStateView(center: center)
            }
            bottomBar
        }
        .padding(.top, DS.Space.xxs)
        .onAppear {
            center.start()
            installed = Set(RemoteProgram.allCases.filter(center.isInstalled))
            searchFocused = true
        }
        .onChange(of: center.snapshot.diagnostics.isClean) { _, clean in if clean { diagnosticsExpanded = false } }
    }

    @ViewBuilder private var emptyList: some View {
        if center.snapshot.records.isEmpty {
            EmptyState("В файле нет записей", systemImage: "tray",
                       message: "Добавьте строки с названием и ID — список обновится сам.", compact: true)
        } else {
            EmptyState("Ничего не найдено", systemImage: "magnifyingglass",
                       message: "Поиск идёт по названию, ID, группе, тегам и заметке. Раскладка уже учтена.", compact: true)
        }
    }

    /// Программы, чьи записи есть в списке, но самой программы на этом Mac нет.
    @ViewBuilder private func missingProgramBanner(_ listing: ConnectionListing) -> some View {
        let missing = RemoteProgram.allCases.filter { !installed.contains($0) && (listing.counts[.program($0)] ?? 0) > 0 }
        if let program = missing.first {
            let others = RemoteProgram.allCases.filter { installed.contains($0) }.map(\.title)
            Banner(.danger, title: "\(program.title) не установлен",
                   message: "Записи \(program.title) (\(listing.counts[.program(program)] ?? 0)) приглушены."
                       + (others.isEmpty ? "" : " \(others.joined(separator: ", ")) работает.")) {
                Button("Скачать \(program.title)") { NSWorkspace.shared.open(program.downloadURL) }
                    .buttonStyle(.graphite(.primary, size: .compact))
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: DS.Space.s) {
            Divider().overlay(Color.dsLine)
            HStack(spacing: 6) {
                Button { center.openFile() } label: { Label("Excel", systemImage: "tablecells") }
                    .buttonStyle(.graphite(.secondary, size: .compact))
                    .help("Открыть файл подключений")
                    .disabled(center.fileURL == nil)
                IconButton("Перечитать", systemImage: "arrow.clockwise", compact: true) { center.reload() }
                    .disabled(center.fileURL == nil)
                IconButton("Выбрать файл", systemImage: "folder", compact: true) { center.chooseFile() }
                Spacer()
                if center.state == .ready {
                    RemoteDiagnosticsSummary(diagnostics: center.snapshot.diagnostics, expanded: $diagnosticsExpanded)
                }
            }
            .padding(.horizontal, DS.Space.l)
        }
        .padding(.bottom, DS.Space.m)
    }
}
