import XCTest
@testable import MURemoteConnections

/// Задачи 4–5 (task-rc-terminal-session): учётка Windows, «Доступ», «Контакты», RDP/VPN/«Другое», метки.
/// Все данные выдуманные; программы не запускаются.
@MainActor
final class AccountAndAccessTests: XCTestCase {
    private let access = """
        VPN (WireGuard) | профиль Выдуманный-1

        RDP — IP: 10.20.0.15
        Server — логин: lims.admin · пароль: Demo-77-выдумка

        Login: operator
        """

    private func xml(_ rows: String) -> Data {
        Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<connections>\n\(rows)\n</connections>\n".utf8)
    }

    private var file: Data {
        xml("""
          <connection><name>Північна лабораторія</name><id>123456789</id><password>AD-pass-1</password><group>Північ</group><tags>Рег</tags><account>Администратор</account><accountPassword>Win-pass-1</accountPassword><contacts>Иван, 050 000 00 00</contacts><app>AnyDesk</app></connection>
          <connection><name>Вінницька · Філія 2</name><id>10.20.0.15</id><group>Вінницька</group><tags>рег., VPN, RDP, фіто</tags><account>lims.admin</account><accountPassword>Win-pass-2</accountPassword><access>\(XMLConnectionsEditor.escape(access))</access><app>RDP</app></connection>
          <connection><name>Озерна</name><id></id><group>Вінницька</group><tags>Рег, Сервер</tags><note>Только по телефону</note><app>Другое</app></connection>
          <connection><name>Лісова</name><id></id><tags>РЕГ, VPN</tags><access>Профиль: лес</access><app>VPN</app></connection>
          <connection><name>Східна</name><id>987654321</id><tags>Фито, VPN</tags><app>TeamViewer</app></connection>
        """)
    }

    // MARK: Колонки

    func testHeadersForAccountAccessAndContacts() {
        let cases: [(String, ConnectionField)] = [
            ("Учётная запись", .account), ("учетка", .account), ("Логин", .account), ("Логін", .account), ("Користувач", .account),
            ("Обліковий запис", .account), ("Windows user", .account), ("username", .account),
            ("Пароль учётной записи", .accountPassword), ("Пароль учетки", .accountPassword), ("Пароль Windows", .accountPassword),
            ("Пароль облікового запису", .accountPassword), ("Account password", .accountPassword),
            ("Пароль", .password), ("password", .password),
            ("Доступ", .access), ("Деталі", .access), ("VPN/RDP", .access), ("Підключення", .access),
            ("Контакты", .contacts), ("Контакти", .contacts), ("Контактное лицо", .contacts), ("Контактна особа", .contacts),
        ]
        for (header, field) in cases { XCTAssertEqual(ConnectionHeaders.field(for: header), field, header) }
    }

    /// «Контакты» — известная колонка: не «лишняя», в записи не попадает, файл чистый.
    func testContactsColumnIsKnownButNotLoaded() throws {
        let rows = [["Название", "ID", "Контакты", "Учётная запись", "Пароль учётной записи", "Доступ"],
                    ["Касса", "123 456 789", "Иван, 050 000 00 00", "admin", "Win-1", "строка 1\n\nстрока 2"]]
        let snap = try XLSXSource().load(Fixtures.xlsx(rows: rows))
        XCTAssertEqual(snap.diagnostics.unrecognizedColumns, [])
        XCTAssertTrue(snap.diagnostics.isClean)
        let r = try XCTUnwrap(snap.records.first)
        XCTAssertEqual(r.account, "admin")
        XCTAssertTrue(r.hasAccountPassword)
        XCTAssertEqual(r.accessLines, 2)
        XCTAssertFalse("\(r)".contains("050 000"), "контактов в записи нет")
        XCTAssertFalse("\(r)".contains("Win-1"), "пароля учётки в записи нет")
    }

    // MARK: RDP, VPN, «Другое»

