import CoreML
import CoreVideo
import Foundation
import MUCore

/// MediaPipe Iris (Apache-2.0) в Core ML: оба глаза пакетом 2×3×64×64, ~0,4 мс на ANE, с кропом ~0,7 мс.
/// Кроп как в MediaPipe: квадрат 2,3 × ширина глаза, повёрнут по линии глаз; глаз справа на кадре отражается.
/// Центр и масштаб кропа сглажены: кроп по выходу самой модели давал обратную связь (масштаб уплывал).
final class IrisModel {
    private let model: MLModel
    private var cropSmooth: [(c: Vec2, w: Double)?] = [nil, nil]
    private static let cropAlpha = 0.25
    private let input: MLMultiArray

    init(compiledURL: URL) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try MLModel(contentsOf: compiledURL, configuration: cfg)
        input = try MLMultiArray(shape: [2, 3, 64, 64], dataType: .float32)
    }

    func reset() { cropSmooth = [nil, nil] }

    /// Где лежит пакет модели: в бандле (Contents/Resources/Models), а при запуске из .build — по переменной MU_GAZE_MODEL.
    static func packageURL() -> URL? {
        if let url = Bundle.main.url(forResource: "IrisLandmarks", withExtension: "mlpackage", subdirectory: "Models") { return url }
        if let path = ProcessInfo.processInfo.environment["MU_GAZE_MODEL"] { return URL(fileURLWithPath: path) }
        return nil
    }

    /// Скомпилированная модель: один раз при первом включении, дальше — из Application Support.
    static func compiledURL(package: URL? = packageURL(), cacheDirectory: URL? = nil) throws -> URL? {
        guard let package else { return nil }
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: package.appendingPathComponent("Manifest.json").path)
        let stamp = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let dir = cacheDirectory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac Utils/Models", isDirectory: true)
        let target = dir.appendingPathComponent("IrisLandmarks-\(stamp).mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: target.path) { return target }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = try MLModel.compileModel(at: package)
        // Старые версии — убрать.
        for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent.hasPrefix("IrisLandmarks-") {
            try? fm.removeItem(at: old)
        }
        try fm.moveItem(at: tmp, to: target)
        return target
    }

    /// Форма обоих глаз. `luma` — для чтения пикселей; буфер уже заблокирован вызывающим.
    func shapes(frames: [EyeFrame], luma: BufferLuma, buffer: CVPixelBuffer) -> [EyeShape?] {
        guard frames.count == 2 else { return [nil, nil] }
        let ptr = input.dataPointer.assumingMemoryBound(to: Float32.self)
        var crops: [(o: Vec2, ex: Vec2, ey: Vec2, s: Double)] = []
        for k in 0..<2 {
            let f = frames[k]
            var center = f.center, width = 2 * f.halfWidth
            if let p = cropSmooth[k], (p.c - center).length < f.halfWidth * 0.5 {
                center = p.c + (center - p.c) * Self.cropAlpha
                width = p.w + (width - p.w) * Self.cropAlpha
            }
            cropSmooth[k] = (center, width)
            let s = 2.3 * width / 64
            let ex = k == 1 ? f.ex * -1 : f.ex, ey = f.ex.perpendicular
            let o = center - ex * (32 * s) - ey * (32 * s)
            crops.append((o, ex, ey, s))
            for y in 0..<64 {
                for x in 0..<64 {
                    let p = o + ex * ((Double(x) + 0.5) * s) + ey * ((Double(y) + 0.5) * s)
                    luma.writeRGB(p, to: ptr, offsets: (((k * 3) * 64 + y) * 64 + x, ((k * 3 + 1) * 64 + y) * 64 + x, ((k * 3 + 2) * 64 + y) * 64 + x))
                }
            }
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["eyes": input])),
              let contour = out.featureValue(for: "contour")?.multiArrayValue,
              let irisPts = out.featureValue(for: "iris")?.multiArrayValue else { return [nil, nil] }
        // Выход модели — fp32 или fp16, а строки бывают выровнены: читаем по шагам массива, а не подряд.
        func value(_ arr: MLMultiArray, _ k: Int, _ i: Int, _ j: Int) -> Double {
            let st = arr.strides.map(\.intValue)
            let idx = k * st[0] + i * st[1] + j * st[2]
            return arr.dataType == .float16 ? Double(arr.dataPointer.assumingMemoryBound(to: Float16.self)[idx])
                : Double(arr.dataPointer.assumingMemoryBound(to: Float32.self)[idx])
        }
        var result: [EyeShape?] = []
        for k in 0..<2 {
            let c = crops[k]
            func point(_ arr: MLMultiArray, _ i: Int, _ n: Int) -> Vec2 {
                let x = value(arr, k, i, 0), y = value(arr, k, i, 1)
                return c.o + c.ex * (x * c.s) + c.ey * (y * c.s)
            }
            let cont = (0..<71).map { point(contour, $0, 71) }
            let ir = (0..<5).map { point(irisPts, $0, 5) }
            result.append(EyeShape.fromMediaPipe(contour: cont, iris: ir, axis: frames[k].ex))
        }
        return result
    }
}

extension BufferLuma {
    /// RGB 0…1 билинейно (кадр BGRA) — сразу в тензор модели, без промежуточных массивов (8 тыс. точек на кадр).
    @inline(__always)
    func writeRGB(_ p: Vec2, to out: UnsafeMutablePointer<Float32>, offsets: (Int, Int, Int)) {
        let x = p.x - 0.5, y = p.y - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = Float32(x - Double(x0)), fy = Float32(y - Double(y0))
        let cx0 = min(max(x0, 0), width - 1), cx1 = min(max(x0 + 1, 0), width - 1)
        let cy0 = min(max(y0, 0), height - 1), cy1 = min(max(y0 + 1, 0), height - 1)
        let r0 = base + cy0 * rowBytes, r1 = base + cy1 * rowBytes
        @inline(__always) func ch(_ c: Int) -> Float32 {
            let a = Float32(r0[cx0 * 4 + c]) * (1 - fx) + Float32(r0[cx1 * 4 + c]) * fx
            let b = Float32(r1[cx0 * 4 + c]) * (1 - fx) + Float32(r1[cx1 * 4 + c]) * fx
            return (a * (1 - fy) + b * fy) / 255
        }
        out[offsets.0] = ch(2); out[offsets.1] = ch(1); out[offsets.2] = ch(0)
    }
}
