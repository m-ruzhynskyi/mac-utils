import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUScreenshot

// MARK: - QR

struct QRPage: View {
    @AppStorage(Pref.qr) private var enabled = true
    @ObservedObject private var permissions = PermissionsModel.shared

    var body: some View {
        SettingsPage(.qr, isOn: $enabled, toggleLabel: "Мгновенный QR") {
            if enabled && !permissions.screenRecording {
                Banner(.warning, title: "Для чтения QR с экрана нужно разрешение «Запись экрана».") {
                    Button("Открыть настройки") {
                        Permissions.requestScreenRecording()
                        Permissions.open(.screenRecording)
                    }
                    .buttonStyle(.graphite(.primary, size: .compact))
                }
            }
            GroupLabel("Как пользоваться")
            ListCard {
                HintRow(action: .qr, text: "Выделен текст — появится его QR-код: скопировать картинку или сохранить.")
                HintRow(action: .qr, text: "Ничего не выделено — QR-коды на экране распознаются и копируются; ссылку можно сразу открыть.")
            }
            .disabled(!enabled)
        }
    }
}
