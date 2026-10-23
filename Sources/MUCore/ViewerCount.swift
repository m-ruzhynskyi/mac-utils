import Foundation

/// Счётчик зрителей модели: сколько её видов сейчас на экране (`onScreen`). Модели опрашивают, только пока он > 0.
package struct ViewerCount: Equatable {
    package private(set) var value = 0
    package var any: Bool { value > 0 }

    package init() {}

    package mutating func update(_ shown: Bool) {
        value = max(0, value + (shown ? 1 : -1))
    }
}
