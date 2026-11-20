import Foundation
import simd

// The games two backdrop effects play. They run on the backdrop's render thread and know nothing of
// drawing: each frame they advance by the time that passed and say what the shader should show.

/// What the chess and maze shaders read; laid out as GameUniforms in Backdrop.metal.
struct GameUniforms {
    var moveFrom: Int32 = -1
    var moveTo: Int32 = -1
    var movePiece: Int32 = 0
    var moveProgress: Float = 0
    var lastFrom: Int32 = -1
    var lastTo: Int32 = -1
    var gridWidth: Int32 = 0
    var gridHeight: Int32 = 0
    var pac = SIMD2<Float>(-10, -10)
    var pacAngle: Float = 0
    var mouth: Float = 0
    var ghost0 = SIMD4<Float>(0, 0, 0, 0)
    var ghost1 = SIMD4<Float>(0, 0, 0, 0)
    var ghost2 = SIMD4<Float>(0, 0, 0, 0)
    var ghost3 = SIMD4<Float>(0, 0, 0, 0)
    var power: Int32 = 0
    var cell: Float = 0
}

// MARK: Chess

/// Famous games replayed move by move, each piece sliding to its square, then the next game.
struct ChessReplay {
    /// Squares count from a1 = 0 to h8 = 63. Pieces are 1–6 for white pawn, knight, bishop, rook,
    /// queen and king, 7–12 for black's.
    static let games: [[String]] = [
        // Morphy against the Duke of Brunswick and Count Isouard, Paris 1858: the Opera Game.
        ("e2e4 e7e5 g1f3 d7d6 d2d4 c8g4 d4e5 g4f3 d1f3 d6e5 f1c4 g8f6 f3b3 d8e7 b1c3 c7c6 c1g5 b7b5 "
            + "c3b5 c6b5 c4b5 b8d7 e1c1 a8d8 d1d7 d8d7 h1d1 e7e6 b5d7 f6d7 b3b8 d7b8 d1d8").split(separator: " ").map(String.init),
        // Anderssen against Kieseritzky, London 1851: the Immortal Game.
        ("e2e4 e7e5 f2f4 e5f4 f1c4 d8h4 e1f1 b7b5 c4b5 g8f6 g1f3 h4h6 d2d3 f6h5 f3h4 h6g5 h4f5 c7c6 "
            + "g2g4 h5f6 h1g1 c6b5 h2h4 g5g6 h4h5 g6g5 d1f3 f6g8 c1f4 g5f6 b1c3 f8c5 c3d5 f6b2 f4d6 c5g1 "
            + "e4e5 b2a1 f1e2 b8a6 f5g7 e8d8 f3f6 g8f6 d6e7").split(separator: " ").map(String.init),
    ]

    static let start: [UInt8] = {
        var board = [UInt8](repeating: 0, count: 64)
        let back: [UInt8] = [4, 2, 3, 5, 6, 3, 2, 4]
        for file in 0..<8 {
            board[file] = back[file]
            board[8 + file] = 1
            board[48 + file] = 7
            board[56 + file] = back[file] + 6
        }
        return board
    }()

    static func square(_ name: Substring) -> Int {
        let characters = Array(name.utf8)
        return Int(characters[1] - UInt8(ascii: "1")) * 8 + Int(characters[0] - UInt8(ascii: "a"))
    }

    /// Plays one move in coordinate notation, moving the rook too when the king castles.
    static func play(_ move: String, on board: inout [UInt8]) {
        let from = square(move.prefix(2)), to = square(move.dropFirst(2).prefix(2))
        let piece = board[from]
        board[to] = piece
        board[from] = 0
        if piece == 6 || piece == 12, abs(to - from) == 2 {
            let rookFrom = to > from ? from + 3 : from - 4, rookTo = to > from ? from + 1 : from - 1
            board[rookTo] = board[rookFrom]
            board[rookFrom] = 0
        }
    }

    private static let slide = 0.55, rest = 1.5, ending = 5.0

    var board = Self.start
    private var game = 0
    private var move = 0
    private var clock = 0.0
    private var last: (Int, Int)?
    /// Whether the move being shown has reached its square.
    private var landed = false

