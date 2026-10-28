import AppKit
import SwiftUI

package final class HUDPanel: NSPanel {
    package override var canBecomeKey: Bool { true }
}
