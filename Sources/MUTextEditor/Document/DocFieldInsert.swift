import Foundation

/// Поля колонтитулов (H2): что вставляется, как это пишется в RTF и как Word-овский «образец» даты и времени (`\@ "dd.MM.yyyy"`)
/// превращается в текст результата. Чистые функции — проверяются без окон.
package enum HeaderField: Equatable {
    /// `PAGE`.
    case page
    /// `NUMPAGES`.
    case numPages
    /// `SECTIONPAGES`.
    case sectionPages
    /// «Стр. X из Y»: `PAGE` и `NUMPAGES`.
    case pageOfTotal
    /// `DATE \@ "образец"`.
    case date(String)
    /// `TIME \@ "образец"`.
    case time(String)
    /// `FILENAME`.
    case fileName

    /// Готовые образцы меню (как в списке Word для русского языка).
    package static let datePictures = ["dd.MM.yyyy", "d MMMM yyyy", "dd.MM.yy", "yyyy-MM-dd", "dddd, d MMMM yyyy"]
    package static let timePictures = ["HH:mm", "H:mm:ss", "h:mm AM/PM"]

    /// Заголовок пункта списка «Поле…».
    package var title: String {
        switch self {
        case .page: return "Номер страницы"
        case .numPages: return "Число страниц"
        case .sectionPages: return "Страниц в разделе"
        case .pageOfTotal: return "Стр. X из Y"
        case .date(let picture): return "Дата · " + DocFieldFormat.text(picture: picture, date: DocFieldFormat.sampleDate)
        case .time(let picture): return "Время · " + DocFieldFormat.text(picture: picture, date: DocFieldFormat.sampleDate)
        case .fileName: return "Имя файла"
        }
    }

    /// Список «Поле…».
    package static let catalog: [HeaderField] = [.page, .numPages, .sectionPages, .pageOfTotal]
        + datePictures.map { .date($0) } + timePictures.map { .time($0) } + [.fileName]
}

package enum DocFieldFormat {
    /// Образец списка: 5 марта 2026, 14:07.
    package static let sampleDate = Date(timeIntervalSince1970: 1_772_719_620)

    package static let locale = Locale(identifier: "ru_RU")

    /// Образец Word → шаблон ICU: `dddd`/`ddd` — день недели, `AM/PM` — `a`, текст в апострофах — как есть.
    package static func icu(picture: String) -> String {
        var out = ""
        var index = picture.startIndex
        var quoted = false
        while index < picture.endIndex {
            let ch = picture[index]
            if ch == "'" {
                quoted.toggle()
                out.append(ch)
                index = picture.index(after: index)
                continue
            }
            if quoted { out.append(ch); index = picture.index(after: index); continue }
            let rest = picture[index...]
            if rest.uppercased().hasPrefix("AM/PM") {
                out += "a"
                index = picture.index(index, offsetBy: 5)
                continue
            }
            if ch == "d" {
                var count = 0
                var cursor = index
                while cursor < picture.endIndex, picture[cursor] == "d" { count += 1; cursor = picture.index(after: cursor) }
                out += count >= 4 ? "EEEE" : count == 3 ? "EEE" : String(repeating: "d", count: count)
                index = cursor
                continue
            }
            out.append(ch)
            index = picture.index(after: index)
        }
        return out
    }

    package static func text(picture: String, date: Date, locale: Locale = DocFieldFormat.locale, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = icu(picture: picture)
        return formatter.string(from: date)
    }

    /// Образец из кода поля: `DATE \@ "dd.MM.yyyy"` → `dd.MM.yyyy`; без `\@` — nil (формат по умолчанию).
    package static func picture(ofInstruction instruction: String) -> String? {
        guard let marker = instruction.range(of: "\\@") else { return nil }
        let rest = instruction[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") { return String(rest[rest.index(after: rest.startIndex)..<close]) }
        return rest.split(separator: " ").first.map(String.init)
    }

    /// Образец по умолчанию, когда в коде поля его нет.
    package static func defaultPicture(forField name: String) -> String { name == "TIME" ? "H:mm" : "dd.MM.yyyy" }
}