    func testMethodRecordsWithEmptyOrIPIDLoadWithoutComplaints() throws {
        let snap = try XMLSource().load(file)
        XCTAssertEqual(snap.records.count, 5)
        XCTAssertTrue(snap.diagnostics.skipped.isEmpty, "\(snap.diagnostics.skipped)")
        XCTAssertTrue(snap.diagnostics.isClean)
        let byName = Dictionary(uniqueKeysWithValues: snap.records.map { ($0.name, $0) })
        let branch = try XCTUnwrap(byName["Вінницька · Філія 2"])
        XCTAssertEqual(branch.method, .rdp)
        XCTAssertNil(branch.program)
        XCTAssertEqual(branch.id, "10.20.0.15", "адрес RDP — как есть")
        XCTAssertEqual(branch.group, "Вінницька", "филиал — отдельная запись в той же группе")
        XCTAssertTrue(branch.usesRDP && branch.needsVPN)
        XCTAssertEqual(branch.labels.map(ConnectionTag.display), ["Рег", "Фито"], "VPN/RDP — не метки, «рег.» = «Рег», «фіто» = «Фито»")
        XCTAssertEqual(branch.accessLines, 4, "пустые строки между блоками не считаются")
        XCTAssertEqual(byName["Озерна"]?.method, .other)
        XCTAssertEqual(byName["Озерна"]?.id, "")
        XCTAssertEqual(byName["Озерна"]?.favoriteKey, "name:Озерна")
        XCTAssertEqual(byName["Лісова"]?.method, .vpn)
        XCTAssertTrue(byName["Східна"]!.needsVPN, "по метке")
        XCTAssertFalse(byName["Східна"]!.usesRDP)
        XCTAssertEqual(byName["Північна лабораторія"]?.account, "Администратор")
    }

    func testTagKeysIgnoreCaseDotsAndUkrainianLetters() {
        XCTAssertEqual(Set(["Рег", "рег.", "РЕГ", " Рег "].map(ConnectionTag.key)).count, 1)
        XCTAssertEqual(Set(["Фито", "фито", "Фіто", "ФІТО."].map(ConnectionTag.key)).count, 1)
        XCTAssertEqual(ConnectionTag.kind("фіто"), .phyto)
        XCTAssertEqual(ConnectionTag.kind("Рег."), .reg)
        XCTAssertEqual(ConnectionTag.kind("Сервер"), .other)
        XCTAssertEqual(ConnectionsBuilder.splitTags("Рег, рег., Фіто, фито"), ["Рег", "Фіто"])
    }

    // MARK: Секреты: «Доступ», пароль учётки

    /// «Доступ» — с переносами и пустыми строками между блоками; в памяти списка его нет, только по запросу.
    func testAccessKeepsLinesAndIsReadOnlyOnDemand() throws {
        let source = XMLSource()
        let snap = try source.load(file)
        let branch = snap.records.first { $0.method == .rdp }!
        let secret = try XCTUnwrap(source.lookupSecret(.access, for: branch, in: file).secret)
        defer { secret.wipe() }
        XCTAssertEqual(secret.withBytes { String(decoding: $0, as: UTF8.self) }, access)
        XCTAssertFalse("\(snap.records)".contains("Demo-77"), "«Доступа» нет в списке")
    }

    func testAccessAndAccountPasswordAreNotSearchedButLoginIs() throws {
        let search = ConnectionSearch(try XMLSource().load(file).records)
        XCTAssertTrue(search.search("Demo-77").records.isEmpty, "по «Доступу» не ищем")
        XCTAssertTrue(search.search("WireGuard").records.isEmpty)
        XCTAssertTrue(search.search("Win-pass").records.isEmpty)
        XCTAssertTrue(search.search("050 000").records.isEmpty, "по контактам не ищем")
        XCTAssertEqual(search.search("lims.admin").records.map(\.name), ["Вінницька · Філія 2"])
        XCTAssertEqual(Set(search.search("фито").records.map(\.name)), ["Вінницька · Філія 2", "Східна"])
    }

    func testAccountPasswordLookupIncludingRecordsWithoutID() throws {
        let source = XMLSource()
        let records = try source.load(file).records
        let north = records[0]
        let pw = try XCTUnwrap(source.lookupSecret(.accountPassword, for: north, in: file).secret)
        XCTAssertTrue(pw.withBytes { $0.elementsEqual("Win-pass-1".utf8) })
        pw.wipe()
        let main = try XCTUnwrap(source.lookupPassword(for: north, in: file).secret)
        XCTAssertTrue(main.withBytes { $0.elementsEqual("AD-pass-1".utf8) }, "«Пароль» — пароль AnyDesk")
        main.wipe()
        let forest = records.first { $0.name == "Лісова" }!
        let text = try XCTUnwrap(source.lookupSecret(.access, for: forest, in: file).secret)
        XCTAssertTrue(text.withBytes { $0.elementsEqual("Профиль: лес".utf8) })
        text.wipe()
        if case .noPassword = try source.lookupSecret(.accountPassword, for: forest, in: file) {} else { XCTFail("у «Лісова» пароля учётки нет") }
    }

