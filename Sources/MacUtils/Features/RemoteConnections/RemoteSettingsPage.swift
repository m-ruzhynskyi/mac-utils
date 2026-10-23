import AppKit
import MURemoteConnections
import SwiftUI
import UniformTypeIdentifiers

/// Раздел «Удалённые подключения» в настройках (m15): файл, лист, шаблон, программа по умолчанию, клавиша, ожидание,
/// автологин, уведомление, язык, программы и «Универсальный доступ». Список компьютеров — во вкладке «Удалённые».
struct RemoteSettingsPage: View {
    @ObservedObject private var center: RemoteConnectionsCenter
    @ObservedObject private var permissions = PermissionsModel.shared
    @State private var sheets: [String] = []
    @State private var shared = false

    init(center: RemoteConnectionsCenter? = nil) {
        _center = ObservedObject(wrappedValue: center ?? .shared)
    }

    var body: some View {
        SettingsPage(.remote, subtitle: RL("Выберите компьютер из своей таблицы — AnyDesk или TeamViewer откроется и подключится, пароль введётся сам.")) {
            Banner(.warning, title: RL("Пароли лежат в вашем файле открытым текстом"),
                   message: RL("Mac Utils их не хранит и не копирует. Держите файл на зашифрованном диске (FileVault), права 600, не отправляйте его по почте.")) {
                EmptyView()
            }
            if shared, let url = center.fileURL {
                Banner(.danger, title: RL("Файл доступен другим пользователям"),
                       message: RL("Его могут прочитать другие учётные записи этого Mac. Права 600 оставят доступ только вам.")) {
                    Button(RL("Поставить 600")) {
                        try? ConnectionsFilePermissions.restrict(url)
                        refresh()
                    }
                    .buttonStyle(.graphite(.primary, size: .compact))
                }
            }
            fileGroup
            connectionGroup
            programsGroup
            GroupLabel(RL("Разрешения"))
            ListCard {
                Row(RL("Универсальный доступ"),
                    subtitle: RL("Нужен, чтобы ввести пароль в окно программы. Без него программа откроется, пароль вводите сами."),
                    systemImage: "hand.raised") {
                    HStack(spacing: DS.Space.s) {
                        Pill(Permissions.accessibility ? .success : .warning,
                             Permissions.accessibility ? RL("Разрешено") : RL("Не разрешено"))
                        Button(RL("Открыть настройки")) { Permissions.open(.accessibility) }
                            .buttonStyle(.graphite(.secondary, size: .compact))
                    }
                }
            }
            Footnote(RL("Диагностику (сколько записей загружено, что пропущено и почему) можно открыть из нижней строки вкладки «Удалённые»."))
        }
        .onAppear(perform: refresh)
        .onChange(of: center.fileURL) { _, _ in refresh() }
        .onChange(of: center.state) { _, _ in refresh() }
    }

    private func refresh() {
        center.start()
        sheets = center.fileURL.map { RemoteConnectionsCenter.sheetNames(of: $0) } ?? []
        shared = center.fileURL.map(ConnectionsFilePermissions.isShared) ?? false
    }

    // MARK: Файл

