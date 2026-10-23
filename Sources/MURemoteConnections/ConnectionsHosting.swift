import Foundation

/// Всё, что модулю нужно от приложения, — протоколами. Приложение даёт адаптеры.

/// Событие журнала. Только числа и коды: ни ID, ни имён, ни путей, ни паролей сюда не передать.
public enum RemoteLogEvent: Equatable, Sendable {
    case loaded(records: Int, skipped: Int, duplicates: Int, unrecognizedColumns: Int, milliseconds: Int)
    case loadFailed(ConnectionsError.Code)
    case retrying(ConnectionsError.Code, attempt: Int)
    /// Исход подключения: код (`ConnectionOutcome.code`), дошло ли до ввода, длительность.
    case connection(result: String, typed: Bool, milliseconds: Int)

    /// Строка для журнала приложения.
    public var message: String {
        switch self {
        case let .loaded(records, skipped, duplicates, columns, ms):
            return "connections loaded=\(records) skipped=\(skipped) duplicates=\(duplicates) columns=\(columns) ms=\(ms)"
        case let .loadFailed(code):
            return "connections failed=\(code.rawValue)"
        case let .retrying(code, attempt):
            return "connections retry=\(code.rawValue) attempt=\(attempt)"
        case let .connection(result, typed, ms):
            return "connect result=\(result) typed=\(typed ? 1 : 0) ms=\(ms)"
        }
    }
}

public protocol RemoteLogger: AnyObject {
    func log(_ event: RemoteLogEvent)
}

/// Где хранится выбор файла. Только путь и имя листа; пароли сюда не попадают никогда.
public protocol ConnectionsSettingsStore: AnyObject {
    var filePath: String? { get set }
    var sheetName: String? { get set }
}

public final class InMemoryConnectionsSettings: ConnectionsSettingsStore {
    public var filePath: String?
    public var sheetName: String?

    public init(filePath: String? = nil, sheetName: String? = nil) {
        self.filePath = filePath
        self.sheetName = sheetName
    }
}
