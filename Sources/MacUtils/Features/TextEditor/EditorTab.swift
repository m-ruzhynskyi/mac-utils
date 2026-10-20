import AppKit
import Combine

/// Позиция курсора для строки состояния.
struct EditorCaret: Equatable {
    var line = 1
    var column = 1
    /// Выделено символов (UTF-16, как длина) и строк (0 — выделение в одной строке).
    var selected = 0
    var selectedLines = 0
    /// Курсоров и выделений (больше одного — прямоугольное выделение или несколько курсоров).
    var cursors = 1
}

/// Вкладка редактора: документ, текст (TextKit 1), своя история отмены, панель `$` и подсветка.
@MainActor
final class EditorTab: NSObject, ObservableObject, Identifiable, NSTextViewDelegate, NSTextStorageDelegate {
    let id: UUID
    @Published var document: EditorDocument
    @Published private(set) var isDirty = false
    @Published private(set) var caret = EditorCaret()
    @Published private(set) var length = 0
    @Published private(set) var lineCount = 1
    @Published private(set) var lineEnding: LineEndingMode = .single(.lf)
    @Published private(set) var overwrite = false
    /// Файла нет на диске (восстановлен из сессии) или он изменён снаружи.
    @Published var fileMissing = false
    @Published var changedOnDisk = false
    /// Найденные совпадения поиска (по возрастанию) и текущее.
    @Published private(set) var matches: [NSRange] = []
    @Published private(set) var currentMatch: Int?

    let scrollView: NSScrollView
    let textView: EditorTextView
    let ruler: LineNumberGutter
    /// Колонка номеров и прокрутка рядом — то, что показывает окно.
    let container: NSView
    private var gutterWidth: NSLayoutConstraint!
    let undo = UndoManager()
    let dollars = DollarPanelModel()
    private(set) var lines = LineIndex("")
    /// Закладки — номера строк (этап «Правка»; рисуются в колонке номеров).
    var bookmarks: Set<Int> = []
    /// «Без имени N» у нового документа.
    var untitledName = "Без имени"
    /// Черновик в сессии: id файла в `Drafts/`.
    var draftID: UUID?
    /// Ручной выбор языка сохраняется для вкладки.
    var zoom: CGFloat = 1 { didSet { applyZoom() } }

    var showsInvisibles: Bool {
        get { (textView.layoutManager as? EditorLayoutManager)?.showsInvisibles ?? false }
        set { (textView.layoutManager as? EditorLayoutManager)?.showsInvisibles = newValue }
    }
    var matchesBrackets = true { didSet { refreshBrackets() } }
    /// Где сейчас подсвечены скобки (временный атрибут фона).
    private var bracketRanges: [NSRange] = []

    /// Растёт с каждой правкой текста: фоновый результат (поиск, замена) применяется, только если текст тот же.
    private(set) var textVersion = 0

    /// Счётчик правок от сохранения: +1 за каждый шаг отмены, −1 за отмену.
    private var changeCount = 0
    private var pendingChange = false
    private var observers: [NSObjectProtocol] = []
    private var highlightScheduled = false
    /// Весь текст заменяется целиком — индекс строк строится заново, а не правкой.
    private var bulkLoading = false
    private var highlighted: [NSRange] = []
    /// Что правили с прошлой подсветки (перекрашивается сразу, остальное — после пересчёта `$`).
    private var lastEdit: NSRange?
    /// Вызывается после каждой правки текста (сессия, автосохранение).
    var onEdit: (() -> Void)?

    var storage: NSTextStorage { textView.textStorage! }
    /// Текст без копирования (в Swift `NSTextStorage.string` при каждом обращении копирует весь текст).
    var text: NSString { storage.mutableString }

