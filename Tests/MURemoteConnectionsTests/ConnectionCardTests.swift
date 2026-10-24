import XCTest
@testable import MURemoteConnections

/// Карточка подключения v2 (.audit/task-rc-card-v2.md): шаги из блоков «Доступа», учётные записи, контакты, номер для
/// звонка, показ пароля на 10 с. Формы строк — как в .audit/rc-access-shapes.txt; сами данные выдуманные.
final class ConnectionCardTests: XCTestCase {
    private func record(method: ConnectionMethod? = nil, program: RemoteProgram? = nil, id: String = "123456789",
                        tags: [String] = [], account: String = "") -> ConnectionRecord {
        ConnectionRecord(sourceRow: 2, name: "Демо", id: id, tags: tags, program: program, method: method, account: account,
                         hasAccountPassword: !account.isEmpty)
    }

    private func pairs(_ accounts: [ConnectionCard.Account]) -> [String] {
        accounts.map { "\($0.kind.rawValue):\($0.login ?? "—")/\($0.password ?? "—")" }
    }

    // MARK: Шаги

    /// Форма row 24: L2TP с IP1/IP2/L2tpPsk, затем блоки RDP и Router.
    func testL2TPWithBackupServerAndKeyThenRDPAndRouter() {
        let access = """
            VPN — подключение средствами Windows, тип L2TP с общим ключом. Если первый сервер не отвечает — второй
            IP1: 203.0.113.10 · основной адрес для подключения через L2tp туннель
            IP2: 203.0.113.11 · запасной адрес для подключения через L2tp туннель
            L2tpPsk: Demo-Psk-10
            login: lims
            pass: demo-Vpn-7731

            RDP
            IP: 10.20.0.15
            login: lims
            pass: Demo-Rdp-13

            Router
            pass: Demo-Rtr-8
            """
        let card = AccessParser.card(record: record(method: .rdp, id: "", tags: ["Рег", "VPN", "RDP"], account: "Администратор"),
                                     access: access, accountPassword: "Demo-Win-1")
        let vpn = try! XCTUnwrap(card.vpn)
        XCTAssertEqual(vpn.kind, "L2TP/IPsec")
        XCTAssertEqual(vpn.server, "203.0.113.10")
        XCTAssertEqual(vpn.backupServer, "203.0.113.11")
        XCTAssertEqual(vpn.key, "Demo-Psk-10")
        XCTAssertEqual(vpn.login, "lims")
        XCTAssertEqual(vpn.password, "demo-Vpn-7731")
        XCTAssertEqual(vpn.note, "подключение средствами Windows, тип L2TP с общим ключом. Если первый сервер не отвечает — второй",
                       "длинная строка-пояснение — «Из файла»")
        XCTAssertEqual(card.rdp, ConnectionCard.RDP(address: "10.20.0.15", login: "lims", password: "Demo-Rdp-13"))
        XCTAssertEqual(card.stepCount, 2)
        XCTAssertEqual(pairs(card.accounts), ["windows:Администратор/Demo-Win-1", "router:—/Demo-Rtr-8"],
                       "пары из шагов VPN/RDP повторно не выводятся; у роутера логин не указан")
        XCTAssertEqual(card.accounts.map(\.source), [.columns, .access])
    }

    /// Форма row 40: RDP-запись, несколько «Логин · Пароль» без заголовка — все в «Учётные записи», шаг — только адрес.
    func testRDPWithSeveralLoginPasswordPairs() {
        let access = """
            Філія · Адрес основний / резервний сервер 192.0.2.40 через шлюз · Логин: operator · Пароль: Demo-Op1-11
            Логин: operator2 · Пароль: demo-Op2-58
            Логин: lab.manager · Пароль: Demo-Mgr-33
            """
        let card = AccessParser.card(record: record(method: .rdp, id: "demo-lab.example.net", tags: ["RDP"]), access: access,
                                     accountPassword: nil)
        XCTAssertNil(card.vpn)
        XCTAssertEqual(card.rdp?.address, "demo-lab.example.net", "адрес RDP-записи — её ID")
        XCTAssertNil(card.rdp?.login)
        XCTAssertEqual(card.rdp?.useAccountsBelow, true)
        XCTAssertEqual(pairs(card.accounts), ["windows:operator/Demo-Op1-11", "windows:operator2/demo-Op2-58",
                                              "windows:lab.manager/Demo-Mgr-33"])
    }

