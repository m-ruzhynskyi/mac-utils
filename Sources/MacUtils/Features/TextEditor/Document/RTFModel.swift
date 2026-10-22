import Foundation

// Модель RTF-документа для режима «Документ»: только то, что нужно показать и править без потерь. Всё, чего модель
// не знает, остаётся в исходнике байт в байт — модель никогда не пишется обратно целиком.
// Единицы — твипы (1/20 пункта), как в RTF; смещения — UTF-16 исходника, как у `NSString`.

/// Выравнивание абзаца (`\ql \qc \qr \qj`).
enum RTFAlignment: String, Hashable, CaseIterable {
    case left, center, right, justify

    var word: String {
        switch self {
        case .left: return "ql"
        case .center: return "qc"
        case .right: return "qr"
        case .justify: return "qj"
        }
    }
}

/// Подчёркивание (`\ul`, `\uldb`, `\uld`…); всё, что не «нет», показывается одиночной или двойной линией.
enum RTFUnderline: Hashable {
    case none, single, double, dotted, dashed, thick, wave, words
}

/// Надстрочный и подстрочный (`\super`, `\sub`, `\up`, `\dn`).
enum RTFVertical: Hashable {
    case normal, superscript, `subscript`
}

/// Свойства символа в точке исходника.
struct RTFCharProps: Hashable {
    /// `\fN`; `nil` — шрифт документа по умолчанию (`\deff`).
    var font: Int?
    /// `\fsN` — в половинках пункта (24 = 12 pt).
    var halfPoints = 24
    var bold = false
    var italic = false
    var underline = RTFUnderline.none
    var strike = false
    /// `\cfN`; 0 — «авто» (чёрный).
    var color = 0
    /// `\highlightN` — индекс в `\colortbl`; 0 — нет маркера.
    var highlight = 0
    /// `\cbN` / `\chcbpatN` — заливка символов; 0 — нет.
    var background = 0
    /// `\v` — скрытый текст.
    var hidden = false
    var vertical = RTFVertical.normal
    var caps = false
    var smallCaps = false
}

/// Граница абзаца или ячейки (`\brdrs\brdrw10\brdrcf1`).
struct RTFBorder: Hashable {
    /// Толщина в твипах (`\brdrwN`, у `\brdrth` вдвое).
    var width = 0
    var color = 0
    var style = Style.single
    var none = false

    enum Style: Hashable { case single, double, dotted, dashed }

    var isVisible: Bool { !none && width > 0 }
}

/// Позиция табуляции (`\tqr\tldot\tx5000`).
struct RTFTabStop: Hashable {
    enum Kind: Hashable { case left, center, right, decimal, bar }
    var position: Int
    var kind = Kind.left
    var leader = false
}

/// Свойства абзаца, действующие на его конце (`\par`, `\cell`).
struct RTFParaProps: Hashable {
    var alignment = RTFAlignment.left
    /// `\li` / `\ri` / `\fi` — отступы слева, справа и первой строки.
    var left = 0
    var right = 0
    var firstLine = 0
    /// `\sb` / `\sa` — интервал до и после.
    var spaceBefore = 0
    var spaceAfter = 0
    /// `\sl`: 0 — авто; > 0 — «не меньше» (или кратный при `\slmult1`, 240 = одинарный); < 0 — «точно».
    var lineSpacing = 0
    var lineMultiple = false
    var tabs: [RTFTabStop] = []
    var inTable = false
    var keepNext = false
    /// `\keep` — не разрывать абзац между страницами.
    var keepTogether = false
    var pageBreakBefore = false
    var borderTop = RTFBorder()
    var borderBottom = RTFBorder()
    var borderLeft = RTFBorder()
    var borderRight = RTFBorder()
    /// `\cbpatN` — заливка абзаца.
    var shading = 0
    /// `\sN` — стиль абзаца (показывается только номер; стили не правятся).
    var style: Int?
    /// `\contextualspace` — без интервалов `\sb`/`\sa` между соседними абзацами того же стиля.
    var contextualSpace = false
    /// `\lsN` — замена списка (`\listoverride`), 0 — не пункт списка; `\ilvlN` — уровень. Список стиля `\sN` Word
    /// при чтении RTF не берёт (коды стиля — только в `{\stylesheet}`), поэтому и здесь — только свои коды абзаца.
    var list = 0
    var listLevel = 0

