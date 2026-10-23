import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenShare

/// Макеты текстового редактора (этап дизайна): вьюхи SwiftUI на компонентах Graphite рисуются офскрин в PNG 2x.
/// Код макетов живёт только здесь, в продукте его нет. Текст — выдуманный .frm-подобный RTF; `$` и значения
/// подсвечиваются настоящим правилом `DollarMarks`.
///   MU_EDITOR_DESIGN=$PWD/.audit/text-editor-design swift test --filter TextEditorDesignSnapshots
@MainActor
final class TextEditorDesignSnapshots: XCTestCase {
    private var directory: URL!
    private static let window = NSSize(width: 800, height: 540)

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_EDITOR_DESIGN"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_EDITOR_DESIGN=<папка>, чтобы нарисовать макеты редактора")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
    }

    func testScreens() throws {
        for dark in [false, true] {
            let ink = Ink(dark: dark)
            try render("a-main", size: Self.window, dark: dark) { EditorWindowMock(ink: ink, state: .main) }
            try render("b-encoding-menu", size: Self.window, dark: dark) { EditorWindowMock(ink: ink, state: .encodingMenu) }
            try render("c-find-replace", size: Self.window, dark: dark) { EditorWindowMock(ink: ink, state: .find) }
            try render("c2-go-to-line", size: NSSize(width: 420, height: 150), dark: dark) { GoToLineMock() }
            try render("d1-dollar-skip-off", size: Self.window, dark: dark) { EditorWindowMock(ink: ink, state: .skipOff) }
            try render("d2-dollar-after-clear", size: Self.window, dark: dark) { EditorWindowMock(ink: ink, state: .cleared) }
            try render("e1-entry-panel", size: NSSize(width: DS.Size.popover.width, height: DS.Size.popover.height), dark: dark) {
                EntryPanelMock()
            }
            try render("e2-entry-settings", size: NSSize(width: 760, height: 760), dark: dark) { EntrySettingsMock() }
        }
    }

    // MARK: - Рендер 2x

    private func render<V: View>(_ name: String, size: NSSize, dark: Bool, _ view: () -> V) throws {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let host = NSHostingView(rootView: view().frame(width: size.width, height: size.height)
            .environment(\.controlActiveState, .key))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        // Своя битовая карта вдвое плотнее точек — 2x независимо от экрана.
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, name)
        XCTAssertLessThanOrEqual(rep.pixelsWide, 1600)
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}

// MARK: - Демо-документ

/// Выдуманная форма счёта в RTF (как .frm): первые три `$` — служебные в `\info`, их по умолчанию пропускаем.
private enum Demo {
    static let lines: [String] = [
        #"{\rtf1\adeflang1025\ansi\ansicpg1252\uc1\adeff0\deff0\stshfdbch0\stshfloch0\stshfhich0\deflang1033"#,
        #"{\fonttbl{\f0\froman\fcharset0 Times New Roman;}{\f1\fswiss\fcharset0 Arial;}}"#,
        #"{\colortbl;\red0\green0\blue0;\red31\green111\blue219;}"#,
        #"{\info{\title $FORM_TITLE}{\author $AUTHOR}{\version $REV}}"#,
        #"\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134"#,
        #"\pard\plain\qc\f1\fs28\b INVOICE\b0\par"#,
        #"\pard\plain\f1\fs20 No. $INV_NO dated $DATE\par"#,
        #"\par"#,
        #"{\b Bill to:}\tab $CLIENT_NAME\par"#,
        #"\tab $CLIENT_ADDR\par"#,
        #"\tab VAT ID $CLIENT_VAT\par"#,
        #"\par"#,
        #"\trowd\cellx4500\cellx6000\cellx7500\cellx9000"#,
        #"{\b Item}\cell{\b Qty}\cell{\b Price}\cell{\b Sum}\cell\row"#,
        #"$ITEM_1\cell $QTY_1\cell $PRICE_1 \'80\cell $SUM_1\cell\row"#,
        #"$ITEM_2\cell $QTY_2\cell $PRICE_2 \'80\cell $SUM_2\cell\row"#,
        #"\pard\par"#,
        #"\qr Subtotal: $SUBTOTAL \'80\par"#,
        #"VAT 20%: $VAT \'80\par"#,
        #"{\b Total: $TOTAL \'80}\par"#,
        #"\pard\par"#,
        #"Payment due within $DAYS days. Merci beaucoup \'97 $COMPANY\par"#,
        #"\pard\qr $SIGNATURE\par"#,
        #"}"#,
    ]
    static let text = lines.joined(separator: "\r\n")
    static let skip = 3

    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{202F}"
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Цвета макета

/// Цвета редактора в нужной теме: синтаксис RTF приглушён, чтобы `$` выделялись. Шесть оттенков знаков `$` —
/// кандидаты в токены `DS.Palette.mark1…6`.
private struct Ink {
    let dark: Bool

