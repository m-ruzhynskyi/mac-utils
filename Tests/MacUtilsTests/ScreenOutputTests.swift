import AppKit
import XCTest
@testable import MacUtils

/// Окна процесса тестов, которые сейчас на экране пользователя: видимые и пересекающие хоть один монитор.
/// Офскрин-рендер тестов (окна за экраном, x = −20 000) сюда не входит.
@MainActor
enum ScreenGuard {
    static func windowsOnScreen() -> [String] {
        let screens = NSScreen.screens.map(\.frame)
        return NSApplication.shared.windows
            .filter { window in window.isVisible && window.alphaValue > 0 && screens.contains { $0.intersects(window.frame) } }
            .map { "\(type(of: $0)) \($0.frame) «\($0.title)»" }
    }
}

/// Тесты не мешают пользователю: ни одно окно, панель или подсказка не выводится на экран, звука нет (ScreenOutput).
@MainActor
final class ScreenOutputTests: XCTestCase {
    override func tearDown() {
        XCTAssertEqual(ScreenGuard.windowsOnScreen(), [], "окна тестов на экране пользователя")
        super.tearDown()
    }

    func testTestProcessIsRecognised() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
    }

    /// Сторож на будущее: показать окно, активировать приложение или пискнуть можно только через ScreenOutput —
    /// иначе тест (и прилипание окон, редактор, тосты) снова вспыхивает и пищит на экране пользователя.
    func testNoDirectScreenOrSoundCallsInSources() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MacUtils")
        let forbidden = [".orderFrontRegardless()", ".makeKeyAndOrderFront(", ".orderFront(", "NSSound.beep()", "NSBeep()",
                         "NSApp.activate(", ".show(relativeTo:", "NSSound(named:"]
        var found: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "ScreenOutput.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                for call in forbidden where code.contains(call) {
                    // Поповер в строке меню показывается только после ScreenOutput.mayShow в той же строке условия.
                    if call == ".show(relativeTo:", lines[max(0, index - 3)...index].joined().contains("ScreenOutput.mayShow") { continue }
                    found.append("\(url.lastPathComponent):\(index + 1) \(call)")
                }
            }
        }
        XCTAssertEqual(found, [], "прямой показ или звук мимо ScreenOutput")
    }

    func testSnapPreviewIsModelOnlyUnderTests() {
        let preview = SnapPreview()
        let before = ScreenOutput.suppressedWindows
        let frame = NSRect(x: 100, y: 100, width: 400, height: 300)
        preview.show(frame)
        XCTAssertTrue(preview.isVisible, "показ виден в модели")
        XCTAssertEqual(preview.frame, frame.insetBy(dx: 4, dy: 4), "рамка панели — как на экране")
        XCTAssertEqual(ScreenOutput.suppressedWindows, before + 1, "показ на экран не состоялся")
        XCTAssertEqual(ScreenGuard.windowsOnScreen(), [])
        preview.flash(frame, duration: 0.01)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(preview.isVisible, "вспышка погасла")
        preview.hide()
    }

    func testToastAndBeepAreSilentUnderTests() {
        let windows = ScreenOutput.suppressedWindows, sounds = ScreenOutput.suppressedSounds
        Toast.show("Проверка", symbol: "checkmark")
        Feedback.beep()
        Feedback.play("Ping")
        ScreenOutput.activateApp()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThanOrEqual(ScreenOutput.suppressedWindows, windows + 2, "тост и активация")
        XCTAssertEqual(ScreenOutput.suppressedSounds, sounds + 2)
        XCTAssertEqual(ScreenGuard.windowsOnScreen(), [])
    }
}
