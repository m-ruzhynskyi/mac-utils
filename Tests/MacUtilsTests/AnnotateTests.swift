import AppKit
import XCTest
@testable import MacUtils
@testable import MUAudio
@testable import MUAnnotate

/// Рисование на экране: чистая логика (хранилище штрихов, план оверлеев по экранам, режим «сквозь клики», снимок с рисунком).
final class AnnotateTests: XCTestCase {
    private func stroke(_ display: CGDirectDisplayID, tool: ScreenAnnotator.Tool = .arrow, born: Date = Date(),
                        _ points: [NSPoint] = [NSPoint(x: 10, y: 10), NSPoint(x: 40, y: 40)]) -> AnnotationStroke {
        AnnotationStroke(display: display, tool: tool, color: .systemRed, points: points, born: born)
    }

    // MARK: Хранилище

    func testUndoRemovesTheLastStrokeAcrossScreens() {
        var store = AnnotationStore()
        store.add(stroke(1)); store.add(stroke(2)); store.add(stroke(1))
        XCTAssertEqual(store.undo()?.display, 1)
        XCTAssertEqual(store.undo()?.display, 2, "отмена идёт в порядке рисования, а не по экранам")
        XCTAssertEqual(store.strokes.count, 1)
        XCTAssertNotNil(store.undo())
        XCTAssertNil(store.undo(), "пусто — ничего не падает")
        XCTAssertTrue(store.isEmpty)
    }

    func testStrokesAreSeparatedByScreen() {
        var store = AnnotationStore()
        store.add(stroke(1)); store.add(stroke(2)); store.add(stroke(2))
        XCTAssertEqual(store.strokes(on: 1).count, 1)
        XCTAssertEqual(store.strokes(on: 2).count, 2)
        XCTAssertTrue(store.strokes(on: 3).isEmpty)
    }

    func testClearRemovesEverythingEverywhere() {
        var store = AnnotationStore()
        store.add(stroke(1)); store.add(stroke(2))
        store.clear()
        XCTAssertTrue(store.isEmpty)
    }

    func testDroppedScreenForgetsOnlyItsStrokes() {
        var store = AnnotationStore()
        store.add(stroke(1)); store.add(stroke(2)); store.add(stroke(3))
        store.drop(displays: [2, 3])
        XCTAssertEqual(store.strokes.map(\.display), [1])
        store.drop(displays: [])
        XCTAssertEqual(store.strokes.count, 1)
    }

    func testAlphaCurve() {
        XCTAssertEqual(AnnotationStore.alpha(age: 100, fading: false), 1, "без затухания штрихи остаются")
        XCTAssertEqual(AnnotationStore.alpha(age: 0, fading: true), 1)
        XCTAssertEqual(AnnotationStore.alpha(age: 2.99, fading: true), 1)
        XCTAssertEqual(AnnotationStore.alpha(age: 3.3, fading: true), 0.5, accuracy: 0.001)
        XCTAssertEqual(AnnotationStore.alpha(age: 3.6, fading: true), 0, accuracy: 0.001)
        XCTAssertEqual(AnnotationStore.alpha(age: 50, fading: true), 0)
    }

    func testExpiredStrokesAreRemovedOnlyAfterFullFade() {
        var store = AnnotationStore()
        let now = Date()
        store.add(stroke(1, born: now.addingTimeInterval(-10)))
        store.add(stroke(1, born: now.addingTimeInterval(-3.3)))
        store.add(stroke(2, born: now))
        XCTAssertTrue(store.removeExpired(now: now))
        XCTAssertEqual(store.strokes.count, 2, "угасающий (3.3 с) ещё виден")
        XCTAssertFalse(store.removeExpired(now: now), "второй вызов ничего не меняет")
        XCTAssertTrue(store.removeExpired(now: now.addingTimeInterval(4)))
        XCTAssertTrue(store.isEmpty)
    }

    // MARK: Экраны

    private let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

