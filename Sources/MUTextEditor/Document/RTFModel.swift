import Foundation
import MUCore
import MUDesign

// Модель RTF-документа для режима «Документ»: только то, что нужно показать и править без потерь. Всё, чего модель
// не знает, остаётся в исходнике байт в байт — модель никогда не пишется обратно целиком.
// Единицы — твипы (1/20 пункта), как в RTF; смещения — UTF-16 исходника, как у `NSString`.

/// Выравнивание абзаца (`\ql \qc \qr \qj`).
package enum RTFAlignment: String, Hashable, CaseIterable {
    case left, center, right, justify

    package var word: String {
        switch self {
        case .left: return "ql"
        case .center: return "qc"
        case .right: return "qr"
        case .justify: return "qj"
        }
    }
}

/// Подчёркивание (`\ul`, `\uldb`, `\uld`…); всё, что не «нет», показывается одиночной или двойной линией.
package enum RTFUnderline: Hashable {
    case none, single, double, dotted, dashed, thick, wave, words
}

/// Надстрочный и подстрочный (`\super`, `\sub`, `\up`, `\dn`).
package enum RTFVertical: Hashable {
    case normal, superscript, `subscript`
}

/// Свойства символа в точке исходника.
package struct RTFCharProps: Hashable {
    /// `\fN`; `nil` — шрифт документа по умолчанию (`\deff`).
    package var font: Int?
    /// `\fsN` — в половинках пункта (24 = 12 pt).
    package var halfPoints = 24
    package var bold = false
    package var italic = false
    package var underline = RTFUnderline.none
    package var strike = false
    /// `\cfN`; 0 — «авто» (чёрный).
    package var color = 0
    /// `\highlightN` — индекс в `\colortbl`; 0 — нет маркера.
    package var highlight = 0
    /// `\cbN` / `\chcbpatN` — заливка символов; 0 — нет.
    package var background = 0
    /// `\chshdngN` (сотые доли процента) и `\chcfpatN` — узор заливки знаков: доля цвета узора поверх фона.
    package var backgroundPercent = 0
    package var backgroundPattern = 0
    /// `\v` — скрытый текст.
    package var hidden = false
    package var vertical = RTFVertical.normal
    package var caps = false
    package var smallCaps = false
    /// `\kerningN` — кернинг пар с размера N полупунктов; 0 — без кернинга (как у Word по умолчанию).
    package var kerning = 0
    /// `\expndtwN` (`\expndN` — в четвертях пункта) — межзнаковый интервал в твипах, + разрежённый, − уплотнённый.
    package var expand = 0
}

/// Граница абзаца или ячейки (`\brdrs\brdrw10\brdrcf1`).
package struct RTFBorder: Hashable {
    /// Толщина в твипах (`\brdrwN`, у `\brdrth` вдвое).
    package var width = 0
    package var color = 0
    package var style = Style.single
    package var none = false

    package enum Style: Hashable { case single, double, dotted, dashed }

    package var isVisible: Bool { !none && width > 0 }
}

/// Позиция табуляции (`\tqr\tldot\tx5000`).
package struct RTFTabStop: Hashable {
    package enum Kind: Hashable { case left, center, right, decimal, bar }
    package var position: Int
    package var kind = Kind.left
    package var leader = false
}