    /// Форма row 36: блок RDP с описанием, адресами отдельными строками, «User:» и «Password: X · …».
    func testRDPBlockWithUserAndPasswordAndTrailingWords() {
        let access = """
            RDP до сервера через основной канал — адрес 10.0.36.1
            Запасной канал RDP через другой порт IP:
            10.0.36.2
            User: Admin
            Password: Demo-Pw-36 · после · смены

            Бухгалтерия-2
            Окно-обслуживания
            """
        let card = AccessParser.card(record: record(program: .anyDesk, tags: ["RDP"]), access: access, accountPassword: nil)
        XCTAssertEqual(card.rdp, ConnectionCard.RDP(address: "10.0.36.1", login: "Admin", password: "Demo-Pw-36"))
        XCTAssertEqual(card.accounts, [], "одиночные слова без меток — не учётки")
    }

    /// Формы row 2 и row 9: FortiClient с «логин — пароль»; «<имя> — VPN PPTP · IP:» с Login/Password; «Роутер — VPN…» — тоже VPN.
    func testFortiClientAndPPTP() {
        let forti = AccessParser.card(record: record(method: .rdp, id: "", tags: ["VPN", "RDP"]), access: """
            FortiClient — шлюз · demo-gw
            vpnuser — Demo-Fc-12
            RDP — IP: 10.0.2.5
            """, accountPassword: nil)
        XCTAssertEqual(forti.vpn?.kind, "FortiClient")
        XCTAssertEqual(forti.vpn?.login, "vpnuser")
        XCTAssertEqual(forti.vpn?.password, "Demo-Fc-12")
        XCTAssertNil(forti.vpn?.server, "одно слово без метки — не сервер")
        XCTAssertEqual(forti.rdp?.address, "10.0.2.5")

        for first in ["Шлюз-1", "Роутер"] {
            let pptp = AccessParser.card(record: record(method: .vpn, id: "", tags: ["VPN"]), access: """
                \(first) — VPN PPTP · IP: 198.51.100.9
                Login: admin
                Password: Demo-Pptp-10
                Компьютер — IP: 10.0.0.9
                """, accountPassword: nil)
            XCTAssertEqual(pptp.vpn?.kind, "PPTP", first)
            XCTAssertEqual(pptp.vpn?.server, "198.51.100.9", first)
            XCTAssertEqual(pptp.vpn?.login, "admin", first)
            XCTAssertEqual(pptp.vpn?.password, "Demo-Pptp-10", first)
            XCTAssertNil(pptp.rdp)
            XCTAssertEqual(pptp.accounts, [], first)
        }
    }

    /// Форма row 34: «VPN — <IP> · пояснение», затем «логин — пароль · PPTP · пояснение».
    func testVPNHeaderWithAddressAndNoteThenDashPair() {
        let card = AccessParser.card(record: record(program: .anyDesk, tags: ["VPN", "RDP"]), access: """
            VPN — 203.0.113.34 · подключение средствами Windows через встроенный клиент
            vpn34 — Demo-V34 · PPTP · шифрование обязательно для этого подключения
            RDP — 10.0.34.2
            """, accountPassword: nil)
        XCTAssertEqual(card.vpn?.server, "203.0.113.34")
        XCTAssertEqual(card.vpn?.kind, "PPTP")
        XCTAssertEqual(card.vpn?.login, "vpn34")
        XCTAssertEqual(card.vpn?.password, "Demo-V34")
        XCTAssertEqual(card.vpn?.note, "подключение средствами Windows через встроенный клиент")
        XCTAssertEqual(card.rdp?.address, "10.0.34.2")
    }

    /// Формы row 25 и row 30: многострочное пояснение VPN, «IP: IP: <IP>», логин и пароль; «логін і пароль …» — не пара.
    func testMultilineVPNNoteAndRepeatedLabel() {
        let card = AccessParser.card(record: record(program: .anyDesk, tags: ["VPN"]), access: """
            AnyDesk: 123 456 789 пароль у заведующего

            Для входа в VPN использовать встроенный клиент Windows с типом подключения
            протокол туннеля выбирается автоматически при первом входе
            Login: lab25
            Password: Demo-V25
            IP: IP: 198.51.100.25
            логін і пароль такі ж як на сервер

            Администратор
            Demo-Adm-8
            """, accountPassword: nil)
        XCTAssertEqual(card.vpn?.server, "198.51.100.25")
        XCTAssertEqual(card.vpn?.login, "lab25")
        XCTAssertEqual(card.vpn?.password, "Demo-V25")
        XCTAssertEqual(card.vpn?.note, "Для входа в VPN использовать встроенный клиент Windows с типом подключения "
                       + "протокол туннеля выбирается автоматически при первом входе логін і пароль ••••••",
                       "пояснение — под маской: после «пароль» могло быть значение")
        XCTAssertNil(card.vpn?.kind, "тип в файле не назван — не выдумываем")
        XCTAssertEqual(card.accounts, [], "строки AnyDesk и два слова в столбик — не учётки")
        XCTAssertNil(card.rdp)
    }

