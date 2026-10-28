import AppKit
import ApplicationServices
import XCTest
@testable import MacUtils
@testable import MUDesign
@testable import MUWindowSnap

/// Стенд прилипания окон (1.6.8 на macOS 27: «по клавишам работает, перетаскиванием — нет и нет подсказки»).
/// Своё окно в отдельном процессе (Tests/Stands/WindowSnapStand.swift); перетаскивание ведём точками в WindowTiler,
/// окно стенда двигаем через AX — курсор и мышь пользователя не участвуют, экран не снимается.
/// Запуск: `MACUTILS_STAND=1 swift test --filter WindowSnapStandTests` (нужен Accessibility у терминала).
@MainActor
final class WindowSnapStandTests: XCTestCase {
    private var stand: Process?
    private var standInput: Pipe?

    override func tearDown() {
        stand?.terminate()
        stand = nil
        standInput = nil
        super.tearDown()
    }

    func testDragByLowerPartOfTallToolbarShowsPreviewAndSnaps() throws {
        let (window, start, bar) = try launchStand()
        let tiler = WindowTiler.shared
        XCTAssertGreaterThan(bar, 40, "полоса объединённой панели выше прежнего предела")

        // Нажатие в нижней части панели — 1.6.8 его отбрасывал (40 pt).
        tiler.handleMouse(.down, at: CGPoint(x: start.minX + 150, y: start.minY + bar - 6))
        try wait("нажатие принято") { tiler.dragWindow != nil }
        try requireStandWindow()

        let screen = NSScreen.screens[0]
        let area = WindowTiler.axRect(fromCocoa: screen.frame)
        let edge = CGPoint(x: area.minX + 1, y: area.midY)
        WindowTiler.setFrame(start.offsetBy(dx: -120, dy: 30), of: window)
        try drag(to: edge, "окно тащат, зона — левая половина") { tiler.dragMoving && tiler.dragTarget == .left }
        let expected = WindowTiler.frame(for: .left, on: screen, window: start)
        try assertPreview(at: expected)

        // Курсор ушёл от края — подсказки нет.
        try drag(to: CGPoint(x: area.midX, y: area.midY), "от края — без зоны") { tiler.dragTarget == nil && !tiler.preview.isVisible }
        try wait("подсказка снята", timeout: 1) { !tiler.preview.isVisible }

        // Прижат к верхнему краю (в Cocoa y == maxY) — весь экран.
        try drag(to: CGPoint(x: area.midX, y: area.minY), "у верхнего края — весь экран") { tiler.dragTarget == .maximize }
        try drag(to: edge, "снова левый край") { tiler.dragTarget == .left }

        tiler.handleMouse(.up, at: edge)
        XCTAssertFalse(tiler.preview.isVisible)
        try wait("окно встало на левую половину") { WindowTiler.frame(of: window).map { close($0, expected) } == true }
    }

    func testDragOnSecondMonitorSnapsToItsFreeEdge() throws {
        guard NSScreen.screens.count > 1 else { throw XCTSkip("один монитор") }
        let (window, _, bar) = try launchStand()
        let tiler = WindowTiler.shared
        let screen = NSScreen.screens[1]
        let frames = NSScreen.screens.map(\.frame)
        let visible = WindowTiler.axRect(fromCocoa: screen.visibleFrame)
        let start = CGRect(x: visible.minX + 80, y: visible.minY + 60, width: min(560, visible.width - 160), height: 320)
        WindowTiler.setFrame(start, of: window)
        try wait("окно стенда на втором мониторе") { WindowTiler.frame(of: window).map { close($0, start) } == true }
        // Сразу после переноса стенд ещё раскладывает окно на новом месте: попадание AX там — kAXErrorNoValue.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Свободный край второго монитора: общий с соседним краем не считается.
        let area = WindowTiler.axRect(fromCocoa: screen.frame)
        let candidates = [CGPoint(x: area.maxX - 1, y: area.midY), CGPoint(x: area.minX, y: area.midY), CGPoint(x: area.midX, y: area.minY)]
        let shared = CGPoint(x: area.minX, y: area.midY)
        guard let point = candidates.first(where: { WindowTiler.zone(for: WindowTiler.cocoaPoint(fromAX: $0), in: screen.frame, screens: frames) != nil }),
              let target = WindowTiler.zone(for: WindowTiler.cocoaPoint(fromAX: point), in: screen.frame, screens: frames) else {
            return XCTFail("у второго монитора нет свободного края")
        }

        let press = CGPoint(x: start.minX + 150, y: start.minY + bar / 2)
        tiler.handleMouse(.down, at: press)
        try wait("нажатие принято") { tiler.dragWindow != nil }
        try requireStandWindow()
        WindowTiler.setFrame(start.offsetBy(dx: 40, dy: 20), of: window)
        try drag(to: point, "зона на втором мониторе") { tiler.dragMoving && tiler.dragTarget == target }
        let expected = WindowTiler.frame(for: target, on: screen, window: start)
        try assertPreview(at: expected)
        if WindowDragRules.sharedEdges(of: screen.frame, at: WindowTiler.cocoaPoint(fromAX: shared), screens: frames).left {
            try drag(to: shared, "общий край мониторов — не край") { tiler.dragTarget == nil }
            try drag(to: point, "обратно к свободному краю") { tiler.dragTarget == target }
        }
        tiler.handleMouse(.up, at: point)
        try wait("окно встало на втором мониторе") { WindowTiler.frame(of: window).map { close($0, expected) } == true }
    }

