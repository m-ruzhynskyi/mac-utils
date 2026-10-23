import XCTest
@testable import MURemoteConnections

/// Правка .xml: меняются только байты нужной записи; `.bak` с теми же правами; запись атомарная.
final class XMLEditorTests: XCTestCase {
    private let file = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- Список подключений: <connection> внутри комментария не запись -->
        <connections>
          <connection>
            <name>Лаборатория Север</name>
            <id>123 456 789</id>
            <password><![CDATA[Pw-1-секрет&<>]]></password>
            <group>Лаборатории</group>
            <extra a="1">чужое поле</extra>
          </connection>
          <connection name="Касса &amp; склад" id="223456789" password="Pw-2-секрет" app="TeamViewer"/>
          <connection><name>Аптека</name><id>323456789</id><note/></connection>
        </connections>

        """

    private func records(_ data: Data) throws -> [ConnectionRecord] { try XMLSource().load(data).records }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testUpdateChangesOnlyEditedField() throws {
        let data = Data(file.utf8)
        let north = try records(data)[0]
        var draft = ConnectionDraft(north)
        draft.group = "Филиалы"
        let out = try XMLConnectionsEditor.update(north, with: draft, in: data)
        XCTAssertEqual(text(out), file.replacingOccurrences(of: "<group>Лаборатории</group>", with: "<group>Филиалы</group>"),
                       "остальные байты — как были: ID с пробелами, CDATA пароля, чужие теги, комментарий")
        XCTAssertEqual(try records(out)[0].group, "Филиалы")
        XCTAssertEqual(try XMLSource().password(for: try records(out)[0], in: out)?.withBytes { Array($0) }, Array("Pw-1-секрет&<>".utf8))
    }

    func testUpdateWithoutChangesKeepsFileByteForByte() throws {
        let data = Data(file.utf8)
        for record in try records(data) {
            XCTAssertEqual(try XMLConnectionsEditor.update(record, with: ConnectionDraft(record), in: data), data, record.name)
        }
    }

    func testUpdateAddsMissingFieldsAndPassword() throws {
        let data = Data(file.utf8)
        let pharmacy = try records(data)[2]
        var draft = ConnectionDraft(pharmacy)
        draft.note = "звонить <заранее>"
        draft.program = .anyDesk
        draft.password = "новый"
        let out = try XMLConnectionsEditor.update(pharmacy, with: draft, in: data)
        XCTAssertTrue(text(out).contains("<connection><name>Аптека</name><id>323456789</id><note>звонить &lt;заранее&gt;</note><app>AnyDesk</app><password>новый</password></connection>"),
                      text(out))
        let updated = try records(out)[2]
        XCTAssertEqual(updated.note, "звонить <заранее>")
        XCTAssertEqual(updated.program, .anyDesk)
        XCTAssertTrue(updated.hasPassword)
        // Остальные записи не тронуты.
        XCTAssertTrue(text(out).hasPrefix(String(file.prefix(upTo: file.range(of: "  <connection><name>Аптека")!.lowerBound))))
    }

    func testUpdateAttributeRecord() throws {
        let data = Data(file.utf8)
        let cash = try records(data)[1]
        XCTAssertEqual(cash.name, "Касса & склад")
        var draft = ConnectionDraft(cash)
        draft.name = "Касса \"2\""
        draft.tags = "ночь;  касса"
        let out = try XMLConnectionsEditor.update(cash, with: draft, in: data)
        XCTAssertTrue(text(out).contains(#"<connection name="Касса &quot;2&quot;" id="223456789" password="Pw-2-секрет" app="TeamViewer" tags="ночь, касса"/>"#),
                      text(out))
        XCTAssertEqual(try records(out)[1].name, "Касса \"2\"")
        XCTAssertEqual(try records(out)[1].tags, ["ночь", "касса"])
    }

    func testChangeIDAndRemovePassword() throws {
        let data = Data(file.utf8)
        let north = try records(data)[0]
        var draft = ConnectionDraft(north)
        draft.id = "987 654 321"
        draft.password = ""
        let out = try XMLConnectionsEditor.update(north, with: draft, in: data)
        let updated = try records(out)[0]
        XCTAssertEqual(updated.id, "987654321")
        XCTAssertFalse(updated.hasPassword)
        XCTAssertFalse(text(out).contains("Pw-1"))
    }

    func testAddAppendsWithSameIndent() throws {
        let data = Data(file.utf8)
        let draft = ConnectionDraft(name: "Склад Одесса", id: "1 234 567 890", group: "Склады", program: .teamViewer, password: "p&1")
        let out = try XMLConnectionsEditor.add(draft, to: data)
        let expected = file.replacingOccurrences(of: "<note/></connection>\n</connections>",
                                                 with: "<note/></connection>\n  <connection><name>Склад Одесса</name><id>1234567890</id><password>p&amp;1</password><group>Склады</group><app>TeamViewer</app></connection>\n</connections>")
        XCTAssertEqual(text(out), expected)
        XCTAssertEqual(try records(out).count, 4)
    }

    func testAddToEmptyFile() throws {
        for empty in ["<connections></connections>", "<connections>\n</connections>\n", "<connections/>"] {
            let draft = ConnectionDraft(name: "Офис", id: "office@ad")
            if empty == "<connections/>" {
                XCTAssertThrowsError(try XMLConnectionsEditor.add(draft, to: Data(empty.utf8)))
                continue
            }
            let out = try XMLConnectionsEditor.add(draft, to: Data(empty.utf8))
            XCTAssertEqual(try records(out).map(\.id), ["office@ad"], empty)
        }
    }

    func testDeleteRemovesWholeLine() throws {
        let data = Data(file.utf8)
        let cash = try records(data)[1]
        let out = try XMLConnectionsEditor.delete(cash, in: data)
        XCTAssertEqual(text(out), file.replacingOccurrences(
            of: "  <connection name=\"Касса &amp; склад\" id=\"223456789\" password=\"Pw-2-секрет\" app=\"TeamViewer\"/>\n", with: ""))
        let north = try records(data)[0]
        let out2 = try XMLConnectionsEditor.delete(north, in: data)
        XCTAssertEqual(try records(out2).map(\.name), ["Касса & склад", "Аптека"])
        XCTAssertFalse(text(out2).contains("чужое поле"))
        XCTAssertTrue(text(out2).contains("<!-- Список подключений"))
    }

    func testFindsRecordAfterFileShifted() throws {
        let data = Data(file.utf8)
        let pharmacy = try records(data)[2]
        let shifted = Data(file.replacingOccurrences(of: "<connections>", with: "<connections>\n\n\n").utf8)
        let out = try XMLConnectionsEditor.delete(pharmacy, in: shifted)
        XCTAssertEqual(try records(out).count, 2)
        let ghost = ConnectionRecord(sourceRow: 4, name: "Нет", id: "999999999")
        XCTAssertThrowsError(try XMLConnectionsEditor.delete(ghost, in: data)) { XCTAssertEqual($0 as? XMLEditError, .entryNotFound) }
    }

    func testValidation() {
        XCTAssertEqual(ConnectionDraft(name: " ", id: "12345").problems, [.missingName, .invalidID])
        XCTAssertEqual(ConnectionDraft(name: "a", id: "front@ad", program: .teamViewer).problems, [.aliasNotSupported])
        XCTAssertEqual(ConnectionDraft(name: "a", id: "123 456 789").problems, [])
        XCTAssertThrowsError(try XMLConnectionsEditor.add(ConnectionDraft(name: "", id: "1"), to: Data(file.utf8))) {
            XCTAssertEqual($0 as? XMLEditError, .invalid([.missingName, .invalidID]))
        }
    }

    func testUnsupportedFiles() {
        let draft = ConnectionDraft(name: "a", id: "123456789")
        let cases = [
            "<?xml version=\"1.0\" encoding=\"windows-1251\"?><connections></connections>",
            "<!DOCTYPE connections [<!ENTITY x \"y\">]><connections></connections>",
            "<hosts></hosts>",
            "<connections><connection>",
        ]
        for c in cases { XCTAssertThrowsError(try XMLConnectionsEditor.add(draft, to: Data(c.utf8)), c) }
    }

    func testFuzzedEditsKeepOtherRecordsIntact() throws {
        let data = Fixtures.xml(rows: Fixtures.messyRows())
        let before = try records(data)
        for (i, record) in before.enumerated() where i % 17 == 0 {
            var draft = ConnectionDraft(record)
            draft.note = "правка \(i)"
            let out = try XMLConnectionsEditor.update(record, with: draft, in: data)
            let after = try records(out)
            XCTAssertEqual(after.count, before.count)
            for (a, b) in zip(after, before) where a.sourceRow != record.sourceRow { XCTAssertEqual(a, b) }
            XCTAssertEqual(after.first { $0.sourceRow == record.sourceRow }?.note, "правка \(i)")
        }
    }

    // MARK: Запись на диск

    func testWriteKeepsPermissionsAndBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("connections.xml")
        let data = Data(file.utf8)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        let out = try XMLConnectionsEditor.delete(try records(data)[2], in: data)
        try XMLConnectionsEditor.write(out, to: url)

        func perms(_ u: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
        let bak = dir.appendingPathComponent("connections.xml.bak")
        XCTAssertEqual(try Data(contentsOf: url), out)
        XCTAssertEqual(try Data(contentsOf: bak), data)
        XCTAssertEqual(try perms(url), 0o600)
        XCTAssertEqual(try perms(bak), 0o600)
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int, inode, "замена атомарная: новый файл")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["connections.xml", "connections.xml.bak"])

        // Второй раз .bak заменяется предыдущей версией; права 644 переносятся так же.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try XMLConnectionsEditor.write(data, to: url)
        XCTAssertEqual(try Data(contentsOf: bak), out)
        XCTAssertEqual(try perms(bak), 0o644)
        XCTAssertEqual(try perms(url), 0o644)
    }

    func testWriteFailureLeavesOriginal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("c.xml")
        try Data(file.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try XMLConnectionsEditor.write(Data("x".utf8), to: url)) { XCTAssertEqual($0 as? XMLEditError, .writeFailed) }
        XCTAssertEqual(try Data(contentsOf: url), Data(file.utf8))
        XCTAssertThrowsError(try XMLConnectionsEditor.write(Data(), to: dir.appendingPathComponent("нет.xml")))
    }

    /// Символическая ссылка остаётся ссылкой, правится её цель; `.bak` — рядом с целью.
    func testWriteThroughSymlinkEditsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-link-\(UUID().uuidString)")
        let real = root.appendingPathComponent("cloud"), links = root.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = real.appendingPathComponent("connections.xml")
        try Data(file.utf8).write(to: target)
        let link = links.appendingPathComponent("c.xml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let out = try XMLConnectionsEditor.delete(try records(Data(file.utf8))[2], in: Data(file.utf8))
        try XMLConnectionsEditor.write(out, to: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, "ссылка цела")
        XCTAssertEqual(try Data(contentsOf: target), out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("connections.xml.bak").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: links.path), ["c.xml"])
    }

    /// Права нового файла — ровно как у оригинала, при любом umask.
    func testWriteKeepsExactPermissionsWhateverUmask() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-umask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.xml")
        for (mask, perms) in [(mode_t(0o000), 0o600), (mode_t(0o077), 0o644), (mode_t(0o022), 0o664)] {
            try Data(file.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
            let old = umask(mask)
            defer { umask(old) }
            try XMLConnectionsEditor.write(Data(file.utf8), to: url)
            umask(old)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, perms)
        }
    }

    /// Сохранённая запись читается обратно ровно как в черновике — и при «неудобных» символах.
    func testWrittenEntryReadsBackLikeDraft() throws {
        let data = Data(file.utf8)
        let draft = ConnectionDraft(name: "  Склад <№1> & \"двор\" ", id: "1 234 567 890", group: "A&B", tags: "x; y, x",
                                    note: "]]> <![CDATA[ ok", program: .teamViewer, password: "пароль <&> ]]>")
        let out = try XMLConnectionsEditor.add(draft, to: data)
        let added = try records(out).last!
        XCTAssertEqual(added.name, "Склад <№1> & \"двор\"")
        XCTAssertEqual(added.tags, ["x", "y"])
        XCTAssertEqual(added.note, "]]> <![CDATA[ ok")
        XCTAssertEqual(try XMLSource().password(for: added, in: out)?.withBytes { Array($0) }, Array("пароль <&> ]]>".utf8))
        var edit = ConnectionDraft(added)
        edit.password = "новый & другой"
        edit.note = "<note>"
        let out2 = try XMLConnectionsEditor.update(added, with: edit, in: out)
        XCTAssertEqual(try records(out2).last?.note, "<note>")
    }

    // MARK: Шаблон и права

    func testTemplatesReadBackInEveryLanguage() throws {
        defer { RemoteL10n.language = .ru }
        for language in RemoteLanguage.allCases {
            RemoteL10n.language = language
            let fromXML = try XMLSource().load(ConnectionsTemplate.xml())
            let fromXLSX = try XLSXSource().load(ConnectionsTemplate.xlsx())
            XCTAssertEqual(Set(fromXML.diagnostics.columns.map(\.field)), Set(ConnectionField.allCases))
            for snap in [fromXML, fromXLSX] {
                XCTAssertEqual(snap.records.map(\.id), ["123456789"], language.rawValue)
                XCTAssertEqual(snap.records.first?.program, .anyDesk)
                XCTAssertTrue(snap.diagnostics.isClean, language.rawValue)
            }
            XCTAssertEqual(Set(fromXLSX.diagnostics.columns.map(\.field)), Set(ConnectionField.allCases), language.rawValue)
            XCTAssertEqual(try XLSXSource.sheetNames(in: ConnectionsTemplate.xlsx()), [ConnectionsTemplate.sheetName])
        }
    }

    func testPermissionsCheck() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-perm-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }
        try ConnectionsTemplate.xml().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertTrue(ConnectionsFilePermissions.isShared(url))
        try ConnectionsFilePermissions.restrict(url)
        XCTAssertFalse(ConnectionsFilePermissions.isShared(url))
    }
}

/// По `MU_RC_TEMPLATE_DIR=папка` кладёт шаблоны туда — проверить сторонней программой (openpyxl, Excel).
final class TemplateExportTests: XCTestCase {
    func testExportTemplates() throws {
        guard let dir = ProcessInfo.processInfo.environment["MU_RC_TEMPLATE_DIR"] else { throw XCTSkip("MU_RC_TEMPLATE_DIR не задан") }
        try ConnectionsTemplate.xlsx().write(to: URL(fileURLWithPath: dir).appendingPathComponent("connections.xlsx"))
        try ConnectionsTemplate.xml().write(to: URL(fileURLWithPath: dir).appendingPathComponent("connections.xml"))
    }
}
