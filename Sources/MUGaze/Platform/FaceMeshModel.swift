import CoreML
import CoreVideo
import Foundation
import MUCore

/// MediaPipe Face Landmarker v2 (face_landmarks_detector, Apache-2.0) в Core ML: 478 точек лица по кропу 256×256,
/// ~0,6 мс на ANE. Нужен ради век: на узких и на широко раскрытых глазах (в том числе в очках) контур модели Iris
/// ошибается на 3–6 px, а Face Landmarker видит веко правильно (GAZE-33, GAZE-34).
/// Кроп как в compare-скрипте прототипа: квадрат 1,5 × рамка лица Vision, повёрнутый по линии глаз; центр и размер сглажены.
final class FaceMeshModel {
    private let model: MLModel
    private let input: MLMultiArray
    private var crop: (c: Vec2, side: Double)?
    private static let cropAlpha = 0.5
    static let side = 256
    /// Логит присутствия лица: ниже — точкам не верим.
    static let minPresence: Float = 0

    init(compiledURL: URL) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try MLModel(contentsOf: compiledURL, configuration: cfg)
        input = try MLMultiArray(shape: [1, 3, NSNumber(value: Self.side), NSNumber(value: Self.side)], dataType: .float32)
    }

    func reset() { crop = nil }

    static func packageURL() -> URL? { GazeModels.packageURL(name: "FaceLandmarks", env: "MU_GAZE_FACEMESH") }

    static func compiledURL(package: URL? = packageURL(), cacheDirectory: URL? = nil) throws -> URL? {
        try GazeModels.compiledURL(name: "FaceLandmarks", package: package, cacheDirectory: cacheDirectory)
    }

    /// 478 точек в координатах кадра. `faceRect` — рамка лица в пикселях кадра (y вниз), `axis` — линия глаз.
    func landmarks(faceRect: CGRect, axis: Vec2, luma: BufferLuma) -> [Vec2]? {
        var center = Vec2(Double(faceRect.midX), Double(faceRect.midY))
        var side = 1.5 * Double(max(faceRect.width, faceRect.height))
        if let p = crop, (p.c - center).length < p.side * 0.25 {
            center = p.c + (center - p.c) * Self.cropAlpha
            side = p.side + (side - p.side) * Self.cropAlpha
        }
        crop = (center, side)
        let n = Self.side, s = side / Double(n)
        let ex = axis.normalized, ey = ex.perpendicular
        let o = center - ex * (Double(n) / 2 * s) - ey * (Double(n) / 2 * s)
        let ptr = input.dataPointer.assumingMemoryBound(to: Float32.self)
        let plane = n * n
        for y in 0..<n {
            let row = o + ey * ((Double(y) + 0.5) * s)
            for x in 0..<n {
                let p = row + ex * ((Double(x) + 0.5) * s)
                let i = y * n + x
                luma.writeRGB(p, to: ptr, offsets: (i, plane + i, 2 * plane + i))
            }
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["face": input])),
              let lm = out.featureValue(for: "landmarks")?.multiArrayValue,
              let presence = out.featureValue(for: "presence")?.multiArrayValue else { return nil }
        guard Self.read(presence, 0) > Self.minPresence else { return nil }
        let st = lm.strides.map(\.intValue)
        return (0..<478).map { i in
            let x = Self.read(lm, i * st[0]), y = Self.read(lm, i * st[0] + st[1])
            return o + ex * (Double(x) * s) + ey * (Double(y) * s)
        }
    }

    private static func read(_ arr: MLMultiArray, _ idx: Int) -> Float {
        arr.dataType == .float16 ? Float(arr.dataPointer.assumingMemoryBound(to: Float16.self)[idx])
            : arr.dataPointer.assumingMemoryBound(to: Float32.self)[idx]
    }
}
