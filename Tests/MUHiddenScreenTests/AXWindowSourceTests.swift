import ApplicationServices
@testable import MUHiddenScreen
import XCTest

/// Разбор ответа AX и строка `--hs-ax-dump` — без запросов к другим программам
/// (`AXUIElementCreateApplication` только создаёт объект, сообщений не шлёт).
final class AXWindowSourceTests: XCTestCase {
    func testElementsAreTypeChecked() {
        let element = AXUIElementCreateApplication(getpid())
        XCTAssertEqual(AXWindowSource.elements([element, element] as CFArray).count, 2)
        XCTAssertEqual(AXWindowSource.elements(["окно", 1] as CFArray).count, 0, "не AXUIElement — пропускаем, а не падаем на мостике")
        XCTAssertEqual(AXWindowSource.elements([element, "x"] as CFArray).count, 1)
        XCTAssertEqual(AXWindowSource.elements(nil).count, 0)
        XCTAssertEqual(AXWindowSource.elements(element).count, 0, "не массив")
        XCTAssertEqual(AXWindowSource.typeName(nil), "nil")
        XCTAssertEqual(AXWindowSource.typeName([] as CFArray), "CFArray")
    }

    func testDumpLineShowsEveryStage() {
        let line = AXDumpFormat.line(name: "Claude", bundleID: "com.anthropic.claudefordesktop", pid: 20111, axPid: 20111, hidden: false,
                                     cgWindows: [(20169, CGRect(x: 208, y: 147, width: 1217, height: 724), 0)],
                                     windowsError: 0, windowsType: "CFArray", windowsCount: 0, childrenError: 0, childrenCount: 3,
                                     appRole: "AXApplication", source: "children",
                                     axWindows: [(20169, CGRect(x: 208, y: 147, width: 1217, height: 724))])
        XCTAssertEqual(line, "AX-дамп: Claude [com.anthropic.claudefordesktop] pid 20111 (AX pid 20111); роль AXApplication; "
                       + "CG окон 1: [20169@208,147 1217×724/слой 0]; kAXWindows: код 0, тип CFArray, элементов 0; "
                       + "kAXChildren: код 0, элементов 3; итог children: [20169@208,147 1217×724]")
    }
}