    @ViewBuilder private var fileGroup: some View {
        GroupLabel(RL("Файл подключений"))
        ListCard {
            Row(RL("Файл"), subtitle: RL("Только путь; пароли читаются в момент подключения"), systemImage: "doc") {
                HStack(spacing: DS.Space.s) {
                    if let url = center.fileURL {
                        Text(url.path)
                            .font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsText)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 240, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .capsuleFill(Color.dsField, border: Color.dsLine)
                            .help(url.path)
                    }
                    Button(RL("Выбрать…")) { center.chooseFile() }.buttonStyle(.graphite(.secondary, size: .compact))
                    if let url = center.fileURL {
                        IconButton(RL("Показать в Finder"), systemImage: "folder", compact: true) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
            Row(RL("Лист"), subtitle: RL("Только для .xlsx"), systemImage: "tablecells") {
                Picker(RL("Лист"), selection: Binding(get: { center.sheetName ?? "" },
                                                      set: { center.setSheet($0.isEmpty ? nil : $0) })) {
                    Text(RL("Первый")).tag("")
                    ForEach(sheets, id: \.self) { Text($0).tag($0) }
                }
                .graphitePicker()
                .disabled(sheets.isEmpty)
            }
            Row(RL("Шаблон файла"), subtitle: RL("Пустая таблица с нужными колонками и примером"), systemImage: "doc.badge.plus") {
                HStack(spacing: DS.Space.s) {
                    Button(".xlsx") { center.createTemplate(xlsx: true) }.buttonStyle(.graphite(.secondary, size: .compact))
                    Button(".xml") { center.createTemplate(xlsx: false) }.buttonStyle(.graphite(.secondary, size: .compact))
                }
            }
        }
    }

    // MARK: Подключение

    @ViewBuilder private var connectionGroup: some View {
        GroupLabel(RL("Подключение"))
        ListCard {
            Row(RL("Программа по умолчанию"),
                subtitle: RL("Если в колонке «Программа» пусто. «Спрашивать» — выбор при подключении, когда в файле есть обе программы"),
                systemImage: "app.badge") {
                Segmented(selection: Binding(get: { center.defaultProgramSetting?.rawValue ?? "" },
                                             set: { center.defaultProgramSetting = RemoteProgram(rawValue: $0) }),
                          options: RemoteProgram.allCases.map { ($0.rawValue, $0.title) } + [("", RL("Спрашивать"))])
            }
            Row(RL("Горячая клавиша"), subtitle: RL("Открывает окно поиска из любого приложения. Работает, когда выбран файл подключений"), systemImage: "keyboard") {
                Keycap(action: .remoteConnections)
            }
            Row(RL("Ждать окно пароля"), subtitle: RL("Если окно не появилось — считаем автологином"), systemImage: "timer") {
                Segmented(selection: Binding(get: { center.timeoutSeconds }, set: { center.timeoutSeconds = $0 }),
                          options: [10, 20, 40].map { ($0, RL("%@ с", $0)) })
            }
            ToggleRow(RL("Входить автоматически"), subtitle: RL("Ставить галочку «Входить автоматически» в окне AnyDesk"),
                      systemImage: "arrow.triangle.2.circlepath",
                      isOn: Binding(get: { center.autologin }, set: { center.autologin = $0 }))
            ToggleRow(RL("Уведомление о подключении"), subtitle: RL("Короткое сообщение после ввода пароля"), systemImage: "bell",
                      isOn: Binding(get: { center.notifySuccess }, set: { center.notifySuccess = $0 }))
            Row(RL("Язык"), subtitle: RL("Список, палитра, сообщения о подключении и этот раздел"), systemImage: "globe") {
                Segmented(selection: Binding(get: { center.language }, set: { center.language = $0 }),
                          options: RemoteLanguage.allCases.map { ($0, $0.title) })
            }
        }
    }

    // MARK: Программы

    @ViewBuilder private var programsGroup: some View {
        GroupLabel(RL("Программы"))
        ListCard {
            ForEach(RemoteProgram.allCases, id: \.self) { program in
                let installed = center.isInstalled(program)
                Row(program.title, subtitle: programDetails(program), systemImage: installed ? "app.badge.checkmark" : "app.dashed") {
                    HStack(spacing: DS.Space.s) {
                        Pill(installed ? .success : .neutral, installed ? RL("Найден") : RL("Не найден"))
                        if !installed {
                            Button(RL("Скачать")) { NSWorkspace.shared.open(program.downloadURL) }
                                .buttonStyle(.graphite(.secondary, size: .compact))
                        }
                    }
                }
            }
            Row(RL("RustDesk и другие"), subtitle: RL("Поставщик подключается отдельным модулем — файл и список менять не придётся"),
                systemImage: "puzzlepiece.extension") {
                Pill(.neutral, RL("Скоро"))
            }
        }
    }

    private func programDetails(_ program: RemoteProgram) -> String {
        let path = center.appURL(program)?.path ?? "/Applications/\(program.title).app"
        let how = program == .anyDesk ? RL("anydesk:ID + ввод пароля через Универсальный доступ")
                                      : RL("ввод пароля через Универсальный доступ")
        return "\(path) · \(program.bundleID) · \(how)"
    }
}