    // MARK: Фильтры и метки

    func testRDPAndVPNFiltersAndTagCounts() throws {
        let search = ConnectionSearch(try XMLSource().load(file).records)
        let all = ConnectionListBuilder.build(search: search, query: "", filter: .all, defaultProgram: .anyDesk, favorites: [], recents: [])
        XCTAssertEqual(all.counts[.all], 5)
        XCTAssertEqual(all.counts[.program(.anyDesk)], 1, "RDP/VPN/«Другое» — не AnyDesk")
        XCTAssertEqual(all.counts[.program(.teamViewer)], 1)
        XCTAssertEqual(all.counts[.rdp], 1)
        XCTAssertEqual(all.counts[.vpn], 3)
        XCTAssertEqual(all.tags.map(\.title), ["Рег", "Фито", "Сервер"])
        XCTAssertEqual(all.tags.map(\.count), [4, 2, 1])

        let vpn = ConnectionListBuilder.build(search: search, query: "", filter: .vpn, defaultProgram: .anyDesk, favorites: [], recents: [])
        XCTAssertEqual(Set(vpn.rows.map(\.record.name)), ["Вінницька · Філія 2", "Лісова", "Східна"])
        let both = ConnectionListBuilder.build(search: search, query: "", filter: .all, defaultProgram: .anyDesk, favorites: [],
                                               recents: [], tags: [ConnectionTag.key("Рег"), ConnectionTag.key("Фито")])
        XCTAssertEqual(both.rows.map(\.record.name), ["Вінницька · Філія 2"], "выбранные метки — все сразу")
        let vpnPhyto = ConnectionListBuilder.build(search: search, query: "", filter: .vpn, defaultProgram: .anyDesk, favorites: [],
                                                   recents: [], tags: [ConnectionTag.key("фіто")])
        XCTAssertEqual(Set(vpnPhyto.rows.map(\.record.name)), ["Вінницька · Філія 2", "Східна"], "вместе с фильтром программы")
    }

    // MARK: RDP