    var hasBorders: Bool { borderTop.isVisible || borderBottom.isVisible || borderLeft.isVisible || borderRight.isVisible }
}

/// Свойства раздела (страница, поля, колонтитулы).
struct RTFSectionProps: Hashable {
    var pageWidth = 11906
    var pageHeight = 16838
    var marginLeft = 1134
    var marginRight = 1134
    var marginTop = 1134
    var marginBottom = 1134
    var landscape = false
    /// `\titlepg` — особый колонтитул первой страницы раздела.
    var titlePage = false
    /// Расстояние колонтитула от края страницы (`\headery` / `\footery`).
    var headerY = 709
    var footerY = 709
    /// Раздел начинается с новой страницы (`\sbkpage`, по умолчанию) или без разрыва (`\sbknone`).
    var newPage = true
}

/// Шрифт из `\fonttbl`.
struct RTFFont: Hashable {
    enum Family: String, Hashable { case nil_ = "fnil", roman = "froman", swiss = "fswiss", modern = "fmodern", script = "fscript",
                                         decor = "fdecor", tech = "ftech", bidi = "fbidi" }
    var number: Int
    var name: String
    var family = Family.nil_
    var charset = 0
    /// `\cpgN` у шрифта.
    var codePage: Int?
    /// Первые байты `\panose` (класс шрифта) — для замены неизвестного.
    var panose: String?
}

/// Цвет из `\colortbl`; `nil` — «авто».
struct RTFColor: Hashable {
    var red: Int
    var green: Int
    var blue: Int
}

/// Вид колонтитула.
enum RTFHeaderKind: String, Hashable, CaseIterable {
    case header, headerLeft = "headerl", headerRight = "headerr", headerFirst = "headerf"
    case footer, footerLeft = "footerl", footerRight = "footerr", footerFirst = "footerf"

    var isHeader: Bool { rawValue.hasPrefix("header") }

    /// Для какой страницы: все, чётные (левые), нечётные (правые), первая.
    enum Page: Hashable { case all, even, odd, first }

    var page: Page {
        switch self {
        case .header, .footer: return .all
        case .headerLeft, .footerLeft: return .even
        case .headerRight, .footerRight: return .odd
        case .headerFirst, .footerFirst: return .first
        }
    }

    static func kind(header: Bool, page: Page) -> RTFHeaderKind {
        switch (header, page) {
        case (true, .all): return .header
        case (true, .even): return .headerLeft
        case (true, .odd): return .headerRight
        case (true, .first): return .headerFirst
        case (false, .all): return .footer
        case (false, .even): return .footerLeft
        case (false, .odd): return .footerRight
        case (false, .first): return .footerFirst
        }
    }

    /// Подпись над рамкой колонтитула при правке.
    var title: String {
        let base = isHeader ? "Верхний колонтитул" : "Нижний колонтитул"
        switch page {
        case .all: return base
        case .even: return base + " — чётные"
        case .odd: return base + " — нечётные"
        case .first: return base + " — первая страница"
        }
    }
}

/// Поле (`\field`): что показывать вместо результата.
enum RTFFieldKind: Hashable {
    /// Номер страницы и число страниц — считаем сами по своей раскладке, правке не подлежат.
    case page, numPages, sectionPages
    /// Любое другое поле (HYPERLINK…): показывается его результат `\fldrslt`, текст результата правится.
    case other(String)

    var isComputed: Bool {
        switch self {
        case .page, .numPages, .sectionPages: return true
        case .other: return false
        }
    }

    static func parse(_ instruction: String) -> RTFFieldKind {
        let word = instruction.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init)?.uppercased() ?? ""
        switch word {
        case "PAGE": return .page
        case "NUMPAGES": return .numPages
        case "SECTIONPAGES": return .sectionPages
        default: return .other(word)
        }
    }
}

/// Непрозрачный элемент — показывается заглушкой (`d05`), в исходнике не трогается.
struct RTFPlaceholder: Hashable {
    enum Kind: Hashable {
        /// Фигура `\shp` (тип по `shapeType`).
        case shape(Int?)
        /// Старый объект рисования `\do` (`\dpline`, `\dprect`…).
        case drawing(String)
        /// OLE `\object`.
        case object
        /// Рисунок, который macOS не показывает (WMF, EMF, PICT…).
        case picture(String)
    }