    func testPlanFirstStartAddsEveryScreen() {
        let plan = AnnotationScreens.plan(existing: [:], current: [1: primary, 2: external])
        XCTAssertEqual(plan, .init(add: [1, 2], remove: [], resize: [], keep: []))
    }

    func testPlanNothingChanged() {
        let plan = AnnotationScreens.plan(existing: [1: primary, 2: external], current: [1: primary, 2: external])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.keep, [1, 2])
    }

    func testPlanMonitorPluggedIn() {
        let plan = AnnotationScreens.plan(existing: [1: primary], current: [1: primary, 2: external])
        XCTAssertEqual(plan.add, [2])
        XCTAssertEqual(plan.keep, [1], "рисунок на встроенном экране не пропадает")
        XCTAssertTrue(plan.remove.isEmpty)
    }

    func testPlanMonitorUnplugged() {
        let plan = AnnotationScreens.plan(existing: [1: primary, 2: external], current: [1: primary])
        XCTAssertEqual(plan.remove, [2])
        XCTAssertEqual(plan.keep, [1])
        XCTAssertFalse(plan.isEmpty)
    }

    func testPlanResolutionOrArrangementChange() {
        let moved = external.offsetBy(dx: -1512, dy: 0)
        let plan = AnnotationScreens.plan(existing: [1: primary, 2: external], current: [1: primary, 2: moved])
        XCTAssertEqual(plan.resize, [2])
        XCTAssertEqual(plan.keep, [1])
        let scaled = AnnotationScreens.plan(existing: [1: primary], current: [1: CGRect(x: 0, y: 0, width: 1920, height: 1080)])
        XCTAssertEqual(scaled.resize, [1])
    }

    func testPlanSwapOfMonitorsAtOnce() {
        let plan = AnnotationScreens.plan(existing: [2: external], current: [3: external])
        XCTAssertEqual(plan.add, [3])
        XCTAssertEqual(plan.remove, [2], "другой монитор с той же рамкой — другой экран")
    }

    func testPlanAllScreensGone() {
        let plan = AnnotationScreens.plan(existing: [1: primary], current: [:])
        XCTAssertEqual(plan.remove, [1])
        XCTAssertTrue(plan.add.isEmpty)
    }

    // MARK: Сквозь клики

    func testClickThroughModeAndOptionInversion() {
        XCTAssertFalse(AnnotationMode.ignoresMouse(clickThrough: false, optionHeld: false), "обычный режим — клики на холст")
        XCTAssertTrue(AnnotationMode.ignoresMouse(clickThrough: true, optionHeld: false), "сквозь клики — мышь у программ")
        XCTAssertTrue(AnnotationMode.ignoresMouse(clickThrough: false, optionHeld: true), "⌥ при рисовании — кликнуть сквозь холст")
        XCTAssertFalse(AnnotationMode.ignoresMouse(clickThrough: true, optionHeld: true), "⌥ в режиме «сквозь клики» — порисовать")
    }

    // MARK: Снимок с рисунком

    private func white(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }

    func testComposeKeepsBaseSizeAndDrawsStrokeOnRetinaScale() throws {
        // Экран 50×30 pt, кадр 100×60 px (Retina ×2). Рамка в точках (10,10)–(30,20), линия 4 pt.
        let base = white(100, 60)
        let rect = stroke(1, tool: .rectangle, [NSPoint(x: 10, y: 10), NSPoint(x: 30, y: 20)])
        let image = try XCTUnwrap(AnnotationRenderer.compose(base: base, strokes: [(rect, 1)], pointSize: CGSize(width: 50, height: 30)))
        XCTAssertEqual([image.width, image.height], [100, 60])
        let edge = pixel(image, 20, 30)   // левая сторона рамки: x = 10 pt → 20 px, середина по высоте: y = 15 pt от низа → 30 px сверху
        XCTAssertGreaterThan(edge.redComponent, 0.7)
        XCTAssertLessThan(edge.greenComponent, 0.35, "линия красная")
        let outside = pixel(image, 90, 5)
        XCTAssertGreaterThan(outside.redComponent + outside.greenComponent + outside.blueComponent, 2.9, "вне рисунка кадр не тронут")
        let inside = pixel(image, 40, 30)
        XCTAssertGreaterThan(inside.greenComponent, 0.9, "внутри рамки кадр не закрашен")
    }

    func testComposeWithoutStrokesReturnsTheSamePicture() throws {
        let image = try XCTUnwrap(AnnotationRenderer.compose(base: white(40, 20), strokes: [], pointSize: CGSize(width: 40, height: 20)))
        for (x, y) in [(0, 0), (39, 19), (20, 10)] {
            let color = pixel(image, x, y)
            XCTAssertGreaterThan(color.redComponent + color.greenComponent + color.blueComponent, 2.95)
        }
    }

    func testFullyFadedStrokeIsNotDrawn() throws {
        let line = stroke(1, tool: .pen, [NSPoint(x: 5, y: 15), NSPoint(x: 45, y: 15)])
        let image = try XCTUnwrap(AnnotationRenderer.compose(base: white(50, 30), strokes: [(line, 0)], pointSize: CGSize(width: 50, height: 30)))
        let color = pixel(image, 25, 15)
        XCTAssertGreaterThan(color.redComponent + color.greenComponent + color.blueComponent, 2.95)
        let half = try XCTUnwrap(AnnotationRenderer.compose(base: white(50, 30), strokes: [(line, 0.5)], pointSize: CGSize(width: 50, height: 30)))
        let faded = pixel(half, 25, 15)
        XCTAssertLessThan(faded.greenComponent, 0.9, "полупрозрачный штрих виден")
    }

    func testComposeRejectsEmptyGeometry() {
        XCTAssertNil(AnnotationRenderer.compose(base: white(10, 10), strokes: [], pointSize: .zero))
        XCTAssertNil(AnnotationRenderer.compose(base: white(10, 10), strokes: [], pointSize: CGSize(width: 0, height: 5)))
    }

    func testEveryToolDrawsSomething() throws {
        for tool in ScreenAnnotator.Tool.allCases {
            let item = stroke(1, tool: tool, [NSPoint(x: 5, y: 5), NSPoint(x: 45, y: 25)])
            let image = try XCTUnwrap(AnnotationRenderer.compose(base: white(50, 30), strokes: [(item, 1)], pointSize: CGSize(width: 50, height: 30)))
            let rep = NSBitmapImageRep(cgImage: image)
            var changed = false
            for y in 0..<30 { for x in 0..<50 where (rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.greenComponent) < 0.97 { changed = true } }
            XCTAssertTrue(changed, "\(tool)")
        }
    }

    func testSinglePointStrokeIsHarmless() throws {
        let dot = stroke(1, tool: .pen, [NSPoint(x: 10, y: 10)])
        XCTAssertNotNil(AnnotationRenderer.compose(base: white(20, 20), strokes: [(dot, 1)], pointSize: CGSize(width: 20, height: 20)))
        let none = stroke(1, tool: .arrow, [])
        XCTAssertNotNil(AnnotationRenderer.compose(base: white(20, 20), strokes: [(none, 1)], pointSize: CGSize(width: 20, height: 20)))
    }

    // MARK: Файл

    func testUniqueWriteNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Annotate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Снимок с рисунком.png")
        let first = try AnnotationRenderer.writeUnique(Data("1".utf8), to: url)
        let second = try AnnotationRenderer.writeUnique(Data("2".utf8), to: url)
        XCTAssertEqual([first.lastPathComponent, second.lastPathComponent], ["Снимок с рисунком.png", "Снимок с рисунком (2).png"])
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "1")
        XCTAssertThrowsError(try AnnotationRenderer.writeUnique(Data("x".utf8), to: root.appendingPathComponent("a.png"), limit: 0)) { _ in }
    }

    func testPNGEncodingAndName() throws {
        let data = try XCTUnwrap(AnnotationRenderer.png(white(8, 4)))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let name = AnnotationRenderer.snapshotName(date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("Снимок с рисунком "), name)
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertFalse(name.contains("/") || name.contains(":"), "имя допустимо для файловой системы")
    }
}
