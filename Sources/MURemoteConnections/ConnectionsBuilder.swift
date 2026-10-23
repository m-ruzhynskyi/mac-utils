import Foundation

/// Сырые строки → записи без паролей + диагностика.
enum ConnectionsBuilder {
    static func build(_ file: ParsedFile) -> ConnectionsSnapshot {
        var diag = ConnectionsDiagnostics()
        diag.columns = file.columns
        diag.unrecognizedColumns = file.unrecognizedColumns
        var records: [ConnectionRecord] = []
        records.reserveCapacity(file.entries.count)
        for e in file.entries where !e.isEmpty {
            let name = trim(e.name)
            let rawID = trim(e.id)
            let skip = { (reason: SkippedRow.Reason, value: String) in
                diag.skipped.append(SkippedRow(row: e.row, reason: reason, value: value))
            }
            if name.isEmpty { skip(.missingName, ""); continue }
            if rawID.isEmpty { skip(.missingID, ""); continue }
            guard let id = ConnectionID.normalize(rawID) else { skip(.invalidID, rawID); continue }
            let programText = trim(e.program)
            var program: RemoteProgram?
            if !programText.isEmpty {
                guard let p = RemoteProgram.parse(programText) else { skip(.unknownProgram, programText); continue }
                program = p
            }
            if let program, id.isAlias, !program.supportsAliases { skip(.aliasNotSupported, rawID); continue }
            if id.lossy { diag.lossyIDRows.append(e.row) }
            records.append(ConnectionRecord(
                sourceRow: e.row, name: name, id: id.value,
                group: trim(e.group), tags: splitTags(e.tags), note: trim(e.note),
                program: program, hasPassword: e.hasPassword))
        }

        // Без программы и не алиас — возьмётся программа по умолчанию. Если в файле есть обе программы, это стоит показать.
        let named = Set(records.compactMap(\.program))
        if named.count > 1 {
            diag.ambiguousProgramRows = records.filter { $0.program == nil && !$0.isAlias }.map(\.sourceRow)
        }
        diag.duplicates = duplicates(records)
        diag.loaded = records.count
        diag.withPassword = records.filter(\.hasPassword).count
        return ConnectionsSnapshot(records: records, diagnostics: diag)
    }

    /// Один ID несколько раз. Не дубликат — только если у всех строк явно указаны разные программы.
    private static func duplicates(_ records: [ConnectionRecord]) -> [DuplicateGroup] {
        var byID: [String: [ConnectionRecord]] = [:]
        var order: [String] = []
        for r in records {
            if byID[r.id] == nil { order.append(r.id) }
            byID[r.id, default: []].append(r)
        }
        return order.compactMap { id in
            guard let group = byID[id], group.count > 1 else { return nil }
            let programs = group.compactMap(\.program)
            if programs.count == group.count, Set(programs).count == programs.count { return nil }
            return DuplicateGroup(id: id, rows: group.map(\.sourceRow), names: group.map(\.name))
        }
    }

    static func splitTags(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { trim(String($0)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
