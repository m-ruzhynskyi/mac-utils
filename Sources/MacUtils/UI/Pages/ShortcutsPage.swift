import AppKit
import SwiftUI

/// Компактный блок внизу «Горячих клавиш»: те же действия есть в «Командах» и по ссылкам `macutils://…`.
struct ShortcutsLinksBlock: View {
    @State private var showing = false

    var body: some View {
        HStack {
            Text("Эти же действия есть в приложении «Команды» и ссылками macutils://")
                .font(DS.Font.body).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Все ссылки…") { showing = true }
                .buttonStyle(.graphite(.secondary))
        }
        .sheet(isPresented: $showing) { ShortcutsLinksSheet() }
    }
}

/// Лист «Все ссылки»: все действия Mac Utils для приложения «Команды» и их ссылки с копированием.
struct ShortcutsLinksSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Footnote("В «Командах» найдите «Mac Utils» среди приложений: у каждого действия свои параметры (место окна, файл, срок «Не засыпать»…). Частые действия вызываются и Siri или Spotlight: «Снимок экрана в Mac Utils». Ссылку можно вставить в «Открыть URL» или открыть из терминала: open \"macutils://snap?left\".")
                    ForEach(groups, id: \.self) { group in
                        GroupLabel(group)
                        ListCard {
                            ForEach(AppAction.catalog.filter { $0.group == group }) { item in
                                Row(item.title, subtitle: "«\(item.shortcut)» · \(item.link)") {
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(item.link, forType: .string)
                                        Toast.show("Ссылка скопирована", symbol: "link")
                                    } label: { Label("Копировать", systemImage: "doc.on.doc") }
                                        .buttonStyle(.graphite(.secondary, size: .compact))
                                        .help(item.link)
                                        .accessibilityLabel("Копировать ссылку «\(item.title)»")
                                }
                            }
                        }
                    }
                    Footnote("Ссылки, которые меняют файлы (значения $, кодировка, переводы строк), сначала спрашивают: открыть macutils:// может любая программа или страница. Действия «Команд» не спрашивают — их настраиваете вы сами.")
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .buttonStyle(.graphite(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
    }

    private var groups: [String] {
        var seen = Set<String>()
        return AppAction.catalog.map(\.group).filter { seen.insert($0).inserted }
    }
}
