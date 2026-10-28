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

    // MARK: Ревью v2 (.audit/review-rc-card-v2.md)

    /// FIX 1: «Доступ · как в файле» — ни одного пароля открыто. Формы row 2, 3, 10, 11/17, 12/27, 21, 25/35, 34, 36–38.
    func testShownAccessHidesEveryPassword() {
        let access = """
            Учётка Server — логин и пароль в колонках
            FortiClient — шлюз · demo-gw
            vpnuser — Demo-Fc-12
            lims — Demo-Lims-12
            Перевірка доступу на сервері — Администратор · Demo-Tail-11
            RDP — 10.0.11.1 · LIMS · Demo-Rdp-17
            Администратор — Demo-Adm-15
            vpn34 — Demo-V34 · PPTP · шифрование обязательно для этого подключения
            User: Admin
            Password: Demo-Pw-36 · Demo-Pw2-8 · Demo-Pw3-10
            pass: ab;cd-Demo
            Пароль: Demo, with comma

            Администратор
            Demo-Col-8
            IP: 10.0.0.9 · кабинет 12
            """
        let record = record(program: .anyDesk, tags: ["VPN", "RDP"], account: "Администратор")
        let card = AccessParser.card(record: record, access: access, accountPassword: "Demo-Win-1")
        let shown = AccessParser.masked(access + "\nAnyDesk пароль подключения как в колонке: Demo-ID-9 \nкопия Demo-Win-1",
                                        secrets: card.secrets + ["Demo-ID-9"])
        for secret in ["Demo-Fc-12", "Demo-Lims-12", "Demo-Tail-11", "Demo-Rdp-17", "Demo-Adm-15", "Demo-V34", "Demo-Pw-36", "Demo-Pw2-8",
                       "Demo-Pw3-10", "ab;cd", "cd-Demo", "with comma", "Demo-Col-8", "Demo-ID-9", "Demo-Win-1"] {
            XCTAssertFalse(shown.contains(secret), "в показе «Доступа» открыто: \(secret)")
        }
        // Что паролем не является — остаётся: заголовки, адреса, логины в метках, пояснения.
        for kept in ["Учётка Server", "FortiClient", "RDP — 10.0.11.1", "User: Admin", "IP: 10.0.0.9 · кабинет 12", "PPTP",
                     "vpnuser — ••••••"] {
            XCTAssertTrue(shown.contains(kept), "должно остаться: \(kept)")
        }
        XCTAssertEqual(AccessParser.masked("a\r\nb c\r\n", secrets: []), "••••••\r\nb c\r\n", "переводы строк — как в файле")
        XCTAssertEqual(AccessParser.masked("Demo-X1x · Demo-X1xx", secrets: ["Demo-X1x"]), "•••••• · ••••••",
                       "значение — отдельным словом; одиночное слово после «·» — тоже под маской")
    }

    /// FIX 2: «слово — слово» не придумывает учётку: row 39, модель, телефон, ID.
    func testDashPairDoesNotInventAccounts() {
        for text in ["Справка — 0501234567 · ночь · 123456789", "Принтер — HP", "Телефон — 0501234567", "Склад — касса",
                     "Каса — 1234567890"] {
            XCTAssertEqual(AccessParser.card(record: record(program: .anyDesk), access: text, accountPassword: nil).accounts, [], text)
        }
        XCTAssertEqual(pairs(AccessParser.card(record: record(program: .anyDesk), access: "delta — Demo-D-4", accountPassword: nil).accounts),
                       ["windows:delta/Demo-D-4"])
        let vpn = AccessParser.card(record: record(program: .anyDesk, tags: ["VPN"]), access: "VPN PPTP\nshort — Ab1\nТелефон — 050 123 45 67",
                                    accountPassword: nil).vpn
        XCTAssertEqual([vpn?.login, vpn?.password], ["short", "Ab1"], "в блоке VPN пара без строгих условий, но номер — не пароль")
    }

    /// FIX 3: пароль и ключ — целиком до «·»/«|» или конца строки; срезается только разделитель после метки.
    func testPasswordValueIsNotCut() {
        let cases: [(String, String)] = [
            ("pass: ab;cd", "ab;cd"), ("Пароль: ab, cd", "ab, cd"), ("пароль: -Qw1", "-Qw1"), ("password = =Qw2=", "=Qw2="),
            ("Password: Demo-12 · после · смены", "Demo-12"), ("пароль — a / b", "a / b"), ("pass:Qw:3", "Qw:3"),
        ]
        for (text, want) in cases {
            XCTAssertEqual(AccessParser.card(record: record(program: .anyDesk), access: text, accountPassword: nil).accounts.first?.password,
                           want, text)
        }
        let key = AccessParser.card(record: record(program: .anyDesk, tags: ["VPN"]), access: "VPN L2TP\nL2tpPsk: k;e,y / 1", accountPassword: nil)
        XCTAssertEqual(key.vpn?.key, "k;e,y / 1")
        XCTAssertEqual(pairs(AccessParser.card(record: record(program: .anyDesk), access: "login: alpha / pass: Demo-A-1", accountPassword: nil).accounts),
                       ["windows:alpha/Demo-A-1"], "логин до « / », пароль после")
    }

    /// Тестер, п. 8: сервер — только хост; явная метка сильнее найденного в прозе.
    func testServerIsHostAndExplicitLabelWins() {
        let prose = AccessParser.card(record: record(method: .vpn, id: "", tags: ["VPN"]), access: "VPN — сервер: второй\nIP2: запасной", accountPassword: nil)
        XCTAssertNil(prose.vpn?.server)
        XCTAssertNil(prose.vpn?.backupServer)
        let explicit = AccessParser.card(record: record(method: .vpn, id: "", tags: ["VPN"]),
                                         access: "VPN — 203.0.113.1 · подключение через встроенный клиент Windows\nСервер: 203.0.113.2", accountPassword: nil)
        XCTAssertEqual(explicit.vpn?.server, "203.0.113.2", "«Сервер:» сильнее адреса из строки-заголовка")
    }

    /// Ревью п. 5: «Войдите одной из учёток ниже» — только про учётки Windows/Server.
    func testUseAccountsBelowCountsOnlyComputerAccounts() {
        let one = AccessParser.card(record: record(program: .anyDesk, tags: ["RDP"], account: "Администратор"),
                                    access: "RDP — 10.0.0.5\n\nRouter\npass: Demo-R-1", accountPassword: "Demo-W-1")
        XCTAssertEqual(one.accounts.count, 2)
        XCTAssertEqual(one.rdp?.useAccountsBelow, false, "одна учётка Windows и роутер — подсказка не нужна")
    }

    /// Ревью, мелочи: «+380» — ровно 12 цифр; «00380…» — как «+380…».
    func testPhoneEdgeCases() {
        XCTAssertNil(PhoneNumber.dialable("+380 50 000 00 01 1"))
        XCTAssertNil(PhoneNumber.dialable("3805000000011"))
        XCTAssertEqual(PhoneNumber.dialable("00380 50 000 00 01"), "+380500000001")
        XCTAssertEqual(PhoneNumber.dialable("0048 600 000 000"), "+48600000000")
    }

    // MARK: Повторное ревью (.audit/review-rc-card-v2b.md)

    /// Row 13: одно слово сразу после заголовка блока — под маской, как «RDP — «17»». Строки AnyDesk не трогаются.
    func testLoneWordAfterBlockHeaderIsMasked() {
        let cases: [(String, String)] = [
            ("VPN Qw3rty-13", "VPN ••••••"), ("RDP Demo17", "RDP ••••••"), ("Router Demo-R", "Router ••••••"),
            ("Server Srv-1", "Server ••••••"), ("FortiClient fc-pass", "FortiClient ••••••"), ("L2TP l2", "L2TP ••••••"),
            ("PPTP pp9", "PPTP ••••••"), ("RDP — Demo-17", "RDP — ••••••"),
            ("VPN WireGuard", "VPN WireGuard"), ("RDP 10.0.13.1", "RDP 10.0.13.1"), ("VPN включено сегодня", "VPN включено сегодня"),
            ("AnyDesk: 123456789 demo-pc office", "AnyDesk: 123456789 demo-pc office"), ("AnyDesk demo-pc", "AnyDesk demo-pc"),
        ]
        for (line, want) in cases { XCTAssertEqual(AccessParser.masked(line, secrets: []), want, line) }
        let shown = AccessParser.masked("VPN Demo-Name-11\nRDP — 10.0.13.2", secrets: [])
        XCTAssertFalse(shown.contains("Demo-Name-11"))
        XCTAssertTrue(shown.contains("RDP — 10.0.13.2"))
    }

    /// Ведущий «-» — часть значения: под маской и он.
    func testLeadingDashOfPasswordIsMasked() {
        let cases: [(String, String)] = [
            ("пароль: -Qw1", "пароль: ••••••"), ("pass -Qw2", "pass ••••••"), ("password = -=Qw3", "password = ••••••"),
            ("L2tpPsk=-k1", "L2tpPsk=••••••"), ("пароль — -Qw4", "пароль — ••••••"), ("pwd:Demo-7", "pwd:••••••"),
            ("RDP — пароль:", "RDP — пароль:"), ("с общим ключом. Если", "с общим ключом. Если"),
        ]
        for (line, want) in cases {
            XCTAssertEqual(AccessParser.mask(line), want, line)
            XCTAssertFalse(AccessParser.masked(line, secrets: []).contains("Qw"), line)
        }
    }
}
