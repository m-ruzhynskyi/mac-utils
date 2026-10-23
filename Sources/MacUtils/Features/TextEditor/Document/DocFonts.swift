import AppKit
import SwiftUI
import MUDesign

/// Список шрифтов режима «Документ» (`d09`): «В этом документе», «Шрифты Word» (все стандартные, есть они на Mac или
/// нет) и «Все шрифты Mac». Каждый пункт написан своим шрифтом или его заменой; отсутствующий выбрать можно —
/// в файл пишется исходное имя. Загружаемые системой — кнопка «Загрузить», только по нажатию.
enum DocFonts {
    /// Шрифты из `\fonttbl`, которыми написан текст (основной и колонтитулы), — по частоте.
    static func used(in model: RTFDocumentModel) -> [String] {
        var counts: [String: Int] = [:]
        func count(_ story: RTFStory) {
            for paragraph in story.paragraphs {
                for run in paragraph.runs where FormatEdits.isTarget(run.kind) {
                    guard let name = model.font(run.props.font)?.name, !name.isEmpty else { continue }
                    counts[name, default: 0] += run.text.utf16.count
                }
            }
        }
        count(model.body)
        for section in model.sections { for header in section.headers.values { count(header.story) } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Все семейства Mac, без служебных (с точкой в начале).
    static var macFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Пометка справа: «нет на Mac · показ: Helvetica Neue» или ничего.
    static func note(_ availability: FontCatalog.Availability) -> String? {
        switch availability {
        case .installed: return nil
        case .downloadable(let substitute), .missing(let substitute): return "нет на Mac · показ: \(substitute)"
        }
    }
}

/// Поиск, группы и пункты списка шрифтов.
struct DocFontList: View {
    let current: String?
    let documentFonts: [String]
    let choose: (String) -> Void
    @State private var query = ""
    @State private var showsAll = false
    @State private var downloads: [String: Double] = [:]
    @State private var failed: Set<String> = []
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.dsMute).accessibilityHidden(true)
                TextField("Найти шрифт", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .accessibilityLabel("Найти шрифт")
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: 34)
            .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .padding(DS.Space.s)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !query.isEmpty {
                        group(nil, names: filtered(Array(Set(documentFonts + FontCatalog.word + DocFonts.macFamilies))))
                    } else {
                        if !documentFonts.isEmpty { group("В этом документе", names: documentFonts) }
                        group("Шрифты Word", names: FontCatalog.word)
                        Button { showsAll.toggle() } label: {
                            HStack {
                                Text("Все шрифты Mac").font(DS.Font.rowTitle).foregroundStyle(Color.dsText)
                                Spacer()
                                Image(systemName: showsAll ? "chevron.down" : "chevron.right").font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.dsMute).accessibilityHidden(true)
                            }
                            .padding(.horizontal, DS.Space.m)
                            .frame(height: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showsAll ? "Скрыть все шрифты Mac" : "Показать все шрифты Mac")
                        if showsAll { group(nil, names: DocFonts.macFamilies) }
                    }
                }
                .padding(.bottom, DS.Space.s)
                .id(revision)
            }
        }
        .frame(width: 380, height: 470)
    }

    private func filtered(_ names: [String]) -> [String] {
        names.filter { $0.localizedCaseInsensitiveContains(query) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @ViewBuilder
    private func group(_ title: String?, names: [String]) -> some View {
        if let title {
            Text(title.uppercased())
                .font(DS.Font.groupLabel)
                .tracking(DS.Font.tracking(0.08, size: 11))
                .foregroundStyle(Color.dsMute)
                .padding(.horizontal, DS.Space.m)
                .padding(.top, DS.Space.m)
                .padding(.bottom, DS.Space.xs)
                .accessibilityAddTraits(.isHeader)
        }
        ForEach(names, id: \.self) { name in row(name) }
    }

    private func row(_ name: String) -> some View {
        let availability = FontCatalog.availability(name)
        let shown = FontSubstitution.display(for: name)
        let selected = current == name
        return HStack(spacing: DS.Space.s) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).opacity(selected ? 1 : 0).accessibilityHidden(true)
            Text(name)
                .font(.custom(shown, size: 15))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.dsAccInk : Color.dsText)
            Spacer(minLength: DS.Space.s)
            trailing(name, availability: availability, selected: selected)
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 36)
        .background(selected ? Color.dsAcc : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, DS.Space.xs)
        .contentShape(Rectangle())
        .onTapGesture { choose(name) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name + (DocFonts.note(availability).map { ", " + $0 } ?? ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose(name) }
    }

    @ViewBuilder
    private func trailing(_ name: String, availability: FontCatalog.Availability, selected: Bool) -> some View {
        if let progress = downloads[name] {
            ProgressView(value: progress).progressViewStyle(.linear).frame(width: 80)
                .accessibilityLabel("Загрузка шрифта \(name)")
        } else if case .downloadable = availability, !failed.contains(name) {
            Button { download(name) } label: {
                Label("Загрузить", systemImage: "icloud.and.arrow.down")
                    .font(DS.Font.caption)
                    .foregroundStyle(Color.dsAccText)
                    .padding(.horizontal, DS.Space.s)
                    .frame(height: 26)
                    .background(Color.dsField, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Шрифт загрузит macOS (как в «Шрифтах»). Пока не загружен — показ заменой")
        } else if let note = DocFonts.note(availability) {
            Text(failed.contains(name) ? "не загрузился · показ заменой" : note)
                .font(DS.Font.rowSub)
                .foregroundStyle(selected ? Color.dsAccInk.opacity(0.7) : Color.dsMute)
                .lineLimit(1)
        }
    }

    private func download(_ name: String) {
        downloads[name] = 0
        FontCatalog.download(name, progress: { value in downloads[name] = value }, done: { ok in
            downloads[name] = nil
            if !ok { failed.insert(name) }
            revision += 1
        })
    }
}
