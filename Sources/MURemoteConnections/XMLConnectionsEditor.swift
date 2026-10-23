import Foundation

/// Запись, которую пользователь добавляет или правит в окне «Правка записи».
public struct ConnectionDraft: Equatable, Sendable {
    public var name: String
    public var id: String
    public var group: String
    public var tags: String
    public var note: String
    public var program: RemoteProgram?
    /// nil — пароль в файле не трогаем (в окне правки его не видно); "" — убрать; иначе — новый.
    public var password: String?

    public init(name: String = "", id: String = "", group: String = "", tags: String = "", note: String = "",
                program: RemoteProgram? = nil, password: String? = nil) {
        self.name = name
        self.id = id
        self.group = group
        self.tags = tags
        self.note = note
        self.program = program
        self.password = password
    }

    /// Черновик из записи списка: пароля в записи нет, поэтому он не меняется.
    public init(_ record: ConnectionRecord) {
        self.init(name: record.name, id: record.displayID, group: record.group, tags: record.tags.joined(separator: ", "),
                  note: record.note, program: record.program)
    }

    public enum Problem: String, Equatable, Sendable {
        case missingName
        case invalidID
        /// Алиас `имя@ad` у программы без алиасов.
        case aliasNotSupported
    }

    public var problems: [Problem] {
        var out: [Problem] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.missingName) }
        if let n = ConnectionID.normalize(id) {
            if n.isAlias, let program, !program.supportsAliases { out.append(.aliasNotSupported) }
        } else {
            out.append(.invalidID)
        }
        return out
    }

    /// ID в том виде, как он пишется в файл: цифры без пробелов или алиас.
    var normalizedID: String { ConnectionID.normalize(id)?.value ?? id }
}

public enum XMLEditError: Error, Equatable, Sendable {
    case invalid([ConnectionDraft.Problem])
    /// Записи больше нет (файл поменяли после чтения списка).
    case entryNotFound
    /// Файл не XML, не UTF-8 или устроен так, что правку без потерь не сделать.
    case unsupported
    case corrupt
    /// Не записалось (права, диск); исходный файл не тронут.
    case writeFailed
}

/// Правка `.xml` с подключениями без потерь: меняются только байты нужной записи (или одного поля),
/// всё остальное — комментарии, порядок, отступы, чужие теги, пароль, если его не меняли, — остаётся байт в байт.
/// XLSX не пишем никогда.
public enum XMLConnectionsEditor {
    public static func add(_ draft: ConnectionDraft, to data: Data) throws -> Data {
        try check(draft)
        let doc = try XMLScan(data)
        let indent = doc.connections.last.map { doc.lineIndent(before: $0.range.lowerBound) } ?? "  "
        var fields = values(draft)
        if let pw = draft.password, !pw.isEmpty { fields.insert((.password, pw), at: 2) }
        var element = "<connection>"
        for (field, value) in fields where !value.isEmpty {
            element += "<\(tag(field))>\(escape(value))</\(tag(field))>"
        }
        element += "</connection>"
        let insertAt: Int
        let text: String
        if let last = doc.connections.last {
            insertAt = doc.lineEnd(after: last.range.upperBound)
            text = "\n" + indent + element
        } else {
            guard let close = doc.rootCloseStart else { throw XMLEditError.unsupported }
            let start = doc.lineStart(of: close)
            if doc.isBlank(start..<close) {
                insertAt = start
                text = indent + element + "\n"
            } else {
                insertAt = close
                text = "\n" + indent + element + "\n"
            }
        }
        var out = data
        out.replaceSubrange(insertAt..<insertAt, with: Data(text.utf8))
        try verify(out, expectedDelta: 1, data)
        try verifyWritten(draft, in: out)
        return out
    }

