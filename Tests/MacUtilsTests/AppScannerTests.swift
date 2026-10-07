import XCTest
@testable import MacUtils

@MainActor
final class AppScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeApp(_ name: String, bundleID: String) throws -> InstalledApp {
        let url = root.appendingPathComponent("Apps/\(name).app/Contents")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(InstalledApp(url: root.appendingPathComponent("Apps/\(name).app")))
    }

    private func touch(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func testMatchesExactBundleIDAndNameOnly() throws {
        let app = try makeApp("TestApp", bundleID: "com.example.testapp")
        let support = root.appendingPathComponent("Support").path
        let prefs = root.appendingPathComponent("Prefs").path
        // Совпадения.
        try touch("Support/com.example.testapp/data")
        try touch("Support/TestApp/data")
        try touch("Prefs/com.example.testapp.plist")
        // Приманки: не должны совпасть.
        try touch("Support/com.example.testappX/data")
        try touch("Support/com.example/data")
        try touch("Support/Test/data")
        try touch("Prefs/com.example.other.plist")
        try touch("Prefs/TestApp.plist")

        let locations = [
            AppScanner.Location(path: support, group: "Данные", byName: true),
            AppScanner.Location(path: prefs, group: "Настройки"),
        ]
        let found = Set(AppScanner.scan(app, others: [app], locations: locations)
            .filter { $0.kind == .file }
            .map { $0.url.path.replacingOccurrences(of: root.path + "/", with: "") })
        XCTAssertEqual(found, ["Support/com.example.testapp", "Support/TestApp", "Prefs/com.example.testapp.plist"])
    }

    func testSkipsOtherAppWithLongerBundleID() throws {
        let app = try makeApp("Browser", bundleID: "com.example.browser")
        let canary = try makeApp("Browser Canary", bundleID: "com.example.browser.canary")
        try touch("Caches/com.example.browser/x")
        try touch("Caches/com.example.browser.canary/x")
        try touch("Caches/com.example.browser.helper/x")
        let locations = [AppScanner.Location(path: root.appendingPathComponent("Caches").path, group: "Кэш")]
        let found = Set(AppScanner.scan(app, others: [app, canary], locations: locations)
            .filter { $0.kind == .file }
            .map(\.url.lastPathComponent))
        XCTAssertEqual(found, ["com.example.browser", "com.example.browser.helper"])
    }

    func testAppItselfIsFirstAndRefusals() throws {
        let app = try makeApp("TestApp", bundleID: "com.example.testapp")
        let items = AppScanner.scan(app, others: [app], locations: [])
        XCTAssertEqual(items.first?.kind, .app)
        XCTAssertNil(app.refusal)
        let apple = try makeApp("Notes", bundleID: "com.apple.Notes")
        XCTAssertNotNil(apple.refusal)
    }
}
