import AppKit

/// Команды E-4: индексы, капитель, все прописные, скрытый текст; «не отрывать», «не разрывать», «с новой страницы»;
/// разрыв страницы; «Обновить поля». Всё — те же точечные правки с проверкой, что у остальных команд формата.
extension DocFormatter {
    /// Надстрочный / подстрочный: повторное нажатие возвращает обычное положение.
    package func toggleVertical(_ vertical: RTFVertical) { apply(.vertical(state.vertical == vertical ? .normal : vertical)) }
    package func toggleSmallCaps() { apply(.smallCaps(!state.smallCaps)) }
    package func toggleCaps() { apply(.caps(!state.caps)) }
    package func toggleHidden() { apply(.hidden(!state.hidden)) }

    /// Флаг абзацев выделения: включается, если он есть не у всех, иначе снимается.
    package func toggle(_ flag: DocParaFlag) {
        guard let controller, let tab = controller.tab, let target = target(), !target.paragraphs.isEmpty else { return }
        let story = controller.model.story(target.story)
        let on = !target.paragraphs.allSatisfy { story?.paragraphs[safe: $0].map { flag.value($0.props) } ?? false }
        perform(FormatEdits.flag(flag, on: on, paragraphs: target.paragraphs, story: target.story, source: tab.text, model: controller.model),
                name: flag.title)
    }

    /// Разрыв страницы на месте курсора (выделение заменяется), как ⌘↩ в Word.
    package func insertPageBreak() {
        guard let controller else { return }
        guard headerSession == nil else { return notify("В колонтитуле разрыв страницы не ставится") }
        controller.perform(replacing: controller.selectedUnits, with: "\u{0C}")
    }

    package func updateFields() {
        guard headerSession == nil else { return notify("Поля обновляются из основного текста") }
        controller?.updateFields()
    }
}

extension DocumentController {
    /// «Обновить поля»: номера страниц и число страниц — по нынешней раскладке.
    package func updateFields() {
        guard let tab else { return }
        let sections = Dictionary(grouping: pagesView.pages, by: \.section).mapValues(\.count)
        let values = DocFieldUpdate.Values(page: { [weak self] in self?.page(ofSource: $0) }, total: max(1, pagesView.pages.count),
                                           sectionPages: { sections[$0] })
        let result = DocFieldUpdate.edits(model: model, source: tab.text, values: values)
        guard !result.edits.isEmpty else {
            return show(notice: result.fields == 0 ? "В документе нет полей номера страницы" : "Поля уже показывают верные номера")
        }
        let selection = selectedUnits
        if apply(result.edits, actionName: "Обновить поля", select: { _ in selection }) {
            show(notice: "Обновлено полей: \(result.updated)")
        }
    }
}
