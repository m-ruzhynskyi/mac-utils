import MUHiddenScreen
import XCTest

/// Строки между Mac Utils и процессом-помощником (без запуска помощника).
final class HelperProtocolTests: XCTestCase {
    func testCommandsRoundTrip() {
        for command in [HelperCommand.open(width: 1440, height: 900), .apps(["com.anthropic.claudefordesktop", "com.openai.codex"]),
                        .apps([]), .quit, .hideAndQuit] {
            XCTAssertEqual(HelperCommand(line: command.line), command, command.line)
        }
    }

    func testCommandsRejectGarbage() {
        XCTAssertNil(HelperCommand(line: ""))
        XCTAssertNil(HelperCommand(line: "open 10 10"), "слишком маленький дисплей")
        XCTAssertNil(HelperCommand(line: "open 1440"))
        XCTAssertNil(HelperCommand(line: "rm -rf /"))
        XCTAssertEqual(HelperCommand(line: "apps a, ,b\n"), .apps(["a", "b"]))
    }

    func testMessagesRoundTrip() {
        for message in [HelperMessage.display(14), .failed("classMissing"), .terminated] {
            XCTAssertEqual(HelperMessage(line: message.line), message, message.line)
        }
        XCTAssertNil(HelperMessage(line: "display 0"))
        XCTAssertNil(HelperMessage(line: "display x"))
        XCTAssertEqual(HelperMessage(line: HelperMessage.failed("a\nb").line), .failed("a b"))
    }

    func testLineBufferJoinsChunks() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append("disp"), [])
        XCTAssertEqual(buffer.append("lay 14\nterm"), ["display 14"])
        XCTAssertEqual(buffer.append("inated\n\n"), ["terminated", ""])
    }
}
