import AppKit
import SwiftUI

// MARK: - QR

struct QRPage: View {
    @AppStorage(Pref.qr) private var enabled = true
    @ObservedObject private var permissions = PermissionsModel.shared

    var body: some View {
        Form {
            Section {
                Toggle("Мгновенный QR", isOn: $enabled)
                Text("Одно сочетание для двух дел: сделать QR-код из выделенного текста или прочитать QR-код с экрана.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Как пользоваться") {
                ActionShortcutRow(action: .qr, text: "Выделен текст — появится его QR-код: скопировать картинку или сохранить.")
                ActionShortcutRow(action: .qr, text: "Ничего не выделено — QR-коды на экране распознаются и копируются; ссылку можно сразу открыть.")
                if !permissions.screenRecording {
                    Text("Для чтения QR с экрана нужно разрешение «Запись экрана».").foregroundStyle(.orange)
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("QR-коды")
    }
}
