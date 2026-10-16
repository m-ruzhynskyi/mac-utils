import AppKit
import SwiftUI

// MARK: - Громкость

struct VolumePage: View {
    @AppStorage(Pref.appVolume) private var enabled = true
    @AppStorage(Pref.appVolumeKeyCode) private var keyCode = LayoutHotKey.controlOptionV.keyCode
    @AppStorage(Pref.appVolumeModifiers) private var modifiers = LayoutHotKey.controlOptionV.modifiers
    @ObservedObject private var model = AppVolume.shared

    private var hotKey: LayoutHotKey { LayoutHotKey(keyCode: keyCode, modifiers: modifiers) }

    var body: some View {
        Form {
            Section {
                Toggle("Громкость для каждого приложения", isOn: $enabled)
                    .disabled(!AppVolume.isSupported)
                Text("Своя громкость (0–150 %) и выключение звука для каждой программы. Громкость запоминается. Перехватываются только приложения, у которых она не 100 % — остальные звучат как обычно.")
                    .foregroundStyle(.secondary)
                if !AppVolume.isSupported {
                    Text("Нужна macOS 14.2 или новее.").foregroundStyle(.orange)
                }
            }
            if enabled && AppVolume.isSupported {
                Section("Сейчас играют") {
                    AppVolumeList(model: model)
                    if model.permissionSuspect {
                        HStack {
                            Text("Перехват не получает звук — разрешите Mac Utils «Запись системного звука» (Конфиденциальность → Запись экрана и системного звука).")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Открыть настройки") { model.openPrivacySettings() }
                        }
                    }
                    if let error = model.lastError {
                        Text(error).foregroundStyle(.orange).font(.caption)
                    }
                }
                Section("Панель громкости") {
                    LabeledContent("Открыть панель") {
                        ShortcutRecorder(hotKey: hotKey, suspend: { recording in
                            if recording { HotKeyCenter.shared.unregister(id: HotKeyID.appVolume) } else { AppVolume.shared.sync() }
                        }, validate: { HotKeyPrefs.shared.problem($0, for: .appVolume) }) {
                            $0.save(codeKey: Pref.appVolumeKeyCode, modifiersKey: Pref.appVolumeModifiers)
                        }
                    }
                    Text("Плавающая панель со списком играющих приложений. Esc или клик мимо — закрыть. Двойной клик по процентам — вернуть 100 %.")
                        .foregroundStyle(.secondary)
                    Text("При первом изменении громкости macOS спросит разрешение на запись системного звука — оно нужно, чтобы перехватить звук приложения. Ничего не записывается и не сохраняется.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Громкость")
        .onAppear { AppVolume.shared.refresh() }
    }
}
