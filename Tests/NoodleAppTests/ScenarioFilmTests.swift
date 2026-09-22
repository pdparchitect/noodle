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

        model.card = .intro(kicker: "Noodle", title: "A morning with Ada", subtitle: nil, icon: nil)
        XCTAssertTrue(model.covering, "The film opens on its title, so that card is solid at once")
        model.leaving = true
        XCTAssertFalse(model.covering)

        model.leaving = false
        model.card = .outro(tagline: nil)
        XCTAssertFalse(model.covering, "The closing card comes over the app, so it starts clear")
        model.written = true
        XCTAssertTrue(model.covering)
    }

    func testTheOpeningCardEmptiesBeforeItLetsTheWindowThrough() {
        let model = ScenarioFilmModel(onLight: false)
        model.card = .intro(kicker: nil, title: "Christmas, handled", subtitle: nil, icon: nil)
        model.written = true
        XCTAssertTrue(model.covering)
        XCTAssertTrue(model.lettering, "The words are up while the card is held")

        model.emptying = true
        XCTAssertFalse(model.lettering, "The words go first")
        XCTAssertTrue(model.covering, "The card stays solid, so the app is never dissolved into")
    }

    /// The wordmark the film writes, as an SVG path: the same stroke, in the same grid.
    private static func wordmarkPathData() -> String {
        func number(_ value: CGFloat) -> String {
            let rounded = (value * 100).rounded() / 100
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
        }
        func point(_ p: CGPoint) -> String { "\(number(p.x)),\(number(p.y))" }
        var parts: [String] = []
        NoodleWordmark.skeleton.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: parts.append("M\(point(points[0]))")
            case .addLineToPoint: parts.append("L\(point(points[0]))")
            case .addCurveToPoint: parts.append("C\(point(points[0])) \(point(points[1])) \(point(points[2]))")
            case .addQuadCurveToPoint: parts.append("Q\(point(points[0])) \(point(points[1]))")
            case .closeSubpath: parts.append("Z")
            @unknown default: break
            }
        }
        return parts.joined(separator: " ")
    }

    /// The wordmark is kept as a drawing too, so it can be used outside a film. It is the
    /// same stroke the film writes, so the two must never drift apart.
    func testTheWordmarkDrawingMatchesWhatTheFilmWrites() throws {
        let file = Self.projectRoot.appendingPathComponent("Support/AppWordmark.svg")
        let expected = Self.wordmarkPathData()
        guard let svg = try? String(contentsOf: file, encoding: .utf8) else {
            XCTFail("Support/AppWordmark.svg is missing. Its path is:\n\(expected)")
            return
        }
        XCTAssertTrue(svg.contains(expected), "Support/AppWordmark.svg has drifted. Its path should be:\n\(expected)")
        XCTAssertTrue(svg.contains("stroke-width=\"\(Int(NoodleWordmark.pen))\""), "The pen must match the film's")
        let box = NoodleWordmark.bounds
        XCTAssertTrue(svg.contains("viewBox=\"\(Int(box.minX)) \(Int(box.minY)) \(Int(box.width)) \(Int(box.height))\""),
                      "The box must be the stroke's own")
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

    func testTypingCuesOneSoundPerCharacterInARecording() async throws {
        let timeline = "[ { \"in\": \"ada\", \"type\": { \"text\": \"Ship it.\" } } ]"
        let session = try session(try scenario(film: "{ }", timeline: timeline))
        var cues: [String] = []
        session.soundCue = { cues.append($0) }
        session.takesShots = true
        session.store.startAgents()
        try await session.play()
        XCTAssertEqual(cues, Array(repeating: "key", count: 8) + ["enter"],
                       "One keystroke each for \"Ship it.\", then the key that sends it")
    }

    func testAReplyCuesASoundOfItsOwn() async throws {
        let timeline = """
        [ { "in": "ada", "type": { "text": "Go" } },
          { "agent": "ada", "reply": { "text": "All 42 parser tests pass." } } ]
        """
        let session = try session(try scenario(film: "{ }", timeline: timeline))
        var cues: [String] = []
        session.soundCue = { cues.append($0) }
        session.takesShots = true
        session.store.startAgents()
        try await session.play()
        XCTAssertEqual(cues, ["key", "key", "enter", "reply"], "A message landing sounds unlike a keystroke")
    }

    func testTypingIsSilentWhenNobodyIsRecording() async throws {
        let timeline = "[ { \"in\": \"ada\", \"type\": { \"text\": \"Ship it.\" } } ]"
        let session = try session(try scenario(film: "{ }", timeline: timeline))
        var cues: [String] = []
        session.soundCue = { cues.append($0) }
        session.store.startAgents()
        try await session.play()
        XCTAssertTrue(cues.isEmpty, "Only a recording needs a sound track")
    }

    func testTypingIsNotMetronomic() async throws {
        let timeline = "[ { \"in\": \"ada\", \"type\": { \"text\": \"Ship it when the tests pass\", \"interval\": 0.05 } } ]"
        let session = try session(try scenario(film: "{ }", timeline: timeline))
        var waits: [Double] = []
        session.sleep = { duration in
            waits.append(Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18)
            await Task.yield()
        }
        session.store.startAgents()
        try await session.play()

        let keys = waits.dropLast()
        XCTAssertEqual(keys.count, 27, "One wait per character")
        XCTAssertGreaterThan(Set(keys).count, 10, "Evenly spaced keys beat like a rotor, so they must vary")
        let average = keys.reduce(0, +) / Double(keys.count)
        XCTAssertEqual(average, 0.05, accuracy: 0.02, "The asked-for interval is still the pace")
        XCTAssertGreaterThan(keys.min() ?? 0, 0, "No character arrives instantly")
    }

    func testAnIntroCanBringUpAPicture() throws {
        let folder = try directory()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let picture = folder.appendingPathComponent("assets/face.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: picture)

        let json = """
        { "version": 1, "title": "Fixture", "harnesses": { "claude-code": { "models": "builtin" } },
          "agents": [ { "key": "ada", "name": "Ada", "harness": "claude-code", "model": "opus" } ],
          "film": { "intro": { "icon": "assets/face.png", "title": "A morning with Ada" } } }
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("scenario.json"))
        XCTAssertEqual(try Scenario.load(from: folder).film?.intro?.icon, "assets/face.png")
        XCTAssertThrowsError(try scenario(film: "{ \"intro\": { \"icon\": \"assets/missing.png\" } }"),
                             "A picture that is not there must not load")
    }

    // MARK: Backgrounds

    func testTheScriptAndTheAppAgreeOnWhereAFetchedFileLands() {
        let address = "https://example.com/clips/earth-spinning.mp4"
        XCTAssertEqual(Scenario.cacheStem(for: address), "78773c13121f0e4b",
                       "The script names downloads the same way; changing this strands every cache")
        XCTAssertEqual(Scenario.cacheStem(for: "https://www.pexels.com/download/video/854261/"), "1b4292543e292d4e")
        XCTAssertTrue(Scenario.isRemote(address))
        XCTAssertFalse(Scenario.isRemote("assets/earth.mp4"))
    }

    func testFetchedFilesAreSharedBetweenScenarios() throws {
        let root = try directory()
        let cache = root.appendingPathComponent(".cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let address = "https://example.com/earth.mp4"
        let fetched = cache.appendingPathComponent(Scenario.cacheStem(for: address) + ".mp4")
        try Data("not really a movie".utf8).write(to: fetched)

        // Two scenarios side by side, both naming the same address.
        for name in ["first", "second"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let json = """
            { "version": 1, "title": "\(name)", "harnesses": { "claude-code": { "models": "builtin" } },
              "agents": [ { "key": "ada", "name": "Ada", "harness": "claude-code", "model": "opus" } ],
              "conversations": [ { "key": "ada", "direct": "ada", "background": { "video": "\(address)" } } ] }
            """
            try Data(json.utf8).write(to: folder.appendingPathComponent("scenario.json"))
            let scenario = try Scenario.load(from: folder)
            XCTAssertEqual(try scenario.media(address).resolvingSymlinksInPath(), fetched.resolvingSymlinksInPath(),
                           "\(name) must read the one copy beside the scenarios, not one of its own")
        }
    }

    func testAFaceCanBeSharedBetweenScenariosInsteadOfCopied() throws {
        let root = try directory()
        let cast = root.appendingPathComponent("cast", isDirectory: true)
        try FileManager.default.createDirectory(at: cast, withIntermediateDirectories: true)
        let face = cast.appendingPathComponent("sol.jpg")
        try Data("not really a face".utf8).write(to: face)

        let folder = root.appendingPathComponent("finances", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
        { "version": 1, "title": "Fixture", "harnesses": { "claude-code": { "models": "builtin" } },
          "agents": [ { "key": "sol", "name": "Sol", "harness": "claude-code", "model": "opus",
                        "avatar": { "image": "cast/sol.jpg" } } ] }
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("scenario.json"))
        let scenario = try Scenario.load(from: folder)
        XCTAssertEqual(try scenario.media("cast/sol.jpg").resolvingSymlinksInPath(), face.resolvingSymlinksInPath(),
                       "A face in the cast is read from beside the scenarios")
        XCTAssertThrowsError(try scenario.media("cast/nobody.jpg"), "A face that is not in the cast must not load")
        XCTAssertThrowsError(try scenario.media("../elsewhere.jpg"), "Nothing outside the scenarios is readable")
    }

    func testAWebAddressThatWasNeverFetchedSaysSo() throws {
        let folder = try directory()
        let json = """
        { "version": 1, "title": "Fixture", "harnesses": { "claude-code": { "models": "builtin" } },
          "agents": [ { "key": "ada", "name": "Ada", "harness": "claude-code", "model": "opus" } ],
          "conversations": [ { "key": "ada", "direct": "ada",
            "background": { "video": "https://example.com/earth.mp4" } } ] }
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("scenario.json"))
        XCTAssertThrowsError(try Scenario.load(from: folder)) { error in
            XCTAssertTrue(error.localizedDescription.contains("has not been fetched"),
                          "The app has no network, so it must say who does: \(error.localizedDescription)")
        }
    }

    func testAWallpaperVideoIsSeededAsOneRatherThanAsAPicture() throws {
        let folder = try directory()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        // Not a playable movie, but the seeder trusts a scenario's own files.
        try Data("not really a movie".utf8).write(to: folder.appendingPathComponent("assets/earth.mp4"))
        let json = """
        { "version": 1, "title": "Fixture", "harnesses": { "claude-code": { "models": "builtin" } },
          "agents": [ { "key": "ada", "name": "Ada", "harness": "claude-code", "model": "opus" } ],
          "conversations": [ { "key": "ada", "direct": "ada", "background": { "video": "assets/earth.mp4" } } ] }
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("scenario.json"))
        let session = try session(try Scenario.load(from: folder))
        let conversation = try XCTUnwrap(session.seeded.conversations["ada"])
        let background = try session.repository.loadBackground(conversationID: conversation.id)
        XCTAssertEqual(background.mediaKind, .video, "A wallpaper that moves must be kept as a video")
        let file = try XCTUnwrap(session.repository.backgroundImageURL(background, conversationID: conversation.id))
        XCTAssertEqual(file.pathExtension, "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The media is copied into the workspace")
    }

    func testAFilmBackgroundIsEitherAColourOrSomethingToPlay() throws {
        XCTAssertNil(try scenario(film: "{ \"background\": \"black\" }").film?.media)
        XCTAssertNil(try scenario(film: "{ \"background\": \"white\" }").film?.media)
        XCTAssertTrue(try scenario(film: "{ \"background\": \"white\" }").film?.isLight == true)
        XCTAssertThrowsError(try scenario(film: "{ \"background\": \"assets/missing.mp4\" }"),
                             "A backdrop that is not there must not load")
    }

    func testAMovingBackgroundRunsUnderTheTitlesRatherThanBeingCoveredUp() {
        let plain = ScenarioFilmModel(onLight: false)
        XCTAssertEqual(plain.scrim, 1, "With nothing behind it, a card is solid")

        let over = ScenarioFilmModel(onLight: false, hasMedia: true)
        XCTAssertLessThan(over.scrim, 1, "A card over a background lets it through for the whole film")
        XCTAssertGreaterThan(over.scrim, 0.4, "Enough of it stays for the words to read")
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
