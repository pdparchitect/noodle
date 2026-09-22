#if NOODLE_DEV_HOOKS
import AppKit
import Foundation
import NoodleCore
import XCTest
@testable import Noodle

/// The titles a scenario film opens and closes with, and the wordmark it writes.
@MainActor final class ScenarioFilmTests: XCTestCase {
    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var directories: [URL] = []
    private var suites: [String] = []
    private var sessions: [ScenarioSession] = []

    override func tearDown() async throws {
        for session in sessions { session.store.stopMonitoring() }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-film-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func session(_ scenario: Scenario) throws -> ScenarioSession {
        let suite = "Noodle.ScenarioFilmTests.\(UUID())"
        suites.append(suite)
        let session = try ScenarioSession(scenario, root: try directory(), defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        session.sleep = { _ in await Task.yield() }
        sessions.append(session)
        return session
    }

    private func scenario(film: String, timeline: String = "[]") throws -> Scenario {
        let folder = try directory()
        let json = """
        { "version": 1, "title": "Fixture", "clock": "09:41",
          "harnesses": { "claude-code": { "models": "builtin" } },
          "agents": [ { "key": "ada", "name": "Ada", "harness": "claude-code", "model": "opus" } ],
          "conversations": [ { "key": "ada", "direct": "ada" } ],
          "film": \(film), "timeline": \(timeline) }
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("scenario.json"))
        return try Scenario.load(from: folder)
    }

    // MARK: The wordmark

    /// The `n` the film writes is the centre line of the shape the app ships as its
    /// symbol. Redrawing one without the other must fail here.
    func testTheWrittenNMatchesTheAppSymbol() throws {
        let symbol = Self.projectRoot.appendingPathComponent("Support/AppSymbol.svg")
        let artwork = try Self.path(inSVG: symbol)
        let written = NoodleWordmark.skeleton.copy(strokingWithWidth: NoodleWordmark.pen,
            lineCap: .round, lineJoin: .round, miterLimit: 10)

        // Both share the icon's 1254 grid and its baseline; the symbol sits 309 units in,
        // and the `n` of the word is everything left of the first `o`.
        let expected = Self.render(artwork, in: CGRect(x: 309, y: 0, width: 740, height: 1254))
        let actual = Self.render(written, in: CGRect(x: 0, y: 0, width: 740, height: 1254))
        var differing = 0, covered = 0
        for index in 0..<expected.count {
            if expected[index] || actual[index] { covered += 1 }
            if expected[index] != actual[index] { differing += 1 }
        }
        XCTAssertGreaterThan(covered, 10_000, "The symbol did not render")
        let mismatch = Double(differing) / Double(covered) * 100
        XCTAssertLessThan(mismatch, 5, "The written n has drifted from Support/AppSymbol.svg")
    }

    func testTheWordmarkIsWrittenFromNothingToTheWholeWord() {
        let rect = CGRect(x: 0, y: 0, width: 800, height: 180)
        XCTAssertTrue(NoodleWordmark(progress: 0).path(in: rect).isEmpty)
        let half = NoodleWordmark(progress: 0.5).path(in: rect).boundingRect
        let whole = NoodleWordmark(progress: 1).path(in: rect).boundingRect
        XCTAssertLessThan(half.maxX, whole.maxX, "Half a word reaches less far than the whole one")
        XCTAssertGreaterThan(whole.width, rect.width * 0.9, "The word fills the space it is given")
        XCTAssertGreaterThan(NoodleWordmark.lineWidth(in: rect), 0)
    }

    func testTheOpeningCardIsSolidBeforeItsTitleMovesAndTheClosingOneFadesIn() {
        let model = ScenarioFilmModel(onLight: false)
        XCTAssertFalse(model.covering, "Nothing covers the app until a card is up")

        model.card = .intro(kicker: "Noodle", title: "A morning with Ada", subtitle: nil)
        XCTAssertTrue(model.covering, "The film opens on its title, so that card is solid at once")
        model.leaving = true
        XCTAssertFalse(model.covering)

        model.leaving = false
        model.card = .outro(tagline: nil)
        XCTAssertFalse(model.covering, "The closing card comes over the app, so it starts clear")
        model.written = true
        XCTAssertTrue(model.covering)
    }

    // MARK: The film

    func testTheFilmPlaysItsTitlesAroundTheTimeline() async throws {
        let timeline = "[ { \"agent\": \"ada\", \"reply\": { \"text\": \"All 42 parser tests pass.\" } } ]"
        let film = "{ \"intro\": { \"title\": \"A morning with Ada\" }, \"outro\": { \"tagline\": \"Bots that live in a chat.\" } }"
        let session = try session(try scenario(film: film, timeline: timeline))
        let conversation = try XCTUnwrap(session.seeded.conversations["ada"])
        var played: [(Scenario.Film.Stage, Int)] = []
        session.playFilm = { stage in
            played.append((stage, (try? session.repository.loadMessages(conversationID: conversation.id).count) ?? -1))
        }
        session.store.startAgents()
        try await session.play()

        XCTAssertEqual(played.map(\.0), [.intro, .outro])
        XCTAssertEqual(played.first?.1, 0, "The intro runs before the timeline says anything")
        XCTAssertEqual(played.last?.1, 1, "The outro runs after the last step")
    }

    func testAScenarioWithoutAFilmPlaysNoTitles() async throws {
        let folder = try directory()
        let json = """
        { "version": 1, "title": "Fixture", "harnesses": { "claude-code": { "models": "builtin" } },
          "agents": [ { "key": "ada", "name": "Ada", "harness": "claude-code", "model": "opus" } ], "timeline": [] }
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("scenario.json"))
        let session = try session(try Scenario.load(from: folder))
        var played = 0
        session.playFilm = { _ in played += 1 }
        try await session.play()
        XCTAssertEqual(played, 0)
    }

    func testTheTitlesFallBackToTheScenarioTitle() throws {
        let scenario = try scenario(film: "{ \"intro\": { \"subtitle\": \"Just the subtitle\" } }")
        XCTAssertNil(scenario.film?.intro?.title)
        XCTAssertEqual(scenario.title, "Fixture", "The card uses the scenario title when the film names none")
    }

    func testFilmSettingsAreChecked() throws {
        for (film, reason) in [("{ \"background\": \"green\" }", "an unknown background"),
                               ("{ \"intro\": { \"title\": \"   \" } }", "a blank title"),
                               ("{ \"outro\": { \"hold\": -2 } }", "a negative hold"),
                               ("{ \"intro\": { \"headline\": \"x\" } }", "an unknown key")] {
            XCTAssertThrowsError(try scenario(film: film), "A film with \(reason) must not load")
        }
        XCTAssertNoThrow(try scenario(film: "{ \"background\": \"white\", \"outro\": { \"hold\": 0 } }"))
    }

    func testAnIntroCanCarryASmallLineAboveItsTitle() throws {
        let scenario = try scenario(film: "{ \"intro\": { \"kicker\": \"Noodle\", \"title\": \"Christmas, handled\" } }")
        XCTAssertEqual(scenario.film?.intro?.kicker, "Noodle")
        XCTAssertThrowsError(try self.scenario(film: "{ \"intro\": { \"kicker\": \" \" } }"), "A blank line must not load")
    }

    /// Text stacks lay out frame to frame, so matching a web page's line-height means
    /// taking the difference out of the spacing between them.
    func testTightLeadingMatchesTheAskedForLineHeight() {
        let size: CGFloat = 48, multiple: CGFloat = 1.0835
        let spacing = ScenarioFilmView.leading(size: size, weight: .semibold, multiple: multiple)
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let natural = font.ascender - font.descender + font.leading
        XCTAssertEqual(natural + spacing, multiple * size, accuracy: 0.01)
        XCTAssertLessThan(spacing, 0, "1.08 is tighter than the font's own line height")
    }

    // MARK: Rendering

    /// A coverage mask of `path` over `box` in design units, at one point per pixel.
    private static func render(_ path: CGPath, in box: CGRect) -> [Bool] {
        let width = Int(box.width / 2), height = Int(box.height / 2)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 0.5, y: 0.5)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(path)
        context.fillPath(using: .evenOdd)
        return (0..<(width * height)).map { bitmap.bitmapData![$0] > 127 }
    }

