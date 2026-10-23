@testable import MacUtils
import MURemoteConnections
import SwiftUI
import XCTest

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
        <connection><name>Склад Харьков</name><id>345678901</id><password>x</password><group>Склады</group><app>AnyDesk</app></connection>
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

    private func render<V: View>(_ view: V, size: NSSize, name: String) {
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
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
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
        full.toggleFavorite(full.snapshot.records[0])
        full.toggleFavorite(full.snapshot.records[1])
        render(RemoteConnectionsPanel(center: full), size: panel, name: "rc01-panel")
        render(RemoteConnectionsPanel(center: full, query: "ctdth"), size: panel, name: "rc02-search-layout")
        render(RemoteConnectionsPanel(center: full, diagnosticsExpanded: true), size: panel, name: "rc03-diagnostics")
        render(RemoteConnectionsPanel(center: full, query: "пекарня"), size: panel, name: "rc04-nothing-found")
        let palette = RemoteListModel(center: full)
        palette.query = "север"
        render(RemotePaletteView(model: palette, close: {}), size: NSSize(width: 680, height: 470), name: "rc05-palette")
        render(RemoteConnectionsPanel(center: try await center(nil)), size: panel, name: "rc06-no-file")
        render(RemoteConnectionsPanel(center: try await center("<hosts/>")), size: panel, name: "rc07-corrupt")
        let columns = try await center("<connections/>", name: "c.xlsx")
        render(RemoteConnectionsPanel(center: columns), size: panel, name: "rc08-bad-xlsx")
    }
}
