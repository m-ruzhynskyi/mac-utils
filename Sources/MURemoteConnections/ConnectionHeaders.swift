import Foundation

/// Поле записи, которому соответствует колонка XLSX или тег XML.
public enum ConnectionField: String, CaseIterable, Sendable {
    case name, id, password, group, tags, note, program

    public var isRequired: Bool { self == .name || self == .id }
}

/// Названия колонок на русском, украинском и английском. Регистр, пробелы и знаки не важны.
enum ConnectionHeaders {
    private static let aliases: [ConnectionField: [String]] = [
        .name: ["name", "название", "назва", "имя", "імя", "computer", "компьютер", "компютер"],
        .id: ["id", "ид", "ід", "anydesk", "anydeskid", "idanydesk", "teamviewer", "teamviewerid", "idteamviewer",
              "anydeskteamviewer", "idanydeskteamviewer", "адрес", "адреса", "address",
              "идентификатор", "ідентифікатор", "номер"],
        .password: ["password", "pass", "pwd", "пароль"],
        .group: ["group", "группа", "група"],
        .tags: ["tags", "tag", "теги", "тэги", "тег"],
        .note: ["note", "notes", "заметка", "заметки", "примітка", "примітки", "комментарий", "коментар"],
        .program: ["program", "app", "application", "программа", "програма", "приложение", "додаток"],
    ]

    private static let lookup: [String: ConnectionField] = {
        var table: [String: ConnectionField] = [:]
        for (field, names) in aliases { for n in names { table[n] = field } }
        return table
    }()

    static func field(for header: String) -> ConnectionField? {
        lookup[key(header)]
    }

    /// Ключ сравнения: только буквы и цифры в нижнем регистре, «ё» = «е».
    static func key(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(u) {
            out.append(u == "ё" ? "е" : u)
        }
        return String(out)
    }
}