    func c(_ darkHex: UInt32, _ lightHex: UInt32) -> Color { Color(nsColor: DS.rgb(dark ? darkHex : lightHex)) }

    var text: Color { c(0xEDEFF2, 0x14171A) }
    var mute: Color { c(0x9AA3AF, 0x59626E) }
    var faint: Color { c(0x5D6673, 0xA0A7B0) }
    var control: Color { c(0x8FA6C8, 0x44618C) }
    var brace: Color { c(0x7C8594, 0x7A838F) }
    var escape: Color { c(0xE0A867, 0x9A5B00) }
    var currentLine: Color { c(0x1C2026, 0xF3F5EF) }
    var gutter: Color { c(0x14171B, 0xF8F9F6) }

    private static let hues: [(dark: UInt32, light: UInt32)] = [
        (0xC8F05A, 0x4F7A00), (0x6EA8FF, 0x1F6FDB), (0xF5B83D, 0xA86400),
        (0xFF7A6B, 0xD03A2B), (0xB79BFF, 0x7A4FE0), (0x4FD8C4, 0x0E8577),
    ]

    func hue(_ index: Int) -> Color {
        let pair = Self.hues[index % Self.hues.count]
        return c(pair.dark, pair.light)
    }

    func hueFill(_ index: Int) -> Color { hue(index).opacity(dark ? 0.22 : 0.15) }
}

// MARK: - Подсветка строки

private enum Paint: Equatable {
    case text, control, brace, escape
    case dollar(Int), value(Int)
    case skipped
    case match(current: Bool)
}

/// Строка редактора: RTF-синтаксис, знаки `$` оттенками, совпадения поиска.
private struct LineText {
    let ink: Ink

    func attributed(_ line: String, start: Int, marks: [DollarMark], hues: [Int: Int], selected: Int?,
                    matches: [NSRange], currentMatch: Int?) -> AttributedString {
        let string = line as NSString
        var paints = lexRTF(string)
        for mark in marks {
            for offset in mark.whole.location..<(mark.whole.location + mark.whole.length) {
                let local = offset - start
                guard local >= 0, local < paints.count else { continue }
                if let hue = hues[mark.dollar] {
                    paints[local] = offset == mark.dollar ? .dollar(hue) : .value(hue)
                } else {
                    paints[local] = .skipped
                }
            }
        }
        for (index, match) in matches.enumerated() {
            for offset in match.location..<(match.location + match.length) where offset - start >= 0 && offset - start < paints.count {
                paints[offset - start] = .match(current: index == currentMatch)
            }
        }
        var result = AttributedString()
        var runStart = 0
        while runStart < paints.count {
            var runEnd = runStart + 1
            while runEnd < paints.count, paints[runEnd] == paints[runStart] { runEnd += 1 }
            var piece = AttributedString(string.substring(with: NSRange(location: runStart, length: runEnd - runStart)))
            style(&piece, paints[runStart], selected: selected.map { isInside($0, start + runStart, marks) } ?? false)
            result += piece
            runStart = runEnd
        }
        return result
    }

    private func isInside(_ dollar: Int, _ offset: Int, _ marks: [DollarMark]) -> Bool {
        guard let mark = marks.first(where: { $0.dollar == dollar }) else { return false }
        return NSLocationInRange(offset, mark.whole)
    }