    public static func update(_ record: ConnectionRecord, with draft: ConnectionDraft, in data: Data) throws -> Data {
        try check(draft)
        let doc = try XMLScan(data)
        let element = try doc.find(record)
        var edits: [(Range<Int>, String)] = []
        var missing: [(ConnectionField, String)] = []
        var all = values(draft)
        if let pw = draft.password { all.append((.password, pw)) }
        for (field, value) in all {
            if let child = element.children.first(where: { $0.field == field }) {
                if let content = child.content {
                    if !same(field, doc.text(content), value) { edits.append((content, escape(value))) }
                } else if !value.isEmpty {
                    // Пустой `<note/>` → `<note>…</note>`.
                    edits.append((child.range, "<\(child.name)>\(escape(value))</\(child.name)>"))
                }
            } else if let attr = element.attributes.first(where: { $0.field == field }) {
                if !same(field, doc.text(attr.value), value) { edits.append((attr.value, escape(value, attribute: true))) }
            } else if !value.isEmpty {
                missing.append((field, value))
            }
        }
        if !missing.isEmpty {
            if let close = element.closeTagStart {
                edits.append((close..<close, missing.map { "<\(tag($0.0))>\(escape($0.1))</\(tag($0.0))>" }.joined()))
            } else {
                // `<connection … />`: недостающие поля — атрибутами.
                let at = element.startTagEnd - 2
                edits.append((at..<at, missing.map { " \(tag($0.0))=\"\(escape($0.1, attribute: true))\"" }.joined()))
            }
        }
        var out = data
        for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            out.replaceSubrange(range, with: Data(text.utf8))
        }
        try verify(out, expectedDelta: 0, data)
        try verifyWritten(draft, in: out)
        return out
    }

    public static func delete(_ record: ConnectionRecord, in data: Data) throws -> Data {
        let doc = try XMLScan(data)
        let element = try doc.find(record)
        var range = element.range
        // Строка целиком, если на ней только эта запись.
        let lineStart = doc.lineStart(of: range.lowerBound)
        let lineEnd = doc.lineEnd(after: range.upperBound)
        if doc.isBlank(lineStart..<range.lowerBound), doc.isBlank(range.upperBound..<lineEnd) {
            range = lineStart..<min(lineEnd + 1, data.count)
        }
        var out = data
        out.removeSubrange(range)
        try verify(out, expectedDelta: -1, data)
        return out
    }

    // MARK: Запись на диск

    /// Атомарная запись: сначала `имя.xml.bak` с теми же правами, затем временный файл рядом — сразу с теми же
    /// правами (`O_EXCL`, `fchmod` до записи данных: ни мгновения с правами по umask), с расширенными атрибутами и ACL
    /// оригинала — и `rename` поверх. Символическая ссылка не заменяется файлом: правится её цель.
    /// При ошибке исходный файл не меняется.
    public static func write(_ data: Data, to link: URL) throws {
        let fm = FileManager.default
        let url = link.resolvingSymlinksInPath()
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else { throw XMLEditError.writeFailed }
        let bak = url.appendingPathExtension("bak")
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            if fm.fileExists(atPath: bak.path) { try fm.removeItem(at: bak) }
            try fm.copyItem(at: url, to: bak)
            try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: bak.path)
            try create(tmp, data, perms: mode_t(perms))
            // Расширенные атрибуты и ACL — как у оригинала; не перенеслись — не страшно, данные и права уже верны.
            _ = copyfile(url.path, tmp.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
            _ = chmod(tmp.path, mode_t(perms))
            guard rename(tmp.path, url.path) == 0 else { throw XMLEditError.writeFailed }
        } catch {
            try? fm.removeItem(at: tmp)
            throw XMLEditError.writeFailed
        }
    }

    private static func create(_ url: URL, _ data: Data, perms: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, perms)
        guard fd >= 0 else { throw XMLEditError.writeFailed }
        defer { close(fd) }
        // umask мог только убрать биты; ставим ровно права оригинала до записи данных.
        guard fchmod(fd, perms) == 0 else { throw XMLEditError.writeFailed }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
        guard ok, fsync(fd) == 0 else { throw XMLEditError.writeFailed }
    }

    // MARK: Внутреннее

    private static func check(_ draft: ConnectionDraft) throws {
        let problems = draft.problems
        if !problems.isEmpty { throw XMLEditError.invalid(problems) }
    }

    private static func values(_ draft: ConnectionDraft) -> [(ConnectionField, String)] {
        let tags = XMLConnectionsEditorTags.split(draft.tags).joined(separator: ", ")
        var out: [(ConnectionField, String)] = [
            (.name, draft.name.trimmingCharacters(in: .whitespacesAndNewlines)),
            (.id, draft.normalizedID),
            (.group, draft.group.trimmingCharacters(in: .whitespacesAndNewlines)),
            (.tags, tags),
            (.note, draft.note.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        out.append((.program, draft.program?.title ?? ""))
        return out
    }

    /// Значение в файле уже равно новому (с точностью до записи): тогда байты не трогаем.
    private static func same(_ field: ConnectionField, _ old: String, _ new: String) -> Bool {
        let trimmed = old.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .id: return ConnectionID.normalize(old)?.value == new
        case .tags: return XMLConnectionsEditorTags.split(old) == XMLConnectionsEditorTags.split(new)
        case .program: return RemoteProgram.parse(old) == RemoteProgram.parse(new) && trimmed.isEmpty == new.isEmpty
        case .password: return old == new
        default: return trimmed == new
        }
    }

    static func tag(_ field: ConnectionField) -> String {
        switch field {
        case .name: return "name"
        case .id: return "id"
        case .password: return "password"
        case .group: return "group"
        case .tags: return "tags"
        case .note: return "note"
        case .program: return "app"
        }
    }

    /// Экранирование для текста элемента или значения атрибута. По скалярам, а не символам: «\r\n» — один `Character`.
    /// CR пишется ссылкой везде (иначе читатель XML превратит CRLF в LF). В атрибуте ещё и перевод строки
    /// и табуляция — ссылками: литералом они читались бы пробелом (нормализация значения атрибута), и многострочная
    /// заметка у записи `<connection … />` потерялась бы.
    static func escape(_ s: String, attribute: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        func put(_ t: String) { out.append(contentsOf: t.unicodeScalars) }
        for u in s.unicodeScalars {
            switch u {
            case "&": put("&amp;")
            case "<": put("&lt;")
            case ">": put("&gt;")
            case "\r": put("&#13;")
            case "\"" where attribute: put("&quot;")
            case "'" where attribute: put("&apos;")
            case "\n" where attribute: put("&#10;")
            case "\t" where attribute: put("&#9;")
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// Запись из черновика читается обратно ровно такой, как в окне правки (и пароль, если его меняли).
    private static func verifyWritten(_ draft: ConnectionDraft, in out: Data) throws {
        let source = XMLSource()
        guard let records = try? source.load(out).records else { throw XMLEditError.corrupt }
        let trimmed = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let matches = records.filter {
            $0.id == draft.normalizedID && $0.name == trimmed(draft.name) && $0.group == trimmed(draft.group)
                && $0.tags == ConnectionsBuilder.splitTags(draft.tags) && $0.note == trimmed(draft.note)
                && $0.program == draft.program
        }
        guard !matches.isEmpty else { throw XMLEditError.corrupt }
        guard let password = draft.password else { return }
        let ok = matches.contains { record in
            switch try? source.lookupPassword(for: record, in: out) {
            case .found(let secret)?:
                defer { secret.wipe() }
                return secret.withBytes { $0.elementsEqual(password.utf8) }
            case .noPassword?: return password.isEmpty
            default: return false
            }
        }
        guard ok else { throw XMLEditError.corrupt }
    }

    /// После правки файл должен читаться, а записей — стать на `expectedDelta` больше.
    private static func verify(_ out: Data, expectedDelta: Int, _ original: Data) throws {
        guard let before = try? XMLSource().parse(original, mode: .records),
              let after = try? XMLSource().parse(out, mode: .records),
              after.entries.count == before.entries.count + expectedDelta else { throw XMLEditError.corrupt }
    }
}

enum XMLConnectionsEditorTags {
    static func split(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
