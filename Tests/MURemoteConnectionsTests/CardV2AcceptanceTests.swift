import XCTest
@testable import MURemoteConnections

/// Приёмка карточки подключения v2 (.audit/task-rc-card-v2.md), независимые от разработчика проверки.
/// Формы строк — по .audit/rc-access-shapes.txt, сами данные выдуманные (IP из диапазонов документации).
final class CardV2AcceptanceTests: XCTestCase {
    private func rec(_ row: Int = 2, method: ConnectionMethod? = nil, program: RemoteProgram? = nil, id: String = "111222333",
                     tags: [String] = [], account: String = "") -> ConnectionRecord {
        ConnectionRecord(sourceRow: row, name: "Демо \(row)", id: id, tags: tags, program: program, method: method,
                         account: account, hasAccountPassword: !account.isEmpty)
    }

    private func flat(_ a: [ConnectionCard.Account]) -> [String] {
        a.map { "\($0.kind.rawValue)|\($0.login ?? "—")|\($0.password ?? "—")" }
    }

    // MARK: 2. Шаги и учётные записи по формам «Доступа»

    /// Форма row 24: L2TP с IP1/IP2/PSK, затем RDP с логином, затем Router без логина.
    func testShapeL2TPWithIP1IP2PSKThenRDPThenRouter() throws {
        let access = """
            VPN — подключение средствами Windows, тип L2TP с общим ключом
            IP1: 198.51.100.10 · основной адрес для туннеля L2tp
            IP2: 198.51.100.11 · запасной адрес для туннеля L2tp
            L2tpPsk: Demo-Psk-001
            login: demo.vpn
            pass: Demo-VpnPass-1

            RDP
            IP: 10.9.8.7
            login: demo.rdp
            pass: Demo-RdpPass-2

            Router
            pass: Demo-RouterPass-3
            """
        let card = AccessParser.card(record: rec(method: .rdp, id: "", tags: ["Рег", "VPN", "RDP"]), access: access, accountPassword: nil)
        let vpn = try XCTUnwrap(card.vpn)
        XCTAssertEqual(vpn.kind, "L2TP/IPsec")
        XCTAssertEqual(vpn.server, "198.51.100.10")
        XCTAssertEqual(vpn.backupServer, "198.51.100.11", "IP2 — запасной сервер")
        XCTAssertEqual(vpn.key, "Demo-Psk-001", "L2tpPsk — общий ключ")
        XCTAssertEqual(vpn.login, "demo.vpn")
        XCTAssertEqual(vpn.password, "Demo-VpnPass-1")
        XCTAssertNotNil(vpn.note, "длинное пояснение показывается как «Из файла»")
        let rdp = try XCTUnwrap(card.rdp)
        XCTAssertEqual(rdp.address, "10.9.8.7")
        XCTAssertEqual(rdp.login, "demo.rdp")
        XCTAssertEqual(rdp.password, "Demo-RdpPass-2")
        XCTAssertEqual(card.stepCount, 2, "VPN — шаг 1, RDP — шаг 2")
        XCTAssertEqual(flat(card.accounts), ["router|—|Demo-RouterPass-3"],
                       "пары из шагов VPN и RDP повторно не выводятся; у Router логин не указан")
    }

    /// Пояснение в строке VPN — проза: слова «адрес», «сервер», «пароль» в ней не должны давать сервер, логин или пароль.
    func testVPNProseSentenceNeverBecomesServerOrSecret() {
        let prose = [
            "VPN — подключение средствами Windows, тип L2TP с общим ключом, при недоступности первого адреса второй",
            "VPN — если сервер не отвечает, используйте запасной",
            "VPN — адрес сервера уточните у администратора",
            "VPN — логин и пароль как для почты",
        ]
        for line in prose {
            let text = line + "\nIP1: 198.51.100.10\nlogin: demo.vpn\npass: Demo-Vpn-1"
            let vpn = AccessParser.card(record: rec(method: .vpn, id: "", tags: ["VPN"]), access: text, accountPassword: nil).vpn
            XCTAssertEqual(vpn?.server, "198.51.100.10", "сервер — из IP1, а не слово из пояснения: \(line)")
            XCTAssertEqual(vpn?.login, "demo.vpn", line)
            XCTAssertEqual(vpn?.password, "Demo-Vpn-1", line)
        }
    }

