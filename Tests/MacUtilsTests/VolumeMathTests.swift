import XCTest
@testable import MacUtils

final class VolumeMathTests: XCTestCase {
    func testGain() {
        XCTAssertEqual(VolumeMath.gain(percent: 100, muted: false), 1)
        XCTAssertEqual(VolumeMath.gain(percent: 30, muted: false), 0.3, accuracy: 0.0001)
        XCTAssertEqual(VolumeMath.gain(percent: 150, muted: false), 1.5, accuracy: 0.0001)
        XCTAssertEqual(VolumeMath.gain(percent: 400, muted: false), 1.5, accuracy: 0.0001)
        XCTAssertEqual(VolumeMath.gain(percent: -5, muted: false), 0)
        XCTAssertEqual(VolumeMath.gain(percent: 80, muted: true), 0)
    }

    func testNeedsTapOnlyWhenChanged() {
        XCTAssertFalse(VolumeMath.needsTap(percent: 100, muted: false))
        XCTAssertTrue(VolumeMath.needsTap(percent: 99, muted: false))
        XCTAssertTrue(VolumeMath.needsTap(percent: 100, muted: true))
    }

    func testApplyScalesAndClips() {
        let source: [Float] = [0.5, -0.5, 1, -1]
        var out = [Float](repeating: 9, count: 4)
        source.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { VolumeMath.apply(gain: 0.3, to: $0, from: src) }
        }
        XCTAssertEqual(out, [0.15, -0.15, 0.3, -0.3].map { Float($0) }, "линейно при gain ≤ 1")
        source.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { VolumeMath.apply(gain: 1.5, to: $0, from: src) }
        }
        XCTAssertEqual(out[0], 0.75, accuracy: 0.0001, "ниже порога — без искажений")
        XCTAssertTrue(out[2] <= 1 && out[2] > 0.9, "выше порога — мягко к 1")
        XCTAssertEqual(out[3], -out[2])
    }

    func testSoftClipIsMonotonicAndBounded() {
        var previous: Float = -1
        for i in 0...300 {
            let y = VolumeMath.softClip(Float(i) / 100)
            XCTAssertGreaterThanOrEqual(y, previous)
            XCTAssertLessThanOrEqual(y, 1)
            previous = y
        }
    }

    func testStoreKeepsOnlyChangedAndRoundTrips() {
        var store = VolumeStore()
        store.set(.init(percent: 30, muted: false), for: "com.example.a")
        store.set(.init(percent: 100, muted: true), for: "com.example.b")
        store.set(.init(percent: 100, muted: false), for: "com.example.c")
        store.set(.init(percent: 999, muted: false), for: "com.example.d")
        XCTAssertEqual(Set(store.entries.keys), ["com.example.a", "com.example.b", "com.example.d"])
        XCTAssertEqual(store.entry(for: "com.example.d").percent, VolumeMath.maxPercent)
        XCTAssertEqual(store.entry(for: "com.example.zzz"), .init(percent: 100, muted: false))
        // Возврат к 100 % убирает запись.
        store.set(.init(percent: 100, muted: false), for: "com.example.a")
        XCTAssertNil(store.entries["com.example.a"])

        let restored = VolumeStore(data: store.data)
        XCTAssertEqual(restored, store)
        XCTAssertEqual(VolumeStore(data: Data("garbage".utf8)), VolumeStore())
    }
}
