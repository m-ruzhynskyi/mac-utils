import AppKit
import SwiftUI
import MUCore
import MUDesign

/// Поиск и замена в текущей вкладке: запрос, опции, совпадения и переходы по ним.
@MainActor
final class EditorSearch: ObservableObject {
    weak var workspace: EditorWorkspace?
    @Published var query = "" { didSet { if query != oldValue { schedule() } } }
    @Published var replacement = ""
    @Published var options = SearchOptions() {
        didSet {
            guard options != oldValue else { return }
            if options.inSelection != oldValue.inSelection { captureScope() }
            schedule()
        }
    }
    @Published private(set) var error: String?
    @Published private(set) var count = 0
    @Published private(set) var truncated = false
    @Published private(set) var current: Int?
    /// Переход «через край» — показать «с начала» / «с конца».
    @Published private(set) var wrapped = false
    /// Итог «Заменить все».
    @Published private(set) var note: String?

    /// Регулярное выражение ищется в фоне: долгий перебор не держит главный поток (а с ним и перехваты клавиш
    /// всего приложения). Пока ищет — «Ищу…», новый запрос или правка прерывают прежний поиск.
    @Published private(set) var searching = false

    /// «В выделении»: где искать (выделение на момент включения опции).
    private var scope: NSRange?
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var running: TextSearch.Cancellation?
    /// ⌘G нажали, пока поиск ещё идёт, — перейти, когда найдётся.
    private var nextAfterSearch: Bool?
    private let queue = DispatchQueue(label: "macutils.editor.search", qos: .userInitiated)

    private var tab: EditorTab? { workspace?.current }
    var isActive: Bool { workspace?.findMode != nil }

    /// Открыть панель: выделенный текст в одной строке становится запросом, выделение в несколько строк — областью «В выделении».
    func prepare(from tab: EditorTab) {
        let selection = tab.textView.selectedRange()
        guard selection.length > 0 else { return }
        let selected = tab.text.substring(with: selection)
        if selected.contains(where: \.isNewline) {
            options.inSelection = true
            scope = selection
        } else if selection.length <= 500 {
            query = options.regex ? NSRegularExpression.escapedPattern(for: selected) : selected
        }
    }

    private func captureScope() {
        guard options.inSelection, let tab else { scope = nil; return }
        let selection = tab.textView.selectedRange()
        scope = selection.length > 0 ? selection : nil
    }

    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func tabChanged() {
        scope = nil
        if isActive { refresh() }
    }

    func clear() {
        stopRunning()
        for tab in workspace?.tabs ?? [] where !tab.matches.isEmpty { tab.setMatches([], current: nil) }
        count = 0
        current = nil
        error = nil
        note = nil
    }

    private var searchScope: NSRange? {
        guard options.inSelection, let scope, let tab else { return nil }
        let full = NSRange(location: 0, length: tab.storage.length)
        let clipped = NSIntersectionRange(scope, full)
        return clipped.length > 0 ? clipped : nil
    }