    private func style(_ piece: inout AttributedString, _ paint: Paint, selected: Bool) {
        piece.font = DS.Font.mono(12.5, relativeTo: .body)
        switch paint {
        case .text: piece.foregroundColor = ink.text
        case .control: piece.foregroundColor = ink.control
        case .brace: piece.foregroundColor = ink.brace
        case .escape: piece.foregroundColor = ink.escape
        case .dollar(let hue):
            piece.foregroundColor = ink.hue(hue)
            piece.font = .custom("JetBrainsMonoRoman-ExtraBold", size: 12.5)
            piece.backgroundColor = selected ? ink.hue(hue).opacity(0.4) : ink.hueFill(hue)
        case .value(let hue):
            piece.foregroundColor = ink.text
            piece.backgroundColor = selected ? ink.hue(hue).opacity(0.4) : ink.hueFill(hue)
            piece.underlineStyle = Text.LineStyle(pattern: .solid, color: ink.hue(hue))
        case .skipped:
            piece.foregroundColor = ink.faint
            piece.underlineStyle = Text.LineStyle(pattern: .dot, color: ink.faint)
        case .match(let current):
            piece.foregroundColor = current ? Color.dsAccInk : ink.text
            piece.backgroundColor = current ? Color.dsAcc : Color.dsAcc.opacity(ink.dark ? 0.22 : 0.3)
        }
    }

    /// Разметка RTF: `\слово`, `\'hh`, скобки, остальное — текст.
    private func lexRTF(_ string: NSString) -> [Paint] {
        var paints = [Paint](repeating: .text, count: string.length)
        var i = 0
        while i < string.length {
            let unit = string.character(at: i)
            if unit == 0x7B || unit == 0x7D {
                paints[i] = .brace
                i += 1
            } else if unit == 0x5C, i + 1 < string.length {
                let next = string.character(at: i + 1)
                if next == 0x27 {
                    let end = min(i + 4, string.length)
                    for j in i..<end { paints[j] = .escape }
                    i = end
                } else if (0x61...0x7A).contains(next) {
                    var end = i + 1
                    while end < string.length, (0x61...0x7A).contains(string.character(at: end)) { end += 1 }
                    while end < string.length, (0x30...0x39).contains(string.character(at: end)) || string.character(at: end) == 0x2D { end += 1 }
                    for j in i..<end { paints[j] = .control }
                    i = end
                } else {
                    paints[i] = .control
                    paints[i + 1] = .control
                    i += 2
                }
            } else {
                i += 1
            }
        }
        return paints
    }
}

// MARK: - Окно редактора

private enum EditorState {
    case main, encodingMenu, find, skipOff, cleared
}

private struct EditorWindowMock: View {
    let ink: Ink
    let state: EditorState

    private var text: String {
        guard state == .cleared else { return Demo.text }
        let marks = DollarMarks.scan(Demo.text)
        return DollarMarks.removingValues(of: DollarMarks.split(marks, skipFirst: Demo.skip).active, in: Demo.text)
    }

    private var skip: Int? { state == .skipOff ? nil : Demo.skip }
    private var showsPanel: Bool { state != .find }