    /// The single `M`/`C`/`Z` path an app symbol is drawn with.
    private static func path(inSVG url: URL) throws -> CGPath {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let range = text.range(of: #"<path d="[^"]*""#, options: .regularExpression) else {
            throw XCTSkip("\(url.lastPathComponent) has no path")
        }
        let data = String(text[range]).dropFirst(9).dropLast()
        let path = CGMutablePath()
        var numbers: [CGFloat] = [], command = Character(" "), token = ""
        func flush() {
            guard !token.isEmpty, let value = Double(token) else { return }
            numbers.append(CGFloat(value))
            token = ""
        }
        func apply() {
            switch command {
            case "M" where numbers.count >= 2: path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "C":
                for base in stride(from: 0, to: numbers.count - 5, by: 6) {
                    path.addCurve(to: CGPoint(x: numbers[base + 4], y: numbers[base + 5]),
                                  control1: CGPoint(x: numbers[base], y: numbers[base + 1]),
                                  control2: CGPoint(x: numbers[base + 2], y: numbers[base + 3]))
                }
            case "Z": path.closeSubpath()
            default: break
            }
            numbers = []
        }
        for character in data {
            if character.isNumber || character == "." || character == "-" { token.append(character) }
            else if character == "," || character == " " { flush() }
            else { flush(); apply(); command = character }
        }
        flush()
        apply()
        return path
    }
}
#endif
