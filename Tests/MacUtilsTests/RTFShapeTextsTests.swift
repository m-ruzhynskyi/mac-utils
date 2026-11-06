import XCTest
@testable import MUTextEditor

/// Тексты фигур — в модели отдельным списком, без места в потоке (для счёта слов).
final class RTFShapeTextsTests: XCTestCase {
    func testShapeTextOnceAndDrawingText() {
        let source = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}"#
            + #"\pard Body text\par "#
            + #"{\shp{\*\shpinst\shpleft0\shptop0{\sp{\sn shapeType}{\sv 202}}{\shptxt \pard Shape one\par \pard \'cf\'f0\'e8\u1074?\par}}"#
            + #"{\shprslt{\*\do\dobxcolumn{\dptxbx{\dptxbxtext \pard Shape one\par \pard Copy\par}}}}}"#
            + #"{\shp{\*\shpinst\shpleft0}{\shprslt{\*\do{\dptxbx{\dptxbxtext \pard Only result\par}}}}}"#
            + #"{\*\do\dobxpage{\dptxbx{\dptxbxtext \pard Old drawing\par}}}"#
            + #"{\shpgrp{\*\shpinst{\shp{\*\shpinst{\shptxt \pard In group\par}}}}{\shprslt{\*\do{\dptxbx{\dptxbxtext \pard In group\par}}}}}"#
            + #"\pard After\par}"#
        let model = RTFReader.read(source)
        XCTAssertEqual(model.shapeTexts, ["Shape one", "Прив", "Only result", "Old drawing", "In group"])
        let body = model.body.paragraphs.map { $0.runs.map(\.text).joined() }.joined(separator: "|")
        XCTAssertTrue(body.contains("Body text") && body.contains("After"))
        XCTAssertFalse(body.contains("Shape one") || body.contains("Old drawing"), "в потоке документа текстов фигур нет")
    }
}
