import AppKit
import SwiftUI

// Прежние общие элементы страниц — перенесены из SettingsView/SettingsExtras без изменений (волна 0 редизайна).
// Страницы переходят на компоненты дизайн-системы в волне 1; файл удаляется в конце волны 2.

// MARK: - Общие элементы

struct StatusLine: View {
    let ok: Bool
    let okText: String
    let problemText: String
    var action: (() -> Void)?
    var actionTitle = "Открыть настройки"
    /// Разрешение «Запись экрана» и «Полный доступ к диску» вступают в силу только после перезапуска: macOS до него
    /// отдаёт старое значение, поэтому рядом с «нет разрешения» есть «Перезапустить» (на случай, что оно уже выдано).
    var relaunchHint = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(ok ? okText : problemText)
                .foregroundStyle(ok ? Color.green : Color.orange)
            Spacer()
            if !ok, let action {
                Button(actionTitle, action: action)
            }
            if !ok, relaunchHint {
                Button("Перезапустить") { Permissions.relaunch() }
                    .help("Уже выдали разрешение? Оно начнёт действовать после перезапуска Mac Utils")
            }
        }
    }
}

struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold))
            .frame(minWidth: 26, minHeight: 24)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
    }
}

struct ShortcutRow: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { KeyCap(key: $0) }
            Text(text).padding(.leading, 4)
        }
    }
}

@MainActor
func accessibilityStatus(_ model: PermissionsModel, running: Bool, readyText: String) -> some View {
    var action: (() -> Void)?
    if !model.accessibility {
        action = {
            Permissions.requestAccessibility()
            Permissions.open(.accessibility)
        }
    }
    return StatusLine(
        ok: model.accessibility && running,
        okText: readyText,
        problemText: model.accessibility ? "Утилита выключена" : "Нужен доступ «Универсальный доступ»",
        action: action
    )
}

/// Строка подсказки с фактическим сочетанием из реестра (а не с жёстко написанным).
struct ActionShortcutRow: View {
    let action: HotKeyAction
    let text: String
    @ObservedObject private var prefs = HotKeyPrefs.shared

    var body: some View {
        ShortcutRow(keys: HotKeyRegistry.combo(for: action).keys, text: text)
    }
}
