import XCTest
@testable import MUTextEditor
@testable import MUCore

/// V3: история $-значений — только память сеанса, по имени знака; ничего на диске и в UserDefaults.
@MainActor
final class DollarHistoryTests: XCTestCase {
    func testNameIsLabelBeforeDollar() {
        let text = "Ответчик: $ООО Ромашка\nИстец - $Иванов" as NSString
        XCTAssertEqual(DollarHistory.name(forDollarAt: text.range(of: "$ООО").location, in: text), "ответчик")
        XCTAssertEqual(DollarHistory.name(forDollarAt: text.range(of: "$Иванов").location, in: text), "истец")
        XCTAssertEqual(DollarHistory.name(forDollarAt: 0, in: "$x" as NSString), "", "без подписи — пустое имя")
        // Длинная подпись: имя — ближайшее к `$`, а не начало строки (иначе у всех знаков с одинаковым началом строки одна история).
        let long = "Сведения о заявителе по делу № 123, фамилия: $Иванов\nСведения о заявителе по делу № 123, телефон: $555" as NSString
        let surname = DollarHistory.name(forDollarAt: long.range(of: "$Иванов").location, in: long)
        let phone = DollarHistory.name(forDollarAt: long.range(of: "$555").location, in: long)
        XCTAssertTrue(surname.hasSuffix("фамилия"), surname)
        XCTAssertTrue(phone.hasSuffix("телефон"), phone)
        XCTAssertNotEqual(surname, phone)
        XCTAssertLessThanOrEqual(surname.count, 40)
    }

    func testRecordsByNameMostRecentFirstWithoutDuplicates() {
        let history = DollarHistory()
        history.record("ООО Ромашка", name: "ответчик")
        history.record("ООО Лютик", name: "ответчик")
        history.record("ООО Ромашка", name: "ответчик")
        history.record("Иванов", name: "истец")
        XCTAssertEqual(history.suggestions(name: "ответчик"), ["ООО Ромашка", "ООО Лютик"])
        XCTAssertEqual(history.suggestions(name: "истец"), ["Иванов"])
        XCTAssertEqual(history.suggestions(name: "судья"), [])
        XCTAssertEqual(history.suggestions(name: "ответчик", prefix: "ооо л"), ["ООО Лютик"])
    }

    func testEmptyValuesNotRememberedAndListIsLimited() {
        let history = DollarHistory()
        history.record("   ", name: "a")
        history.record("", name: "a")
        XCTAssertTrue(history.isEmpty)
        for index in 0..<30 { history.record("v\(index)", name: "a") }
        XCTAssertEqual(history.suggestions(name: "a").count, DollarHistory.limitPerName)
        XCTAssertEqual(history.suggestions(name: "a").first, "v29")
    }

    func testModelHelpersUseSessionHistoryByName() {
        let text = "Ответчик: $ООО Ромашка" as NSString
        let entry = DollarPanelModel.scan(text).first!
        let model = DollarPanelModel()
        let history = DollarHistory()
        model.remember("ООО Ромашка", for: entry, in: text, history: history)
        XCTAssertEqual(model.suggestions(for: entry, in: text, history: history), ["ООО Ромашка"])
    }

    /// Никакой записи: ни в UserDefaults (снимок всего домена до и после), ни на диск (каталог временных файлов теста).
    func testNothingIsWrittenToDefaultsOrDisk() throws {
        let suiteName = "dollar-history-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let standardBefore = UserDefaults.standard.dictionaryRepresentation().filter { !$0.key.hasPrefix("NS") && !$0.key.hasPrefix("Apple") }
        let tmp = FileManager.default.temporaryDirectory
        let tmpBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])

        let history = DollarHistory()
        let text = "Ответчик: $ООО Ромашка" as NSString
        let model = DollarPanelModel()
        let entry = DollarPanelModel.scan(text).first!
        for index in 0..<50 { model.remember("Значение \(index)", for: entry, in: text, history: history) }
        history.record("ПДн", name: "x")
        _ = history.suggestions(name: "x")
        history.clear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue((suite.persistentDomain(forName: suiteName) ?? [:]).isEmpty, "свой suite пуст")
        let standardAfter = UserDefaults.standard.dictionaryRepresentation().filter { !$0.key.hasPrefix("NS") && !$0.key.hasPrefix("Apple") }
        XCTAssertEqual(standardAfter.keys.sorted(), standardBefore.keys.sorted(), "в общие настройки ничего не добавлено")
        for value in standardAfter.values { XCTAssertFalse("\(value)".contains("Значение"), "значение попало в настройки") }
        let tmpAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
        XCTAssertTrue(tmpAfter.subtracting(tmpBefore).filter { $0.lowercased().contains("dollar") || $0.lowercased().contains("history") }.isEmpty,
                      "файлов истории нет")
    }

    func testHistoryTypeIsNotCodableAndHasNoPersistenceHooks() {
        XCTAssertFalse((DollarHistory.self as Any) is Encodable.Type)
        XCTAssertFalse((DollarHistory.self as Any) is Decodable.Type)
    }
}
