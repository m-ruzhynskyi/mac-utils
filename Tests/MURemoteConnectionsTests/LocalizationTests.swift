import XCTest
@testable import MURemoteConnections

/// Русский, украинский, английский: у каждой строки `RL(…)` модуля и вкладки приложения есть оба перевода.
final class LocalizationTests: XCTestCase {
    override func tearDown() { RemoteL10n.language = .ru }

    /// Ключи `RL("…")` из исходников модуля и тонкого слоя приложения.
    private func keys() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dirs = ["Sources/MURemoteConnections", "Sources/MacUtils/Features/RemoteConnections"]
        let files = try dirs.flatMap { dir in
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)
                .filter { $0.hasSuffix(".swift") }.map { root.appendingPathComponent(dir).appendingPathComponent($0) }
        }
        let pattern = try NSRegularExpression(pattern: #"RL\("((?:[^"\\]|\\.)*)""#)
        var out: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let raw = String(text[Range(m.range(at: 1), in: text)!])
                out.append(raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return out
    }

    func testEveryStringIsTranslated() throws {
        let keys = try keys()
        XCTAssertGreaterThan(keys.count, 150)
        for key in keys { XCTAssertTrue(RemoteL10n.hasTranslation(key), "нет перевода: \(key)") }
        for (key, value) in RemoteStrings.table {
            let n = key.components(separatedBy: "%@").count
            XCTAssertEqual(value.uk.components(separatedBy: "%@").count, n, key)
            XCTAssertEqual(value.en.components(separatedBy: "%@").count, n, key)
            // Исключение — имя вкладки «Удалённые»: в боковом меню и панели оно русское, как всё приложение.
            XCTAssertNil(value.en.replacingOccurrences(of: "«Удалённые»", with: "").range(of: "[А-Яа-яЁёІіЇїЄє]", options: .regularExpression),
                         "кириллица в английском: \(value.en)")
        }
        XCTAssertEqual(Set(RemoteStrings.table.keys).subtracting(keys), [], "лишние переводы")
    }

    func testLanguageSwitchAndArguments() {
        XCTAssertEqual(RL("Открываю %@…", "AnyDesk"), "Открываю AnyDesk…")
        RemoteL10n.language = .uk
        XCTAssertEqual(RL("Открываю %@…", "AnyDesk"), "Відкриваю AnyDesk…")
        XCTAssertEqual(RL("%@ отклонил пароль для «%@».", "TeamViewer", "Склад"), "TeamViewer відхилив пароль для «Склад».")
        RemoteL10n.language = .en
        XCTAssertEqual(RL("Загружено %@", 214), "Loaded 214")
        XCTAssertEqual(RL("Нет такой строки %@", 1), "Нет такой строки 1", "без перевода — русский")
        XCTAssertEqual(RemoteL10n.text("Подключено", in: .ru), "Подключено")
    }
}