    var body: some View {
        let text = self.text
        let marks = DollarMarks.scan(text)
        let parts = DollarMarks.split(marks, skipFirst: skip)
        let hues = Dictionary(uniqueKeysWithValues: parts.active.enumerated().map { ($0.element.dollar, $0.offset) })
        let index = LineIndex(text)
        let selected: Int? = state == .main || state == .encodingMenu ? parts.active.first { (text as NSString).substring(with: $0.value) == "CLIENT_NAME" }?.dollar : nil
        let matches = state == .find ? findMatches(text) : []
        VStack(spacing: 0) {
            TitleBarMock(state: state, panelOn: showsPanel)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if state == .find { FindBarMock(count: matches.count) }
                    EditorTextMock(ink: ink, text: text, index: index, marks: marks, hues: hues, selected: selected,
                                   matches: matches, currentMatch: matches.isEmpty ? nil : 0,
                                   currentLine: state == .find ? 15 : 9, cursorColumn: state == .find ? 27 : 18)
                }
                if showsPanel {
                    Rectangle().fill(Color.dsLine).frame(width: 1)
                    DollarPanelMock(ink: ink, text: text, index: index, skipped: Array(parts.skipped), active: Array(parts.active),
                                    hues: hues, skipOn: skip != nil, selected: selected, cleared: state == .cleared)
                        .frame(width: 272)
                }
            }
            StatusBarMock(state: state, text: text, index: index)
        }
        .background(Color.dsPanel)
        .overlay(alignment: .bottomTrailing) {
            if state == .encodingMenu {
                EncodingMenuMock().padding(.trailing, 104).padding(.bottom, 32)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .padding(1)
        .background(Color.dsBg)
    }

    /// Совпадения поиска `\$SUM_\d` (регулярное выражение включено).
    private func findMatches(_ text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: #"\$(SUM|PRICE)_\d"#) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }
}

/// Заголовок окна: «светофор», вкладки документов, кнопки поиска и панели `$`.
private struct TitleBarMock: View {
    let state: EditorState
    let panelOn: Bool

    var body: some View {
        HStack(spacing: DS.Space.m) {
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: DS.rgb(0xFF5F57))).frame(width: 12, height: 12)
                Circle().fill(Color(nsColor: DS.rgb(0xFEBC2E))).frame(width: 12, height: 12)
                Circle().fill(Color(nsColor: DS.rgb(0x28C840))).frame(width: 12, height: 12)
            }
            .padding(.trailing, DS.Space.xs)
            HStack(spacing: DS.Space.xs) {
                DocTab(title: "invoice_demo.frm", selected: true, modified: state == .cleared)
                DocTab(title: "contract_demo.frm", selected: false, modified: false)
                DocTab(title: "Без имени 1", selected: false, modified: true)
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(.dsMute)
                    .frame(width: 26, height: 26)
            }
            .padding(3)
            .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            Spacer(minLength: 0)
            IconButton("Найти и заменить (⌘F)", systemImage: "magnifyingglass", active: state == .find, compact: true) {}
            IconButton("Панель «Знаки $»", systemImage: "dollarsign", active: panelOn, compact: true) {}
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 50)
        .background(Color.dsSide)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 1) }
    }
}

/// Вкладка документа: выбранная — лайм; точка — есть несохранённые правки; × — закрыть.
private struct DocTab: View {
    let title: String
    let selected: Bool
    let modified: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: title.hasSuffix(".frm") ? "doc.richtext" : "doc.plaintext").font(.system(size: 11, weight: .semibold))
            Text(title).font(DS.Font.manrope(12.5, .bold, relativeTo: .callout)).lineLimit(1)
            if modified {
                Circle().fill(selected ? Color.dsAccInk : Color.dsMute).frame(width: 7, height: 7)
            } else if selected {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.7)
            }
        }
        .foregroundStyle(selected ? Color.dsAccInk : Color.dsMute)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(selected ? Color.dsAcc : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Текст с номерами строк, текущей строкой и закладкой.
private struct EditorTextMock: View {
    let ink: Ink
    let text: String
    let index: LineIndex
    let marks: [DollarMark]
    let hues: [Int: Int]
    let selected: Int?
    let matches: [NSRange]
    let currentMatch: Int?
    let currentLine: Int
    let cursorColumn: Int

    private let lineHeight: CGFloat = 19.5
    private static let bookmarks: Set<Int> = [14]

    var body: some View {
        let string = text as NSString
        let painter = LineText(ink: ink)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...index.lineCount, id: \.self) { line in
                    HStack(spacing: 4) {
                        Circle().fill(Self.bookmarks.contains(line) ? Color.dsBlue : .clear).frame(width: 6, height: 6)
                        Text("\(line)")
                            .font(DS.Font.mono(11, relativeTo: .caption))
                            .foregroundStyle(line == currentLine ? ink.text : ink.faint)
                            .frame(width: 22, alignment: .trailing)
                    }
                    .frame(height: lineHeight)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.top, 6)
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .background(ink.gutter)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.dsLine).frame(width: 1) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(1...index.lineCount, id: \.self) { line in
                    let start = index.starts[line - 1]
                    let end = line < index.lineCount ? index.starts[line] - 2 : string.length
                    let content = string.substring(with: NSRange(location: start, length: max(0, end - start)))
                    Text(painter.attributed(content, start: start, marks: marks, hues: hues, selected: selected,
                                            matches: matches, currentMatch: currentMatch))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: lineHeight, alignment: .leading)
                        .padding(.leading, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line == currentLine ? ink.currentLine : .clear)
                        .overlay(alignment: .leading) {
                            if line == currentLine && selected == nil {
                                Rectangle().fill(ink.text).frame(width: 1.5, height: 15).offset(x: 10 + 7.5 * CGFloat(cursorColumn - 1))
                            }
                        }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            // minWidth 0: длинные строки не распирают окно, а уходят за правый край (горизонтальная прокрутка).
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(Color.dsPanel)
    }
}