    var kind: Kind
    /// Размер в твипах, если известен.
    var width = 0
    var height = 0

    var title: String {
        switch kind {
        case .shape: return "Фигура (\\shp)"
        case .drawing: return "Объект рисования (\\do)"
        case .object: return "Объект OLE"
        case .picture(let format): return "Рисунок \(format)"
        }
    }

    var subtitle: String {
        var parts: [String] = []
        switch kind {
        case .shape(let type): parts.append(Self.shapeName(type))
        case .drawing(let type): parts.append(type)
        case .object: parts.append("Встроенный объект другой программы")
        case .picture: parts.append("macOS не показывает этот формат")
        }
        if width > 0, height > 0 {
            parts.append(String(format: "%.1f × %.1f см", Double(width) / 567, Double(height) / 567).replacingOccurrences(of: ".", with: ","))
        }
        return parts.joined(separator: " · ")
    }

    static func shapeName(_ type: Int?) -> String {
        switch type {
        case 1: return "Прямоугольник"
        case 2: return "Скруглённый прямоугольник"
        case 3: return "Овал"
        case 20: return "Линия"
        case 32: return "Соединительная линия"
        case 75: return "Рамка рисунка"
        case 202: return "Надпись"
        case .some(let other): return "Тип \(other)"
        case nil: return "Фигура"
        }
    }
}

/// Плавающая фигура или рисунок `\shp` без обтекания (`\shpwr3`): в тексте Word не занимает места и рисуется поверх
/// страницы (или под текстом) там, где задано рамкой `\shpleft…\shpbottom` от своей опоры.
struct RTFFloat: Hashable {
    /// От чего отсчитывается рамка по горизонтали (`\shpbx*`, `posrelh`) и по вертикали (`\shpby*`, `posrelv`).
    enum Horizontal: Hashable { case margin, page, column }
    enum Vertical: Hashable { case margin, page, paragraph }

    /// Рамка в твипах от опоры.
    var left = 0
    var top = 0
    var width = 0
    var height = 0
    var horizontal = Horizontal.column
    var vertical = Vertical.paragraph
    /// В ячейке таблицы опора по горизонтали — ячейка (`fLayoutInCell`, по умолчанию — да).
    var layoutInCell = true
    /// Под текстом (`\shpfblwtxt1`).
    var behind = false
    /// `shapeType`: 1 — прямоугольник, 2 — скруглённый, 3 — овал, 20 и 32 — линии, 75 — рисунок, 202 — надпись.
    var shapeType = 1
    var filled = true
    /// Цвета Word: R + G·256 + B·65536.
    var fillColor = 0xFFFFFF
    var line = true
    var lineColor = 0
    /// Толщина линии, EMU (12 700 на пункт).
    var lineWidth = 9_525
    var flipH = false
    var flipV = false

    /// Какие фигуры рисуются сами (остальные — заглушкой в тексте).
    static let drawnTypes: Set<Int> = [1, 2, 3, 20, 32, 75, 202]
}

/// Кусок абзаца с одними свойствами. `map[i]` — диапазон исходника `i`-й единицы UTF-16 `text`.
struct RTFRun {
    enum Kind: Hashable {
        /// Обычный текст — правится.
        case text
        /// `\tab`, `\line`.
        case tab, lineBreak
        /// `\page` внутри абзаца или `\pagebb` / разрыв раздела в его начале.
        case pageBreak
        /// Вычисляемое поле (PAGE, NUMPAGES): текст результата не правится.
        case field(RTFFieldKind)
        /// Текст номера списка (`\pntext`, `\listtext`): показывается, но не правится (списки — позже).
        case listText
        /// Рисунок PNG/JPEG (данные — в `picture`).
        case picture
        /// Заглушка непрозрачного элемента.
        case placeholder(RTFPlaceholder)
    }

    var kind: Kind
    var text: String
    var props: RTFCharProps
    var map: [NSRange]
    /// Самая внутренняя группа `{…}` исходника, где стоит текст: форматирование оборачивает только куски одной группы.
    var group: Int
    /// `\ucN` в этом месте — сколько заменителей писать после `\uN` при вводе.
    var uc = 1
    /// Рисунок: данные PNG/JPEG и размер на странице в твипах.
    var picture: RTFPicture?
    /// Поле (`\field`), в результате которого стоит текст: номер в `RTFDocumentModel.fields`.
    var field: Int?
    /// Группа `{…}` непрозрачного элемента или рисунка — целиком (для «Показать в коде»).
    var objectGroup: NSRange?
    /// Фигура или рисунок без обтекания: в тексте — только опора нулевой ширины.
    var floating: RTFFloat?

