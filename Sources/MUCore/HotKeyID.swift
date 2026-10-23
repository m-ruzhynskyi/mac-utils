import Foundation

package enum HotKeyID {
    package static let settings: UInt32 = 1
    package static let screenshot: UInt32 = 2
    package static let screenshotOCR: UInt32 = 3
    package static let layoutFix: UInt32 = 4
    package static let tools: UInt32 = 5
    package static let dropShelf: UInt32 = 6
    package static let annotate: UInt32 = 8
    package static let fixText: UInt32 = 9
    package static let qr: UInt32 = 7
    /// 10…20 — раскладка окон (по одному на сочетание).
    package static let windowSnapBase: UInt32 = 10
    package static let appVolume: UInt32 = 30
    package static let windowPin: UInt32 = 31
    package static let meeting: UInt32 = 32
    package static let focus: UInt32 = 33
    package static let textEditor: UInt32 = 34
    package static let videoPlayer: UInt32 = 35
}
