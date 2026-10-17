import CoreGraphics
import Foundation

/// Снятый шаг коллажа: картинка в пикселях, сколько пикселей в точке (2 на Retina), область на экране
/// (в глобальных точках Cocoa — чтобы предложить её для следующего шага) и необязательная подпись.
struct StepShot: Identifiable {
    let id: UUID
    var image: CGImage
    var unit: CGFloat
    var rect: CGRect?
    var caption: String
    /// Уменьшенная копия для панели шагов: панель не держит и не масштабирует полноразмерные снимки при каждой отрисовке.
    var thumbnail: CGImage

    init(id: UUID = UUID(), image: CGImage, unit: CGFloat, rect: CGRect?, caption: String = "") {
        self.id = id
        self.image = image
        self.unit = unit
        self.rect = rect
        self.caption = caption
        thumbnail = Self.makeThumbnail(image) ?? image
    }

    /// Не больше 240 px по большей стороне.
    static func makeThumbnail(_ image: CGImage, maxSide: CGFloat = 240) -> CGImage? {
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
struct StepsModel {
    /// Больше шагов коллаж всё равно не уместит читаемо, а память под полноразмерные снимки конечна.
    static let maxSteps = 20
    static let maxCaption = 80

    private(set) var steps: [StepShot] = []
    /// Шаг, который сейчас переснимается: следующий снимок заменит его, а не добавится в конец.
    private(set) var retakeTarget: UUID?
    /// Последний удалённый шаг и его место — для «Вернуть».
    private(set) var lastRemoved: (step: StepShot, index: Int)?

    var count: Int { steps.count }
    var isEmpty: Bool { steps.isEmpty }
    var isFull: Bool { steps.count >= Self.maxSteps }

    func index(of id: UUID) -> Int? { steps.firstIndex { $0.id == id } }

    /// Область, которую предложить для следующего снимка: при пересъёмке — область этого шага, иначе — последнего.
    var proposedRect: CGRect? {
        if let retakeTarget, let index = index(of: retakeTarget) { return steps[index].rect }
        return steps.last?.rect
    }

    /// Номер (с 1) шага, который переснимается.
    var retakeNumber: Int? { retakeTarget.flatMap(index(of:)).map { $0 + 1 } }

    /// Добавляет снимок или, если идёт пересъёмка, заменяет им тот шаг (подпись и место сохраняются).
    /// Возвращает номер шага (с 1); nil — шагов уже предел.
    @discardableResult
    mutating func add(_ image: CGImage, unit: CGFloat, rect: CGRect?) -> Int? {
        if let retakeTarget, let index = index(of: retakeTarget) {
            let old = steps[index]
            steps[index] = StepShot(id: old.id, image: image, unit: unit, rect: rect, caption: old.caption)
            self.retakeTarget = nil
            lastRemoved = nil
            return index + 1
        }
        retakeTarget = nil
        guard !isFull else { return nil }
        steps.append(StepShot(image: image, unit: unit, rect: rect))
        lastRemoved = nil
        return steps.count
    }

    mutating func remove(_ id: UUID) {
        guard let index = index(of: id) else { return }
        lastRemoved = (steps.remove(at: index), index)
        if retakeTarget == id { retakeTarget = nil }
    }

    /// Возвращает последний удалённый шаг на его место.
    @discardableResult
    mutating func undoRemove() -> Bool {
        guard let removed = lastRemoved, !isFull else { return false }
        steps.insert(removed.step, at: min(removed.index, steps.count))
        lastRemoved = nil
        return true
    }

    /// Переносит шаг на место `destination` (индекс в итоговом порядке, обрезается до границ).
    mutating func move(_ id: UUID, to destination: Int) {
        guard let from = index(of: id) else { return }
        let to = min(max(destination, 0), steps.count - 1)
        guard from != to else { return }
        let step = steps.remove(at: from)
        steps.insert(step, at: to)
        lastRemoved = nil
    }

    mutating func beginRetake(_ id: UUID) {
        guard index(of: id) != nil else { return }
        retakeTarget = id
    }

    mutating func cancelRetake() {
        retakeTarget = nil
    }

    /// Подпись — одна строка, не длиннее `maxCaption`.
    mutating func setCaption(_ text: String, for id: UUID) {
        guard let index = index(of: id) else { return }
        steps[index].caption = Self.cleanCaption(text)
    }

    static func cleanCaption(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
        return String(line.prefix(maxCaption))
    }

    /// Куда встанет шаг `index`, если его протащили по полосе миниатюр на `translation` точек
    /// (шаг полосы — `pitch`: ширина миниатюры и промежуток).
    static func reorderIndex(from index: Int, translation: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard count > 0, pitch > 0 else { return index }
        let shift = Int((translation / pitch).rounded())
        return min(max(index + shift, 0), count - 1)
    }
}
