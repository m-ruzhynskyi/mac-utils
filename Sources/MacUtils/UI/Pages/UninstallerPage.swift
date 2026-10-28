import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUUninstaller

// MARK: - Общие части страниц-инструментов (Программы, Монитор, Задачи, Очистка)

/// Нижняя полоса действий: тот же фон, разделитель сверху.
struct ToolsBar<Content: View>: View {
    var compact = false
    let content: Content

    init(compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        HStack(spacing: compact ? DS.Space.s : DS.Space.m) { content }
            .padding(.horizontal, compact ? DS.Space.s : 0)
            .padding(.vertical, compact ? DS.Space.s : DS.Space.xs)
            .overlay(alignment: .top) {
                if compact { Rectangle().fill(Color.dsLine).frame(height: 1).accessibilityHidden(true) }
            }
    }
}

// MARK: - Удаление программ

struct UninstallerPage: View {
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var model: UninstallerModel
    var compact = false

    @MainActor
    init(compact: Bool = false, model: UninstallerModel? = nil) {
        self.compact = compact
        _model = ObservedObject(wrappedValue: model ?? .shared)
    }

    var body: some View {
        ToolsPageFrame(.uninstaller, compact: compact) {
            VStack(alignment: .leading, spacing: compact ? 0 : DS.Space.m) {
                fullDiskAccessBar
                UninstallerView(model: model, compact: compact)
            }
        }
        .onAppear {
            permissions.refresh()
            if model.apps.isEmpty { model.reload() }
        }
    }

    /// Нужен для контейнеров приложений из App Store и части защищённых папок.
    @ViewBuilder
    private var fullDiskAccessBar: some View {
        if permissions.fullDiskAccess == false {
            Banner(.warning,
                   title: "Нет «Полного доступа к диску» — часть контейнеров может не удалиться.",
                   message: "Уже включили? Доступ действует после перезапуска Mac Utils. Если и после перезапуска не видно — удалите Mac Utils из списка кнопкой «−» и добавьте снова.") {
                Button("Открыть настройки") { Permissions.openFullDiskAccess() }.buttonStyle(.graphite(.primary, size: .compact))
                Button("Перезапустить Mac Utils") { Permissions.relaunch() }.buttonStyle(.graphite(.secondary, size: .compact))
            }
            .padding(.horizontal, compact ? DS.Space.s : 0)
            .padding(.top, compact ? DS.Space.s : 0)
        } else if permissions.fullDiskAccess == true && !compact {
            HStack(spacing: DS.Space.s) {
                Pill(.success, "Полный доступ к диску есть")
                Spacer()
            }
        }
    }
}
