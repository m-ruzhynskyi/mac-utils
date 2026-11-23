import SwiftUI
import MUCore
import MUDesign
import MULink

// MARK: - Windows-ПК

/// Макет: доска «Настройки» (`Main.dc.html`), раздел «Windows-ПК». Здесь — MU Link: связь с Mac Utils Share на ПК.
/// Остальные блоки страницы (Moonlight, буфер, файлы, ссылки) добавятся своими задачами.
struct PCPage: View {
    @State private var moonlightHost: String?
    private let keyPersistent = ShareIdentitySigner.isPersistent

    var body: some View {
        SettingsPage(.pc, subtitle: SettingsSection.pc.subtitle) {
            if !keyPersistent {
                Banner(.warning, title: "Ключ этого Mac не сохраняется.", message: "Связать с ПК можно будет после перезапуска Mac Utils.") { EmptyView() }
            }
            LinkSettingsView(client: LinkCenter.client, defaultHost: moonlightHost)
        }
        .onAppear { if moonlightHost == nil { moonlightHost = MoonlightHosts.defaultAddress() } }
    }
}
