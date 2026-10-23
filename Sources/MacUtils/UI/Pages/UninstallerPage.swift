import AppKit
import SwiftUI
import MUCore
import MUDesign

// MARK: - Общие части страниц-инструментов (Программы, Монитор, Задачи, Очистка)

/// Рама страницы-инструмента. В окне настроек: фон `bg`, шапка `PageHeader`, поля как у страниц настроек;
/// в панели из строки меню (`compact`) — только содержимое.
struct ToolsPageFrame<Accessory: View, Content: View>: View {
    let section: SettingsSection
    var compact = false
    let accessory: Accessory
    let content: Content

    init(_ section: SettingsSection, compact: Bool, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.section = section
        self.compact = compact
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        if compact {
            content
        } else {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                PageHeader(section) { accessory }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, DS.Space.pageVertical)
            .padding(.horizontal, DS.Space.pageHorizontal)
            .padding(.bottom, DS.Space.xl)
            .frame(maxWidth: DS.Size.contentMaxWidth + 2 * DS.Space.pageHorizontal, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.dsBg)
            .navigationTitle(section.title)
        }
    }
}

extension ToolsPageFrame where Accessory == EmptyView {
    init(_ section: SettingsSection, compact: Bool, @ViewBuilder content: () -> Content) {
        self.init(section, compact: compact, accessory: { EmptyView() }, content: content)
    }
}

/// Поле поиска: `field`, обводка `line`, радиус 10, лупа.
struct ToolsSearchField: View {
    let prompt: String
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.dsMute)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Color.dsMute))
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(.dsText)
                .focused($focused)
                .accessibilityLabel(prompt)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.dsField, in: shape)
        .overlay(shape.strokeBorder(focused ? Color.dsAccLine : Color.dsLine, lineWidth: focused ? DS.State.focusRing : 1))
    }
}

/// Сегментный выбор на всю доступную ширину (сегменты равной ширины): `panel` + `line`, радиус 12, выбранный — лайм.
/// Свой, потому что `Segmented` из компонентов имеет фиксированную ширину.
struct ToolsSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous)
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(on ? DS.Font.buttonPrimary : DS.Font.bodyStrong)
                        .foregroundStyle(on ? Color.dsAccInk : Color.dsMute)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(on ? Color.dsAcc : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(DS.Space.xs)
        .frame(maxWidth: .infinity)
        .background(Color.dsPanel, in: shape)
        .overlay(shape.strokeBorder(Color.dsLine, lineWidth: 1))
    }
}

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
