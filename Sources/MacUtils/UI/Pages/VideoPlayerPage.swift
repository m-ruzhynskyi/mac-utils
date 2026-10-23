import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUScreenShare

// MARK: - Видеоплеер

/// Страница «Видеоплеер» (макеты v11 и v15b): точки входа, просмотр, субтитры, пропуск интро и титров.
/// Плеер по умолчанию для всех видео и видео из браузера — не в этой версии, их здесь нет.
struct VideoPlayerPage: View {
    @AppStorage(Pref.playerOpensShots) private var opensShots = true
    @AppStorage(Pref.playerRememberPosition) private var remember = true
    @AppStorage(Pref.playerSeekStep) private var seekStep = 5.0
    @AppStorage(Pref.playerKeepAwake) private var keepAwake = true
    @AppStorage(Pref.playerSubtitlesNearby) private var nearby = true
    @AppStorage(Pref.playerSubtitleSize) private var subtitleSize = 1
    @AppStorage(Pref.playerSubtitleBackground) private var subtitleBackground = false
    @AppStorage(Pref.playerSkipAuto) private var skipAuto = false
    @AppStorage(Pref.playerNextEpisode) private var nextEpisode = true

    @State private var hiddenFolders = PlayerPrefs.skipHiddenFolders.count
    @State private var forgotten = false

    var body: some View {
        SettingsPage(.videoPlayer) {
            Button("Открыть плеер") { PlayerWindowController.show() }
                .buttonStyle(.graphite(.primary))
        } content: {
            ListCard {
                Row("Открыть плеер", subtitle: "Из любой программы. Изменить — в «Горячих клавишах»", systemImage: "keyboard") {
                    Keycap(action: .videoPlayer)
                }
                Row("«Открыть с помощью» в Finder", subtitle: "Запасной вариант, QuickTime остаётся по умолчанию", systemImage: "folder") {
                    HStack(spacing: 6) {
                        ForEach(PlayerMedia.openWithExtensions, id: \.self) { ext in
                            Text(".\(ext)").font(DS.Font.mono(11.5, relativeTo: .caption)).foregroundStyle(.dsText)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .capsuleFill(Color.dsField, border: Color.dsLine)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Row("Видео в «Моих снимках»", subtitle: "Записи экрана открываются двойным кликом", systemImage: "photo.on.rectangle.angled") {
                    Picker("Видео в «Моих снимках»", selection: $opensShots) {
                        Text("Плеер Mac Utils").tag(true)
                        Text("Программа по умолчанию").tag(false)
                    }
                    .labelsHidden()
                    .graphitePicker()
                    .fixedSize()
                }
            }
            GroupLabel("Просмотр")
            ListCard {
                ToggleRow("Запоминать место", subtitle: "Если посмотрено больше 30 с и меньше 95 %", systemImage: "clock.arrow.circlepath",
                          isOn: $remember)
                Row("Шаг перемотки ← →", systemImage: "goforward.5") {
                    Segmented(selection: $seekStep, options: PlayerPrefs.seekSteps.map { ($0, "\(Int($0)) с") })
                }
                ToggleRow("Экран не гаснет во время просмотра", subtitle: "Только пока видео играет", systemImage: "display",
                          isOn: Binding(get: { keepAwake }, set: { keepAwake = $0; PlayerSystem.shared.update() }))
                Row("Запомненные места", subtitle: forgotten ? "Очищено" : "Где остановились и «Продолжить просмотр»",
                    systemImage: "list.bullet.rectangle") {
                    Button("Очистить") {
                        PositionStore.shared.removeAll()
                        PlayerRecent.clear()
                        forgotten = true
                    }
                    .buttonStyle(.graphite(.ghost, size: .compact))
                }
            }
            GroupLabel("Субтитры")
            ListCard {
                ToggleRow("Загружать .srt и .ass рядом с видео", subtitle: "Файл «имя видео.ru.srt» подхватится сам",
                          systemImage: "captions.bubble", isOn: $nearby)
                Row("Размер", systemImage: "textformat.size") {
                    Segmented(selection: $subtitleSize, options: [(0, "S"), (1, "M"), (2, "L")])
                }
                ToggleRow("Подложка под текстом", systemImage: "rectangle.fill", isOn: $subtitleBackground)
            }
            GroupLabel("Пропуск")
            ListCard {
                ToggleRow("Пропускать интро и пересказ автоматически",
                          subtitle: "Иначе — кнопка «Пропустить» на 10 с, клавиша S или ↩", systemImage: "forward.end", isOn: $skipAuto)
                ToggleRow("Автоматически следующая серия — отсчёт 5 с",
                          subtitle: "На титрах в конце серии, если в плейлисте есть следующий файл", systemImage: "play.square.stack",
                          isOn: $nextEpisode)
                if hiddenFolders > 0 {
                    Row("Кнопка пропуска скрыта", subtitle: "В папках: \(hiddenFolders)", systemImage: "eye.slash") {
                        Button("Показывать снова") {
                            UserDefaults.standard.removeObject(forKey: Pref.playerSkipHiddenFolders)
                            hiddenFolders = 0
                        }
                        .buttonStyle(.graphite(.ghost, size: .compact))
                    }
                }
            }
            Footnote("Интро, пересказ и титры находятся по главам файла (MP4, MOV, M4V). MKV, WebM и AVI macOS не открывает — для них нужна другая программа.")
        }
        .onAppear { hiddenFolders = PlayerPrefs.skipHiddenFolders.count }
    }
}
