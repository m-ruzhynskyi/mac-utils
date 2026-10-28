import CoreGraphics
import Foundation

/// Снятый шаг коллажа: картинка в пикселях, сколько пикселей в точке (2 на Retina), область на экране
/// (в глобальных точках Cocoa — чтобы предложить её для следующего шага) и необязательная подпись.
package struct StepShot: Identifiable {
    package let id: UUID
    package var image: CGImage
    package var unit: CGFloat
    package var rect: CGRect?
    package var caption: String
    /// Сколько памяти держит полноразмерный снимок (4 байта на пиксель).
    package var bytes: Int { image.bytesPerRow * image.height }

    /// Уменьшенная копия для панели шагов: панель не держит и не масштабирует полноразмерные снимки при каждой отрисовке.
    package var thumbnail: CGImage

    package init(id: UUID = UUID(), image: CGImage, unit: CGFloat, rect: CGRect?, caption: String = "") {
        self.id = id
        self.image = image
        self.unit = unit
        self.rect = rect
        self.caption = caption
        thumbnail = Self.makeThumbnail(image) ?? image
    }

    /// Не больше 240 px по большей стороне.
    package static func makeThumbnail(_ image: CGImage, maxSide: CGFloat = 240) -> CGImage? {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height, 1)))
        guard scale < 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Шаги коллажа и действия над ними. Чистая логика без окон: её проверяют тесты.
package struct StepsModel {
    /// Больше шагов коллаж всё равно не уместит читаемо, а память под полноразмерные снимки конечна.
    package static let maxSteps = 20
    package static let maxCaption = 80
    /// Сколько удалённых шагов можно вернуть (они держат полноразмерные снимки).
    package static let maxRemoved = 20
    /// Больше этого шаги вместе занимают заметную часть памяти Mac (шаг 5K-экрана ≈ 59 МБ): коллаж предупреждает.
    package static let memoryWarningBytes = 1_000_000_000

    package private(set) var steps: [StepShot] = []
    /// Шаг, который сейчас переснимается: следующий снимок заменит его, а не добавится в конец.
    package private(set) var retakeTarget: UUID?
    /// Удалённые шаги и их места, последний — в конце: «Вернуть» возвращает их по одному, в обратном порядке.
    package private(set) var removed: [(step: StepShot, index: Int)] = []

    package var canUndo: Bool { !removed.isEmpty }

    /// Память под снимки шагов и удалённых шагов, которые ещё можно вернуть.
    package var memoryBytes: Int { (steps + removed.map(\.step)).reduce(0) { $0 + $1.bytes } }

    package var count: Int { steps.count }
    package var isEmpty: Bool { steps.isEmpty }
    package var isFull: Bool { steps.count >= Self.maxSteps }

    package func index(of id: UUID) -> Int? { steps.firstIndex { $0.id == id } }

    /// Область, которую предложить для следующего снимка: при пересъёмке — область этого шага, иначе — последнего.
    package var proposedRect: CGRect? {
        if let retakeTarget, let index = index(of: retakeTarget) { return steps[index].rect }
        return steps.last?.rect
    }

    /// Номер (с 1) шага, который переснимается.
    package var retakeNumber: Int? { retakeTarget.flatMap(index(of:)).map { $0 + 1 } }

    /// Добавляет снимок или, если идёт пересъёмка, заменяет им тот шаг (подпись и место сохраняются).
    /// Возвращает номер шага (с 1); nil — шагов уже предел.
    @discardableResult
    package mutating func add(_ image: CGImage, unit: CGFloat, rect: CGRect?) -> Int? {
        if let retakeTarget, let index = index(of: retakeTarget) {
            let old = steps[index]
            steps[index] = StepShot(id: old.id, image: image, unit: unit, rect: rect, caption: old.caption)
            self.retakeTarget = nil
            return index + 1
        }
        retakeTarget = nil
        guard !isFull else { return nil }
        steps.append(StepShot(image: image, unit: unit, rect: rect))
        return steps.count
    }

    package mutating func remove(_ id: UUID) {
        guard let index = index(of: id) else { return }
        removed.append((steps.remove(at: index), index))
        if removed.count > Self.maxRemoved { removed.removeFirst(removed.count - Self.maxRemoved) }
        if retakeTarget == id { retakeTarget = nil }
    }

    /// Возвращает последний удалённый шаг на его место (повторно — предыдущий, и так далее).
    @discardableResult
    package mutating func undoRemove() -> Bool {
        guard !isFull, let last = removed.popLast() else { return false }
        steps.insert(last.step, at: min(last.index, steps.count))
        return true
    }

    /// Переносит шаг на место `destination` (индекс в итоговом порядке, обрезается до границ).
    package mutating func move(_ id: UUID, to destination: Int) {
        guard let from = index(of: id) else { return }
        let to = min(max(destination, 0), steps.count - 1)
        guard from != to else { return }
        let step = steps.remove(at: from)
        steps.insert(step, at: to)
    }

    package mutating func beginRetake(_ id: UUID) {
        guard index(of: id) != nil else { return }
        retakeTarget = id
    }

    package mutating func cancelRetake() {
        retakeTarget = nil
    }

    /// Подпись — одна строка, не длиннее `maxCaption`.
    package mutating func setCaption(_ text: String, for id: UUID) {
        guard let index = index(of: id) else { return }
        steps[index].caption = Self.cleanCaption(text)
    }

    package static func cleanCaption(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
        return String(line.prefix(maxCaption))
    }

    /// Куда встанет шаг `index`, если его протащили по полосе миниатюр на `translation` точек
    /// (шаг полосы — `pitch`: ширина миниатюры и промежуток).
    package static func reorderIndex(from index: Int, translation: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard count > 0, pitch > 0, translation.isFinite, pitch.isFinite else { return min(max(index, 0), max(count - 1, 0)) }
        let shift = Int((translation / pitch).rounded())
        return min(max(index + shift, 0), count - 1)
    }
}
