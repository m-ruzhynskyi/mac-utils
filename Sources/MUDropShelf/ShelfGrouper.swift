import AppKit
import Darwin
import PDFKit
import MUCore
import MUDesign

package struct ShelfGroup: Identifiable, Equatable {
    package let id = UUID()
    package var title: String
    package var files: [URL]
}
package enum ShelfGrouper {
    package static func group(_ files: [URL]) async throws -> [ShelfGroup] {
        let list = files.enumerated().map { "\($0.offset + 1). \($0.element.lastPathComponent)" }.joined(separator: "\n")
        let prompt = """
        Сгруппируй эти файлы по смыслу (проект, тема, тип задачи). 2–5 групп, короткие русские подписи.
        \(list)
        Ответь JSON: {"groups": [{"title": "...", "files": [1, 2]}]}
        """
        let json = try await Ollama.generateJSON(prompt)
        var used = Set<Int>()
        var groups: [ShelfGroup] = []
        for entry in json["groups"] as? [[String: Any]] ?? [] {
            let indexes = (entry["files"] as? [Int] ?? []).filter { $0 >= 1 && $0 <= files.count && !used.contains($0) }
            guard !indexes.isEmpty else { continue }
            used.formUnion(indexes)
            groups.append(ShelfGroup(title: entry["title"] as? String ?? "Группа", files: indexes.map { files[$0 - 1] }))
        }
        let rest = files.indices.filter { !used.contains($0 + 1) }.map { files[$0] }
        if !rest.isEmpty { groups.append(ShelfGroup(title: "Другое", files: rest)) }
        return groups
    }
}