/// Свойства абзаца, действующие на его конце (`\par`, `\cell`).
package struct RTFParaProps: Hashable {
    package var alignment = RTFAlignment.left
    /// `\li` / `\ri` / `\fi` — отступы слева, справа и первой строки.
    package var left = 0
    package var right = 0
    package var firstLine = 0
    /// `\sb` / `\sa` — интервал до и после.
    package var spaceBefore = 0
    package var spaceAfter = 0
    /// `\sl`: 0 — авто; > 0 — «не меньше» (или кратный при `\slmult1`, 240 = одинарный); < 0 — «точно».
    package var lineSpacing = 0
    package var lineMultiple = false
    package var tabs: [RTFTabStop] = []
    package var inTable = false
    package var keepNext = false
    /// `\keep` — не разрывать абзац между страницами; `\widctlpar` — без висячих строк (≥ 2 строки на каждой странице).
    package var keepTogether = false
    package var widowControl = false
    package var pageBreakBefore = false
    package var borderTop = RTFBorder()
    package var borderBottom = RTFBorder()
    package var borderLeft = RTFBorder()
    package var borderRight = RTFBorder()
    /// `\cbpatN` — заливка абзаца.
    package var shading = 0
    /// `\sN` — стиль абзаца (показывается только номер; стили не правятся).
    package var style: Int?
    /// `\contextualspace` — без интервалов `\sb`/`\sa` между соседними абзацами того же стиля.
    package var contextualSpace = false
    /// `\lsN` — замена списка (`\listoverride`), 0 — не пункт списка; `\ilvlN` — уровень. Список стиля `\sN` Word
    /// при чтении RTF не берёт (коды стиля — только в `{\stylesheet}`), поэтому и здесь — только свои коды абзаца.
    package var list = 0
    package var listLevel = 0

    /// Рамка позиционирования (`\posx…`, `\posy…`, `\pv…`, `\ph…`, `\absw`/`\absh`).
    package var frame = RTFFrame()

    package var hasBorders: Bool { borderTop.isVisible || borderBottom.isVisible || borderLeft.isVisible || borderRight.isVisible }
}

/// Рамка позиционирования абзаца. Рамка у абзаца (`\pvpara`) без сдвига по вертикали стоит рядом со следующим
/// текстом (обтекание): места в потоке у Word не занимает — так в колонтитулах рамка номера страницы.
package struct RTFFrame: Hashable {
    package var isSet = false
    /// По вертикали — от абзаца (`\pvpara`), иначе от поля или листа.
    package var fromParagraph = false
    /// `\posyN` (твипы); `\posyt`/`\posyc`/… — не 0.
    package var y = 0
    /// `\posxl`/`\posxc`/`\posxr` (`\posxi`/`\posxo` — как слева/справа), `\posxN` — слева.
    package var x: RTFAlignment?

    /// Рамка у правого края на месте абзаца (номер, штамп): текст идёт рядом слева, места она не занимает. Рамка по центру (f152) текст раздвигает.
    package var besideNext: Bool { isSet && fromParagraph && y == 0 && x == .right }
}

/// Свойства раздела (страница, поля, колонтитулы).
package struct RTFSectionProps: Hashable {
    package var pageWidth = 11906
    package var pageHeight = 16838
    package var marginLeft = 1134
    package var marginRight = 1134
    package var marginTop = 1134
    package var marginBottom = 1134
    package var landscape = false
    /// `\titlepg` — особый колонтитул первой страницы раздела.
    package var titlePage = false
    /// Расстояние колонтитула от края страницы (`\headery` / `\footery`).
    package var headerY = 709
    package var footerY = 709
    /// Раздел начинается с новой страницы (`\sbkpage`, по умолчанию) или без разрыва (`\sbknone`).
    package var newPage = true
}

/// Шрифт из `\fonttbl`.
package struct RTFFont: Hashable {
    package enum Family: String, Hashable { case nil_ = "fnil", roman = "froman", swiss = "fswiss", modern = "fmodern", script = "fscript",
                                         decor = "fdecor", tech = "ftech", bidi = "fbidi" }
    package var number: Int
    package var name: String
    package var family = Family.nil_
    package var charset = 0
    /// `\cpgN` у шрифта.
    package var codePage: Int?
    /// Первые байты `\panose` (класс шрифта) — для замены неизвестного.
    package var panose: String?
}

/// Цвет из `\colortbl`; `nil` — «авто».
package struct RTFColor: Hashable {
    package var red: Int
    package var green: Int
    package var blue: Int
}