    /// Клавиши: окно встаёт сразу, рамка вспыхивает ≈0,25 с и гаснет. Окно стенда передаём сами — активное окно
    /// пользователя тест не трогает.
    func testHotKeySnapFlashesTargetFrame() throws {
        let (window, start, _) = try launchStand()
        let tiler = WindowTiler.shared
        let screen = NSScreen.screens[0]
        let expected = WindowTiler.frame(for: .right, on: screen, window: start)
        tiler.perform(.snap(.right), on: window)
        XCTAssertTrue(tiler.preview.isVisible, "вспышка рамки")
        try assertPreview(at: expected)
        try wait("вспышка погасла", timeout: 1) { !tiler.preview.isVisible }
        try wait("окно на правой половине") { WindowTiler.frame(of: window).map { close($0, expected) } == true }
        tiler.perform(.restore, on: window)
        try wait("прежний размер") { WindowTiler.frame(of: window).map { close($0, start) } == true }
    }

    // MARK: - Стенд

    private func launchStand() throws -> (AXUIElement, CGRect, CGFloat) {
        guard ProcessInfo.processInfo.environment["MACUTILS_STAND"] == "1" else { throw XCTSkip("стенд: MACUTILS_STAND=1") }
        guard AXIsProcessTrusted() else { throw XCTSkip("нужен Accessibility") }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Stands/WindowSnapStand.swift")
        let binary = FileManager.default.temporaryDirectory.appendingPathComponent("macutils-window-snap-stand")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.arguments = ["swiftc", "-O", source.path, "-o", binary.path]
        try build.run()
        build.waitUntilExit()
        XCTAssertEqual(build.terminationStatus, 0, "стенд собран")

        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = binary
        process.standardOutput = output
        process.standardInput = input
        try process.run()
        stand = process
        standInput = input
        var line = ""
        let deadline = Date().addingTimeInterval(10)
        while !line.contains("\n"), Date() < deadline {
            line += String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        }
        func number(_ key: String) -> CGFloat? {
            (line.split(separator: " ").first { $0.hasPrefix(key + "=") }).flatMap { Double($0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)) }.map { CGFloat($0) }
        }
        guard let pid = number("pid"), let x = number("x"), let y = number("y"), let w = number("w"), let h = number("h"),
              let bar = number("bar") else { throw XCTSkip("стенд не ответил") }
        let app = AXUIElementCreateApplication(pid_t(pid))
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard let window = (value as? [AXUIElement])?.first else { throw XCTSkip("окно стенда не видно через AX") }
        let frame = CGRect(x: x, y: y, width: w, height: h)
        XCTAssertEqual(WindowTiler.frame(of: window), frame)
        return (window, frame, bar)
    }

    // MARK: - Помощники

    /// Нажатие взяло окно стенда, а не чужое окно над ним: иначе отпускаем кнопку без движения (раскладки нет) и стоп.
    private func requireStandWindow() throws {
        let tiler = WindowTiler.shared
        guard tiler.dragWindow?.pid == stand?.processIdentifier else {
            tiler.handleMouse(.up, at: .zero)
            throw XCTSkip("окно стенда перекрыто другим окном")
        }
    }

    private func wait(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("не дождались: \(what)") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Перетаскивание идёт событиями: шлём точку, пока условие не выполнится (проверка рамки — раз в 50 мс).
    private func drag(to point: CGPoint, _ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            WindowTiler.shared.handleMouse(.dragged, at: point)
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            if condition() { return }
        } while Date() < deadline
        let tiler = WindowTiler.shared
        XCTFail("не дождались: \(what) (moving=\(tiler.dragMoving) target=\(String(describing: tiler.dragTarget)) window=\(tiler.dragWindow != nil))")
    }

    /// Подсказка на экране (по WindowServer) и там, где встанет окно (с отступом 4 pt).
    /// Подсказка показана в нужной рамке. Проверяется модель и рамка панели, а не экран: под тестами панель на экран
    /// пользователя не выводится (ScreenOutput), и у WindowServer её нет.
    private func assertPreview(at frame: CGRect, file: StaticString = #filePath, line: UInt = #line) throws {
        let preview = WindowTiler.shared.preview
        let expected = frame.insetBy(dx: 4, dy: 4)
        XCTAssertTrue(preview.isVisible, "подсказка показана", file: file, line: line)
        let shown = try XCTUnwrap(preview.frame, "панели подсказки нет", file: file, line: line)
        XCTAssertTrue(close(shown, expected), "подсказка \(shown) вместо \(expected)", file: file, line: line)
        XCTAssertFalse(onscreen(preview.windowNumber), "подсказка не выводится на экран пользователя", file: file, line: line)
    }

    private func onscreen(_ number: Int?) -> Bool {
        guard let number else { return false }
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]] ?? []
        return info.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
