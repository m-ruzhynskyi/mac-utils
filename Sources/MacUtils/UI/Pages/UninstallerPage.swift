import AppKit
import SwiftUI

// MARK: - Инструменты

// MARK: - Удаление программ

struct UninstallerPage: View {
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var model = UninstallerModel.shared
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            fullDiskAccessBar
            UninstallerView(model: model, compact: compact)
        }
        .navigationTitle("Удаление программ")
        .onAppear {
            permissions.refresh()
            if model.apps.isEmpty { model.reload() }
        }
    }

    /// Нужен для контейнеров приложений из App Store и части защищённых папок.
    @ViewBuilder
    private var fullDiskAccessBar: some View {
        if permissions.fullDiskAccess == false {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Нет «Полного доступа к диску» — часть контейнеров может не удалиться.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Уже включили? Доступ действует после перезапуска Mac Utils. Если и после перезапуска не видно — удалите Mac Utils из списка кнопкой «−» и добавьте снова.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Открыть настройки") { Permissions.openFullDiskAccess() }
                        Button("Перезапустить Mac Utils") { Permissions.relaunch() }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.orange.opacity(0.1))
        } else if permissions.fullDiskAccess == true && !compact {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Полный доступ к диску есть").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
