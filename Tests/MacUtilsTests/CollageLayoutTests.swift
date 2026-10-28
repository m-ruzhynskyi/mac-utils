import CoreGraphics
import XCTest
@testable import MacUtils
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

@MainActor
final class CollageLayoutTests: XCTestCase {
    private func images(_ count: Int, width: Int = 800, height: Int = 500) -> [CGImage] {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        return Array(repeating: image, count: count)
    }

    func testAutoColumns() {
        XCTAssertEqual(ShotComposer.columnCount(for: images(1), layout: .auto), 1)
        XCTAssertEqual(ShotComposer.columnCount(for: images(2), layout: .auto), 2)
        XCTAssertEqual(ShotComposer.columnCount(for: images(3), layout: .auto), 2)
        XCTAssertEqual(ShotComposer.columnCount(for: images(4), layout: .auto), 2)
        // 5+ — 2 или 3 колонки, что ближе к квадрату.
        XCTAssertEqual(ShotComposer.columnCount(for: images(6), layout: .auto), 2)
        XCTAssertEqual(ShotComposer.columnCount(for: images(9, width: 500, height: 500), layout: .auto), 3)
        XCTAssertEqual(ShotComposer.columnCount(for: images(6, width: 400, height: 800), layout: .auto), 3)
    }

    func testManualLayouts() {
        XCTAssertEqual(ShotComposer.columnCount(for: images(5), layout: .vertical), 1)
        XCTAssertEqual(ShotComposer.columnCount(for: images(5), layout: .horizontal), 5)
        XCTAssertEqual(ShotComposer.columnCount(for: images(9), layout: .grid), 3)
        XCTAssertEqual(ShotComposer.columnCount(for: images(5), layout: .grid), 3)
    }

    func testFourStepsMakeSquareishCanvas() {
        var options = ShotComposer.Options()
        options.layout = .auto
        options.unit = 1
        let collage = ShotComposer.compose(images(4), options: options)
        XCTAssertNotNil(collage)
        let ratio = Double(collage!.width) / Double(collage!.height)
        XCTAssertGreaterThan(ratio, 1.2)
        XCTAssertLessThan(ratio, 1.8)
    }
}

