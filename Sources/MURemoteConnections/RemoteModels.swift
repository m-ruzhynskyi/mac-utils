import Foundation

/// Программа удалённого доступа, через которую открывается запись.
public enum RemoteProgram: String, Codable, CaseIterable, Sendable {
    case anyDesk
    case teamViewer

    public var bundleID: String {
        switch self {
        case .anyDesk: return "com.philandro.anydesk"
        case .teamViewer: return "com.teamviewer.TeamViewer"
        }
    }

    public var title: String {
        switch self {
        case .anyDesk: return "AnyDesk"
        case .teamViewer: return "TeamViewer"
        }
    }

    /// Поддерживает ли программа алиасы вида `имя@ad`.
    public var supportsAliases: Bool { self == .anyDesk }

    private static let names: [String: RemoteProgram] = [
        "anydesk": .anyDesk, "ad": .anyDesk, "энидеск": .anyDesk, "анидеск": .anyDesk, "енідеск": .anyDesk,
        "teamviewer": .teamViewer, "tv": .teamViewer, "тимвьюер": .teamViewer, "тимвьювер": .teamViewer,
        "тімвюер": .teamViewer, "тімвювер": .teamViewer,
    ]

    /// Значение ячейки «Программа» → программа. Регистр, пробелы и знаки не важны; nil — не распознано.
    public static func parse(_ raw: String) -> RemoteProgram? {
        names[ConnectionHeaders.key(raw)]
    }
}

/// Запись о подключении в памяти. Пароля здесь нет и быть не должно:
/// он читается из файла в момент подключения (`ConnectionsFileStore.password(for:)`).
public struct ConnectionRecord: Equatable, Identifiable, Sendable {
    /// Номер строки листа (XLSX) или строка файла (XML), на которой запись начинается.
    public let sourceRow: Int
    public let name: String
    /// Нормализованный ID: 9–10 цифр или алиас в нижнем регистре.
    public let id: String
    public let group: String
    public let tags: [String]
    public let note: String
    /// nil — в файле программа не указана: берётся программа по умолчанию из настроек.
    public let program: RemoteProgram?
    public let hasPassword: Bool

    public init(sourceRow: Int, name: String, id: String, group: String = "", tags: [String] = [],
                note: String = "", program: RemoteProgram? = nil, hasPassword: Bool = false) {
        self.sourceRow = sourceRow
        self.name = name
        self.id = id
        self.group = group
        self.tags = tags
        self.note = note
        self.program = program
        self.hasPassword = hasPassword
    }

    /// Уникален в списке: один и тот же ID может встретиться дважды (дубликат показываются оба).
    public var identity: String { "\(sourceRow):\(id)" }

    /// Ключ избранного и недавних — нормализованный ID (номер строки меняется при правке файла).
    public var favoriteKey: String { id }

    public var isAlias: Bool { id.contains("@") }

    /// Программа для подключения: из файла, иначе алиас — AnyDesk, иначе программа по умолчанию.
    public func program(default fallback: RemoteProgram) -> RemoteProgram {
        program ?? (isAlias ? .anyDesk : fallback)
    }
}

// MARK: - Диагностика

public struct SkippedRow: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case missingName
        case missingID
        case invalidID
        case unknownProgram
        /// Алиас `имя@ad` у программы, которая алиасов не знает (TeamViewer).
        case aliasNotSupported
    }
    public let row: Int
    public let reason: Reason
    /// Что было в ячейке (ID или программа) — показывается в меню, в журнал не пишется.
    public let value: String
}

public struct DuplicateGroup: Equatable, Sendable {
    public let id: String
    public let rows: [Int]
    public let names: [String]
}

/// Колонка XLSX (или тег XML) и поле, которому она соответствует.
public struct MatchedColumn: Equatable, Sendable {
    public let title: String
    public let field: ConnectionField
}

/// Итог проверки файла. Всё показывается в меню подключений, отдельного окна нет.
public struct ConnectionsDiagnostics: Equatable, Sendable {
    public var loaded = 0
    public var withPassword = 0
    public var columns: [MatchedColumn] = []
    public var skipped: [SkippedRow] = []
    public var duplicates: [DuplicateGroup] = []
    public var unrecognizedColumns: [String] = []
    /// Строки, где ID записан как 1.23E+08 и цифры могли потеряться.
    public var lossyIDRows: [Int] = []
    /// Строки без программы в файле, где встречаются и AnyDesk, и TeamViewer: возьмётся программа по умолчанию.
    public var ambiguousProgramRows: [Int] = []

    public init() {}

    /// Сколько записей повторяют ID, уже встретившийся выше.
    public var duplicateCount: Int { duplicates.reduce(0) { $0 + $1.rows.count - 1 } }

    /// Чисто: показывается только «Загружено N».
    public var isClean: Bool {
        skipped.isEmpty && duplicates.isEmpty && unrecognizedColumns.isEmpty
            && lossyIDRows.isEmpty && ambiguousProgramRows.isEmpty
    }
}

public struct ConnectionsSnapshot: Equatable, Sendable {
    public var records: [ConnectionRecord]
    public var diagnostics: ConnectionsDiagnostics

    public init(records: [ConnectionRecord] = [], diagnostics: ConnectionsDiagnostics = ConnectionsDiagnostics()) {
        self.records = records
        self.diagnostics = diagnostics
    }
}

// MARK: - Ошибки

public enum ConnectionsError: Error, Equatable, Sendable {
    case noFile
    case unavailable
    case cloudNotDownloaded
    /// Файл занят или недописан (Excel сохраняет): стоит повторить.
    case locked
    case unsupportedType
    case tooLarge
    case noSheet(String)
    /// Нет обязательных колонок: в ошибке — заголовки, которые нашлись, чтобы пользователь увидел, что не так.
    case missingColumns(found: [String])
    case corrupt(String)

    /// Код для журнала: без имён листов, заголовков и причин из файла.
    public enum Code: String, Sendable {
        case noFile, unavailable, cloud, locked, type, tooLarge, noSheet, missingColumns, corrupt
    }

    public var code: Code {
        switch self {
        case .noFile: return .noFile
        case .unavailable: return .unavailable
        case .cloudNotDownloaded: return .cloud
        case .locked: return .locked
        case .unsupportedType: return .type
        case .tooLarge: return .tooLarge
        case .noSheet: return .noSheet
        case .missingColumns: return .missingColumns
        case .corrupt: return .corrupt
        }
    }
}