    mutating func advance(by elapsed: Double, into uniforms: inout GameUniforms) {
        clock += elapsed
        let moves = Self.games[game]
        if move >= moves.count {
            // A pause on the final position, then the next game from the start.
            if clock >= Self.ending {
                game = (game + 1) % Self.games.count
                move = 0; clock = 0; last = nil
                board = Self.start
            }
        } else if clock >= Self.slide, !landed {
            // The piece lands as its slide ends, so it stays on its new square through the pause.
            let text = moves[move]
            Self.play(text, on: &board)
            last = (Self.square(text.prefix(2)), Self.square(text.dropFirst(2).prefix(2)))
            landed = true
        } else if clock >= Self.slide + Self.rest {
            move += 1
            clock = 0
            landed = false
        }
        uniforms.lastFrom = Int32(last?.0 ?? -1)
        uniforms.lastTo = Int32(last?.1 ?? -1)
        if move < moves.count, !landed {
            let text = moves[move]
            let from = Self.square(text.prefix(2))
            uniforms.moveFrom = Int32(from)
            uniforms.moveTo = Int32(Self.square(text.dropFirst(2).prefix(2)))
            uniforms.movePiece = Int32(board[from])
            uniforms.moveProgress = Float(min(1, clock / Self.slide))
        } else {
            uniforms.moveFrom = -1; uniforms.moveTo = -1; uniforms.movePiece = 0
        }
    }
}

// MARK: Maze

/// A symmetric maze filling the window, cleared by a hunter that heads for the nearest dot and keeps
/// away from ghosts, until a pellet lets it chase them. A cleared maze makes way for a new one.
struct MazeGame {
    static let wall: UInt8 = 1, dot: UInt8 = 2, pellet: UInt8 = 4
    private static let directions = [SIMD2<Int>(1, 0), SIMD2(0, 1), SIMD2(-1, 0), SIMD2(0, -1)]

    private(set) var width = 0
    private(set) var height = 0
    private(set) var cells: [UInt8] = []
    private var random: SplitMixGenerator
    private var pac = Mover(speed: 5.2)
    private var ghosts: [Mover] = []
    private var power = 0.0
    private var mouthClock = 0.0
    private var pause = 0.0

    init(seed: UInt64 = 0x51ED) { random = SplitMixGenerator(seed: seed) }

    /// A new maze for a window of this many cells, when its size changed.
    mutating func fit(width: Int, height: Int) {
        // Odd sizes keep walls on the border; a width of 4n + 3 puts the mirror line in a corridor, so the halves meet.
        let width = max(11, width + (3 - width % 4 + 4) % 4), height = max(9, height | 1)
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height
        build()
    }

    func isOpen(_ cell: SIMD2<Int>) -> Bool {
        cell.x >= 0 && cell.y >= 0 && cell.x < width && cell.y < height && cells[cell.y * width + cell.x] & Self.wall == 0
    }

    private mutating func build() {
        cells = [UInt8](repeating: Self.wall, count: width * height)
        let middle = (width - 1) / 2
        // Carve the left half, rooms on odd squares, then mirror it.
        var stack = [SIMD2<Int>(1, 1)]
        set(stack[0], 0)
        while let current = stack.last {
            let options = Self.directions.map { current &+ $0 &* 2 }.filter {
                $0.x >= 1 && $0.x <= middle && $0.y >= 1 && $0.y < height - 1 && cells[$0.y * width + $0.x] == Self.wall
            }
            guard let next = options.randomElement(using: &random) else { stack.removeLast(); continue }
            set((current &+ next) / 2, 0)
            set(next, 0)
            stack.append(next)
        }
        // Dead ends become loops, as in an arcade maze.
        for y in stride(from: 1, to: height - 1, by: 2) {
            for x in stride(from: 1, through: middle, by: 2) {
                let room = SIMD2(x, y)
                guard Self.directions.filter({ isOpen(room &+ $0) }).count == 1 else { continue }
                let walls = Self.directions.filter {
                    let beyond = room &+ $0 &* 2
                    return !isOpen(room &+ $0) && beyond.x >= 1 && beyond.x <= middle && beyond.y >= 1 && beyond.y < height - 1
                }
                if let wall = walls.randomElement(using: &random) { set(room &+ wall, 0) }
            }
        }
        for y in 0..<height {
            for x in 0...middle { cells[y * width + (width - 1 - x)] = cells[y * width + x] }
        }
        for index in cells.indices where cells[index] == 0 { cells[index] = Self.dot }
        for corner in [SIMD2(1, 1), SIMD2(width - 2, 1), SIMD2(1, height - 2), SIMD2(width - 2, height - 2)] {
            cells[corner.y * width + corner.x] = Self.pellet
        }
        let start = nearestOpen(to: SIMD2(middle, height - 2))
        pac = Mover(speed: 5.2, at: start)
        cells[start.y * width + start.x] = 0
        let den = nearestOpen(to: SIMD2(middle, height / 2 | 1))
        ghosts = (0..<4).map { index in Mover(speed: 4.2 - Double(index) * 0.25, at: den) }
        power = 0
        pause = 0.6
    }