    /// Router: блок без логина — пара с пустым логином, подпись «Роутер», пароль на месте.
    func testRouterBlockWithoutLogin() {
        let card = AccessParser.card(record: rec(), access: "Router\npass: Demo-R-5", accountPassword: nil)
        XCTAssertNil(card.vpn)
        XCTAssertNil(card.rdp)
        XCTAssertEqual(card.accounts.count, 1)
        XCTAssertEqual(card.accounts[0].kind, .router)
        XCTAssertNil(card.accounts[0].login, "нет логина — «не указан»")
        XCTAssertEqual(card.accounts[0].password, "Demo-R-5")
        // Заголовок Router по-русски.
        let ru = AccessParser.card(record: rec(), access: "Роутер\nпароль: Demo-R-6", accountPassword: nil)
        XCTAssertEqual(flat(ru.accounts), ["router|—|Demo-R-6"])
    }

    /// Форма row 40: RDP-запись и три пары «Логин/Пароль» — все три в «Учётные записи», в шаге RDP своей пары нет.
    func testRDPWithThreeLoginPasswordPairs() throws {
        let access = """
            Лаборатория · Адрес основной / резервный 192.0.2.40 · Логин: oper.one · Пароль: Demo-One-1
            Логин: oper.two · Пароль: Demo-Two-2
            Логин: oper.three · Пароль: Demo-Three-3
            """
        let card = AccessParser.card(record: rec(method: .rdp, id: "192.0.2.40", tags: ["Рег", "RDP"]), access: access, accountPassword: nil)
        let rdp = try XCTUnwrap(card.rdp)
        XCTAssertEqual(rdp.address, "192.0.2.40")
        XCTAssertNil(rdp.login, "из трёх пар шаг не выбирает одну")
        XCTAssertNil(rdp.password)
        XCTAssertTrue(rdp.useAccountsBelow, "«Войдите одной из учёток ниже»")
        XCTAssertEqual(flat(card.accounts), ["windows|oper.one|Demo-One-1", "windows|oper.two|Demo-Two-2", "windows|oper.three|Demo-Three-3"])
        XCTAssertEqual(card.stepCount, 1)
    }

    /// «Учётка Server — …»: учётка из колонок получает подпись Server, а не Windows.
    func testServerAccountLineLabelsColumnAccountAsServer() {
        let access = "Учётка Server — логин: Администратор · пароль: Demo-Srv-9\nRDP — IP: 10.1.1.1"
        let card = AccessParser.card(record: rec(method: .rdp, id: "", account: "Администратор"), access: access, accountPassword: "Demo-Srv-9")
        XCTAssertEqual(card.accounts.map(\.kind), [.server], "та же пара в колонках и в «Доступе» — одна учётка Server")
        XCTAssertEqual(card.accounts.first?.login, "Администратор")
        XCTAssertEqual(card.accounts.first?.password, "Demo-Srv-9")
        XCTAssertEqual(card.accounts.first?.source, .columns)
        // Без такой строки колонка — обычная учётка Windows.
        let plain = AccessParser.card(record: rec(account: "Администратор"), access: "AnyDesk: 123", accountPassword: "Demo-W-1")
        XCTAssertEqual(flat(plain.accounts), ["windows|Администратор|Demo-W-1"])
    }

    /// Все формы пар из п. 2.3 ТЗ в одном «Доступе»: пары из блоков без заголовка — учётки Windows, все найдены.
    func testAllLoginPasswordFormsFromSpec() {
        let forms: [(String, String, String)] = [
            ("login: alpha / pass: Demo-A-1", "alpha", "Demo-A-1"),
            ("Логин: beta · Пароль: Demo-B-2", "beta", "Demo-B-2"),
            ("User: gamma\nPassword: Demo-C-3", "gamma", "Demo-C-3"),
            ("delta — Demo-D-4", "delta", "Demo-D-4"),
        ]
        for (text, login, pass) in forms {
            let card = AccessParser.card(record: rec(), access: text, accountPassword: nil)
            XCTAssertEqual(flat(card.accounts), ["windows|\(login)|\(pass)"], "форма: \(text.replacingOccurrences(of: "\n", with: "⏎"))")
        }
    }

    /// Нет пары в колонках и «Доступе» — ничего не выдумывается.
    func testNothingInventedWhenFileHasNothing() {
        let empty = AccessParser.card(record: rec(), access: nil, accountPassword: nil)
        XCTAssertNil(empty.vpn)
        XCTAssertNil(empty.rdp)
        XCTAssertTrue(empty.accounts.isEmpty)
        XCTAssertEqual(empty.stepCount, 0)
        // Строки программы без меток не превращаются в учётки.
        let programs = AccessParser.card(record: rec(), access: "AnyDesk: 987 654 321\nLOCAL IP: 10.0.0.9", accountPassword: nil)
        XCTAssertNil(programs.vpn)
        XCTAssertNil(programs.rdp)
        XCTAssertTrue(programs.accounts.isEmpty)
        // Логин без пароля: пароля в карточке нет.
        let loginOnly = AccessParser.card(record: rec(), access: "Логин: only.login", accountPassword: nil)
        XCTAssertEqual(loginOnly.accounts.first?.password, nil)
    }