    /// Пересчитать совпадения в текущей вкладке; текущее — первое не раньше курсора. Обычный текст — сразу
    /// (10 МБ — десятки миллисекунд), регулярное выражение — в фоне с отменой.
    func refresh() {
        pending?.cancel()
        pending = nil
        stopRunning()
        guard let tab, isActive else { return }
        note = nil
        wrapped = false
        guard !query.isEmpty else {
            error = nil
            count = 0
            truncated = false
            current = nil
            tab.setMatches([], current: nil)
            return
        }
        let query = self.query, options = self.options, scope = searchScope
        guard options.regex else {
            finish(Result { try TextSearch.find(query, in: tab.text, options: options, scope: scope) }, timedOut: false, tab: tab)
            return
        }
        let generation = self.generation
        let snapshot = UncheckedSendable(tab.text.copy() as! NSString)
        let cancel = TextSearch.Cancellation()
        running = cancel
        searching = true
        queue.async { [weak self] in
            let outcome = Result { try TextSearch.find(query, in: snapshot.value, options: options, scope: scope, isCancelled: { cancel.isCancelled }) }
            let timedOut = cancel.timedOut
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, let tab = self.tab else { return }
                    self.searching = false
                    self.running = nil
                    self.finish(outcome, timedOut: timedOut, tab: tab)
                    if let backwards = self.nextAfterSearch {
                        self.nextAfterSearch = nil
                        self.next(backwards: backwards)
                    }
                }
            }
        }
    }

    private func finish(_ outcome: Result<TextSearch.Result, Error>, timedOut: Bool, tab: EditorTab) {
        switch outcome {
        case .success(let result):
            error = nil
            count = result.ranges.count
            truncated = result.truncated
            let selection = tab.textView.selectedRange()
            current = result.ranges.firstIndex { $0 == selection } ?? result.ranges.firstIndex { $0.location >= selection.location }
                ?? (result.ranges.isEmpty ? nil : 0)
            tab.setMatches(result.ranges, current: current)
        case .failure(let failure):
            error = timedOut ? "Выражение ищет слишком долго" : failure.localizedDescription
            count = 0
            current = nil
            tab.setMatches([], current: nil)
        }
    }

    /// Прервать фоновый поиск или замену (новый запрос, правка, другая вкладка, закрытие панели).
    private func stopRunning() {
        generation += 1
        running?.cancel()
        running = nil
        searching = false
        nextAfterSearch = nil
    }

    /// ⌘G / ⇧⌘G: следующее или предыдущее совпадение, по кругу.
    func next(backwards: Bool = false) {
        guard let tab else { return }
        if pending != nil || (tab.matches.isEmpty && !searching) { refresh() }
        if searching {
            nextAfterSearch = backwards
            return
        }
        guard let found = TextSearch.next(in: tab.matches, after: tab.textView.selectedRange(), backwards: backwards) else {
            Feedback.beep()
            return
        }
        current = found.index
        wrapped = found.wrapped
        tab.setMatches(tab.matches, current: found.index)
        tab.reveal(tab.matches[found.index])
    }

    /// «Заменить»: текущее совпадение (если выделено оно) — и к следующему.
    func replaceOne() {
        guard let tab, error == nil, !query.isEmpty else { return }
        let selection = tab.textView.selectedRange()
        if tab.matches.contains(selection),
           let string = try? TextSearch.replacement(for: selection, query, template: replacement, in: tab.text, options: options) {
            tab.textView.replace([selection], with: [string], actionName: "Заменить")
            tab.textView.setSelectedRange(NSRange(location: selection.location + (string as NSString).length, length: 0))
            refresh()
        }
        next()
    }

    /// «Заменить все» одним шагом отмены. С регулярным выражением замены считаются в фоне и применяются, только если
    /// текст за это время не меняли.
    func replaceAll() {
        guard let tab, !query.isEmpty else { return }
        let query = self.query, template = replacement, options = self.options, scope = searchScope
        guard options.regex else {
            apply(Result { try TextSearch.replacements(query, template: template, in: tab.text, options: options, scope: scope) },
                  timedOut: false, to: tab)
            return
        }
        stopRunning()
        let generation = self.generation, version = tab.textVersion
        let snapshot = UncheckedSendable(tab.text.copy() as! NSString)
        let cancel = TextSearch.Cancellation()
        running = cancel
        searching = true
        queue.async { [weak self] in
            let outcome = Result {
                try TextSearch.replacements(query, template: template, in: snapshot.value, options: options, scope: scope,
                                            isCancelled: { cancel.isCancelled })
            }
            let timedOut = cancel.timedOut
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.searching = false
                    self.running = nil
                    guard tab.textVersion == version else {
                        self.note = "Текст изменился — замените ещё раз"
                        return
                    }
                    self.apply(outcome, timedOut: timedOut, to: tab)
                }
            }
        }
    }

    private func apply(_ outcome: Result<(ranges: [NSRange], strings: [String]), Error>, timedOut: Bool, to tab: EditorTab) {
        switch outcome {
        case .success(let plan):
            guard !plan.ranges.isEmpty else {
                note = "Совпадений нет"
                return
            }
            tab.textView.replace(plan.ranges, with: plan.strings, actionName: "Заменить все")
            refresh()
            note = "Заменено: \(plan.ranges.count)"
        case .failure(let failure):
            error = timedOut ? "Выражение ищет слишком долго" : failure.localizedDescription
        }
    }

    /// «1 из 4», «20 000+», «Нет совпадений».
    var counter: String {
        if query.isEmpty { return "" }
        if searching { return "Ищу…" }
        if count == 0 { return "Нет совпадений" }
        if truncated { return "\(Self.number(TextSearch.limit))+" }
        let position = current.map { "\($0 + 1) из " } ?? ""
        return position + Self.number(count)
    }

    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{202F}"
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Панель

