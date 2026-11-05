import AppKit
import MUCore

/// Команды вкладки «Вставка» (R3): номер страницы, поле, символ, разрыв страницы. Только логика — вид ленты рисует интерфейс.
/// Доступность решает чистая функция по `Context` (как у `TableCommand`): `.hidden` — кнопки нет, `.disabled(причина)` — есть,
/// но не нажимается, и подсказка говорит почему. Вставка — точечная правка исходника (одна правка — один шаг отмены).
package enum InsertCommand: Equatable {
    case pageNumber
    case field(HeaderField)
    case symbol(String)
    case pageBreak

    /// Символы быстрого выбора: то, что встречается в юридических и деловых формах.
    package static let symbols = ["©", "®", "™", "°", "±", "№", "§", "—", "–", "…", "«", "»", "€", "×", "\u{00A0}"]

    /// Все команды вкладки по порядку ленты: номер страницы, остальные поля, символы, разрыв страницы.
    package static let catalog: [InsertCommand] = [.pageNumber] + HeaderField.catalog.filter { $0 != .page }.map { .field($0) }
        + symbols.map { .symbol($0) } + [.pageBreak]

    package var title: String {
        switch self {
        case .pageNumber: return "Номер страницы"
        case .field(let field): return field.title
        case .symbol(let text): return text == "\u{00A0}" ? "Неразрывный пробел" : "Символ " + text
        case .pageBreak: return "Разрыв страницы"
        }
    }

    package enum Availability: Equatable {
        case hidden
        case disabled(String)
        case enabled

        package var isEnabled: Bool { self == .enabled }
        package var isVisible: Bool { self != .hidden }
    }

    /// Что известно о месте курсора (без доступа к документу — для тестов).
    package struct Context: Equatable {
        /// Документ открыт в режиме «Документ» (вне него команд нет).
        package var isDocument = true
        /// Правится колонтитул: поля там вставляются, остальное — нет.
        package var inHeader = false
        /// Курсор в ячейке таблицы.
        package var inTableCell = false
        /// Почему сюда нельзя набирать (`nil` — можно): защищённое место, граница ячейки…
        package var textRefusal: String?
        /// Почему сюда нельзя вставить поле (`nil` — можно): курсор внутри другого поля…
        package var fieldRefusal: String?
        /// У документа есть имя файла (поле `FILENAME`).
        package var hasFileName = true

        package init(isDocument: Bool = true, inHeader: Bool = false, inTableCell: Bool = false, textRefusal: String? = nil,
                     fieldRefusal: String? = nil, hasFileName: Bool = true) {
            self.isDocument = isDocument
            self.inHeader = inHeader
            self.inTableCell = inTableCell
            self.textRefusal = textRefusal
            self.fieldRefusal = fieldRefusal
            self.hasFileName = hasFileName
        }
    }

    package func availability(in context: Context) -> Availability {
        guard context.isDocument else { return .hidden }
        switch self {
        case .pageNumber, .field:
            if self == .field(.fileName), !context.hasFileName { return .disabled("У документа ещё нет имени файла") }
            if let reason = context.fieldRefusal { return .disabled(reason) }
            return .enabled
        case .symbol:
            if context.inHeader { return .disabled("В колонтитуле символ набирается с клавиатуры") }
            if let reason = context.textRefusal { return .disabled(reason) }
            return .enabled
        case .pageBreak:
            if context.inHeader { return .disabled("В колонтитуле разрыв страницы не ставится") }
            if context.inTableCell { return .disabled("В ячейке таблицы разрыв страницы не ставится") }
            if let reason = context.textRefusal { return .disabled(reason) }
            return .enabled
        }
    }

    package static func visible(in context: Context) -> [InsertCommand] {
        catalog.filter { $0.availability(in: context).isVisible }
    }
}

extension DocumentController {
    /// Состояние курсора для `InsertCommand.availability`: проверки «можно ли сюда» — пробными расчётами правки без применения.
    package var insertContext: InsertCommand.Context {
        guard let tab, tab.mode == .document else { return InsertCommand.Context(isDocument: false) }
        let units = selectedUnits
        var context = InsertCommand.Context()
        context.hasFileName = tab.document.url != nil
        if let index = rendering.paragraph(atUnit: min(units.location, max(0, rendering.length - 1))) {
            context.inTableCell = model.body.paragraphs[safe: index]?.cell != nil
        }
        context.textRefusal = DocTextEditor.replace(units, with: "x", model: model, map: rendering.map, source: tab.text).refusal
        if case .failure(let failure) = DocHeaderFooterEdits.insertField(.page, story: .body, unit: units.location, map: rendering.map,
                                                                         source: tab.text, model: model) {
            context.fieldRefusal = failure.reason
        }
        return context
    }

    /// Выполнить команду вкладки «Вставка» на месте курсора. `false` — сейчас недоступна или отказала (отказ показан подсказкой).
    @discardableResult
    package func perform(_ command: InsertCommand) -> Bool {
        guard let tab else { return false }
        let context = insertContext
        if case .disabled(let reason) = command.availability(in: context) {
            show(notice: reason)
            Feedback.beep()
            return false
        }
        guard command.availability(in: context).isEnabled else { return false }
        switch command {
        case .symbol(let text): return perform(replacing: selectedUnits, with: text)
        case .pageBreak: return perform(replacing: selectedUnits, with: "\u{0C}")
        case .pageNumber: return insertBodyField(.page, tab: tab)
        case .field(let field): return insertBodyField(field, tab: tab)
        }
    }

    private func insertBodyField(_ field: HeaderField, tab: EditorTab) -> Bool {
        let units = selectedUnits
        let before = rendering.length
        let result = DocHeaderFooterEdits.insertField(field, story: .body, unit: units.location, map: rendering.map, source: tab.text,
                                                      model: model, fileName: tab.document.url?.lastPathComponent ?? "")
        switch result {
        case .failure(let failure):
            show(notice: "Нельзя без потерь: \(failure.reason.lowercasedFirst). Изменить это можно в режиме «Код»")
            Feedback.beep()
            return false
        case .success(let plan):
            guard let edits = FormatCheck.merged(plan.edits) else { return false }
            return apply(edits.map { DocEdit(range: $0.range, text: $0.string) }, actionName: field.title) { rendering in
                // Курсор — сразу после вставленного поля (вставка добавляет единицы только в этом месте).
                NSRange(location: units.location + max(0, rendering.length - before), length: 0)
            }
        }
    }
}