    /// В «Доступе · как в файле» пароли под маской, логины и прочее видны.
    func testAccessTextMaskHidesSecretsOnly() {
        let masked = AccessParser.mask("login: demo · pass: Demo-Visible-1 · L2tpPsk: Demo-Psk-2\nпароль: Demo-Ru-3")
        XCTAssertFalse(masked.contains("Demo-Visible-1"))
        XCTAssertFalse(masked.contains("Demo-Psk-2"))
        XCTAssertFalse(masked.contains("Demo-Ru-3"))
        XCTAssertTrue(masked.contains("login: demo"))
        XCTAssertTrue(masked.contains("••••"))
    }

    // MARK: 1. Фильтр: программы и «Другое»

    func testFilterOtherHoldsRDPVPNAndOther() {
        let records = [
            rec(2, program: .anyDesk, id: "111"),
            rec(3, program: .teamViewer, id: "222"),
            rec(4, method: .rdp, id: "10.0.0.4", tags: ["RDP"]),
            rec(5, method: .vpn, id: "10.0.0.5", tags: ["VPN"]),
            rec(6, method: .other, id: ""),
            rec(7, program: .teamViewer, id: "333", tags: ["Рег", "VPN"]),
        ]
        func list(_ f: ProgramFilter) -> ConnectionListing {
            ConnectionListBuilder.build(search: ConnectionSearch(records), query: "", filter: f, defaultProgram: .anyDesk,
                                        favorites: [], recents: [])
        }
        func rows(_ f: ProgramFilter) -> [Int] { list(f).rows.map(\.record.sourceRow).sorted() }
        XCTAssertEqual(rows(.all), [2, 3, 4, 5, 6, 7])
        XCTAssertEqual(rows(.program(.anyDesk)), [2])
        XCTAssertEqual(rows(.program(.teamViewer)), [3, 7], "TeamViewer с меткой VPN остаётся в TeamViewer")
        XCTAssertEqual(rows(.other), [4, 5, 6], "RDP, VPN и «Другое» — в «Другое»")
        let counts = list(.all).counts
        XCTAssertEqual(counts[.all], 6)
        XCTAssertEqual(counts[.other], 3)
        XCTAssertEqual(counts[.program(.anyDesk)], 1)
        XCTAssertEqual(counts[.program(.teamViewer)], 2)
    }

    /// Старых фильтров RDP и VPN больше нет: в типе только «Все», программа и «Другое».
    func testNoSeparateRDPVPNFilterCases() {
        let all: [ProgramFilter] = [.all, .program(.anyDesk), .program(.teamViewer), .other]
        XCTAssertEqual(Set(all).count, 4)
        // Значки в строке остаются: метки VPN/RDP — бейджи, а не метки-фильтры.
        let r = rec(4, method: .rdp, id: "10.0.0.4", tags: ["Рег", "VPN", "RDP"])
        XCTAssertEqual(r.labels.map(ConnectionTag.key), ["рег"], "бейджи VPN/RDP не попадают в строку «МЕТКИ»")
        XCTAssertTrue(r.needsVPN, "значок VPN остаётся по метке")
    }

    /// ТЗ: «записи без программы попадают в „Другое“». Запись без программы и без способа берёт программу по умолчанию
    /// из настроек. Проверка фиксирует фактическое поведение и расхождение с формулировкой ТЗ.
    func testRecordWithoutProgramFollowsDefaultProgram() {
        let r = rec(8, id: "444")
        let listing = ConnectionListBuilder.build(search: ConnectionSearch([r]), query: "", filter: .other, defaultProgram: .anyDesk,
                                                  favorites: [], recents: [])
        XCTAssertEqual(listing.rows.count, 0, "сейчас запись без программы идёт в программу по умолчанию, а не в «Другое»")
    }

    // MARK: 3. Показ пароля на 10 секунд

