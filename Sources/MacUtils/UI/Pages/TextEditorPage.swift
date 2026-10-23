import AppKit
import SwiftUI
import MUCore
import MUDesign

// MARK: - Текстовый редактор

/// Страница «Текстовый редактор» (макет e2): точки входа, знаки `$`, новые документы, сессия.
struct TextEditorPage: View {
    @AppStorage(Pref.editorSkipFirst) private var skipOn = true
    @AppStorage(Pref.editorSkipCount) private var skipCount = 3
    @AppStorage(Pref.editorNewEncoding) private var newEncoding = TextEncoding.utf8.rawValue
    @AppStorage(Pref.editorNewLineEnding) private var newLineEnding = LineEnding.lf.rawValue
    @AppStorage(Pref.editorRestoreSession) private var restore = true
    @AppStorage(Pref.editorAutosaveDrafts) private var drafts = true
    @AppStorage(Pref.editorTabWidth) private var tabWidth = 4

    static let extensions = ["frm", "rtf", "txt", "log", "json", "xml", "csv"]

    var body: some View {
        SettingsPage(.textEditor) {
            Button("Открыть редактор") { EditorWindowController.shared.show() }
                .buttonStyle(.graphite(.primary))
        } content: {
            ListCard {
                Row("Открыть редактор", subtitle: "Из любой программы. Изменить — в «Горячих клавишах»", systemImage: "keyboard") {
                    Keycap(action: .textEditor)
                }
                Row("«Открыть с помощью» в Finder", subtitle: "Mac Utils — запасной вариант, ваши программы по умолчанию не меняются",
                    systemImage: "folder") {
                    HStack(spacing: 6) {
                        ForEach(Self.extensions, id: \.self) { ext in
                            Text(".\(ext)").font(DS.Font.mono(11.5, relativeTo: .caption)).foregroundStyle(.dsText)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .capsuleFill(Color.dsField, border: Color.dsLine)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            GroupLabel("Знаки $")
            ListCard {
                Row("Пропускать первые знаки", subtitle: "Служебные $ в начале файла не трогаются и не подсвечиваются",
                    systemImage: "dollarsign") {
                    HStack(spacing: DS.Space.m) {
                        GraphiteStepper(value: Binding(get: { DollarSkip.clamp(skipCount) }, set: { skipCount = DollarSkip.clamp($0) }),
                                        range: 0...DollarSkip.maxCount, label: "Сколько знаков пропускать")
                            .disabled(!skipOn)
                        Toggle("Пропускать первые знаки", isOn: $skipOn).toggleStyle(.graphite)
                    }
                }
            }
            GroupLabel("Файлы")
            ListCard {
                Row("Кодировка новых документов", systemImage: "textformat") {
                    Picker("Кодировка новых документов", selection: $newEncoding) {
                        ForEach(TextEncoding.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .graphitePicker()
                    .fixedSize()
                }
                Row("Ширина табуляции", subtitle: "Сколько пробелов в табе — на экране и в «Табы ↔ пробелы»", systemImage: "arrow.right.to.line") {
                    GraphiteStepper(value: Binding(get: { min(max(tabWidth, 1), 8) }, set: { tabWidth = min(max($0, 1), 8) }),
                                    range: 1...8, label: "Ширина табуляции")
                }
                Row("Перевод строки новых документов", systemImage: "return") {
                    Segmented(selection: $newLineEnding, options: LineEnding.allCases.map { ($0.rawValue, $0.title) })
                }
                ToggleRow("Восстанавливать вкладки", subtitle: "После перезапуска — те же файлы и места", systemImage: "rectangle.stack",
                          isOn: $restore)
                ToggleRow("Автосохранение черновиков", subtitle: "Безымянные и несохранённые документы не пропадут при выходе и сбое",
                          systemImage: "clock.arrow.circlepath", isOn: $drafts)
            }
            Footnote("Черновики хранятся без шифрования в ~/Library/Application Support/Mac Utils/Editor.")
        }
    }
}