    func testRDPFile() {
        func text(_ host: String, _ account: String = "") -> String? { RDPLink.file(host: host, account: account).map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(text("10.20.0.15"), "full address:s:10.20.0.15\r\n")
        XCTAssertEqual(text(" srv-1.example.lan:3390 ", "lims.admin"), "full address:s:srv-1.example.lan:3390\r\nusername:s:lims.admin\r\n")
        XCTAssertEqual(text("10.0.0.1", "DOMAIN\\Іван"), "full address:s:10.0.0.1\r\nusername:s:DOMAIN\\Іван\r\n")
        XCTAssertEqual(text("10.0.0.1", "a\npassword:s:x"), "full address:s:10.0.0.1\r\n", "логин не дописывает строки")
        XCTAssertNil(text(""))
        XCTAssertNil(text("10.0.0.1\npassword:s:x"), "адрес не дописывает строки")
        XCTAssertNil(text("a b"))
        XCTAssertEqual(RDPLink.fileName(for: "Вінницька · Філія 2"), "Вінницька___Філія_2.rdp")
        XCTAssertEqual(RDPLink.fileName(for: "../.."), "connection.rdp")
    }

    // MARK: «Как подключиться» и «Контакты» (последние правки пользователя)

    func testAccessParserFindsVPNAndRDP() {
        let info = AccessParser.parse("""
            VPN (WireGuard) | сервер: vpn.example.lan · логин: lab-7 · ключ: Demo-Key-77

            RDP — IP: 10.20.0.15 · порт 3390
            Server — логин: lims.admin · пароль: Demo-77-выдумка

            Login: operator
            """)
        XCTAssertEqual(info.vpn?.kind, "WireGuard")
        XCTAssertEqual(info.vpn?.server, "vpn.example.lan")
        XCTAssertEqual(info.vpn?.login, "lab-7")
        XCTAssertEqual(info.vpn?.secret, "Demo-Key-77")
        XCTAssertEqual(info.rdp?.address, "10.20.0.15:3390")
        XCTAssertEqual(info.rdp?.lines, ["RDP — IP: 10.20.0.15 · порт 3390"])

        let other = AccessParser.parse("FortiClient: 203.0.113.40, user ivan, password Demo-1\nRDP 192.0.2.7:3389")
        XCTAssertEqual(other.vpn?.kind, "FortiClient")
        XCTAssertEqual(other.vpn?.server, "203.0.113.40")
        XCTAssertEqual(other.vpn?.login, "ivan")
        XCTAssertEqual(other.vpn?.secret, "Demo-1")
        XCTAssertEqual(other.rdp?.address, "192.0.2.7:3389")

        let wg = AccessParser.parse("VPN WireGuard · server: 198.51.100.7 · key: QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=")
        XCTAssertEqual(wg.vpn?.secret, "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=", "«=» в конце ключа base64 сохраняется")
        XCTAssertEqual(AccessParser.parse("VPN · login = ivan").vpn?.login, "ivan", "разделитель «=» в начале срезается")

        let raw = AccessParser.parse("VPN — профиль у заведующего")
        XCTAssertNotNil(raw.vpn)
        XCTAssertNil(raw.vpn?.server)
        XCTAssertNil(raw.vpn?.secret)
        XCTAssertEqual(raw.vpn?.lines, ["VPN — профиль у заведующего"], "не разобралось — строки как есть")
        XCTAssertNil(raw.rdp)
        XCTAssertNil(AccessParser.parse("Телефон 050 000 00 00").vpn, "без VPN-строк — нет блока VPN")
    }

    func testPhonesInContacts() {
        XCTAssertEqual(ContactPhones.find(in: "Іван Петрович, +380 (50) 000-00-00; Оля 067 000 00 01"),
                       ["+380 (50) 000-00-00", "067 000 00 01"])
        XCTAssertEqual(ContactPhones.find(in: "каб. 12, 2 этаж"), [], "короткие числа — не телефоны")
    }

    /// «Контакты» — только по запросу (карточка), в записи — лишь признак.
    func testContactsReadOnDemand() throws {
        let source = XMLSource()
        let north = try source.load(file).records[0]
        XCTAssertTrue(north.hasContacts)
        XCTAssertFalse("\(north)".contains("050 000"))
        let c = try XCTUnwrap(source.lookupSecret(.contacts, for: north, in: file).secret)
        XCTAssertTrue(c.withBytes { $0.elementsEqual("Иван, 050 000 00 00".utf8) })
        c.wipe()
    }

    // MARK: Правка XML

    func testXMLEditorWritesAccountAndKeepsContactsAndAccess() throws {
        let records = try XMLSource().load(file).records
        let north = records[0]
        var draft = ConnectionDraft(north)
        XCTAssertEqual(draft.account, "Администратор")
        draft.account = "Оператор"
        draft.accountPassword = "Новый-Win-2"
        let out = try XMLConnectionsEditor.update(north, with: draft, in: file)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("<contacts>Иван, 050 000 00 00</contacts>"), "контакты — как были")
        XCTAssertTrue(text.contains(XMLConnectionsEditor.escape(access)), "«Доступ» соседней записи — байт в байт")
        let again = try XMLSource().load(out).records[0]
        XCTAssertEqual(again.account, "Оператор")
        let pw = try XCTUnwrap(XMLSource().lookupSecret(.accountPassword, for: again, in: out).secret)
        XCTAssertTrue(pw.withBytes { $0.elementsEqual("Новый-Win-2".utf8) })
        pw.wipe()

        // Новая запись VPN без ID — допустима.
        let vpn = ConnectionDraft(name: "Філія 3", group: "Вінницька", tags: "Рег, VPN", method: .vpn)
        XCTAssertEqual(vpn.problems, [])
        let added = try XMLConnectionsEditor.add(vpn, to: out)
        let last = try XCTUnwrap(XMLSource().load(added).records.last)
        XCTAssertEqual(last.method, .vpn)
        XCTAssertEqual(last.id, "")
        // Без программы ID по-прежнему обязателен.
        XCTAssertEqual(ConnectionDraft(name: "x").problems, [.invalidID])
    }
}
