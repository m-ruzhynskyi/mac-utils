import SwiftUI

/// Панель форматирования режима «Документ» (`d01`): полоса 44 pt под заголовком. Этапы D-4/D-4а (Разработчик 4)
/// заменяют этот файл целиком — шрифт, размер, Ж/К/Ч/S, цвет, маркер, выравнивание, интервалы, отступы, ¶, линейка.
/// Пока — отмена, повтор и ¶.
struct DocFormatBar: View {
    @ObservedObject var tab: EditorTab
    @ObservedObject var document: DocumentController

    var body: some View {
        HStack(spacing: DS.Space.s) {
            button("Отменить (⌘Z)", "arrow.uturn.backward", enabled: tab.undo.canUndo) { tab.undo.undo() }
            button("Повторить (⇧⌘Z)", "arrow.uturn.forward", enabled: tab.undo.canRedo) { tab.undo.redo() }
            Spacer(minLength: 0)
            button("Невидимые символы (⌥⌘I)", "paragraphsign", active: document.showsInvisibles) {
                EditorWindowController.shared.workspace.showsInvisibles.toggle()
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 44)
        .background(Color.dsSide)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 1) }
    }

    private func button(_ title: String, _ symbol: String, enabled: Bool = true, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? Color.dsAccInk : Color.dsText)
                .frame(width: 32, height: 30)
                .background(active ? Color.dsAcc : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : DS.State.disabledOpacity)
        .help(title)
        .accessibilityLabel(title)
    }
}