    func testRevealLastsTenSecondsThenHides() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var reveal = SecretReveal()
        XCTAssertEqual(SecretReveal.seconds, 10)
        XCTAssertFalse(reveal.isShown("vpn.password", now: t0), "по умолчанию скрыт")
        XCTAssertTrue(reveal.toggle("vpn.password", now: t0))
        XCTAssertTrue(reveal.isShown("vpn.password", now: t0.addingTimeInterval(9.9)))
        XCTAssertEqual(reveal.remaining("vpn.password", now: t0.addingTimeInterval(3)), 7)
        XCTAssertFalse(reveal.isShown("vpn.password", now: t0.addingTimeInterval(10)), "ровно через 10 с — скрыт")
        XCTAssertNil(reveal.remaining("vpn.password", now: t0.addingTimeInterval(10.5)))
        XCTAssertEqual(reveal.expire(now: t0.addingTimeInterval(10.5)), ["vpn.password"], "истёкшие ключи отдаются на затирание")
        XCTAssertTrue(reveal.isEmpty)
    }

    func testRevealSecondTapHidesImmediatelyAndKeysAreIndependent() {
        let t0 = Date(timeIntervalSinceReferenceDate: 5000)
        var reveal = SecretReveal()
        reveal.toggle("account.0", now: t0)
        reveal.toggle("account.1", now: t0.addingTimeInterval(4))
        XCTAssertFalse(reveal.toggle("account.0", now: t0.addingTimeInterval(5)), "повторное нажатие скрывает сразу")
        XCTAssertFalse(reveal.isShown("account.0", now: t0.addingTimeInterval(5)))
        XCTAssertTrue(reveal.isShown("account.1", now: t0.addingTimeInterval(5)))
        XCTAssertFalse(reveal.isShown("account.1", now: t0.addingTimeInterval(14.1)), "срок account.1 считается от его нажатия")
        reveal.toggle("password", now: t0)
        reveal.hideAll()
        XCTAssertTrue(reveal.isEmpty, "закрытие карточки скрывает всё")
    }

    // MARK: 4. Нормализация номера

    func testPhoneNormalization() {
        let ok: [(String, String)] = [
            ("050 000 00 01", "+380500000001"),
            ("(050) 000-00-01", "+380500000001"),
            ("050-000-00-01", "+380500000001"),
            ("0500000001", "+380500000001"),
            ("+380 50 000 00 01", "+380500000001"),
            ("+38 (050) 000 00 01", "+380500000001"),
            ("380500000001", "+380500000001"),
            ("80500000001", "+380500000001"),
            ("  067 000 00 02 ", "+380670000002"),
            ("\u{00A0}093\u{00A0}000\u{00A0}00\u{00A0}03", "+380930000003"),
        ]
        for (raw, want) in ok {
            XCTAssertEqual(PhoneNumber.dialable(raw), want, raw)
            XCTAssertEqual(PhoneNumber.telURL(raw)?.absoluteString, "tel:" + want, raw)
        }
        for raw in ["", "   ", "каб. 12", "12-34", "abc", "05000"] {
            XCTAssertNil(PhoneNumber.dialable(raw), "«\(raw)» не номер")
            XCTAssertNil(PhoneNumber.telURL(raw))
        }
        XCTAssertEqual(PhoneNumber.dialable("+48 123 456 789"), "+48123456789", "чужой код страны с «+» не переписывается на +380")
    }

    // MARK: 4. Звонок: план (UniTalk есть / нет)

    func testCallPlanOnlyThroughUniTalkOrCopy() {
        XCTAssertEqual(PhoneCall.uniTalkBundleID, "com.unitalk.desktop")
        XCTAssertEqual(PhoneCall.plan("050 000 00 01", uniTalkInstalled: true), .call(URL(string: "tel:+380500000001")!))
        XCTAssertEqual(PhoneCall.plan("050 000 00 01", uniTalkInstalled: false), .copy("050 000 00 01", reason: .noUniTalk),
                       "нет UniTalk — копирование номера как есть")
        XCTAssertEqual(PhoneCall.plan("каб. 12", uniTalkInstalled: true), .copy("каб. 12", reason: .notANumber),
                       "не номер не звонится, даже при UniTalk")
        XCTAssertEqual(PhoneCall.plan(" 050 000 00 01 ", uniTalkInstalled: false), .copy("050 000 00 01", reason: .noUniTalk))
    }

    // MARK: 2.6 Контакты

    func testContactsMultilinePositionJoinedAndNoPhoneCase() {
        let text = """
            Заступник директора
            вірусологічного відділу
            Демо Іван Петрович
            050 000 00 01, 067 000 00 02

            Секретар
            Демо Марія
            """
        let contacts = ContactsParser.parse(text)
        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(contacts[0].title, "Заступник директора вірусологічного відділу", "должность склеена в одну строку")
        XCTAssertEqual(contacts[0].phones, ["050 000 00 01", "067 000 00 02"])
        XCTAssertTrue(contacts[1].phones.isEmpty, "нет телефона — карточка пишет «Телефона в файле нет»")
        XCTAssertEqual(contacts[1].title, "Секретар")
    }
}
