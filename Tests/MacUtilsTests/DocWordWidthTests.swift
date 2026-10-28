import AppKit
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// Ширины текста как у Word (этап P-2): шрифты Word или метрически совместимые замены, кернинг пар — как у TextKit,
/// межзнаковый интервал `\expnd`, капитель `\caps`/`\scaps`, висячий отступ `\fi` как позиция табуляции.
/// Демо-фикстуры с выдуманным текстом; ожидания — по правилам Word.
@MainActor
final class DocWordWidthTests: XCTestCase {
    private static let header = #"{\rtf1\ansi\ansicpg1251\deff0\deftab708{\fonttbl{\f0\froman\fcharset204 Times New Roman;}{\f1\fswiss\fcharset204 Calibri;}{\f2\froman\fcharset204 Cambria;}}"#

    private func rendered(_ body: String) -> NSAttributedString {
        let model = RTFReader.read((Self.header + body + "}") as NSString)
        return DocRenderer().render(model, previous: nil).1.string
    }

    private func attributes(of probe: String, in text: NSAttributedString) throws -> [NSAttributedString.Key: Any] {
        let range = (text.string as NSString).range(of: probe)
        XCTAssertNotEqual(range.location, NSNotFound, probe)
        guard range.location != NSNotFound else { throw XCTSkip("нет «\(probe)»") }
        return text.attributes(at: range.location, effectiveRange: nil)
    }

    // MARK: - Кернинг и межзнаковый интервал