    /// Учётка Server (row 2/10…): строка «Учётка Server — …» помечает учётку из колонок как Server; такая же пара в блоке
    /// Server (row 22) не повторяется.
    func testServerAccountLine() {
        let access = """
            Учётка Server — логин и пароль в колонках «Учётная запись» и «Пароль учётной записи»
            Server — логин: Администратор · пароль: Demo-Srv-8

            RDP — IP: 10.0.22.1
            """
        let card = AccessParser.card(record: record(program: .teamViewer, tags: ["RDP"], account: "Администратор"), access: access,
                                     accountPassword: "Demo-Srv-8")
        XCTAssertEqual(pairs(card.accounts), ["server:Администратор/Demo-Srv-8"])
        XCTAssertEqual(card.rdp?.address, "10.0.22.1")
        XCTAssertNil(card.rdp?.login)
        XCTAssertEqual(card.rdp?.useAccountsBelow, false, "одна учётка — без подсказки «одной из учёток»")

        let other = AccessParser.card(record: record(program: .teamViewer, account: "Администратор"),
                                      access: "Server — логин: Администратор · пароль: Demo-Other-1", accountPassword: "Demo-Win-2")
        XCTAssertEqual(pairs(other.accounts), ["windows:Администратор/Demo-Win-2", "server:Администратор/Demo-Other-1"])
    }

    /// Router без логина: и блоком, и одной строкой «Router / pass: Y»; «<логин> — <пароль>» и пароль отдельным блоком.
    func testRouterAndGenericPairs() {
        let card = AccessParser.card(record: record(program: .teamViewer, tags: ["RDP"]), access: """
            Router / pass: Demo-R1

            Администратор — Demo-Adm-15

            rdp — 10.0.31.1

            Lims

            пароль: Demo-P31
            """, accountPassword: nil)
        XCTAssertEqual(pairs(card.accounts), ["router:—/Demo-R1", "windows:Администратор/Demo-Adm-15", "windows:—/Demo-P31"])
        XCTAssertEqual(card.rdp?.address, "10.0.31.1")
        XCTAssertEqual(card.rdp?.useAccountsBelow, true)
    }

    /// Чего нет в файле — нет в карточке.
    func testNothingInvented() {
        let anyDesk = AccessParser.card(record: record(program: .anyDesk), access: """
            AnyDesk: 123 456 789
            LOCAL IP: 10.1.1.1
            IP: 10.1.1.2 · касса на втором этаже
            """, accountPassword: nil)
        XCTAssertEqual(anyDesk, ConnectionCard(), "без меток VPN/RDP и без блоков — ни шагов, ни учёток")

        let bare = AccessParser.card(record: record(program: .teamViewer, tags: ["VPN", "RDP"]), access: "VPN включено\nRDP\nServer",
                                     accountPassword: nil)
        XCTAssertEqual(bare.vpn?.isEmpty, true, "шаг VPN есть (метка), но пустой — окно напишет, что подробностей нет")
        XCTAssertNil(bare.rdp?.address)
        XCTAssertEqual(bare.accounts, [])

        let column = AccessParser.card(record: record(program: .anyDesk, account: "kassa"), access: nil, accountPassword: nil)
        XCTAssertEqual(pairs(column.accounts), ["windows:kassa/—"], "пароля учётки нет — только логин")
        XCTAssertNil(column.vpn)
        XCTAssertNil(column.rdp)

        let port = AccessParser.card(record: record(program: .anyDesk, tags: ["RDP"]), access: "RDP — IP: 10.20.0.15 · порт 3390",
                                     accountPassword: nil)
        XCTAssertEqual(port.rdp?.address, "10.20.0.15:3390")
    }

    // MARK: Контакты и звонок