    var isEditableText: Bool {
        switch kind {
        case .text, .tab, .lineBreak: return true
        default: return false
        }
    }
}

/// Поле `{\field{\*\fldinst …}{\fldrslt …}}`.
struct RTFField: Hashable {
    var kind: RTFFieldKind
    var instruction: String
    /// Группа поля целиком: удаление через поле удаляет его всё.
    var group: NSRange
}

/// Рисунок `\pict` с данными, которые macOS умеет показать.
struct RTFPicture: Hashable {
    enum Format: String, Hashable { case png = "PNG", jpeg = "JPEG" }
    var format: Format
    var data: Data
    var width: Int
    var height: Int
}

/// Чем заканчивается абзац.
enum RTFParagraphEnd: Hashable {
    /// `\par` (и `\` + перевод строки).
    case paragraph
    /// `\cell` — конец ячейки таблицы.
    case cell
    /// `\sect` — конец раздела.
    case section
    /// Конец истории (текста, колонтитула) без завершающего кода.
    case storyEnd
}

/// Абзац: прогоны, свойства, конец и где в исходнике лежат его коды (для точечной правки свойств).
struct RTFParagraph {
    var runs: [RTFRun] = []
    var props = RTFParaProps()
    /// Свойства символа на конце абзаца (у знака ¶): их получает набранное в пустом абзаце.
    var endProps = RTFCharProps()
    /// `\ucN` на конце абзаца.
    var endUC = 1
    var end = RTFParagraphEnd.storyEnd
    /// Код конца абзаца в исходнике (`\par ` с разделителем); у `.storyEnd` — пустой диапазон в конце истории.
    var endRange = NSRange(location: 0, length: 0)
    /// Где начинается область абзаца: сразу после конца предыдущего (или начало истории).
    var regionStart = 0
    /// Последний `\pard` в области абзаца, действующий на его конце.
    var pard: NSRange?
    /// Последние коды свойств абзаца в его области, действующие на его конце (`ql`, `li`, `sl`…).
    var propTokens: [String: NSRange] = [:]
    /// Номер раздела.
    var section = 0
    /// Ячейка таблицы: номер таблицы, строки и ячейки (заполняется на `\row`).
    var cell: RTFCellRef?
    /// Группа готового номера `{\listtext …}` или `{\pntext …}` абзаца целиком.
    var listTextGroup: NSRange?
    /// Первая видимая единица абзаца в исходнике (или `endRange.location`, если абзац пуст).
    var contentStart: Int {
        runs.first(where: { !$0.map.isEmpty })?.map.first?.location ?? endRange.location
    }

    var plainText: String { runs.map(\.text).joined() }

    /// Начало текста абзаца без готового номера списка.
    var textStart: Int {
        runs.first(where: { !$0.map.isEmpty && $0.kind != .listText })?.map.first?.location ?? endRange.location
    }
}

/// Где абзац лежит в таблице.
struct RTFCellRef: Hashable {
    var table: Int
    var row: Int
    var cell: Int
}

/// Ячейка строки таблицы: правая граница (`\cellx`), границы, заливка, объединение.
struct RTFCellDef: Hashable {
    var right = 0
    var borderTop = RTFBorder()
    var borderBottom = RTFBorder()
    var borderLeft = RTFBorder()
    var borderRight = RTFBorder()
    var shading = 0
    /// `\clvmgf` — первая из объединённых по вертикали, `\clvmrg` — продолжение.
    var verticalMergeFirst = false
    var verticalMerged = false
    /// `\clmgf` / `\clmrg` — объединение по горизонтали.
    var horizontalMergeFirst = false
    var horizontalMerged = false
    enum VerticalAlign: Hashable { case top, center, bottom }
    var verticalAlign = VerticalAlign.top
    /// Поля ячейки, твипы, при единице 3 (твипы): `\clpadt`/`\clpadft` — левое (Word меняет местами `l` и `t`),
    /// `\clpadr`/`\clpadfr` — правое. Иначе — поля строки.
    var padLeft = 0, padLeftUnit = 0
    var padRight = 0, padRightUnit = 0
}

