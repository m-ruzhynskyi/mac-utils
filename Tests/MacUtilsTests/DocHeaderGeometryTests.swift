import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore

/// Геометрия колонтитулов как в Word: нижний — низом на `\footery` и внутри своей страницы (растёт вверх, текст
/// страницы поднимается), верхний — от `\headery` вниз; абзацы с отрицательными отступами выходят в поля.
/// Демо по мотивам структуры настоящих форм: `\titlepg`, высокий `\footerf` (абзацы + таблица), узкое поле снизу.
@MainActor
final class DocHeaderGeometryTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        super.tearDown()
    }

    /// Форма: колонтитул первой страницы — 5 абзацев (два с отступом −1134 и −426 твипов) и таблица 2×1; на второй — короткий.
    nonisolated static var form: String {
        let line = #"\pard\plain\fs20 "#
        var footerFirst = #"{\footerf "#
        footerFirst += line + #"\li-1134\ri-545 Wide left line\par "#
        footerFirst += line + #"\li-426 Second line\par "#
        footerFirst += line + #"Third\par "# + line + #"Fourth\par "# + line + #"Fifth\par "#
        footerFirst += #"\trowd\trgaph108\trleft0\clbrdrt\brdrs\brdrw10 \cellx4000\clbrdrt\brdrs\brdrw10 \cellx8000 "#
        footerFirst += #"\pard\plain\intbl\fs20 $ \cell $ \cell{\trowd\trgaph108\trleft0\cellx4000\cellx8000\row}"#
        footerFirst += #"\pard\plain\par}"#
        var s = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\froman Times New Roman;}}"#
        s += #"\paperw11906\paperh16838\margl1134\margr850\margt660\margb840"#
        s += #"\sectd\titlepg\headery380\footery380{\headerr \pard\plain\fs20 Top line\par}{\headerf \pard\plain\fs20 First top\par}"#
        s += footerFirst + #"{\footerr \pard\plain\li-284\fs20 Page footer\par}"#
        for number in 1...70 { s += #"\pard\plain\fs24 Body paragraph "# + "\(number)" + #" with some words to fill the page\par "# }
        return s + "}"
    }

    private func open() throws -> DocumentController { try XCTUnwrap(load(Data(Self.form.utf8), url: URL(fileURLWithPath: "/tmp/form.frm"))) }

    private func load(_ data: Data, url: URL) -> DocumentController? {
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: EditorDocument(data: data, url: url))
        tab.restoreMode(nil)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        windows.append(window)
        guard let document = tab.documentController else { return nil }
        document.layoutManager.ensureLayout(for: document.layoutManager.textContainers.last!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return document
    }

    func testFooterStaysOnItsPageAndPushesBodyUp() throws {
        let document = try open()
        XCTAssertGreaterThanOrEqual(document.pageCount, 2)
        for page in document.pagesView.pages {
            let footer = page.footerRect, header = page.headerRect, body = page.bodyRect
            XCTAssertNotNil(page.footer, "страница \(page.number): колонтитул есть")
            // Внутри листа и не на разрыве: низ — ровно на \footery от низа листа.
            XCTAssertGreaterThanOrEqual(footer.minY, 0)
            XCTAssertEqual(footer.maxY, page.bounds.height - 380.0 / 20, accuracy: 0.5, "страница \(page.number): низ на \\footery")
            XCTAssertLessThanOrEqual(footer.maxY, page.bounds.height)
            // Текст страницы — над колонтитулом, под верхним.
            XCTAssertLessThanOrEqual(body.maxY, footer.minY + 0.5, "страница \(page.number): текст не заходит на колонтитул")
            XCTAssertGreaterThanOrEqual(body.minY, header.maxY - 0.5)
            // Рамка поля выравнивается по пикселям — допуск в пункт.
            XCTAssertEqual(page.textView.frame.minY, body.minY, accuracy: 1)
            XCTAssertEqual(page.textView.frame.maxY, body.maxY, accuracy: 1)
            XCTAssertEqual(page.container.size.height, body.height, accuracy: 0.01)
        }
        // Первая страница: высокий колонтитул (абзацы + таблица) выше своего поля — текст поднят.
        let first = document.pagesView.pages[0]
        XCTAssertGreaterThan(first.footerHeight, 840.0 / 20 - 380.0 / 20, "колонтитул выше поля снизу")
        XCTAssertLessThan(first.bodyRect.maxY, DocPageView.bodyRect(first.props).maxY, "текст поднят")
        // Выступ в поле: отступ −1134 твипа — колонтитул шире текста на 56,7 pt влево.
        let base = DocPageView.bodyRect(first.props)
        XCTAssertEqual(first.footerRect.minX, base.minX - 1134.0 / 20, accuracy: 0.01)
        XCTAssertEqual(first.footerRect.maxX, base.maxX + 545.0 / 20, accuracy: 0.01)
        // Обычная страница: свой короткий колонтитул с отступом −284.
        let second = document.pagesView.pages[1]
        XCTAssertEqual(second.footer?.string.trimmingCharacters(in: .newlines), "Page footer")
        XCTAssertEqual(second.footerRect.minX, base.minX - 284.0 / 20, accuracy: 0.01)
    }

    /// Рамка правки нижнего колонтитула первой страницы — на этой же странице, у её низа (а не поперёк разрыва).
    func testFooterEditFrameStaysOnPage() throws {
        let document = try open()
        let page = document.pagesView.pages[0]
        DocFormatter.of(document).beginHeaderEditing(page: page, header: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let frame = try XCTUnwrap(page.headerFrame?.rect)
        XCTAssertGreaterThanOrEqual(frame.minY, page.bodyRect.maxY - 10, "рамка ниже текста страницы")
        XCTAssertLessThanOrEqual(frame.maxY, page.bounds.height, "рамка не выходит за лист")
        XCTAssertEqual(page.headerFrame?.title, "Нижний колонтитул — первая страница")
        XCTAssertLessThanOrEqual(frame.minX, page.footerRect.minX, "рамка — с выступом в поле")
        DocFormatter.of(document).endHeaderEditing()
    }

    /// Настоящие формы — только по `MU_REAL_FRM_DIR` (копии вне репозитория); в выводе — только числа.
    func testRealFormsKeepHeadersOnTheirPages() throws {
        guard let dir = ProcessInfo.processInfo.environment["MU_REAL_FRM_DIR"] else { throw XCTSkip("MU_REAL_FRM_DIR не задан") }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { ["frm", "rtf"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        var pages = 0, footers = 0, bad = 0, badFrames = 0, closed = 0
        for (index, url) in urls.enumerated() {
            guard let document = load(try Data(contentsOf: url), url: url) else { closed += 1; continue }
            for page in document.pagesView.pages {
                pages += 1
                guard page.footer != nil else { continue }
                footers += 1
                let footer = page.footerRect, body = page.bodyRect
                if footer.minY < 0 || footer.maxY > page.bounds.height + 0.5 || body.maxY > footer.minY + 0.5
                    || footer.minX < -0.5 || footer.maxX > page.bounds.width + 0.5 { bad += 1 }
            }
            if let page = document.pagesView.pages.first, page.footer != nil {
                DocFormatter.of(document).beginHeaderEditing(page: page, header: false)
                if let frame = page.headerFrame?.rect, frame.minY < page.bodyRect.maxY - 10 || frame.maxY > page.bounds.height {
                    badFrames += 1
                    print("REAL file #\(index): frame \(frame.minY)…\(frame.maxY) body \(page.bodyRect.maxY) page \(page.bounds.height)")
                }
                DocFormatter.of(document).endHeaderEditing()
            }
            for window in windows { window.contentView = nil; window.close() }
            windows = []
        }
        print("REAL files \(urls.count), pages \(pages), footers \(footers), bad \(bad), bad edit frames \(badFrames), not in Document mode \(closed)")
        XCTAssertEqual(bad, 0)
        XCTAssertEqual(badFrames, 0)
    }
}