@MainActor
final class CollagePlanTests: XCTestCase {
    private func image(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testRetinaAndNonRetinaStepsKeepTheirScreenSize() {
        // Одно и то же окно 400×300 pt: на Retina 800×600 px, на обычном экране 400×300 px.
        var options = ShotComposer.Options()
        options.layout = .horizontal
        let plan = ShotComposer.plan(sizes: [CGSize(width: 800, height: 600), CGSize(width: 400, height: 300)],
                                     units: [2, 1], options: options)
        XCTAssertEqual(plan.unit, 2, "итог — в самой высокой плотности")
        XCTAssertEqual(plan.content[0].size, CGSize(width: 800, height: 600))
        XCTAssertEqual(plan.content[1].size, CGSize(width: 800, height: 600), "шаг с обычного экрана увеличен до той же плотности")
        let (unit, scales) = ShotComposer.normalizedScales(units: [2, 1, 0, .nan])
        XCTAssertEqual(unit, 2)
        XCTAssertEqual(scales, [1, 2, 2, 2], "непонятная плотность считается 1")
    }

    func testEqualSizePerLayoutWithUpscaleLimit() {
        let sizes = [CGSize(width: 1000, height: 500), CGSize(width: 500, height: 500), CGSize(width: 200, height: 100)]
        let vertical = ShotComposer.equalized(sizes, layout: .vertical)
        XCTAssertEqual(vertical[0].width, 500, "столбик — общая ширина (медиана)")
        XCTAssertEqual(vertical[1].width, 500)
        XCTAssertEqual(vertical[2].width, 400, "увеличение не больше чем вдвое")
        let row = ShotComposer.equalized(sizes, layout: .horizontal)
        XCTAssertEqual(row.map(\.height), [500, 500, 200])
    }

    func testCellsDoNotOverlapAndStayInsideCanvas() {
        var options = ShotComposer.Options()
        options.windowFrame = true
        options.badges = true
        options.arrows = true
        options.captions = ["Один", "", "Три", "Четыре", "Пять"]
        for layout in StepsLayout.allCases {
            options.layout = layout
            let sizes = [CGSize(width: 900, height: 500), CGSize(width: 300, height: 700), CGSize(width: 640, height: 400),
                         CGSize(width: 1200, height: 300), CGSize(width: 500, height: 500)]
            let plan = ShotComposer.plan(sizes: sizes, units: [2, 2, 1, 2, 2], options: options)
            let canvas = CGRect(origin: .zero, size: plan.canvas)
            let boxes = plan.window.indices.map { index in plan.caption[index].map { plan.window[index].union($0) } ?? plan.window[index] }
            for (index, box) in boxes.enumerated() {
                XCTAssertTrue(canvas.contains(box), "\(layout): шаг \(index + 1) внутри холста")
                for other in boxes[(index + 1)...] {
                    XCTAssertFalse(box.insetBy(dx: 1, dy: 1).intersects(other), "\(layout): ячейки не перекрываются")
                }
                XCTAssertEqual(plan.window[index].maxY, plan.content[index].maxY, "содержимое — под заголовком окна")
                XCTAssertEqual(plan.window[index].height - plan.content[index].height, 28 * plan.unit, accuracy: 0.01)
            }
            XCTAssertNotNil(plan.caption[0])
            XCTAssertNil(plan.caption[1], "пустая подпись места не занимает")
            XCTAssertGreaterThanOrEqual(plan.gap, 64 * plan.unit, "между шагами место для стрелки")
        }
    }

    func testIncompleteLastRowIsCentered() {
        var options = ShotComposer.Options()
        options.layout = .grid
        let plan = ShotComposer.plan(sizes: Array(repeating: CGSize(width: 400, height: 300), count: 3), units: [1, 1, 1], options: options)
        XCTAssertEqual(plan.columns, 2)
        XCTAssertEqual(plan.window[2].midX, plan.canvas.width / 2, accuracy: 0.5)
    }

    func testHugeCollageIsScaledDownToTheLimit() {
        var options = ShotComposer.Options()
        options.layout = .horizontal
        let sizes = Array(repeating: CGSize(width: 5120, height: 2880), count: 6)
        let plan = ShotComposer.plan(sizes: sizes, units: Array(repeating: 2, count: 6), options: options)
        XCTAssertLessThan(plan.scale, 1)
        XCTAssertLessThanOrEqual(max(plan.outputSize.width, plan.outputSize.height), options.maxSide)
        XCTAssertLessThanOrEqual(plan.outputSize.width * plan.outputSize.height, options.maxPixels)
        // Обычный коллаж не трогается.
        let small = ShotComposer.plan(sizes: [CGSize(width: 800, height: 600)], units: [2], options: options)
        XCTAssertEqual(small.scale, 1)
    }

    func testRenderedSizeMatchesPlan() throws {
        var options = ShotComposer.Options()
        options.layout = .vertical
        options.windowFrame = true
        options.titles = true
        options.badges = true
        options.arrows = true
        options.captions = ["Шаг с подписью", "Ещё одна подпись, очень длинная, чтобы проверить обрезку многоточием в узкой плашке"]
        options.maxSide = 1000
        let steps: [(image: CGImage, unit: CGFloat)] = [(image(800, 500), 2), (image(300, 200), 1)]
        let plan = ShotComposer.plan(sizes: steps.map { CGSize(width: $0.image.width, height: $0.image.height) },
                                     units: steps.map(\.unit), options: options)
        let collage = try XCTUnwrap(ShotComposer.compose(steps: steps, options: options))
        XCTAssertEqual(CGFloat(collage.width), plan.outputSize.width)
        XCTAssertEqual(CGFloat(collage.height), plan.outputSize.height)
        XCTAssertLessThanOrEqual(max(collage.width, collage.height), 1000)
    }
}