// MARK: - Панель «Знаки $»

private struct DollarPanelMock: View {
    let ink: Ink
    let text: String
    let index: LineIndex
    let skipped: [DollarMark]
    let active: [DollarMark]
    let hues: [Int: Int]
    let skipOn: Bool
    let selected: Int?
    let cleared: Bool

    private var string: NSString { text as NSString }
    private var withValues: Int { active.filter { $0.value.length > 0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Text("Знаки $").font(DS.Font.manrope(16, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
                Spacer(minLength: 0)
                Pill(.neutral, "\(active.count) из \(active.count + skipped.count)")
            }
            ListCard(style: .field) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: DS.Space.s) {
                        Text("Пропускать первые").font(DS.Font.bodyStrong).foregroundStyle(.dsText)
                        Spacer(minLength: 0)
                        Toggle("Пропускать первые", isOn: .constant(skipOn)).toggleStyle(.graphite)
                    }
                    HStack(spacing: DS.Space.s) {
                        Text(skipOn ? "Без подсветки и правки" : "Обрабатываются все")
                            .font(DS.Font.rowSub).foregroundStyle(.dsMute)
                        Spacer(minLength: 0)
                        StepperMock(value: Demo.skip).opacity(skipOn ? 1 : DS.State.disabledOpacity)
                    }
                }
                .padding(.vertical, DS.Space.s)
                .padding(.horizontal, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !skipped.isEmpty {
                        GroupLabel("Пропущено · \(skipped.count)").padding(.horizontal, DS.Space.xs)
                        ForEach(skipped, id: \.dollar) { mark in row(mark, hue: nil) }
                        Spacer().frame(height: DS.Space.s)
                    }
                    GroupLabel(cleared ? "Без значений · \(active.count)" : "Подсвечено · \(active.count)").padding(.horizontal, DS.Space.xs)
                    ForEach(active, id: \.dollar) { mark in row(mark, hue: hues[mark.dollar]) }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            if cleared {
                UndoNoteMock(count: 19)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Убрать значения · \(withValues)") {}.buttonStyle(.graphite(.primary, fill: true))
                    // Одно значение — × в строке списка (или ⌫ на выбранной строке).
                    Text("У одного — × в строке списка").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(DS.Space.m)
        .frame(maxHeight: .infinity)
        .background(Color.dsSide)
    }

    private func row(_ mark: DollarMark, hue: Int?) -> some View {
        let value = string.substring(with: mark.value)
        let isSelected = mark.dollar == selected
        return HStack(spacing: DS.Space.s) {
            Text("\(index.line(at: mark.dollar))")
                .font(DS.Font.mono(11, relativeTo: .caption))
                .foregroundStyle(ink.faint)
                .frame(width: 22, alignment: .trailing)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(hue.map { ink.hue($0) } ?? ink.faint.opacity(0.5))
                .frame(width: 4, height: 16)
            (Text("$").foregroundStyle(hue.map { ink.hue($0) } ?? ink.faint)
             + Text(value.isEmpty ? "" : value).foregroundStyle(hue == nil ? ink.faint : ink.text))
                .font(DS.Font.mono(12.5, relativeTo: .body))
                .lineLimit(1)
            if value.isEmpty {
                Text("пусто").font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.dsMute)
                    .help("Убрать значение")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(isSelected ? Color.dsPanel : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isSelected { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsAccLine, lineWidth: 1.5) }
        }
    }
}

private struct StepperMock: View {
    let value: Int

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "minus").frame(width: 22, height: 26)
            Text("\(value)").font(DS.Font.mono(13, relativeTo: .body)).foregroundStyle(.dsText).frame(minWidth: 18)
            Image(systemName: "plus").frame(width: 22, height: 26)
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.dsMute)
        .capsuleFill(Color.dsPanel, border: Color.dsLine)
    }
}