    func testContactsJoinMultilinePositionAndPickPhones() {
        let contacts = ContactsParser.parse("""
            Іваненко Олена
            Заступник директора
            вірусологічного відділу
            050 000 00 01

            Адміністратор мережі

            Ольга (бухгалтерия) +38 (044) 000-00-00
            Дежурный: 067 000 11 22, каб. 12
            Склад 050 000 00 02, 050 000 00 03
            """)
        XCTAssertEqual(contacts, [
            ConnectionContact(title: "Іваненко Олена", detail: "Заступник директора вірусологічного відділу", phones: ["050 000 00 01"]),
            ConnectionContact(title: "Адміністратор мережі"),
            ConnectionContact(title: "Ольга (бухгалтерия)", phones: ["+38 (044) 000-00-00"]),
            ConnectionContact(title: "Дежурный", detail: "каб. 12", phones: ["067 000 11 22"]),
            ConnectionContact(title: "Склад", phones: ["050 000 00 02", "050 000 00 03"]),
        ])
        XCTAssertEqual(ContactsParser.parse("Заступник директора\nвірусологічного відділу"),
                       [ConnectionContact(title: "Заступник директора вірусологічного відділу")])
        XCTAssertEqual(ContactsParser.phones(in: "каб. 12, 2 этаж, 23.10.2026"), [], "короткие числа и даты — не телефоны")
    }

    func testPhoneNormalization() {
        let cases: [(String, String?)] = [
            ("050 000 00 01", "+380500000001"), ("+38 (044) 000-00-00", "+380440000000"), ("380670001122", "+380670001122"),
            ("8 050 000 00 01", "+380500000001"), ("500000001", "+380500000001"), ("+48 600 000 000", "+48600000000"),
            ("12-34", nil), ("0500000", nil), ("050 000 00 0123", nil),
        ]
        for (raw, want) in cases { XCTAssertEqual(PhoneNumber.dialable(raw), want, raw) }
        XCTAssertEqual(PhoneNumber.telURL("050 000 00 01")?.absoluteString, "tel:+380500000001")
    }

    func testCallPlanUsesUniTalkOrCopies() {
        XCTAssertEqual(PhoneCall.plan("050 000 00 01", uniTalkInstalled: true), .call(URL(string: "tel:+380500000001")!))
        XCTAssertEqual(PhoneCall.plan(" 050 000 00 01 ", uniTalkInstalled: false), .copy("050 000 00 01", reason: .noUniTalk))
        XCTAssertEqual(PhoneCall.plan("каб. 12-34", uniTalkInstalled: true), .copy("каб. 12-34", reason: .notANumber))
        XCTAssertEqual(PhoneCall.uniTalkBundleID, "com.unitalk.desktop")
    }

    // MARK: Показ на 10 секунд

    func testRevealHidesAfterTenSecondsOrOnSecondTap() {
        var reveal = SecretReveal()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(reveal.toggle("vpn.password", now: t0))
        XCTAssertEqual(reveal.remaining("vpn.password", now: t0), 10)
        XCTAssertEqual(reveal.remaining("vpn.password", now: t0.addingTimeInterval(2.2)), 8, "«скроется через 8 с»")
        XCTAssertEqual(reveal.expire(now: t0.addingTimeInterval(9.9)), [])
        XCTAssertTrue(reveal.isShown("vpn.password", now: t0.addingTimeInterval(9.9)))
        XCTAssertEqual(reveal.expire(now: t0.addingTimeInterval(10)), ["vpn.password"], "через 10 с скрывается сам")
        XCTAssertNil(reveal.remaining("vpn.password", now: t0.addingTimeInterval(10)))
        XCTAssertTrue(reveal.isEmpty)

        XCTAssertTrue(reveal.toggle("a", now: t0))
        XCTAssertTrue(reveal.toggle("b", now: t0.addingTimeInterval(5)))
        XCTAssertFalse(reveal.toggle("a", now: t0.addingTimeInterval(6)), "повторное нажатие — скрыть сразу")
        XCTAssertFalse(reveal.isShown("a", now: t0.addingTimeInterval(6)))
        XCTAssertEqual(reveal.remaining("b", now: t0.addingTimeInterval(6)), 9)
        XCTAssertEqual(reveal.expire(now: t0.addingTimeInterval(15)), ["b"])
        XCTAssertTrue(reveal.toggle("a", now: t0.addingTimeInterval(16)), "после истечения — снова показать")
        reveal.hideAll()
        XCTAssertTrue(reveal.isEmpty)
    }
}