    init(document: EditorDocument, text: String? = nil, id: UUID = UUID(), zoom: CGFloat = 1) {
        self.id = id
        self.document = document
        self.zoom = zoom
        let made = EditorTextView.make()
        scrollView = made.scroll
        textView = made.text
        ruler = LineNumberGutter(frame: .zero)
        container = NSView()
        super.init()
        ruler.tab = self
        ruler.textView = textView
        layoutContainer()
        textView.delegate = self
        storage.delegate = self
        textView.onOverwriteChange = { [weak self] in self?.overwrite = $0 }
        textView.onCursorsChange = { [weak self] in self?.refreshCaret() }
        dollars.onUpdate = { [weak self] in self?.rehighlight() }
        dollars.rule = Self.defaultRule(for: document)
        dollars.encoding = document.encoding
        load(text ?? document.decodedText, resetUndo: true)
        if let text, !(text as NSString).isEqual(to: document.decodedText) {
            // Восстановленный черновик отличается от файла — вкладка изменена.
            pendingChange = true
            updateDirty()
        }
        observeUndo()
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ruler.needsDisplay = true
                self?.visibleAreaChanged()
            }
        })
    }

    private func layoutContainer() {
        container.clipsToBounds = true
        for view in [ruler, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        gutterWidth = ruler.widthAnchor.constraint(equalToConstant: ruler.thickness)
        NSLayoutConstraint.activate([
            ruler.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            ruler.topAnchor.constraint(equalTo: container.topAnchor),
            ruler.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutterWidth,
            scrollView.leadingAnchor.constraint(equalTo: ruler.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        ruler.onThicknessChange = { [weak self] width in self?.gutterWidth.constant = width }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var title: String { document.url?.lastPathComponent ?? untitledName }

    // MARK: - Текст

    /// Заменить весь текст без шага отмены (открытие, «Открыть заново в…», «Перезагрузить»).
    func load(_ string: String, resetUndo: Bool) {
        undo.disableUndoRegistration()
        bulkLoading = true
        defer { bulkLoading = false }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: string)
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        undo.enableUndoRegistration()
        if resetUndo { undo.removeAllActions() }
        textView.typingAttributes = baseAttributes
        lines = LineIndex(text)
        textVersion += 1
        changeCount = 0
        pendingChange = false
        updateDirty()
        refreshCounts()
        refreshLineEnding()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        dollars.removedCount = nil
        dollars.textChanged({ [weak self] in self?.text ?? "" }, immediately: true)
        ruler.updateThickness()
        rehighlight()
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = EditorStyle.lineHeight * zoom
        style.maximumLineHeight = EditorStyle.lineHeight * zoom
        style.lineBreakMode = .byCharWrapping
        style.tabStops = []
        style.defaultTabInterval = (String(repeating: " ", count: EditorPrefs.tabWidth) as NSString)
            .size(withAttributes: [.font: EditorStyle.font(zoom: zoom)]).width
        return [.font: EditorStyle.font(zoom: zoom), .foregroundColor: EditorStyle.text, .paragraphStyle: style]
    }

    private func applyZoom() {
        undo.disableUndoRegistration()
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        undo.enableUndoRegistration()
        textView.typingAttributes = baseAttributes
        ruler.zoom = zoom
        ruler.needsDisplay = true
    }

    // MARK: - Состояние «изменено»

    private func observeUndo() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSUndoManagerWillCloseUndoGroup, object: undo, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.undo.groupingLevel == 1 else { return }
                self.changeCount += 1
                self.pendingChange = false
                self.updateDirty()
            }
        })
        observers.append(center.addObserver(forName: .NSUndoManagerDidUndoChange, object: undo, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changeCount -= 1
                self.pendingChange = false
                self.updateDirty()
            }
        })
        observers.append(center.addObserver(forName: .NSUndoManagerDidRedoChange, object: undo, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changeCount += 1
                self.pendingChange = false
                self.updateDirty()
            }
        })
    }

    func updateDirty() {
        let dirty = changeCount != 0 || pendingChange || document.isConverted
        if dirty != isDirty {
            isDirty = dirty
            onDirtyChange?()
        }
    }

    /// Отметка «изменено» сменилась (точка на кнопке закрытия окна).
    var onDirtyChange: (() -> Void)?

    /// После сохранения: текущий текст — «чистый».
    func markSaved() {
        changeCount = 0
        pendingChange = false
        updateDirty()
    }

    /// Отметить вкладку изменённой (смена кодировки, черновик сессии).
    func markChanged() {
        pendingChange = true
        updateDirty()
    }

    // MARK: - Делегаты

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            guard !bulkLoading else { return }
            dollars.invalidate()
            let editLine = lines.line(at: editedRange.location)
            // Вставка в самом начале строки (Enter перед текстом) сдвигает и саму эту строку.
            let atLineStart = lines.starts[editLine - 1] == editedRange.location
            let oldLineCount = lines.lineCount
            lines.update(textStorage.mutableString, editedRange: editedRange, delta: delta)
            let lineDelta = lines.lineCount - oldLineCount
            bookmarks = Self.shiftBookmarks(bookmarks, editLine: atLineStart && lineDelta > 0 ? editLine - 1 : editLine, lineDelta: lineDelta)
            // Временные атрибуты подсветки сдвигаются вместе с текстом — запоминаем, где они теперь.
            let oldEnd = editedRange.location + editedRange.length - delta
            highlighted = highlighted.map { range in
                if range.location >= oldEnd { return NSRange(location: range.location + delta, length: range.length) }
                if NSMaxRange(range) > editedRange.location { return NSRange(location: range.location, length: max(0, range.length + delta)) }
                return range
            }
            lastEdit = lastEdit.map { NSUnionRange($0, editedRange) } ?? editedRange
        }
    }

    func textDidChange(_ notification: Notification) {
        textVersion += 1
        pendingChange = true
        updateDirty()
        refreshCounts()
        refreshLineEnding()
        dollars.removedCount = nil
        dollars.textChanged { [weak self] in self?.text ?? "" }
        if !matches.isEmpty { onSearchInvalidated?() }
        ruler.updateThickness()
        ruler.needsDisplay = true
        highlightEdit()
        onEdit?()
    }

    /// Текст изменился, а поиск был активен — пересчитать совпадения.
    var onSearchInvalidated: (() -> Void)?

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshCaret()
        refreshBrackets()
        ruler.needsDisplay = true
    }

    // MARK: - Правило значений `$`

    /// Одно правило для всех файлов: значение — до конца строки исходника (решение пользователя).
    static func defaultRule(for document: EditorDocument) -> DollarRule { .source }

    /// Правило значений; в интерфейсе не меняется (`.rtf` — для будущего режима «Документ»).
    var dollarRule: DollarRule {
        get { dollars.rule }
        set {
            guard newValue != dollars.rule else { return }
            dollars.rule = newValue
            dollars.objectWillChange.send()
            dollars.scanNow(text)
        }
    }

    // MARK: - Закладки

    /// Закладки ниже правки сдвигаются вместе со строками; закладки удалённых строк встают на строку правки.
    nonisolated static func shiftBookmarks(_ marks: Set<Int>, editLine: Int, lineDelta: Int) -> Set<Int> {
        guard lineDelta != 0 else { return marks }
        return Set(marks.map { line in
            guard line > editLine else { return line }
            return max(editLine, line + lineDelta)
        })
    }

    /// ⌘F2: закладка на строке курсора — поставить или снять.
    func toggleBookmark(line: Int? = nil) {
        let line = line ?? caret.line
        if bookmarks.contains(line) { bookmarks.remove(line) } else { bookmarks.insert(line) }
        ruler.needsDisplay = true
        onEdit?()
    }

    /// F2 / ⇧F2: к следующей или предыдущей закладке, по кругу.
    func goToBookmark(backwards: Bool) {
        let sorted = bookmarks.filter { $0 <= lines.lineCount }.sorted()
        guard !sorted.isEmpty else { return Feedback.beep() }
        let current = caret.line
        let target = backwards ? (sorted.last { $0 < current } ?? sorted.last!) : (sorted.first { $0 > current } ?? sorted.first!)
        goTo(line: target)
    }

    func clearBookmarks() {
        bookmarks.removeAll()
        ruler.needsDisplay = true
        onEdit?()
    }

    /// Парная скобка у курсора — фоном у обеих; без пары — красным. Только при пустом выделении.
    func refreshBrackets() {
        guard let layout = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: storage.length)
        for range in bracketRanges where NSMaxRange(range) <= full.length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        bracketRanges = []
        let selection = textView.selectedRange()
        guard matchesBrackets, selection.length == 0, let match = BracketMatcher.match(in: text, caret: selection.location) else { return }
        switch match {
        case .pair(let a, let b):
            bracketRanges = [NSRange(location: a, length: 1), NSRange(location: b, length: 1)]
            for range in bracketRanges { layout.addTemporaryAttribute(.backgroundColor, value: EditorStyle.bracketFill, forCharacterRange: range) }
        case .unmatched(let a):
            bracketRanges = [NSRange(location: a, length: 1)]
            layout.addTemporaryAttribute(.backgroundColor, value: EditorStyle.bracketUnmatched, forCharacterRange: bracketRanges[0])
        }
    }

    private func refreshCounts() {
        length = storage.length
        lineCount = lines.lineCount
        refreshCaret()
    }

    private func refreshCaret() {
        let selection = textView.selectedRange()
        let position = lines.position(at: min(selection.location, storage.length))
        var next = EditorCaret(line: position.line, column: position.column, selected: selection.length, selectedLines: 0,
                               cursors: textView.cursorCount)
        if selection.length > 0 {
            let endLine = lines.line(at: max(selection.location, NSMaxRange(selection) - 1))
            next.selectedLines = endLine > position.line ? endLine - position.line + 1 : 0
        }
        if next != caret { caret = next }
    }

    private var lineEndingWork: DispatchWorkItem?

    /// Вид переводов строк (для строки состояния): на больших текстах — с задержкой.
    private func refreshLineEnding() {
        lineEndingWork?.cancel()
        let compute = { [weak self] in
            guard let self else { return }
            let mode = LineEndingMode.of(self.text, default: EditorPrefs.newLineEnding)
            if mode != self.lineEnding { self.lineEnding = mode }
            if case .single(let ending) = mode { self.textView.lineBreak = ending.string }
        }
        if storage.length < 200_000 { compute(); return }
        let work = DispatchWorkItem { MainActor.assumeIsolated { compute() } }
        lineEndingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Команды

    /// Все переводы строк — одного вида; один шаг отмены.
    func convertLineEndings(to ending: LineEnding) {
        let converted = LineEnding.convert(text, to: ending)
        guard !(converted as NSString).isEqual(to: text as String) else {
            textView.lineBreak = ending.string
            lineEnding = .single(ending)
            return
        }
        textView.replace([NSRange(location: 0, length: storage.length)], with: [converted], actionName: "Перевод строк \(ending.title)")
        textView.lineBreak = ending.string
    }

    /// «Убрать значения» у всех подсвеченных. Скан мог отстать от текста (пересчёт через 250 мс после правки) —
    /// тогда сначала пересчитываем сразу.
    @discardableResult
    func removeHighlightedValues() -> Int {
        if !dollars.isCurrent { dollars.scanNow(text) }
        return removeValues(Array(dollars.split.active))
    }

    /// «Убрать значения» у подсвеченных (или у одного): `$` остаются, один шаг отмены.
    @discardableResult
    func removeValues(_ entries: [DollarEntry]) -> Int {
        // Список отстал от текста (пересчёт через 250 мс после правки) — пересчитываем сразу и убираем только то,
        // что совпало с новым списком; не совпало — ничего не трогаем.
        if !dollars.isCurrent { dollars.scanNow(text) }
        guard let fresh = dollars.current(entries.filter { !$0.isHidden }) else {
            Feedback.beep()
            return 0
        }
        let ranges = DollarMarks.valueRanges(fresh.map(\.mark))
        guard !ranges.isEmpty else { return 0 }
        let removed = fresh.filter { !$0.mark.isEmpty }.count
        // Не запрещаем, но предупреждаем: был баланс `{}`, а после удаления его нет — Word может не открыть файл.
        let wasBalanced = DollarMarks.unbalancedBraces(in: text) == 0
        textView.replace(ranges, with: Array(repeating: "", count: ranges.count),
                         actionName: fresh.count == 1 ? "Убрать значение" : "Убрать значения")
        let after = wasBalanced ? DollarMarks.unbalancedBraces(in: text) : 0
        dollars.removedCount = removed
        dollars.unbalancedAfterRemoval = after > 0 ? after : nil
        return removed
    }

    /// Выделить и показать диапазон.
    func reveal(_ range: NSRange, select: Bool = true) {
        // Не `NSIntersectionRange`: для пустого диапазона в конце текста он даёт {0, 0} — курсор прыгал в начало.
        let location = min(max(range.location, 0), storage.length)
        let target = NSRange(location: location, length: min(max(range.length, 0), storage.length - location))
        if select { textView.setSelectedRange(target) }
        textView.scrollRangeToVisible(target)
        textView.showFindIndicator(for: target)
    }

    /// Перейти к строке и столбцу (с 1); вне диапазона — к ближайшим.
    func goTo(line: Int, column: Int = 1) {
        let lineNumber = min(max(line, 1), lines.lineCount)
        let start = lines.starts[lineNumber - 1]
        let end = lineNumber < lines.lineCount ? lines.starts[lineNumber] : storage.length
        let content = (text.substring(with: NSRange(location: start, length: end - start)) as NSString)
        var lineLength = content.length
        while lineLength > 0, [0x0A, 0x0D].contains(content.character(at: lineLength - 1)) { lineLength -= 1 }
        let offset = start + min(max(column - 1, 0), lineLength)
        textView.window?.makeFirstResponder(textView)
        reveal(NSRange(location: offset, length: 0))
    }

    // MARK: - Поиск

    func setMatches(_ ranges: [NSRange], current: Int?) {
        matches = ranges
        currentMatch = current
        rehighlight()
    }

    // MARK: - Подсветка

    private func visibleAreaChanged() {
        // Подсвечено с запасом в два экрана — при прокрутке пересчёт только у края.
        let covered = highlightRanges(margin: 0.5).allSatisfy { range in
            highlighted.contains { NSIntersectionRange(range, $0) == range }
        }
        if !covered { rehighlight() }
    }

    /// Пересчитать подсветку видимой части (один раз за проход цикла событий).
    func rehighlight() {
        guard !highlightScheduled else { return }
        highlightScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.highlightScheduled = false
                self.applyHighlights()
            }
        }
    }

    /// Символы на экране (целыми строками) с запасом `margin` экранов сверху и снизу.
    func visibleCharacterRange(margin: CGFloat) -> NSRange? {
        guard let layout = textView.layoutManager, let container = textView.textContainer, storage.length > 0 else { return nil }
        let visible = textView.visibleRect
        guard visible.height > 0 else { return nil }
        let rect = NSRect(x: 0, y: visible.minY - visible.height * margin, width: max(visible.maxX, 1), height: visible.height * (1 + 2 * margin))
            .offsetBy(dx: 0, dy: -textView.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        return layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// Что подсвечивать: видимые строки; у длинных строк без переноса — только видимые столбцы (± экран), иначе
    /// каждое нажатие клавиши раскрашивало бы мегабайты невидимого текста.
    func highlightRanges(margin: CGFloat) -> [NSRange] {
        guard let vertical = visibleCharacterRange(margin: margin) else { return [] }
        if textView.textContainer?.widthTracksTextView == true { return [vertical] }
        let visible = textView.visibleRect
        let advance = max(1, ("0" as NSString).size(withAttributes: [.font: EditorStyle.font(zoom: zoom)]).width)
        let padding = Int(visible.width / advance) + 40
        let fromColumn = max(0, Int(visible.minX / advance) - padding)
        let toColumn = Int(visible.maxX / advance) + padding
        var ranges: [NSRange] = []
        var line = lines.line(at: vertical.location)
        let end = NSMaxRange(vertical)
        while line <= lines.lineCount {
            let start = lines.starts[line - 1]
            if start > end || (start == end && line > 1 && start < storage.length) { break }
            let lineEnd = line < lines.lineCount ? lines.starts[line] : storage.length
            let length = lineEnd - start
            // Табы шире одного столбца — запас в 40 столбцов это покрывает.
            let window = length <= 4 * padding ? NSRange(location: start, length: length)
                : NSRange(location: start + min(fromColumn, length), length: max(0, min(toColumn, length) - min(fromColumn, length)))
            if window.length > 0 {
                if let last = ranges.last, NSMaxRange(last) == window.location {
                    ranges[ranges.count - 1].length += window.length
                } else {
                    ranges.append(window)
                }
            }
            line += 1
        }
        return ranges
    }

    /// После нажатия клавиши — перекрасить только правленое место (синтаксис и знаки `$` по месту); весь экран
    /// перекрашивается, когда готов новый список `$` (через 250 мс после последней правки).
    func highlightEdit() {
        guard let edit = lastEdit, let layout = textView.layoutManager else { return rehighlight() }
        lastEdit = nil
        let string = text
        let length = string.length
        guard edit.length <= 4_096 else { return rehighlight() }
        // Начало — после ближайшего завершителя значения (кроме `$`): тогда ни одно значение не начинается раньше окна.
        let lineStart = lines.starts[lines.line(at: min(edit.location, length)) - 1]
        var start = max(lineStart, edit.location - 2_000)
        while start > lineStart {
            let previous = string.character(at: start - 1)
            if previous != 0x24, DollarMarks.isTerminator(previous) { break }
            start -= 1
        }
        let endLine = lines.line(at: min(NSMaxRange(edit), length))
        let lineEnd = endLine < lines.lineCount ? lines.starts[endLine] : length
        let end = min(lineEnd, NSMaxRange(edit) + 2_000)
        guard end > start else { return }
        let window = NSRange(location: start, length: end - start)
        // RTF: значение тянется через коды и строки — по куску его не пересчитать. Подсветка знаков сдвинулась вместе
        // с текстом; здесь только синтаксис, весь экран — после пересчёта списка (через 250 мс).
        if dollars.rule == .rtf {
            for (tokenRange, token) in SyntaxHighlighter.tokens(document.language, in: string, range: window) {
                layout.addTemporaryAttribute(.foregroundColor, value: Self.color(token), forCharacterRange: tokenRange)
            }
            refreshBrackets()
            return
        }
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor] {
            layout.removeTemporaryAttribute(key, forCharacterRange: window)
        }
        // Знаки в окне — свежим сканом; номер по порядку — по списку до окна (он до правки и не сдвинулся).
        let before = dollars.count(before: start)
        let local = DollarMarks.scan(string.substring(with: window) as NSString, rule: .source).map { mark in
            let shifted = DollarMark(dollar: mark.dollar + start, value: NSRange(location: mark.value.location + start, length: mark.value.length))
            return DollarEntry(mark: shifted, line: 0, value: string.substring(with: shifted.value),
                               hue: DollarMarks.hue(of: string.substring(with: shifted.value) as NSString, hues: EditorStyle.hueCount))
        }
        highlight(window, in: string, layout: layout, entries: local, firstIndex: before)
        refreshBrackets()
    }

    func applyHighlights() {
        lastEdit = nil
        guard let layout = textView.layoutManager else { return }
        let string = text
        let full = NSRange(location: 0, length: string.length)
        let keys: [NSAttributedString.Key] = [.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor]
        for old in highlighted {
            let range = NSIntersectionRange(old, full)
            if range.length > 0 { for key in keys { layout.removeTemporaryAttribute(key, forCharacterRange: range) } }
        }
        let ranges = highlightRanges(margin: 2)
        highlighted = ranges
        for range in ranges {
            for key in keys { layout.removeTemporaryAttribute(key, forCharacterRange: range) }
            highlight(range, in: string, layout: layout)
        }
        bracketRanges = []
        refreshBrackets()
    }

    /// `entries` и `firstIndex` — знаки `$` для окна и номер первого из них по порядку (по умолчанию — из списка панели).
    private func highlight(_ visible: NSRange, in string: NSString, layout: NSLayoutManager,
                           entries local: [DollarEntry]? = nil, firstIndex: Int = 0) {
        // Синтаксис — с начала строки (кроме очень длинных строк).
        var range = visible
        let lineStart = lines.starts[lines.line(at: range.location) - 1]
        if range.location - lineStart <= SyntaxHighlighter.context {
            range = NSRange(location: lineStart, length: NSMaxRange(range) - lineStart)
        }
        for (tokenRange, token) in SyntaxHighlighter.tokens(document.language, in: string, range: range) {
            layout.addTemporaryAttribute(.foregroundColor, value: Self.color(token), forCharacterRange: tokenRange)
        }

        // Знаки `$`: пропущенные — бледно с точками, остальные — оттенком по значению.
        let skip = max(dollars.skip ?? 0, 0)
        let slice = local.map { ArraySlice($0) } ?? dollars.entries(in: range)
        for index in slice.indices {
            let entry = slice[index]
            let mark = entry.mark
            guard mark.dollar < string.length, string.character(at: mark.dollar) == 0x24,
                  mark.parts.allSatisfy({ NSMaxRange($0) <= string.length }) else { continue }
            // Подсвечиваются `$` и куски значения; коды RTF между кусками не красим.
            let pieces = [NSRange(location: mark.dollar, length: 1)] + mark.parts
            // Служебные знаки (`\info`, `{\*\…}`) — бледно, без подчёркивания; пропущенные первые N — бледно с точками.
            if mark.hidden {
                for piece in pieces { layout.addTemporaryAttribute(.foregroundColor, value: EditorStyle.faint, forCharacterRange: piece) }
                continue
            }
            let order = local == nil ? (entry.order ?? 0) : firstIndex + index
            if order < skip {
                for piece in pieces {
                    layout.addTemporaryAttributes([
                        .foregroundColor: EditorStyle.faint,
                        .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                        .underlineColor: EditorStyle.faint,
                    ], forCharacterRange: piece)
                }
                continue
            }
            let selected = dollars.selected == mark.dollar
            let fill = EditorStyle.hueFill(entry.hue, selected: selected)
            layout.addTemporaryAttributes([.foregroundColor: EditorStyle.hue(entry.hue), .backgroundColor: fill],
                                          forCharacterRange: pieces[0])
            for part in mark.parts {
                layout.addTemporaryAttributes([
                    .foregroundColor: EditorStyle.text, .backgroundColor: fill,
                    .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: EditorStyle.hue(entry.hue),
                ], forCharacterRange: part)
            }
        }

        // Совпадения поиска: все — бледный лайм, текущее — сплошной.
        guard !matches.isEmpty else { return }
        var low = 0, high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(matches[mid]) <= range.location { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < matches.count, matches[index].location < NSMaxRange(range) {
            let current = index == currentMatch
            layout.addTemporaryAttributes([
                .backgroundColor: current ? EditorStyle.match : EditorStyle.matchFill,
                .foregroundColor: current ? DS.Palette.accInk : EditorStyle.text,
            ], forCharacterRange: matches[index])
            index += 1
        }
    }

    private static func color(_ token: SyntaxToken) -> NSColor {
        switch token {
        case .control, .tag: return EditorStyle.control
        case .escape, .number: return EditorStyle.escape
        case .brace, .punctuation: return EditorStyle.brace
        case .key, .attribute: return EditorStyle.control
        case .string: return EditorStyle.string
        case .keyword: return EditorStyle.keyword
        case .comment: return EditorStyle.comment
        }
    }
}
