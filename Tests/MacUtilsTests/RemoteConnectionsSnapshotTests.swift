@testable import MacUtils
import MURemoteConnections
import SwiftUI
import XCTest
import MUCore
import MUDesign
@testable import MUTextEditor

/// Вкладка «Удалённые» и палитра офскрин в PNG на выдуманных данных — для сверки с макетами m01…m11.
/// Без переменной окружения тест пропускается:  MU_RC_SNAPSHOTS=/папка swift test --filter RemoteConnectionsSnapshotTests
@MainActor
final class RemoteConnectionsSnapshotTests: XCTestCase {
    private var directory: URL!
    private var work: URL!
    private var suites: [String] = []

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["MU_RC_SNAPSHOTS"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_RC_SNAPSHOTS=<папка>")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        for s in suites { UserDefaults.standard.removePersistentDomain(forName: s) }
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private static let xml = """
        <connections>
        <connection><name>Лаборатория Север</name><id>123456789</id><password>x</password><group>Лаборатории</group><app>AnyDesk</app></connection>
        <connection><name>Лаборатория Восток</name><id>1234567890</id><password>x</password><group>Лаборатории</group><app>TeamViewer</app></connection>
        <connection><name>Север · резервный сервер</name><id>678901234</id><group>Лаборатории</group><app>AnyDesk</app></connection>
        <connection><name>Склад Харьков</name><id>345678901</id><password>x</password><group>Склады</group><tags>склад, ночь, сервер, касса</tags><note>Ключ у охраны, звонить заранее</note><app>AnyDesk</app></connection>
        <connection><name>Склад Одесса · выдача</name><id>1987654321</id><group>Склады</group><app>TeamViewer</app></connection>
        <connection><name>Касса 4 · Запад</name><id>kassa4@ad</id><password>x</password><group>Офисы</group></connection>
        <connection><name>Бухгалтерия</name><id>567890123</id><password>x</password><group>Офисы</group><app>TeamViewer</app></connection>
        <connection><name>Север (копия)</name><id>123456789</id><group>Лаборатории</group><app>AnyDesk</app></connection>
        <connection><name>Аптека</name><id>12345</id></connection>
        <connection><name>Пекарня</name><id>223456789</id><app>Anydesc</app></connection>
        </connections>
        """

    private func center(_ contents: String?, name: String = "connections.xml") async throws -> RemoteConnectionsCenter {
        let suite = "mu-rc-snap-\(UUID().uuidString)"
        suites.append(suite)
        let c = RemoteConnectionsCenter(defaults: UserDefaults(suiteName: suite)!)
        guard let contents else { return c }
        let url = work.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        c.setFile(url)
        let deadline = Date().addingTimeInterval(5)
        while c.state == .loading || c.state == .noFile, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        return c
    }

    /// Ждать — через `Task.sleep`: тест сам на главном акторе, вложенный RunLoop не дал бы отработать `.task` карточки.
    private func render<V: View>(_ view: V, size: NSSize, name: String, settle: TimeInterval = 0.3) async {
        for dark in [false, true] {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.dsBg)
                .environment(\.controlActiveState, .key))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
            window.contentView = nil
            window.close()
        }
    }

    func testScreens() async throws {
        let panel = NSSize(width: DS.Size.popover.width, height: 560)
        let full = try await center(Self.xml)
        let eastEntry = full.snapshot.records.first { $0.name == "Лаборатория Восток" }!
        full.toggleFavorite(full.snapshot.records[0])
        full.toggleFavorite(full.snapshot.records[1])
        await render(RemoteConnectionsPanel(center: full), size: panel, name: "rc01-panel")
        await render(RemoteConnectionsPanel(center: full, query: "ctdth"), size: panel, name: "rc02-search-layout")
        await render(RemoteSettingsPage(center: full), size: NSSize(width: 820, height: 1600), name: "rc03-diagnostics")
        await render(RemoteConnectionsPanel(center: full, query: "пекарня"), size: panel, name: "rc04-nothing-found")
        let palette = RemoteListModel(center: full)
        palette.query = "север"
        await render(RemotePaletteView(model: palette, close: {}), size: NSSize(width: 680, height: 470), name: "rc05-palette")
        await render(RemoteConnectionsPanel(center: try await center(nil)), size: panel, name: "rc06-no-file")
        await render(RemoteConnectionsPanel(center: try await center("<hosts/>")), size: panel, name: "rc07-corrupt")
        let columns = try await center("<connections/>", name: "c.xlsx")
        await render(RemoteConnectionsPanel(center: columns), size: panel, name: "rc08-bad-xlsx")

        // HUD подключения (m06/m07).
        let north = ConnectionRecord(sourceRow: 2, name: "Лаборатория Север", id: "123456789", hasPassword: true)
        let east = ConnectionRecord(sourceRow: 3, name: "Лаборатория Восток", id: "1234567890", program: .teamViewer, hasPassword: true)
        func cards(_ phases: [ConnectionPhase], _ program: RemoteProgram, _ record: ConnectionRecord) -> some View {
            VStack(spacing: 14) {
                ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                    RemoteHUDCard(content: .make(phase, program: program, record: record), program: program)
                }
            }
            .padding(24)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        let progress: [ConnectionPhase] = [.opening, .waiting(elapsed: 7, timeout: 20), .entered, .finished(.connected),
                                           .finished(.connectedWithoutPassword)]
        await render(cards(progress, .anyDesk, north), size: NSSize(width: 460, height: 640), name: "rc09-hud-anydesk")
        let failures: [ConnectionFailure] = [.noAccessibility, .notInstalled, .fieldNotFound(structure: []), .wrongPassword,
                                             .focusLost, .entryGone]
        await render(cards(failures.map { .finished(.failed($0)) }, .anyDesk, north), size: NSSize(width: 460, height: 900),
               name: "rc10-hud-errors-anydesk")
        await render(cards([.finished(.failed(.wrongPassword)), .finished(.failed(.programNotSpecified))], .teamViewer, east),
               size: NSSize(width: 460, height: 330), name: "rc11-hud-errors-teamviewer")
        await render(RemoteHUDCard(content: .make(.finished(.failed(.fieldNotFound(structure: ["AXWindow", "  AXGroup", "    AXStaticText", "  AXButton"]))),
                                            program: .anyDesk, record: north), program: .anyDesk, showStructure: true)
                .padding(24).frame(maxHeight: .infinity, alignment: .top),
               size: NSSize(width: 460, height: 300), name: "rc12-hud-structure")

        // A-4: настройки (m15), правка и добавление (m16/m17), вкладка на украинском и английском.
        await render(RemoteSettingsPage(center: full), size: NSSize(width: 820, height: 1500), name: "rc13-settings")
        await render(RemoteEditSheet(center: full, record: eastEntry), size: NSSize(width: 480, height: 640), name: "rc14-edit")
        await render(RemoteEditSheet(center: full, record: nil), size: NSSize(width: 480, height: 600), name: "rc15-add")
        let book = try await center(nil)
        book.setFile(work.appendingPathComponent("connections.xlsx"))
        await render(RemoteEditSheet(center: book, record: eastEntry), size: NSSize(width: 480, height: 640), name: "rc19-view-xlsx")
        // Задачи 3–5: метки, VPN/RDP, учётка, подробности (макет .audit/rc-tags-design).
        let labs = try await center("""
            <connections>
            <connection><name>Північна лабораторія</name><id>123456789</id><password>x</password><group>Північ</group><tags>Рег</tags><note>Звонить перед подключением, работают до 17:00</note><account>Администратор</account><accountPassword>y</accountPassword><app>AnyDesk</app></connection>
            <connection><name>Східна · AnyDesk</name><id>987654321</id><password>x</password><group>Схід</group><tags>Рег, Фито, VPN</tags><note>Сначала WireGuard — профиль в «Доступ»</note><access>VPN (WireGuard) | профиль Схід-1</access><app>AnyDesk</app></connection>
            <connection><name>Приморська · сервер</name><id>10.20.0.15</id><group>Південь</group><tags>Фито, Сервер, VPN, RDP</tags><note>RDP только после VPN. Если не пускает — звонить заведующему, работают до 17:00.</note><account>lims.admin</account><accountPassword>y</accountPassword><access>VPN (WireGuard) | сервер: vpn.example.lan · логин: lab-7 · ключ: demo-key

            RDP — IP: 10.20.0.15
            Server — логин: lims.admin · пароль: demo

            Login: operator</access><contacts>Заведующая Ольга, +380 (50) 000-00-00</contacts><app>RDP</app></connection>
            <connection><name>Лісова</name><id>1234567890</id><password>x</password><group>Південь</group><tags>Рег, Фито, Сервер, ЛІМС</tags><note>Два компьютера: бухгалтерия и лаборатория — второй ID в «Доступ»</note><account>Администратор</account><app>TeamViewer</app></connection>
            <connection><name>Озерна</name><id></id><group>Південь</group><tags>Рег</tags><note>Только по телефону, контакты в «Доступ»</note><app>Другое</app></connection>
            </connections>
            """, name: "labs.xml")
        await render(RemoteConnectionsPanel(center: labs), size: panel, name: "rc20-panel-labels")
        labs.detailsRecord = labs.snapshot.records.first { $0.name == "Приморська · сервер" }
        await render(RemoteConnectionsPanel(center: labs), size: panel, name: "rc21-details")
        labs.detailsRecord = nil

        // Карточка v2 (task-rc-card-v2, макеты Details и Accounts): шаги из блоков «Доступа», учётки, контакты внизу.
        let v2 = try await center("""
            <connections>
            <connection><name>Тестова · Лабораторія</name><id></id><group>Тестова</group><tags>Рег, VPN, RDP</tags><account>Администратор</account><accountPassword>demo-Win-1</accountPassword><access>VPN — подключение средствами Windows, тип L2TP с общим ключом. Если первый сервер не отвечает — второй
            IP1: 203.0.113.10 · основной адрес
            IP2: 203.0.113.11 · запасной адрес
            L2tpPsk: demo-Psk-10
            login: lims
            pass: demo-Vpn-7731

            RDP
            IP: 10.20.0.15:3389
            login: lims
            pass: demo-Rdp-13

            Router
            pass: demo-Rtr-8</access><contacts>Іваненко Олена
            Заступник директора
            вірусологічного відділу
            050 000 00 01

            Адміністратор мережі</contacts><app>RDP</app></connection>
            <connection><name>Демо · Філія (RDP, три входа)</name><id>1234567890</id><password>demo-AD</password><group>Демо</group><tags>Рег, RDP</tags><access>Філія · адрес demo-lab.example.net · Логин: operator · Пароль: demo-Op1-11
            Логин: operator2 · Пароль: demo-Op2-58
            Логин: lab.manager · Пароль: demo-Mgr-33
            RDP — demo-lab.example.net</access><contacts>Заступник директора
            вірусологічного відділу</contacts><app>AnyDesk</app></connection>
            </connections>
            """, name: "v2.xml")
        for (name, file) in [("Тестова · Лабораторія", "rc22-card-v2-steps"), ("Демо · Філія (RDP, три входа)", "rc23-card-v2-accounts")] {
            let record = v2.snapshot.records.first { $0.name == name }!
            await render(RemoteDetailsView(record: record, center: v2, onBack: {}).padding(16), size: NSSize(width: 460, height: 1300), name: file,
                   settle: 1.5)
        }

        defer { RemoteL10n.language = .ru }
        for language in [RemoteLanguage.uk, .en] {
            RemoteL10n.language = language
            await render(RemoteConnectionsPanel(center: full), size: panel, name: "rc16-panel-\(language.rawValue)")
            await render(cards(failures.map { .finished(.failed($0)) }, .anyDesk, north), size: NSSize(width: 460, height: 900),
                   name: "rc17-hud-\(language.rawValue)")
            await render(RemoteSettingsPage(center: full), size: NSSize(width: 820, height: 1500), name: "rc18-settings-\(language.rawValue)")
        }
    }
}