/// Строка таблицы.
struct RTFRow {
    var cells: [RTFCellDef] = []
    /// Абзацы каждой ячейки (индексы в истории).
    var paragraphs: [[Int]] = []
    var left = 0
    /// `\trgaph`: без него поля ячеек нулевые.
    var gap = 0
    /// `\trpaddl`/`\trpaddr` при `\trpaddfl3`/`\trpaddfr3` (Word 2000+) — поля ячеек вместо `\trgaph`.
    var padLeft = 0, padLeftUnit = 0
    var padRight = 0, padRightUnit = 0
    /// `\trql`/`\trqc`/`\trqr`: строка по левому краю (от `\trleft`), по центру или вправо полосы текста.
    enum Alignment: Hashable { case left, center, right }
    var alignment = Alignment.left
    /// `\trrhN`: > 0 — «не меньше», < 0 — «точно».
    var height = 0
    /// Поля ячеек сверху и снизу (`\trpaddt`, `\trpaddb`), твипы; у Word по умолчанию 0.
    var padTop = 0
    var padBottom = 0
    var header = false
    /// Код `\row` в исходнике.
    var endRange = NSRange(location: 0, length: 0)

    /// Левое и правое поле ячейки, твипы, — как их берёт Word: поле ячейки, поле строки, `\trgaph`.
    func margins(_ cell: RTFCellDef) -> (left: Int, right: Int) {
        let left = cell.padLeftUnit == 3 ? cell.padLeft : padLeftUnit == 3 ? padLeft : gap
        let right = cell.padRightUnit == 3 ? cell.padRight : padRightUnit == 3 ? padRight : gap
        return (max(left, 0), max(right, 0))
    }
}

struct RTFTable {
    var rows: [RTFRow] = []
}

/// Текст одной истории: основной текст или колонтитул.
struct RTFStory {
    var paragraphs: [RTFParagraph] = []
    var tables: [RTFTable] = []
    /// Группа истории в исходнике (у основного текста — весь документ).
    var range = NSRange(location: 0, length: 0)
}

/// Колонтитул раздела: вид, группа в исходнике и его текст.
struct RTFHeader {
    var kind: RTFHeaderKind
    var story: RTFStory
    /// Группа `{\header… }` целиком.
    var group: NSRange
}

/// Раздел: свойства страницы и колонтитулы.
struct RTFSection {
    var props = RTFSectionProps()
    var headers: [RTFHeaderKind: RTFHeader] = [:]
    /// Где в исходнике можно вставить новую группу колонтитула: после свойств раздела, до его первого абзаца.
    var headerInsertion = 0
    /// Код `\sectd` раздела (для `\titlepg`), если есть.
    var sectd: NSRange?
    /// Первый абзац раздела в основном тексте.
    var firstParagraph = 0
}

/// Разобранный документ.
struct RTFDocumentModel {
    var fonts: [Int: RTFFont] = [:]
    var defaultFont: Int?
    var colors: [RTFColor?] = []
    /// `{\fonttbl …}` и `{\colortbl …}` целиком — новые записи дописываются перед их `}`.
    var fontTable: NSRange?
    var colorTable: NSRange?
    /// Кодовая страница документа (`\ansicpg`) — для `\'hh` и ввода.
    var codePage = TextEncoding.windows1252
    /// `\deftab` — шаг табуляции по умолчанию.
    var defaultTab = 720
    var facingPages = false
    /// Код `\facingp` в исходнике.
    var facingPagesRange: NSRange?
    var body = RTFStory()
    var sections: [RTFSection] = [RTFSection()]
    var fields: [RTFField] = []
    /// Списки (`\listtable`, `\listoverridetable`).
    var lists = RTFListTable()
    /// Где можно вставить свойство документа (`\facingp`): перед первым `\sectd` или первым абзацем.
    var documentPropsInsertion = 0
    /// Начинается ли исходник с `{\rtf`.
    var isRTF = false

    func font(_ number: Int?) -> RTFFont? {
        guard let number = number ?? defaultFont else { return nil }
        return fonts[number]
    }

    func color(_ index: Int) -> RTFColor? {
        guard index > 0, index < colors.count else { return nil }
        return colors[index]
    }
}
