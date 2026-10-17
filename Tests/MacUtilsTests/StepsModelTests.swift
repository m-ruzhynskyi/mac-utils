import CoreGraphics
import XCTest
@testable import MacUtils

final class StepsModelTests: XCTestCase {
    private func image(_ width: Int = 40, _ height: Int = 30, gray: CGFloat = 0.5) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func model(_ count: Int) -> StepsModel {
        var model = StepsModel()
        for index in 0..<count {
            model.add(image(40 + index), unit: 2, rect: CGRect(x: CGFloat(index) * 10, y: 0, width: 100, height: 80))
        }
        return model
    }

    func testAddNumbersStepsAndRemembersArea() {
        var model = StepsModel()
        XCTAssertNil(model.proposedRect, "до первого шага предлагать нечего")
        XCTAssertEqual(model.add(image(), unit: 2, rect: CGRect(x: 1, y: 2, width: 3, height: 4)), 1)
        XCTAssertEqual(model.add(image(), unit: 1, rect: CGRect(x: 5, y: 6, width: 7, height: 8)), 2)
        XCTAssertEqual(model.count, 2)
        XCTAssertEqual(model.proposedRect, CGRect(x: 5, y: 6, width: 7, height: 8), "«Ещё шаг» предлагает область прошлого шага")
        XCTAssertEqual(model.steps[1].unit, 1)
    }

    func testLimitOfSteps() {
        var model = model(StepsModel.maxSteps)
        XCTAssertTrue(model.isFull)
        XCTAssertNil(model.add(image(), unit: 2, rect: nil), "сверх предела шаг не добавляется")
        XCTAssertEqual(model.count, StepsModel.maxSteps)
    }

    func testRemoveAndUndo() {
        var model = model(3)
        let middle = model.steps[1].id
        model.remove(middle)
        XCTAssertEqual(model.count, 2)
        XCTAssertNil(model.index(of: middle))
        XCTAssertTrue(model.undoRemove())
        XCTAssertEqual(model.steps.map(\.id)[1], middle, "«Вернуть» ставит шаг на прежнее место")
        XCTAssertFalse(model.undoRemove(), "вернуть можно один раз")
        // Удалить последний шаг и вернуть его.
        var single = self.model(1)
        let only = single.steps[0].id
        single.remove(only)
        XCTAssertTrue(single.isEmpty)
        XCTAssertNil(single.proposedRect)
        XCTAssertTrue(single.undoRemove())
        XCTAssertEqual(single.steps.map(\.id), [only])
        // Новое действие забывает удалённое.
        var other = self.model(2)
        other.remove(other.steps[0].id)
        other.add(image(), unit: 2, rect: nil)
        XCTAssertNil(other.lastRemoved)
    }

    func testMoveReorders() {
        var model = model(4)
        let ids = model.steps.map(\.id)
        model.move(ids[0], to: 2)
        XCTAssertEqual(model.steps.map(\.id), [ids[1], ids[2], ids[0], ids[3]])
        model.move(ids[3], to: -5)
        XCTAssertEqual(model.steps.map(\.id), [ids[3], ids[1], ids[2], ids[0]], "индекс обрезается до границ")
        model.move(ids[3], to: 99)
        XCTAssertEqual(model.steps.map(\.id).last, ids[3])
        model.move(UUID(), to: 0)
        XCTAssertEqual(model.count, 4, "неизвестный шаг ничего не меняет")
    }

    func testRetakeReplacesInPlaceKeepingCaption() {
        var model = model(3)
        let target = model.steps[1]
        model.setCaption("Нажмите «Готово»", for: target.id)
        model.beginRetake(target.id)
        XCTAssertEqual(model.retakeNumber, 2)
        XCTAssertEqual(model.proposedRect, target.rect, "при пересъёмке предлагается область этого шага")
        let fresh = image(64, 48, gray: 0.9)
        XCTAssertEqual(model.add(fresh, unit: 1, rect: CGRect(x: 9, y: 9, width: 9, height: 9)), 2)
        XCTAssertEqual(model.count, 3, "пересъёмка не добавляет шаг")
        XCTAssertEqual(model.steps[1].id, target.id)
        XCTAssertEqual(model.steps[1].image.width, 64)
        XCTAssertEqual(model.steps[1].unit, 1)
        XCTAssertEqual(model.steps[1].caption, "Нажмите «Готово»")
        XCTAssertNil(model.retakeTarget)
        // Пересъёмку можно отменить (Esc в режиме снимка): следующий снимок — новый шаг.
        model.beginRetake(model.steps[0].id)
        model.cancelRetake()
        XCTAssertEqual(model.add(image(), unit: 2, rect: nil), 4)
        // Пересъёмка удалённого шага отменяется.
        model.beginRetake(model.steps[0].id)
        model.remove(model.steps[0].id)
        XCTAssertNil(model.retakeTarget)
    }

    func testRetakeWorksWhenFull() {
        var model = model(StepsModel.maxSteps)
        model.beginRetake(model.steps[5].id)
        XCTAssertEqual(model.add(image(), unit: 2, rect: nil), 6, "полный коллаж: заменить шаг можно")
    }

    func testCaptionIsOneShortLine() {
        var model = model(1)
        let id = model.steps[0].id
        model.setCaption("Первая\nвторая", for: id)
        XCTAssertEqual(model.steps[0].caption, "Первая вторая")
        model.setCaption(String(repeating: "я", count: 200), for: id)
        XCTAssertEqual(model.steps[0].caption.count, StepsModel.maxCaption)
    }

    func testDragReorderIndex() {
        // Миниатюра 112 + промежуток 8.
        XCTAssertEqual(StepsModel.reorderIndex(from: 0, translation: 50, pitch: 120, count: 4), 0, "меньше половины шага — на месте")
        XCTAssertEqual(StepsModel.reorderIndex(from: 0, translation: 70, pitch: 120, count: 4), 1)
        XCTAssertEqual(StepsModel.reorderIndex(from: 3, translation: -250, pitch: 120, count: 4), 1)
        XCTAssertEqual(StepsModel.reorderIndex(from: 1, translation: 9_000, pitch: 120, count: 4), 3)
        XCTAssertEqual(StepsModel.reorderIndex(from: 1, translation: -9_000, pitch: 120, count: 4), 0)
    }

    func testThumbnailIsSmall() {
        let shot = StepShot(image: image(2400, 1200), unit: 2, rect: nil)
        XCTAssertEqual(max(shot.thumbnail.width, shot.thumbnail.height), 240)
        let small = StepShot(image: image(100, 50), unit: 2, rect: nil)
        XCTAssertEqual(small.thumbnail.width, 100, "маленький снимок не увеличивается")
    }
}