    private mutating func eat(_ cell: SIMD2<Int>) {
        let index = cell.y * width + cell.x
        if cells[index] & Self.pellet != 0 { power = 7 }
        if cells[index] & Self.wall == 0 { cells[index] = 0 }
    }

    private mutating func set(_ cell: SIMD2<Int>, _ value: UInt8) { cells[cell.y * width + cell.x] = value }

    private func nearestOpen(to target: SIMD2<Int>) -> SIMD2<Int> {
        var best = SIMD2(1, 1), distance = Int.max
        for y in 0..<height { for x in 0..<width where isOpen(SIMD2(x, y)) {
            let d = abs(x - target.x) + abs(y - target.y)
            if d < distance { distance = d; best = SIMD2(x, y) }
        } }
        return best
    }

    mutating func advance(by elapsed: Double, into uniforms: inout GameUniforms) {
        guard width > 0 else { return }
        let elapsed = min(elapsed, 0.1)
        mouthClock += elapsed
        if pause > 0 { pause -= elapsed } else { step(elapsed) }
        uniforms.gridWidth = Int32(width)
        uniforms.gridHeight = Int32(height)
        uniforms.pac = pac.position
        uniforms.pacAngle = atan2(Float(pac.heading.y), Float(pac.heading.x))
        uniforms.mouth = Float(abs(sin(mouthClock * 10)))
        let shown = ghosts.map { ghost in
            SIMD4<Float>(ghost.position.x, ghost.position.y, atan2(Float(ghost.heading.y), Float(ghost.heading.x)), 1)
        } + Array(repeating: SIMD4<Float>(0, 0, 0, 0), count: 4)
        uniforms.ghost0 = shown[0]; uniforms.ghost1 = shown[1]; uniforms.ghost2 = shown[2]; uniforms.ghost3 = shown[3]
        // The last two seconds of power flicker, as a warning.
        uniforms.power = power > 2 || (power > 0 && Int(power * 6) % 2 == 0) ? 1 : 0
    }

    private mutating func step(_ elapsed: Double) {
        power = max(0, power - elapsed)
        let dangers = ghosts.map(\.cell)
        let chasing = power > 0
        var distance = elapsed * pac.speed
        while distance > 0 {
            if pac.atCentre, !pac.begin(pacChoice(from: pac.cell, heading: pac.heading, dangers: dangers, chasing: chasing)) { break }
            distance = pac.advance(distance)
            // Each square is eaten as the hunter reaches its centre.
            if pac.atCentre { eat(pac.cell) }
        }
        let target = pac.cell
        for index in ghosts.indices {
            let frightened = power > 0
            var distance = elapsed * ghosts[index].speed * (frightened ? 0.6 : 1)
            while distance > 0 {
                if ghosts[index].atCentre {
                    let way = ghostChoice(from: ghosts[index].cell, heading: ghosts[index].heading, target: target, fleeing: frightened, index: index)
                    if !ghosts[index].begin(way) { break }
                }
                distance = ghosts[index].advance(distance)
            }
        }
        for index in ghosts.indices where simd_distance(ghosts[index].position, pac.position) < 0.6 {
            if power > 0 {
                ghosts[index] = Mover(speed: ghosts[index].speed, at: nearestOpen(to: SIMD2(width / 2, height / 2)))
            } else {
                // Caught: the hunter starts again from the bottom, and the ghosts go home.
                pac = Mover(speed: pac.speed, at: nearestOpen(to: SIMD2((width - 1) / 2, height - 2)))
                let den = nearestOpen(to: SIMD2((width - 1) / 2, height / 2 | 1))
                ghosts = ghosts.map { Mover(speed: $0.speed, at: den) }
                pause = 1
                return
            }
        }
        if !cells.contains(where: { $0 & (Self.dot | Self.pellet) != 0 }) { build() }
    }