/// После «Убрать значения»: итог и отмена.
private struct UndoNoteMock: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(DS.Tone.success.line)
                Text("Убрано: \(count)").font(DS.Font.bodyStrong).foregroundStyle(.dsText)
                Spacer(minLength: 0)
                Button("Отменить ⌘Z") {}.buttonStyle(.graphite(.secondary, size: .compact))
            }
            Text("Знаки $ остались на местах").font(DS.Font.rowSub).foregroundStyle(.dsMute)
        }
        .padding(10)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous).strokeBorder(Color.dsAccLine, lineWidth: 1.5))
    }
}

// MARK: - Строка состояния

private struct StatusBarMock: View {
    let state: EditorState
    let text: String
    let index: LineIndex

    var body: some View {
        let length = (text as NSString).length
        HStack(spacing: 2) {
            item(state == .find ? "Стр 15, стл 27" : "Стр 9, стл 18", mono: true)
            item(state == .find ? "Выделено 8" : "Выделено 0")
            item("\(Demo.number(length)) симв. · \(index.lineCount) стр.")
            Spacer(minLength: 0)
            item("RTF", menu: true)
            item("Windows-1252", menu: true, open: state == .encodingMenu)
            item("CRLF", menu: true)
            item("ВСТ", mono: true)
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: 30)
        .background(Color.dsSide)
        .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 1) }
    }

    private func item(_ title: String, mono: Bool = false, menu: Bool = false, open: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).font(mono ? DS.Font.mono(11.5, relativeTo: .caption) : DS.Font.manrope(12, .semibold, relativeTo: .caption))
            if menu { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .foregroundStyle(open ? Color.dsText : Color.dsMute)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(open ? Color.dsField : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { if open { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.dsAccLine, lineWidth: 1.5) } }
    }
}

// MARK: - Меню «Кодировка»

