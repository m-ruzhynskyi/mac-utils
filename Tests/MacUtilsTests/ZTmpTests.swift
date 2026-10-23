import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
func err(_ items: Any...) { FileHandle.standardError.write((items.map { "\($0)" }.joined(separator: " ") + "\n").data(using: .utf8)!) }
@MainActor
final class ZTmpTests: XCTestCase {
    func testDebug() throws {
        let env = ProcessInfo.processInfo.environment
        let doc = EditorDocument(data: try Data(contentsOf: URL(fileURLWithPath: env["F"]!)), url: URL(fileURLWithPath: "/tmp/x.rtf"))
        let tab = EditorTab(document: doc); tab.restoreMode(.document); let ws = EditorWorkspace(); ws.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: ws))
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        let document = try XCTUnwrap(tab.documentController)
        for _ in 0..<5 { if let c = document.layoutManager.textContainers.last { document.layoutManager.ensureLayout(for: c) }; RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        let manager = document.layoutManager, model = document.model, rendering = document.rendering
        for (r, row) in model.body.tables[Int(env["T"] ?? "0")!].rows.prefix(Int(env["ROWS"] ?? "2")!).enumerated() {
            err("ROW", r, "h", row.height, "valign", row.cells.map { "\($0.verticalAlign)" })
            for (c, paras) in row.paragraphs.enumerated().prefix(3) {
                var ys: [String] = []
                for p in paras {
                    let range = rendering.paragraphRanges[p]
                    guard range.length > 0 else { continue }
                    var g = manager.glyphIndexForCharacter(at: range.location)
                    while g < manager.glyphIndexForCharacter(at: NSMaxRange(range) - 1) + 1 {
                        var eff = NSRange(); let frag = manager.lineFragmentRect(forGlyphAt: g, effectiveRange: &eff)
                        ys.append(String(format: "%.1f+%.1f", frag.minY, frag.height)); g = NSMaxRange(eff)
                    }
                }
                err("  cell", c, ys.joined(separator: " "))
            }
        }
    }
}
