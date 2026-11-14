import CoreVideo
import Foundation
import MUCore
import Vision

/// Яркость BGRA-кадра 0…1 (билинейно). Буфер должен быть заблокирован на чтение, пока живёт сэмплер.
struct BufferLuma: LumaSampler {
    let base: UnsafePointer<UInt8>
    let width: Int, height: Int, rowBytes: Int

    init(locked buffer: CVPixelBuffer) {
        base = UnsafePointer(CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self))
        width = CVPixelBufferGetWidth(buffer); height = CVPixelBufferGetHeight(buffer)
        rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    }

    @inline(__always) private func px(_ x: Int, _ y: Int) -> Double {
        let p = base + min(max(y, 0), height - 1) * rowBytes + min(max(x, 0), width - 1) * 4
        return (0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])) / 255
    }

    func luma(_ p: Vec2) -> Double {
        let x = p.x - 0.5, y = p.y - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y)), fx = x - Double(x0), fy = y - Double(y0)
        let a = px(x0, y0) * (1 - fx) + px(x0 + 1, y0) * fx
        let b = px(x0, y0 + 1) * (1 - fx) + px(x0 + 1, y0 + 1) * fx
        return a * (1 - fy) + b * fy
    }
}

/// Лицо на кадре: Vision (поворот головы, грубые глаза) + точная форма глаз: веки — Face Landmarker, радужка — Iris.
/// Без Face Landmarker (не загрузился или выключен в отладке) веки — из Iris, как в GAZE-33.
/// Поиск лица — раз в `rectEvery` кадров, контуры — на каждом кадре. Вызывается на очереди конвейера.
final class FaceTracker {
    var rectEvery = 3
    private let iris: IrisModel?
    private let faceMesh: FaceMeshModel?
    /// Веки из Face Landmarker (выключение — только для сравнения в отладке).
    var useFaceMesh = true
    private var frameIndex = 0
    private var lastRect: VNFaceObservation?

    private let rects: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()
    private let landmarks: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        return r
    }()

    init(iris: IrisModel?, faceMesh: FaceMeshModel? = nil) { self.iris = iris; self.faceMesh = faceMesh }

    func reset() { lastRect = nil; frameIndex = 0; iris?.reset(); faceMesh?.reset() }

    func track(_ buffer: CVPixelBuffer) -> FaceInput? {
        defer { frameIndex += 1 }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        if lastRect == nil || frameIndex % max(rectEvery, 1) == 0 {
            try? handler.perform([rects])
            lastRect = (rects.results ?? []).max { $0.boundingBox.width < $1.boundingBox.width }
        }
        guard let pose = lastRect else { iris?.reset(); return nil }
        landmarks.inputFaceObservations = [pose]
        try? handler.perform([landmarks])
        guard let obs = landmarks.results?.first, let lm = obs.landmarks, let le = lm.leftEye, let re = lm.rightEye else {
            lastRect = nil; iris?.reset(); return nil
        }
        let w = Double(CVPixelBufferGetWidth(buffer)), h = Double(CVPixelBufferGetHeight(buffer))
        let size = CGSize(width: w, height: h)
        func pts(_ r: VNFaceLandmarkRegion2D) -> [Vec2] { r.pointsInImage(imageSize: size).map { Vec2(Double($0.x), h - Double($0.y)) } }
        func mean(_ a: [Vec2]) -> Vec2 { a.reduce(.zero, +) / Double(a.count) }
        var contours = [pts(le), pts(re)]
        contours.sort { mean($0).x < mean($1).x } // слева на кадре → справа
        let axis = mean(contours[1]) - mean(contours[0])
        let frames = contours.compactMap { EyeFrame.fit(contour: $0, axis: axis) }
        guard frames.count == 2 else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = BufferLuma(locked: buffer)
        var shapes: [EyeShape?] = iris?.shapes(frames: frames, luma: luma, buffer: buffer) ?? [nil, nil]
        if useFaceMesh, let faceMesh {
            let bb = obs.boundingBox
            let rect = CGRect(x: bb.minX * w, y: (1 - bb.maxY) * h, width: bb.width * w, height: bb.height * h)
            if let points = faceMesh.landmarks(faceRect: rect, axis: axis, luma: luma) {
                for k in 0..<2 {
                    let iris = shapes[k].map { (center: $0.iris, radius: $0.irisRadius) }
                    // Глаз FaceMesh должен лежать там же, где глаз Vision, иначе (сбой, чужое лицо) — веки от Iris.
                    guard let mesh = EyeShape.fromFaceMesh(points, eye: k, iris: iris, axis: axis),
                          ((mesh.cornerA + mesh.cornerB) / 2 - frames[k].center).length < frames[k].halfWidth * 0.6 else { continue }
                    shapes[k] = mesh
                }
            } else {
                faceMesh.reset()
            }
        }
        let eyes = frames.indices.map { k -> EyeInput in
            // Радужка: из модели, иначе — поиск по градиентам (если модели нет).
            let fallback = shapes[k] == nil ? IrisLocator.locate(in: frames[k], image: luma)?.center : nil
            return EyeInput(frame: frames[k], iris: shapes[k]?.iris ?? fallback, shape: shapes[k])
        }
        return FaceInput(headYaw: (pose.yaw?.doubleValue ?? 0) * 180 / .pi,
                         headPitch: (pose.pitch?.doubleValue ?? 0) * 180 / .pi, eyes: eyes)
    }
}