/// Вид колонтитула.
package enum RTFHeaderKind: String, Hashable, CaseIterable {
    case header, headerLeft = "headerl", headerRight = "headerr", headerFirst = "headerf"
    case footer, footerLeft = "footerl", footerRight = "footerr", footerFirst = "footerf"

    package var isHeader: Bool { rawValue.hasPrefix("header") }

    /// Для какой страницы: все, чётные (левые), нечётные (правые), первая.
    package enum Page: Hashable { case all, even, odd, first }

    package var page: Page {
        switch self {
        case .header, .footer: return .all
        case .headerLeft, .footerLeft: return .even
        case .headerRight, .footerRight: return .odd
        case .headerFirst, .footerFirst: return .first
        }
    }

    package static func kind(header: Bool, page: Page) -> RTFHeaderKind {
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
    package var title: String {
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
package enum RTFFieldKind: Hashable {
    /// Номер страницы и число страниц — считаем сами по своей раскладке, правке не подлежат.
    case page, numPages, sectionPages
    /// Любое другое поле (HYPERLINK…): показывается его результат `\fldrslt`, текст результата правится.
    case other(String)

    package var isComputed: Bool {
        switch self {
        case .page, .numPages, .sectionPages: return true
        case .other: return false
        }
    }

    package static func parse(_ instruction: String) -> RTFFieldKind {
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
package struct RTFPlaceholder: Hashable {
    package enum Kind: Hashable {
        /// Фигура `\shp` (тип по `shapeType`).
        case shape(Int?)
        /// Старый объект рисования `\do` (`\dpline`, `\dprect`…).
        case drawing(String)
        /// OLE `\object`.
        case object
        /// Рисунок, который macOS не показывает (WMF, EMF, PICT…).
        case picture(String)
    }

    package var kind: Kind
    /// Размер в твипах, если известен.
    package var width = 0
    package var height = 0

    package var title: String {
        switch kind {
        case .shape: return "Фигура (\\shp)"
        case .drawing: return "Объект рисования (\\do)"
        case .object: return "Объект OLE"
        case .picture(let format): return "Рисунок \(format)"
        }
    }

    package var subtitle: String {
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

    package static func shapeName(_ type: Int?) -> String {
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
package struct RTFFloat: Hashable {
    /// От чего отсчитывается рамка по горизонтали (`\shpbx*`, `posrelh`) и по вертикали (`\shpby*`, `posrelv`).
    package enum Horizontal: Hashable { case margin, page, column }
    package enum Vertical: Hashable { case margin, page, paragraph }

    /// Рамка в твипах от опоры.
    package var left = 0
    package var top = 0
    package var width = 0
    package var height = 0
    package var horizontal = Horizontal.column
    package var vertical = Vertical.paragraph
    /// В ячейке таблицы опора по горизонтали — ячейка (`fLayoutInCell`, по умолчанию — да).
    package var layoutInCell = true
    /// Под текстом (`\shpfblwtxt1`).
    package var behind = false
    /// `shapeType`: 1 — прямоугольник, 2 — скруглённый, 3 — овал, 20 и 32 — линии, 75 — рисунок, 202 — надпись.
    package var shapeType = 1
    package var filled = true
    /// Цвета Word: R + G·256 + B·65536.
    package var fillColor = 0xFFFFFF
    package var line = true
    package var lineColor = 0
    /// Толщина линии, EMU (12 700 на пункт).
    package var lineWidth = 9_525
    package var flipH = false
    package var flipV = false

    /// Какие фигуры рисуются сами (остальные — заглушкой в тексте).
    package static let drawnTypes: Set<Int> = [1, 2, 3, 20, 32, 75, 202]
}

/// Кусок абзаца с одними свойствами. `map[i]` — диапазон исходника `i`-й единицы UTF-16 `text`.
package struct RTFRun {
    package enum Kind: Hashable {
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

    package var kind: Kind
    package var text: String
    package var props: RTFCharProps
    package var map: [NSRange]
    /// Самая внутренняя группа `{…}` исходника, где стоит текст: форматирование оборачивает только куски одной группы.
    package var group: Int
    /// `\ucN` в этом месте — сколько заменителей писать после `\uN` при вводе.
    package var uc = 1
    /// Рисунок: данные PNG/JPEG и размер на странице в твипах.
    package var picture: RTFPicture?
    /// Поле (`\field`), в результате которого стоит текст: номер в `RTFDocumentModel.fields`.
    package var field: Int?
    /// Группа `{…}` непрозрачного элемента или рисунка — целиком (для «Показать в коде»).
    package var objectGroup: NSRange?
    /// Фигура или рисунок без обтекания: в тексте — только опора нулевой ширины.
    package var floating: RTFFloat?

    package var isEditableText: Bool {
        switch kind {
        case .text, .tab, .lineBreak: return true
        default: return false
        }
    }
}

/// Поле `{\field{\*\fldinst …}{\fldrslt …}}`.
package struct RTFField: Hashable {
    package var kind: RTFFieldKind
    package var instruction: String
    /// Группа поля целиком: удаление через поле удаляет его всё.
    package var group: NSRange
}

/// Рисунок `\pict` с данными, которые macOS умеет показать.
package struct RTFPicture: Hashable {
    package enum Format: String, Hashable { case png = "PNG", jpeg = "JPEG" }
    package var format: Format
    package var data: Data
    package var width: Int
    package var height: Int
}

/// Чем заканчивается абзац.
package enum RTFParagraphEnd: Hashable {
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
package struct RTFParagraph {
    package var runs: [RTFRun] = []
    package var props = RTFParaProps()
    /// Свойства символа на конце абзаца (у знака ¶): их получает набранное в пустом абзаце.
    package var endProps = RTFCharProps()
    /// `\ucN` на конце абзаца.
    package var endUC = 1
    package var end = RTFParagraphEnd.storyEnd
    /// Код конца абзаца в исходнике (`\par ` с разделителем); у `.storyEnd` — пустой диапазон в конце истории.
    package var endRange = NSRange(location: 0, length: 0)
    /// Где начинается область абзаца: сразу после конца предыдущего (или начало истории).
    package var regionStart = 0
    /// Последний `\pard` в области абзаца, действующий на его конце.
    package var pard: NSRange?
    /// Последние коды свойств абзаца в его области, действующие на его конце (`ql`, `li`, `sl`…).
    package var propTokens: [String: NSRange] = [:]
    /// Номер раздела.
    package var section = 0
    /// Ячейка таблицы: номер таблицы, строки и ячейки (заполняется на `\row`).
    package var cell: RTFCellRef?
    /// Группа готового номера `{\listtext …}` или `{\pntext …}` абзаца целиком.
    package var listTextGroup: NSRange?
    /// Первая видимая единица абзаца в исходнике (или `endRange.location`, если абзац пуст).
    package var contentStart: Int {
        runs.first(where: { !$0.map.isEmpty })?.map.first?.location ?? endRange.location
    }

    package var plainText: String { runs.map(\.text).joined() }

    /// Начало текста абзаца без готового номера списка.
    package var textStart: Int {
        runs.first(where: { !$0.map.isEmpty && $0.kind != .listText })?.map.first?.location ?? endRange.location
    }
}

/// Где абзац лежит в таблице.
package struct RTFCellRef: Hashable {
    package var table: Int
    package var row: Int
    package var cell: Int
}

/// Ячейка строки таблицы: правая граница (`\cellx`), границы, заливка, объединение.
package struct RTFCellDef: Hashable {
    package var right = 0
    package var borderTop = RTFBorder()
    package var borderBottom = RTFBorder()
    package var borderLeft = RTFBorder()
    package var borderRight = RTFBorder()
    /// `\clcbpatN` — фон ячейки; `\clshdngN` (сотые доли процента) и `\clcfpatN` — узор: доля его цвета поверх фона.
    package var shading = 0
    package var shadingPercent = 0
    package var shadingPattern = 0
    /// `\clvmgf` — первая из объединённых по вертикали, `\clvmrg` — продолжение.
    package var verticalMergeFirst = false
    package var verticalMerged = false
    /// `\clmgf` / `\clmrg` — объединение по горизонтали.
    package var horizontalMergeFirst = false
    package var horizontalMerged = false
    package enum VerticalAlign: Hashable { case top, center, bottom }
    package var verticalAlign = VerticalAlign.top
    /// Поля ячейки, твипы, при единице 3 (твипы): `\clpadt`/`\clpadft` — левое (Word меняет местами `l` и `t`),
    /// `\clpadr`/`\clpadfr` — правое. Иначе — поля строки.
    package var padLeft = 0, padLeftUnit = 0
    package var padRight = 0, padRightUnit = 0
}

/// Строка таблицы.
package struct RTFRow {
    package var cells: [RTFCellDef] = []
    /// Абзацы каждой ячейки (индексы в истории).
    package var paragraphs: [[Int]] = []
    package var left = 0
    /// `\trgaph`: без него поля ячеек нулевые.
    package var gap = 0
    /// `\trpaddl`/`\trpaddr` при `\trpaddfl3`/`\trpaddfr3` (Word 2000+) — поля ячеек вместо `\trgaph`.
    package var padLeft = 0, padLeftUnit = 0
    package var padRight = 0, padRightUnit = 0
    /// `\trql`/`\trqc`/`\trqr`: строка по левому краю (от `\trleft`), по центру или вправо полосы текста.
    package enum Alignment: Hashable { case left, center, right }
    package var alignment = Alignment.left
    /// `\trrhN`: > 0 — «не меньше», < 0 — «точно».
    package var height = 0
    /// Поля ячеек сверху и снизу (`\trpaddt`, `\trpaddb`), твипы; у Word по умолчанию 0.
    package var padTop = 0
    package var padBottom = 0
    package var header = false
    /// Код `\row` в исходнике.
    package var endRange = NSRange(location: 0, length: 0)

    /// Левое и правое поле ячейки, твипы, — как их берёт Word: поле ячейки, поле строки, `\trgaph`.
    package func margins(_ cell: RTFCellDef) -> (left: Int, right: Int) {
        let left = cell.padLeftUnit == 3 ? cell.padLeft : padLeftUnit == 3 ? padLeft : gap
        let right = cell.padRightUnit == 3 ? cell.padRight : padRightUnit == 3 ? padRight : gap
        return (max(left, 0), max(right, 0))
    }
}

package struct RTFTable {
    package var rows: [RTFRow] = []
}

/// Текст одной истории: основной текст или колонтитул.
package struct RTFStory {
    package var paragraphs: [RTFParagraph] = []
    package var tables: [RTFTable] = []
    /// Группа истории в исходнике (у основного текста — весь документ).
    package var range = NSRange(location: 0, length: 0)
}

/// Колонтитул раздела: вид, группа в исходнике и его текст.
package struct RTFHeader {
    package var kind: RTFHeaderKind
    package var story: RTFStory
    /// Группа `{\header… }` целиком.
    package var group: NSRange
}

/// Раздел: свойства страницы и колонтитулы.
package struct RTFSection {
    package var props = RTFSectionProps()
    package var headers: [RTFHeaderKind: RTFHeader] = [:]
    /// Где в исходнике можно вставить новую группу колонтитула: после свойств раздела, до его первого абзаца.
    package var headerInsertion = 0
    /// Код `\sectd` раздела (для `\titlepg`), если есть.
    package var sectd: NSRange?
    /// Первый абзац раздела в основном тексте.
    package var firstParagraph = 0
}

/// Разобранный документ.
package struct RTFDocumentModel {
    package var fonts: [Int: RTFFont] = [:]
    package var defaultFont: Int?
    package var colors: [RTFColor?] = []
    /// `{\fonttbl …}` и `{\colortbl …}` целиком — новые записи дописываются перед их `}`.
    package var fontTable: NSRange?
    package var colorTable: NSRange?
    /// Кодовая страница документа (`\ansicpg`) — для `\'hh` и ввода.
    package var codePage = TextEncoding.windows1252
    /// `\deftab` — шаг табуляции по умолчанию.
    package var defaultTab = 720
    package var facingPages = false
    /// Код `\facingp` в исходнике.
    package var facingPagesRange: NSRange?
    package var body = RTFStory()
    package var sections: [RTFSection] = [RTFSection()]
    package var fields: [RTFField] = []
    /// Списки (`\listtable`, `\listoverridetable`).
    package var lists = RTFListTable()
    /// Где можно вставить свойство документа (`\facingp`): перед первым `\sectd` или первым абзацем.
    package var documentPropsInsertion = 0
    /// Начинается ли исходник с `{\rtf`.
    package var isRTF = false

    package func font(_ number: Int?) -> RTFFont? {
        guard let number = number ?? defaultFont else { return nil }
        return fonts[number]
    }

    package func color(_ index: Int) -> RTFColor? {
        guard index > 0, index < colors.count else { return nil }
        return colors[index]
    }
}
