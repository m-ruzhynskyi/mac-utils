import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUAudio
@testable import MUScreenshot

/// Раскладка «Документа» заканчивается при любом месте разрыва страницы (зависание 1.9.6): абзацы с заливкой
/// (`NSTextBlock`) у нижнего края страницы — с выступом рамки истории в поля и отрицательными отступами, как в формах,
/// и без них. Если раскладка не кончилась за отведённое время, сторож снимает процесс. Демо — выдуманный текст.
@MainActor
final class DocLayoutHangTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
    }

    override func tearDown() {
        closeWindows()
        defaults.restore()
        super.tearDown()
    }

    private func closeWindows() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
    }

    private static let head = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\froman Times New Roman;}}"#
        + #"{\colortbl;\red0\green0\blue0;\red200\green200\blue200;}"#
        + #"\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134\sectd "#

    /// Сторож: главный поток, застрявший в раскладке, иначе не остановить — процесс снимается с сообщением.
    private func watchdog(_ seconds: Double, _ label: String) -> DispatchWorkItem {
        let item = DispatchWorkItem {
            FileHandle.standardError.write(Data("DocLayoutHangTests: раскладка не закончилась за \(Int(seconds)) с — \(label)\n".utf8))
            exit(3)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    private func open(_ body: String) throws -> DocumentController {
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: EditorDocument(data: Data((Self.head + body + "}").utf8), url: URL(fileURLWithPath: "/tmp/layout-hang.rtf")))
        tab.restoreMode(.document)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        windows.append(window)
        let document = try XCTUnwrap(tab.documentController)
        for _ in 0..<3 {
            if let last = document.layoutManager.textContainers.last { document.layoutManager.ensureLayout(for: last) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return document
    }

    /// Весь текст разложен по страницам (ничего не осталось за последней).
    private func assertLaidOut(_ document: DocumentController, _ label: String) {
        let manager = document.layoutManager
        let shown = document.pagesView.pages.reduce(0) { $0 + manager.glyphRange(for: $1.container).length }
        XCTAssertEqual(shown, manager.numberOfGlyphs, "весь текст на страницах — \(label)")
    }

    private static let words = String(repeating: "Justified demo words fill the shaded paragraph near the bottom of the page. ", count: 3)

    func testShadedParagraphsAtPageBottomFinish() throws {
        // Как в формах: абзац с выступом в поля задаёт рамку истории шире полосы текста; абзацы с заливкой — с
        // отрицательными отступами, соседние — разные блоки.
        let outdent = (
            lead: #"\pard\plain\li-426\ri-447\qj\b\fs18 Wide demo paragraph out into both margins\par "#,
            filler: #"\pard\plain\li-284\ri-425\qj\b\fs18 Filler line of the demo form\par "#,
            shaded: #"\pard\plain\li-284\ri-425\qj\cbpat2\b\fs18 Short shaded demo heading\par "#
                + #"\pard\plain\li-284\ri-427\qj\cbpat2\b\fs18 "# + Self.words + #"\par "#
        )
        // Без выступа: два абзаца с одной заливкой — один блок.
        let plain = (
            lead: "",
            filler: #"\pard\plain\qj\b\fs18 Filler line of the demo form\par "#,
            shaded: #"\pard\plain\qj\cbpat2\b\fs18 Short shaded demo heading\par "# + #"\pard\plain\qj\cbpat2\b\fs18 "# + Self.words + #"\par "#
        )
        // Перебор места разрыва: первые строки блока — у нижнего края страницы, с шагом меньше строки.
        for (name, kind) in [("выступ", outdent), ("без выступа", plain)] {
            for lines in 63...69 {
                for before in stride(from: 0, through: 200, by: 20) {
                    let label = "\(name), строк \(lines), \\sb\(before)"
                    let guardItem = watchdog(30, label)
                    let body = kind.lead + String(repeating: kind.filler, count: lines) + #"\pard\plain\sb\#(before)\fs18 Spacer\par "#
                        + kind.shaded + kind.filler
                    let document = try open(body)
                    guardItem.cancel()
                    assertLaidOut(document, label)
                    closeWindows()
                }
            }
        }
    }

    /// Защита `DocLineMetrics`: один контейнер (как колонтитул или последняя страница без запасной), блок абзацев
    /// с заливкой у нижнего края — typesetter перекладывает его по кругу; после предела повторов раскладка кончается.
    func testLineMetricsGuardEndsBlockRetryLoop() {
        let block = NSTextBlock()
        block.backgroundColor = .lightGray
        let plain = NSMutableParagraphStyle()
        let shaded = NSMutableParagraphStyle()
        shaded.textBlocks = [block]
        shaded.alignment = .justified
        let font = NSFont(name: "Times New Roman", size: 9) ?? .systemFont(ofSize: 9)
        for lines in 60...70 {
            for before in stride(from: 0, through: 20, by: 2) {
                let text = NSMutableAttributedString()
                let filler = NSAttributedString(string: "Filler line of the demo form\n", attributes: [.font: font, .paragraphStyle: plain])
                for _ in 0..<lines { text.append(filler) }
                let spacer = NSMutableParagraphStyle()
                spacer.paragraphSpacingBefore = CGFloat(before)
                text.append(NSAttributedString(string: "Spacer\n", attributes: [.font: font, .paragraphStyle: spacer]))
                text.append(NSAttributedString(string: "Short shaded demo heading\n" + Self.words + "\n", attributes: [.font: font, .paragraphStyle: shaded]))
                let storage = NSTextStorage(attributedString: text)
                let manager = NSLayoutManager()
                manager.delegate = DocLineMetricsDelegate.shared
                let container = NSTextContainer(size: NSSize(width: 496, height: 728))
                container.lineFragmentPadding = 0
                manager.addTextContainer(container)
                storage.addLayoutManager(manager)
                let label = "один контейнер, строк \(lines), над блоком \(before) pt"
                let guardItem = watchdog(30, label)
                manager.ensureLayout(for: container)
                guardItem.cancel()
            }
        }
    }
}
