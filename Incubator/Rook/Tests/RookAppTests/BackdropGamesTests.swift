import XCTest

final class BackdropGamesTests: XCTestCase {
    /// Every move picks up a piece of the side whose turn it is and never lands on its own piece,
    /// so a mistyped move cannot leave the board showing nonsense.
    func testReplayedGamesMoveOnlyTheSideToMove() {
        for game in ChessReplay.games {
            var board = ChessReplay.start
            for (index, move) in game.enumerated() {
                let from = ChessReplay.square(move.prefix(2)), to = ChessReplay.square(move.dropFirst(2).prefix(2))
                let piece = board[from], white = index % 2 == 0
                XCTAssertNotEqual(piece, 0, "\(move) moves from an empty square")
                XCTAssertEqual(piece <= 6, white, "\(move) moves the wrong side's piece")
                if board[to] != 0 { XCTAssertNotEqual(board[to] <= 6, white, "\(move) captures its own piece") }
                ChessReplay.play(move, on: &board)
            }
        }
    }

    /// A piece that has slid to its square stays there; it never shows back where it started while the
    /// board waits for the next move.
    func testAPieceStaysWhereItSlid() {
        var replay = ChessReplay()
        var uniforms = GameUniforms()
        let e2 = ChessReplay.square("e2"), e4 = ChessReplay.square("e4")
        var time = 0.0
        while time < 2.5 {
            replay.advance(by: 0.05, into: &uniforms)
            time += 0.05
            let sliding = uniforms.movePiece != 0 && uniforms.moveFrom == Int32(e2)
            if time > 0.7, time < 2.5, !sliding {
                XCTAssertEqual(replay.board[e4], 1, "the pawn is on e4 at \(time)s")
                XCTAssertEqual(replay.board[e2], 0, "e2 is empty at \(time)s")
            }
        }
    }

    func testCastlingMovesTheRook() {
        var board = ChessReplay.start
        for square in [1, 2, 3] { board[square] = 0 }
        ChessReplay.play("e1c1", on: &board)
        XCTAssertEqual(board[2], 6)
        XCTAssertEqual(board[3], 4)
        XCTAssertEqual(board[0], 0)
    }

    /// Every corridor can be reached from every other, so the hunter can always clear the maze.
    func testMazeCorridorsAreConnected() {
        for (width, height) in [(47, 30), (60, 34), (98, 56)] {
            var maze = MazeGame()
            maze.fit(width: width, height: height)
            let open = (0..<maze.height).flatMap { y in (0..<maze.width).map { SIMD2(Int($0), y) } }.filter(maze.isOpen)
            var seen: Set<SIMD2<Int>> = [open[0]], queue = [open[0]]
            while let cell = queue.popLast() {
                for step in [SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)] where maze.isOpen(cell &+ step) && !seen.contains(cell &+ step) {
                    seen.insert(cell &+ step)
                    queue.append(cell &+ step)
                }
            }
            XCTAssertEqual(seen.count, open.count, "\(width)×\(height) has corridors that cannot be reached")
        }
    }

    func testHunterEatsDots() {
        var maze = MazeGame()
        maze.fit(width: 47, height: 30)
        var uniforms = GameUniforms()
        let before = maze.cells.filter { $0 & MazeGame.dot != 0 }.count
        for _ in 0..<300 { maze.advance(by: 1.0 / 30, into: &uniforms) }
        XCTAssertLessThan(maze.cells.filter { $0 & MazeGame.dot != 0 }.count, before)
    }
}