    /// Кернинг пар не выключается (`.kern` не задаётся): выключение по правилу Word (без `\kerningN` — не кернит) в гейте
    /// почти не меняло разрывы, а форме f144 давало лишнюю страницу (.audit/doc-resume.md).
    func testPairKerningLeftToTextKit() throws {
        let text = rendered(#"\pard\plain\f0\fs24 AVA Toy\par\pard\plain\f0\fs32\kerning28 VAV Tea\par}"#)
        XCTAssertNil(try attributes(of: "AVA", in: text)[.kern])
        XCTAssertNil(try attributes(of: "VAV", in: text)[.kern])
    }

    func testExpandedAndCondensedSpacing() throws {
        let text = rendered(#"\pard\plain\f0\expnd4\expndtw20 wide\par\pard\plain\f0\expnd-2 tight\par\pard\plain\f0\expnd0\expndtw0 flat\par}"#)
        XCTAssertEqual(try attributes(of: "wide", in: text)[.tracking] as? CGFloat, 1, "\\expndtw20 = 1 pt после каждого знака")
        XCTAssertEqual(try attributes(of: "tight", in: text)[.tracking] as? CGFloat, -0.5, "\\expnd-2 = −½ pt (четверти пункта)")
        XCTAssertNil(try attributes(of: "flat", in: text)[.tracking])
        XCTAssertNil(try attributes(of: "wide", in: text)[.kern], "интервал не трогает кернинг пар")
    }

    func testExpandWidensLineLikeWord() {
        func width(_ body: String) -> CGFloat {
            let storage = NSTextStorage(attributedString: rendered(body))
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(size: NSSize(width: 2000, height: 100))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            return manager.usedRect(for: container).width
        }
        let plain = width(#"\pard\plain\f0 abcdefghij\par}"#)
        XCTAssertEqual(width(#"\pard\plain\f0\expndtw20 abcdefghij\par}"#) - plain, 10, accuracy: 0.01, "10 знаков × 1 pt")
    }

    func testSuperscriptTwoThirdsInWholeHalfPoints() throws {
        let text = rendered(#"\pard\plain\f0\fs22 a{\super 1}\fs24 b{\super 2}\fs18 c{\sub 3}\par}"#)
        func size(_ probe: String) throws -> CGFloat { try XCTUnwrap(try attributes(of: probe, in: text)[.font] as? NSFont).pointSize }
        XCTAssertEqual(try size("1"), 7, "11 pt → 7 pt, как у Word")
        XCTAssertEqual(try size("2"), 8)
        XCTAssertEqual(try size("3"), 6)
    }

    // MARK: - Переносы

    func testNoBreakAfterSlashInsideWord() {
        let text = "купли/продажи и/или" as NSString
        XCTAssertFalse(WordLineBreaks.allowsBreak(before: 6, in: text), "после «/» Word не переносит")
        XCTAssertTrue(WordLineBreaks.allowsBreak(before: 14, in: text), "после пробела — да")
        XCTAssertTrue(WordLineBreaks.allowsBreak(before: 0, in: text))
    }

    func testSlashWordMovesToNextLineWhole() {
        let storage = NSTextStorage(string: "aaaa bbbbbbbbbb/cccccccccc", attributes: [.font: NSFont(name: "Times New Roman", size: 12) ?? .systemFont(ofSize: 12)])
        let manager = NSLayoutManager()
        final class Delegate: NSObject, NSLayoutManagerDelegate {
            func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
                WordLineBreaks.allowsBreak(before: charIndex, in: layoutManager.textStorage?.mutableString ?? "")
            }
        }
        let delegate = Delegate()
        manager.delegate = delegate
        storage.addLayoutManager(manager)
        let probe = (storage.string as NSString).size(withAttributes: storage.attributes(at: 0, effectiveRange: nil)).width
        let container = NSTextContainer(size: NSSize(width: probe * 0.9, height: 1000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var lines: [String] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
            lines.append((storage.string as NSString).substring(with: manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
        }
        XCTAssertEqual(lines.map { $0.trimmingCharacters(in: .whitespaces) }, ["aaaa", "bbbbbbbbbb/cccccccccc"])
    }

    // MARK: - Капитель

    func testCapsShownUppercaseSourceUntouched() throws {
        let source = Self.header + #"\pard\plain\f0\caps lower case\caps0  tail\par}"#
        let model = RTFReader.read(source as NSString)
        let (rendering, patch) = DocRenderer().render(model, previous: nil)
        XCTAssertTrue(patch.string.string.hasPrefix("LOWER CASE tail"), "на экране — прописные")
        XCTAssertTrue(source.contains("lower case"), "в файле буквы как были")
        // Единицы показа по-прежнему один к одному с исходником.
        let unit = (patch.string.string as NSString).range(of: "CASE").location
        let mapped = rendering.map.sourceLocation(beforeUnit: unit)
        XCTAssertEqual((source as NSString).substring(with: NSRange(location: mapped, length: 4)), "case")
    }

    func testSmallCapsLowercaseAtEightyPercent() throws {
        let text = rendered(#"\pard\plain\f0\fs20\scaps Ab\par}"#)
        XCTAssertTrue(text.string.hasPrefix("AB"))
        let capital = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let small = try XCTUnwrap(text.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(capital.pointSize, 10)
        XCTAssertEqual(small.pointSize, 8, accuracy: 0.001, "строчные — прописными на 80 %")
    }

    // MARK: - Висячий отступ

    func testHangingIndentIsTabStop() throws {
        let text = rendered(#"\pard\plain\fi-360\li720\f0 1.\tab Item\par\pard\plain\fi-360\li720\tx1440\f0 2.\tab Next\par}"#)
        let first = try XCTUnwrap(try attributes(of: "Item", in: text)[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(first.tabStops.map(\.location), [36], "табуляция первой строки доходит до \\li")
        let second = try XCTUnwrap(try attributes(of: "Next", in: text)[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(second.tabStops.map(\.location), [36, 72])
        let plain = rendered(#"\pard\plain\fi360\li720\f0 a\tab b\par}"#)
        XCTAssertEqual((try attributes(of: "a", in: plain)[.paragraphStyle] as? NSParagraphStyle)?.tabStops.count, 0,
                       "у отступа первой строки вправо своей позиции нет")
    }

    // MARK: - Шрифты Word

    func testTwinsKeepWordWidths() {
        XCTAssertEqual(FontSubstitution.display(for: "Calibri", available: { $0 == "Carlito" || $0 == "Helvetica Neue" }), "Carlito")
        XCTAssertEqual(FontSubstitution.display(for: "Cambria", available: { $0 == "Caladea" || $0 == "Georgia" }), "Caladea")
        XCTAssertEqual(FontSubstitution.display(for: "Calibri", available: { $0 == "Helvetica Neue" }), "Helvetica Neue",
                       "без замены из ресурсов — по таблице, как раньше")
        XCTAssertEqual(FontSubstitution.display(for: "Calibri", available: { _ in true }), "Calibri")
    }

    func testIndexReadsFamiliesFromFiles() throws {
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts")
        let index = WordFonts.buildIndex([fonts])
        XCTAssertEqual(index["Carlito"]?.count, 4)
        XCTAssertEqual(index["Caladea"]?.count, 4)
        XCTAssertNil(index["Calibri"], "по таблице имён в файле, а не по имени файла")
        for name in WordFonts.twinFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fonts.appendingPathComponent(name).path), name)
        }
    }

    /// Документ с Calibri и Cambria: после подготовки шрифтов показ — сами шрифты Word (есть Word) или замены той же
    /// ширины из ресурсов, но не Helvetica Neue / Georgia. Регистрация — только для процесса тестов.
    func testDocumentFontsPreparedForWordWidths() throws {
        WordFonts.prepare(["Calibri", "Cambria", "Times New Roman CYR"])
        let calibri = FontSubstitution.display(for: "Calibri")
        let cambria = FontSubstitution.display(for: "Cambria")
        XCTAssertTrue(["Calibri", "Carlito"].contains(calibri), calibri)
        XCTAssertTrue(["Cambria", "Caladea"].contains(cambria), cambria)
        XCTAssertTrue(WordFonts.prepare(["Calibri"]).isEmpty, "повторно ничего не делается")
        // Ширины Calibri и Carlito совпадают — переносы те же, что у Word.
        let sample = "Пример строки формы 0123456789"
        func width(_ family: String) -> CGFloat {
            let font = DocRenderer().font(family: family, size: 11, bold: false, italic: false)
            return (sample as NSString).size(withAttributes: [.font: font, .kern: 0]).width
        }
        if calibri == "Calibri", FontCatalog.isInstalled("Carlito") {
            XCTAssertEqual(width("Calibri"), width("Carlito"), accuracy: 0.01)
        }
    }
}
