#if DEBUG
import SwiftUI

/// Витрина компонентов Graphite во всех состояниях — для снимков (`UISnapshotTests`) и сверки с концептом.
/// Только в отладочной сборке.
struct ComponentsGallery: View {
    enum Part: String, CaseIterable {
        /// Как страница настроек: шапка, карточки-списки, группы, кейкапы, переключатели, чипы, сегменты, баннеры.
        case settings
        /// Поповер, первый запуск, пустые состояния, плавающие панели, таблетки, кнопки во всех состояниях.
        case surfaces
    }

    var part: Part = .settings

    @State private var login = true
    @State private var autoUpdate = true
    @State private var menuIcon = true
    @State private var dock = false
    @State private var format = "mp4"
    @State private var speed = 1.4
    @State private var switcher = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                switch part {
                case .settings: settings
                case .surfaces: surfaces
                }
            }
            .padding(.vertical, DS.Space.pageVertical)
            .padding(.horizontal, DS.Space.pageHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.dsBg)
    }

    // MARK: - Страница настроек

    @ViewBuilder private var settings: some View {
        PageHeader(.general)
        ListCard {
            ToggleRow("Открывать при входе в систему", subtitle: "Mac Utils запускается вместе с macOS", systemImage: "power", isOn: $login)
            ToggleRow("Обновляться автоматически", subtitle: "Скачивать и ставить новые версии",
                      systemImage: "arrow.triangle.2.circlepath", isOn: $autoUpdate)
            ToggleRow("Значок в строке меню", subtitle: "Панель с вкладками под значком", systemImage: "menubar.rectangle", isOn: $menuIcon)
            ToggleRow("Показывать в Dock", subtitle: "Обычно приложение живёт только в строке меню", systemImage: "dock.rectangle", isOn: $dock)
            ToggleRow("Выключенная строка", subtitle: "Состояние «недоступно»", systemImage: "nosign", isOn: .constant(true))
                .disabled(true)
        }
        GroupLabel("Горячие клавиши")
        ListCard {
            KeyRow("Снимок экрана", action: .screenshot)
            KeyRow("Распознать текст", action: .screenshotOCR)
            KeyRow("Переключатель приложений", keys: ["⌥", " Tab"])
            KeyRow("Рисование на экране", keys: ["⌃", "⌥", "A"])
        }
        GroupLabel("Панель в строке меню")
        Card {
            Text("Какие вкладки показывать и в каком порядке").font(DS.Font.body).foregroundStyle(.dsMute)
            HStack(spacing: DS.Space.s) {
                Chip("Музыка", selected: true) {}
                Chip("Программы", selected: true) {}
                Chip("Монитор", selected: true) {}
                Chip("+ Окна", selected: false) {}
            }
        }
        GroupLabel("Строки с контролами")
        ListCard {
            PathRow("Папка для снимков", subtitle: "Раскладывать по дням и программам", url: URL(fileURLWithPath: "/Users/Shared/Снимки"),
                    isCustom: true, choose: {}, reset: {}, resetHelp: "Вернуть Рабочий стол")
            SliderRow("Скорость", systemImage: "computermouse", value: $speed, in: 0.3...3) { String(format: "%.1f×", $0) }
            Row("Формат видео", systemImage: "film") {
                Segmented(selection: $format, options: [("mp4", "MP4"), ("gif", "GIF")])
            }
            PermissionRow(.accessibility, state: .granted, purpose: "Для ⌘X/⌘V в Finder, прокрутки и переключателя")
            PermissionRow(.screenRecording, state: .needed, purpose: "Для скриншотов, записи и трансляции", action: {}, relaunchHint: true)
            FeatureStatusRow(tone: .warning, label: "Нужен доступ", detail: "Нужен доступ «Универсальный доступ»",
                             actions: [StatusAction(title: "Открыть настройки") {}])
        }
        GroupLabel("Сочетания и подсказки")
        Card {
            ShortcutHintRow(keys: ["⌘", "C"], text: "Скопировать в буфер обмена.")
            ShortcutHintRow(keys: ["Esc"], text: "Закрыть.")
        }
        GroupLabel("Баннеры")
        ForEach(DS.Tone.allCases, id: \.self) { tone in
            Banner(tone, title: Self.name(tone), message: "Пояснение баннера — обычным текстом, цвет только у рамки и плитки.") {
                Button("Главное") {}.buttonStyle(.graphite(.primary, size: .compact))
                Button("Другое") {}.buttonStyle(.graphite(.secondary, size: .compact))
            }
        }
        HStack {
            Text("Версия · проверено сегодня").font(DS.Font.manrope(13, .regular, relativeTo: .callout)).foregroundStyle(.dsMute)
            Spacer()
            Button("Проверить сейчас") {}.buttonStyle(.graphite(.primary))
        }
    }

    // MARK: - Поверхности

    @ViewBuilder private var surfaces: some View {
        HStack(alignment: .top, spacing: DS.Space.xxl) {
            // Поповер: шапка, вкладки, группа быстрых действий.
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    AppMark(size: 22)
                        .frame(width: 38, height: 38)
                        .background(Color.dsField, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Mac Utils").font(DS.Font.headline).foregroundStyle(.dsText)
                        Text("актуальная версия").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                    }
                    Spacer()
                    IconButton("Тёплый экран", systemImage: "sun.horizon", active: true) {}
                    IconButton("Настройки", systemImage: "gearshape") {}
                }
                GroupLabel("Захват")
                ListCard(style: .field) {
                    Row("Снять область или окно", systemImage: "camera.viewfinder", tile: .accent) { Keycap(action: .screenshot, compact: true, onPanel: true) }
                    Row("Распознать текст", subtitle: "Текст сразу в буфер", systemImage: "text.viewfinder") {
                        Keycap(action: .screenshotOCR, compact: true, onPanel: true)
                    }
                    Row("Записать экран", subtitle: "Выделите область и нажмите R", systemImage: "record.circle", tile: .record) {
                        Keycap(["R"], compact: true, onPanel: true)
                    }
                    ToggleRow("Переключатель приложений", subtitle: "Превью каждого окна", systemImage: "rectangle.on.rectangle", isOn: $switcher)
                }
            }
            .padding(DS.Space.l)
            .frame(width: 420)
            .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.popover, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.popover, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))

            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("РАЗРЕШЕНИЯ").font(DS.Font.manrope(12, .bold, relativeTo: .caption)).tracking(1.2).foregroundStyle(.dsAccText)
                PermissionCard(title: "Универсальный доступ", purpose: "Для ⌘X/⌘V в Finder, прокрутки и переключателя", state: .granted)
                PermissionCard(title: "Запись экрана", purpose: "Для скриншотов, записи и трансляции", state: .needed, action: {})
                PermissionCard(title: "Звук приложений", purpose: "Для громкости по приложениям, по желанию", state: .needed, optional: true)
                ProgressBar(value: 0.62)
                Text("Загрузка… 62%").font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
        }
        GroupLabel("Кнопки")
        HStack(spacing: DS.Space.s) {
            Button("Главная") {}.buttonStyle(.graphite(.primary))
            Button("Вторичная") {}.buttonStyle(.graphite(.secondary))
            Button("Призрачная") {}.buttonStyle(.graphite(.ghost))
            Button("Стоп") {}.buttonStyle(.graphite(.danger))
            Button("Выключена") {}.buttonStyle(.graphite(.primary)).disabled(true)
            Button("Крупная") {}.buttonStyle(.graphite(.primary, size: .large))
            IconButton("Скопировать", systemImage: "doc.on.doc") {}
            IconButton("Выключена", systemImage: "folder") {}.disabled(true)
        }
        GroupLabel("Таблетки, кейкапы, инструменты")
        HStack(spacing: DS.Space.s) {
            ForEach(DS.Tone.allCases, id: \.self) { Pill($0, Self.name($0)) }
            Pill(.danger, "В эфире", caps: true)
            Keycap(["⌘", "⇧", "X"])
            Keycap(["Esc"], compact: true)
        }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: 3), spacing: DS.Space.s) {
            ToolTile(systemImage: "cursorarrow", title: "Выбор", key: "V")
            ToolTile(systemImage: "arrow.up.right", title: "Стрелка", key: "1")
            ToolTile(systemImage: "rectangle", title: "Прямоугольник", key: "2")
            ToolTile(systemImage: "arrow.uturn.backward", title: "Отменить", key: "⌘Z")
            ToolTile(systemImage: "record.circle", title: "Запись экрана", key: "R")
            ToolTile(systemImage: "xmark", title: "Закрыть", key: "Esc")
        }
        .padding(.vertical, DS.Space.l)
        .padding(.horizontal, 18)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        GroupLabel("Пустые состояния и плавающие панели")
        HStack(alignment: .top, spacing: DS.Space.l) {
            Card { EmptyState("Пока нет записей", systemImage: "waveform", message: "Записи встреч появятся здесь.", compact: true) }
            Card { EmptyState.featureOff(.volume) {} }
            Card { EmptyState.loading("Ищу программы…").frame(height: 120) }
        }
        HStack(alignment: .top, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: DS.Space.m) {
                    Text("М").font(DS.Font.manrope(15, .heavy, relativeTo: .body)).foregroundStyle(.dsText)
                        .frame(width: 38, height: 38).background(Color.dsField, in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Марко хочет смотреть").font(DS.Font.manrope(14, .heavy, relativeTo: .body)).foregroundStyle(.dsText)
                        Text("731 204 8815").font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute)
                    }
                }
                HStack(spacing: DS.Space.s) {
                    Button("Отклонить") {}.buttonStyle(.graphite(.secondary, fill: true))
                    Button("Всегда") {}.buttonStyle(.graphite(.secondary, fill: true))
                    Button("Разрешить") {}.buttonStyle(.graphite(.primary, fill: true))
                }
            }
            .frame(width: 380)
            .floating(.panel)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                LiveIndicator(.broadcast, detail: "Смотрят: 2") {
                    IconButton("Стоп", systemImage: "stop.fill", compact: true) {}
                }
                LiveIndicator(.recording, since: Date(timeIntervalSinceNow: -75))
                HStack(spacing: DS.Space.m) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.dsField).frame(width: 64, height: 44)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Скопировано").font(DS.Font.manrope(13, .bold, relativeTo: .callout)).foregroundStyle(.dsText)
                        Text("Сохранено в «Снимки»").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                    }
                }
                .padding(DS.Space.m)
                .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            }
        }
    }

    private static func name(_ tone: DS.Tone) -> String {
        switch tone {
        case .success: return "Выдано"
        case .warning: return "Внимание"
        case .danger: return "Ошибка"
        case .info: return "Подсказка"
        case .neutral: return "Позже"
        }
    }
}
#endif
