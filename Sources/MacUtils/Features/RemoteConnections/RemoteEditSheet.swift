import MURemoteConnections
import SwiftUI

/// Что правим: новая запись или существующая.
struct RemoteEditTarget: Identifiable {
    let record: ConnectionRecord?
    var id: String { record?.identity ?? "new" }
}

/// «Правка записи» и «Добавить запись» (m16/m17). Только для .xml: правки сразу пишутся в файл.
/// Пароль существующей записи не читается и не показывается: поле пустое — пароль в файле не меняется.
struct RemoteEditSheet: View {
    let center: RemoteConnectionsCenter
    let record: ConnectionRecord?
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ConnectionDraft
    @State private var password = ""
    @State private var removePassword = false
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var showProblems = false

    init(center: RemoteConnectionsCenter, record: ConnectionRecord?) {
        self.center = center
        self.record = record
        var draft = record.map(ConnectionDraft.init) ?? ConnectionDraft()
        if record == nil { draft.program = center.defaultProgram }
        _draft = State(initialValue: draft)
    }

    private var program: RemoteProgram { draft.program ?? center.defaultProgram }
    private var problems: [ConnectionDraft.Problem] { draft.problems }
    private var fileName: String { center.fileURL?.lastPathComponent ?? "connections.xml" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                HeaderTile(systemImage: record == nil ? "plus" : "pencil")
                VStack(alignment: .leading, spacing: 2) {
                    Text(record == nil ? RL("Добавить запись") : RL("Правка записи"))
                        .font(DS.Font.dialogTitle).foregroundStyle(.dsText).accessibilityAddTraits(.isHeader)
                    Text(RL("%@ · правки записываются сразу в файл", fileName)).font(DS.Font.rowSub).foregroundStyle(.dsMute)
                }
            }
            field(RL("Название"), problem: showProblems && problems.contains(.missingName) ? RL("Укажите название") : nil) {
                TextField(RL("Название"), text: $draft.name).textFieldStyle(.graphite)
            }
            field(RL("Программа")) {
                Segmented(selection: Binding(get: { program }, set: { draft.program = $0 }),
                          options: RemoteProgram.allCases.map { ($0, $0.title) })
            }
            field(RL("ID или алиас"), problem: idProblem) {
                TextField("123 456 789", text: $draft.id).textFieldStyle(.graphiteMono)
            }
            field(RL("Пароль")) {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField(passwordPlaceholder, text: $password).textFieldStyle(.graphite).disabled(removePassword)
                    if record?.hasPassword == true {
                        Toggle(RL("Убрать пароль из файла"), isOn: $removePassword).toggleStyle(.checkbox)
                            .font(DS.Font.rowSub)
                    }
                }
            }
            HStack(alignment: .top, spacing: DS.Space.m) {
                field(RL("Группа")) { TextField(RL("Группа"), text: $draft.group).textFieldStyle(.graphite) }
                field(RL("Теги")) { TextField(RL("через запятую"), text: $draft.tags).textFieldStyle(.graphite) }
            }
            field(RL("Заметка")) { TextField("—", text: $draft.note).textFieldStyle(.graphite) }
            Label(RL("Перед записью создаётся %@.bak с теми же правами.", fileName), systemImage: "doc.on.doc")
                .font(DS.Font.rowSub).foregroundStyle(.dsMute)
            if let error {
                Banner(.danger, title: error) { EmptyView() }
            }
            HStack(spacing: DS.Space.s) {
                if let record {
                    Button(confirmDelete ? RL("Точно удалить?") : RL("Удалить запись")) {
                        if confirmDelete { perform { try center.delete(record) } } else { confirmDelete = true }
                    }
                    .buttonStyle(.graphite(.danger))
                }
                Spacer()
                Button(RL("Отмена")) { close() }.buttonStyle(.graphite(.secondary)).keyboardShortcut(.cancelAction)
                Button(record == nil ? RL("Добавить") : RL("Сохранить")) { save() }
                    .buttonStyle(.graphite(.primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Color.dsBg)
        .onDisappear { password = "" }
    }

    private var passwordPlaceholder: String {
        if record?.hasPassword == true { return RL("Не меняется") }
        return RL("Постоянный пароль %@", program.title)
    }

    private var idProblem: String? {
        guard showProblems || !draft.id.isEmpty else { return nil }
        if problems.contains(.invalidID), !draft.id.isEmpty || showProblems { return RL("ID — 9–10 цифр или алиас вида имя@ad") }
        if problems.contains(.aliasNotSupported) { return RL("%@ не открывает алиасы — нужен числовой ID", program.title) }
        return nil
    }

    private func field<Content: View>(_ title: String, problem: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(DS.Font.manrope(12, .semibold, relativeTo: .caption)).foregroundStyle(.dsMute)
            content()
                .overlay {
                    if problem != nil {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Tone.danger.text, lineWidth: DS.State.focusRing)
                            .allowsHitTesting(false)
                    }
                }
            if let problem {
                Label(problem, systemImage: "xmark.circle.fill")
                    .font(DS.Font.rowSub).foregroundStyle(DS.Tone.danger.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        showProblems = true
        guard problems.isEmpty else { return }
        var draft = self.draft
        draft.program = program
        if removePassword { draft.password = "" } else if !password.isEmpty { draft.password = password }
        perform { try center.save(draft, replacing: record) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            close()
        } catch let e as XMLEditError {
            error = Self.message(e)
        } catch {
            self.error = RL("Файл не записан")
        }
    }

    private func close() {
        password = ""
        dismiss()
    }

    static func message(_ error: XMLEditError) -> String {
        switch error {
        case .invalid: return RL("Проверьте название и ID")
        case .entryNotFound: return RL("Записи больше нет в файле — список обновлён")
        case .unsupported: return RL("Этот файл нельзя править без потерь: нужен .xml в UTF-8 с корнем <connections>")
        case .corrupt: return RL("После правки файл не читался бы — ничего не записано")
        case .writeFailed: return RL("Файл не записан: нет прав или места. Исходный файл не тронут")
        }
    }
}