/// Панель над текстом (⌘F — поиск, ⌥⌘F — с заменой), как на макете c.
struct FindBar: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var search: EditorSearch
    @FocusState private var focus: Field?

    private enum Field { case query, replacement }

    var body: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                field(icon: "magnifyingglass", placeholder: "Найти", text: $search.query, focused: .query, trailing: trailing,
                      error: search.error != nil)
                    .onSubmit { search.next() }
                option("Aa", help: "Учитывать регистр", isOn: $search.options.caseSensitive)
                option("ab", help: "Слово целиком", isOn: $search.options.wholeWord, underline: true)
                option(".*", help: "Регулярное выражение", isOn: $search.options.regex)
                option("[ ]", help: "Только в выделении", isOn: $search.options.inSelection)
                IconButton("Предыдущее (⇧⌘G)", systemImage: "chevron.up", compact: true) { search.next(backwards: true) }
                    .disabled(search.count == 0)
                IconButton("Следующее (⌘G)", systemImage: "chevron.down", compact: true) { search.next() }
                    .disabled(search.count == 0)
                IconButton("Закрыть (Esc)", systemImage: "xmark", compact: true) { EditorWindowController.shared.hideFind() }
            }
            if workspace.findMode == true {
                HStack(spacing: DS.Space.s) {
                    field(icon: "arrow.2.squarepath", placeholder: "Заменить на", text: $search.replacement, focused: .replacement,
                          trailing: search.note, error: false)
                        .onSubmit { search.replaceOne() }
                    Button("Заменить") { search.replaceOne() }
                        .buttonStyle(.graphite(.secondary, size: .compact))
                        .disabled(search.count == 0)
                    Button("Заменить все") { search.replaceAll() }
                        .buttonStyle(.graphite(.primary, size: .compact))
                        .disabled(search.query.isEmpty || search.error != nil)
                    Button("В папке…") { EditorWindowController.shared.showFolderSearch() }
                        .buttonStyle(.graphite(.ghost, size: .compact))
                        .help("Найти и заменить во всех файлах папки (⇧⌘F)")
                }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 10)
        .background(Color.dsSide)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 1) }
        .onAppear { focus = .query }
        .onExitCommand { EditorWindowController.shared.hideFind() }
        .onReceive(NotificationCenter.default.publisher(for: .editorFocusFind)) { _ in focus = .query }
    }

    private var trailing: String? {
        if let error = search.error { return error }
        guard !search.query.isEmpty else { return nil }
        if search.wrapped { return "\(search.counter) · с начала" }
        return search.counter
    }

    private func field(icon: String, placeholder: String, text: Binding<String>, focused: Field, trailing: String?,
                       error: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        let active = focus == focused
        return HStack(spacing: DS.Space.s) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.dsMute)
                .accessibilityHidden(true)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(DS.Font.mono(13, relativeTo: .body))
                .foregroundStyle(.dsText)
                .focused($focus, equals: focused)
                .accessibilityLabel(placeholder)
            if let trailing {
                Text(trailing).font(DS.Font.rowSub).foregroundStyle(error ? DS.Tone.danger.text : .dsMute).lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.dsField, in: shape)
        .overlay(shape.strokeBorder(error ? DS.Tone.danger.line : (active ? Color.dsAccLine : Color.dsLine),
                                    lineWidth: active || error ? 2 : 1))
    }

    private func option(_ title: String, help: String, isOn: Binding<Bool>, underline: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let on = isOn.wrappedValue
        return Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .underline(underline)
                .font(DS.Font.mono(12, relativeTo: .caption))
                .foregroundStyle(on ? Color.dsAccInk : Color.dsMute)
                .frame(width: 30, height: 30)
                .background(on ? Color.dsAcc : Color.dsField, in: shape)
                .overlay(shape.strokeBorder(on ? Color.clear : Color.dsLine, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// «Перейти к строке» (⌘L): плавающее поле, понимает «строка» и «строка:столбец».
struct GoToLinePanel: View {
    let lineCount: Int
    let onGo: (Int, Int) -> Void
    let onClose: () -> Void
    @State private var input = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Перейти к строке").font(DS.Font.manrope(15, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
                Spacer()
                Keycap(["⌘", "L"], compact: true)
            }
            HStack(spacing: DS.Space.s) {
                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .font(DS.Font.mono(14, relativeTo: .body))
                    .foregroundStyle(.dsText)
                    .focused($focused)
                    .onSubmit(go)
                    .accessibilityLabel("Строка")
                    .padding(.horizontal, DS.Space.m)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(invalid ? DS.Tone.danger.line : Color.dsAccLine, lineWidth: 2))
                Button("Перейти", action: go).buttonStyle(.graphite(.primary, size: .compact))
            }
            Text(invalid ? "Введите номер строки: 15 или 15:26" : "Строка 1–\(lineCount), можно со столбцом: 15:26")
                .font(DS.Font.rowSub).foregroundStyle(invalid ? DS.Tone.danger.text : .dsMute)
        }
        .frame(width: 360)
        .floating()
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .onAppear { focused = true }
        .onExitCommand(perform: onClose)
    }

    private func go() {
        guard let location = TextSearch.parseLocation(input), location.line >= 1 else {
            invalid = true
            Feedback.beep()
            return
        }
        onGo(location.line, location.column)
    }
}

extension Notification.Name {
    /// ⌘F при открытой панели — вернуть фокус в поле «Найти».
    static let editorFocusFind = Notification.Name("MacUtils.editorFocusFind")
}