private struct EncodingMenuMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Кодировка").font(DS.Font.manrope(15, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
                Spacer()
                Text("определена по \\ansicpg1252").font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
            Segmented(selection: .constant(0), options: [(0, "Открыть заново в…"), (1, "Преобразовать в…")])
            HStack(alignment: .top, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    group(.unicode)
                    Spacer().frame(height: 6)
                    group(.western)
                }
                VStack(alignment: .leading, spacing: 2) {
                    group(.cyrillic)
                    Spacer().frame(height: 6)
                    group(.central)
                }
            }
            Text("«Открыть заново» читает те же байты в другой кодировке. «Преобразовать» сохранит текст в новой.")
                .font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 430)
        .floating()
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private func group(_ group: TextEncoding.Group) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            GroupLabel(group.title).padding(.leading, 6).padding(.bottom, 2)
            ForEach(TextEncoding.allCases.filter { $0.group == group }, id: \.self) { encoding in
                let current = encoding == .windows1252
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).opacity(current ? 1 : 0)
                    Text(encoding.title).font(current ? DS.Font.bodyStrong : DS.Font.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(current ? Color.dsAccInk : Color.dsText)
                .padding(.horizontal, 8)
                .frame(width: 190, height: 26)
                .background(current ? Color.dsAcc : (encoding == .windows1251 ? Color.dsField : .clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

// MARK: - Поиск и замена

private struct FindBarMock: View {
    let count: Int

    var body: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                field(icon: "magnifyingglass", text: #"\$(SUM|PRICE)_\d"#, trailing: "1 из \(count)")
                option("Aa", help: "Учитывать регистр", on: false)
                option("ab", help: "Слово целиком", on: false, underline: true)
                option(".*", help: "Регулярное выражение", on: true)
                option("[ ]", help: "Только в выделении", on: false)
                IconButton("Предыдущее (⇧⌘G)", systemImage: "chevron.up", compact: true) {}
                IconButton("Следующее (⌘G)", systemImage: "chevron.down", compact: true) {}
            }
            HStack(spacing: DS.Space.s) {
                field(icon: "arrow.2.squarepath", text: "$LINE_TOTAL", trailing: nil)
                Button("Заменить") {}.buttonStyle(.graphite(.secondary, size: .compact))
                Button("Заменить все") {}.buttonStyle(.graphite(.primary, size: .compact))
                Button("В папке…") {}.buttonStyle(.graphite(.ghost, size: .compact))
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 10)
        .background(Color.dsSide)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 1) }
    }

    private func field(icon: String, text: String, trailing: String?) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        return HStack(spacing: DS.Space.s) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.dsMute)
            Text(text).font(DS.Font.mono(13, relativeTo: .body)).foregroundStyle(.dsText).lineLimit(1)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(DS.Font.rowSub).foregroundStyle(.dsMute) }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.dsField, in: shape)
        .overlay(shape.strokeBorder(trailing != nil ? Color.dsAccLine : Color.dsLine, lineWidth: trailing != nil ? 2 : 1))
    }

    private func option(_ title: String, help: String, on: Bool, underline: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Text(title)
            .underline(underline)
            .font(DS.Font.mono(12, relativeTo: .caption))
            .foregroundStyle(on ? Color.dsAccInk : Color.dsMute)
            .frame(width: 30, height: 30)
            .background(on ? Color.dsAcc : Color.dsField, in: shape)
            .overlay(shape.strokeBorder(on ? Color.clear : Color.dsLine, lineWidth: 1))
            .help(help)
    }
}

/// «Перейти к строке» (⌘L): плавающее поле над текстом.
private struct GoToLineMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Перейти к строке").font(DS.Font.manrope(15, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
                Spacer()
                Keycap(["⌘", "L"], compact: true)
            }
            HStack(spacing: DS.Space.s) {
                Text("15:26").font(DS.Font.mono(14, relativeTo: .body)).foregroundStyle(.dsText)
                    .padding(.horizontal, DS.Space.m)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Color.dsAccLine, lineWidth: 2))
                Button("Перейти") {}.buttonStyle(.graphite(.primary, size: .compact))
            }
            Text("Строка 1–24, можно со столбцом: 15:26").font(DS.Font.rowSub).foregroundStyle(.dsMute)
        }
        .floating()
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsBg)
    }
}

// MARK: - Откуда открывается

/// Вкладка «Редактор» в панели 🔧 (как остальные быстрые панели).
private struct EntryPanelMock: View {
    var body: some View {
        VStack(spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                AppMark(size: 22)
                    .frame(width: 38, height: 38)
                    .background(Color.dsField, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Mac Utils").font(DS.Font.headline).foregroundStyle(.dsText)
                    Text("Актуальная версия").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                }
                Spacer()
                IconButton("Настройки", systemImage: "gearshape") {}
                IconButton("Выйти", systemImage: "power") {}
            }
            .padding(.horizontal, DS.Space.l)
            HStack(spacing: DS.Space.xs) {
                ForEach(["music.note", "trash", "gauge.with.dots.needle.67percent", "list.bullet.rectangle"], id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.dsMute)
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                HStack(spacing: 6) {
                    Image(systemName: "doc.plaintext").font(.system(size: 15, weight: .medium))
                    Text("Редактор").font(DS.Font.manrope(13, .bold, relativeTo: .callout)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(.dsAccInk)
                .padding(.horizontal, DS.Space.m)
                .frame(height: 38)
                .background(Color.dsAcc, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                ForEach(["externaldrive.badge.minus", "photo.on.rectangle.angled"], id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.dsMute)
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
            }
            .padding(DS.Space.xs)
            .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .padding(.horizontal, DS.Space.l)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                group("Текстовый редактор") {
                    Row("Открыть редактор", subtitle: "Вкладки прошлого сеанса вернутся", systemImage: "doc.plaintext", tile: .accent) {
                        Keycap(["⌃", "⌥", "⌘", "E"], compact: true, onPanel: true)
                    }
                    Row("Открыть файл…", subtitle: ".frm, .rtf, .txt, .json, .xml… или перетащите сюда", systemImage: "folder") {
                        Keycap(["⌘", "O"], compact: true, onPanel: true)
                    }
                    Row("Новый документ", systemImage: "plus") { Keycap(["⌘", "N"], compact: true, onPanel: true) }
                }
                group("Недавние") {
                    Row("invoice_demo.frm", subtitle: "~/Documents/Формы · Windows-1252", systemImage: "doc.richtext")
                    Row("contract_demo.frm", subtitle: "~/Documents/Формы · Windows-1251", systemImage: "doc.richtext")
                    Row("settings_demo.json", subtitle: "~/Desktop · UTF-8", systemImage: "curlybraces")
                }
            }
            .padding(.horizontal, DS.Space.l)
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Rectangle().fill(Color.dsLine).frame(height: 1)
                HStack {
                    Label("Все настройки раздела", systemImage: "gearshape").font(DS.Font.bodyStrong).foregroundStyle(.dsAccText)
                    Spacer()
                }
                .padding(.horizontal, DS.Space.l)
                .frame(height: 40)
            }
        }
        .padding(.top, DS.Space.l)
        .background(Color.dsPanel)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupLabel(title).padding(.horizontal, DS.Space.xs)
            ListCard(style: .field) { content() }
        }
    }
}

