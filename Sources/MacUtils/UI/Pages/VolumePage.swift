import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUAppVolume

// MARK: - Громкость

struct VolumePage: View {
    @AppStorage(Pref.appVolume) private var enabled = true
    @AppStorage(Pref.appVolumeKeyCode) private var keyCode = LayoutHotKey.controlOptionV.keyCode
    @AppStorage(Pref.appVolumeModifiers) private var modifiers = LayoutHotKey.controlOptionV.modifiers
    @ObservedObject private var model = AppVolume.shared

    private var hotKey: LayoutHotKey { LayoutHotKey(keyCode: keyCode, modifiers: modifiers) }

    var body: some View {
        SettingsPage(.volume, isOn: $enabled, toggleLabel: "Громкость для каждого приложения", toggleEnabled: AppVolume.isSupported) {
            Footnote("Громкость запоминается. Перехватываются только приложения, у которых она не 100 % — остальные звучат как обычно.")
            if !AppVolume.isSupported {
                Banner(.warning, title: "Нужна macOS 14.2 или новее.")
            } else if enabled {
                GroupLabel("Сейчас играют")
                Card { AppVolumeList(model: model) }
                if model.permissionSuspect {
                    Banner(.warning, title: "Перехват не получает звук — разрешите Mac Utils «Запись системного звука» (Конфиденциальность → Запись экрана и системного звука).") {
                        Button("Открыть настройки") { model.openPrivacySettings() }.buttonStyle(.graphite(.primary, size: .compact))
                    }
                }
                if let error = model.lastError {
                    Banner(.danger, title: error)
                }
                GroupLabel("Панель громкости")
                ListCard {
                    Row("Открыть панель",
                        subtitle: "Плавающая панель со списком играющих приложений. Esc или клик мимо — закрыть. Двойной клик по процентам — вернуть 100 %.",
                        systemImage: "slider.horizontal.3") {
                        ShortcutRecorder(hotKey: hotKey, suspend: { recording in
                            if recording { HotKeyCenter.shared.unregister(id: HotKeyID.appVolume) } else { AppVolume.shared.sync() }
                        }, validate: { HotKeyPrefs.shared.problem($0, for: .appVolume) }) {
                            $0.save(codeKey: Pref.appVolumeKeyCode, modifiersKey: Pref.appVolumeModifiers)
                        }
                    }
                }
                Footnote("При первом изменении громкости macOS спросит разрешение на запись системного звука — оно нужно, чтобы перехватить звук приложения. Ничего не записывается и не сохраняется.")
            } else {
                // Список играющих программ — живой: при выключенной функции вместо него пустое состояние.
                Card { EmptyState.featureOff(.volume) { enabled = true } }
            }
        }
        .onAppear { AppVolume.shared.refresh() }
    }
}