    /// A breadth-first walk to the nearest dot, never through a square next to a ghost unless chasing.
    private mutating func pacChoice(from start: SIMD2<Int>, heading: SIMD2<Int>, dangers: [SIMD2<Int>], chasing: Bool) -> SIMD2<Int> {
        let unsafe = Set(chasing ? [] : dangers.flatMap { ghost in [ghost] + Self.directions.map { ghost &+ $0 } }.map { $0.y * width + $0.x })
        var previous = [Int: Int]()
        var queue = [start.y * width + start.x], head = 0
        previous[queue[0]] = -1
        var goal: Int?
        while head < queue.count {
            let index = queue[head]; head += 1
            let cell = SIMD2(index % width, index / width)
            let wanted = chasing ? dangers.contains(cell) : cells[index] & (Self.dot | Self.pellet) != 0
            if index != queue[0], wanted { goal = index; break }
            for direction in Self.directions.shuffled(using: &random) {
                let next = cell &+ direction, key = next.y * width + next.x
                guard isOpen(next), previous[key] == nil, !unsafe.contains(key) else { continue }
                previous[key] = index
                queue.append(key)
            }
        }
        if var step = goal {
            while let back = previous[step], back != queue[0], back >= 0 { step = back }
            return SIMD2(step % width, step / width) &- start
        }
        // Cornered or nothing in reach: any way out, not straight back if it can help it.
        let ways = Self.directions.filter { isOpen(start &+ $0) && !unsafe.contains(($0 &+ start).y * width + ($0 &+ start).x) }
        return ways.filter { $0 != heading &* -1 }.randomElement(using: &random) ?? ways.first ?? heading &* -1
    }

    /// Ghosts never turn back; mostly they take the turn that brings them nearer the hunter, or further when fleeing.
    private mutating func ghostChoice(from start: SIMD2<Int>, heading: SIMD2<Int>, target: SIMD2<Int>, fleeing: Bool, index: Int) -> SIMD2<Int> {
        var ways = Self.directions.filter { isOpen(start &+ $0) && $0 != heading &* -1 }
        if ways.isEmpty { ways = [heading &* -1] }
        let chance = Double(random.next() % 1000) / 1000
        if chance < 0.3 + Double(index) * 0.12 { return ways.randomElement(using: &random)! }
        let distance = { (way: SIMD2<Int>) -> Int in let d = start &+ way &- target; return d.x * d.x + d.y * d.y }
        return (fleeing ? ways.max { distance($0) < distance($1) } : ways.min { distance($0) < distance($1) })!
    }

    /// Moves from square centre to square centre, choosing its way at each centre.
    struct Mover {
        let speed: Double
        private(set) var cell = SIMD2<Int>(1, 1)
        private(set) var heading = SIMD2<Int>(1, 0)
        private var progress = 0.0
        private var next: SIMD2<Int>?

        init(speed: Double, at cell: SIMD2<Int> = SIMD2(1, 1)) { self.speed = speed; self.cell = cell }

        var position: SIMD2<Float> {
            let from = SIMD2<Float>(Float(cell.x), Float(cell.y)) + 0.5
            guard let next else { return from }
            let to = SIMD2<Float>(Float(next.x), Float(next.y)) + 0.5
            return from + (to - from) * Float(progress)
        }

        var atCentre: Bool { next == nil }

        /// Sets off one square that way; false when the way is nowhere.
        mutating func begin(_ way: SIMD2<Int>) -> Bool {
            guard way != .zero else { return false }
            heading = way
            next = cell &+ way
            return true
        }

        /// Goes up to that many squares towards the next centre and returns what is left over.
        mutating func advance(_ distance: Double) -> Double {
            let step = min(distance, 1 - progress)
            progress += step
            if progress >= 1, let next { cell = next; self.next = nil; progress = 0 }
            return distance - step
        }
    }
}

/// SplitMix64, so a maze's randomness is cheap and repeatable.
struct SplitMixGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