/// Страница настроек «Текстовый редактор» (группа «Файлы и система»).
private struct EntrySettingsMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.section) {
            HStack(alignment: .top, spacing: 14) {
                HeaderTile(systemImage: "doc.plaintext")
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Текстовый редактор").font(DS.Font.display).foregroundStyle(.dsText)
                    Text("Вкладки, кодировки и знаки $ для .frm и других текстов").font(DS.Font.body).foregroundStyle(.dsMute)
                }
                Spacer()
                Button("Открыть редактор") {}.buttonStyle(.graphite(.primary))
            }
            ListCard {
                Row("Открыть редактор", subtitle: "Из любой программы", systemImage: "keyboard") {
                    Keycap(["⌃", "⌥", "⌘", "E"])
                }
                Row("«Открыть с помощью» в Finder", subtitle: "Mac Utils — запасной вариант, ваши программы по умолчанию не меняются",
                    systemImage: "folder") {
                    HStack(spacing: 6) {
                        ForEach(["frm", "rtf", "txt", "log", "json", "xml", "csv"], id: \.self) { ext in
                            Text(".\(ext)").font(DS.Font.mono(11.5, relativeTo: .caption)).foregroundStyle(.dsText)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .capsuleFill(Color.dsField, border: Color.dsLine)
                        }
                    }
                }
            }
            GroupLabel("Знаки $")
            ListCard {
                Row("Пропускать первые знаки", subtitle: "Служебные $ в начале файла не трогаются и не подсвечиваются",
                    systemImage: "dollarsign") {
                    HStack(spacing: DS.Space.m) {
                        StepperMock(value: 3)
                        Toggle("Пропускать первые знаки", isOn: .constant(true)).toggleStyle(.graphite)
                    }
                }
            }
            GroupLabel("Файлы")
            ListCard {
                Row("Кодировка новых документов", systemImage: "textformat") {
                    Picker("", selection: .constant(0)) { Text("UTF-8").tag(0) }.graphitePicker()
                }
                Row("Перевод строки новых документов", systemImage: "return") {
                    Segmented(selection: .constant(1), options: [(0, "CRLF"), (1, "LF"), (2, "CR")])
                }
                ToggleRow("Восстанавливать вкладки", subtitle: "После перезапуска — те же файлы и места", systemImage: "rectangle.stack",
                          isOn: .constant(true))
                ToggleRow("Автосохранение черновиков", subtitle: "Безымянные документы не пропадут", systemImage: "clock.arrow.circlepath",
                          isOn: .constant(true))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Space.pageVertical)
        .padding(.horizontal, DS.Space.pageHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dsBg)
    }
}
