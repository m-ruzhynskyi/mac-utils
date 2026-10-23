import Foundation

/// Строка файла до проверки: все значения как есть, строками.
/// Сам пароль сохраняется только при поиске пароля (`ParseMode.passwords`), при обычной загрузке — лишь признак.
struct RawEntry {
    var row: Int
    var name = ""
    var id = ""
    var password = ""
    var hasPassword = false
    var group = ""
    var tags = ""
    var note = ""
    var program = ""
    var account = ""
    var accountPassword = ""
    var hasAccountPassword = false
    var access = ""
    var accessLines = 0

    init(row: Int) { self.row = row }

    mutating func set(_ field: ConnectionField, _ value: String, mode: ParseMode) {
        switch field {
        case .name: name = value
        case .id: id = value
        case .password:
            hasPassword = !value.isEmpty
            if mode == .passwords { password = value }
        case .group: group = value
        case .tags: tags = value
        case .note: note = value
        case .program: program = value
        case .account: account = value
        case .accountPassword:
            hasAccountPassword = !value.isEmpty
            if mode == .passwords { accountPassword = value }
        case .access:
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            accessLines = text.isEmpty ? 0 : text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
            if mode == .passwords { access = text }
        case .contacts:
            break   // известна, но не нужна: значение не сохраняется
        }
    }

    /// Секретное поле (только в режиме `.passwords`).
    func secret(_ field: ConnectionField) -> String {
        switch field {
        case .accountPassword: return accountPassword
        case .access: return access
        default: return password
        }
    }

    var isEmpty: Bool {
        !hasPassword && !hasAccountPassword && accessLines == 0 && [name, id, group, tags, note, program, account].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

enum ParseMode {
    /// Список: пароли не сохраняются, только признак «есть пароль».
    case records
    /// Поиск пароля в момент подключения.
    case passwords
}

struct ParsedFile {
    var entries: [RawEntry]
    var columns: [MatchedColumn] = []
    var unrecognizedColumns: [String] = []
}

/// Источник списка подключений: .xlsx или .xml. Файл только читается.
protocol ConnectionsSource {
    /// Разбор содержимого файла в сырые строки. Бросает `ConnectionsError`.
    func parse(_ data: Data, mode: ParseMode) throws -> ParsedFile
}

extension ConnectionsSource {
    func load(_ data: Data) throws -> ConnectionsSnapshot {
        ConnectionsBuilder.build(try parse(data, mode: .records))
    }

    /// Пароль записи — прямо из файла, в момент подключения. Сначала строка с тем же номером и ID;
    /// если файл успели поправить — строка с тем же ID и именем, затем единственная строка с этим ID.
    /// Угадывать среди нескольких строк с одним ID не будем. Строки разбора (`String`) затереть нельзя —
    /// они живут только до конца этого вызова.
    func lookupPassword(for record: ConnectionRecord, in data: Data) throws -> PasswordLookup {
        try lookupSecret(.password, for: record, in: data)
    }

    /// Секретное поле записи (пароль, пароль учётки, «Доступ») — так же, как пароль. Записи без ID ищутся
    /// по номеру строки и названию.
    func lookupSecret(_ field: ConnectionField, for record: ConnectionRecord, in data: Data) throws -> PasswordLookup {
        let sameID = try parse(data, mode: .passwords).entries.filter { ConnectionsBuilder.idKey($0.id) == record.id }
        let name = { (e: RawEntry) in e.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        var match = sameID.first { $0.row == record.sourceRow && (!record.id.isEmpty || name($0) == record.name) }
        if match == nil { match = sameID.first { name($0) == record.name } }
        if match == nil, sameID.count == 1, !record.id.isEmpty { match = sameID[0] }
        guard let match else { return .entryGone }
        let value = match.secret(field)
        guard !value.isEmpty else { return .noPassword }
        return .found(SecretBuffer(value.utf8))
    }

    /// nil — записи или пароля нет.
    func password(for record: ConnectionRecord, in data: Data) throws -> SecretBuffer? {
        try lookupPassword(for: record, in: data).secret
    }
}

/// Что нашлось в файле для записи в момент подключения.
public enum PasswordLookup: Sendable {
    case found(SecretBuffer)
    /// Запись есть, ячейка пароля пустая.
    case noPassword
    /// Записи больше нет: файл поправили после чтения списка.
    case entryGone

    public var secret: SecretBuffer? {
        if case .found(let s) = self { return s }
        return nil
    }
}

enum ConnectionsSources {
    static let maxFileSize = 64 << 20

    static func source(forExtension ext: String, sheet: String? = nil) -> ConnectionsSource? {
        switch ext.lowercased() {
        case "xlsx", "xlsm": return XLSXSource(sheet: sheet)
        case "xml": return XMLSource()
        default: return nil
        }
    }

    static func source(for url: URL, sheet: String? = nil) throws -> ConnectionsSource {
        guard let s = source(forExtension: url.pathExtension, sheet: sheet) else { throw ConnectionsError.unsupportedType }
        return s
    }
}
