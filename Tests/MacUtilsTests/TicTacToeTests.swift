@testable import MacUtils
import XCTest

final class TicTacToeTests: XCTestCase {
    func testWinDrawAndTurns() {
        var board = TicTacToe()
        XCTAssertEqual(board.turn, .x)
        for cell in [0, 3, 1, 4] { XCTAssertTrue(board.play(cell)) }
        XCTAssertFalse(board.play(0), "занятая клетка")
        XCTAssertTrue(board.play(2))
        XCTAssertEqual(board.winner, .x)
        XCTAssertEqual(board.winLine, [0, 1, 2])
        XCTAssertFalse(board.play(8), "после победы ходить нельзя")

        var draw = TicTacToe()
        for cell in [0, 1, 2, 4, 3, 5, 7, 6, 8] { draw.play(cell) }
        XCTAssertTrue(draw.isDraw)
    }

    func testStarterAlternates() {
        var board = TicTacToe()
        XCTAssertEqual(board.mark(inviter: true), .x)
        XCTAssertEqual(board.mark(inviter: false), .o)
        board.start(round: 1)
        XCTAssertEqual(board.mark(inviter: true), .o)
        XCTAssertEqual(board.mark(inviter: false), .x)
        XCTAssertTrue(board.cells.allSatisfy { $0 == nil })
    }
}
